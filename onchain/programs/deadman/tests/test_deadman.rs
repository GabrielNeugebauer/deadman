use {
    anchor_lang::{
        prelude::Pubkey,
        solana_program::{clock::Clock, instruction::Instruction, rent::Rent, system_program},
        AccountDeserialize, Discriminator, InstructionData, ToAccountMetas,
    },
    anchor_spl::associated_token::get_associated_token_address_with_program_id,
    deadman::VestingInput,
    deadman::{
        AmountMode, Config, Rail, RuleInput, Subscription, SubscriptionConfig, Vault, CONFIG_SEED,
        SUBSCRIPTION_SEED, SUB_CONFIG_SEED, VAULT_SEED,
    },
    litesvm::LiteSVM,
    litesvm_token::{
        get_spl_account, spl_token::state::Account as SplAccount,
        CreateAssociatedTokenAccountIdempotent, CreateMint, MintTo, TOKEN_ID,
    },
    solana_keypair::Keypair,
    solana_message::{Message, VersionedMessage},
    solana_signer::Signer,
    solana_transaction::versioned::VersionedTransaction,
};

const SOL: u64 = 1_000_000_000;
const DAY: i64 = 86_400;
const INTERVAL: i64 = 7 * DAY;
const LOCK: i64 = 3 * DAY;
const GRACE: i64 = 30 * DAY;
const FEE_PUBLIC: u16 = 200;
const FEE_PRIVATE: u16 = 500;
const ZCASH_STIPEND: u64 = 3_000_000;
const CLOAK_STIPEND: u64 = 12_000_000;

struct Env {
    svm: LiteSVM,
    admin: Keypair,
    treasury: Keypair,
    owner: Keypair,
    guard: Keypair,
    keeper: Keypair,
    /// Plan the helpers act on.
    plan: u16,
    /// Subscription account the payout helpers pass instead of the owner's.
    sub_override: Option<Pubkey>,
}

fn config_pda() -> Pubkey {
    Pubkey::find_program_address(&[CONFIG_SEED], &deadman::id()).0
}

fn vault_pda(owner: &Pubkey, plan_id: u16) -> Pubkey {
    Pubkey::find_program_address(
        &[VAULT_SEED, owner.as_ref(), &plan_id.to_le_bytes()],
        &deadman::id(),
    )
    .0
}

fn sub_pda(owner: &Pubkey) -> Pubkey {
    Pubkey::find_program_address(&[SUBSCRIPTION_SEED, owner.as_ref()], &deadman::id()).0
}

fn ata(owner: &Pubkey, mint: &Pubkey) -> Pubkey {
    get_associated_token_address_with_program_id(owner, mint, &TOKEN_ID)
}

fn program_data_pda() -> Pubkey {
    Pubkey::find_program_address(
        &[deadman::id().as_ref()],
        &anchor_lang::solana_program::bpf_loader_upgradeable::ID,
    )
    .0
}

fn rule(
    beneficiary: &Pubkey,
    rail: Rail,
    after: i64,
    mint: Option<Pubkey>,
    mode: AmountMode,
    amount: u64,
) -> RuleInput {
    RuleInput {
        beneficiary: *beneficiary,
        rail,
        after_secs: after,
        mint,
        mode,
        amount,
    }
}

fn all_to(beneficiary: &Pubkey) -> Vec<RuleInput> {
    vec![rule(
        beneficiary,
        Rail::Solana,
        10 * DAY,
        None,
        AmountMode::Percent,
        10_000,
    )]
}

impl Env {
    fn new() -> Self {
        let mut svm = LiteSVM::new();
        let bytes = include_bytes!(concat!(
            env!("CARGO_TARGET_TMPDIR"),
            "/../deploy/deadman.so"
        ));
        svm.add_program(deadman::id(), bytes).unwrap();

        let admin = Keypair::new();
        let treasury = Keypair::new();
        let owner = Keypair::new();
        let guard = Keypair::new();
        let keeper = Keypair::new();
        for k in [&admin, &treasury, &owner, &guard, &keeper] {
            svm.airdrop(&k.pubkey(), 100 * SOL).unwrap();
        }

        // LiteSVM deploys with no upgrade authority; make `admin` the
        // authority so init_config's gate can be exercised.
        let pd = program_data_pda();
        let mut acc = svm.get_account(&pd).unwrap();
        acc.data[12] = 1;
        acc.data[13..45].copy_from_slice(admin.pubkey().as_ref());
        svm.set_account(pd, acc).unwrap();

        let mut env = Self {
            svm,
            admin,
            treasury,
            owner,
            guard,
            keeper,
            plan: 0,
            sub_override: None,
        };
        env.set_time(1_800_000_000);
        env
    }

    fn vault_addr(&self) -> Pubkey {
        vault_pda(&self.owner.pubkey(), self.plan)
    }

    /// Subscription account passed to payouts (the owner's PDA by default).
    fn sub_addr(&self) -> Pubkey {
        self.sub_override
            .unwrap_or_else(|| sub_pda(&self.owner.pubkey()))
    }

    fn now(&self) -> i64 {
        self.svm.get_sysvar::<Clock>().unix_timestamp
    }

    fn set_time(&mut self, ts: i64) {
        let mut clock = self.svm.get_sysvar::<Clock>();
        clock.unix_timestamp = ts;
        self.svm.set_sysvar(&clock);
    }

    fn advance(&mut self, secs: i64) {
        let t = self.now() + secs;
        self.set_time(t);
    }

    fn send(&mut self, ix: Instruction, signers: &[&Keypair]) -> Result<u64, String> {
        self.svm.expire_blockhash();
        let msg = Message::new_with_blockhash(
            &[ix],
            Some(&signers[0].pubkey()),
            &self.svm.latest_blockhash(),
        );
        let tx = VersionedTransaction::try_new(VersionedMessage::Legacy(msg), signers).unwrap();
        self.svm
            .send_transaction(tx)
            .map(|m| m.compute_units_consumed)
            .map_err(|e| format!("{:?}\n{}", e.err, e.meta.logs.join("\n")))
    }

    fn vault(&self) -> Vault {
        let acc = self.svm.get_account(&self.vault_addr()).unwrap();
        Vault::try_deserialize(&mut acc.data.as_slice()).unwrap()
    }

    fn lamports(&self, k: &Pubkey) -> u64 {
        self.svm.get_account(k).map(|a| a.lamports).unwrap_or(0)
    }

    fn token_balance(&self, k: &Pubkey) -> u64 {
        get_spl_account::<SplAccount>(&self.svm, k).unwrap().amount
    }

    fn withdrawable(&self) -> u64 {
        let v = self.vault_addr();
        let acc = self.svm.get_account(&v).unwrap();
        let rent = self
            .svm
            .minimum_balance_for_rent_exemption(acc.data.len())
            .max(self.vault().rent_paid);
        acc.lamports - rent
    }

    fn config_ix(&self, signer: &Pubkey, public: u16, private: u16) -> Instruction {
        Instruction::new_with_bytes(
            deadman::id(),
            &deadman::instruction::InitConfig {
                treasury: self.treasury.pubkey(),
                fee_bps_public: public,
                fee_bps_private: private,
            }
            .data(),
            deadman::accounts::InitConfig {
                admin: *signer,
                config: config_pda(),
                program: deadman::id(),
                program_data: program_data_pda(),
                system_program: system_program::ID,
            }
            .to_account_metas(None),
        )
    }

    fn init_config(&mut self) {
        let admin = self.admin.insecure_clone();
        let ix = self.config_ix(&admin.pubkey(), FEE_PUBLIC, FEE_PRIVATE);
        self.send(ix, &[&admin]).unwrap();
    }

    fn create_vault(&mut self, rules: Vec<RuleInput>) -> Result<u64, String> {
        let ix = Instruction::new_with_bytes(
            deadman::id(),
            &deadman::instruction::CreateVault {
                plan_id: self.plan,
                label: format!("Plan {}", self.plan),
                guard: self.guard.pubkey(),
                interval_secs: INTERVAL,
                lock_secs: LOCK,
                skip_grace_secs: GRACE,
                rules,
            }
            .data(),
            deadman::accounts::CreateVault {
                owner: self.owner.pubkey(),
                payer: self.owner.pubkey(),
                vault: self.vault_addr(),
                system_program: system_program::ID,
            }
            .to_account_metas(None),
        );
        let owner = self.owner.insecure_clone();
        self.send(ix, &[&owner])
    }

    fn deposit_sol(&mut self, amount: u64) {
        let ix = anchor_lang::solana_program::system_instruction::transfer(
            &self.owner.pubkey(),
            &self.vault_addr(),
            amount,
        );
        let owner = self.owner.insecure_clone();
        self.send(ix, &[&owner]).unwrap();
    }

    fn owner_ix<T: InstructionData>(&self, data: T) -> Instruction {
        Instruction::new_with_bytes(
            deadman::id(),
            &data.data(),
            deadman::accounts::OwnerAction {
                owner: self.owner.pubkey(),
                vault: self.vault_addr(),
            }
            .to_account_metas(None),
        )
    }

    fn update_policy(
        &mut self,
        rules: Vec<RuleInput>,
        guardian: Option<Pubkey>,
    ) -> Result<u64, String> {
        let ix = self.owner_ix(deadman::instruction::UpdatePolicy {
            label: "Updated".to_string(),
            interval_secs: INTERVAL,
            lock_secs: LOCK,
            skip_grace_secs: GRACE,
            rules,
            guardian,
        });
        let owner = self.owner.insecure_clone();
        self.send(ix, &[&owner])
    }

    fn pulse(&mut self, signer: &Keypair) -> Result<u64, String> {
        let ix = Instruction::new_with_bytes(
            deadman::id(),
            &deadman::instruction::Pulse {}.data(),
            deadman::accounts::Pulse {
                signer: signer.pubkey(),
                vault: self.vault_addr(),
            }
            .to_account_metas(None),
        );
        let signer = signer.insecure_clone();
        self.send(ix, &[&signer])
    }

    fn lockdown(&mut self, signer: &Keypair) -> Result<u64, String> {
        let ix = Instruction::new_with_bytes(
            deadman::id(),
            &deadman::instruction::Lockdown {}.data(),
            deadman::accounts::Lockdown {
                signer: signer.pubkey(),
                vault: self.vault_addr(),
            }
            .to_account_metas(None),
        );
        let signer = signer.insecure_clone();
        self.send(ix, &[&signer])
    }

    fn withdraw_sol(&mut self, amount: u64) -> Result<u64, String> {
        let ix = Instruction::new_with_bytes(
            deadman::id(),
            &deadman::instruction::WithdrawSol { amount }.data(),
            deadman::accounts::WithdrawSol {
                owner: self.owner.pubkey(),
                vault: self.vault_addr(),
            }
            .to_account_metas(None),
        );
        let owner = self.owner.insecure_clone();
        self.send(ix, &[&owner])
    }

    fn skip(&mut self, index: u8) -> Result<u64, String> {
        self.skip_with(index, None)
    }

    fn skip_token(&mut self, index: u8, mint: &Pubkey) -> Result<u64, String> {
        let vault_token = ata(&self.vault_addr(), mint);
        self.skip_with(index, Some(vault_token))
    }

    fn skip_with(&mut self, index: u8, vault_token: Option<Pubkey>) -> Result<u64, String> {
        let ix = Instruction::new_with_bytes(
            deadman::id(),
            &deadman::instruction::SkipRule { index }.data(),
            deadman::accounts::SkipRule {
                caller: self.keeper.pubkey(),
                vault: self.vault_addr(),
                vault_token,
            }
            .to_account_metas(None),
        );
        let keeper = self.keeper.insecure_clone();
        self.send(ix, &[&keeper])
    }

    fn execute_sol(&mut self, index: u8, beneficiary: &Pubkey) -> Result<u64, String> {
        let treasury = self.treasury.pubkey();
        self.execute_sol_with(index, beneficiary, &treasury)
    }

    fn execute_sol_with(
        &mut self,
        index: u8,
        beneficiary: &Pubkey,
        treasury: &Pubkey,
    ) -> Result<u64, String> {
        let ix = Instruction::new_with_bytes(
            deadman::id(),
            &deadman::instruction::ExecuteSolRule { index }.data(),
            deadman::accounts::ExecuteSolRule {
                executor: self.keeper.pubkey(),
                vault: self.vault_addr(),
                config: config_pda(),
                beneficiary: *beneficiary,
                treasury: *treasury,
                subscription: self.sub_addr(),
            }
            .to_account_metas(None),
        );
        let keeper = self.keeper.insecure_clone();
        self.send(ix, &[&keeper])
    }

    fn execute_token(
        &mut self,
        index: u8,
        beneficiary: &Pubkey,
        mint: &Pubkey,
    ) -> Result<u64, String> {
        // The program no longer creates the beneficiary's account; clients
        // create the ATA (or pass any token account the beneficiary owns).
        let admin = self.admin.insecure_clone();
        CreateAssociatedTokenAccountIdempotent::new(&mut self.svm, &admin, mint)
            .owner(beneficiary)
            .send()
            .map_err(|e| format!("{:?}", e.err))?;
        self.execute_token_to(index, beneficiary, mint, &ata(beneficiary, mint))
    }

    fn execute_token_to(
        &mut self,
        index: u8,
        beneficiary: &Pubkey,
        mint: &Pubkey,
        destination: &Pubkey,
    ) -> Result<u64, String> {
        let vault = self.vault_addr();
        let ix = Instruction::new_with_bytes(
            deadman::id(),
            &deadman::instruction::ExecuteTokenRule { index }.data(),
            deadman::accounts::ExecuteTokenRule {
                executor: self.keeper.pubkey(),
                vault,
                config: config_pda(),
                mint: *mint,
                vault_token: ata(&vault, mint),
                beneficiary: *beneficiary,
                beneficiary_token: *destination,
                treasury_token: ata(&self.treasury.pubkey(), mint),
                token_program: TOKEN_ID,
                subscription: self.sub_addr(),
            }
            .to_account_metas(None),
        );
        let keeper = self.keeper.insecure_clone();
        self.send(ix, &[&keeper])
    }

    fn withdraw_token(&mut self, mint: &Pubkey, amount: u64) -> Result<u64, String> {
        let vault = self.vault_addr();
        let ix = Instruction::new_with_bytes(
            deadman::id(),
            &deadman::instruction::WithdrawToken { amount }.data(),
            deadman::accounts::WithdrawToken {
                owner: self.owner.pubkey(),
                vault,
                mint: *mint,
                vault_token: ata(&vault, mint),
                owner_token: ata(&self.owner.pubkey(), mint),
                token_program: TOKEN_ID,
            }
            .to_account_metas(None),
        );
        let owner = self.owner.insecure_clone();
        self.send(ix, &[&owner])
    }

