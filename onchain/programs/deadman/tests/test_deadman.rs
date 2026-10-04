use {
    anchor_lang::{
        prelude::Pubkey,
        solana_program::{clock::Clock, instruction::Instruction, system_program},
        AccountDeserialize, InstructionData, ToAccountMetas,
    },
    anchor_spl::associated_token::get_associated_token_address_with_program_id,
    deadman::{AmountMode, Config, Rail, RuleInput, Vault, CONFIG_SEED, VAULT_SEED},
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
const STIPEND: u64 = 3_000_000;

struct Env {
    svm: LiteSVM,
    admin: Keypair,
    treasury: Keypair,
    owner: Keypair,
    guard: Keypair,
    keeper: Keypair,
    /// Plan the helpers act on.
    plan: u16,
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
        };
        env.set_time(1_800_000_000);
        env
    }

    fn vault_addr(&self) -> Pubkey {
        vault_pda(&self.owner.pubkey(), self.plan)
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
        acc.lamports - self.svm.minimum_balance_for_rent_exemption(acc.data.len())
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
    assert_eq!(env.lamports(&c.pubkey()), STIPEND);
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
