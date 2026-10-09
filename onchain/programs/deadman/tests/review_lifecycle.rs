//! Review lane "lifecycle": vault lifecycle and authority (create_plan,
//! update_plan, set_guard, pulse, lockdown/unlock, revoke, close_vault,
//! recover_legacy_vault). Loads target/deploy/deadman.so like test_deadman.rs.
//!
//! Run: cd onchain && cargo test -p deadman --test review_lifecycle
//! LC-I1 and LC-I2 are fixed; their tests run by default.

use {
    anchor_lang::{
        prelude::Pubkey,
        solana_program::{clock::Clock, instruction::Instruction, system_program},
        AccountDeserialize, AnchorSerialize, Discriminator, InstructionData, ToAccountMetas,
    },
    anchor_spl::associated_token::get_associated_token_address_with_program_id,
    deadman::{AmountMode, Rail, RuleInput, Vault, VestingInput, CONFIG_SEED, VAULT_SEED},
    litesvm::LiteSVM,
    litesvm_token::{CreateAssociatedTokenAccountIdempotent, CreateMint, MintTo, TOKEN_ID},
    solana_keypair::Keypair,
    solana_message::{Message, VersionedMessage},
    solana_signer::Signer,
    solana_transaction::versioned::VersionedTransaction,
};

const SOL: u64 = 1_000_000_000;
const DAY: i64 = 86_400;
const LOCK: i64 = 3 * DAY;
const GRACE: i64 = 30 * DAY;

fn vault_pda(owner: &Pubkey, plan_id: u16) -> Pubkey {
    Pubkey::find_program_address(
        &[VAULT_SEED, owner.as_ref(), &plan_id.to_le_bytes()],
        &deadman::id(),
    )
    .0
}

fn config_pda() -> Pubkey {
    Pubkey::find_program_address(&[CONFIG_SEED], &deadman::id()).0
}

fn program_data_pda() -> Pubkey {
    Pubkey::find_program_address(
        &[deadman::id().as_ref()],
        &anchor_lang::solana_program::bpf_loader_upgradeable::ID,
    )
    .0
}

fn ata(owner: &Pubkey, mint: &Pubkey) -> Pubkey {
    get_associated_token_address_with_program_id(owner, mint, &TOKEN_ID)
}

fn all_to(b: &Pubkey) -> Vec<RuleInput> {
    vec![RuleInput {
        beneficiary: *b,
        rail: Rail::Solana,
        after_secs: 10 * DAY,
        mint: None,
        mode: AmountMode::Percent,
        amount: 10_000,
    }]
}

struct Env {
    svm: LiteSVM,
    admin: Keypair,
    treasury: Keypair,
    owner: Keypair,
    guard: Keypair,
    keeper: Keypair,
    plan: u16,
}