    /// New mint with the vault funded and owner/treasury ATAs created.
    fn token_setup(&mut self, vault_amount: u64) -> Pubkey {
        let admin = self.admin.insecure_clone();
        let mint = CreateMint::new(&mut self.svm, &admin)
            .decimals(6)
            .send()
            .unwrap();
        let vault = self.vault_addr();
        for owner in [vault, self.owner.pubkey(), self.treasury.pubkey()] {
            CreateAssociatedTokenAccountIdempotent::new(&mut self.svm, &admin, &mint)
                .owner(&owner)
                .send()
                .unwrap();
        }
        MintTo::new(
            &mut self.svm,
            &admin,
            &mint,
            &ata(&vault, &mint),
            vault_amount,
        )
        .send()
        .unwrap();
        mint
    }
}

fn ready(rules: Vec<RuleInput>) -> Env {
    let mut env = Env::new();
    env.init_config();
    env.create_vault(rules).unwrap();
    env
}

fn fee(gross: u64, bps: u16) -> u64 {
    gross * u64::from(bps) / 10_000
}

#[test]
fn config_requires_upgrade_authority_and_caps_fees() {
    let mut env = Env::new();
    let intruder = Keypair::new();
    env.svm.airdrop(&intruder.pubkey(), SOL).unwrap();
    let ix = env.config_ix(&intruder.pubkey(), FEE_PUBLIC, FEE_PRIVATE);
    assert!(env.send(ix, &[&intruder]).is_err());

    let admin = env.admin.insecure_clone();
    let ix = env.config_ix(&admin.pubkey(), 200, 501);
    assert!(env.send(ix, &[&admin]).is_err(), "5% cap");

    env.init_config();
    let acc = env.svm.get_account(&config_pda()).unwrap();
    let config = Config::try_deserialize(&mut acc.data.as_slice()).unwrap();
    assert_eq!(
        (config.fee_bps_public, config.fee_bps_private),
        (FEE_PUBLIC, FEE_PRIVATE)
    );

    let set = |treasury: Pubkey, signer: Pubkey, public: u16| {
        Instruction::new_with_bytes(
            deadman::id(),
            &deadman::instruction::SetConfig {
                treasury,
                fee_bps_public: public,
                fee_bps_private: FEE_PRIVATE,
            }
            .data(),
            deadman::accounts::SetConfig {
                admin: signer,
                config: config_pda(),
            }
            .to_account_metas(None),
        )
    };
    let treasury = env.treasury.pubkey();
    let bad = set(treasury, intruder.pubkey(), 100);
    assert!(env.send(bad, &[&intruder]).is_err());
    let zero_treasury = set(Pubkey::default(), admin.pubkey(), 100);
    assert!(env.send(zero_treasury, &[&admin]).is_err());
    let good = set(treasury, admin.pubkey(), 100);
    env.send(good, &[&admin]).unwrap();
}

#[test]
fn guard_pulses_and_streak_tracks_days() {
    let b = Keypair::new();
    let mut env = ready(all_to(&b.pubkey()));
    assert_eq!(env.vault().streak, 1);

    env.advance(DAY);
    let guard = env.guard.insecure_clone();
    env.pulse(&guard).unwrap();
    assert_eq!(env.vault().streak, 2);
    env.advance(60);
    env.pulse(&guard).unwrap();
    assert_eq!(env.vault().streak, 2, "same-day pulse keeps streak");
    env.advance(3 * DAY);
    env.pulse(&guard).unwrap();
    let v = env.vault();
    assert_eq!((v.streak, v.best_streak, v.total_pulses), (1, 2, 4));

    let stranger = Keypair::new();
    env.svm.airdrop(&stranger.pubkey(), SOL).unwrap();
    assert!(env.pulse(&stranger).is_err());
}

#[test]
fn rule_validation() {
    let mut env = Env::new();
    env.init_config();
    let a = Keypair::new().pubkey();
    let owner = env.owner.pubkey();
    let guard = env.guard.pubkey();
    let pct = |b: &Pubkey, after: i64, bps: u64| {
        rule(b, Rail::Solana, after, None, AmountMode::Percent, bps)
    };
    let cases: Vec<(&str, Vec<RuleInput>)> = vec![
        ("empty", vec![]),
        (
            "unsorted",
            vec![pct(&a, 20 * DAY, 5_000), pct(&a, 10 * DAY, 5_000)],
        ),
        ("percent over 100%", vec![pct(&a, 10 * DAY, 10_001)]),
        (
            "zero fixed",
            vec![rule(&a, Rail::Solana, 10 * DAY, None, AmountMode::Fixed, 0)],
        ),
        ("before check-in is due", vec![pct(&a, INTERVAL, 10_000)]),
        ("owner as beneficiary", vec![pct(&owner, 10 * DAY, 10_000)]),
        ("guard as beneficiary", vec![pct(&guard, 10 * DAY, 10_000)]),
        (
            "too many",
            (0..9).map(|i| pct(&a, 10 * DAY + i, 1)).collect(),
        ),
    ];
    for (name, rules) in cases {
        assert!(
            env.create_vault(rules).is_err(),
            "{name} should be rejected"
        );
    }
    let eight = (0..8)
        .map(|i| rule(&a, Rail::Zcash, 10 * DAY + i, None, AmountMode::Fixed, 1))
        .collect();
    env.create_vault(eight).unwrap();
}

#[test]
fn tiered_sol_rules_pay_in_order_with_per_rail_fees() {
    let (a, b, c) = (Keypair::new(), Keypair::new(), Keypair::new());
    let mut env = ready(vec![
        rule(
            &a.pubkey(),
            Rail::Solana,
            10 * DAY,
            None,
            AmountMode::Fixed,
            2 * SOL,
        ),
        rule(
            &b.pubkey(),
            Rail::Zcash,
            20 * DAY,
            None,
            AmountMode::Percent,
            5_000,
        ),
        rule(
            &c.pubkey(),
            Rail::Cloak,
            30 * DAY,
            None,
            AmountMode::Percent,
            10_000,
        ),
    ]);
    env.deposit_sol(10 * SOL);

    env.advance(10 * DAY);
    assert!(
        env.execute_sol(0, &a.pubkey()).is_err(),
        "due time is exclusive"
    );
    env.advance(1);
    assert!(env.execute_sol(1, &b.pubkey()).is_err(), "rule 1 not due");
    assert!(
        env.execute_sol(0, &b.pubkey()).is_err(),
        "wrong beneficiary"
    );
    let rogue_treasury = Keypair::new().pubkey();
    assert!(env
        .execute_sol_with(0, &a.pubkey(), &rogue_treasury)
        .is_err());

    let t0 = env.lamports(&env.treasury.pubkey());
    env.execute_sol(0, &a.pubkey()).unwrap();
    assert_eq!(
        env.lamports(&a.pubkey()),
        2 * SOL - fee(2 * SOL, FEE_PUBLIC)
    );
    assert_eq!(
        env.lamports(&env.treasury.pubkey()) - t0,
        fee(2 * SOL, FEE_PUBLIC)
    );
    assert!(
        env.execute_sol(0, &a.pubkey()).is_err(),
        "no double execution"
    );

    env.advance(10 * DAY);
    let gross = env.withdrawable() / 2;
    env.execute_sol(1, &b.pubkey()).unwrap();
    assert_eq!(env.lamports(&b.pubkey()), gross - fee(gross, FEE_PRIVATE));

    env.advance(10 * DAY);
    let rest = env.withdrawable();
    env.execute_sol(2, &c.pubkey()).unwrap();
    assert_eq!(env.lamports(&c.pubkey()), rest - fee(rest, FEE_PRIVATE));
    assert_eq!(env.withdrawable(), 0);
    let v = env.vault();
    assert!(v.rules.iter().all(|r| r.executed_at > 0));
    assert_eq!(v.rules[2].paid, rest - fee(rest, FEE_PRIVATE));
}

#[test]
fn per_asset_order_is_enforced() {
    let (a, b) = (Keypair::new(), Keypair::new());
    let mut env = ready(vec![
        rule(
            &a.pubkey(),
            Rail::Solana,
            10 * DAY,
            None,
            AmountMode::Percent,
            5_000,
        ),
        rule(
            &b.pubkey(),
            Rail::Solana,
            10 * DAY,
            None,
            AmountMode::Percent,
            10_000,
        ),
    ]);
    env.deposit_sol(4 * SOL);
    env.advance(10 * DAY + 1);
    assert!(env.execute_sol(1, &b.pubkey()).is_err(), "rule 0 first");
    env.execute_sol(0, &a.pubkey()).unwrap();
    env.execute_sol(1, &b.pubkey()).unwrap();
}

#[test]
fn pulse_resets_pending_rules_after_partial_release() {
    let (a, b) = (Keypair::new(), Keypair::new());
    let mut env = ready(vec![
        rule(
            &a.pubkey(),
            Rail::Solana,
            10 * DAY,
            None,
            AmountMode::Fixed,
            SOL,
        ),
        rule(
            &b.pubkey(),
            Rail::Solana,
            20 * DAY,
            None,
            AmountMode::Percent,
            10_000,
        ),
    ]);
    env.deposit_sol(5 * SOL);
    env.advance(10 * DAY + 1);
    env.execute_sol(0, &a.pubkey()).unwrap();

    // After a release only the owner's wallet can stop the later tiers.
    let guard = env.guard.insecure_clone();
    let err = env.pulse(&guard).unwrap_err();
    assert!(err.contains("OwnerConfirmationRequired"), "{err}");
    // The owner was only on a long trip: one wallet check-in stops tier 2.
    let owner = env.owner.insecure_clone();
    env.pulse(&owner).unwrap();
    env.pulse(&guard).unwrap();
    env.advance(15 * DAY);
    assert!(env.execute_sol(1, &b.pubkey()).is_err());
    env.withdraw_sol(SOL).unwrap();
}

#[test]
fn undeliverable_dust_stays_pending_then_can_be_skipped() {
    let (a, b) = (Keypair::new(), Keypair::new());
    let mut env = ready(vec![
        rule(
            &a.pubkey(),
            Rail::Solana,
            10 * DAY,
            None,
            AmountMode::Fixed,
            1_000,
        ),
        rule(
            &b.pubkey(),
            Rail::Solana,
            10 * DAY,
            None,
            AmountMode::Percent,
            10_000,
        ),
    ]);
    env.deposit_sol(SOL);
    env.advance(10 * DAY + 1);
    let err = env.execute_sol(0, &a.pubkey()).unwrap_err();
    assert!(err.contains("BeneficiaryCannotReceive"), "{err}");
    assert_eq!(env.vault().rules[0].executed_at, 0, "not consumed");
    assert!(env.execute_sol(1, &b.pubkey()).is_err(), "still ordered");

    assert!(env.skip(0).unwrap_err().contains("SkipTooEarly"));
    env.advance(30 * DAY);
    env.skip(0).unwrap();
    let v = env.vault();
    assert!(v.rules[0].skipped_at > 0 && v.rules[0].executed_at == 0);
    assert_eq!(v.rules[0].reserved, 1_000, "its share stays set aside");
    env.execute_sol(1, &b.pubkey()).unwrap();
    assert!(env.lamports(&b.pubkey()) > SOL / 2);
}

#[test]
fn token_rules_pay_with_fee_and_independent_order() {
    let (a, b) = (Keypair::new(), Keypair::new());
    let mut env = ready(all_to(&a.pubkey()));
    let usdc = env.token_setup(1_000_000_000);
    env.update_policy(
        vec![
            rule(
                &a.pubkey(),
                Rail::Solana,
                10 * DAY,
                Some(usdc),
                AmountMode::Fixed,
                100_000_000,
            ),
            rule(
                &b.pubkey(),
                Rail::Cloak,
                10 * DAY,
                Some(usdc),
                AmountMode::Percent,
                10_000,
            ),
            rule(
                &a.pubkey(),
                Rail::Solana,
                10 * DAY,
                None,
                AmountMode::Percent,
                10_000,
            ),
        ],
        None,
    )
    .unwrap();
    env.deposit_sol(SOL);
    env.advance(10 * DAY + 1);

    // The SOL rule is not blocked by pending token rules.
    env.execute_sol(2, &a.pubkey()).unwrap();
    assert!(
        env.execute_token(1, &b.pubkey(), &usdc).is_err(),
        "rule 0 first"
    );
    assert!(
        env.execute_sol(0, &a.pubkey()).is_err(),
        "token rule via SOL instruction"
    );
    env.execute_token(0, &a.pubkey(), &usdc).unwrap();
    assert_eq!(
        env.token_balance(&ata(&a.pubkey(), &usdc)),
        100_000_000 - fee(100_000_000, FEE_PUBLIC)
    );

    // The vault has no spare SOL left, so no stipend is sent.
    env.execute_token(1, &b.pubkey(), &usdc).unwrap();
    let gross = 900_000_000;
    assert_eq!(
        env.token_balance(&ata(&b.pubkey(), &usdc)),
        gross - fee(gross, FEE_PRIVATE)
    );
    assert_eq!(
        env.token_balance(&ata(&env.treasury.pubkey(), &usdc)),
        fee(100_000_000, FEE_PUBLIC) + fee(gross, FEE_PRIVATE)
    );
    assert_eq!(env.lamports(&b.pubkey()), 0);
}

#[test]
fn private_token_rule_sends_gas_stipend() {
    let c = Keypair::new();
    let mut env = ready(all_to(&Keypair::new().pubkey()));
    let usdc = env.token_setup(50_000_000);
    env.update_policy(
        vec![rule(
            &c.pubkey(),
            Rail::Zcash,
            10 * DAY,
            Some(usdc),
            AmountMode::Percent,
            10_000,
        )],
        None,
    )
    .unwrap();
    env.deposit_sol(SOL);
    env.advance(10 * DAY + 1);
    env.execute_token(0, &c.pubkey(), &usdc).unwrap();
    assert_eq!(env.lamports(&c.pubkey()), ZCASH_STIPEND);
}

