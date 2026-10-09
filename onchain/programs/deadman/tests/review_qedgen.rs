//! qedgen review lane: checks every `qedgen probe` hypothesis and cluster
//! against the real program, and checks the properties of
//! `onchain/qedgen/deadman.qedspec` against the real code (LiteSVM for
//! instruction sequences, the crate's pure functions for the arithmetic).
//!
//! Run: `cd onchain && cargo test -p deadman --test review_qedgen`

use {
    anchor_lang::{
        prelude::Pubkey,
        solana_program::{clock::Clock, instruction::Instruction, system_program},
        AccountDeserialize, Discriminator, InstructionData, ToAccountMetas,
    },
    anchor_spl::associated_token::get_associated_token_address_with_program_id,
    deadman::{
        rule_gross, split_fee, AmountMode, Config, PlanKind, Rail, Rule, RuleInput, Vault,
        VestingInput, CONFIG_SEED, MAX_RULES, VAULT_SEED,
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
const LOCK: i64 = 3 * DAY;
const GRACE: i64 = 5 * DAY;
const FEE_PUBLIC: u16 = 200;

/// SplitMix64: deterministic, seedable, no extra dependency.
struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^ (z >> 31)
    }
    fn below(&mut self, n: u64) -> u64 {
        self.next() % n
    }
    fn range_i64(&mut self, lo: i64, hi: i64) -> i64 {
        lo + (self.next() % ((hi - lo + 1) as u64)) as i64
    }
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

fn sol_rule(b: &Pubkey, after: i64, mode: AmountMode, amount: u64) -> RuleInput {
    RuleInput {
        beneficiary: *b,
        rail: Rail::Solana,
        after_secs: after,
        mint: None,
        mode,
        amount,
    }
}

fn schedule(b: &Pubkey, total: u64, cliff: i64, duration: i64) -> VestingInput {
    VestingInput {
        beneficiary: *b,
        rail: Rail::Solana,
        mint: None,
        total,
        cliff_secs: cliff,
        duration_secs: duration,
    }
}

struct Env {
    svm: LiteSVM,
    admin: Keypair,
    treasury: Keypair,
    owner: Keypair,
    guard: Keypair,
    keeper: Keypair,
    attacker: Keypair,
}

impl Env {
    fn new() -> Self {
        let mut svm = LiteSVM::new();
        let bytes = include_bytes!(concat!(
            env!("CARGO_TARGET_TMPDIR"),
            "/../deploy/deadman.so"
        ));
        svm.add_program(deadman::id(), bytes).unwrap();
        let ks: Vec<Keypair> = (0..6).map(|_| Keypair::new()).collect();
        for k in &ks {
            svm.airdrop(&k.pubkey(), 1_000 * SOL).unwrap();
        }
        let mut it = ks.into_iter();
        let admin = it.next().unwrap();
        // LiteSVM deploys without an upgrade authority; make `admin` it.
        let pd = program_data_pda();
        let mut acc = svm.get_account(&pd).unwrap();
        acc.data[12] = 1;
        acc.data[13..45].copy_from_slice(admin.pubkey().as_ref());
        svm.set_account(pd, acc).unwrap();
        let mut env = Self {
            svm,
            admin,
            treasury: it.next().unwrap(),
            owner: it.next().unwrap(),
            guard: it.next().unwrap(),
            keeper: it.next().unwrap(),
            attacker: it.next().unwrap(),
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

    /// Sends with `signers[0]` as fee payer.
    fn send(&mut self, ix: Instruction, signers: &[&Keypair]) -> Result<(), String> {
        self.svm.expire_blockhash();
        let msg = Message::new_with_blockhash(
            &[ix],
            Some(&signers[0].pubkey()),
            &self.svm.latest_blockhash(),
        );
        let tx = VersionedTransaction::try_new(VersionedMessage::Legacy(msg), signers).unwrap();
        self.svm
            .send_transaction(tx)
            .map(|_| ())
            .map_err(|e| format!("{:?}\n{}", e.err, e.meta.logs.join("\n")))
    }

    /// Sends with the keeper paying the network fee, so the other signers'
    /// lamport deltas are exactly what the program moved.
    fn send_kp(&mut self, ix: Instruction, signer: &Keypair) -> Result<(), String> {
        let keeper = self.keeper.insecure_clone();
        self.send(ix, &[&keeper, signer])
    }

    fn lamports(&self, k: &Pubkey) -> u64 {
        self.svm.get_account(k).map(|a| a.lamports).unwrap_or(0)
    }
    fn data(&self, k: &Pubkey) -> Vec<u8> {
        self.svm.get_account(k).map(|a| a.data).unwrap_or_default()
    }
    fn vault_at(&self, addr: &Pubkey) -> Vault {
        let acc = self.svm.get_account(addr).unwrap();
        Vault::try_deserialize(&mut acc.data.as_slice()).unwrap()
    }
    fn vault(&self) -> Vault {
        self.vault_at(&self.vault_addr())
    }
    fn vault_addr(&self) -> Pubkey {
        vault_pda(&self.owner.pubkey(), 0)
    }
    fn withdrawable(&self) -> u64 {
        let v = self.vault_addr();
        let acc = self.svm.get_account(&v).unwrap();
        let rent = self
            .svm
            .minimum_balance_for_rent_exemption(acc.data.len())
            .max(self.vault().rent_paid);
        acc.lamports.saturating_sub(rent)
    }

    fn init_config_ix(&self, signer: &Pubkey) -> Instruction {
        Instruction::new_with_bytes(
            deadman::id(),
            &deadman::instruction::InitConfig {
                skr_mint: Pubkey::default(),
            }
            .data(),
            deadman::accounts::InitConfig {
                admin: *signer,
                config: config_pda(),
                treasury: self.treasury.pubkey(),
                program: deadman::id(),
                program_data: program_data_pda(),
                system_program: system_program::ID,
            }
            .to_account_metas(None),
        )
    }
    fn init_config(&mut self) {
        let admin = self.admin.insecure_clone();
        let ix = self.init_config_ix(&admin.pubkey());
        self.send(ix, &[&admin]).unwrap();
    }

    fn create_plan(&mut self, rules: Vec<RuleInput>) -> Result<(), String> {
        let ix = Instruction::new_with_bytes(
            deadman::id(),
            &deadman::instruction::CreatePlan {
                plan_id: 0,
                label: "Plan".to_string(),
                guard: self.guard.pubkey(),
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

    fn create_vesting(
        &mut self,
        revocable: bool,
        schedules: Vec<VestingInput>,
        period_secs: i64,
    ) -> Result<(), String> {
        let ix = Instruction::new_with_bytes(
            deadman::id(),
            &deadman::instruction::CreateVesting {
                plan_id: 0,
                label: "Vesting".to_string(),
                guard: self.guard.pubkey(),
                lock_secs: LOCK,
                start_at: self.now(),
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

    fn deposit(&mut self, amount: u64) {
        let ix = anchor_lang::solana_program::system_instruction::transfer(
            &self.keeper.pubkey(),
            &self.vault_addr(),
            amount,
        );
        let keeper = self.keeper.insecure_clone();
        self.send(ix, &[&keeper]).unwrap();
    }

    /// An `OwnerAction` instruction with `signer` in the owner slot.
    fn owner_action<T: InstructionData>(
        &self,
        signer: &Pubkey,
        vault: &Pubkey,
        d: T,
    ) -> Instruction {
        Instruction::new_with_bytes(
            deadman::id(),
            &d.data(),
            deadman::accounts::OwnerAction {
                owner: *signer,
                vault: *vault,
            }
            .to_account_metas(None),
        )
    }

    fn update_plan_ix(&self, signer: &Pubkey, rules: Vec<RuleInput>) -> Instruction {
        self.owner_action(
            signer,
            &self.vault_addr(),
            deadman::instruction::UpdatePlan {
                label: "Updated".to_string(),
                lock_secs: LOCK,
                skip_grace_secs: GRACE,
                rules,
                guardian: None,
            },
        )
    }

    fn withdraw_sol_ix(&self, signer: &Pubkey, amount: u64) -> Instruction {
        Instruction::new_with_bytes(
            deadman::id(),
            &deadman::instruction::WithdrawSol { amount }.data(),
            deadman::accounts::WithdrawSol {
                owner: *signer,
                vault: self.vault_addr(),
            }
            .to_account_metas(None),
        )
    }

    fn close_ix(&self, signer: &Pubkey, rent_payer: &Pubkey) -> Instruction {
        Instruction::new_with_bytes(
            deadman::id(),
            &deadman::instruction::CloseVault {}.data(),
            deadman::accounts::CloseVault {
                owner: *signer,
                vault: self.vault_addr(),
                rent_payer: *rent_payer,
            }
            .to_account_metas(None),
        )
    }

    fn signer_ix<T: InstructionData>(&self, signer: &Pubkey, d: T, lockdown: bool) -> Instruction {
        let metas = if lockdown {
            deadman::accounts::Lockdown {
                signer: *signer,
                vault: self.vault_addr(),
            }
            .to_account_metas(None)
        } else {
            deadman::accounts::Pulse {
                signer: *signer,
                vault: self.vault_addr(),
            }
            .to_account_metas(None)
        };
        Instruction::new_with_bytes(deadman::id(), &d.data(), metas)
    }

    fn execute_sol_ix(&self, index: u8, beneficiary: &Pubkey) -> Instruction {
        Instruction::new_with_bytes(
            deadman::id(),
            &deadman::instruction::ExecuteSolRule { index }.data(),
            deadman::accounts::ExecuteSolRule {
                executor: self.keeper.pubkey(),
                vault: self.vault_addr(),
                config: config_pda(),
                beneficiary: *beneficiary,
                treasury: self.treasury.pubkey(),
            }
            .to_account_metas(None),
        )
    }

    fn release_sol_ix(&self, index: u8, beneficiary: &Pubkey) -> Instruction {
        Instruction::new_with_bytes(
            deadman::id(),
            &deadman::instruction::ReleaseVestedSol { index }.data(),
            deadman::accounts::ExecuteSolRule {
                executor: self.keeper.pubkey(),
                vault: self.vault_addr(),
                config: config_pda(),
                beneficiary: *beneficiary,
                treasury: self.treasury.pubkey(),
            }
            .to_account_metas(None),
        )
    }

    fn skip_ix(&self, index: u8) -> Instruction {
        Instruction::new_with_bytes(
            deadman::id(),
            &deadman::instruction::SkipRule { index }.data(),
            deadman::accounts::SkipRule {
                caller: self.keeper.pubkey(),
                vault: self.vault_addr(),
                vault_token: None,
            }
            .to_account_metas(None),
        )
    }

    fn keeper_send(&mut self, ix: Instruction) -> Result<(), String> {
        let keeper = self.keeper.insecure_clone();
        self.send(ix, &[&keeper])
    }

    fn new_mint(&mut self) -> Pubkey {
        let admin = self.admin.insecure_clone();
        CreateMint::new(&mut self.svm, &admin)
            .decimals(6)
            .send()
            .unwrap()
    }

    fn fund_token(&mut self, owner: &Pubkey, mint: &Pubkey, amount: u64) -> Pubkey {
        let admin = self.admin.insecure_clone();
        CreateAssociatedTokenAccountIdempotent::new(&mut self.svm, &admin, mint)
            .owner(owner)
            .send()
            .unwrap();
        let a = ata(owner, mint);
        if amount > 0 {
            MintTo::new(&mut self.svm, &admin, mint, &a, amount)
                .send()
                .unwrap();
        }
        a
    }

    fn token_balance(&self, k: &Pubkey) -> u64 {
        get_spl_account::<SplAccount>(&self.svm, k).unwrap().amount
    }

    fn propose_admin_ix(&self, signer: &Pubkey, new_admin: &Pubkey) -> Instruction {
        Instruction::new_with_bytes(
            deadman::id(),
            &deadman::instruction::ProposeAdmin {
                new_admin: *new_admin,
            }
            .data(),
            deadman::accounts::ProposeAdmin {
                admin: *signer,
                config: config_pda(),
            }
            .to_account_metas(None),
        )
    }

    fn accept_admin_ix(&self, signer: &Pubkey) -> Instruction {
        Instruction::new_with_bytes(
            deadman::id(),
            &deadman::instruction::AcceptAdmin {}.data(),
            deadman::accounts::AcceptAdmin {
                new_admin: *signer,
                config: config_pda(),
            }
            .to_account_metas(None),
        )
    }
}

fn plan_env(rules: Vec<RuleInput>) -> Env {
    let mut env = Env::new();
    env.init_config();
    env.create_plan(rules).unwrap();
    env
}

/// Snapshot of an account (lamports + data) for "nothing changed" checks.
fn snap(env: &Env, k: &Pubkey) -> (u64, Vec<u8>) {
    (env.lamports(k), env.data(k))
}

// =====================================================================
// Probe hypotheses H1..H11 (`qedgen probe --program programs/deadman`):
// "`<handler>` requires the caller to be the stored authority".
// Each test: a non-authority signer is rejected and changes nothing; the
// authority succeeds (positive control).
// =====================================================================

#[test]
fn h3_init_config_requires_upgrade_authority() {
    let mut env = Env::new();
    let attacker = env.attacker.insecure_clone();
    let ix = env.init_config_ix(&attacker.pubkey());
    assert!(env.send(ix, &[&attacker]).is_err());
    assert!(env.svm.get_account(&config_pda()).is_none());
    env.init_config();
    assert!(env.svm.get_account(&config_pda()).is_some());
}

#[test]
fn h7_set_config_requires_config_admin() {
    let mut env = Env::new();
    env.init_config();
    let mk = |signer: Pubkey, treasury: Pubkey| {
        Instruction::new_with_bytes(
            deadman::id(),
            &deadman::instruction::SetConfig {
                fee_bps_public: 0,
                fee_bps_private: 0,
                skr_mint: Pubkey::default(),
                fee_bps_skr: 0,
                skr_burn_bps: 0,
            }
            .data(),
            deadman::accounts::SetConfig {
                admin: signer,
                config: config_pda(),
                treasury,
                system_program: system_program::ID,
            }
            .to_account_metas(None),
        )
    };
    let attacker = env.attacker.insecure_clone();
    let before = snap(&env, &config_pda());
    assert!(env
        .send(mk(attacker.pubkey(), attacker.pubkey()), &[&attacker])
        .is_err());
    assert_eq!(snap(&env, &config_pda()), before);
    let admin = env.admin.insecure_clone();
    let t = env.treasury.pubkey();
    env.send(mk(admin.pubkey(), t), &[&admin]).unwrap();
}

#[test]
fn h10_propose_admin_requires_config_admin() {
    let mut env = Env::new();
    env.init_config();
    let attacker = env.attacker.insecure_clone();
    let before = snap(&env, &config_pda());
    let ix = env.propose_admin_ix(&attacker.pubkey(), &attacker.pubkey());
    assert!(env.send(ix, &[&attacker]).is_err());
    assert_eq!(snap(&env, &config_pda()), before);
    let admin = env.admin.insecure_clone();
    let ix = env.propose_admin_ix(&admin.pubkey(), &attacker.pubkey());
    env.send(ix, &[&admin]).unwrap();
}

#[test]
fn h11_accept_admin_requires_the_proposed_admin() {
    let mut env = Env::new();
    env.init_config();
    let attacker = env.attacker.insecure_clone();
    let (admin, next) = (env.admin.insecure_clone(), Keypair::new());
    env.svm.airdrop(&next.pubkey(), SOL).unwrap();
    let ix = env.accept_admin_ix(&attacker.pubkey());
    assert!(env.send(ix, &[&attacker]).is_err(), "nothing proposed");
    let ix = env.propose_admin_ix(&admin.pubkey(), &next.pubkey());
    env.send(ix, &[&admin]).unwrap();
    let before = snap(&env, &config_pda());
    let ix = env.accept_admin_ix(&attacker.pubkey());
    assert!(env.send(ix, &[&attacker]).is_err());
    assert_eq!(snap(&env, &config_pda()), before);
    let ix = env.accept_admin_ix(&next.pubkey());
    env.send(ix, &[&next]).unwrap();
    let acc = env.svm.get_account(&config_pda()).unwrap();
    let c = Config::try_deserialize(&mut acc.data.as_slice()).unwrap();
    assert_eq!(
        (c.admin, c.pending_admin),
        (next.pubkey(), Pubkey::default())
    );
}

#[test]
fn h2_h4_h5_h6_owner_actions_reject_another_signer() {
    let b = Keypair::new();
    let mut env = plan_env(vec![sol_rule(
        &b.pubkey(),
        10 * DAY,
        AmountMode::Percent,
        10_000,
    )]);
    env.deposit(5 * SOL);
    let vault = env.vault_addr();
    let attacker = env.attacker.insecure_clone();
    let a = attacker.pubkey();
    let before = snap(&env, &vault);

    // H2 set_guard, H4 update_plan, H5 withdraw_sol, H6 close_vault: the
    // attacker in the owner slot against the victim's vault.
    let ixs = vec![
        env.owner_action(&a, &vault, deadman::instruction::SetGuard { new_guard: a }),
        env.update_plan_ix(&a, vec![sol_rule(&a, 60, AmountMode::Percent, 10_000)]),
        env.withdraw_sol_ix(&a, SOL),
        env.close_ix(&a, &a),
        // close with the real owner key named but not signing is impossible
        // to build; also try the real rent payer as destination.
        env.close_ix(&a, &env.owner.pubkey()),
    ];
    for ix in ixs {
        assert!(env.send(ix, &[&attacker]).is_err());
        assert_eq!(snap(&env, &vault), before);
    }

    // Positive controls with the owner.
    let owner = env.owner.insecure_clone();
    let o = owner.pubkey();
    let g2 = Keypair::new().pubkey();
    let ix = env.owner_action(&o, &vault, deadman::instruction::SetGuard { new_guard: g2 });
    env.send(ix, &[&owner]).unwrap();
    assert_eq!(env.vault().guard, g2);
    let ix = env.withdraw_sol_ix(&o, SOL);
    env.send(ix, &[&owner]).unwrap();
    let ix = env.update_plan_ix(&o, vec![sol_rule(&b.pubkey(), 60, AmountMode::Fixed, 1)]);
    env.send(ix, &[&owner]).unwrap();
    let ix = env.close_ix(&o, &o);
    env.send(ix, &[&owner]).unwrap();
    assert!(env.svm.get_account(&vault).is_none_or(|a| a.lamports == 0));
}

#[test]
fn h8_withdraw_token_rejects_another_signer() {
    let b = Keypair::new();
    let mut env = plan_env(vec![sol_rule(
        &b.pubkey(),
        10 * DAY,
        AmountMode::Percent,
        10_000,
    )]);
    let vault = env.vault_addr();
    let mint = env.new_mint();
    let vault_token = env.fund_token(&vault, &mint, 1_000);
    let attacker = env.attacker.insecure_clone();
    let attacker_token = env.fund_token(&attacker.pubkey(), &mint, 0);
    let owner = env.owner.insecure_clone();
    let owner_token = env.fund_token(&owner.pubkey(), &mint, 0);
    let mk = |signer: Pubkey, dest: Pubkey| {
        Instruction::new_with_bytes(
            deadman::id(),
            &deadman::instruction::WithdrawToken { amount: 1_000 }.data(),
            deadman::accounts::WithdrawToken {
                owner: signer,
                vault,
                mint,
                vault_token,
                owner_token: dest,
                token_program: TOKEN_ID,
            }
            .to_account_metas(None),
        )
    };
    assert!(env
        .send(mk(attacker.pubkey(), attacker_token), &[&attacker])
        .is_err());
    assert_eq!(env.token_balance(&vault_token), 1_000);
    // The owner cannot route it to someone else's account either.
    assert!(env
        .send(mk(owner.pubkey(), attacker_token), &[&owner])
        .is_err());
    env.send(mk(owner.pubkey(), owner_token), &[&owner])
        .unwrap();
    assert_eq!(env.token_balance(&owner_token), 1_000);
}

#[test]
fn h9_revoke_vesting_rejects_another_signer() {
    let b = Keypair::new();
    let mut env = Env::new();
    env.init_config();
    env.create_vesting(true, vec![schedule(&b.pubkey(), 10 * SOL, 0, 100 * DAY)], 0)
        .unwrap();
    let vault = env.vault_addr();
    let attacker = env.attacker.insecure_clone();
    let ix = env.owner_action(
        &attacker.pubkey(),
        &vault,
        deadman::instruction::RevokeVesting {},
    );
    assert!(env.send(ix, &[&attacker]).is_err());
    assert_eq!(env.vault().revoked_at, 0);
    let owner = env.owner.insecure_clone();
    let ix = env.owner_action(
        &owner.pubkey(),
        &vault,
        deadman::instruction::RevokeVesting {},
    );
    env.send(ix, &[&owner]).unwrap();
    assert_ne!(env.vault().revoked_at, 0);
}

/// Builds a legacy-layout account (current discriminator, other size).
fn legacy_bytes(owner: &Pubkey, plan_id: u16, len: usize) -> Vec<u8> {
    let mut d = vec![0u8; len];
    d[..8].copy_from_slice(Vault::DISCRIMINATOR);
    d[8..40].copy_from_slice(owner.as_ref());
    d[40..42].copy_from_slice(&plan_id.to_le_bytes());
    d
}

fn put(env: &mut Env, addr: &Pubkey, data: Vec<u8>, lamports: u64) {
    // Any fetched account gives the SDK's Account type to fill in.
    let mut acc = env.svm.get_account(&env.keeper.pubkey()).unwrap();
    acc.lamports = lamports;
    acc.data = data;
    acc.owner = deadman::id();
    env.svm.set_account(*addr, acc).unwrap();
}

fn recover_ix(owner: &Pubkey, legacy: &Pubkey, plan_id: u16) -> Instruction {
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

#[test]
fn h1_recover_legacy_vault_pays_only_the_recorded_owner() {
    let mut env = Env::new();
    let victim = env.owner.pubkey();
    let attacker = env.attacker.insecure_clone();
    let a = attacker.pubkey();

    // Victim's legacy plan at its own PDA.
    let legacy = vault_pda(&victim, 7);
    put(&mut env, &legacy, legacy_bytes(&victim, 7, 958), 5 * SOL);
    // Attacker names the victim's address: PDA seeds use the signer.
    assert!(env.send(recover_ix(&a, &legacy, 7), &[&attacker]).is_err());
    assert_eq!(env.lamports(&legacy), 5 * SOL);

    // A legacy account at the attacker's own address that records the
    // victim as owner is refused by the owner-bytes check, so a mismatch
    // between address and recorded owner never pays the signer.
    let own = vault_pda(&a, 7);
    put(&mut env, &own, legacy_bytes(&victim, 7, 958), SOL);
    assert!(env.send(recover_ix(&a, &own, 7), &[&attacker]).is_err());

    // A current-layout account is never "legacy".
    let cur = vault_pda(&victim, 8);
    put(&mut env, &cur, legacy_bytes(&victim, 8, Vault::SPACE), SOL);
    let owner = env.owner.insecure_clone();
    assert!(env.send(recover_ix(&victim, &cur, 8), &[&owner]).is_err());

    // Positive control.
    let before = env.lamports(&victim);
    let keeper = env.keeper.insecure_clone();
    env.send(recover_ix(&victim, &legacy, 7), &[&keeper, &owner])
        .unwrap();
    assert_eq!(env.lamports(&victim), before + 5 * SOL);
}

// =====================================================================
// Probe clusters.
// c-b36edecf account_type_tag_check: beneficiary / treasury / rent_payer
// are UncheckedAccount. (c-1a18555d, init_if_needed on Subscribe, went
// away with the subscription.)
// =====================================================================

#[test]
fn cluster_unchecked_accounts_are_pinned() {
    let b = Keypair::new();
    let mut env = plan_env(vec![sol_rule(&b.pubkey(), 60, AmountMode::Percent, 10_000)]);
    env.deposit(10 * SOL);
    env.advance(120);
    let vault = env.vault_addr();
    let before = snap(&env, &vault);
    let a = env.attacker.pubkey();

    // Wrong beneficiary.
    let ix = env.execute_sol_ix(0, &a);
    assert!(env.keeper_send(ix).is_err());
    // Wrong treasury.
    let mut ix = env.execute_sol_ix(0, &b.pubkey());
    ix.accounts[4].pubkey = a;
    assert!(env.keeper_send(ix).is_err());
    assert_eq!(snap(&env, &vault), before);

    // Wrong rent payer on close.
    let owner = env.owner.insecure_clone();
    let ix = env.close_ix(&owner.pubkey(), &a);
    assert!(env.send(ix, &[&owner]).is_err());
    assert_eq!(snap(&env, &vault), before);

    env.keeper_send(env.execute_sol_ix(0, &b.pubkey())).unwrap();
}

// =====================================================================
// Spec properties against the real program (LiteSVM, random sequences).
// =====================================================================

/// Sum of the shares set aside for skipped, still unpaid SOL tiers.
fn reserved_sol(v: &Vault) -> u64 {
    v.rules
        .iter()
        .filter(|r| r.mint.is_none() && r.executed_at == 0 && r.skipped_at != 0)
        .map(|r| r.reserved)
        .sum()
}

/// Inheritance plan: random check-ins, lockdowns, deposits, payouts, skips,
/// owner withdrawals (never into reserves) and plan edits.
///
/// Spec properties checked after every step:
/// - sol_conservation: lamports only move between the tracked accounts;
/// - reserves_backed: reserves of skipped tiers <= withdrawable SOL;
/// - executed_is_final: a paid tier keeps executed_at and paid forever,
///   a skipped tier keeps skipped_at and its reserve until it pays;
/// - fee cap: treasury gets <= MAX_FEE_BPS of every payout;
/// - lock_monotone: only `unlock` can lower locked_until (not used here);
/// - rent: the vault never drops below its rent reserve;
/// - failed transactions change nothing.
#[test]
fn spec_inheritance_sequences_hold_on_the_real_program() {
    let mut total = [0u32; 10];
    for seed in 0..24u64 {
        let h = run_inheritance_sequence(seed, 70);
        total.iter_mut().zip(h).for_each(|(t, x)| *t += x);
    }
    eprintln!("inheritance ops that succeeded, by op: {total:?}");
    // Not vacuous: payouts (2,3), skips (4), guard check-ins (6),
    // withdrawals (8) and edits (9) all happened.
    for op in [2, 4, 5, 6, 7, 8, 9] {
        assert!(total[op] > 0, "op {op} never succeeded");
    }
}

fn run_inheritance_sequence(seed: u64, steps: usize) -> [u32; 10] {
    let mut hits = [0u32; 10];
    let mut rng = Rng(seed.wrapping_mul(0x2545_F491_4F6C_DD1D) ^ 0xDEAD);
    let mut env = Env::new();
    env.init_config();
    // Beneficiaries: some funded (can receive anything), one fresh (dust
    // payouts fail BeneficiaryCannotReceive and must be skipped).
    let bens: Vec<Keypair> = (0..4).map(|_| Keypair::new()).collect();
    for (i, b) in bens.iter().enumerate() {
        if i != 3 {
            env.svm.airdrop(&b.pubkey(), SOL).unwrap();
        }
    }
    let make_rules = |rng: &mut Rng| -> Vec<RuleInput> {
        let n = 1 + rng.below(4) as usize;
        let mut after = 60i64;
        (0..n)
            .map(|_| {
                after += rng.range_i64(0, 20 * DAY);
                let b = &bens[rng.below(4) as usize];
                if rng.below(2) == 0 {
                    sol_rule(
                        &b.pubkey(),
                        after,
                        AmountMode::Percent,
                        1 + rng.below(10_000),
                    )
                } else {
                    sol_rule(
                        &b.pubkey(),
                        after,
                        AmountMode::Fixed,
                        1 + rng.below(3 * SOL),
                    )
                }
            })
            .collect()
    };
    let rules = make_rules(&mut rng);
    env.create_plan(rules).unwrap();
    env.deposit(rng.below(5 * SOL));

    let vault = env.vault_addr();
    let owner = env.owner.insecure_clone();
    let guard = env.guard.insecure_clone();
    let treasury = env.treasury.pubkey();
    let mut tracked: Vec<Pubkey> = vec![vault, treasury, owner.pubkey(), guard.pubkey()];
    tracked.extend(bens.iter().map(|b| b.pubkey()));
    let total = |env: &Env| tracked.iter().map(|k| env.lamports(k)).sum::<u64>();

    for step in 0..steps {
        let pre_v = env.vault();
        let pre_snap = snap(&env, &vault);
        let pre_total = total(&env);
        let pre_lock = pre_v.locked_until;
        let pre_treasury = env.lamports(&treasury);
        let mut deposited = 0u64;
        // Bias towards time passing and payouts so tiers fall due.
        let op = match rng.below(18) {
            x if x >= 10 => [0, 2, 4][(x % 3) as usize],
            x => x,
        };
        let ctx = format!("seed {seed} step {step} op {op}");
        let res = match op {
            0 => {
                env.advance(rng.range_i64(0, 25 * DAY));
                Ok(())
            }
            1 => {
                deposited = rng.below(2 * SOL);
                env.deposit(deposited);
                Ok(())
            }
            2 | 3 => {
                let i = rng.below(pre_v.rules.len() as u64 + 1) as u8;
                let b = pre_v
                    .rules
                    .get(i as usize)
                    .map_or(bens[0].pubkey(), |r| r.beneficiary);
                env.keeper_send(env.execute_sol_ix(i, &b))
            }
            4 => {
                let i = rng.below(pre_v.rules.len() as u64 + 1) as u8;
                env.keeper_send(env.skip_ix(i))
            }
            5 => {
                let ix = env.signer_ix(&owner.pubkey(), deadman::instruction::Pulse {}, false);
                env.send_kp(ix, &owner)
            }
            6 => {
                let ix = env.signer_ix(&guard.pubkey(), deadman::instruction::Pulse {}, false);
                env.send_kp(ix, &guard)
            }
            7 => {
                let ix = env.signer_ix(&guard.pubkey(), deadman::instruction::Lockdown {}, true);
                env.send_kp(ix, &guard)
            }
            8 => {
                // Owner withdraws only SOL not reserved for skipped tiers
                // (the program refuses more; see the separate test).
                let free = env.withdrawable().saturating_sub(reserved_sol(&pre_v));
                let amt = if free == 0 { 1 } else { rng.below(free + 1) };
                let ix = env.withdraw_sol_ix(&owner.pubkey(), amt);
                env.send_kp(ix, &owner)
            }
            _ => {
                let rules = make_rules(&mut rng);
                let ix = env.update_plan_ix(&owner.pubkey(), rules);
                env.send_kp(ix, &owner)
            }
        };

        let post_v = env.vault();
        if res.is_ok() {
            hits[op as usize] += 1;
        }
        // Conservation (keeper pays every network fee).
        assert_eq!(total(&env), pre_total + deposited, "{ctx}: lamports leaked");
        if res.is_err() {
            assert_eq!(
                snap(&env, &vault),
                pre_snap,
                "{ctx}: failed tx changed the vault"
            );
        }
        // Rent reserve.
        let acc = env.svm.get_account(&vault).unwrap();
        assert!(
            acc.lamports >= post_v.rent_paid
                && acc.lamports >= env.svm.minimum_balance_for_rent_exemption(acc.data.len()),
            "{ctx}: vault below rent"
        );
        // Reserves backed.
        assert!(
            reserved_sol(&post_v) <= env.withdrawable(),
            "{ctx}: reserves {} > withdrawable {}",
            reserved_sol(&post_v),
            env.withdrawable()
        );
        // History is final.
        for r in pre_v
            .rules
            .iter()
            .filter(|r| r.executed_at != 0 || r.skipped_at != 0)
        {
            let kept = post_v.rules.iter().any(|q| {
                q.beneficiary == r.beneficiary
                    && q.after_secs == r.after_secs
                    && q.amount == r.amount
                    && q.skipped_at == r.skipped_at
                    && q.reserved == r.reserved
                    && (r.executed_at == 0 || (q.executed_at == r.executed_at && q.paid == r.paid))
            });
            assert!(kept, "{ctx}: history tier changed or vanished: {r:?}");
        }
        assert!(
            post_v.rules.iter().filter(|r| r.executed_at != 0).count()
                >= pre_v.rules.iter().filter(|r| r.executed_at != 0).count(),
            "{ctx}: a paid tier became pending"
        );
        // Fee cap on payouts.
        if res.is_ok() && (op == 2 || op == 3) {
            let fee = env.lamports(&treasury) - pre_treasury;
            let paid = post_v
                .rules
                .iter()
                .zip(pre_v.rules.iter())
                .find(|(q, r)| q.executed_at != 0 && r.executed_at == 0)
                .map(|(q, _)| q.paid)
                .expect("a tier paid");
            let gross = paid + fee;
            assert!(
                u128::from(fee) * 10_000 <= u128::from(gross) * u128::from(FEE_PUBLIC),
                "{ctx}: fee {fee} above cap on {gross}"
            );
        }
        // Lock monotone (no unlock in this sequence).
        assert!(post_v.locked_until >= pre_lock, "{ctx}: lock shortened");
    }
    hits
}

/// Vesting plan: random releases, deposits, owner withdrawals, revocation
/// and lockdowns. Checks vesting_within_cap, that a successful owner
/// withdrawal never dips into commitments, that every release pays exactly
/// what vested (or what is there), and conservation.
#[test]
fn spec_vesting_sequences_hold_on_the_real_program() {
    let mut total = [0u32; 7];
    for seed in 0..24u64 {
        let h = run_vesting_sequence(seed, 60);
        total.iter_mut().zip(h).for_each(|(t, x)| *t += x);
    }
    eprintln!("vesting ops that succeeded, by op: {total:?}");
    for op in [2, 4, 5, 6] {
        assert!(total[op] > 0, "op {op} never succeeded");
    }
}

fn run_vesting_sequence(seed: u64, steps: usize) -> [u32; 7] {
    let mut hits = [0u32; 7];
    let mut rng = Rng(seed ^ 0x005E_ED0F_7E57);
    let mut env = Env::new();
    env.init_config();
    let bens: Vec<Keypair> = (0..3).map(|_| Keypair::new()).collect();
    for b in &bens {
        env.svm.airdrop(&b.pubkey(), SOL).unwrap();
    }
    let n = 1 + rng.below(3) as usize;
    let mut min_dur = i64::MAX;
    let schedules: Vec<VestingInput> = (0..n)
        .map(|i| {
            let dur = rng.range_i64(DAY, 200 * DAY);
            min_dur = min_dur.min(dur);
            let cliff = rng.range_i64(0, dur);
            schedule(&bens[i].pubkey(), 1 + rng.below(5 * SOL), cliff, dur)
        })
        .collect();
    let period = if rng.below(2) == 0 {
        0
    } else {
        rng.range_i64(60, min_dur)
    };
    env.create_vesting(rng.below(2) == 0, schedules, period)
        .unwrap();
    env.deposit(rng.below(8 * SOL));

    let vault = env.vault_addr();
    let owner = env.owner.insecure_clone();
    let guard = env.guard.insecure_clone();
    let treasury = env.treasury.pubkey();
    let mut tracked: Vec<Pubkey> = vec![vault, treasury, owner.pubkey(), guard.pubkey()];
    tracked.extend(bens.iter().map(|b| b.pubkey()));
    let total = |env: &Env| tracked.iter().map(|k| env.lamports(k)).sum::<u64>();

    for step in 0..steps {
        let pre_v = env.vault();
        let pre_snap = snap(&env, &vault);
        let pre_total = total(&env);
        let pre_w = env.withdrawable();
        let now = env.now();
        let mut deposited = 0;
        let op = rng.below(7);
        let ctx = format!("seed {seed} step {step} op {op}");
        let mut released_idx = None;
        let res = match op {
            0 => {
                env.advance(rng.range_i64(0, 20 * DAY));
                Ok(())
            }
            1 => {
                deposited = rng.below(3 * SOL);
                env.deposit(deposited);
                Ok(())
            }
            2 | 3 => {
                let i = rng.below(pre_v.rules.len() as u64) as usize;
                released_idx = Some(i);
                env.keeper_send(env.release_sol_ix(i as u8, &pre_v.rules[i].beneficiary))
            }
            4 => {
                let amt = rng.below(pre_w + 1).max(1);
                let ix = env.withdraw_sol_ix(&owner.pubkey(), amt);
                env.send_kp(ix, &owner)
            }
            5 => {
                let ix = env.owner_action(
                    &owner.pubkey(),
                    &vault,
                    deadman::instruction::RevokeVesting {},
                );
                env.send_kp(ix, &owner)
            }
            _ => {
                let ix = env.signer_ix(&guard.pubkey(), deadman::instruction::Lockdown {}, true);
                env.send_kp(ix, &guard)
            }
        };
        let post_v = env.vault();
        if res.is_ok() {
            hits[op as usize] += 1;
        }
        assert_eq!(total(&env), pre_total + deposited, "{ctx}: lamports leaked");
        if res.is_err() {
            assert_eq!(
                snap(&env, &vault),
                pre_snap,
                "{ctx}: failed tx changed the vault"
            );
        }
        for i in 0..post_v.rules.len() {
            let cap = post_v.vesting_cap(i).unwrap();
            assert!(post_v.rules[i].released <= cap, "{ctx}: released above cap");
            assert!(cap <= post_v.rules[i].amount, "{ctx}: cap above total");
            assert!(post_v.rules[i].released >= pre_v.rules[i].released, "{ctx}");
        }
        if op == 4 && res.is_ok() {
            assert!(
                env.withdrawable() >= post_v.committed(None).unwrap(),
                "{ctx}: withdrawal dipped into commitments"
            );
        }
        if let (Some(i), Ok(())) = (released_idx, &res) {
            let due = pre_v.vested(i, now).unwrap() - pre_v.rules[i].released;
            let gross = post_v.rules[i].released - pre_v.rules[i].released;
            assert_eq!(gross, due.min(pre_w), "{ctx}: release amount");
        }
    }
    hits
}

/// FUNDS-1 / QG-I1 (fixed): a skipped tier's reserve is kept from the
/// owner's withdrawals, so `reserves_backed` holds for `withdraw_sol` too.
#[test]
fn owner_cannot_withdraw_a_skipped_tiers_reserve() {
    let fresh = Keypair::new(); // unfunded: dust payouts cannot land
    let mut env = plan_env(vec![sol_rule(
        &fresh.pubkey(),
        60,
        AmountMode::Fixed,
        1_000,
    )]);
    env.deposit(10 * SOL);
    env.advance(60 + GRACE + 2);
    assert!(env
        .keeper_send(env.execute_sol_ix(0, &fresh.pubkey()))
        .is_err());
    env.keeper_send(env.skip_ix(0)).unwrap();
    assert_eq!(reserved_sol(&env.vault()), 1_000);
    let all = env.withdrawable();
    let owner = env.owner.insecure_clone();
    let ix = env.withdraw_sol_ix(&owner.pubkey(), all);
    assert!(env
        .send_kp(ix, &owner)
        .unwrap_err()
        .contains("FundsCommitted"));
    let ix = env.withdraw_sol_ix(&owner.pubkey(), all - 1_000);
    env.send_kp(ix, &owner).unwrap();
    assert_eq!(env.withdrawable(), 1_000);
    assert_eq!(reserved_sol(&env.vault()), 1_000, "reserve still backed");
}

// =====================================================================
// Pure-function properties (real crate code, random inputs).
// =====================================================================

fn blank_vault(kind: PlanKind) -> Vault {
    Vault {
        owner: Pubkey::new_unique(),
        plan_id: 0,
        guard: Pubkey::new_unique(),
        guardian: None,
        _reserved_interval: [0; 8],
        lock_secs: LOCK,
        skip_grace_secs: GRACE,
        last_pulse: 0,
        owner_last_seen: 0,
        locked_until: 0,
        guardian_ready_at: 0,
        total_pulses: 0,
        streak: 0,
        best_streak: 0,
        kind,
        start_at: 0,
        revocable: true,
        revoked_at: 0,
        rent_payer: Pubkey::new_unique(),
        rent_paid: 0,
        rules: vec![],
        label: String::new(),
        bump: 255,
        stipend_paid: 0,
        vest_period_secs: 0,
        _reserved: [0; 55],
    }
}

fn vest_rule(amount: u64, cliff: i64, duration: i64) -> Rule {
    Rule {
        beneficiary: Pubkey::new_unique(),
        rail: Rail::Solana,
        after_secs: cliff,
        mint: None,
        mode: AmountMode::Fixed,
        amount,
        executed_at: 0,
        paid: 0,
        skipped_at: 0,
        reserved: 0,
        duration_secs: duration,
        released: 0,
    }
}

#[test]
fn pure_split_fee_conserves_and_caps() {
    let mut rng = Rng(1);
    for _ in 0..200_000 {
        let gross = match rng.below(3) {
            0 => rng.next(),
            1 => rng.below(10_000),
            _ => u64::MAX - rng.below(10_000),
        };
        let bps = rng.below(501) as u16;
        let (net, fee) = split_fee(gross, bps).unwrap();
        assert_eq!(net + fee, gross);
        assert_eq!(
            u128::from(fee),
            u128::from(gross) * u128::from(bps) / 10_000
        );
    }
}

#[test]
fn pure_rule_gross_never_exceeds_available() {
    let mut rng = Rng(2);
    for _ in 0..200_000 {
        let available = rng.next() >> rng.below(64);
        let pct = rng.below(2) == 0;
        let r = Rule {
            mode: if pct {
                AmountMode::Percent
            } else {
                AmountMode::Fixed
            },
            amount: if pct {
                1 + rng.below(10_000)
            } else {
                rng.next() >> rng.below(64)
            },
            ..vest_rule(0, 0, 0)
        };
        let g = rule_gross(&r, available).unwrap();
        assert!(g <= available);
    }
}

#[test]
fn pure_payout_and_skip_never_take_other_reserves() {
    let mut rng = Rng(3);
    for _ in 0..20_000 {
        let mut v = blank_vault(PlanKind::Inheritance);
        let n = 1 + rng.below(MAX_RULES as u64) as usize;
        let balance = rng.below(100 * SOL);
        let mut left = balance;
        for _ in 0..n {
            let mut r = vest_rule(0, 60, 0);
            r.mode = if rng.below(2) == 0 {
                AmountMode::Percent
            } else {
                AmountMode::Fixed
            };
            r.amount = if r.mode == AmountMode::Percent {
                1 + rng.below(10_000)
            } else {
                1 + rng.below(50 * SOL)
            };
            match rng.below(3) {
                0 => {}
                1 => {
                    r.skipped_at = 1;
                    r.reserved = rng.below(left + 1);
                    left -= r.reserved;
                }
                _ => r.executed_at = 1,
            }
            v.rules.push(r);
        }
        for i in 0..n {
            let g = v.payout_gross(i, balance).unwrap();
            assert!(g <= balance);
            let r = &v.rules[i];
            if !(r.skipped_at != 0 && r.reserved > 0) {
                let others = v.reserved_for(None, i).unwrap();
                assert!(
                    g <= balance - others,
                    "tier {i} takes another tier's reserve"
                );
            }
        }
    }
}

#[test]
fn pure_vesting_is_monotone_capped_and_exact_at_the_end() {
    let mut rng = Rng(4);
    for _ in 0..20_000 {
        let mut v = blank_vault(PlanKind::Vesting);
        let dur = rng.range_i64(1, deadman::MAX_VEST_SECS);
        let cliff = rng.range_i64(0, dur);
        let amount = if rng.below(4) == 0 {
            u64::MAX
        } else {
            (rng.next() >> rng.below(64)).max(1)
        };
        v.start_at = rng.range_i64(0, 2_000_000_000);
        v.vest_period_secs = if rng.below(2) == 0 {
            0
        } else {
            rng.range_i64(60, dur.max(60)).min(dur)
        };
        if v.vest_period_secs != 0 && v.vest_period_secs < 60 {
            v.vest_period_secs = 0;
        }
        v.rules.push(vest_rule(amount, cliff, dur));
        let mut last = 0u64;
        let mut t = v.start_at - 10;
        for _ in 0..40 {
            t += rng.range_i64(0, dur / 8 + 1);
            let x = v.vested(0, t).unwrap();
            assert!(x >= last && x <= amount, "not monotone or above total");
            if t - v.start_at < cliff {
                assert_eq!(x, 0);
            }
            last = x;
        }
        assert_eq!(v.vested(0, v.start_at + dur).unwrap(), amount);
        // Stepped never ahead of continuous.
        let p = v.vest_period_secs;
        v.vest_period_secs = 0;
        let cont = v.vested(0, t).unwrap();
        v.vest_period_secs = p;
        assert!(v.vested(0, t).unwrap() <= cont);
        // Revocation freezes the cap at what had vested.
        let rv = v.start_at + rng.range_i64(0, dur);
        v.revoked_at = rv;
        assert_eq!(v.vesting_cap(0).unwrap(), v.vested(0, rv).unwrap());
        assert_eq!(v.vested(0, rv + dur).unwrap(), v.vesting_cap(0).unwrap());
    }
}

#[test]
fn pure_apply_policy_keeps_history_and_bounds_rules() {
    let mut rng = Rng(5);
    for _ in 0..5_000 {
        let mut v = blank_vault(PlanKind::Inheritance);
        v.stipend_paid = rng.below(256) as u8;
        let stipends = v.stipend_paid;
        let key = Pubkey::new_unique();
        let k = rng.below(MAX_RULES as u64) as usize;
        for j in 0..k {
            let mut r = vest_rule(1 + j as u64, 60, 0);
            match rng.below(3) {
                0 => {}
                1 => {
                    r.skipped_at = 5;
                    r.reserved = 7;
                }
                _ => {
                    r.executed_at = 9;
                    r.paid = 11;
                }
            }
            v.rules.push(r);
        }
        let history: Vec<Rule> = v
            .rules
            .iter()
            .filter(|r| r.executed_at != 0 || r.skipped_at != 0)
            .copied()
            .collect();
        // ON-L1: each kept tier's stipend bit moves with it; new tiers and
        // dropped pending tiers leave no bit behind.
        let expected_bits = v
            .rules
            .iter()
            .enumerate()
            .filter(|(_, r)| r.executed_at != 0 || r.skipped_at != 0)
            .enumerate()
            .fold(0u8, |acc, (j, (i, _))| acc | (((stipends >> i) & 1) << j));
        let m = 1 + rng.below(MAX_RULES as u64) as usize;
        let rules: Vec<RuleInput> = (0..m)
            .map(|j| sol_rule(&Pubkey::new_unique(), 60 + j as i64, AmountMode::Fixed, 1))
            .collect();
        let res = v.apply_policy(&key, LOCK, GRACE, &rules, None);
        if history.len() + m <= MAX_RULES {
            res.unwrap();
            assert_eq!(&v.rules[..history.len()], &history[..]);
            assert!(v.rules[history.len()..]
                .iter()
                .all(|r| r.executed_at == 0 && r.skipped_at == 0 && r.reserved == 0));
            assert_eq!(v.stipend_paid, expected_bits);
        } else {
            assert!(res.is_err());
            assert_eq!(v.stipend_paid, stipends);
        }
        assert!(v.rules.len() <= MAX_RULES);
    }
}

#[test]
fn pure_fee_picks_the_skr_rate_and_burn_split_conserves() {
    let mut rng = Rng(6);
    for _ in 0..100_000 {
        let skr = Pubkey::new_unique();
        let cfg = Config {
            admin: Pubkey::new_unique(),
            treasury: Pubkey::new_unique(),
            fee_bps_public: rng.below(501) as u16,
            fee_bps_private: rng.below(501) as u16,
            bump: 0,
            skr_mint: if rng.below(8) == 0 {
                Pubkey::default()
            } else {
                skr
            },
            fee_bps_skr: rng.below(501) as u16,
            skr_burn_bps: rng.below(10_001) as u16,
            pending_admin: Pubkey::default(),
            _reserved: [0; 64],
        };
        let rail = [Rail::Solana, Rail::Cloak, Rail::Zcash][rng.below(3) as usize];
        let rail_bps = match rail {
            Rail::Solana => cfg.fee_bps_public,
            _ => cfg.fee_bps_private,
        };
        let other = Pubkey::new_unique();
        let is_skr = cfg.skr_mint != Pubkey::default();
        assert_eq!(cfg.fee_bps(rail, None), rail_bps);
        assert_eq!(cfg.fee_bps(rail, Some(other)), rail_bps);
        assert_eq!(cfg.fee_bps(rail, Some(Pubkey::default())), rail_bps);
        assert_eq!(
            cfg.fee_bps(rail, Some(skr)),
            if is_skr { cfg.fee_bps_skr } else { rail_bps }
        );
        let fee = rng.next();
        let (burned, rest) = cfg.split_burn(fee, Some(skr)).unwrap();
        assert_eq!(burned + rest, fee);
        if is_skr {
            assert_eq!(
                u128::from(burned),
                u128::from(fee) * u128::from(cfg.skr_burn_bps) / 10_000
            );
        } else {
            assert_eq!(burned, 0);
        }
        assert_eq!(cfg.split_burn(fee, Some(other)).unwrap(), (0, fee));
        assert_eq!(cfg.split_burn(fee, None).unwrap(), (0, fee));
    }
}
