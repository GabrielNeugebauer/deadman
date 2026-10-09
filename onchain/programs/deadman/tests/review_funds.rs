//! Funds-lane review (2026-10-08): fund movement, fee math, skip reserves,
//! stipends, NFT tiers and Token-2022 mints.
//!
//! The FUNDS-1..6 tests assert the correct behaviour; all of them are fixed
//! and run by default. Token-2022 mints can no longer be put in a plan.
use {
    anchor_lang::{
        prelude::Pubkey,
        solana_program::{
            clock::Clock,
            instruction::{AccountMeta, Instruction},
            system_instruction, system_program,
        },
        AccountDeserialize, InstructionData, ToAccountMetas,
    },
    anchor_spl::{
        associated_token::get_associated_token_address_with_program_id,
        token_2022::spl_token_2022 as t22,
    },
    deadman::{
        split_fee, AmountMode, Rail, RuleInput, Vault, VestingInput, CONFIG_SEED, VAULT_SEED,
    },
    litesvm::LiteSVM,
    litesvm_token::{
        CreateAccount, CreateAssociatedTokenAccountIdempotent, CreateMint, MintTo, TOKEN_ID,
    },
    solana_keypair::Keypair,
    solana_message::{Message, VersionedMessage},
    solana_signer::Signer,
    solana_transaction::versioned::VersionedTransaction,
};

const SOL: u64 = 1_000_000_000;
const DAY: i64 = 86_400;
const LOCK: i64 = 3 * DAY;
const GRACE: i64 = 30 * DAY;
const FEE_PUBLIC: u16 = 200;
const CLOAK_STIPEND: u64 = 12_000_000;
const T22: Pubkey = t22::ID;

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

/// Plan creation and edits take every token mint in the remaining accounts.
fn mint_metas(mints: impl IntoIterator<Item = Option<Pubkey>>) -> Vec<AccountMeta> {
    let mut out: Vec<AccountMeta> = Vec::new();
    for m in mints.into_iter().flatten() {
        if !out.iter().any(|a| a.pubkey == m) {
            out.push(AccountMeta::new_readonly(m, false));
        }
    }
    out
}