#[test]
fn duress_lockdown_freezes_funds_and_policy() {
    let b = Keypair::new();
    let mut env = ready(all_to(&b.pubkey()));
    env.deposit_sol(5 * SOL);
    env.withdraw_sol(SOL).unwrap();

    let guard = env.guard.insecure_clone();
    env.lockdown(&guard).unwrap();
    assert!(env.withdraw_sol(SOL).is_err());
    let attacker = Keypair::new().pubkey();
    assert!(
        env.update_policy(all_to(&attacker), None).is_err(),
        "coercer cannot redirect"
    );

    let new_guard = Keypair::new();
    let ix = env.owner_ix(deadman::instruction::SetGuard {
        new_guard: new_guard.pubkey(),
    });
    let owner = env.owner.insecure_clone();
    env.send(ix, &[&owner]).unwrap();
    assert!(env.lockdown(&guard).is_err(), "old guard revoked");

    env.advance(LOCK + 1);
    env.withdraw_sol(SOL).unwrap();
}

#[test]
fn lockdown_does_not_stop_inheritance() {
    let b = Keypair::new();
    let mut env = ready(all_to(&b.pubkey()));
    env.deposit_sol(2 * SOL);
    let guard = env.guard.insecure_clone();
    env.lockdown(&guard).unwrap();
    env.advance(10 * DAY + 1);
    env.execute_sol(0, &b.pubkey()).unwrap();
}

#[test]
fn guard_cannot_move_funds() {
    let b = Keypair::new();
    let mut env = ready(all_to(&b.pubkey()));
    env.deposit_sol(2 * SOL);
    let guard = env.guard.insecure_clone();
    let ix = Instruction::new_with_bytes(
        deadman::id(),
        &deadman::instruction::WithdrawSol { amount: SOL }.data(),
        deadman::accounts::WithdrawSol {
            owner: guard.pubkey(),
            vault: env.vault_addr(),
        }
        .to_account_metas(None),
    );
    assert!(env.send(ix, &[&guard]).is_err());
}

#[test]
fn guardian_lockdown_is_rate_limited_and_removable() {
    let b = Keypair::new();
    let guardian = Keypair::new();
    let mut env = ready(all_to(&b.pubkey()));
    env.svm.airdrop(&guardian.pubkey(), SOL).unwrap();
    env.update_policy(all_to(&b.pubkey()), Some(guardian.pubkey()))
        .unwrap();

    env.lockdown(&guardian).unwrap();
    env.advance(LOCK + 1);
    assert!(env.lockdown(&guardian).is_err(), "cooldown after expiry");

    // The owner uses the unlocked window to remove the guardian.
    env.update_policy(all_to(&b.pubkey()), None).unwrap();
    env.advance(LOCK);
    assert!(env.lockdown(&guardian).is_err(), "no longer guardian");
}

#[test]
fn guardian_cosigns_early_unlock() {
    let b = Keypair::new();
    let guardian = Keypair::new();
    let mut env = ready(all_to(&b.pubkey()));
    env.svm.airdrop(&guardian.pubkey(), SOL).unwrap();
    env.update_policy(all_to(&b.pubkey()), Some(guardian.pubkey()))
        .unwrap();
    env.deposit_sol(SOL);
    let guard = env.guard.insecure_clone();
    env.lockdown(&guard).unwrap();

    let ix = Instruction::new_with_bytes(
        deadman::id(),
        &deadman::instruction::Unlock {}.data(),
        deadman::accounts::Unlock {
            owner: env.owner.pubkey(),
            guardian: guardian.pubkey(),
            vault: env.vault_addr(),
        }
        .to_account_metas(None),
    );
    let owner = env.owner.insecure_clone();
    env.send(ix, &[&owner, &guardian]).unwrap();
    env.withdraw_sol(SOL / 2).unwrap();
}

#[test]
fn withdraw_token_owner_only_and_frozen_by_lockdown() {
    let b = Keypair::new();
    let mut env = ready(all_to(&b.pubkey()));
    let usdc = env.token_setup(500);
    env.withdraw_token(&usdc, 200).unwrap();
    assert_eq!(env.token_balance(&ata(&env.owner.pubkey(), &usdc)), 200);
    assert!(env.withdraw_token(&usdc, 301).is_err());
    let guard = env.guard.insecure_clone();
    env.lockdown(&guard).unwrap();
    assert!(env.withdraw_token(&usdc, 100).is_err());
}

#[test]
fn close_vault_blocked_while_locked() {
    let b = Keypair::new();
    let mut env = ready(all_to(&b.pubkey()));
    let guard = env.guard.insecure_clone();
    env.lockdown(&guard).unwrap();
    let ix = Instruction::new_with_bytes(
        deadman::id(),
        &deadman::instruction::CloseVault {}.data(),
        deadman::accounts::CloseVault {
            owner: env.owner.pubkey(),
            vault: env.vault_addr(),
            rent_payer: env.owner.pubkey(),
        }
        .to_account_metas(None),
    );
    let owner = env.owner.insecure_clone();
    assert!(env.send(ix.clone(), &[&owner]).is_err());
    env.advance(LOCK + 1);
    env.send(ix, &[&owner]).unwrap();
    assert_eq!(env.lamports(&env.vault_addr()), 0);
}

#[test]
fn compute_unit_profile() {
    let (a, b) = (Keypair::new(), Keypair::new());
    let mut env = Env::new();
    env.init_config();
    let rules: Vec<RuleInput> = (0..8)
        .map(|i| {
            rule(
                &a.pubkey(),
                Rail::Solana,
                10 * DAY + i,
                None,
                AmountMode::Percent,
                1_000,
            )
        })
        .collect();
    let create = env.create_vault(rules.clone()).unwrap();
    env.deposit_sol(10 * SOL);
    let guard = env.guard.insecure_clone();
    let pulse = env.pulse(&guard).unwrap();
    let update = env.update_policy(rules, Some(b.pubkey())).unwrap();
    let lock = env.lockdown(&guard).unwrap();
    env.advance(10 * DAY + 10);
    let exec = env.execute_sol(0, &a.pubkey()).unwrap();
    println!(
        "CU create_vault(8 rules)={create} pulse={pulse} update_policy(8)={update} \
         lockdown={lock} execute_sol_rule={exec}"
    );
    assert!(exec < 30_000);
}

#[test]
fn pulse_is_closed_once_every_tier_released() {
    let (a, b) = (Keypair::new(), Keypair::new());
    let mut env = ready(vec![
        rule(
            &a.pubkey(),
            Rail::Solana,
            10 * DAY,
            None,
            AmountMode::Fixed,
            SOL,
        ),
        rule(
            &b.pubkey(),
            Rail::Solana,
            20 * DAY,
            None,
            AmountMode::Percent,
            10_000,
        ),
    ]);
    env.deposit_sol(5 * SOL);
    let guard = env.guard.insecure_clone();
    let owner = env.owner.insecure_clone();

    env.advance(10 * DAY + 1);
    env.execute_sol(0, &a.pubkey()).unwrap();
    // Between tiers a wallet check-in still stops the rest.
    env.pulse(&owner).unwrap();

    env.advance(20 * DAY + 1);
    env.execute_sol(1, &b.pubkey()).unwrap();
    assert!(env.pulse(&guard).is_err(), "guard pulse after full release");
    let err = env.pulse(&owner).unwrap_err();
    assert!(err.contains("PlanCompleted"), "{err}");
}

#[test]
fn one_owner_runs_independent_plans() {
    let (a, b) = (Keypair::new(), Keypair::new());
    let mut env = ready(all_to(&a.pubkey()));
    env.deposit_sol(2 * SOL);

    env.plan = 7;
    env.create_vault(vec![rule(
        &b.pubkey(),
        Rail::Zcash,
        30 * DAY,
        None,
        AmountMode::Percent,
        10_000,
    )])
    .unwrap();
    env.deposit_sol(3 * SOL);
    assert!(env.create_vault(all_to(&b.pubkey())).is_err(), "id taken");
    let v = env.vault();
    assert_eq!((v.plan_id, v.label.as_str()), (7, "Plan 7"));

    // Plan 0 releases on its own schedule; plan 7 is untouched.
    env.advance(10 * DAY + 1);
    env.plan = 0;
    env.execute_sol(0, &a.pubkey()).unwrap();
    env.plan = 7;
    assert!(env.execute_sol(0, &b.pubkey()).is_err(), "plan 7 not due");
    assert!(env.withdrawable() >= 3 * SOL);
}

#[test]
fn label_length_is_capped() {
    let a = Keypair::new();
    let mut env = Env::new();
    env.init_config();
    let ix = Instruction::new_with_bytes(
        deadman::id(),
        &deadman::instruction::CreateVault {
            plan_id: 0,
            label: "x".repeat(33),
            guard: env.guard.pubkey(),
            interval_secs: INTERVAL,
            lock_secs: LOCK,
            skip_grace_secs: GRACE,
            rules: all_to(&a.pubkey()),
        }
        .data(),
        deadman::accounts::CreateVault {
            owner: env.owner.pubkey(),
            payer: env.owner.pubkey(),
            vault: env.vault_addr(),
            system_program: system_program::ID,
        }
        .to_account_metas(None),
    );
    let owner = env.owner.insecure_clone();
    assert!(env.send(ix, &[&owner]).is_err());
}

#[test]
fn sponsor_pays_vault_rent() {
    let a = Keypair::new();
    let sponsor = Keypair::new();
    let mut env = Env::new();
    env.init_config();
    env.svm.airdrop(&sponsor.pubkey(), SOL).unwrap();
    let owner_before = env.lamports(&env.owner.pubkey());
    let ix = Instruction::new_with_bytes(
        deadman::id(),
        &deadman::instruction::CreateVault {
            plan_id: 0,
            label: "Sponsored".to_string(),
            guard: env.guard.pubkey(),
            interval_secs: INTERVAL,
            lock_secs: LOCK,
            skip_grace_secs: GRACE,
            rules: all_to(&a.pubkey()),
        }
        .data(),
        deadman::accounts::CreateVault {
            owner: env.owner.pubkey(),
            payer: sponsor.pubkey(),
            vault: env.vault_addr(),
            system_program: system_program::ID,
        }
        .to_account_metas(None),
    );
    let owner = env.owner.insecure_clone();
    // The sponsor is the fee payer and funds rent; the owner only signs.
    env.send(ix, &[&sponsor, &owner]).unwrap();
    assert_eq!(env.lamports(&env.owner.pubkey()), owner_before);
    assert_eq!(env.vault().owner, env.owner.pubkey());
}

// Regression tests for docs/security-audit-2026-10-03.md.

fn usdc_rules(env: &mut Env, a: &Keypair, b: &Keypair) -> Pubkey {
    let usdc = env.token_setup(1_000_000);
    env.update_policy(
        vec![
            rule(
                &a.pubkey(),
                Rail::Solana,
                10 * DAY,
                Some(usdc),
                AmountMode::Percent,
                1_000,
            ),
            rule(
                &b.pubkey(),
                Rail::Solana,
                10 * DAY,
                Some(usdc),
                AmountMode::Percent,
                10_000,
            ),
        ],
        None,
    )
    .unwrap();
    usdc
}

#[test]
fn h1_reassigned_ata_is_bypassed_with_another_token_account() {
    let (a, b) = (Keypair::new(), Keypair::new());
    let mut env = ready(all_to(&b.pubkey()));
    let usdc = usdc_rules(&mut env, &a, &b);
    env.advance(10 * DAY + 1);
    // Alice's own ATA cannot be used (wrong owner check fails) ...
    let stranger = Keypair::new().pubkey();
    let admin = env.admin.insecure_clone();
    let foreign = CreateAssociatedTokenAccountIdempotent::new(&mut env.svm, &admin, &usdc)
        .owner(&stranger)
        .send()
        .unwrap();
    assert!(env
        .execute_token_to(0, &a.pubkey(), &usdc, &foreign)
        .is_err());
    // ... but any token account Alice owns works, not only her ATA.
    env.execute_token(0, &a.pubkey(), &usdc).unwrap();
    env.execute_token(1, &b.pubkey(), &usdc).unwrap();
    assert!(env.token_balance(&ata(&b.pubkey(), &usdc)) > 0);
}

#[test]
fn h1_unpayable_tier_is_skipped_after_grace_and_later_tiers_run() {
    let (a, b) = (Keypair::new(), Keypair::new());
    let mut env = ready(all_to(&b.pubkey()));
    let usdc = usdc_rules(&mut env, &a, &b);
    env.advance(10 * DAY + 1);
    // Alice never provides a usable account: tier 1 blocks tier 2 ...
    assert!(env
        .execute_token(1, &b.pubkey(), &usdc)
        .unwrap_err()
        .contains("RuleOutOfOrder"));
    // ... only until the grace period ends.
    assert!(env
        .skip_token(0, &usdc)
        .unwrap_err()
        .contains("SkipTooEarly"));
    env.advance(30 * DAY);
    env.skip_token(0, &usdc).unwrap();
    assert!(env.skip_token(0, &usdc).is_err(), "skip once");
    // Bob gets 100% of what is not reserved for Alice.
    env.execute_token(1, &b.pubkey(), &usdc).unwrap();
    let bob = 900_000;
    assert_eq!(
        env.token_balance(&ata(&b.pubkey(), &usdc)),
        bob - fee(bob, FEE_PUBLIC)
    );
    // Alice can still claim her reserved 10% later.
    env.execute_token(0, &a.pubkey(), &usdc).unwrap();
    let alice = 100_000;
    assert_eq!(
        env.token_balance(&ata(&a.pubkey(), &usdc)),
        alice - fee(alice, FEE_PUBLIC)
    );
}

#[test]
fn m1_guard_alone_cannot_keep_a_plan_alive_past_a_year() {
    let b = Keypair::new();
    let mut env = ready(all_to(&b.pubkey()));
    env.deposit_sol(SOL);
    let guard = env.guard.insecure_clone();
    for _ in 0..52 {
        env.advance(7 * DAY);
        env.pulse(&guard).unwrap();
    }
    env.advance(2 * DAY);
    let err = env.pulse(&guard).unwrap_err();
    assert!(err.contains("OwnerConfirmationRequired"), "{err}");
    env.advance(10 * DAY);
    env.execute_sol(0, &b.pubkey()).unwrap();
}

#[test]
fn m1_owner_wallet_action_restarts_the_guard_window() {
    let b = Keypair::new();
    let mut env = ready(all_to(&b.pubkey()));
    env.deposit_sol(SOL);
    let (guard, owner) = (env.guard.insecure_clone(), env.owner.insecure_clone());
    env.advance(360 * DAY);
    env.pulse(&owner).unwrap();
    env.advance(300 * DAY);
    env.pulse(&guard).unwrap();
}

