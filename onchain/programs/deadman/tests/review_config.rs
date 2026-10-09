//! Review lane "subscription", config part (2026-10-08). The subscription
//! itself was removed; the `set_config` findings stay here. SUB-L1 is fixed:
//! its test runs by default.

use {
    anchor_lang::{
        prelude::Pubkey,
        solana_program::{clock::Clock, instruction::Instruction, system_program},
        InstructionData, ToAccountMetas,
    },
    deadman::{AmountMode, Rail, RuleInput, CONFIG_SEED, VAULT_SEED},
    litesvm::LiteSVM,
    litesvm_token::TOKEN_ID,
    solana_keypair::Keypair,
    solana_message::{Message, VersionedMessage},
    solana_signer::Signer,
    solana_transaction::versioned::VersionedTransaction,
};

const SOL: u64 = 1_000_000_000;
const DAY: i64 = 86_400;

fn pda(seeds: &[&[u8]]) -> Pubkey {
    Pubkey::find_program_address(seeds, &deadman::id()).0
}
fn config_pda() -> Pubkey {
    pda(&[CONFIG_SEED])
}

struct Env {
    svm: LiteSVM,
    admin: Keypair,
    treasury: Keypair,
    owner: Keypair,
    guard: Keypair,
    keeper: Keypair,
}

impl Env {
    fn new() -> Self {
        let mut svm = LiteSVM::new();
        let bytes = include_bytes!(concat!(
            env!("CARGO_TARGET_TMPDIR"),
            "/../deploy/deadman.so"
        ));
        svm.add_program(deadman::id(), bytes).unwrap();
        let [admin, treasury, owner, guard, keeper] = std::array::from_fn(|_| Keypair::new());
        for k in [&admin, &treasury, &owner, &guard, &keeper] {
            svm.airdrop(&k.pubkey(), 100 * SOL).unwrap();
        }
        // Make `admin` the upgrade authority so init_config's gate passes.
        let pd = Pubkey::find_program_address(
            &[deadman::id().as_ref()],
            &anchor_lang::solana_program::bpf_loader_upgradeable::ID,
        )
        .0;
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
        env.init_config();
        env
    }

    fn now(&self) -> i64 {
        self.svm.get_sysvar::<Clock>().unix_timestamp
    }
    fn set_time(&mut self, ts: i64) {
        let mut c = self.svm.get_sysvar::<Clock>();
        c.unix_timestamp = ts;
        self.svm.set_sysvar(&c);
    }
    fn advance(&mut self, secs: i64) {
        let t = self.now() + secs;
        self.set_time(t);
    }

    fn send(&mut self, ixs: &[Instruction], signers: &[&Keypair]) -> Result<(), String> {
        self.svm.expire_blockhash();
        let msg = Message::new_with_blockhash(
            ixs,
            Some(&signers[0].pubkey()),
            &self.svm.latest_blockhash(),
        );
        let tx = VersionedTransaction::try_new(VersionedMessage::Legacy(msg), signers).unwrap();
        self.svm
            .send_transaction(tx)
            .map(|_| ())
            .map_err(|e| format!("{:?}\n{}", e.err, e.meta.logs.join("\n")))
    }

    fn admin_send(&mut self, ix: Instruction) -> Result<(), String> {
        let admin = self.admin.insecure_clone();
        self.send(&[ix], &[&admin])
    }

    fn owner_send(&mut self, ix: Instruction) -> Result<(), String> {
        let owner = self.owner.insecure_clone();
        self.send(&[ix], &[&owner])
    }

    fn lamports(&self, k: &Pubkey) -> u64 {
        self.svm.get_account(k).map_or(0, |a| a.lamports)
    }

    fn init_config(&mut self) {
        let ix = Instruction::new_with_bytes(
            deadman::id(),
            &deadman::instruction::InitConfig {
                skr_mint: Pubkey::default(),
            }
            .data(),
            deadman::accounts::InitConfig {
                admin: self.admin.pubkey(),
                config: config_pda(),
                treasury: self.treasury.pubkey(),
                program: deadman::id(),
                program_data: Pubkey::find_program_address(
                    &[deadman::id().as_ref()],
                    &anchor_lang::solana_program::bpf_loader_upgradeable::ID,
                )
                .0,
                system_program: system_program::ID,
            }
            .to_account_metas(None),
        );
        self.admin_send(ix).unwrap();
    }

