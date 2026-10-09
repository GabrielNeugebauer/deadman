//! LiteSVM replays of the Trident fuzz campaign in `onchain/trident-tests/`
//! (lane "fuzz", 2026-10-08).
//!
//! The only invariant the fuzzer broke was the opt-in stipend liveness check
//! (`FUZZ_STIPEND_LIVENESS=1`), the ON-L1 issue from
//! docs/security-audit-2026-10-05.md. It is fixed: `apply_policy` now moves
//! each kept tier's stipend bit with it, and its test runs by default.
//!
//! The other test pins the safety half of the same invariant (never two
//! stipends, paid history survives `update_plan`).

use {
    anchor_lang::{
        prelude::Pubkey,
        solana_program::{
            clock::Clock,
            instruction::{AccountMeta, Instruction},
            system_program,
        },
        AccountDeserialize, InstructionData, ToAccountMetas,
    },
    anchor_spl::associated_token::get_associated_token_address_with_program_id,
    deadman::{AmountMode, Rail, RuleInput, Vault, CONFIG_SEED, VAULT_SEED},
    litesvm::LiteSVM,
    litesvm_token::{CreateAssociatedTokenAccountIdempotent, CreateMint, MintTo, TOKEN_ID},
    solana_keypair::Keypair,
    solana_message::{Message, VersionedMessage},
    solana_signer::Signer,
    solana_transaction::versioned::VersionedTransaction,
};

const SOL: u64 = 1_000_000_000;
const DAY: i64 = 86_400;
const CLOAK_STIPEND: u64 = 12_000_000;

struct Env {
    svm: LiteSVM,
    admin: Keypair,
    treasury: Keypair,
    owner: Keypair,
    guard: Keypair,
    keeper: Keypair,
}

fn pda(seeds: &[&[u8]]) -> Pubkey {
    Pubkey::find_program_address(seeds, &deadman::id()).0
}

fn ata(owner: &Pubkey, mint: &Pubkey) -> Pubkey {
    get_associated_token_address_with_program_id(owner, mint, &TOKEN_ID)
}

/// Plan creation and edits take every token mint in the remaining accounts.
fn mint_metas(rules: &[RuleInput]) -> Vec<AccountMeta> {
    let mut out: Vec<AccountMeta> = Vec::new();
    for m in rules.iter().filter_map(|r| r.mint) {
        if !out.iter().any(|a| a.pubkey == m) {
            out.push(AccountMeta::new_readonly(m, false));
        }
    }
    out
}

fn token_rule(beneficiary: &Pubkey, mint: &Pubkey, amount: u64) -> RuleInput {
    RuleInput {
        beneficiary: *beneficiary,
        rail: Rail::Cloak,
        after_secs: 60,
        mint: Some(*mint),
        mode: AmountMode::Fixed,
        amount,
    }
}

impl Env {
    fn new() -> Self {
        let mut svm = LiteSVM::new();
        let bytes = include_bytes!(concat!(
            env!("CARGO_TARGET_TMPDIR"),
            "/../deploy/deadman.so"
        ));
        svm.add_program(deadman::id(), bytes).unwrap();
        let env = Self {
            svm,
            admin: Keypair::new(),
            treasury: Keypair::new(),
            owner: Keypair::new(),
            guard: Keypair::new(),
            keeper: Keypair::new(),
        };
        let mut env = env;
        for k in [&env.admin, &env.treasury, &env.owner, &env.keeper] {
            env.svm.airdrop(&k.pubkey(), 100 * SOL).unwrap();
        }
        // Make `admin` the upgrade authority so init_config passes.
        let pd = Pubkey::find_program_address(
            &[deadman::id().as_ref()],
            &anchor_lang::solana_program::bpf_loader_upgradeable::ID,
        )
        .0;
        let mut acc = env.svm.get_account(&pd).unwrap();
        acc.data[12] = 1;
        acc.data[13..45].copy_from_slice(env.admin.pubkey().as_ref());
        env.svm.set_account(pd, acc).unwrap();
        let mut clock = env.svm.get_sysvar::<Clock>();
        clock.unix_timestamp = 1_800_000_000;
        env.svm.set_sysvar(&clock);

        let ix = Instruction::new_with_bytes(
            deadman::id(),
            &deadman::instruction::InitConfig {
                skr_mint: Pubkey::default(),
            }
            .data(),
            deadman::accounts::InitConfig {
                admin: env.admin.pubkey(),
                config: pda(&[CONFIG_SEED]),
                treasury: env.treasury.pubkey(),
                program: deadman::id(),
                program_data: pd,
                system_program: system_program::ID,
            }
            .to_account_metas(None),
        );
        let admin = env.admin.insecure_clone();
        env.send(ix, &[&admin]).unwrap();
        env
    }