#[test]
fn l1_empty_payout_does_not_consume_the_tier() {
    let (a, b) = (Keypair::new(), Keypair::new());
    let mut env = ready(all_to(&b.pubkey()));
    let usdc = env.token_setup(0);
    env.update_policy(
        vec![rule(
            &a.pubkey(),
            Rail::Solana,
            10 * DAY,
            Some(usdc),
            AmountMode::Percent,
            10_000,
        )],
        None,
    )
    .unwrap();
    env.advance(10 * DAY + 1);
    let err = env.execute_token(0, &a.pubkey(), &usdc).unwrap_err();
    assert!(err.contains("NothingToPay"), "{err}");
    assert_eq!(env.vault().rules[0].executed_at, 0);
}

#[test]
fn l2_editing_after_a_release_keeps_history_and_never_pays_twice() {
    let (a, b) = (Keypair::new(), Keypair::new());
    let mut env = ready(vec![
        rule(
            &a.pubkey(),
            Rail::Solana,
            10 * DAY,
            None,
            AmountMode::Fixed,
            SOL,
        ),
        rule(
            &b.pubkey(),
            Rail::Solana,
            20 * DAY,
            None,
            AmountMode::Fixed,
            SOL,
        ),
    ]);
    env.deposit_sol(5 * SOL);
    env.advance(10 * DAY + 1);
    env.execute_sol(0, &a.pubkey()).unwrap();
    let paid_a = env.lamports(&a.pubkey());

    // Owner returns and saves the plan again (only pending tiers are sent).
    env.update_policy(
        vec![rule(
            &b.pubkey(),
            Rail::Solana,
            20 * DAY,
            None,
            AmountMode::Fixed,
            SOL,
        )],
        None,
    )
    .unwrap();
    let v = env.vault();
    assert_eq!(v.rules.len(), 2);
    assert!(v.rules[0].executed_at > 0, "history kept");
    env.advance(30 * DAY);
    assert!(env
        .execute_sol(0, &a.pubkey())
        .unwrap_err()
        .contains("RuleAlreadyExecuted"));
    env.execute_sol(1, &b.pubkey()).unwrap();
    assert_eq!(env.lamports(&a.pubkey()), paid_a, "A paid once");
}

#[test]
fn completed_plan_can_be_rearmed_as_a_fresh_plan() {
    let b = Keypair::new();
    let mut env = ready(all_to(&b.pubkey()));
    env.deposit_sol(SOL);
    env.advance(10 * DAY + 1);
    env.execute_sol(0, &b.pubkey()).unwrap();
    env.update_policy(all_to(&b.pubkey()), None).unwrap();
    let v = env.vault();
    assert_eq!((v.rules.len(), v.rules[0].executed_at), (1, 0));
}

#[test]
fn vault_cannot_be_its_own_beneficiary() {
    let mut env = Env::new();
    env.init_config();
    let vault = env.vault_addr();
    assert!(env.create_vault(all_to(&vault)).is_err());
}

#[test]
fn skip_grace_is_owner_configured_and_bounded() {
    let (a, b) = (Keypair::new(), Keypair::new());
    let tiers = || {
        vec![
            rule(
                &a.pubkey(),
                Rail::Solana,
                10 * DAY,
                None,
                AmountMode::Fixed,
                1_000,
            ),
            rule(
                &b.pubkey(),
                Rail::Solana,
                10 * DAY,
                None,
                AmountMode::Percent,
                10_000,
            ),
        ]
    };
    let mut env = ready(tiers());
    let policy = |env: &Env, grace: i64| {
        env.owner_ix(deadman::instruction::UpdatePolicy {
            label: String::new(),
            interval_secs: INTERVAL,
            lock_secs: LOCK,
            skip_grace_secs: grace,
            rules: tiers(),
            guardian: None,
        })
    };
    let owner = env.owner.insecure_clone();
    for bad in [59, 367 * DAY] {
        let ix = policy(&env, bad);
        assert!(env.send(ix, &[&owner]).is_err(), "grace {bad} out of range");
    }
    let ix = policy(&env, 2 * DAY);
    env.send(ix, &[&owner]).unwrap();
    assert_eq!(env.vault().skip_grace_secs, 2 * DAY);

    env.deposit_sol(SOL);
    env.advance(10 * DAY + 1);
    assert!(
        env.execute_sol(0, &a.pubkey()).is_err(),
        "dust to fresh account"
    );
    env.advance(DAY);
    assert!(env.skip(0).unwrap_err().contains("SkipTooEarly"));
    env.advance(DAY);
    env.skip(0).unwrap();
    env.execute_sol(1, &b.pubkey()).unwrap();
}

// Regression tests for the re-audit of the fixes (NEW-1..NEW-3).

#[test]
fn new1_skipping_a_payable_lone_tier_cannot_strand_it() {
    let b = Keypair::new();
    let mut env = ready(all_to(&b.pubkey()));
    env.deposit_sol(5 * SOL);
    env.advance(10 * DAY + 1 + GRACE);
    // A stranger skips the only tier although it could pay ...
    let reserved = env.withdrawable();
    env.skip(0).unwrap();
    assert_eq!(env.vault().rules[0].reserved, reserved);
    // ... and the beneficiary still claims all of it afterwards.
    env.advance(400 * DAY);
    env.execute_sol(0, &b.pubkey()).unwrap();
    assert_eq!(
        env.lamports(&b.pubkey()),
        reserved - fee(reserved, FEE_PUBLIC)
    );
}

#[test]
fn new2_later_heir_cannot_take_a_skipped_share() {
    let (a, b) = (Keypair::new(), Keypair::new());
    let mut env = ready(vec![
        rule(
            &a.pubkey(),
            Rail::Solana,
            10 * DAY,
            None,
            AmountMode::Percent,
            5_000,
        ),
        rule(
            &b.pubkey(),
            Rail::Solana,
            10 * DAY,
            None,
            AmountMode::Percent,
            10_000,
        ),
    ]);
    env.deposit_sol(10 * SOL);
    env.advance(10 * DAY + 1 + GRACE);
    let total = env.withdrawable();
    env.skip(0).unwrap();
    env.execute_sol(1, &b.pubkey()).unwrap();
    let bob = total - total / 2;
    assert_eq!(env.lamports(&b.pubkey()), bob - fee(bob, FEE_PUBLIC));
    env.execute_sol(0, &a.pubkey()).unwrap();
    let alice = total / 2;
    assert_eq!(env.lamports(&a.pubkey()), alice - fee(alice, FEE_PUBLIC));
}

#[test]
fn new3_payout_to_a_non_ata_account_needs_the_beneficiary_signature() {
    let (a, b) = (Keypair::new(), Keypair::new());
    let mut env = ready(all_to(&b.pubkey()));
    let usdc = usdc_rules(&mut env, &a, &b);
    env.advance(10 * DAY + 1);
    // An executor creates a plain token account owned by Alice and tries to
    // route her payout there.
    let admin = env.admin.insecure_clone();
    let other = litesvm_token::CreateAccount::new(&mut env.svm, &admin, &usdc)
        .owner(&a.pubkey())
        .send()
        .unwrap();
    let err = env
        .execute_token_to(0, &a.pubkey(), &usdc, &other)
        .unwrap_err();
    assert!(err.contains("Unauthorized"), "{err}");

    // Alice herself may choose that account.
    env.svm.airdrop(&a.pubkey(), SOL).unwrap();
    let vault = env.vault_addr();
    let ix = Instruction::new_with_bytes(
        deadman::id(),
        &deadman::instruction::ExecuteTokenRule { index: 0 }.data(),
        deadman::accounts::ExecuteTokenRule {
            executor: a.pubkey(),
            vault,
            config: config_pda(),
            mint: usdc,
            vault_token: ata(&vault, &usdc),
            beneficiary: a.pubkey(),
            beneficiary_token: other,
            treasury_token: ata(&env.treasury.pubkey(), &usdc),
            token_program: TOKEN_ID,
            subscription: env.sub_addr(),
        }
        .to_account_metas(None),
    );
    env.send(ix, &[&a]).unwrap();
    assert!(env.token_balance(&other) > 0);
}

#[test]
fn skipping_a_token_tier_needs_the_real_vault_account() {
    let (a, b) = (Keypair::new(), Keypair::new());
    let mut env = ready(all_to(&b.pubkey()));
    let usdc = usdc_rules(&mut env, &a, &b);
    env.advance(10 * DAY + 1 + GRACE);
    // An empty decoy account owned by the vault would reserve 0.
    let admin = env.admin.insecure_clone();
    let vault = env.vault_addr();
    let decoy = litesvm_token::CreateAccount::new(&mut env.svm, &admin, &usdc)
        .owner(&vault)
        .send()
        .unwrap();
    assert!(env.skip_with(0, Some(decoy)).is_err());
    assert!(env.skip(0).is_err(), "token tier needs its vault account");
    env.skip_token(0, &usdc).unwrap();
    assert_eq!(env.vault().rules[0].reserved, 100_000);
}

#[test]
fn guard_cannot_check_in_after_a_skip_until_the_owner_confirms() {
    let b = Keypair::new();
    let mut env = ready(all_to(&b.pubkey()));
    env.advance(10 * DAY + 1 + GRACE);
    env.skip(0).unwrap();
    let (guard, owner) = (env.guard.insecure_clone(), env.owner.insecure_clone());
    assert!(env
        .pulse(&guard)
        .unwrap_err()
        .contains("OwnerConfirmationRequired"));
    env.pulse(&owner).unwrap();
    env.pulse(&guard).unwrap();
}

// Rent refunds and vesting plans.

impl Env {
    fn close_ix(&self, rent_payer: &Pubkey) -> Instruction {
        Instruction::new_with_bytes(
            deadman::id(),
            &deadman::instruction::CloseVault {}.data(),
            deadman::accounts::CloseVault {
                owner: self.owner.pubkey(),
                vault: self.vault_addr(),
                rent_payer: *rent_payer,
            }
            .to_account_metas(None),
        )
    }

    fn create_vesting(
        &mut self,
        start_at: i64,
        revocable: bool,
        schedules: Vec<VestingInput>,
    ) -> Result<u64, String> {
        self.create_vesting_stepped(start_at, revocable, schedules, 0)
    }

    fn create_vesting_stepped(
        &mut self,
        start_at: i64,
        revocable: bool,
        schedules: Vec<VestingInput>,
        period_secs: i64,
    ) -> Result<u64, String> {
        let ix = Instruction::new_with_bytes(
            deadman::id(),
            &deadman::instruction::CreateVesting {
                plan_id: self.plan,
                label: "Vesting".to_string(),
                guard: self.guard.pubkey(),
                lock_secs: LOCK,
                start_at,
                revocable,
                schedules,
                period_secs,
            }
            .data(),
            deadman::accounts::CreateVault {
                owner: self.owner.pubkey(),
                payer: self.owner.pubkey(),
                vault: self.vault_addr(),
                system_program: system_program::ID,
            }
            .to_account_metas(None),
        );
        let owner = self.owner.insecure_clone();
        self.send(ix, &[&owner])
    }

    fn release(&mut self, index: u8, beneficiary: &Pubkey) -> Result<u64, String> {
        let treasury = self.treasury.pubkey();
        let ix = Instruction::new_with_bytes(
            deadman::id(),
            &deadman::instruction::ReleaseVestedSol { index }.data(),
            deadman::accounts::ExecuteSolRule {
                executor: self.keeper.pubkey(),
                vault: self.vault_addr(),
                config: config_pda(),
                beneficiary: *beneficiary,
                treasury,
                subscription: self.sub_addr(),
            }
            .to_account_metas(None),
        );
        let keeper = self.keeper.insecure_clone();
        self.send(ix, &[&keeper])
    }

    fn release_token(
        &mut self,
        index: u8,
        beneficiary: &Pubkey,
        mint: &Pubkey,
    ) -> Result<u64, String> {
        let admin = self.admin.insecure_clone();
        CreateAssociatedTokenAccountIdempotent::new(&mut self.svm, &admin, mint)
            .owner(beneficiary)
            .send()
            .map_err(|e| format!("{:?}", e.err))?;
        let vault = self.vault_addr();
        let ix = Instruction::new_with_bytes(
            deadman::id(),
            &deadman::instruction::ReleaseVestedToken { index }.data(),
            deadman::accounts::ExecuteTokenRule {
                executor: self.keeper.pubkey(),
                vault,
                config: config_pda(),
                mint: *mint,
                vault_token: ata(&vault, mint),
                beneficiary: *beneficiary,
                beneficiary_token: ata(beneficiary, mint),
                treasury_token: ata(&self.treasury.pubkey(), mint),
                token_program: TOKEN_ID,
                subscription: self.sub_addr(),
            }
            .to_account_metas(None),
        );
        let keeper = self.keeper.insecure_clone();
        self.send(ix, &[&keeper])
    }

    fn revoke(&mut self) -> Result<u64, String> {
        let ix = self.owner_ix(deadman::instruction::RevokeVesting {});
        let owner = self.owner.insecure_clone();
        self.send(ix, &[&owner])
    }
}

fn schedule(
    b: &Pubkey,
    mint: Option<Pubkey>,
    total: u64,
    cliff: i64,
    duration: i64,
) -> VestingInput {
    VestingInput {
        beneficiary: *b,
        rail: Rail::Solana,
        mint,
        total,
        cliff_secs: cliff,
        duration_secs: duration,
    }
}

fn vesting_env(revocable: bool, b: &Keypair) -> Env {
    let mut env = Env::new();
    env.init_config();
    let now = env.now();
    env.create_vesting(
        now,
        revocable,
        vec![schedule(&b.pubkey(), None, 10 * SOL, 30 * DAY, 100 * DAY)],
    )
    .unwrap();
    env.deposit_sol(12 * SOL);
    env
}