    fn set_config_ix(&self, treasury: Pubkey) -> Instruction {
        Instruction::new_with_bytes(
            deadman::id(),
            &deadman::instruction::SetConfig {
                fee_bps_public: 200,
                fee_bps_private: 200,
                skr_mint: Pubkey::default(),
                fee_bps_skr: 150,
                skr_burn_bps: 1_000,
            }
            .data(),
            deadman::accounts::SetConfig {
                admin: self.admin.pubkey(),
                config: config_pda(),
                treasury,
                system_program: system_program::ID,
            }
            .to_account_metas(None),
        )
    }

    fn vault_addr(&self) -> Pubkey {
        pda(&[
            VAULT_SEED,
            self.owner.pubkey().as_ref(),
            &0u16.to_le_bytes(),
        ])
    }

    /// Plan 0 paying all its SOL to `b` 10 days after the last check-in,
    /// funded with `amount`.
    fn sol_plan(&mut self, b: &Pubkey, amount: u64) {
        let ix = Instruction::new_with_bytes(
            deadman::id(),
            &deadman::instruction::CreatePlan {
                plan_id: 0,
                label: "p".into(),
                guard: self.guard.pubkey(),
                lock_secs: 3 * DAY,
                skip_grace_secs: 30 * DAY,
                rules: vec![RuleInput {
                    beneficiary: *b,
                    rail: Rail::Solana,
                    after_secs: 10 * DAY,
                    mint: None,
                    mode: AmountMode::Percent,
                    amount: 10_000,
                }],
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
        self.owner_send(ix).unwrap();
        let fund = anchor_lang::solana_program::system_instruction::transfer(
            &self.owner.pubkey(),
            &self.vault_addr(),
            amount,
        );
        self.owner_send(fund).unwrap();
    }

    fn execute_sol(&mut self, b: &Pubkey, treasury: &Pubkey) -> Result<(), String> {
        let ix = Instruction::new_with_bytes(
            deadman::id(),
            &deadman::instruction::ExecuteSolRule { index: 0 }.data(),
            deadman::accounts::ExecuteSolRule {
                executor: self.keeper.pubkey(),
                vault: self.vault_addr(),
                config: config_pda(),
                beneficiary: *b,
                treasury: *treasury,
            }
            .to_account_metas(None),
        );
        let k = self.keeper.insecure_clone();
        self.send(&[ix], &[&k])
    }
}

/// SUB-L1 (fixed). `set_config` used to accept any non-default treasury. A
/// sysvar or program address is demoted to read-only by the runtime, so
/// the `mut` constraint on `treasury` failed (2000 ConstraintMut) and every
/// SOL payout and SOL vesting release stopped. The treasury is now passed as
/// an account and must be a system-owned, non-executable wallet.
#[test]
fn sub_l1_unusable_treasury_is_rejected_or_does_not_block_payouts() {
    let clock = Pubkey::from_str_const("SysvarC1ock11111111111111111111111111111111");
    let mut failures = Vec::new();
    for bad in [clock, system_program::ID, TOKEN_ID, deadman::id()] {
        let mut env = Env::new();
        let b = Keypair::new();
        env.sol_plan(&b.pubkey(), 2 * SOL);
        let accepted = env.admin_send(env.set_config_ix(bad)).is_ok();
        env.advance(10 * DAY + 1);
        if let (true, Err(e)) = (accepted, env.execute_sol(&b.pubkey(), &bad)) {
            let first = e.lines().next().unwrap_or_default().to_string();
            failures.push(format!("{bad}: {first}"));
        }
        assert!(!accepted, "{bad} accepted as treasury");
        let t = env.treasury.pubkey();
        env.execute_sol(&b.pubkey(), &t).unwrap();
    }
    assert!(
        failures.is_empty(),
        "unusable treasury accepted and payouts failed: {failures:?}"
    );
}

/// Control for SUB-L1: with the normal treasury the same payout succeeds.
#[test]
fn sub_l1_control_payout_succeeds_with_a_normal_treasury() {
    let mut env = Env::new();
    let b = Keypair::new();
    env.sol_plan(&b.pubkey(), 2 * SOL);
    env.advance(10 * DAY + 1);
    let t = env.treasury.pubkey();
    env.execute_sol(&b.pubkey(), &t).unwrap();
    assert!(env.lamports(&b.pubkey()) > 0);
}