fn ata_p(owner: &Pubkey, mint: &Pubkey, program: &Pubkey) -> Pubkey {
    get_associated_token_address_with_program_id(owner, mint, program)
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
        let admin = Keypair::new();
        let treasury = Keypair::new();
        let owner = Keypair::new();
        let guard = Keypair::new();
        let keeper = Keypair::new();
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
        };
        env.set_time(1_800_000_000);
        let ix = Instruction::new_with_bytes(
            deadman::id(),
            &deadman::instruction::InitConfig {
                skr_mint: Pubkey::default(),
            }
            .data(),
            deadman::accounts::InitConfig {
                admin: env.admin.pubkey(),
                config: config_pda(),
                treasury: env.treasury.pubkey(),
                program: deadman::id(),
                program_data: program_data_pda(),
                system_program: system_program::ID,
            }
            .to_account_metas(None),
        );
        let admin = env.admin.insecure_clone();
        env.send(&[ix], &[&admin]).unwrap();
        env
    }

    fn vault_addr(&self) -> Pubkey {
        vault_pda(&self.owner.pubkey(), 0)
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

    fn send(&mut self, ixs: &[Instruction], signers: &[&Keypair]) -> Result<u64, String> {
        self.svm.expire_blockhash();
        let msg = Message::new_with_blockhash(
            ixs,
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

    /// Token amount of a classic or Token-2022 account (same base layout).
    fn tokens(&self, k: &Pubkey) -> u64 {
        self.svm
            .get_account(k)
            .map(|a| u64::from_le_bytes(a.data[64..72].try_into().unwrap()))
            .unwrap_or(0)
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

    fn owner_signed(&mut self, ix: Instruction) -> Result<u64, String> {
        let owner = self.owner.insecure_clone();
        self.send(&[ix], &[&owner])
    }

    fn keeper_signed(&mut self, ix: Instruction) -> Result<u64, String> {
        let keeper = self.keeper.insecure_clone();
        self.send(&[ix], &[&keeper])
    }

    fn create_plan(&mut self, rules: Vec<RuleInput>) -> Result<u64, String> {
        let mints = mint_metas(rules.iter().map(|r| r.mint));
        let mut ix = Instruction::new_with_bytes(
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
        ix.accounts.extend(mints);
        self.owner_signed(ix)
    }

    fn create_vesting(&mut self, schedules: Vec<VestingInput>) -> Result<u64, String> {
        let mints = mint_metas(schedules.iter().map(|v| v.mint));
        let mut ix = Instruction::new_with_bytes(
            deadman::id(),
            &deadman::instruction::CreateVesting {
                plan_id: 0,
                label: "Vesting".to_string(),
                guard: self.guard.pubkey(),
                lock_secs: LOCK,
                start_at: self.now(),
                revocable: false,
                schedules,
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
        ix.accounts.extend(mints);
        self.owner_signed(ix)
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

    fn update_plan(&mut self, rules: Vec<RuleInput>) -> Result<u64, String> {
        let mints = mint_metas(rules.iter().map(|r| r.mint));
        let mut ix = self.owner_ix(deadman::instruction::UpdatePlan {
            label: "Updated".to_string(),
            lock_secs: LOCK,
            skip_grace_secs: GRACE,
            rules,
            guardian: None,
        });
        ix.accounts.extend(mints);
        self.owner_signed(ix)
    }

    fn deposit_sol(&mut self, amount: u64) {
        let ix = system_instruction::transfer(&self.owner.pubkey(), &self.vault_addr(), amount);
        self.owner_signed(ix).unwrap();
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
        self.owner_signed(ix)
    }

    fn skip(&mut self, index: u8, vault_token: Option<Pubkey>) -> Result<u64, String> {
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
        self.keeper_signed(ix)
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
        self.keeper_signed(ix)
    }

    /// Token payout (inheritance or vesting) with every account explicit.
    #[allow(clippy::too_many_arguments)]
    fn token_payout(
        &mut self,
        vesting: bool,
        index: u8,
        beneficiary: &Pubkey,
        mint: &Pubkey,
        program: &Pubkey,
        destination: &Pubkey,
        treasury_token: Option<&Pubkey>,
    ) -> Result<u64, String> {
        let vault = self.vault_addr();
        let accounts = deadman::accounts::ExecuteTokenRule {
            executor: self.keeper.pubkey(),
            vault,
            config: config_pda(),
            mint: *mint,
            vault_token: ata_p(&vault, mint, program),
            beneficiary: *beneficiary,
            beneficiary_token: *destination,
            treasury_token: treasury_token.copied(),
            token_program: *program,
        }
        .to_account_metas(None);
        let data = if vesting {
            deadman::instruction::ReleaseVestedToken { index }.data()
        } else {
            deadman::instruction::ExecuteTokenRule { index }.data()
        };
        self.keeper_signed(Instruction::new_with_bytes(deadman::id(), &data, accounts))
    }

    fn create_ata(&mut self, owner: &Pubkey, mint: &Pubkey, program: &Pubkey) -> Pubkey {
        let admin = self.admin.insecure_clone();
        CreateAssociatedTokenAccountIdempotent::new(&mut self.svm, &admin, mint)
            .owner(owner)
            .token_program_id(program)
            .send()
            .unwrap()
    }

    /// Classic SPL mint; `vault_amount` minted to the vault's ATA. The
    /// treasury ATA is created only when `treasury_ata`.
    fn classic_mint(&mut self, decimals: u8, vault_amount: u64, treasury_ata: bool) -> Pubkey {
        let admin = self.admin.insecure_clone();
        let mint = CreateMint::new(&mut self.svm, &admin)
            .decimals(decimals)
            .send()
            .unwrap();
        let vault = self.vault_addr();
        let vault_ata = self.create_ata(&vault, &mint, &TOKEN_ID);
        if treasury_ata {
            let t = self.treasury.pubkey();
            self.create_ata(&t, &mint, &TOKEN_ID);
        }
        MintTo::new(&mut self.svm, &admin, &mint, &vault_ata, vault_amount)
            .send()
            .unwrap();
        mint
    }

    /// Token-2022 mint whose mint authority and permanent delegate is the
    /// plan owner, with a `fee_bps` transfer fee. Vault, owner and treasury
    /// ATAs exist; `vault_amount` is minted to the vault.
    fn t22_mint(&mut self, fee_bps: u16, vault_amount: u64) -> Pubkey {
        use t22::extension::ExtensionType;
        let mint_kp = Keypair::new();
        let mint = mint_kp.pubkey();
        let owner = self.owner.pubkey();
        let space = ExtensionType::try_calculate_account_len::<t22::state::Mint>(&[
            ExtensionType::TransferFeeConfig,
            ExtensionType::PermanentDelegate,
        ])
        .unwrap();
        let rent = self.svm.minimum_balance_for_rent_exemption(space);
        let ixs = [
            system_instruction::create_account(&owner, &mint, rent, space as u64, &T22),
            t22::extension::transfer_fee::instruction::initialize_transfer_fee_config(
                &T22,
                &mint,
                Some(&owner),
                Some(&owner),
                fee_bps,
                u64::MAX,
            )
            .unwrap(),
            t22::instruction::initialize_permanent_delegate(&T22, &mint, &owner).unwrap(),
            t22::instruction::initialize_mint2(&T22, &mint, &owner, None, 6).unwrap(),
        ];
        let o = self.owner.insecure_clone();
        self.send(&ixs, &[&o, &mint_kp]).unwrap();
        let vault = self.vault_addr();
        let t = self.treasury.pubkey();
        let vault_ata = self.create_ata(&vault, &mint, &T22);
        self.create_ata(&owner, &mint, &T22);
        self.create_ata(&t, &mint, &T22);
        let mint_to =
            t22::instruction::mint_to(&T22, &mint, &vault_ata, &owner, &[], vault_amount).unwrap();
        self.send(&[mint_to], &[&o]).unwrap();
        mint
    }
}

fn net_of(gross: u64, bps: u16) -> u64 {
    gross - gross * u64::from(bps) / 10_000
}

// ---------------------------------------------------------------------------
// FUNDS-1 (fixed): owner withdrawals used to ignore skipped-tier reserves.
// ---------------------------------------------------------------------------

/// A skipped tier's `reserved` share is set aside. `withdraw_sol` used to
/// subtract only `committed()` (0 for inheritance plans), so the owner
/// could take the reserve, and the stale reservation then outranked a new
/// heir on every later deposit. Withdrawals now keep the reserve.
#[test]
fn funds1_stale_skipped_reserve_outranks_a_tier_added_after_the_owner_returns() {
    let mut env = Env::new();
    let bob = Keypair::new();
    let carol = Keypair::new();
    env.svm.airdrop(&bob.pubkey(), SOL).unwrap();
    env.svm.airdrop(&carol.pubkey(), SOL).unwrap();
    env.create_plan(vec![rule(
        &bob.pubkey(),
        Rail::Solana,
        10 * DAY,
        None,
        AmountMode::Fixed,
        5 * SOL,
    )])
    .unwrap();
    env.deposit_sol(10 * SOL);

    // Nobody runs Bob's tier in time; anyone may skip it.
    env.advance(10 * DAY + GRACE + 1);
    env.skip(0, None).unwrap();
    assert_eq!(env.vault().rules[0].reserved, 5 * SOL);

    // The owner comes back, takes everything (the reserve included) and
    // names Carol as the only new heir, then tops the plan up with 4 SOL.
    let all = env.withdrawable();
    let _ = env.withdraw_sol(all);
    env.update_plan(vec![rule(
        &carol.pubkey(),
        Rail::Solana,
        10 * DAY,
        None,
        AmountMode::Percent,
        10_000,
    )])
    .unwrap();
    env.deposit_sol(4 * SOL);
    env.advance(10 * DAY + 1);

    // Correct: Carol's 100% tier pays from the deposit made for her.
    let carol_before = env.lamports(&carol.pubkey());
    let res = env.execute_sol(1, &carol.pubkey());
    assert!(
        res.is_ok() && env.lamports(&carol.pubkey()) > carol_before,
        "Carol's tier paid nothing; Bob's stale 5 SOL reserve swallows the 4 SOL deposit: {res:?}"
    );
}

/// FUNDS-1 fixed: the owner may withdraw everything but the skipped
/// tier's reserve, so a tier added later pays from the new deposit and the
/// skipped heir still gets exactly the reserve.
#[test]
fn funds1_withdrawals_keep_the_reserve_and_each_heir_gets_its_own_share() {
    let mut env = Env::new();
    let bob = Keypair::new();
    let carol = Keypair::new();
    env.svm.airdrop(&bob.pubkey(), SOL).unwrap();
    env.svm.airdrop(&carol.pubkey(), SOL).unwrap();
    env.create_plan(vec![rule(
        &bob.pubkey(),
        Rail::Solana,
        10 * DAY,
        None,
        AmountMode::Fixed,
        5 * SOL,
    )])
    .unwrap();
    env.deposit_sol(10 * SOL);
    env.advance(10 * DAY + GRACE + 1);
    env.skip(0, None).unwrap();
    let all = env.withdrawable();
    let err = env.withdraw_sol(all).unwrap_err();
    assert!(err.contains("FundsCommitted"), "{err}");
    env.withdraw_sol(all - 5 * SOL).unwrap();
    env.update_plan(vec![rule(
        &carol.pubkey(),
        Rail::Solana,
        10 * DAY,
        None,
        AmountMode::Percent,
        10_000,
    )])
    .unwrap();
    env.deposit_sol(4 * SOL);
    env.advance(10 * DAY + 1);
    let carol_before = env.lamports(&carol.pubkey());
    env.execute_sol(1, &carol.pubkey()).unwrap();
    assert_eq!(
        env.lamports(&carol.pubkey()) - carol_before,
        net_of(4 * SOL, FEE_PUBLIC)
    );
    let bob_before = env.lamports(&bob.pubkey());
    env.execute_sol(0, &bob.pubkey()).unwrap();
    assert_eq!(
        env.lamports(&bob.pubkey()) - bob_before,
        net_of(5 * SOL, FEE_PUBLIC)
    );
}

// ---------------------------------------------------------------------------
// FUNDS-2: ON-L1 (stipend bit not remapped by update_plan), fixed.
// ---------------------------------------------------------------------------

#[test]
fn funds2_new_private_tier_at_a_reused_index_gets_its_stipend() {
    let mut env = Env::new();
    let a = Keypair::new();
    let c = Keypair::new();
    let d = Keypair::new();
    // Rules: 0 = SOL tier to A, 1 = Cloak USDC tier to claim key C.
    env.create_plan(vec![rule(
        &a.pubkey(),
        Rail::Solana,
        20 * DAY,
        None,
        AmountMode::Percent,
        10_000,
    )])
    .unwrap();
    let usdc = env.classic_mint(6, 50_000_000, true);
    env.update_plan(vec![
        rule(
            &a.pubkey(),
            Rail::Solana,
            10 * DAY,
            None,
            AmountMode::Percent,
            10_000,
        ),
        rule(
            &c.pubkey(),
            Rail::Cloak,
            10 * DAY,
            Some(usdc),
            AmountMode::Percent,
            10_000,
        ),
    ])
    .unwrap();
    env.deposit_sol(SOL);
    env.advance(10 * DAY + 1);
    let c_ata = env.create_ata(&c.pubkey(), &usdc, &TOKEN_ID);
    let t_ata = ata_p(&env.treasury.pubkey(), &usdc, &TOKEN_ID);
    env.token_payout(
        false,
        1,
        &c.pubkey(),
        &usdc,
        &TOKEN_ID,
        &c_ata,
        Some(&t_ata),
    )
    .unwrap();
    assert_eq!(env.lamports(&c.pubkey()), CLOAK_STIPEND);

    // Owner returns: C's tier moves to index 0 as history; D lands at 1.
    env.update_plan(vec![rule(
        &d.pubkey(),
        Rail::Cloak,
        10 * DAY,
        Some(usdc),
        AmountMode::Percent,
        10_000,
    )])
    .unwrap();
    let vault_ata = ata_p(&env.vault_addr(), &usdc, &TOKEN_ID);
    let admin = env.admin.insecure_clone();
    MintTo::new(&mut env.svm, &admin, &usdc, &vault_ata, 10_000_000)
        .send()
        .unwrap();
    env.advance(10 * DAY + 1);
    let d_ata = env.create_ata(&d.pubkey(), &usdc, &TOKEN_ID);
    env.token_payout(
        false,
        1,
        &d.pubkey(),
        &usdc,
        &TOKEN_ID,
        &d_ata,
        Some(&t_ata),
    )
    .unwrap();
    assert!(env.withdrawable() >= CLOAK_STIPEND, "vault had spare SOL");
    assert_eq!(
        env.lamports(&d.pubkey()),
        CLOAK_STIPEND,
        "D's fresh claim key got tokens but no gas: bit 1 was set by C's old tier"
    );
}

// ---------------------------------------------------------------------------
// FUNDS-3 / FUNDS-4 (ON-L5 / ON-L4), fixed: plans take classic SPL Token
// mints only, so Token-2022 extensions cannot break the guarantees.
// ---------------------------------------------------------------------------

/// A Token-2022 transfer-fee mint is refused when creating or editing a
/// plan, and its token program is refused at payout.
#[test]
fn t22_mints_are_refused_at_create_update_and_payout() {
    let mut env = Env::new();
    let bob = Keypair::new();
    let mint = env.t22_mint(100, 1_000_000);
    let tier = rule(
        &bob.pubkey(),
        Rail::Solana,
        10 * DAY,
        Some(mint),
        AmountMode::Percent,
        10_000,
    );
    let err = env.create_plan(vec![tier]).unwrap_err();
    assert!(err.contains("UnsupportedMint"), "{err}");
    env.create_plan(vec![rule(
        &bob.pubkey(),
        Rail::Solana,
        10 * DAY,
        None,
        AmountMode::Percent,
        10_000,
    )])
    .unwrap();
    let err = env.update_plan(vec![tier]).unwrap_err();
    assert!(err.contains("UnsupportedMint"), "{err}");

    env.advance(10 * DAY + 1);
    let bob_ata = env.create_ata(&bob.pubkey(), &mint, &T22);
    let t_ata = ata_p(&env.treasury.pubkey(), &mint, &T22);
    assert!(env
        .token_payout(false, 0, &bob.pubkey(), &mint, &T22, &bob_ata, Some(&t_ata))
        .is_err());
}

/// ON-L5 fixed: a transfer-fee mint cannot be put in a plan, so `rule.paid`
/// can never overstate what a beneficiary received.
#[test]
fn funds3_t22_paid_matches_what_the_beneficiary_received() {
    let mut env = Env::new();
    let bob = Keypair::new();
    env.create_plan(vec![rule(
        &bob.pubkey(),
        Rail::Solana,
        10 * DAY,
        None,
        AmountMode::Percent,
        10_000,
    )])
    .unwrap();
    let mint = env.t22_mint(100, 1_000_000);
    let err = env
        .update_plan(vec![rule(
            &bob.pubkey(),
            Rail::Solana,
            10 * DAY,
            Some(mint),
            AmountMode::Percent,
            10_000,
        )])
        .unwrap_err();
    assert!(err.contains("UnsupportedMint"), "{err}");
    assert_eq!(env.vault().rules[0].mint, None);
}

/// ON-L4 fixed: a vesting plan in a Token-2022 mint whose permanent
/// delegate is the owner cannot be created, so the owner can never pull
/// committed tokens out behind the program's back.
#[test]
fn funds4_permanent_delegate_cannot_empty_committed_vesting() {
    let mut env = Env::new();
    let bob = Keypair::new();
    let mint = env.t22_mint(0, 1_000_000);
    let err = env
        .create_vesting(vec![VestingInput {
            beneficiary: bob.pubkey(),
            rail: Rail::Solana,
            mint: Some(mint),
            total: 1_000_000,
            cliff_secs: 0,
            duration_secs: 30 * DAY,
        }])
        .unwrap_err();
    assert!(err.contains("UnsupportedMint"), "{err}");
    assert!(env
        .svm
        .get_account(&env.vault_addr())
        .is_none_or(|a| a.data.is_empty()));
}

// ---------------------------------------------------------------------------
// FUNDS-5: NFT and dust token tiers never pay a fee but still need a
// treasury token account for the mint.
// ---------------------------------------------------------------------------

#[test]
fn funds5_nft_tier_pays_without_a_treasury_token_account() {
    let mut env = Env::new();
    let bob = Keypair::new();
    env.create_plan(vec![rule(
        &bob.pubkey(),
        Rail::Solana,
        10 * DAY,
        None,
        AmountMode::Percent,
        10_000,
    )])
    .unwrap();
    let nft = env.classic_mint(0, 1, false);
    env.update_plan(vec![rule(
        &bob.pubkey(),
        Rail::Cloak,
        10 * DAY,
        Some(nft),
        AmountMode::Fixed,
        1,
    )])
    .unwrap();
    // 1 unit even at the 5% cap: the fee is always 0.
    assert_eq!(split_fee(1, 500).unwrap(), (1, 0));
    env.advance(10 * DAY + 1);
    let bob_ata = env.create_ata(&bob.pubkey(), &nft, &TOKEN_ID);
    let t_ata = ata_p(&env.treasury.pubkey(), &nft, &TOKEN_ID);
    assert!(env.svm.get_account(&t_ata).is_none());
    let res = env.token_payout(false, 0, &bob.pubkey(), &nft, &TOKEN_ID, &bob_ata, None);
    assert!(
        res.is_ok(),
        "NFT tier blocked until someone pays rent for a treasury ATA that never receives anything: {res:?}"
    );
    assert_eq!(env.tokens(&bob_ata), 1);
}

// ---------------------------------------------------------------------------
// FUNDS-6: the executor picks which treasury-owned token account gets fees.
// ---------------------------------------------------------------------------

#[test]
fn funds6_token_fee_goes_to_the_treasury_ata() {
    let mut env = Env::new();
    let bob = Keypair::new();
    env.create_plan(vec![rule(
        &bob.pubkey(),
        Rail::Solana,
        10 * DAY,
        None,
        AmountMode::Percent,
        10_000,
    )])
    .unwrap();
    let usdc = env.classic_mint(6, 1_000_000, true);
    env.update_plan(vec![rule(
        &bob.pubkey(),
        Rail::Solana,
        10 * DAY,
        Some(usdc),
        AmountMode::Percent,
        10_000,
    )])
    .unwrap();
    // Anyone can open a token account whose owner is the treasury.
    let keeper = env.keeper.insecure_clone();
    let t = env.treasury.pubkey();
    let stray = CreateAccount::new(&mut env.svm, &keeper, &usdc)
        .owner(&t)
        .send()
        .unwrap();
    env.advance(10 * DAY + 1);
    let bob_ata = env.create_ata(&bob.pubkey(), &usdc, &TOKEN_ID);
    let res = env.token_payout(
        false,
        0,
        &bob.pubkey(),
        &usdc,
        &TOKEN_ID,
        &bob_ata,
        Some(&stray),
    );
    assert!(
        res.is_err(),
        "fee of {} landed in a non-ATA treasury account the treasury does not track",
        env.tokens(&stray)
    );
}

// ---------------------------------------------------------------------------
// Regression guards that hold today.
// ---------------------------------------------------------------------------

/// The private-rail stipend never spends SOL reserved for a skipped SOL
/// tier, and the skipped heir still gets the full reserve.
#[test]
fn stipend_never_spends_a_skipped_sol_reserve() {
    let mut env = Env::new();
    let a = Keypair::new();
    let c = Keypair::new();
    env.svm.airdrop(&a.pubkey(), SOL).unwrap();
    env.create_plan(vec![rule(
        &a.pubkey(),
        Rail::Solana,
        10 * DAY,
        None,
        AmountMode::Percent,
        10_000,
    )])
    .unwrap();
    let usdc = env.classic_mint(6, 5_000_000, true);
    env.update_plan(vec![
        rule(
            &a.pubkey(),
            Rail::Solana,
            10 * DAY,
            None,
            AmountMode::Percent,
            10_000,
        ),
        rule(
            &c.pubkey(),
            Rail::Cloak,
            10 * DAY,
            Some(usdc),
            AmountMode::Percent,
            10_000,
        ),
    ])
    .unwrap();
    env.deposit_sol(SOL);
    env.advance(10 * DAY + GRACE + 1);
    env.skip(0, None).unwrap();
    let reserved = env.vault().rules[0].reserved;
    assert_eq!(reserved, env.withdrawable());

    let c_ata = env.create_ata(&c.pubkey(), &usdc, &TOKEN_ID);
    let t_ata = ata_p(&env.treasury.pubkey(), &usdc, &TOKEN_ID);
    env.token_payout(
        false,
        1,
        &c.pubkey(),
        &usdc,
        &TOKEN_ID,
        &c_ata,
        Some(&t_ata),
    )
    .unwrap();
    assert_eq!(
        env.lamports(&c.pubkey()),
        0,
        "no stipend out of the reserve"
    );
    assert_eq!(env.withdrawable(), reserved);

    let before = env.lamports(&a.pubkey());
    env.execute_sol(0, &a.pubkey()).unwrap();
    assert_eq!(
        env.lamports(&a.pubkey()) - before,
        net_of(reserved, FEE_PUBLIC)
    );
}

/// `split_fee` never charges more than the rate, never loses a unit, and
/// rounds in the payee's favour by less than one base unit.
#[test]
fn split_fee_is_exact_and_bounded() {
    let grosses = [
        1u64,
        2,
        19,
        20,
        199,
        200,
        9_999,
        10_000,
        123_456_789,
        u64::MAX / 3,
        u64::MAX,
    ];
    for &gross in &grosses {
        for bps in [0u16, 1, 199, 200, 499, 500] {
            let (net, fee) = split_fee(gross, bps).unwrap();
            assert_eq!(net + fee, gross);
            let exact = u128::from(gross) * u128::from(bps);
            assert!(u128::from(fee) * 10_000 <= exact);
            assert!(exact - u128::from(fee) * 10_000 < 10_000);
        }
    }
}

/// Executor-chosen `remaining_accounts` are not forwarded to the token CPI.
/// Passing the vault PDA and another vault ATA (as a would-be multisig
/// signer or destination) moves nothing extra.
#[test]
fn extra_accounts_cannot_move_other_vault_tokens() {
    {
        let program = TOKEN_ID;
        let mut env = Env::new();
        let bob = Keypair::new();
        env.create_plan(vec![rule(
            &bob.pubkey(),
            Rail::Solana,
            10 * DAY,
            None,
            AmountMode::Percent,
            10_000,
        )])
        .unwrap();
        let (paid, other) = (
            env.classic_mint(6, 1_000_000, true),
            env.classic_mint(6, 7_000_000, true),
        );
        env.update_plan(vec![rule(
            &bob.pubkey(),
            Rail::Solana,
            10 * DAY,
            Some(paid),
            AmountMode::Fixed,
            400_000,
        )])
        .unwrap();
        env.advance(10 * DAY + 1);
        let vault = env.vault_addr();
        let bob_ata = env.create_ata(&bob.pubkey(), &paid, &program);
        let other_vault_ata = ata_p(&vault, &other, &program);
        let mut metas = deadman::accounts::ExecuteTokenRule {
            executor: env.keeper.pubkey(),
            vault,
            config: config_pda(),
            mint: paid,
            vault_token: ata_p(&vault, &paid, &program),
            beneficiary: bob.pubkey(),
            beneficiary_token: bob_ata,
            treasury_token: Some(ata_p(&env.treasury.pubkey(), &paid, &program)),
            token_program: program,
        }
        .to_account_metas(None);
        metas.push(AccountMeta::new_readonly(vault, false));
        metas.push(AccountMeta::new(other_vault_ata, false));
        let ix = Instruction::new_with_bytes(
            deadman::id(),
            &deadman::instruction::ExecuteTokenRule { index: 0 }.data(),
            metas,
        );
        env.keeper_signed(ix).unwrap();
        assert_eq!(env.tokens(&other_vault_ata), 7_000_000);
        assert_eq!(env.tokens(&bob_ata), net_of(400_000, FEE_PUBLIC));
        assert_eq!(env.tokens(&ata_p(&vault, &paid, &program)), 600_000);
    }
}