#[test]
fn close_returns_rent_to_the_sponsor_and_the_rest_to_the_owner() {
    let a = Keypair::new();
    let sponsor = Keypair::new();
    let mut env = Env::new();
    env.init_config();
    env.svm.airdrop(&sponsor.pubkey(), SOL).unwrap();
    let ix = Instruction::new_with_bytes(
        deadman::id(),
        &deadman::instruction::CreateVault {
            plan_id: 0,
            label: String::new(),
            guard: env.guard.pubkey(),
            interval_secs: INTERVAL,
            lock_secs: LOCK,
            skip_grace_secs: GRACE,
            rules: all_to(&a.pubkey()),
        }
        .data(),
        deadman::accounts::CreateVault {
            owner: env.owner.pubkey(),
            payer: sponsor.pubkey(),
            vault: env.vault_addr(),
            system_program: system_program::ID,
        }
        .to_account_metas(None),
    );
    let owner = env.owner.insecure_clone();
    env.send(ix, &[&sponsor, &owner]).unwrap();
    env.deposit_sol(2 * SOL);
    let rent = env.lamports(&env.vault_addr()) - 2 * SOL;
    let (s0, o0) = (
        env.lamports(&sponsor.pubkey()),
        env.lamports(&env.owner.pubkey()),
    );

    // The owner cannot send the rent to himself instead.
    let ix = env.close_ix(&env.owner.pubkey());
    assert!(env.send(ix, &[&owner]).is_err());
    let ix = env.close_ix(&sponsor.pubkey());
    env.send(ix, &[&owner]).unwrap();
    assert_eq!(env.lamports(&sponsor.pubkey()) - s0, rent);
    // Two owner-signed transactions: the refused close and the real one.
    assert_eq!(env.lamports(&env.owner.pubkey()) + 10_000 - o0, 2 * SOL);
}

#[test]
fn vesting_releases_linearly_after_the_cliff() {
    let b = Keypair::new();
    let mut env = vesting_env(false, &b);
    env.advance(29 * DAY);
    assert!(env
        .release(0, &b.pubkey())
        .unwrap_err()
        .contains("NothingToPay"));
    env.advance(21 * DAY); // day 50: half vested
    env.release(0, &b.pubkey()).unwrap();
    let half = 5 * SOL;
    assert_eq!(env.lamports(&b.pubkey()), half - fee(half, FEE_PUBLIC));
    assert!(env
        .release(0, &b.pubkey())
        .unwrap_err()
        .contains("NothingToPay"));
    env.advance(60 * DAY);
    env.release(0, &b.pubkey()).unwrap();
    assert_eq!(
        env.lamports(&b.pubkey()),
        10 * SOL - fee(half, FEE_PUBLIC) * 2
    );
    let v = env.vault();
    assert_eq!(v.rules[0].released, 10 * SOL);
    assert!(v.rules[0].executed_at > 0);
    assert!(env.release(0, &b.pubkey()).is_err());
}

#[test]
fn vesting_funds_are_committed_but_surplus_is_withdrawable() {
    let b = Keypair::new();
    let mut env = vesting_env(false, &b);
    assert!(env
        .withdraw_sol(3 * SOL)
        .unwrap_err()
        .contains("FundsCommitted"));
    env.withdraw_sol(2 * SOL).unwrap();
    assert!(env.revoke().unwrap_err().contains("NotRevocable"));
    let owner = env.owner.insecure_clone();
    let ix = env.close_ix(&env.owner.pubkey());
    assert!(env
        .send(ix, &[&owner])
        .unwrap_err()
        .contains("FundsCommitted"));
}

#[test]
fn revoking_keeps_what_vested_and_frees_the_rest() {
    let b = Keypair::new();
    let mut env = vesting_env(true, &b);
    env.advance(40 * DAY);
    env.revoke().unwrap();
    assert!(env.revoke().unwrap_err().contains("AlreadyRevoked"));
    // 40% stays owed; the owner takes back the rest.
    env.withdraw_sol(8 * SOL).unwrap();
    assert!(env.withdraw_sol(1).unwrap_err().contains("FundsCommitted"));
    env.advance(100 * DAY);
    env.release(0, &b.pubkey()).unwrap();
    let vested = 4 * SOL;
    assert_eq!(env.lamports(&b.pubkey()), vested - fee(vested, FEE_PUBLIC));
    assert!(env.vault().rules[0].executed_at > 0);
    let owner = env.owner.insecure_clone();
    let ix = env.close_ix(&env.owner.pubkey());
    env.send(ix, &[&owner]).unwrap();
}

#[test]
fn vesting_tokens_release_with_fee() {
    let b = Keypair::new();
    let mut env = Env::new();
    env.init_config();
    let usdc = env.token_setup(0);
    let now = env.now();
    env.create_vesting(
        now,
        false,
        vec![schedule(&b.pubkey(), Some(usdc), 1_000_000, 0, 10 * DAY)],
    )
    .unwrap();
    let admin = env.admin.insecure_clone();
    let vault = env.vault_addr();
    CreateAssociatedTokenAccountIdempotent::new(&mut env.svm, &admin, &usdc)
        .owner(&vault)
        .send()
        .unwrap();
    MintTo::new(&mut env.svm, &admin, &usdc, &ata(&vault, &usdc), 1_500_000)
        .send()
        .unwrap();
    env.advance(5 * DAY);
    env.release_token(0, &b.pubkey(), &usdc).unwrap();
    let half = 500_000;
    assert_eq!(
        env.token_balance(&ata(&b.pubkey(), &usdc)),
        half - fee(half, FEE_PUBLIC)
    );
    assert!(env
        .withdraw_token(&usdc, 500_001)
        .unwrap_err()
        .contains("FundsCommitted"));
    env.withdraw_token(&usdc, 500_000).unwrap();
}

#[test]
fn plan_kinds_do_not_mix() {
    let b = Keypair::new();
    let mut env = vesting_env(false, &b);
    let guard = env.guard.insecure_clone();
    assert!(env.pulse(&guard).unwrap_err().contains("WrongPlanKind"));
    env.advance(200 * DAY);
    assert!(env
        .execute_sol(0, &b.pubkey())
        .unwrap_err()
        .contains("WrongPlanKind"));
    assert!(env.skip(0).unwrap_err().contains("WrongPlanKind"));
    assert!(env
        .update_policy(all_to(&b.pubkey()), None)
        .unwrap_err()
        .contains("WrongPlanKind"));
    // Lockdown still protects a vesting plan from a coerced withdrawal.
    env.lockdown(&guard).unwrap();
    assert!(env.withdraw_sol(SOL).unwrap_err().contains("VaultLocked"));

    let mut inh = ready(all_to(&b.pubkey()));
    inh.deposit_sol(SOL);
    inh.advance(20 * DAY);
    assert!(inh
        .release(0, &b.pubkey())
        .unwrap_err()
        .contains("WrongPlanKind"));
}

#[test]
fn vesting_schedules_are_validated() {
    let b = Keypair::new();
    let mut env = Env::new();
    env.init_config();
    let now = env.now();
    let bad = [
        schedule(&b.pubkey(), None, 0, 0, DAY),
        schedule(&b.pubkey(), None, SOL, 2 * DAY, DAY),
        schedule(&b.pubkey(), None, SOL, 0, 0),
        schedule(&b.pubkey(), None, SOL, 0, 21 * 366 * DAY),
        schedule(&env.owner.pubkey(), None, SOL, 0, DAY),
    ];
    for s in bad {
        assert!(env.create_vesting(now, false, vec![s]).is_err());
    }
    assert!(env
        .create_vesting(
            now + 367 * DAY,
            false,
            vec![schedule(&b.pubkey(), None, SOL, 0, DAY)]
        )
        .is_err());
    env.create_vesting(
        now - 30 * DAY,
        false,
        vec![schedule(&b.pubkey(), None, SOL, 0, DAY)],
    )
    .unwrap();
}

// Installment vesting: value unlocks only at whole periods from the start.

/// 10 SOL over 10 days, paid out in daily installments.
fn stepped_env(revocable: bool, b: &Keypair, cliff: i64) -> Env {
    let mut env = Env::new();
    env.init_config();
    let now = env.now();
    env.create_vesting_stepped(
        now,
        revocable,
        vec![schedule(&b.pubkey(), None, 10 * SOL, cliff, 10 * DAY)],
        DAY,
    )
    .unwrap();
    env.deposit_sol(12 * SOL);
    env
}

fn net(gross: u64) -> u64 {
    gross - fee(gross, FEE_PUBLIC)
}

fn nothing_to_pay(env: &mut Env, b: &Keypair) -> bool {
    env.release(0, &b.pubkey())
        .unwrap_err()
        .contains("NothingToPay")
}

#[test]
fn installments_release_once_per_period() {
    let b = Keypair::new();
    let mut env = stepped_env(false, &b, 0);
    assert_eq!(env.vault().vest_period_secs, DAY);
    assert!(nothing_to_pay(&mut env, &b));
    env.advance(DAY - 1);
    assert!(nothing_to_pay(&mut env, &b));
    env.advance(1); // first boundary: exactly one installment
    env.release(0, &b.pubkey()).unwrap();
    assert_eq!(env.vault().rules[0].released, SOL);
    assert_eq!(env.lamports(&b.pubkey()), net(SOL));
    // Claiming again within the same installment pays nothing.
    assert!(nothing_to_pay(&mut env, &b));
    env.advance(DAY / 2);
    assert!(nothing_to_pay(&mut env, &b));
    env.advance(DAY / 2 - 1);
    assert!(nothing_to_pay(&mut env, &b));
    env.advance(1);
    env.release(0, &b.pubkey()).unwrap();
    assert_eq!(env.vault().rules[0].released, 2 * SOL);
    assert!(nothing_to_pay(&mut env, &b));
}

#[test]
fn skipped_installments_are_paid_together() {
    let b = Keypair::new();
    let mut env = stepped_env(false, &b, 0);
    env.advance(5 * DAY + DAY / 2);
    env.release(0, &b.pubkey()).unwrap();
    assert_eq!(env.vault().rules[0].released, 5 * SOL);
    assert_eq!(env.lamports(&b.pubkey()), net(5 * SOL));
    assert!(nothing_to_pay(&mut env, &b));
    env.advance(30 * DAY);
    env.release(0, &b.pubkey()).unwrap();
    let v = env.vault();
    assert_eq!(v.rules[0].released, 10 * SOL);
    assert!(v.rules[0].executed_at > 0);
    assert_eq!(env.lamports(&b.pubkey()), net(5 * SOL) * 2);
    assert!(env
        .release(0, &b.pubkey())
        .unwrap_err()
        .contains("RuleAlreadyExecuted"));
}

#[test]
fn installments_fully_vest_at_an_uneven_duration() {
    let b = Keypair::new();
    let mut env = Env::new();
    env.init_config();
    let now = env.now();
    // 7 SOL over 7 days in 2-day installments: 2, 4, 6, then 7 at day 7.
    env.create_vesting_stepped(
        now,
        false,
        vec![schedule(&b.pubkey(), None, 7 * SOL, 0, 7 * DAY)],
        2 * DAY,
    )
    .unwrap();
    env.deposit_sol(8 * SOL);
    env.advance(6 * DAY);
    env.release(0, &b.pubkey()).unwrap();
    assert_eq!(env.vault().rules[0].released, 6 * SOL);
    env.advance(DAY - 1);
    assert!(nothing_to_pay(&mut env, &b));
    env.advance(1);
    env.release(0, &b.pubkey()).unwrap();
    let v = env.vault();
    assert_eq!(v.rules[0].released, 7 * SOL);
    assert!(v.rules[0].executed_at > 0);
}

#[test]
fn installments_respect_the_cliff() {
    let b = Keypair::new();
    // Cliff at 3.5 days: nothing before it, then the 3 whole days so far.
    let mut env = stepped_env(false, &b, 3 * DAY + DAY / 2);
    env.advance(3 * DAY);
    assert!(nothing_to_pay(&mut env, &b));
    env.advance(DAY / 2 - 1);
    assert!(nothing_to_pay(&mut env, &b));
    env.advance(1);
    env.release(0, &b.pubkey()).unwrap();
    assert_eq!(env.vault().rules[0].released, 3 * SOL);
    assert!(nothing_to_pay(&mut env, &b));
    env.advance(DAY / 2);
    env.release(0, &b.pubkey()).unwrap();
    assert_eq!(env.vault().rules[0].released, 4 * SOL);
}

#[test]
fn revoking_between_installments_keeps_only_unlocked_ones() {
    let b = Keypair::new();
    let mut env = stepped_env(true, &b, 0);
    env.advance(4 * DAY + DAY / 2);
    env.revoke().unwrap();
    // 4 installments stay owed; the half-elapsed fifth goes back.
    env.withdraw_sol(8 * SOL).unwrap();
    assert!(env.withdraw_sol(1).unwrap_err().contains("FundsCommitted"));
    env.advance(100 * DAY);
    env.release(0, &b.pubkey()).unwrap();
    assert_eq!(env.lamports(&b.pubkey()), net(4 * SOL));
    let v = env.vault();
    assert_eq!(v.rules[0].released, 4 * SOL);
    assert!(v.rules[0].executed_at > 0);
    assert!(env.release(0, &b.pubkey()).is_err());
    let owner = env.owner.insecure_clone();
    let ix = env.close_ix(&env.owner.pubkey());
    env.send(ix, &[&owner]).unwrap();
}

#[test]
fn installment_tokens_release_per_period() {
    let b = Keypair::new();
    let mut env = Env::new();
    env.init_config();
    let usdc = env.token_setup(0);
    let now = env.now();
    env.create_vesting_stepped(
        now,
        false,
        vec![schedule(&b.pubkey(), Some(usdc), 1_000_000, 0, 10 * DAY)],
        5 * DAY,
    )
    .unwrap();
    let admin = env.admin.insecure_clone();
    let vault = env.vault_addr();
    CreateAssociatedTokenAccountIdempotent::new(&mut env.svm, &admin, &usdc)
        .owner(&vault)
        .send()
        .unwrap();
    MintTo::new(&mut env.svm, &admin, &usdc, &ata(&vault, &usdc), 1_000_000)
        .send()
        .unwrap();
    env.advance(5 * DAY - 1);
    assert!(env
        .release_token(0, &b.pubkey(), &usdc)
        .unwrap_err()
        .contains("NothingToPay"));
    env.advance(1);
    env.release_token(0, &b.pubkey(), &usdc).unwrap();
    assert_eq!(env.vault().rules[0].released, 500_000);
    env.advance(DAY);
    assert!(env
        .release_token(0, &b.pubkey(), &usdc)
        .unwrap_err()
        .contains("NothingToPay"));
}

#[test]
fn installment_period_is_validated() {
    let b = Keypair::new();
    let c = Keypair::new();
    let mut env = Env::new();
    env.init_config();
    let now = env.now();
    let two = || {
        vec![
            schedule(&b.pubkey(), None, SOL, 0, 10 * DAY),
            schedule(&c.pubkey(), None, SOL, 0, 5 * DAY),
        ]
    };
    for period in [-1, 30, 59, 5 * DAY + 1, 10 * DAY] {
        assert!(env
            .create_vesting_stepped(now, false, two(), period)
            .unwrap_err()
            .contains("InvalidVesting"));
    }
    env.create_vesting_stepped(now, false, two(), 5 * DAY)
        .unwrap();
    env.plan = 1;
    env.create_vesting_stepped(now, false, two(), 60).unwrap();
    assert_eq!(env.vault().vest_period_secs, 60);
    env.plan = 2;
    env.create_vesting(now, false, two()).unwrap();
    assert_eq!(env.vault().vest_period_secs, 0);
}