    fn vault_addr(&self) -> Pubkey {
        pda(&[
            VAULT_SEED,
            self.owner.pubkey().as_ref(),
            &0u16.to_le_bytes(),
        ])
    }

    fn advance(&mut self, secs: i64) {
        let mut clock = self.svm.get_sysvar::<Clock>();
        clock.unix_timestamp += secs;
        self.svm.set_sysvar(&clock);
    }

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

    fn vault(&self) -> Vault {
        let acc = self.svm.get_account(&self.vault_addr()).unwrap();
        Vault::try_deserialize(&mut acc.data.as_slice()).unwrap()
    }

    fn lamports(&self, k: &Pubkey) -> u64 {
        self.svm.get_account(k).map(|a| a.lamports).unwrap_or(0)
    }

    fn create_plan(&mut self, rules: Vec<RuleInput>) {
        let mints = mint_metas(&rules);
        let mut ix = Instruction::new_with_bytes(
            deadman::id(),
            &deadman::instruction::CreatePlan {
                plan_id: 0,
                label: "fuzz".to_string(),
                guard: self.guard.pubkey(),
                lock_secs: 3 * DAY,
                skip_grace_secs: 30 * DAY,
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
        ix.accounts.extend(mints);
        let owner = self.owner.insecure_clone();
        self.send(ix, &[&owner]).unwrap();
    }

    fn update_plan(&mut self, rules: Vec<RuleInput>) {
        let mints = mint_metas(&rules);
        let mut ix = Instruction::new_with_bytes(
            deadman::id(),
            &deadman::instruction::UpdatePlan {
                label: "fuzz".to_string(),
                lock_secs: 3 * DAY,
                skip_grace_secs: 30 * DAY,
                rules,
                guardian: None,
            }
            .data(),
            deadman::accounts::OwnerAction {
                owner: self.owner.pubkey(),
                vault: self.vault_addr(),
            }
            .to_account_metas(None),
        );
        ix.accounts.extend(mints);
        let owner = self.owner.insecure_clone();
        self.send(ix, &[&owner]).unwrap();
    }

    /// Mint with the vault funded and vault/treasury ATAs created.
    fn mint(&mut self, vault_amount: u64) -> Pubkey {
        let admin = self.admin.insecure_clone();
        let mint = CreateMint::new(&mut self.svm, &admin)
            .decimals(6)
            .send()
            .unwrap();
        for o in [self.vault_addr(), self.treasury.pubkey()] {
            CreateAssociatedTokenAccountIdempotent::new(&mut self.svm, &admin, &mint)
                .owner(&o)
                .send()
                .unwrap();
        }
        let vt = ata(&self.vault_addr(), &mint);
        MintTo::new(&mut self.svm, &admin, &mint, &vt, vault_amount)
            .send()
            .unwrap();
        mint
    }

    fn execute_token(
        &mut self,
        index: u8,
        beneficiary: &Pubkey,
        mint: &Pubkey,
    ) -> Result<(), String> {
        let admin = self.admin.insecure_clone();
        CreateAssociatedTokenAccountIdempotent::new(&mut self.svm, &admin, mint)
            .owner(beneficiary)
            .send()
            .unwrap();
        let vault = self.vault_addr();
        let ix = Instruction::new_with_bytes(
            deadman::id(),
            &deadman::instruction::ExecuteTokenRule { index }.data(),
            deadman::accounts::ExecuteTokenRule {
                executor: self.keeper.pubkey(),
                vault,
                config: pda(&[CONFIG_SEED]),
                mint: *mint,
                vault_token: ata(&vault, mint),
                beneficiary: *beneficiary,
                beneficiary_token: ata(beneficiary, mint),
                treasury_token: Some(ata(&self.treasury.pubkey(), mint)),
                token_program: TOKEN_ID,
            }
            .to_account_metas(None),
        );
        let keeper = self.keeper.insecure_clone();
        self.send(ix, &[&keeper])
    }
}

/// Fuzz failure shape: a private-rail token tier at index 1 pays (and sets
/// stipend bit 1) while the SOL tier at index 0 is still pending; the owner
/// then installs a new private-rail tier, which `apply_policy` places at
/// index 1 behind the kept history. Returns (env, mint, first claim key).
fn reindexed_plan() -> (Env, Pubkey, Pubkey) {
    let mut env = Env::new();
    let sol_ben = Keypair::new().pubkey();
    let first = Keypair::new().pubkey();
    // The vault's ATA can be created before the plan: its address is fixed.
    let mint = env.mint(1_000_000);
    env.create_plan(vec![
        RuleInput {
            beneficiary: sol_ben,
            rail: Rail::Solana,
            after_secs: 60,
            mint: None,
            mode: AmountMode::Percent,
            amount: 10_000,
        },
        token_rule(&first, &mint, 100_000),
    ]);
    let vault = env.vault_addr();
    env.svm.airdrop(&vault, SOL).unwrap();
    env.advance(61);
    // Pay the token tier first: per-asset order lets it run past the SOL tier.
    env.execute_token(1, &first, &mint).unwrap();
    assert_eq!(env.lamports(&first), CLOAK_STIPEND);
    assert_eq!(env.vault().stipend_paid, 0b10);
    (env, mint, first)
}

#[test]
fn fuzz_inv_stipend_once_and_history_survive_update_plan() {
    let (mut env, mint, first) = reindexed_plan();
    let second = Keypair::new().pubkey();
    env.update_plan(vec![token_rule(&second, &mint, 100_000)]);
    let v = env.vault();
    // History compacts to index 0; the new tier lands on index 1.
    assert_eq!(v.rules.len(), 2);
    assert_eq!(v.rules[0].beneficiary, first);
    assert_ne!(v.rules[0].executed_at, 0);
    // INV-ONCE: the paid tier cannot pay again at its new index.
    assert!(env.execute_token(0, &first, &mint).is_err());
    env.advance(61);
    let vault_before = env.lamports(&env.vault_addr());
    env.execute_token(1, &second, &mint).unwrap();
    // INV-STIPEND safety: no second stipend leaves the vault, and the
    // paid tier keeps its bit at its new index.
    assert_eq!(env.vault().stipend_paid & 1, 1);
    assert!(vault_before - env.lamports(&env.vault_addr()) <= CLOAK_STIPEND);
    assert_eq!(env.lamports(&first), CLOAK_STIPEND);
}

#[test]
fn fuzz_on_l1_new_private_tier_gets_its_stipend_after_update_plan() {
    let (mut env, mint, _first) = reindexed_plan();
    let second = Keypair::new().pubkey();
    env.update_plan(vec![token_rule(&second, &mint, 100_000)]);
    env.advance(61);
    env.execute_token(1, &second, &mint).unwrap();
    // The vault holds ~1 SOL of spare SOL and the claim key holds 0, so the
    // new Cloak tier is eligible for its stipend.
    assert_eq!(
        env.lamports(&second),
        CLOAK_STIPEND,
        "new private-rail tier got no gas stipend (stale bit 1)"
    );
}
