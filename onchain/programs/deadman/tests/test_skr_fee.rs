//! Release fees paid in SKR from a plan's fee reserve, priced by Pyth
//! `PriceUpdateV2` accounts built by hand at their canonical addresses.

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
    deadman::{
        AmountMode, PriceFeed, Rail, RuleInput, Vault, VestingInput, CONFIG_SEED, NATIVE_MINT,
        PRICE_FEED_SEED, PRICE_UPDATE_V2_DISCRIMINATOR, PYTH_PUSH_ORACLE_ID, PYTH_RECEIVER_ID,
        VAULT_SEED,
    },
    litesvm::LiteSVM,
    litesvm_token::{
        get_spl_account,
        spl_token::state::{Account as SplAccount, Mint as SplMint},
        CreateAssociatedTokenAccountIdempotent, CreateMint, MintTo, TOKEN_ID,
    },
    solana_keypair::Keypair,
    solana_message::{Message, VersionedMessage},
    solana_signer::Signer,
    solana_transaction::versioned::VersionedTransaction,
};

const SOL: u64 = 1_000_000_000;
const SKR: u64 = 1_000_000;
const DAY: i64 = 86_400;
const MAX_AGE: u32 = 120;

const SOL_FEED: &str = "ef0d8b6fda2ceba41da15d4095d1da392a0d2f8ed0c6c7bc0f4cfac8c280b56d";
const USDC_FEED: &str = "eaa020c61cc479712813461ce153894a96a6c00b21ed0cfc2798d1f9a9e9c94a";
const SKR_FEED: &str = "38846ec4d0dbe808091817f5c0d6ab8058e25422348ddf97db52b6c378a93bf9";

/// $150, $1 and $0.02, all with exponent -8.
const SOL_PRICE: i64 = 15_000_000_000;
const USDC_PRICE: i64 = 100_000_000;
const SKR_PRICE: i64 = 2_000_000;

fn feed_id(hex: &str) -> [u8; 32] {
    let mut out = [0u8; 32];
    for (i, b) in out.iter_mut().enumerate() {
        *b = u8::from_str_radix(&hex[2 * i..2 * i + 2], 16).unwrap();
    }
    out
}

fn canonical(feed: &[u8; 32]) -> Pubkey {
    Pubkey::find_program_address(&[&0u16.to_le_bytes(), feed], &PYTH_PUSH_ORACLE_ID).0
}

fn price_feed_pda(mint: &Pubkey) -> Pubkey {
    Pubkey::find_program_address(&[PRICE_FEED_SEED, mint.as_ref()], &deadman::id()).0
}

fn config_pda() -> Pubkey {
    Pubkey::find_program_address(&[CONFIG_SEED], &deadman::id()).0
}

fn ata(owner: &Pubkey, mint: &Pubkey) -> Pubkey {
    get_associated_token_address_with_program_id(owner, mint, &TOKEN_ID)
}

/// A `PriceUpdateV2` account body (134 bytes, like the receiver allocates).
fn price_update(feed: &[u8; 32], price: i64, conf: u64, publish_time: i64, full: bool) -> Vec<u8> {
    let mut d = PRICE_UPDATE_V2_DISCRIMINATOR.to_vec();
    d.extend_from_slice(&[9u8; 32]);
    if full {
        d.push(1);
    } else {
        d.extend_from_slice(&[0, 3]);
    }
    d.extend_from_slice(feed);
    d.extend_from_slice(&price.to_le_bytes());
    d.extend_from_slice(&conf.to_le_bytes());
    d.extend_from_slice(&(-8i32).to_le_bytes());
    d.extend_from_slice(&publish_time.to_le_bytes());
    d.extend_from_slice(&(publish_time - 1).to_le_bytes());
    d.extend_from_slice(&price.to_le_bytes());
    d.extend_from_slice(&conf.to_le_bytes());
    d.extend_from_slice(&7u64.to_le_bytes());
    d.resize(134, 0);
    d
}

/// Independent model of the SKR fee: `bps` of the payout's USD value in
/// SKR base units, rounded up. All prices use exponent -8.
fn model_fee(gross: u64, asset_price: i64, asset_decimals: u32, bps: u64) -> u64 {
    let skr_decimals = 6u32;
    let num = u128::from(gross) * asset_price as u128 * u128::from(bps) * 10u128.pow(skr_decimals);
    let den = 10_000u128 * SKR_PRICE as u128 * 10u128.pow(asset_decimals);
    u64::try_from(num.div_ceil(den)).unwrap()
}

fn tier(beneficiary: &Pubkey, mint: Option<Pubkey>, mode: AmountMode, amount: u64) -> RuleInput {
    RuleInput {
        beneficiary: *beneficiary,
        rail: Rail::Solana,
        after_secs: 10 * DAY,
        mint,
        mode,
        amount,
    }
}

fn all_sol(beneficiary: &Pubkey) -> Vec<RuleInput> {
    vec![tier(beneficiary, None, AmountMode::Percent, 10_000)]
}

struct Env {
    svm: LiteSVM,
    admin: Keypair,
    treasury: Keypair,
    owner: Keypair,
    guard: Keypair,
    keeper: Keypair,
    skr: Pubkey,
    plan: u16,
}

impl Env {
    /// Config with an SKR mint, SOL and SKR feeds registered with fresh
    /// prices, and the treasury's SKR ATA created.
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
        let pd = Pubkey::find_program_address(
            &[deadman::id().as_ref()],
            &anchor_lang::solana_program::bpf_loader_upgradeable::ID,
        )
        .0;
        let mut acc = svm.get_account(&pd).unwrap();
        acc.data[12] = 1;
        acc.data[13..45].copy_from_slice(admin.pubkey().as_ref());
        svm.set_account(pd, acc).unwrap();
        let skr = CreateMint::new(&mut svm, &admin)
            .decimals(6)
            .send()
            .unwrap();
        let mut env = Self {
            svm,
            admin,
            treasury,
            owner,
            guard,
            keeper,
            skr,
            plan: 0,
        };
        env.set_time(1_800_000_000);