// Mainnet layout: per-rail stipends, stored rent, reserved space and
// recovery of accounts left in older layouts.

fn private_token_env(rail: Rail, c: &Pubkey, sol: u64) -> (Env, Pubkey) {
    let mut env = ready(all_to(&Keypair::new().pubkey()));
    let usdc = env.token_setup(50_000_000);
    env.update_policy(
        vec![rule(
            c,
            rail,
            10 * DAY,
            Some(usdc),
            AmountMode::Percent,
            10_000,
        )],
        None,
    )
    .unwrap();
    if sol > 0 {
        env.deposit_sol(sol);
    }
    env.advance(10 * DAY + 1);
    (env, usdc)
}

#[test]
fn cloak_token_payout_sends_the_larger_stipend() {
    let c = Keypair::new();
    let (mut env, usdc) = private_token_env(Rail::Cloak, &c.pubkey(), SOL);
    env.execute_token(0, &c.pubkey(), &usdc).unwrap();
    assert_eq!(env.lamports(&c.pubkey()), CLOAK_STIPEND);
}

#[test]
fn stipend_only_tops_up_a_poor_claim_key_from_spare_sol() {
    // A claim key that already holds the stipend gets nothing more.
    let c = Keypair::new();
    let (mut env, usdc) = private_token_env(Rail::Cloak, &c.pubkey(), SOL);
    env.svm.airdrop(&c.pubkey(), CLOAK_STIPEND).unwrap();
    let before = env.lamports(&env.vault_addr());
    env.execute_token(0, &c.pubkey(), &usdc).unwrap();
    assert_eq!(env.lamports(&c.pubkey()), CLOAK_STIPEND);
    assert_eq!(env.lamports(&env.vault_addr()), before);

    // A vault with less spare SOL than the stipend pays the tokens only.
    let d = Keypair::new();
    let (mut env, usdc) = private_token_env(Rail::Cloak, &d.pubkey(), CLOAK_STIPEND - 1);
    env.execute_token(0, &d.pubkey(), &usdc).unwrap();
    assert_eq!(env.lamports(&d.pubkey()), 0);
    assert_eq!(env.withdrawable(), CLOAK_STIPEND - 1);
}

#[test]
fn vesting_stipend_never_uses_sol_owed_to_other_schedules() {
    let b = Keypair::new();
    let c = Keypair::new();
    let mut env = Env::new();
    env.init_config();
    let usdc = env.token_setup(1_000_000);
    let now = env.now();
    let mut token = schedule(&c.pubkey(), Some(usdc), 1_000_000, 0, 10 * DAY);
    token.rail = Rail::Cloak;
    env.create_vesting(
        now,
        false,
        vec![schedule(&b.pubkey(), None, SOL, 0, 10 * DAY), token],
    )
    .unwrap();
    let vault = env.vault_addr();
    let admin = env.admin.insecure_clone();
    CreateAssociatedTokenAccountIdempotent::new(&mut env.svm, &admin, &usdc)
        .owner(&vault)
        .send()
        .unwrap();
    MintTo::new(&mut env.svm, &admin, &usdc, &ata(&vault, &usdc), 1_000_000)
        .send()
        .unwrap();
    // Only the SOL owed to `b` plus less than a stipend is spare.
    env.deposit_sol(SOL + CLOAK_STIPEND - 1);
    env.advance(5 * DAY);
    env.release_token(1, &c.pubkey(), &usdc).unwrap();
    assert_eq!(env.lamports(&c.pubkey()), 0);
    assert_eq!(env.withdrawable(), SOL + CLOAK_STIPEND - 1);

    env.deposit_sol(1);
    env.advance(DAY);
    env.release_token(1, &c.pubkey(), &usdc).unwrap();
    assert_eq!(env.lamports(&c.pubkey()), CLOAK_STIPEND);
    assert_eq!(env.withdrawable(), SOL);
}

fn sponsored_env(sponsor: &Keypair) -> Env {
    let mut env = Env::new();
    env.init_config();
    env.svm.airdrop(&sponsor.pubkey(), SOL).unwrap();
    let ix = Instruction::new_with_bytes(
        deadman::id(),
        &deadman::instruction::CreateVault {
            plan_id: 0,
            label: String::new(),
            guard: env.guard.pubkey(),
            interval_secs: INTERVAL,
            lock_secs: LOCK,
            skip_grace_secs: GRACE,
            rules: all_to(&Keypair::new().pubkey()),
        }
        .data(),
        deadman::accounts::CreateVault {
            owner: env.owner.pubkey(),
            payer: sponsor.pubkey(),
            vault: env.vault_addr(),
            system_program: system_program::ID,
        }
        .to_account_metas(None),
    );
    let owner = env.owner.insecure_clone();
    env.send(ix, &[sponsor, &owner]).unwrap();
    env
}

const DEFAULT_LAMPORTS_PER_BYTE: u64 = 6_960;

fn set_rent(env: &mut Env, lamports_per_byte: u64) {
    env.svm
        .set_sysvar(&Rent::with_lamports_per_byte(lamports_per_byte));
}

#[test]
fn rent_paid_is_stored_and_survives_a_rent_cut() {
    let sponsor = Keypair::new();
    let mut env = sponsored_env(&sponsor);
    let rent = env.svm.minimum_balance_for_rent_exemption(Vault::SPACE);
    assert_eq!(env.vault().rent_paid, rent);
    assert_eq!(env.lamports(&env.vault_addr()), rent);
    env.deposit_sol(SOL);

    // Rent halves: the sponsor's deposit is still not withdrawable.
    set_rent(&mut env, DEFAULT_LAMPORTS_PER_BYTE / 2);
    assert!(env.svm.minimum_balance_for_rent_exemption(Vault::SPACE) < rent);
    assert!(env
        .withdraw_sol(SOL + 1)
        .unwrap_err()
        .contains("InsufficientFunds"));
    env.withdraw_sol(SOL / 2).unwrap();

    // Close: exactly the deposited rent back to the sponsor.
    let (s0, o0) = (
        env.lamports(&sponsor.pubkey()),
        env.lamports(&env.owner.pubkey()),
    );
    let owner = env.owner.insecure_clone();
    let ix = env.close_ix(&sponsor.pubkey());
    env.send(ix, &[&owner]).unwrap();
    assert_eq!(env.lamports(&sponsor.pubkey()) - s0, rent);
    assert_eq!(env.lamports(&env.owner.pubkey()) + 5_000 - o0, SOL / 2);
}

#[test]
fn a_rent_rise_keeps_the_account_rent_exempt() {
    let sponsor = Keypair::new();
    let mut env = sponsored_env(&sponsor);
    let paid = env.vault().rent_paid;
    env.deposit_sol(SOL);
    set_rent(&mut env, DEFAULT_LAMPORTS_PER_BYTE * 2);
    let now_min = env.svm.minimum_balance_for_rent_exemption(Vault::SPACE);
    assert!(now_min > paid);
    let free = paid + SOL - now_min;
    assert!(env
        .withdraw_sol(free + 1)
        .unwrap_err()
        .contains("InsufficientFunds"));
    env.withdraw_sol(free).unwrap();

    // The sponsor still gets only what it paid; the owner the rest.
    let (s0, o0) = (
        env.lamports(&sponsor.pubkey()),
        env.lamports(&env.owner.pubkey()),
    );
    let owner = env.owner.insecure_clone();
    let ix = env.close_ix(&sponsor.pubkey());
    env.send(ix, &[&owner]).unwrap();
    assert_eq!(env.lamports(&sponsor.pubkey()) - s0, paid);
    assert_eq!(
        env.lamports(&env.owner.pubkey()) + 5_000 - o0,
        now_min - paid
    );
}

#[test]
fn vault_layout_keeps_client_offsets_and_reserved_space() {
    let b = Keypair::new();
    let guardian = Keypair::new();
    let mut env = Env::new();
    env.init_config();
    env.plan = 0x1234;
    env.create_vault(all_to(&b.pubkey())).unwrap();
    env.update_policy(all_to(&b.pubkey()), Some(guardian.pubkey()))
        .unwrap();
    let data = env.svm.get_account(&env.vault_addr()).unwrap().data;
    assert_eq!(Vault::SPACE, 1390);
    assert_eq!(data.len(), Vault::SPACE);
    assert_eq!(&data[..8], Vault::DISCRIMINATOR);
    assert_eq!(&data[8..40], env.owner.pubkey().as_ref());
    assert_eq!(&data[40..42], &0x1234u16.to_le_bytes());
    assert_eq!(&data[42..74], env.guard.pubkey().as_ref());
    assert_eq!(data[74], 1);
    assert_eq!(&data[75..107], guardian.pubkey().as_ref());
    let v = env.vault();
    assert_eq!(v._reserved, [0u8; 55]);
    assert_eq!(v.vest_period_secs, 0);
    assert_eq!(v.stipend_paid, 0);
    assert!(v.rent_paid > 0);
}

#[test]
fn vest_period_sits_between_stipend_bits_and_reserved_space() {
    let b = Keypair::new();
    let mut env = Env::new();
    env.init_config();
    env.plan = 0x1234;
    let now = env.now();
    env.create_vesting_stepped(
        now,
        false,
        vec![schedule(&b.pubkey(), None, SOL, 0, 10 * DAY)],
        DAY,
    )
    .unwrap();
    let data = env.svm.get_account(&env.vault_addr()).unwrap().data;
    assert_eq!(data.len(), Vault::SPACE);
    assert_eq!(&data[8..40], env.owner.pubkey().as_ref());
    assert_eq!(&data[40..42], &0x1234u16.to_le_bytes());
    assert_eq!(&data[42..74], env.guard.pubkey().as_ref());
    assert_eq!(data[74], 0);
    let v = env.vault();
    // Borsh tail: ... bump, stipend_paid, vest_period_secs, _reserved.
    let mut body = Vec::new();
    anchor_lang::AnchorSerialize::serialize(&v, &mut body).unwrap();
    let end = 8 + body.len();
    let period_at = end - 55 - 8;
    assert_eq!(&data[period_at..period_at + 8], &DAY.to_le_bytes());
    assert_eq!(data[period_at - 1], v.stipend_paid);
    assert_eq!(data[period_at - 2], v.bump);
    assert!(data[period_at + 8..].iter().all(|&x| x == 0));
}

impl Env {
    fn recover_ix(&self, owner: &Pubkey, legacy: &Pubkey, plan_id: u16) -> Instruction {
        Instruction::new_with_bytes(
            deadman::id(),
            &deadman::instruction::RecoverLegacyVault { plan_id }.data(),
            deadman::accounts::RecoverLegacyVault {
                owner: *owner,
                legacy: *legacy,
            }
            .to_account_metas(None),
        )
    }

    fn recover(&mut self, plan_id: u16) -> Result<u64, String> {
        let owner = self.owner.insecure_clone();
        let ix = self.recover_ix(
            &owner.pubkey(),
            &vault_pda(&owner.pubkey(), plan_id),
            plan_id,
        );
        self.send(ix, &[&owner])
    }

    /// Puts `data` at `address`, owned by `program_owner`.
    fn put_legacy(
        &mut self,
        address: &Pubkey,
        data: Vec<u8>,
        program_owner: Pubkey,
        lamports: u64,
    ) {
        // Any fetched account gives us the SDK's Account type to fill in.
        let mut acc = self.svm.get_account(&self.owner.pubkey()).unwrap();
        acc.lamports = lamports;
        acc.data = data;
        acc.owner = program_owner;
        self.svm.set_account(*address, acc).unwrap();
    }
}

/// Bytes of a vault of `owner` and `plan_id` in an older, `len`-byte layout.
fn legacy_bytes(disc: &[u8], owner: &Pubkey, plan_id: u16, len: usize) -> Vec<u8> {
    let mut data = vec![7u8; len];
    data[..8].copy_from_slice(disc);
    data[8..40].copy_from_slice(owner.as_ref());
    data[40..42].copy_from_slice(&plan_id.to_le_bytes());
    data
}

#[test]
fn legacy_vault_is_recovered_to_its_owner() {
    let mut env = Env::new();
    env.init_config();
    let owner = env.owner.pubkey();
    // Devnet holds plans 0, 1 and 42801 in 958/996/1318-byte layouts.
    for (plan, len) in [(0u16, 958usize), (1, 996), (42_801, 1318)] {
        let addr = vault_pda(&owner, plan);
        env.put_legacy(
            &addr,
            legacy_bytes(Vault::DISCRIMINATOR, &owner, plan, len),
            deadman::id(),
            SOL / 10,
        );
        let before = env.lamports(&owner);
        env.recover(plan).unwrap();
        assert_eq!(env.lamports(&owner) + 5_000 - before, SOL / 10);
        assert_eq!(env.lamports(&addr), 0);
    }
    // The freed address hosts a new plan.
    env.plan = 1;
    env.create_vault(all_to(&Keypair::new().pubkey())).unwrap();
    assert_eq!(env.vault().plan_id, 1);
}

