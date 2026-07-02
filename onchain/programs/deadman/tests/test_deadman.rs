use {
    anchor_lang::{
        prelude::Pubkey,
        solana_program::{clock::Clock, instruction::Instruction, system_program},
        AccountDeserialize, InstructionData, ToAccountMetas,
    },
    anchor_spl::associated_token::{self, get_associated_token_address_with_program_id},
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
}

fn config_pda() -> Pubkey {
    Pubkey::find_program_address(&[CONFIG_SEED], &deadman::id()).0
}

fn vault_pda(owner: &Pubkey) -> Pubkey {
    Pubkey::find_program_address(&[VAULT_SEED, owner.as_ref()], &deadman::id()).0
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
        };
        env.set_time(1_800_000_000);
        env
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
        let acc = self
            .svm
            .get_account(&vault_pda(&self.owner.pubkey()))
            .unwrap();
        Vault::try_deserialize(&mut acc.data.as_slice()).unwrap()
    }

    fn lamports(&self, k: &Pubkey) -> u64 {
        self.svm.get_account(k).map(|a| a.lamports).unwrap_or(0)
    }

    fn token_balance(&self, k: &Pubkey) -> u64 {
        get_spl_account::<SplAccount>(&self.svm, k).unwrap().amount
    }

    fn withdrawable(&self) -> u64 {
        let v = vault_pda(&self.owner.pubkey());
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
                guard: self.guard.pubkey(),
                interval_secs: INTERVAL,
                lock_secs: LOCK,
                rules,
            }
            .data(),
            deadman::accounts::CreateVault {
                owner: self.owner.pubkey(),
                vault: vault_pda(&self.owner.pubkey()),
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
            &vault_pda(&self.owner.pubkey()),
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
                vault: vault_pda(&self.owner.pubkey()),
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
            interval_secs: INTERVAL,
            lock_secs: LOCK,
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
                vault: vault_pda(&self.owner.pubkey()),
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
                vault: vault_pda(&self.owner.pubkey()),
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
                vault: vault_pda(&self.owner.pubkey()),
            }
            .to_account_metas(None),
        );
        let owner = self.owner.insecure_clone();
        self.send(ix, &[&owner])
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
                vault: vault_pda(&self.owner.pubkey()),
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
        let vault = vault_pda(&self.owner.pubkey());
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
                beneficiary_token: ata(beneficiary, mint),
                treasury_token: ata(&self.treasury.pubkey(), mint),
                token_program: TOKEN_ID,
                associated_token_program: associated_token::ID,
                system_program: system_program::ID,
            }
            .to_account_metas(None),
        );
        let keeper = self.keeper.insecure_clone();
        self.send(ix, &[&keeper])
    }

    fn withdraw_token(&mut self, mint: &Pubkey, amount: u64) -> Result<u64, String> {
        let vault = vault_pda(&self.owner.pubkey());
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
        let vault = vault_pda(&self.owner.pubkey());
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

    // The owner was only on a long trip: one pulse stops the second tier.
    let guard = env.guard.insecure_clone();
    env.pulse(&guard).unwrap();
    env.advance(15 * DAY);
    assert!(env.execute_sol(1, &b.pubkey()).is_err());
    env.withdraw_sol(SOL).unwrap();
}

#[test]
fn dust_to_fresh_account_is_skipped_not_blocking() {
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
    env.execute_sol(0, &a.pubkey()).unwrap();
    assert_eq!(env.vault().rules[0].paid, 0);
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
            vault: vault_pda(&env.owner.pubkey()),
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
            vault: vault_pda(&env.owner.pubkey()),
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
            vault: vault_pda(&env.owner.pubkey()),
        }
        .to_account_metas(None),
    );
    let owner = env.owner.insecure_clone();
    assert!(env.send(ix.clone(), &[&owner]).is_err());
    env.advance(LOCK + 1);
    env.send(ix, &[&owner]).unwrap();
    assert_eq!(env.lamports(&vault_pda(&env.owner.pubkey())), 0);
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