        let admin = env.admin.insecure_clone();
        let ix = Instruction::new_with_bytes(
            deadman::id(),
            &deadman::instruction::InitConfig { skr_mint: skr }.data(),
            deadman::accounts::InitConfig {
                admin: admin.pubkey(),
                config: config_pda(),
                treasury: env.treasury.pubkey(),
                program: deadman::id(),
                program_data: pd,
                system_program: system_program::ID,
            }
            .to_account_metas(None),
        );
        env.send(ix, &[&admin]).unwrap();
        env.set_feed(&NATIVE_MINT, SOL_FEED, MAX_AGE).unwrap();
        env.set_feed(&skr, SKR_FEED, MAX_AGE).unwrap();
        env.post(SOL_FEED, SOL_PRICE, 0, true);
        env.post(SKR_FEED, SKR_PRICE, 0, true);
        let t = env.treasury.pubkey();
        env.create_ata(&t, &skr);
        env
    }

    fn vault_addr(&self) -> Pubkey {
        Pubkey::find_program_address(
            &[
                VAULT_SEED,
                self.owner.pubkey().as_ref(),
                &self.plan.to_le_bytes(),
            ],
            &deadman::id(),
        )
        .0
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

    fn balance(&self, k: &Pubkey) -> u64 {
        get_spl_account::<SplAccount>(&self.svm, k).unwrap().amount
    }

    fn supply(&self, mint: &Pubkey) -> u64 {
        get_spl_account::<SplMint>(&self.svm, mint).unwrap().supply
    }

    fn withdrawable(&self) -> u64 {
        let acc = self.svm.get_account(&self.vault_addr()).unwrap();
        let rent = self
            .svm
            .minimum_balance_for_rent_exemption(acc.data.len())
            .max(self.vault().rent_paid);
        acc.lamports - rent
    }

    fn create_ata(&mut self, owner: &Pubkey, mint: &Pubkey) -> Pubkey {
        let admin = self.admin.insecure_clone();
        CreateAssociatedTokenAccountIdempotent::new(&mut self.svm, &admin, mint)
            .owner(owner)
            .send()
            .unwrap()
    }

    fn mint_to(&mut self, mint: &Pubkey, to: &Pubkey, amount: u64) {
        let admin = self.admin.insecure_clone();
        MintTo::new(&mut self.svm, &admin, mint, to, amount)
            .send()
            .unwrap();
    }

    /// New 6-decimal mint with vault and treasury ATAs; `vault_amount` in
    /// the vault.
    fn token(&mut self, vault_amount: u64) -> Pubkey {
        let admin = self.admin.insecure_clone();
        let mint = CreateMint::new(&mut self.svm, &admin)
            .decimals(6)
            .send()
            .unwrap();
        let (v, t) = (self.vault_addr(), self.treasury.pubkey());
        let vault_ata = self.create_ata(&v, &mint);
        self.create_ata(&t, &mint);
        self.mint_to(&mint, &vault_ata, vault_amount);
        mint
    }

    fn set_feed_ix(&self, signer: &Pubkey, mint: &Pubkey, feed: &str, max_age: u32) -> Instruction {
        Instruction::new_with_bytes(
            deadman::id(),
            &deadman::instruction::SetPriceFeed {
                mint: *mint,
                feed_id: feed_id(feed),
                shard_id: 0,
                max_age_secs: max_age,
            }
            .data(),
            deadman::accounts::SetPriceFeed {
                admin: *signer,
                config: config_pda(),
                price_feed: price_feed_pda(mint),
                system_program: system_program::ID,
            }
            .to_account_metas(None),
        )
    }

    fn set_feed(&mut self, mint: &Pubkey, feed: &str, max_age: u32) -> Result<u64, String> {
        let admin = self.admin.insecure_clone();
        let ix = self.set_feed_ix(&admin.pubkey(), mint, feed, max_age);
        self.send(ix, &[&admin])
    }

    fn price_feed(&self, mint: &Pubkey) -> PriceFeed {
        let acc = self.svm.get_account(&price_feed_pda(mint)).unwrap();
        PriceFeed::try_deserialize(&mut acc.data.as_slice()).unwrap()
    }

    fn put(&mut self, address: &Pubkey, data: Vec<u8>, owner: Pubkey) {
        let mut acc = self.svm.get_account(&self.admin.pubkey()).unwrap();
        acc.lamports = self.svm.minimum_balance_for_rent_exemption(data.len());
        acc.data = data;
        acc.owner = owner;
        self.svm.set_account(*address, acc).unwrap();
    }

    /// Posts a price `age` seconds old to the feed's canonical account.
    fn post(&mut self, feed: &str, price: i64, age: i64, full: bool) {
        self.post_with(
            feed,
            feed,
            price,
            price as u64 / 1_000,
            age,
            full,
            PYTH_RECEIVER_ID,
        );
    }

    #[allow(clippy::too_many_arguments)]
    fn post_with(
        &mut self,
        at_feed: &str,
        feed: &str,
        price: i64,
        conf: u64,
        age: i64,
        full: bool,
        owner: Pubkey,
    ) {
        let data = price_update(&feed_id(feed), price, conf, self.now() - age, full);
        self.put(&canonical(&feed_id(at_feed)), data, owner);
    }

    fn create_plan(&mut self, rules: Vec<RuleInput>) -> Result<u64, String> {
        let mut ix = Instruction::new_with_bytes(
            deadman::id(),
            &deadman::instruction::CreatePlan {
                plan_id: self.plan,
                label: "Plan".to_string(),
                guard: self.guard.pubkey(),
                lock_secs: 3 * DAY,
                skip_grace_secs: 30 * DAY,
                rules: rules.clone(),
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
        let mut mints: Vec<Pubkey> = rules.iter().filter_map(|r| r.mint).collect();
        mints.dedup();
        ix.accounts
            .extend(mints.iter().map(|m| AccountMeta::new_readonly(*m, false)));
        let owner = self.owner.insecure_clone();
        self.send(ix, &[&owner])
    }

    fn update_plan(&mut self, rules: Vec<RuleInput>) -> Result<u64, String> {
        let mut ix = Instruction::new_with_bytes(
            deadman::id(),
            &deadman::instruction::UpdatePlan {
                label: "Plan".to_string(),
                lock_secs: 3 * DAY,
                skip_grace_secs: 30 * DAY,
                rules: rules.clone(),
                guardian: None,
            }
            .data(),
            deadman::accounts::OwnerAction {
                owner: self.owner.pubkey(),
                vault: self.vault_addr(),
            }
            .to_account_metas(None),
        );
        let mut mints: Vec<Pubkey> = rules.iter().filter_map(|r| r.mint).collect();
        mints.dedup();
        ix.accounts
            .extend(mints.iter().map(|m| AccountMeta::new_readonly(*m, false)));
        let owner = self.owner.insecure_clone();
        self.send(ix, &[&owner])
    }

    fn create_vesting(&mut self, schedules: Vec<VestingInput>) -> Result<u64, String> {
        let mut ix = Instruction::new_with_bytes(
            deadman::id(),
            &deadman::instruction::CreateVesting {
                plan_id: self.plan,
                label: "Vesting".to_string(),
                guard: self.guard.pubkey(),
                lock_secs: 3 * DAY,
                start_at: self.now(),
                revocable: false,
                schedules: schedules.clone(),
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
        ix.accounts.extend(
            schedules
                .iter()
                .filter_map(|s| s.mint)
                .map(|m| AccountMeta::new_readonly(m, false)),
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

    /// Gives the owner `amount` SKR and moves it into the fee reserve.
    fn fund(&mut self, amount: u64) -> Result<u64, String> {
        let (o, v, skr) = (self.owner.pubkey(), self.vault_addr(), self.skr);
        let owner_ata = self.create_ata(&o, &skr);
        self.create_ata(&v, &skr);
        self.mint_to(&skr, &owner_ata, amount);
        self.fund_with(&skr, amount)
    }

    fn fund_with(&mut self, mint: &Pubkey, amount: u64) -> Result<u64, String> {
        let (o, v) = (self.owner.pubkey(), self.vault_addr());
        let ix = Instruction::new_with_bytes(
            deadman::id(),
            &deadman::instruction::FundSkrReserve { amount }.data(),
            deadman::accounts::FundSkrReserve {
                owner: o,
                vault: v,
                config: config_pda(),
                mint: *mint,
                vault_token: ata(&v, mint),
                owner_token: ata(&o, mint),
                token_program: TOKEN_ID,
            }
            .to_account_metas(None),
        );
        let owner = self.owner.insecure_clone();
        self.send(ix, &[&owner])
    }

    fn owner_token_ix<T: InstructionData>(&self, data: T, mint: &Pubkey) -> Instruction {
        let (o, v) = (self.owner.pubkey(), self.vault_addr());
        Instruction::new_with_bytes(
            deadman::id(),
            &data.data(),
            deadman::accounts::WithdrawToken {
                owner: o,
                vault: v,
                mint: *mint,
                vault_token: ata(&v, mint),
                owner_token: ata(&o, mint),
                token_program: TOKEN_ID,
            }
            .to_account_metas(None),
        )
    }

    fn withdraw_reserve(&mut self, amount: u64) -> Result<u64, String> {
        let ix = self.owner_token_ix(
            deadman::instruction::WithdrawSkrReserve { amount },
            &self.skr,
        );
        let owner = self.owner.insecure_clone();
        self.send(ix, &[&owner])
    }

    fn withdraw_token(&mut self, mint: &Pubkey, amount: u64) -> Result<u64, String> {
        let ix = self.owner_token_ix(deadman::instruction::WithdrawToken { amount }, mint);
        let owner = self.owner.insecure_clone();
        self.send(ix, &[&owner])
    }

    /// The SKR fee accounts for a payout of `asset` (SOL: the native mint).
    fn skr_accounts(&self, asset: &Pubkey) -> Vec<AccountMeta> {
        let asset_feed = price_feed_pda(asset);
        let asset_price = self
            .svm
            .get_account(&asset_feed)
            .map(|_| self.price_feed(asset).price_account)
            .unwrap_or_default();
        vec![
            AccountMeta::new_readonly(asset_feed, false),
            AccountMeta::new_readonly(asset_price, false),
            AccountMeta::new_readonly(price_feed_pda(&self.skr), false),
            AccountMeta::new_readonly(self.price_feed(&self.skr).price_account, false),
            AccountMeta::new(ata(&self.vault_addr(), &self.skr), false),
            AccountMeta::new(self.skr, false),
            AccountMeta::new(ata(&self.treasury.pubkey(), &self.skr), false),
            AccountMeta::new_readonly(TOKEN_ID, false),
        ]
    }

    fn sol_ix<T: InstructionData>(
        &self,
        data: T,
        beneficiary: &Pubkey,
        extra: Vec<AccountMeta>,
    ) -> Instruction {
        let mut ix = Instruction::new_with_bytes(
            deadman::id(),
            &data.data(),
            deadman::accounts::ExecuteSolRule {
                executor: self.keeper.pubkey(),
                vault: self.vault_addr(),
                config: config_pda(),
                beneficiary: *beneficiary,
                treasury: self.treasury.pubkey(),
            }
            .to_account_metas(None),
        );
        ix.accounts.extend(extra);
        ix
    }

    fn token_ix<T: InstructionData>(
        &mut self,
        data: T,
        beneficiary: &Pubkey,
        mint: &Pubkey,
        extra: Vec<AccountMeta>,
    ) -> Instruction {
        self.create_ata(beneficiary, mint);
        let vault = self.vault_addr();
        let mut ix = Instruction::new_with_bytes(
            deadman::id(),
            &data.data(),
            deadman::accounts::ExecuteTokenRule {
                executor: self.keeper.pubkey(),
                vault,
                config: config_pda(),
                mint: *mint,
                vault_token: ata(&vault, mint),
                beneficiary: *beneficiary,
                beneficiary_token: ata(beneficiary, mint),
                treasury_token: Some(ata(&self.treasury.pubkey(), mint)),
                token_program: TOKEN_ID,
            }
            .to_account_metas(None),
        );
        ix.accounts.extend(extra);
        ix
    }

    fn run(&mut self, ix: Instruction) -> Result<u64, String> {
        let keeper = self.keeper.insecure_clone();
        self.send(ix, &[&keeper])
    }

    fn execute_sol(
        &mut self,
        beneficiary: &Pubkey,
        extra: Vec<AccountMeta>,
    ) -> Result<u64, String> {
        let ix = self.sol_ix(
            deadman::instruction::ExecuteSolRule { index: 0 },
            beneficiary,
            extra,
        );
        self.run(ix)
    }

    fn execute_token(
        &mut self,
        index: u8,
        beneficiary: &Pubkey,
        mint: &Pubkey,
        extra: Vec<AccountMeta>,
    ) -> Result<u64, String> {
        let ix = self.token_ix(
            deadman::instruction::ExecuteTokenRule { index },
            beneficiary,
            mint,
            extra,
        );
        self.run(ix)
    }

    fn treasury_skr(&self) -> u64 {
        self.balance(&ata(&self.treasury.pubkey(), &self.skr))
    }
}

/// A plan paying all its SOL to a fresh beneficiary, `sol` deposited and
/// `reserve` SKR in the fee reserve, with the tier due.
fn sol_plan(sol: u64, reserve: u64) -> (Env, Pubkey) {
    let mut env = Env::new();
    let b = Keypair::new().pubkey();
    env.create_plan(all_sol(&b)).unwrap();
    env.deposit_sol(sol);
    if reserve > 0 {
        env.fund(reserve).unwrap();
    }
    env.advance(10 * DAY + 1);
    env.post(SOL_FEED, SOL_PRICE, 0, true);
    env.post(SKR_FEED, SKR_PRICE, 0, true);
    (env, b)
}

/// Asserts the SOL payout fell back to the 2% fee in SOL and left the
/// reserve untouched.
fn assert_sol_fallback(env: &Env, b: &Pubkey, gross: u64, reserve: u64, treasury_before: u64) {
    let fee = gross * 200 / 10_000;
    assert_eq!(env.lamports(b), gross - fee);
    assert_eq!(env.lamports(&env.treasury.pubkey()), treasury_before + fee);
    assert_eq!(env.vault().skr_fee_reserve, reserve);
    assert_eq!(env.treasury_skr(), 0);
}

#[test]
fn set_price_feed_is_admin_only_capped_and_derives_the_canonical_account() {
    let mut env = Env::new();
    // The derivation matches the live shard-0 accounts.
    assert_eq!(
        env.price_feed(&NATIVE_MINT).price_account,
        Pubkey::from_str_const("7UVimffxr9ow1uXYxsr4LHAcV58mLzhmwaeKvJ1pjLiE")
    );
    assert_eq!(
        env.price_feed(&env.skr).price_account,
        Pubkey::from_str_const("AFrJWhfWt3vDtGPdcwTyLyHz8ZQ4M9L2z1YHThY5Vbj5")
    );
    let usdc = Pubkey::new_unique();
    env.set_feed(&usdc, USDC_FEED, 60).unwrap();
    let f = env.price_feed(&usdc);
    assert_eq!(
        f.price_account,
        Pubkey::from_str_const("Dpw1EAVrSB1ibxiDQyTAW6Zip3J4Btk2x4SgApQCeFbX")
    );
    assert_eq!(
        (f.mint, f.feed_id, f.max_age_secs),
        (usdc, feed_id(USDC_FEED), 60)
    );

    // Updating in place, and disabling with 0.
    env.set_feed(&usdc, USDC_FEED, 0).unwrap();
    assert_eq!(env.price_feed(&usdc).max_age_secs, 0);

    let intruder = Keypair::new();
    env.svm.airdrop(&intruder.pubkey(), SOL).unwrap();
    let ix = env.set_feed_ix(&intruder.pubkey(), &usdc, USDC_FEED, 60);
    let err = env.send(ix, &[&intruder]).unwrap_err();
    assert!(err.contains("Unauthorized"), "{err}");
    let err = env.set_feed(&usdc, USDC_FEED, 3_601).unwrap_err();
    assert!(err.contains("InvalidConfig"), "{err}");
    let err = env.set_feed(&Pubkey::default(), USDC_FEED, 60).unwrap_err();
    assert!(err.contains("InvalidConfig"), "{err}");
}

#[test]
fn sol_payout_pays_the_fee_in_skr_and_burns_ten_percent() {
    let (mut env, b) = sol_plan(10 * SOL, 10_000 * SKR);
    let gross = env.withdrawable();
    let treasury_sol = env.lamports(&env.treasury.pubkey());
    let supply = env.supply(&env.skr);
    let extra = env.skr_accounts(&NATIVE_MINT);
    let cu = env.execute_sol(&b, extra).unwrap();
    println!("execute_sol_rule with SKR fee: {cu} CU");

    // $1,500 payout: 1.5% = $22.50 = 1,125 SKR at $0.02.
    let fee = model_fee(gross, SOL_PRICE, 9, 150);
    assert_eq!(fee, 1_125 * SKR);
    let burned = fee / 10;
    assert_eq!(env.lamports(&b), gross, "beneficiary gets 100%");
    assert_eq!(env.lamports(&env.treasury.pubkey()), treasury_sol);
    assert_eq!(env.treasury_skr(), fee - burned);
    assert_eq!(env.supply(&env.skr), supply - burned);
    let v = env.vault();
    assert_eq!(v.skr_fee_reserve, 10_000 * SKR - fee);
    assert_eq!(v.rules[0].paid, gross);
    assert_eq!(
        env.balance(&ata(&env.vault_addr(), &env.skr)),
        10_000 * SKR - fee
    );
}

#[test]
fn token_payout_pays_the_fee_in_skr() {
    let mut env = Env::new();
    let b = Keypair::new().pubkey();
    env.create_plan(all_sol(&Keypair::new().pubkey())).unwrap();
    let usdc = env.token(1_000 * SKR);
    env.update_plan(vec![tier(&b, Some(usdc), AmountMode::Percent, 10_000)])
        .unwrap();
    env.set_feed(&usdc, USDC_FEED, MAX_AGE).unwrap();
    env.fund(1_000 * SKR).unwrap();
    env.advance(10 * DAY + 1);
    for (f, p) in [(SKR_FEED, SKR_PRICE), (USDC_FEED, USDC_PRICE)] {
        env.post(f, p, 30, true);
    }
    let extra = env.skr_accounts(&usdc);
    let cu = env.execute_token(0, &b, &usdc, extra).unwrap();
    println!("execute_token_rule with SKR fee: {cu} CU");

    // $1,000 payout: $15 = 750 SKR.
    let fee = model_fee(1_000 * SKR, USDC_PRICE, 6, 150);
    assert_eq!(fee, 750 * SKR);
    assert_eq!(env.balance(&ata(&b, &usdc)), 1_000 * SKR);
    assert_eq!(env.balance(&ata(&env.treasury.pubkey(), &usdc)), 0);
    assert_eq!(env.treasury_skr(), fee - fee / 10);
    assert_eq!(env.vault().skr_fee_reserve, 1_000 * SKR - fee);
}

#[test]
fn the_fee_rounds_up_in_the_protocol_favour() {
    // 1 SOL + 7 lamports: the exact fee is 112.5000007875 SKR.
    let (mut env, b) = sol_plan(SOL + 7, 200 * SKR);
    let gross = env.withdrawable();
    assert_eq!(gross, SOL + 7);
    let extra = env.skr_accounts(&NATIVE_MINT);
    env.execute_sol(&b, extra).unwrap();
    let fee = 200 * SKR - env.vault().skr_fee_reserve;
    assert_eq!(fee, 112_500_001);
    assert_eq!(fee, model_fee(gross, SOL_PRICE, 9, 150));
}

#[test]
fn unusable_prices_fall_back_to_the_asset_fee() {
    type Spoil = fn(&mut Env);
    let cases: [(&str, Spoil); 8] = [
        ("stale SOL", |e| {
            e.post(SOL_FEED, SOL_PRICE, i64::from(MAX_AGE) + 1, true)
        }),
        ("stale SKR", |e| {
            e.post(SKR_FEED, SKR_PRICE, i64::from(MAX_AGE) + 1, true)
        }),
        ("partial", |e| e.post(SOL_FEED, SOL_PRICE, 0, false)),
        ("wrong feed id", |e| {
            e.post_with(SOL_FEED, USDC_FEED, SOL_PRICE, 0, 0, true, PYTH_RECEIVER_ID)
        }),
        ("wrong owner", |e| {
            e.post_with(
                SOL_FEED,
                SOL_FEED,
                SOL_PRICE,
                0,
                0,
                true,
                system_program::ID,
            )
        }),
        ("wide confidence", |e| {
            let conf = SOL_PRICE as u64 / 50 + 1;
            e.post_with(
                SOL_FEED,
                SOL_FEED,
                SOL_PRICE,
                conf,
                0,
                true,
                PYTH_RECEIVER_ID,
            )
        }),
        ("negative price", |e| {
            e.post_with(SKR_FEED, SKR_FEED, -SKR_PRICE, 0, 0, true, PYTH_RECEIVER_ID)
        }),
        ("feed disabled", |e| {
            e.set_feed(&NATIVE_MINT, SOL_FEED, 0).unwrap();
        }),
    ];
    for (name, spoil) in cases {
        let (mut env, b) = sol_plan(10 * SOL, 10_000 * SKR);
        spoil(&mut env);
        let gross = env.withdrawable();
        let treasury = env.lamports(&env.treasury.pubkey());
        let extra = env.skr_accounts(&NATIVE_MINT);
        env.execute_sol(&b, extra)
            .unwrap_or_else(|e| panic!("{name}: {e}"));
        assert_sol_fallback(&env, &b, gross, 10_000 * SKR, treasury);
    }
}

#[test]
fn exactly_max_age_and_two_percent_confidence_are_still_usable() {
    let (mut env, b) = sol_plan(10 * SOL, 10_000 * SKR);
    env.post_with(
        SOL_FEED,
        SOL_FEED,
        SOL_PRICE,
        SOL_PRICE as u64 / 50,
        i64::from(MAX_AGE),
        true,
        PYTH_RECEIVER_ID,
    );
    let gross = env.withdrawable();
    let extra = env.skr_accounts(&NATIVE_MINT);
    env.execute_sol(&b, extra).unwrap();
    assert_eq!(env.lamports(&b), gross);
    assert!(env.vault().skr_fee_reserve < 10_000 * SKR);
}

#[test]
fn a_short_reserve_falls_back_and_keeps_the_reserve() {
    // The fee is 1,125 SKR; the reserve holds 1,124.
    let (mut env, b) = sol_plan(10 * SOL, 1_124 * SKR);
    let gross = env.withdrawable();
    let treasury = env.lamports(&env.treasury.pubkey());
    let extra = env.skr_accounts(&NATIVE_MINT);
    env.execute_sol(&b, extra).unwrap();
    assert_sol_fallback(&env, &b, gross, 1_124 * SKR, treasury);
}

#[test]
fn a_missing_treasury_skr_account_falls_back() {
    let mut env = Env::new();
    let b = Keypair::new().pubkey();
    env.create_plan(all_sol(&b)).unwrap();
    env.deposit_sol(10 * SOL);
    env.fund(10_000 * SKR).unwrap();
    // Close the treasury's SKR ATA (empty), as if never created.
    let t_ata = ata(&env.treasury.pubkey(), &env.skr);
    let mut acc = env.svm.get_account(&t_ata).unwrap();
    acc.data = vec![];
    acc.owner = system_program::ID;
    acc.lamports = 0;
    env.svm.set_account(t_ata, acc).unwrap();
    env.advance(10 * DAY + 1);
    env.post(SOL_FEED, SOL_PRICE, 0, true);
    env.post(SKR_FEED, SKR_PRICE, 0, true);
    let gross = env.withdrawable();
    let treasury = env.lamports(&env.treasury.pubkey());
    let extra = env.skr_accounts(&NATIVE_MINT);
    env.execute_sol(&b, extra).unwrap();
    let fee = gross * 200 / 10_000;
    assert_eq!(env.lamports(&b), gross - fee);
    assert_eq!(env.lamports(&env.treasury.pubkey()), treasury + fee);
    assert_eq!(env.vault().skr_fee_reserve, 10_000 * SKR);
}

#[test]
fn executors_cannot_substitute_or_omit_the_fee_accounts() {
    let (mut env, b) = sol_plan(10 * SOL, 10_000 * SKR);
    let good = env.skr_accounts(&NATIVE_MINT);

    let err = env.execute_sol(&b, vec![]).unwrap_err();
    assert!(err.contains("SkrFeeAccountsRequired"), "{err}");
    let err = env.execute_sol(&b, good[..7].to_vec()).unwrap_err();
    assert!(err.contains("SkrFeeAccountsRequired"), "{err}");

    // A fresh, valid SOL update at a non-canonical address.
    let other = Pubkey::new_unique();
    let data = price_update(&feed_id(SOL_FEED), SOL_PRICE, 0, env.now(), true);
    env.put(&other, data, PYTH_RECEIVER_ID);
    let unrelated = Keypair::new().pubkey();
    let swaps: Vec<(usize, Pubkey)> = vec![
        (1, other),
        (3, other),
        // The SKR feed passed as the SOL feed and the other way round.
        (0, price_feed_pda(&env.skr)),
        (2, price_feed_pda(&NATIVE_MINT)),
        // An address that is neither the feed nor its empty PDA.
        (0, unrelated),
        (4, ata(&env.owner.pubkey(), &env.skr)),
        (5, Pubkey::new_unique()),
        (6, ata(&env.owner.pubkey(), &env.skr)),
        (7, system_program::ID),
    ];
    for (i, key) in swaps {
        let mut extra = good.clone();
        extra[i].pubkey = key;
        let err = env.execute_sol(&b, extra).unwrap_err();
        assert!(err.contains("InvalidSkrFeeAccounts"), "slot {i}: {err}");
    }
    assert_eq!(env.vault().rules[0].executed_at, 0);

    env.execute_sol(&b, good).unwrap();
    assert!(env.vault().skr_fee_reserve < 10_000 * SKR);
}

#[test]
fn an_unregistered_asset_needs_its_empty_feed_address_and_falls_back() {
    let mut env = Env::new();
    let b = Keypair::new().pubkey();
    env.create_plan(all_sol(&Keypair::new().pubkey())).unwrap();
    let tok = env.token(1_000 * SKR);
    env.update_plan(vec![tier(&b, Some(tok), AmountMode::Percent, 10_000)])
        .unwrap();
    env.fund(500 * SKR).unwrap();
    env.advance(10 * DAY + 1);
    env.post(SKR_FEED, SKR_PRICE, 0, true);
    let extra = env.skr_accounts(&tok);
    assert_eq!(extra[0].pubkey, price_feed_pda(&tok));
    env.execute_token(0, &b, &tok, extra).unwrap();
    assert_eq!(env.balance(&ata(&b, &tok)), 980 * SKR);
    assert_eq!(env.balance(&ata(&env.treasury.pubkey(), &tok)), 20 * SKR);
    assert_eq!(env.vault().skr_fee_reserve, 500 * SKR);
}

#[test]
fn skr_payouts_stay_in_kind_and_never_touch_the_reserve() {
    let mut env = Env::new();
    let b = Keypair::new().pubkey();
    env.create_plan(all_sol(&Keypair::new().pubkey())).unwrap();
    let skr = env.skr;
    env.update_plan(vec![tier(&b, Some(skr), AmountMode::Percent, 10_000)])
        .unwrap();
    env.fund(300 * SKR).unwrap();
    // Tier funds: 1,000 SKR deposited directly next to the reserve.
    let vault_ata = ata(&env.vault_addr(), &skr);
    env.mint_to(&skr, &vault_ata, 1_000 * SKR);
    let supply = env.supply(&skr);
    env.advance(10 * DAY + 1);
    // No price accounts needed: the in-kind 1.5% applies.
    env.execute_token(0, &b, &skr, vec![]).unwrap();
    let fee = 1_000 * SKR * 150 / 10_000;
    assert_eq!(env.balance(&ata(&b, &skr)), 1_000 * SKR - fee);
    assert_eq!(env.treasury_skr(), fee - fee / 10);
    assert_eq!(env.supply(&skr), supply - fee / 10);
    assert_eq!(env.balance(&vault_ata), 300 * SKR);
    assert_eq!(env.vault().skr_fee_reserve, 300 * SKR);
}

#[test]
fn nft_payouts_stay_fee_free_without_fee_accounts() {
    let mut env = Env::new();
    let b = Keypair::new().pubkey();
    env.create_plan(all_sol(&Keypair::new().pubkey())).unwrap();
    let admin = env.admin.insecure_clone();
    let nft = CreateMint::new(&mut env.svm, &admin)
        .decimals(0)
        .send()
        .unwrap();
    let v = env.vault_addr();
    let vault_nft = env.create_ata(&v, &nft);
    let t = env.treasury.pubkey();
    env.create_ata(&t, &nft);
    env.mint_to(&nft, &vault_nft, 1);
    env.update_plan(vec![tier(&b, Some(nft), AmountMode::Fixed, 1)])
        .unwrap();
    env.fund(100 * SKR).unwrap();
    env.advance(10 * DAY + 1);
    env.execute_token(0, &b, &nft, vec![]).unwrap();
    assert_eq!(env.balance(&ata(&b, &nft)), 1);
    assert_eq!(env.vault().skr_fee_reserve, 100 * SKR);
}

#[test]
fn the_reserve_is_kept_apart_from_tier_funds() {
    let mut env = Env::new();
    let b = Keypair::new().pubkey();
    env.create_plan(all_sol(&Keypair::new().pubkey())).unwrap();
    let skr = env.skr;
    env.update_plan(vec![tier(&b, Some(skr), AmountMode::Percent, 5_000)])
        .unwrap();
    env.fund(300 * SKR).unwrap();
    let vault_ata = ata(&env.vault_addr(), &skr);
    env.mint_to(&skr, &vault_ata, 100 * SKR);

    // Tier withdrawals only see the 100 deposited SKR.
    let err = env.withdraw_token(&skr, 101 * SKR).unwrap_err();
    assert!(err.contains("FundsCommitted"), "{err}");
    env.withdraw_token(&skr, 40 * SKR).unwrap();
    assert_eq!(env.vault().skr_fee_reserve, 300 * SKR);

    // The reserve comes back without a fee, but never more than it holds.
    let err = env.withdraw_reserve(301 * SKR).unwrap_err();
    assert!(err.contains("InsufficientFunds"), "{err}");
    let before = env.balance(&ata(&env.owner.pubkey(), &skr));
    env.withdraw_reserve(100 * SKR).unwrap();
    assert_eq!(
        env.balance(&ata(&env.owner.pubkey(), &skr)),
        before + 100 * SKR
    );
    assert_eq!(env.vault().skr_fee_reserve, 200 * SKR);
    assert_eq!(env.balance(&vault_ata), 260 * SKR);

    // A due tier pays 50% of the 60 tier SKR, not of the reserve.
    env.advance(10 * DAY + 1);
    env.execute_token(0, &b, &skr, vec![]).unwrap();
    let gross = 30 * SKR;
    assert_eq!(env.balance(&ata(&b, &skr)), gross - gross * 150 / 10_000);
    assert_eq!(env.vault().skr_fee_reserve, 200 * SKR);
}

#[test]
fn skipping_reserves_tier_funds_only() {
    let mut env = Env::new();
    let b = Keypair::new().pubkey();
    env.create_plan(all_sol(&Keypair::new().pubkey())).unwrap();
    let skr = env.skr;
    env.update_plan(vec![tier(&b, Some(skr), AmountMode::Percent, 10_000)])
        .unwrap();
    env.fund(300 * SKR).unwrap();
    let vault_ata = ata(&env.vault_addr(), &skr);
    env.mint_to(&skr, &vault_ata, 100 * SKR);
    env.advance(41 * DAY);
    let ix = Instruction::new_with_bytes(
        deadman::id(),
        &deadman::instruction::SkipRule { index: 0 }.data(),
        deadman::accounts::SkipRule {
            caller: env.keeper.pubkey(),
            vault: env.vault_addr(),
            vault_token: Some(vault_ata),
        }
        .to_account_metas(None),
    );
    env.run(ix).unwrap();
    assert_eq!(env.vault().rules[0].reserved, 100 * SKR);
}

#[test]
fn reserve_funding_and_withdrawal_rules() {
    let mut env = Env::new();
    env.create_plan(all_sol(&Keypair::new().pubkey())).unwrap();

    // Only the config's SKR mint can fund the reserve.
    let other = env.token(0);
    let (o, v) = (env.owner.pubkey(), env.vault_addr());
    let owner_other = env.create_ata(&o, &other);
    env.mint_to(&other, &owner_other, 10 * SKR);
    let err = env.fund_with(&other, SKR).unwrap_err();
    assert!(err.contains("WrongAsset"), "{err}");
    let err = env
        .send(
            env.owner_token_ix(
                deadman::instruction::WithdrawSkrReserve { amount: 1 },
                &other,
            ),
            &[&env.owner.insecure_clone()],
        )
        .unwrap_err();
    assert!(err.contains("WrongAsset"), "{err}");

    env.fund(50 * SKR).unwrap();
    env.fund_with(&env.skr.clone(), 0).unwrap();
    let vault = env.vault();
    assert_eq!(
        (vault.skr_fee_reserve, vault.skr_reserve_mint),
        (50 * SKR, env.skr)
    );
    assert_eq!(env.balance(&ata(&v, &env.skr)), 50 * SKR);

    // Funding works during lockdown; withdrawing does not.
    let guard = env.guard.insecure_clone();
    let ix = Instruction::new_with_bytes(
        deadman::id(),
        &deadman::instruction::Lockdown {}.data(),
        deadman::accounts::Lockdown {
            signer: guard.pubkey(),
            vault: v,
        }
        .to_account_metas(None),
    );
    env.send(ix, &[&guard]).unwrap();
    let skr = env.skr;
    let owner_skr = ata(&o, &skr);
    env.mint_to(&skr, &owner_skr, 5 * SKR);
    env.fund_with(&skr, 5 * SKR).unwrap();
    let err = env.withdraw_reserve(SKR).unwrap_err();
    assert!(err.contains("VaultLocked"), "{err}");
    env.advance(3 * DAY + 1);
    env.withdraw_reserve(SKR).unwrap();
    assert_eq!(env.vault().skr_fee_reserve, 54 * SKR);
}

#[test]
fn closing_requires_the_reserve_withdrawn() {
    let mut env = Env::new();
    env.create_plan(all_sol(&Keypair::new().pubkey())).unwrap();
    env.fund(20 * SKR).unwrap();
    let close = |env: &mut Env| {
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
        env.send(ix, &[&owner])
    };
    let err = close(&mut env).unwrap_err();
    assert!(err.contains("FeeReserveNotEmpty"), "{err}");
    env.withdraw_reserve(20 * SKR).unwrap();
    close(&mut env).unwrap();
    assert!(env
        .svm
        .get_account(&env.vault_addr())
        .is_none_or(|a| a.lamports == 0));
}

#[test]
fn an_skr_mint_change_never_strands_the_reserve() {
    let (mut env, b) = sol_plan(10 * SOL, 100 * SKR);
    let old = env.skr;
    let admin = env.admin.insecure_clone();
    let new_skr = CreateMint::new(&mut env.svm, &admin)
        .decimals(6)
        .send()
        .unwrap();
    let ix = Instruction::new_with_bytes(
        deadman::id(),
        &deadman::instruction::SetConfig {
            fee_bps_public: 200,
            fee_bps_private: 200,
            skr_mint: new_skr,
            fee_bps_skr: 150,
            skr_burn_bps: 1_000,
        }
        .data(),
        deadman::accounts::SetConfig {
            admin: admin.pubkey(),
            config: config_pda(),
            treasury: env.treasury.pubkey(),
            system_program: system_program::ID,
        }
        .to_account_metas(None),
    );
    env.send(ix, &[&admin]).unwrap();

    // The old-mint reserve no longer pays fees or demands fee accounts...
    let gross = env.withdrawable();
    let treasury = env.lamports(&env.treasury.pubkey());
    env.execute_sol(&b, vec![]).unwrap();
    assert_eq!(env.lamports(&b), gross - gross * 200 / 10_000);
    assert_eq!(
        env.lamports(&env.treasury.pubkey()),
        treasury + gross * 200 / 10_000
    );
    // ...and the owner can still take it back in the old mint.
    env.skr = old;
    env.withdraw_reserve(100 * SKR).unwrap();
    assert_eq!(env.vault().skr_fee_reserve, 0);
}

#[test]
fn vesting_releases_pay_the_fee_in_skr() {
    let mut env = Env::new();
    let (b, c) = (Keypair::new().pubkey(), Keypair::new().pubkey());
    // The vault must exist before its token accounts.
    let usdc_admin = env.admin.insecure_clone();
    let usdc = CreateMint::new(&mut env.svm, &usdc_admin)
        .decimals(6)
        .send()
        .unwrap();
    let schedule = |beneficiary: Pubkey, mint: Option<Pubkey>, total: u64| VestingInput {
        beneficiary,
        rail: Rail::Solana,
        mint,
        total,
        cliff_secs: 0,
        duration_secs: 100 * DAY,
    };
    env.create_vesting(vec![
        schedule(b, None, 10 * SOL),
        schedule(c, Some(usdc), 1_000 * SKR),
    ])
    .unwrap();
    env.deposit_sol(10 * SOL);
    let (v, t) = (env.vault_addr(), env.treasury.pubkey());
    let vault_usdc = env.create_ata(&v, &usdc);
    env.create_ata(&t, &usdc);
    env.mint_to(&usdc, &vault_usdc, 1_000 * SKR);
    env.set_feed(&usdc, USDC_FEED, MAX_AGE).unwrap();
    env.fund(10_000 * SKR).unwrap();
    env.advance(50 * DAY);
    for (f, p) in [
        (SOL_FEED, SOL_PRICE),
        (SKR_FEED, SKR_PRICE),
        (USDC_FEED, USDC_PRICE),
    ] {
        env.post(f, p, 0, true);
    }

    let extra = env.skr_accounts(&NATIVE_MINT);
    let ix = env.sol_ix(
        deadman::instruction::ReleaseVestedSol { index: 0 },
        &b,
        extra,
    );
    env.run(ix).unwrap();
    assert_eq!(env.lamports(&b), 5 * SOL);
    let sol_fee = model_fee(5 * SOL, SOL_PRICE, 9, 150);
    assert_eq!(env.vault().skr_fee_reserve, 10_000 * SKR - sol_fee);

    let extra = env.skr_accounts(&usdc);
    let ix = env.token_ix(
        deadman::instruction::ReleaseVestedToken { index: 1 },
        &c,
        &usdc,
        extra,
    );
    env.run(ix).unwrap();
    assert_eq!(env.balance(&ata(&c, &usdc)), 500 * SKR);
    let usdc_fee = model_fee(500 * SKR, USDC_PRICE, 6, 150);
    assert_eq!(
        env.vault().skr_fee_reserve,
        10_000 * SKR - sol_fee - usdc_fee
    );
    assert_eq!(
        env.treasury_skr(),
        sol_fee - sol_fee / 10 + usdc_fee - usdc_fee / 10
    );
    assert_eq!(env.vault().rules[1].released, 500 * SKR);
}

#[test]
fn plans_without_a_reserve_need_no_fee_accounts() {
    let (mut env, b) = sol_plan(10 * SOL, 0);
    let gross = env.withdrawable();
    let treasury = env.lamports(&env.treasury.pubkey());
    env.execute_sol(&b, vec![]).unwrap();
    assert_sol_fallback(&env, &b, gross, 0, treasury);
}

#[test]
fn quote_math_handles_exponents_and_overflow() {
    use deadman::skr_fee_quote;
    // Same exponents and decimals: 1.5% of 1,000,000 units at equal prices.
    assert_eq!(
        skr_fee_quote(1_000_000, (5, -2), 6, (5, -2), 6, 150),
        Some(15_000)
    );
    // Positive and mixed exponents scale either side.
    assert_eq!(skr_fee_quote(1, (1, 2), 0, (1, 0), 0, 10_000), Some(100));
    assert_eq!(skr_fee_quote(100, (1, 0), 2, (1, 0), 0, 10_000), Some(1));
    // Round up.
    assert_eq!(skr_fee_quote(1, (1, 0), 0, (3, 0), 0, 10_000), Some(1));
    // Overflow, out-of-range scale and a zero price are refused.
    assert_eq!(
        skr_fee_quote(u64::MAX, (u64::MAX, 0), 0, (1, 0), 0, 500),
        None
    );
    assert_eq!(skr_fee_quote(1, (1, 40), 0, (1, 0), 0, 150), None);
    assert_eq!(skr_fee_quote(1, (1, 0), 0, (0, 0), 0, 150), None);
}