#[test]
fn recovery_rejects_anything_but_the_callers_legacy_vault() {
    let mut env = ready(all_to(&Keypair::new().pubkey()));
    let owner = env.owner.pubkey();
    // A current-layout vault.
    assert!(env.recover(0).unwrap_err().contains("NotLegacyVault"));

    // Another wallet cannot recover the owner's legacy plan: the address
    // is derived from the signer.
    let addr = vault_pda(&owner, 5);
    env.put_legacy(
        &addr,
        legacy_bytes(Vault::DISCRIMINATOR, &owner, 5, 958),
        deadman::id(),
        SOL,
    );
    let thief = env.keeper.insecure_clone();
    let ix = env.recover_ix(&thief.pubkey(), &addr, 5);
    assert!(env
        .send(ix, &[&thief])
        .unwrap_err()
        .contains("ConstraintSeeds"));

    // Bytes naming another owner at the owner's address.
    let addr6 = vault_pda(&owner, 6);
    env.put_legacy(
        &addr6,
        legacy_bytes(Vault::DISCRIMINATOR, &thief.pubkey(), 6, 958),
        deadman::id(),
        SOL,
    );
    assert!(env.recover(6).unwrap_err().contains("Unauthorized"));

    // Wrong plan id in the bytes.
    let addr7 = vault_pda(&owner, 7);
    env.put_legacy(
        &addr7,
        legacy_bytes(Vault::DISCRIMINATOR, &owner, 8, 958),
        deadman::id(),
        SOL,
    );
    assert!(env.recover(7).unwrap_err().contains("NotLegacyVault"));

    // Not a vault discriminator.
    let addr9 = vault_pda(&owner, 9);
    env.put_legacy(
        &addr9,
        legacy_bytes(Config::DISCRIMINATOR, &owner, 9, 958),
        deadman::id(),
        SOL,
    );
    assert!(env.recover(9).unwrap_err().contains("NotLegacyVault"));

    // Not owned by the program.
    let addr10 = vault_pda(&owner, 10);
    env.put_legacy(
        &addr10,
        legacy_bytes(Vault::DISCRIMINATOR, &owner, 10, 958),
        system_program::ID,
        SOL,
    );
    assert!(env.recover(10).unwrap_err().contains("NotLegacyVault"));

    // Valid bytes at an address that is not the plan's PDA.
    let stray = Keypair::new().pubkey();
    env.put_legacy(
        &stray,
        legacy_bytes(Vault::DISCRIMINATOR, &owner, 5, 958),
        deadman::id(),
        SOL,
    );
    let me = env.owner.insecure_clone();
    let ix = env.recover_ix(&owner, &stray, 5);
    assert!(env
        .send(ix, &[&me])
        .unwrap_err()
        .contains("ConstraintSeeds"));

    // Nothing moved; the real legacy plan still recovers.
    assert_eq!(env.lamports(&addr), SOL);
    env.recover(5).unwrap();
    assert_eq!(env.lamports(&addr), 0);
}

#[test]
fn vesting_stipend_is_paid_once_per_schedule() {
    let c = Keypair::new();
    let mut env = Env::new();
    env.init_config();
    let usdc = env.token_setup(1_000_000);
    let now = env.now();
    let mut token = schedule(&c.pubkey(), Some(usdc), 1_000_000, 0, 10 * DAY);
    token.rail = Rail::Cloak;
    env.create_vesting(now, true, vec![token]).unwrap();
    let vault = env.vault_addr();
    let admin = env.admin.insecure_clone();
    CreateAssociatedTokenAccountIdempotent::new(&mut env.svm, &admin, &usdc)
        .owner(&vault)
        .send()
        .unwrap();
    MintTo::new(&mut env.svm, &admin, &usdc, &ata(&vault, &usdc), 1_000_000)
        .send()
        .unwrap();
    env.deposit_sol(10 * CLOAK_STIPEND);

    env.advance(DAY);
    env.release_token(0, &c.pubkey(), &usdc).unwrap();
    assert_eq!(env.lamports(&c.pubkey()), CLOAK_STIPEND);
    assert_eq!(env.vault().stipend_paid, 1);
    // The beneficiary spends the stipend; later releases do not refill it.
    let sink = Keypair::new().pubkey();
    let ix = anchor_lang::solana_program::system_instruction::transfer(
        &c.pubkey(),
        &sink,
        CLOAK_STIPEND - 5000,
    );
    env.send(ix, &[&c]).unwrap();
    let spare = env.withdrawable();
    env.advance(DAY);
    env.release_token(0, &c.pubkey(), &usdc).unwrap();
    assert_eq!(env.withdrawable(), spare);
}

const SUB_PRICE: u64 = 5_000_000;
const SUB_PERIOD: i64 = 30 * DAY;

fn sub_config_pda() -> Pubkey {
    Pubkey::find_program_address(&[SUB_CONFIG_SEED], &deadman::id()).0
}

impl Env {
    fn set_subscription_ix(
        &self,
        signer: &Pubkey,
        price: u64,
        period_secs: i64,
        mint: &Pubkey,
        enabled: bool,
        min_periods: u16,
    ) -> Instruction {
        Instruction::new_with_bytes(
            deadman::id(),
            &deadman::instruction::SetSubscription {
                price_per_period: price,
                period_secs,
                mint: *mint,
                enabled,
                min_periods,
            }
            .data(),
            deadman::accounts::SetSubscription {
                admin: *signer,
                config: config_pda(),
                sub_config: sub_config_pda(),
                system_program: system_program::ID,
            }
            .to_account_metas(None),
        )
    }

    fn set_subscription(&mut self, mint: &Pubkey, enabled: bool) -> Result<u64, String> {
        self.set_subscription_min(mint, enabled, 1)
    }

    fn set_subscription_min(
        &mut self,
        mint: &Pubkey,
        enabled: bool,
        min_periods: u16,
    ) -> Result<u64, String> {
        let admin = self.admin.insecure_clone();
        let ix = self.set_subscription_ix(
            &admin.pubkey(),
            SUB_PRICE,
            SUB_PERIOD,
            mint,
            enabled,
            min_periods,
        );
        self.send(ix, &[&admin])
    }

    fn sub_config(&self) -> SubscriptionConfig {
        let acc = self.svm.get_account(&sub_config_pda()).unwrap();
        SubscriptionConfig::try_deserialize(&mut acc.data.as_slice()).unwrap()
    }

    /// Mint with the owner's ATA funded and the treasury's ATA created.
    fn sub_mint(&mut self) -> Pubkey {
        let admin = self.admin.insecure_clone();
        let mint = CreateMint::new(&mut self.svm, &admin)
            .decimals(6)
            .send()
            .unwrap();
        for owner in [self.owner.pubkey(), self.treasury.pubkey()] {
            CreateAssociatedTokenAccountIdempotent::new(&mut self.svm, &admin, &mint)
                .owner(&owner)
                .send()
                .unwrap();
        }
        let owner_token = ata(&self.owner.pubkey(), &mint);
        MintTo::new(
            &mut self.svm,
            &admin,
            &mint,
            &owner_token,
            1_000 * SUB_PRICE,
        )
        .send()
        .unwrap();
        mint
    }

    /// Enabled subscription priced in a fresh mint.
    fn sub_setup(&mut self) -> Pubkey {
        let mint = self.sub_mint();
        self.set_subscription(&mint, true).unwrap();
        mint
    }

    fn subscribe_ix(
        &self,
        owner: &Pubkey,
        payer: &Pubkey,
        mint: &Pubkey,
        owner_token: &Pubkey,
        treasury_token: &Pubkey,
        periods: u16,
    ) -> Instruction {
        self.subscribe_ix_at(
            &sub_pda(owner),
            owner,
            payer,
            mint,
            owner_token,
            treasury_token,
            periods,
        )
    }

    #[allow(clippy::too_many_arguments)]
    fn subscribe_ix_at(
        &self,
        subscription: &Pubkey,
        owner: &Pubkey,
        payer: &Pubkey,
        mint: &Pubkey,
        owner_token: &Pubkey,
        treasury_token: &Pubkey,
        periods: u16,
    ) -> Instruction {
        Instruction::new_with_bytes(
            deadman::id(),
            &deadman::instruction::Subscribe { periods }.data(),
            deadman::accounts::Subscribe {
                owner: *owner,
                payer: *payer,
                subscription: *subscription,
                config: config_pda(),
                sub_config: sub_config_pda(),
                mint: *mint,
                owner_token: *owner_token,
                treasury_token: *treasury_token,
                token_program: TOKEN_ID,
                system_program: system_program::ID,
            }
            .to_account_metas(None),
        )
    }

    fn subscribe(&mut self, mint: &Pubkey, periods: u16) -> Result<u64, String> {
        let owner = self.owner.insecure_clone();
        let ix = self.subscribe_ix(
            &owner.pubkey(),
            &owner.pubkey(),
            mint,
            &ata(&owner.pubkey(), mint),
            &ata(&self.treasury.pubkey(), mint),
            periods,
        );
        self.send(ix, &[&owner])
    }

    /// The owner's subscription, if it was ever created.
    fn subscription(&self) -> Option<Subscription> {
        let acc = self.svm.get_account(&sub_pda(&self.owner.pubkey()))?;
        Some(Subscription::try_deserialize(&mut acc.data.as_slice()).unwrap())
    }

    fn paid_until(&self) -> i64 {
        self.subscription().map_or(0, |s| s.paid_until)
    }

    /// Switches the helpers to another owner (fresh plan 0 unless created).
    fn switch_owner(&mut self, owner: &Keypair) {
        self.owner = owner.insecure_clone();
        self.plan = 0;
    }
}

/// Plan paying all of the vault's SOL to `b` and all of `usdc` to `a`.
fn sol_and_token_rules(a: &Pubkey, b: &Pubkey, usdc: Pubkey, rail: Rail) -> Vec<RuleInput> {
    vec![
        rule(
            a,
            Rail::Solana,
            10 * DAY,
            Some(usdc),
            AmountMode::Percent,
            10_000,
        ),
        rule(b, rail, 10 * DAY, None, AmountMode::Percent, 10_000),
    ]
}

#[test]
fn subscription_config_is_admin_only_and_validated() {
    let mut env = Env::new();
    env.init_config();
    let mint = env.sub_mint();
    let intruder = Keypair::new();
    env.svm.airdrop(&intruder.pubkey(), SOL).unwrap();
    let ix = env.set_subscription_ix(&intruder.pubkey(), SUB_PRICE, SUB_PERIOD, &mint, true, 1);
    assert!(env
        .send(ix, &[&intruder])
        .unwrap_err()
        .contains("Unauthorized"));

    let admin = env.admin.insecure_clone();
    for (price, period, m) in [
        (0, SUB_PERIOD, mint),
        (SUB_PRICE, DAY - 1, mint),
        (SUB_PRICE, 366 * DAY + 1, mint),
        (SUB_PRICE, SUB_PERIOD, Pubkey::default()),
    ] {
        let ix = env.set_subscription_ix(&admin.pubkey(), price, period, &m, true, 1);
        assert!(env
            .send(ix, &[&admin])
            .unwrap_err()
            .contains("InvalidSubscription"));
    }

    env.set_subscription(&mint, true).unwrap();
    let c = env.sub_config();
    assert_eq!(
        (c.price_per_period, c.period_secs, c.mint, c.enabled),
        (SUB_PRICE, SUB_PERIOD, mint, true)
    );
    let ix = env.set_subscription_ix(&admin.pubkey(), 7, 366 * DAY, &mint, false, 1);
    env.send(ix, &[&admin]).unwrap();
    let c = env.sub_config();
    assert_eq!(
        (c.price_per_period, c.period_secs, c.enabled),
        (7, 366 * DAY, false)
    );
    let ix = env.set_subscription_ix(&intruder.pubkey(), SUB_PRICE, SUB_PERIOD, &mint, true, 1);
    assert!(env.send(ix, &[&intruder]).is_err(), "update is admin-only");
}

#[test]
fn subscribing_pays_the_treasury_and_extends_coverage() {
    // No plan needed: the subscription belongs to the account.
    let mut env = Env::new();
    env.init_config();
    let mint = env.sub_setup();
    let treasury_token = ata(&env.treasury.pubkey(), &mint);
    let owner_token = ata(&env.owner.pubkey(), &mint);
    let o0 = env.token_balance(&owner_token);

    for periods in [0, 37] {
        assert!(env
            .subscribe(&mint, periods)
            .unwrap_err()
            .contains("InvalidSubscription"));
    }
    assert!(env.subscription().is_none());

    let t0 = env.now();
    env.subscribe(&mint, 1).unwrap();
    let sub = env.subscription().unwrap();
    assert_eq!(
        (sub.owner, sub.paid_until, sub.bump),
        (
            env.owner.pubkey(),
            t0 + SUB_PERIOD,
            Pubkey::find_program_address(
                &[SUBSCRIPTION_SEED, env.owner.pubkey().as_ref()],
                &deadman::id()
            )
            .1
        )
    );
    assert_eq!(sub._reserved, [0u8; 32]);
    let acc = env.svm.get_account(&sub_pda(&env.owner.pubkey())).unwrap();
    assert_eq!(acc.data.len(), Subscription::SPACE);
    assert_eq!(Subscription::SPACE, 81);
    assert_eq!(env.token_balance(&treasury_token), SUB_PRICE);

    // Still covered: the new periods stack on the paid end.
    env.advance(10 * DAY);
    env.subscribe(&mint, 3).unwrap();
    assert_eq!(env.paid_until(), t0 + 4 * SUB_PERIOD);
    assert_eq!(env.token_balance(&treasury_token), 4 * SUB_PRICE);

    // Lapsed: coverage restarts from now.
    env.advance(200 * DAY);
    env.subscribe(&mint, 1).unwrap();
    assert_eq!(env.paid_until(), env.now() + SUB_PERIOD);
    assert_eq!(env.token_balance(&treasury_token), 5 * SUB_PRICE);
    assert_eq!(o0 - env.token_balance(&owner_token), 5 * SUB_PRICE);
}

#[test]
fn a_sponsor_can_pay_the_subscription_rent() {
    let mut env = Env::new();
    env.init_config();
    let mint = env.sub_setup();
    let sponsor = Keypair::new();
    env.svm.airdrop(&sponsor.pubkey(), SOL).unwrap();
    let owner = env.owner.insecure_clone();
    let o0 = env.lamports(&owner.pubkey());
    let s0 = env.lamports(&sponsor.pubkey());
    let ix = env.subscribe_ix(
        &owner.pubkey(),
        &sponsor.pubkey(),
        &mint,
        &ata(&owner.pubkey(), &mint),
        &ata(&env.treasury.pubkey(), &mint),
        1,
    );
    env.send(ix, &[&sponsor, &owner]).unwrap();
    let rent = env
        .svm
        .minimum_balance_for_rent_exemption(Subscription::SPACE);
    assert_eq!(env.lamports(&owner.pubkey()), o0);
    assert_eq!(s0 - env.lamports(&sponsor.pubkey()), rent + 10_000);
    assert_eq!(env.subscription().unwrap().owner, owner.pubkey());

    // The owner must still sign: a sponsor cannot spend the owner's tokens.
    let mut ix = env.subscribe_ix(
        &owner.pubkey(),
        &sponsor.pubkey(),
        &mint,
        &ata(&owner.pubkey(), &mint),
        &ata(&env.treasury.pubkey(), &mint),
        1,
    );
    ix.accounts[0].is_signer = false;
    assert!(env.send(ix, &[&sponsor]).is_err());
}