impl Env {
    fn new() -> Self {
        let mut svm = LiteSVM::new();
        let bytes = include_bytes!(concat!(
            env!("CARGO_TARGET_TMPDIR"),
            "/../deploy/deadman.so"
        ));
        svm.add_program(deadman::id(), bytes).unwrap();
        let (admin, treasury, owner, guard, keeper) = (
            Keypair::new(),
            Keypair::new(),
            Keypair::new(),
            Keypair::new(),
            Keypair::new(),
        );
        for k in [&admin, &treasury, &owner, &guard, &keeper] {
            svm.airdrop(&k.pubkey(), 100 * SOL).unwrap();
        }
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
        let admin = env.admin.insecure_clone();
        let ix = Instruction::new_with_bytes(
            deadman::id(),
            &deadman::instruction::InitConfig {
                skr_mint: Pubkey::default(),
            }
            .data(),
            deadman::accounts::InitConfig {
                admin: admin.pubkey(),
                config: config_pda(),
                treasury: env.treasury.pubkey(),
                program: deadman::id(),
                program_data: program_data_pda(),
                system_program: system_program::ID,
            }
            .to_account_metas(None),
        );
        env.send(ix, &[&admin]).unwrap();
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

    fn create_plan_ix(&self, payer: &Pubkey, rules: Vec<RuleInput>) -> Instruction {
        Instruction::new_with_bytes(
            deadman::id(),
            &deadman::instruction::CreatePlan {
                plan_id: self.plan,
                label: "Plan".to_string(),
                guard: self.guard.pubkey(),
                lock_secs: LOCK,
                skip_grace_secs: GRACE,
                rules,
            }
            .data(),
            deadman::accounts::CreateVault {
                owner: self.owner.pubkey(),
                payer: *payer,
                vault: self.vault_addr(),
                system_program: system_program::ID,
            }
            .to_account_metas(None),
        )
    }

    fn create_plan(&mut self, rules: Vec<RuleInput>) -> Result<u64, String> {
        let ix = self.create_plan_ix(&self.owner.pubkey(), rules);
        let owner = self.owner.insecure_clone();
        self.send(ix, &[&owner])
    }

    fn create_vesting(&mut self, start_at: i64, b: &Pubkey, total: u64) -> Result<u64, String> {
        let ix = Instruction::new_with_bytes(
            deadman::id(),
            &deadman::instruction::CreateVesting {
                plan_id: self.plan,
                label: "Vesting".to_string(),
                guard: self.guard.pubkey(),
                lock_secs: LOCK,
                start_at,
                revocable: true,
                schedules: vec![VestingInput {
                    beneficiary: *b,
                    rail: Rail::Solana,
                    mint: None,
                    total,
                    cliff_secs: 30 * DAY,
                    duration_secs: 100 * DAY,
                }],
                period_secs: 0,
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

    /// An `OwnerAction` instruction with `signer` in the owner slot.
    fn owner_ix_as<T: InstructionData>(&self, signer: &Pubkey, data: T) -> Instruction {
        Instruction::new_with_bytes(
            deadman::id(),
            &data.data(),
            deadman::accounts::OwnerAction {
                owner: *signer,
                vault: self.vault_addr(),
            }
            .to_account_metas(None),
        )
    }

    fn update_plan_ix(
        &self,
        signer: &Pubkey,
        rules: Vec<RuleInput>,
        guardian: Option<Pubkey>,
    ) -> Instruction {
        self.owner_ix_as(
            signer,
            deadman::instruction::UpdatePlan {
                label: "Updated".to_string(),
                lock_secs: LOCK,
                skip_grace_secs: GRACE,
                rules,
                guardian,
            },
        )
    }

    fn update_plan(
        &mut self,
        rules: Vec<RuleInput>,
        guardian: Option<Pubkey>,
    ) -> Result<u64, String> {
        let ix = self.update_plan_ix(&self.owner.pubkey(), rules, guardian);
        let owner = self.owner.insecure_clone();
        self.send(ix, &[&owner])
    }

    fn set_guard(&mut self, new_guard: Pubkey) -> Result<u64, String> {
        let ix = self.owner_ix_as(
            &self.owner.pubkey(),
            deadman::instruction::SetGuard { new_guard },
        );
        let owner = self.owner.insecure_clone();
        self.send(ix, &[&owner])
    }

    fn signer_ix<T: InstructionData>(
        &self,
        signer: &Pubkey,
        data: T,
        lockdown: bool,
    ) -> Instruction {
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
        Instruction::new_with_bytes(deadman::id(), &data.data(), metas)
    }

    fn pulse(&mut self, signer: &Keypair) -> Result<u64, String> {
        let ix = self.signer_ix(&signer.pubkey(), deadman::instruction::Pulse {}, false);
        self.send(ix, &[signer])
    }

    fn lockdown(&mut self, signer: &Keypair) -> Result<u64, String> {
        let ix = self.signer_ix(&signer.pubkey(), deadman::instruction::Lockdown {}, true);
        self.send(ix, &[signer])
    }

    fn unlock_ix(&self, owner: &Pubkey, guardian: &Pubkey) -> Instruction {
        Instruction::new_with_bytes(
            deadman::id(),
            &deadman::instruction::Unlock {}.data(),
            deadman::accounts::Unlock {
                owner: *owner,
                guardian: *guardian,
                vault: self.vault_addr(),
            }
            .to_account_metas(None),
        )
    }

    fn close_ix_as(&self, owner: &Pubkey, rent_payer: &Pubkey) -> Instruction {
        Instruction::new_with_bytes(
            deadman::id(),
            &deadman::instruction::CloseVault {}.data(),
            deadman::accounts::CloseVault {
                owner: *owner,
                vault: self.vault_addr(),
                rent_payer: *rent_payer,
            }
            .to_account_metas(None),
        )
    }

    fn close(&mut self) -> Result<u64, String> {
        let me = self.owner.pubkey();
        let ix = self.close_ix_as(&me, &me);
        let owner = self.owner.insecure_clone();
        self.send(ix, &[&owner])
    }

    fn withdraw_sol_ix(&self, owner: &Pubkey, amount: u64) -> Instruction {
        Instruction::new_with_bytes(
            deadman::id(),
            &deadman::instruction::WithdrawSol { amount }.data(),
            deadman::accounts::WithdrawSol {
                owner: *owner,
                vault: self.vault_addr(),
            }
            .to_account_metas(None),
        )
    }

    fn execute_sol(&mut self, index: u8, beneficiary: &Pubkey) -> Result<u64, String> {
        let ix = Instruction::new_with_bytes(
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
        );
        let keeper = self.keeper.insecure_clone();
        self.send(ix, &[&keeper])
    }

    fn put_account(&mut self, address: &Pubkey, data: Vec<u8>, owner: Pubkey, lamports: u64) {
        let mut acc = self.svm.get_account(&self.owner.pubkey()).unwrap();
        acc.lamports = lamports;
        acc.data = data;
        acc.owner = owner;
        self.svm.set_account(*address, acc).unwrap();
    }
}

fn funded(svm: &mut LiteSVM) -> Keypair {
    let k = Keypair::new();
    svm.airdrop(&k.pubkey(), 10 * SOL).unwrap();
    k
}

// ---------------------------------------------------------------- create

/// Anyone can send lamports to a future plan address; creation falls back
/// to transfer + allocate + assign, so this cannot block it.
#[test]
fn prefunded_plan_address_does_not_block_create() {
    let mut env = Env::new();
    let griefer = funded(&mut env.svm);
    let ix = anchor_lang::solana_program::system_instruction::transfer(
        &griefer.pubkey(),
        &env.vault_addr(),
        1,
    );
    env.send(ix, &[&griefer]).unwrap();
    env.create_plan(all_to(&Keypair::new().pubkey())).unwrap();
    assert_eq!(env.vault().owner, env.owner.pubkey());
}

/// LC-I1 (fixed): `rent_paid` used to record the full rent even when the
/// plan address already held lamports and the payer topped up less (or
/// nothing), so on close the rent payer received lamports it never
/// deposited. It now records what the payer actually put in.
#[test]
fn sponsor_gets_back_only_the_rent_it_deposited() {
    let mut env = Env::new();
    let sponsor = funded(&mut env.svm);
    let rent = env.svm.minimum_balance_for_rent_exemption(Vault::SPACE);
    // A deposit lands on the plan address before the (sponsored) create.
    env.deposit_sol(rent);
    let s0 = env.lamports(&sponsor.pubkey());
    let ix = env.create_plan_ix(&sponsor.pubkey(), all_to(&Keypair::new().pubkey()));
    let owner = env.owner.insecure_clone();
    env.send(ix, &[&sponsor, &owner]).unwrap();
    let s1 = env.lamports(&sponsor.pubkey());
    // Two signatures: 10_000 lamports of fees, the rest is rent it put in.
    let deposited = s0 - s1 - 10_000;
    assert_eq!(deposited, 0);
    assert_eq!(env.vault().rent_paid, deposited);

    let ix = env.close_ix_as(&env.owner.pubkey(), &sponsor.pubkey());
    env.send(ix, &[&owner]).unwrap();
    let refunded = env.lamports(&sponsor.pubkey()) - s1;
    assert_eq!(refunded, deposited);
}

/// LC-I1, partial pre-funding: the sponsor pays only the shortfall and gets
/// exactly that back; the rest goes to the owner.
#[test]
fn sponsor_tops_up_a_partly_funded_plan_address_and_gets_that_back() {
    let mut env = Env::new();
    let sponsor = funded(&mut env.svm);
    let rent = env.svm.minimum_balance_for_rent_exemption(Vault::SPACE);
    env.deposit_sol(rent / 4);
    let s0 = env.lamports(&sponsor.pubkey());
    let ix = env.create_plan_ix(&sponsor.pubkey(), all_to(&Keypair::new().pubkey()));
    let owner = env.owner.insecure_clone();
    env.send(ix, &[&sponsor, &owner]).unwrap();
    let s1 = env.lamports(&sponsor.pubkey());
    let shortfall = rent - rent / 4;
    assert_eq!(s0 - s1 - 10_000, shortfall);
    assert_eq!(env.vault().rent_paid, shortfall);
    assert_eq!(env.lamports(&env.vault_addr()), rent);

    let o0 = env.lamports(&env.owner.pubkey());
    let ix = env.close_ix_as(&env.owner.pubkey(), &sponsor.pubkey());
    env.send(ix, &[&owner]).unwrap();
    assert_eq!(env.lamports(&sponsor.pubkey()) - s1, shortfall);
    assert_eq!(env.lamports(&env.owner.pubkey()) + 5_000 - o0, rent / 4);
}

/// create_plan and create_vesting share one PDA space per (owner, plan_id);
/// a second init on a live id fails whatever the kind, and seeds bind the
/// address to the signing owner.
#[test]
fn plan_ids_are_unique_per_owner_and_kind() {
    let mut env = Env::new();
    let b = Keypair::new().pubkey();
    env.create_plan(all_to(&b)).unwrap();
    let now = env.now();
    assert!(env.create_vesting(now, &b, SOL).is_err());
    assert!(env.create_plan(all_to(&b)).is_err());

    // Another wallet cannot create at the owner's address.
    let thief = funded(&mut env.svm);
    let mut ix = env.create_plan_ix(&thief.pubkey(), all_to(&b));
    ix.accounts[0].pubkey = thief.pubkey();
    env.plan = 1;
    ix.accounts[2].pubkey = env.vault_addr();
    let err = env.send(ix, &[&thief]).unwrap_err();
    assert!(err.contains("ConstraintSeeds"), "{err}");
}

// ---------------------------------------------------------- authorities

/// Every owner-only instruction rejects the guard, the guardian, a
/// beneficiary and a stranger signing in the owner slot.
#[test]
fn only_the_owner_can_use_owner_instructions() {
    let mut env = Env::new();
    let b = funded(&mut env.svm);
    let guardian = funded(&mut env.svm);
    env.create_plan(all_to(&b.pubkey())).unwrap();
    env.update_plan(all_to(&b.pubkey()), Some(guardian.pubkey()))
        .unwrap();
    env.deposit_sol(5 * SOL);
    let stranger = funded(&mut env.svm);
    let guard = env.guard.insecure_clone();
    let before = env.vault();

    for who in [&guard, &guardian, &b, &stranger] {
        let me = who.pubkey();
        let ixs = vec![
            env.update_plan_ix(&me, all_to(&me), None),
            env.owner_ix_as(&me, deadman::instruction::SetGuard { new_guard: me }),
            env.owner_ix_as(&me, deadman::instruction::RevokeVesting {}),
            env.withdraw_sol_ix(&me, SOL),
            env.close_ix_as(&me, &me),
            env.unlock_ix(&me, &guardian.pubkey()),
        ];
        for ix in ixs {
            let signers: Vec<&Keypair> = if ix.data[..8]
                == *deadman::instruction::Unlock::DISCRIMINATOR
                && who.pubkey() != guardian.pubkey()
            {
                vec![who, &guardian]
            } else {
                vec![who]
            };
            let err = env.send(ix, &signers).unwrap_err();
            assert!(
                err.contains("ConstraintSeeds") || err.contains("Unauthorized"),
                "{err}"
            );
        }
    }
    // Pulse: only owner or guard. Lockdown: owner, guard or guardian.
    for who in [&guardian, &b, &stranger] {
        assert!(env.pulse(who).unwrap_err().contains("Unauthorized"));
    }
    for who in [&b, &stranger] {
        assert!(env.lockdown(who).unwrap_err().contains("Unauthorized"));
    }
    // Unlock needs the stored guardian, not the guard.
    let owner = env.owner.insecure_clone();
    let ix = env.unlock_ix(&owner.pubkey(), &guard.pubkey());
    assert!(env
        .send(ix, &[&owner, &guard])
        .unwrap_err()
        .contains("Unauthorized"));

    let after = env.vault();
    assert_eq!(after.guard, before.guard);
    assert_eq!(after.guardian, before.guardian);
    assert_eq!(after.rules, before.rules);
    assert_eq!(after.locked_until, before.locked_until);
}

/// Guard, guardian, owner and pending beneficiaries stay distinct keys.
#[test]
fn guard_guardian_and_beneficiaries_stay_disjoint() {
    let mut env = Env::new();
    let b = Keypair::new().pubkey();
    let guardian = Keypair::new().pubkey();
    env.create_plan(all_to(&b)).unwrap();
    env.update_plan(all_to(&b), Some(guardian)).unwrap();
    let owner = env.owner.pubkey();
    let guard = env.guard.pubkey();

    for g in [guardian, b, owner, Pubkey::default()] {
        assert!(env.set_guard(g).unwrap_err().contains("InvalidGuard"));
    }
    for g in [guard, owner, b, Pubkey::default()] {
        assert!(env
            .update_plan(all_to(&b), Some(g))
            .unwrap_err()
            .contains("InvalidGuardian"));
    }
    // A beneficiary equal to the guard is refused.
    assert!(env
        .update_plan(all_to(&guard), None)
        .unwrap_err()
        .contains("InvalidRules"));
}

// ------------------------------------------------------- lockdown/unlock

/// LC-I2 (fixed): after a guardian lockdown the owner gets `lock_secs`
/// unlocked to remove the guardian. A guard-key lockdown near the end of it
/// used to push `locked_until` but not `guardian_ready_at`, shrinking that
/// window to one second. Every lockdown now moves `guardian_ready_at` to at
/// least `locked_until + lock_secs` while a guardian is set.
#[test]
fn guard_lockdown_cannot_shrink_the_owner_window_after_a_guardian_lockdown() {
    let mut env = Env::new();
    let b = Keypair::new().pubkey();
    let guardian = funded(&mut env.svm);
    env.create_plan(all_to(&b)).unwrap();
    env.update_plan(all_to(&b), Some(guardian.pubkey()))
        .unwrap();
    let guard = env.guard.insecure_clone();

    let t0 = env.now();
    env.lockdown(&guardian).unwrap();
    env.advance(LOCK - 1);
    env.lockdown(&guard).unwrap();
    let v = env.vault();
    assert_eq!(v.locked_until, t0 + 2 * LOCK - 1);
    assert_eq!(v.guardian_ready_at, t0 + 3 * LOCK - 1);
    // The guardian cannot lock again one second after the guard's lockdown.
    env.set_time(t0 + 2 * LOCK);
    assert!(env
        .lockdown(&guardian)
        .unwrap_err()
        .contains("GuardianCooldown"));
    // The owner has a full window and removes the guardian at its end.
    env.set_time(t0 + 3 * LOCK - 2);
    assert!(env
        .lockdown(&guardian)
        .unwrap_err()
        .contains("GuardianCooldown"));
    env.update_plan(all_to(&b), None).unwrap();
    assert_eq!(env.vault().guardian, None);

    // Without a guardian, lockdowns leave `guardian_ready_at` alone.
    let ready = env.vault().guardian_ready_at;
    env.lockdown(&guard).unwrap();
    assert_eq!(env.vault().guardian_ready_at, ready);
}

/// Lockdown never touches the switch, and unlock needs owner + guardian.
#[test]
fn lockdown_keeps_the_switch_and_unlock_needs_both() {
    let mut env = Env::new();
    let b = funded(&mut env.svm);
    let guardian = funded(&mut env.svm);
    env.create_plan(all_to(&b.pubkey())).unwrap();
    env.update_plan(all_to(&b.pubkey()), Some(guardian.pubkey()))
        .unwrap();
    env.deposit_sol(2 * SOL);
    let last = env.vault().last_pulse;
    let owner = env.owner.insecure_clone();
    env.advance(DAY);
    env.lockdown(&owner).unwrap();
    assert_eq!(env.vault().last_pulse, last);
    assert!(env.close().unwrap_err().contains("VaultLocked"));
    let me = owner.pubkey();
    let ix = env.withdraw_sol_ix(&me, SOL);
    assert!(env.send(ix, &[&owner]).unwrap_err().contains("VaultLocked"));

    // Inheritance still runs while locked.
    env.advance(10 * DAY);
    env.execute_sol(0, &b.pubkey()).unwrap();

    let ix = env.unlock_ix(&me, &guardian.pubkey());
    env.send(ix, &[&owner, &guardian]).unwrap();
    assert!(env.vault().locked_until <= env.now());
}

// ------------------------------------------------------ completion/close

/// A released plan is final for check-ins and edits; guard rotation and
/// lockdown stay possible and harmless; leftovers can be withdrawn.
#[test]
fn released_plan_rejects_pulse_and_edit_from_everyone() {
    let mut env = Env::new();
    let b = funded(&mut env.svm);
    env.create_plan(all_to(&b.pubkey())).unwrap();
    env.deposit_sol(2 * SOL);
    env.advance(10 * DAY + 1);
    env.execute_sol(0, &b.pubkey()).unwrap();
    let owner = env.owner.insecure_clone();
    let guard = env.guard.insecure_clone();
    assert!(env.pulse(&owner).unwrap_err().contains("PlanCompleted"));
    assert!(env.pulse(&guard).unwrap_err().contains("PlanCompleted"));
    assert!(env
        .update_plan(all_to(&b.pubkey()), None)
        .unwrap_err()
        .contains("PlanCompleted"));
    env.lockdown(&guard).unwrap();
    env.set_guard(Keypair::new().pubkey()).unwrap();
    let until = env.vault().locked_until;
    env.set_time(until);
    env.close().unwrap();
    assert_eq!(env.lamports(&env.vault_addr()), 0);
}

/// Close leaves an empty system account (no revival as a Vault), and the
/// id can host a new plan of either kind, which again controls the old
/// plan's token account.
#[test]
fn closed_plan_cannot_be_revived_and_its_id_is_reusable() {
    let mut env = Env::new();
    let b = Keypair::new().pubkey();
    env.create_plan(all_to(&b)).unwrap();
    let admin = env.admin.insecure_clone();
    let mint = CreateMint::new(&mut env.svm, &admin)
        .decimals(6)
        .send()
        .unwrap();
    let vault = env.vault_addr();
    for o in [vault, env.owner.pubkey()] {
        CreateAssociatedTokenAccountIdempotent::new(&mut env.svm, &admin, &mint)
            .owner(&o)
            .send()
            .unwrap();
    }
    MintTo::new(&mut env.svm, &admin, &mint, &ata(&vault, &mint), 1_000)
        .send()
        .unwrap();
    env.close().unwrap();
    let acc = env.svm.get_account(&vault);
    assert!(acc.is_none_or(|a| a.data.is_empty() && a.owner == system_program::ID));

    // Lamports sent back do not make it a vault again.
    env.deposit_sol(SOL);
    let owner = env.owner.insecure_clone();
    let err = env.pulse(&owner).unwrap_err();
    assert!(
        err.contains("AccountOwnedByWrongProgram") || err.contains("AccountNotInitialized"),
        "{err}"
    );

    // Recreate as vesting; it controls the old ATA.
    let now = env.now();
    env.create_vesting(now, &b, SOL).unwrap();
    // The 1 SOL already there covers the rent, so the owner deposited none.
    assert_eq!(env.vault().rent_paid, 0);
    let ix = Instruction::new_with_bytes(
        deadman::id(),
        &deadman::instruction::WithdrawToken { amount: 1_000 }.data(),
        deadman::accounts::WithdrawToken {
            owner: owner.pubkey(),
            vault,
            mint,
            vault_token: ata(&vault, &mint),
            owner_token: ata(&owner.pubkey(), &mint),
            token_program: TOKEN_ID,
        }
        .to_account_metas(None),
    );
    env.send(ix, &[&owner]).unwrap();
}

/// Revoking a vesting plan before its start leaves nothing committed, so
/// the owner can take everything back and close.
#[test]
fn revoke_before_start_frees_everything() {
    let mut env = Env::new();
    let b = Keypair::new().pubkey();
    let start = env.now() + 100 * DAY;
    env.create_vesting(start, &b, 5 * SOL).unwrap();
    env.deposit_sol(5 * SOL);
    let owner = env.owner.insecure_clone();
    let me = owner.pubkey();
    let ix = env.withdraw_sol_ix(&me, SOL);
    assert!(env
        .send(ix, &[&owner])
        .unwrap_err()
        .contains("FundsCommitted"));
    let ix = env.owner_ix_as(&me, deadman::instruction::RevokeVesting {});
    env.send(ix, &[&owner]).unwrap();
    let ix = env.withdraw_sol_ix(&me, 5 * SOL);
    env.send(ix, &[&owner]).unwrap();
    env.close().unwrap();
}

// ------------------------------------------------------------- legacy

/// Borsh writer for older account layouts.
#[derive(Default)]
struct Bytes(Vec<u8>);
impl Bytes {
    fn put<T: AnchorSerialize>(&mut self, v: T) -> &mut Self {
        v.serialize(&mut self.0).unwrap();
        self
    }
}

/// A realistic plan in the e3a13b3 layout (996 bytes on devnet).
fn layout_996(owner: &Pubkey, plan_id: u16, guard: &Pubkey, b: &Pubkey, now: i64) -> Vec<u8> {
    let mut w = Bytes::default();
    w.0.extend_from_slice(Vault::DISCRIMINATOR);
    w.put(*owner).put(plan_id).put(*guard).put(None::<Pubkey>);
    w.put(7 * DAY)
        .put(LOCK)
        .put(now)
        .put(0i64)
        .put(0i64)
        .put(3u64);
    w.put(2u32).put(2u32);
    w.put(1u32); // rules
    w.put(*b)
        .put(0u8)
        .put(10 * DAY)
        .put(None::<Pubkey>)
        .put(1u8);
    w.put(10_000u64).put(0i64).put(0u64);
    w.put("Kids".to_string()).put(254u8);
    w.0.resize(996, 0);
    w.0
}

/// A realistic plan in the 0c91602 layout (1318 bytes on devnet).
fn layout_1318(owner: &Pubkey, plan_id: u16, guard: &Pubkey, b: &Pubkey, now: i64) -> Vec<u8> {
    let mut w = Bytes::default();
    w.0.extend_from_slice(Vault::DISCRIMINATOR);
    w.put(*owner).put(plan_id).put(*guard).put(None::<Pubkey>);
    w.put(7 * DAY)
        .put(LOCK)
        .put(GRACE)
        .put(now)
        .put(now)
        .put(0i64)
        .put(0i64);
    w.put(3u64).put(2u32).put(2u32);
    w.put(0u8).put(0i64).put(false).put(0i64).put(*owner); // kind..rent_payer
    w.put(1u32); // rules
    w.put(*b)
        .put(0u8)
        .put(10 * DAY)
        .put(None::<Pubkey>)
        .put(1u8);
    w.put(10_000u64)
        .put(0i64)
        .put(0u64)
        .put(0i64)
        .put(0u64)
        .put(0i64)
        .put(0u64);
    w.put("Kids".to_string()).put(254u8);
    w.0.resize(1318, 0);
    w.0
}

/// Older layouts keep the Vault discriminator but do not decode as the
/// current Vault, so no lifecycle instruction can act on them with
/// misread fields; only recover_legacy_vault applies.
#[test]
fn legacy_layouts_are_inert_except_for_recovery() {
    let mut env = Env::new();
    let owner = env.owner.insecure_clone();
    let guard = env.guard.insecure_clone();
    let b = Keypair::new().pubkey();
    let now = env.now();
    for (plan, data) in [
        (
            3u16,
            layout_996(&owner.pubkey(), 3, &guard.pubkey(), &b, now),
        ),
        (4, layout_1318(&owner.pubkey(), 4, &guard.pubkey(), &b, now)),
    ] {
        assert!(Vault::try_deserialize(&mut data.as_slice()).is_err());
        env.plan = plan;
        let addr = env.vault_addr();
        env.put_account(&addr, data, deadman::id(), SOL);
        for res in [
            env.pulse(&owner),
            env.pulse(&guard),
            env.lockdown(&guard),
            env.set_guard(Keypair::new().pubkey()),
            env.update_plan(all_to(&b), None),
            env.close(),
        ] {
            let err = res.unwrap_err();
            assert!(err.contains("AccountDidNotDeserialize"), "{err}");
        }
        let ix = Instruction::new_with_bytes(
            deadman::id(),
            &deadman::instruction::RecoverLegacyVault { plan_id: plan }.data(),
            deadman::accounts::RecoverLegacyVault {
                owner: owner.pubkey(),
                legacy: addr,
            }
            .to_account_metas(None),
        );
        env.send(ix, &[&owner]).unwrap();
        assert_eq!(env.lamports(&addr), 0);
    }
}

/// A client still sending create_vesting without `period_secs` (0c91602
/// argument layout) is rejected, not misparsed.
#[test]
fn old_create_vesting_arguments_are_rejected() {
    let mut env = Env::new();
    let b = Keypair::new().pubkey();
    let mut w = Bytes::default();
    w.0.extend_from_slice(deadman::instruction::CreateVesting::DISCRIMINATOR);
    w.put(0u16)
        .put("Old".to_string())
        .put(env.guard.pubkey())
        .put(LOCK);
    w.put(env.now()).put(true);
    w.put(vec![VestingInput {
        beneficiary: b,
        rail: Rail::Solana,
        mint: None,
        total: SOL,
        cliff_secs: 0,
        duration_secs: 100 * DAY,
    }]);
    let ix = Instruction::new_with_bytes(
        deadman::id(),
        &w.0,
        deadman::accounts::CreateVault {
            owner: env.owner.pubkey(),
            payer: env.owner.pubkey(),
            vault: env.vault_addr(),
            system_program: system_program::ID,
        }
        .to_account_metas(None),
    );
    let owner = env.owner.insecure_clone();
    let err = env.send(ix, &[&owner]).unwrap_err();
    assert!(err.contains("InstructionDidNotDeserialize"), "{err}");
}