#[test]
fn subscribing_rejects_wrong_accounts_and_disabled_config() {
    let mut env = Env::new();
    env.init_config();
    let mint = env.sub_setup();
    let other = env.sub_mint();
    let owner = env.owner.insecure_clone();
    let treasury = env.treasury.pubkey();
    let owner_ata = ata(&owner.pubkey(), &mint);

    // Wrong mint, even with matching token accounts.
    let ix = env.subscribe_ix(
        &owner.pubkey(),
        &owner.pubkey(),
        &other,
        &ata(&owner.pubkey(), &other),
        &ata(&treasury, &other),
        1,
    );
    assert!(env
        .send(ix, &[&owner])
        .unwrap_err()
        .contains("InvalidSubscription"));

    // Payment must land in the treasury's ATA, not any other account.
    let admin = env.admin.insecure_clone();
    let stranger = Keypair::new();
    CreateAssociatedTokenAccountIdempotent::new(&mut env.svm, &admin, &mint)
        .owner(&stranger.pubkey())
        .send()
        .unwrap();
    for to in [ata(&stranger.pubkey(), &mint), owner_ata] {
        let ix = env.subscribe_ix(&owner.pubkey(), &owner.pubkey(), &mint, &owner_ata, &to, 1);
        assert!(env.send(ix, &[&owner]).is_err());
    }

    // An intruder cannot spend the owner's tokens...
    let intruder = Keypair::new();
    env.svm.airdrop(&intruder.pubkey(), SOL).unwrap();
    CreateAssociatedTokenAccountIdempotent::new(&mut env.svm, &admin, &mint)
        .owner(&intruder.pubkey())
        .send()
        .unwrap();
    let ix = env.subscribe_ix(
        &intruder.pubkey(),
        &intruder.pubkey(),
        &mint,
        &owner_ata,
        &ata(&treasury, &mint),
        1,
    );
    assert!(env.send(ix, &[&intruder]).is_err());
    // ...nor write its own payment into the owner's subscription.
    let ix = env.subscribe_ix_at(
        &sub_pda(&owner.pubkey()),
        &intruder.pubkey(),
        &intruder.pubkey(),
        &mint,
        &ata(&intruder.pubkey(), &mint),
        &ata(&treasury, &mint),
        1,
    );
    assert!(env
        .send(ix, &[&intruder])
        .unwrap_err()
        .contains("ConstraintSeeds"));
    assert!(env.subscription().is_none());

    env.set_subscription(&mint, false).unwrap();
    assert!(env
        .subscribe(&mint, 1)
        .unwrap_err()
        .contains("SubscriptionDisabled"));
    assert!(env.subscription().is_none());
    assert_eq!(env.token_balance(&ata(&treasury, &mint)), 0);
}

#[test]
fn one_subscription_waives_fees_on_every_plan_of_the_owner() {
    let (a, b) = (Keypair::new(), Keypair::new());
    let mut env = ready(all_to(&b.pubkey()));
    let sub = env.sub_setup();
    let usdc = env.token_setup(1_000_000);
    env.update_policy(
        sol_and_token_rules(&a.pubkey(), &b.pubkey(), usdc, Rail::Cloak),
        None,
    )
    .unwrap();
    env.deposit_sol(4 * SOL);
    env.subscribe(&sub, 1).unwrap();

    // A plan created after subscribing is covered too.
    let c = Keypair::new();
    env.plan = 9;
    env.create_vault(vec![rule(
        &c.pubkey(),
        Rail::Zcash,
        10 * DAY,
        None,
        AmountMode::Percent,
        10_000,
    )])
    .unwrap();
    env.deposit_sol(2 * SOL);

    // Silence outlasts the subscription; it covered both last check-ins.
    env.advance(40 * DAY);
    let treasury = env.treasury.pubkey();
    let t0 = env.lamports(&treasury);

    let gross = env.withdrawable();
    env.execute_sol(0, &c.pubkey()).unwrap();
    assert_eq!(env.lamports(&c.pubkey()), gross);

    env.plan = 0;
    let gross = env.withdrawable();
    env.execute_sol(1, &b.pubkey()).unwrap();
    assert_eq!(env.lamports(&b.pubkey()), gross);
    env.execute_token(0, &a.pubkey(), &usdc).unwrap();
    assert_eq!(env.token_balance(&ata(&a.pubkey(), &usdc)), 1_000_000);

    assert_eq!(env.lamports(&treasury), t0);
    assert_eq!(env.token_balance(&ata(&treasury, &usdc)), 0);
}

#[test]
fn another_owners_plan_is_not_covered_and_cannot_borrow_the_subscription() {
    let (b, d) = (Keypair::new(), Keypair::new());
    let mut env = ready(all_to(&b.pubkey()));
    let sub = env.sub_setup();
    env.subscribe(&sub, 1).unwrap();
    let subscriber = env.owner.pubkey();

    let other = Keypair::new();
    env.svm.airdrop(&other.pubkey(), 100 * SOL).unwrap();
    env.switch_owner(&other);
    env.create_vault(all_to(&d.pubkey())).unwrap();
    env.deposit_sol(2 * SOL);
    env.advance(10 * DAY + 1);
    let gross = env.withdrawable();

    // The subscriber's PDA does not match this vault's owner.
    env.sub_override = Some(sub_pda(&subscriber));
    assert!(env
        .execute_sol(0, &d.pubkey())
        .unwrap_err()
        .contains("InvalidSubscription"));

    // With its own (never created) PDA, the normal fee applies.
    env.sub_override = None;
    let treasury = env.treasury.pubkey();
    let t0 = env.lamports(&treasury);
    env.execute_sol(0, &d.pubkey()).unwrap();
    assert_eq!(env.lamports(&d.pubkey()), gross - fee(gross, FEE_PUBLIC));
    assert_eq!(env.lamports(&treasury) - t0, fee(gross, FEE_PUBLIC));
}

#[test]
fn payouts_reject_a_substituted_subscription_account() {
    let (a, b) = (Keypair::new(), Keypair::new());
    let mut env = ready(all_to(&b.pubkey()));
    let sub = env.sub_setup();
    let usdc = env.token_setup(1_000_000);
    env.update_policy(
        sol_and_token_rules(&a.pubkey(), &b.pubkey(), usdc, Rail::Solana),
        None,
    )
    .unwrap();
    env.deposit_sol(2 * SOL);
    env.subscribe(&sub, 1).unwrap();
    env.advance(10 * DAY + 1);

    // An executor cannot drop the waiver by passing an empty account or
    // another program account in place of the owner's subscription.
    env.sub_override = Some(Keypair::new().pubkey());
    assert!(env
        .execute_sol(1, &b.pubkey())
        .unwrap_err()
        .contains("InvalidSubscription"));
    assert!(env
        .execute_token(0, &a.pubkey(), &usdc)
        .unwrap_err()
        .contains("InvalidSubscription"));
    for fake in [env.vault_addr(), sub_config_pda(), config_pda()] {
        env.sub_override = Some(fake);
        assert!(env.execute_sol(1, &b.pubkey()).is_err());
        assert!(env.execute_token(0, &a.pubkey(), &usdc).is_err());
    }
    env.sub_override = None;
    let gross = env.withdrawable();
    env.execute_sol(1, &b.pubkey()).unwrap();
    assert_eq!(env.lamports(&b.pubkey()), gross);
}

#[test]
fn an_uncreated_subscription_pays_the_normal_fee() {
    let b = Keypair::new();
    let mut env = ready(all_to(&b.pubkey()));
    env.deposit_sol(2 * SOL);
    // Lamports sent to the PDA do not create a subscription.
    let owner = env.owner.insecure_clone();
    let ix = anchor_lang::solana_program::system_instruction::transfer(
        &owner.pubkey(),
        &sub_pda(&owner.pubkey()),
        SOL,
    );
    env.send(ix, &[&owner]).unwrap();
    assert!(env.svm.get_account(&sub_pda(&owner.pubkey())).is_some());

    env.advance(10 * DAY + 1);
    let treasury = env.treasury.pubkey();
    let t0 = env.lamports(&treasury);
    let gross = env.withdrawable();
    env.execute_sol(0, &b.pubkey()).unwrap();
    assert_eq!(env.lamports(&b.pubkey()), gross - fee(gross, FEE_PUBLIC));
    assert_eq!(env.lamports(&treasury) - t0, fee(gross, FEE_PUBLIC));

    // Subscribing later still works on the pre-funded PDA.
    let sub = env.sub_setup();
    env.subscribe(&sub, 1).unwrap();
    assert_eq!(env.paid_until(), env.now() + SUB_PERIOD);
}

#[test]
fn lapsed_subscription_before_the_last_check_in_pays_the_normal_fee() {
    let (a, b) = (Keypair::new(), Keypair::new());
    let mut env = ready(all_to(&b.pubkey()));
    let sub = env.sub_setup();
    let usdc = env.token_setup(1_000_000);
    env.update_policy(
        sol_and_token_rules(&a.pubkey(), &b.pubkey(), usdc, Rail::Solana),
        None,
    )
    .unwrap();
    env.deposit_sol(4 * SOL);
    env.subscribe(&sub, 1).unwrap();
    env.advance(SUB_PERIOD + 1);
    let owner = env.owner.insecure_clone();
    env.pulse(&owner).unwrap();
    assert!(env.paid_until() < env.vault().last_pulse);

    env.advance(10 * DAY + 1);
    let treasury = env.treasury.pubkey();
    let t0 = env.lamports(&treasury);
    let gross = env.withdrawable();
    env.execute_sol(1, &b.pubkey()).unwrap();
    assert_eq!(env.lamports(&b.pubkey()), gross - fee(gross, FEE_PUBLIC));
    assert_eq!(env.lamports(&treasury) - t0, fee(gross, FEE_PUBLIC));

    env.execute_token(0, &a.pubkey(), &usdc).unwrap();
    assert_eq!(
        env.token_balance(&ata(&a.pubkey(), &usdc)),
        1_000_000 - fee(1_000_000, FEE_PUBLIC)
    );
    assert_eq!(
        env.token_balance(&ata(&treasury, &usdc)),
        fee(1_000_000, FEE_PUBLIC)
    );
}

#[test]
fn vesting_fee_is_waived_only_while_the_subscription_is_active() {
    let b = Keypair::new();
    let mut env = Env::new();
    env.init_config();
    let sub = env.sub_setup();
    let usdc = env.token_setup(0);
    let now = env.now();
    env.create_vesting(
        now,
        false,
        vec![
            schedule(&b.pubkey(), None, 10 * SOL, 0, 100 * DAY),
            schedule(&b.pubkey(), Some(usdc), 1_000_000, 0, 100 * DAY),
        ],
    )
    .unwrap();
    env.deposit_sol(10 * SOL);
    let admin = env.admin.insecure_clone();
    let vault = env.vault_addr();
    CreateAssociatedTokenAccountIdempotent::new(&mut env.svm, &admin, &usdc)
        .owner(&vault)
        .send()
        .unwrap();
    MintTo::new(&mut env.svm, &admin, &usdc, &ata(&vault, &usdc), 1_000_000)
        .send()
        .unwrap();
    env.subscribe(&sub, 1).unwrap();
    let treasury = env.treasury.pubkey();
    let t0 = env.lamports(&treasury);

    // Day 20, covered: 20% vested, no fee.
    env.advance(20 * DAY);
    env.release(0, &b.pubkey()).unwrap();
    assert_eq!(env.lamports(&b.pubkey()), 2 * SOL);
    env.release_token(1, &b.pubkey(), &usdc).unwrap();
    assert_eq!(env.token_balance(&ata(&b.pubkey(), &usdc)), 200_000);
    assert_eq!(env.lamports(&treasury), t0);
    assert_eq!(env.token_balance(&ata(&treasury, &usdc)), 0);

    // A substituted subscription account is rejected here too.
    env.sub_override = Some(Keypair::new().pubkey());
    env.advance(DAY);
    assert!(env
        .release(0, &b.pubkey())
        .unwrap_err()
        .contains("InvalidSubscription"));
    assert!(env
        .release_token(1, &b.pubkey(), &usdc)
        .unwrap_err()
        .contains("InvalidSubscription"));
    env.sub_override = None;

    // Day 50, lapsed: the next 30% pays the fee.
    env.advance(29 * DAY);
    env.release(0, &b.pubkey()).unwrap();
    let part = 3 * SOL;
    assert_eq!(
        env.lamports(&b.pubkey()),
        2 * SOL + part - fee(part, FEE_PUBLIC)
    );
    assert_eq!(env.lamports(&treasury) - t0, fee(part, FEE_PUBLIC));
    env.release_token(1, &b.pubkey(), &usdc).unwrap();
    assert_eq!(
        env.token_balance(&ata(&b.pubkey(), &usdc)),
        200_000 + 300_000 - fee(300_000, FEE_PUBLIC)
    );
    assert_eq!(
        env.token_balance(&ata(&treasury, &usdc)),
        fee(300_000, FEE_PUBLIC)
    );
}

#[test]
fn a_new_or_lapsed_subscription_commits_to_the_minimum_term() {
    let mut env = Env::new();
    env.init_config();
    let mint = env.sub_setup();
    env.set_subscription_min(&mint, true, 12).unwrap();
    assert_eq!(env.sub_config().min_periods, 12);

    assert!(env
        .subscribe(&mint, 11)
        .unwrap_err()
        .contains("InvalidSubscription"));
    let t0 = env.now();
    env.subscribe(&mint, 12).unwrap();
    assert_eq!(env.paid_until(), t0 + 12 * SUB_PERIOD);

    // While active, any extension is fine.
    env.subscribe(&mint, 1).unwrap();
    assert_eq!(env.paid_until(), t0 + 13 * SUB_PERIOD);
    env.subscribe(&mint, 36).unwrap();
    assert_eq!(env.paid_until(), t0 + 49 * SUB_PERIOD);

    // After a lapse the minimum applies again.
    env.advance(49 * SUB_PERIOD + DAY);
    assert!(env
        .subscribe(&mint, 1)
        .unwrap_err()
        .contains("InvalidSubscription"));
    env.subscribe(&mint, 12).unwrap();
    assert_eq!(env.paid_until(), env.now() + 12 * SUB_PERIOD);

    let admin = env.admin.insecure_clone();
    for min in [0, deadman::constants::MAX_SUB_PERIODS + 1] {
        let ix = env.set_subscription_ix(&admin.pubkey(), SUB_PRICE, SUB_PERIOD, &mint, true, min);
        assert!(env
            .send(ix, &[&admin])
            .unwrap_err()
            .contains("InvalidSubscription"));
    }
}
