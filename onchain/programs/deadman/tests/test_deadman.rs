use {
    anchor_lang::{
        prelude::{AccountMeta, Pubkey},
        solana_program::{
            clock::Clock, instruction::Instruction, system_instruction, system_program,
        },
        AccountDeserialize, InstructionData, ToAccountMetas,
    },
    anchor_spl::{
        associated_token::{self, get_associated_token_address_with_program_id},
        token_2022::spl_token_2022::{
            self,
            extension::{transfer_fee::instruction::initialize_transfer_fee_config, ExtensionType},
        },
    },
    deadman::{state::HeirInput, Config, Vault, VaultStatus, CLAIM_SEED, CONFIG_SEED, VAULT_SEED},
    litesvm::LiteSVM,
    litesvm_token::{
        get_spl_account, spl_token::state::Account as SplAccount, CreateAccount,
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
const GRACE: i64 = DAY;
const LOCK: i64 = 3 * DAY;
const FEE_BPS: u16 = 50;
const PLUS_PRICE: u64 = 100_000_000;

struct Env {
    svm: LiteSVM,
    admin: Keypair,
    treasury: Keypair,
    owner: Keypair,
    guard: Keypair,
    skr_mint: Pubkey,
    /// Compute units of the last successful transaction.
    last_cu: u64,
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

fn ata_with(owner: &Pubkey, mint: &Pubkey, program: &Pubkey) -> Pubkey {
    get_associated_token_address_with_program_id(owner, mint, program)
}

fn claim_pda(vault: &Pubkey, mint: &Pubkey) -> Pubkey {
    Pubkey::find_program_address(&[CLAIM_SEED, vault.as_ref(), mint.as_ref()], &deadman::id()).0
}

fn program_data_pda() -> Pubkey {
    Pubkey::find_program_address(
        &[deadman::id().as_ref()],
        &anchor_lang::solana_program::bpf_loader_upgradeable::ID,
    )
    .0
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
        for k in [&admin, &treasury, &owner, &guard] {
            svm.airdrop(&k.pubkey(), 100 * SOL).unwrap();
        }

        // LiteSVM deploys with no upgrade authority; set it to `admin` so
        // init_config's upgrade-authority gate can be exercised.
        let pd = program_data_pda();
        let mut acc = svm.get_account(&pd).unwrap();
        acc.data[12] = 1;
        acc.data[13..45].copy_from_slice(admin.pubkey().as_ref());
        svm.set_account(pd, acc).unwrap();

        let skr_mint = CreateMint::new(&mut svm, &admin)
            .decimals(6)
            .send()
            .unwrap();

        let mut env = Self {
            svm,
            admin,
            treasury,
            owner,
            guard,
            skr_mint,
            last_cu: 0,
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

    fn send(&mut self, ix: Instruction, signers: &[&Keypair]) -> Result<(), String> {
        self.send_ixs(&[ix], signers)
    }

    fn send_ixs(&mut self, ixs: &[Instruction], signers: &[&Keypair]) -> Result<(), String> {
        self.svm.expire_blockhash();
        let msg = Message::new_with_blockhash(
            ixs,
            Some(&signers[0].pubkey()),
            &self.svm.latest_blockhash(),
        );
        let tx = VersionedTransaction::try_new(VersionedMessage::Legacy(msg), signers).unwrap();
        let meta = self
            .svm
            .send_transaction(tx)
            .map_err(|e| format!("{:?}\n{}", e.err, e.meta.logs.join("\n")))?;
        self.last_cu = meta.compute_units_consumed;
        Ok(())
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

    fn init_config(&mut self, signer: &Keypair) -> Result<(), String> {
        let treasury = self.treasury.pubkey();
        self.init_config_with(signer, treasury, FEE_BPS)
    }

    fn init_config_with(
        &mut self,
        signer: &Keypair,
        treasury: Pubkey,
        fee_bps: u16,
    ) -> Result<(), String> {
        let ix = Instruction::new_with_bytes(
            deadman::id(),
            &deadman::instruction::InitConfig {
                treasury,
                skr_mint: self.skr_mint,
                plus_price: PLUS_PRICE,
                fee_bps,
            }
            .data(),
            deadman::accounts::InitConfig {
                admin: signer.pubkey(),
                config: config_pda(),
                program: deadman::id(),
                program_data: program_data_pda(),
                system_program: system_program::ID,
            }
            .to_account_metas(None),
        );
        let signer = signer.insecure_clone();
        self.send(ix, &[&signer])
    }

    fn set_config(
        &mut self,
        signer: &Keypair,
        treasury: Pubkey,
        plus_price: u64,
        fee_bps: u16,
    ) -> Result<(), String> {
        let ix = Instruction::new_with_bytes(
            deadman::id(),
            &deadman::instruction::SetConfig {
                treasury,
                skr_mint: self.skr_mint,
                plus_price,
                fee_bps,
            }
            .data(),
            deadman::accounts::SetConfig {
                admin: signer.pubkey(),
                config: config_pda(),
            }
            .to_account_metas(None),
        );
        let signer = signer.insecure_clone();
        self.send(ix, &[&signer])
    }

    fn config(&self) -> Config {
        let acc = self.svm.get_account(&config_pda()).unwrap();
        Config::try_deserialize(&mut acc.data.as_slice()).unwrap()
    }

    fn create_vault(&mut self, heirs: Vec<HeirInput>) -> Result<(), String> {
        let ix = Instruction::new_with_bytes(
            deadman::id(),
            &deadman::instruction::CreateVault {
                guard: self.guard.pubkey(),
                interval_secs: INTERVAL,
                grace_secs: GRACE,
                lock_secs: LOCK,
                heirs,
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
        heirs: Vec<HeirInput>,
        guardian: Option<Pubkey>,
    ) -> Result<(), String> {
        let ix = self.owner_ix(deadman::instruction::UpdatePolicy {
            interval_secs: INTERVAL,
            grace_secs: GRACE,
            lock_secs: LOCK,
            heirs,
            guardian,
        });
        let owner = self.owner.insecure_clone();
        self.send(ix, &[&owner])
    }

    fn pulse(&mut self, signer: &Keypair) -> Result<(), String> {
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

    fn lockdown(&mut self, signer: &Keypair) -> Result<(), String> {
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

    fn withdraw_sol(&mut self, amount: u64) -> Result<(), String> {
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

    fn trigger(&mut self, caller: &Keypair) -> Result<(), String> {
        let ix = Instruction::new_with_bytes(
            deadman::id(),
            &deadman::instruction::Trigger {}.data(),
            deadman::accounts::Trigger {
                caller: caller.pubkey(),
                vault: vault_pda(&self.owner.pubkey()),
            }
            .to_account_metas(None),
        );
        let caller = caller.insecure_clone();
        self.send(ix, &[&caller])
    }

    fn claim_sol(&mut self, heir: &Keypair) -> Result<(), String> {
        let treasury = self.treasury.pubkey();
        self.claim_sol_to(heir, treasury)
    }

    fn claim_sol_to(&mut self, heir: &Keypair, treasury: Pubkey) -> Result<(), String> {
        let ix = Instruction::new_with_bytes(
            deadman::id(),
            &deadman::instruction::ClaimSol {}.data(),
            deadman::accounts::ClaimSol {
                heir: heir.pubkey(),
                vault: vault_pda(&self.owner.pubkey()),
                config: config_pda(),
                treasury,
            }
            .to_account_metas(None),
        );
        let heir = heir.insecure_clone();
        self.send(ix, &[&heir])
    }

    fn claim_token(&mut self, heir: &Keypair, mint: &Pubkey) -> Result<(), String> {
        let vault_token = ata(&vault_pda(&self.owner.pubkey()), mint);
        self.claim_token_with(heir, mint, &TOKEN_ID, vault_token, &[])
    }

    fn claim_token_with(
        &mut self,
        heir: &Keypair,
        mint: &Pubkey,
        program: &Pubkey,
        vault_token: Pubkey,
        extra: &[AccountMeta],
    ) -> Result<(), String> {
        let vault = vault_pda(&self.owner.pubkey());
        let mut ix = Instruction::new_with_bytes(
            deadman::id(),
            &deadman::instruction::ClaimToken {}.data(),
            deadman::accounts::ClaimToken {
                heir: heir.pubkey(),
                vault,
                config: config_pda(),
                mint: *mint,
                vault_token,
                heir_token: ata_with(&heir.pubkey(), mint, program),
                treasury_token: ata_with(&self.treasury.pubkey(), mint, program),
                claim: claim_pda(&vault, mint),
                token_program: *program,
                associated_token_program: associated_token::ID,
                system_program: system_program::ID,
            }
            .to_account_metas(None),
        );
        ix.accounts.extend_from_slice(extra);
        let heir = heir.insecure_clone();
        self.send(ix, &[&heir])
    }

    fn withdraw_token(
        &mut self,
        signer: &Keypair,
        mint: &Pubkey,
        program: &Pubkey,
        amount: u64,
    ) -> Result<(), String> {
        let vault = vault_pda(&self.owner.pubkey());
        let ix = Instruction::new_with_bytes(
            deadman::id(),
            &deadman::instruction::WithdrawToken { amount }.data(),
            deadman::accounts::WithdrawToken {
                owner: signer.pubkey(),
                vault,
                mint: *mint,
                vault_token: ata_with(&vault, mint, program),
                owner_token: ata_with(&signer.pubkey(), mint, program),
                token_program: *program,
            }
            .to_account_metas(None),
        );
        let signer = signer.insecure_clone();
        self.send(ix, &[&signer])
    }

    fn close_vault(&mut self) -> Result<(), String> {
        let ix = Instruction::new_with_bytes(
            deadman::id(),
            &deadman::instruction::CloseVault {}.data(),
            deadman::accounts::CloseVault {
                owner: self.owner.pubkey(),
                vault: vault_pda(&self.owner.pubkey()),
            }
            .to_account_metas(None),
        );
        let owner = self.owner.insecure_clone();
        self.send(ix, &[&owner])
    }

    fn unlock(&mut self, guardian: &Keypair) -> Result<(), String> {
        let ix = Instruction::new_with_bytes(
            deadman::id(),
            &deadman::instruction::Unlock {}.data(),
            deadman::accounts::Unlock {
                owner: self.owner.pubkey(),
                guardian: guardian.pubkey(),
                vault: vault_pda(&self.owner.pubkey()),
            }
            .to_account_metas(None),
        );
        let owner = self.owner.insecure_clone();
        let guardian = guardian.insecure_clone();
        self.send(ix, &[&owner, &guardian])
    }

    fn set_guard(&mut self, new_guard: Pubkey) -> Result<(), String> {
        let ix = self.owner_ix(deadman::instruction::SetGuard { new_guard });
        let owner = self.owner.insecure_clone();
        self.send(ix, &[&owner])
    }

    fn new_mint(&mut self) -> Pubkey {
        let admin = self.admin.insecure_clone();
        CreateMint::new(&mut self.svm, &admin)
            .decimals(6)
            .send()
            .unwrap()
    }

    /// Token-2022 mint with a transfer-fee extension; `admin` is mint authority.
    fn new_fee_mint_2022(&mut self, fee_bps: u16) -> Pubkey {
        let admin = self.admin.insecure_clone();
        let mint = Keypair::new();
        let program = spl_token_2022::ID;
        let len = ExtensionType::try_calculate_account_len::<spl_token_2022::state::Mint>(&[
            ExtensionType::TransferFeeConfig,
        ])
        .unwrap();
        let ixs = [
            system_instruction::create_account(
                &admin.pubkey(),
                &mint.pubkey(),
                self.svm.minimum_balance_for_rent_exemption(len),
                len as u64,
                &program,
            ),
            initialize_transfer_fee_config(
                &program,
                &mint.pubkey(),
                Some(&admin.pubkey()),
                Some(&admin.pubkey()),
                fee_bps,
                u64::MAX,
            )
            .unwrap(),
            spl_token_2022::instruction::initialize_mint2(
                &program,
                &mint.pubkey(),
                &admin.pubkey(),
                None,
                6,
            )
            .unwrap(),
        ];
        self.send_ixs(&ixs, &[&admin, &mint]).unwrap();
        mint.pubkey()
    }

    fn subscribe(&mut self, months: u8) -> Result<(), String> {
        let ix = Instruction::new_with_bytes(
            deadman::id(),
            &deadman::instruction::Subscribe { months }.data(),
            deadman::accounts::Subscribe {
                owner: self.owner.pubkey(),
                vault: vault_pda(&self.owner.pubkey()),
                config: config_pda(),
                skr_mint: self.skr_mint,
                owner_skr: ata(&self.owner.pubkey(), &self.skr_mint),
                treasury_skr: ata(&self.treasury.pubkey(), &self.skr_mint),
                token_program: TOKEN_ID,
            }
            .to_account_metas(None),
        );
        let owner = self.owner.insecure_clone();
        self.send(ix, &[&owner])
    }

    /// Creates `owner`'s and `treasury`'s ATAs for `mint` and funds `owner`.
    fn fund_tokens(&mut self, mint: &Pubkey, owner: &Pubkey, amount: u64) -> Pubkey {
        self.fund_tokens_with(mint, owner, amount, &TOKEN_ID)
    }

    fn fund_tokens_with(
        &mut self,
        mint: &Pubkey,
        owner: &Pubkey,
        amount: u64,
        program: &Pubkey,
    ) -> Pubkey {
        let admin = self.admin.insecure_clone();
        self.svm.expire_blockhash();
        let account = CreateAssociatedTokenAccountIdempotent::new(&mut self.svm, &admin, mint)
            .owner(owner)
            .token_program_id(program)
            .send()
            .unwrap();
        CreateAssociatedTokenAccountIdempotent::new(&mut self.svm, &admin, mint)
            .owner(&self.treasury.pubkey())
            .token_program_id(program)
            .send()
            .unwrap();
        if amount > 0 {
            let ix = spl_token_2022::instruction::mint_to(
                program,
                mint,
                &account,
                &admin.pubkey(),
                &[],
                amount,
            )
            .unwrap();
            self.send(ix, &[&admin]).unwrap();
        }
        account
    }

    fn give_plus(&mut self) {
        let mint = self.skr_mint;
        let owner = self.owner.pubkey();
        self.fund_tokens(&mint, &owner, 10 * PLUS_PRICE);
        self.subscribe(1).unwrap();
    }
}

fn expect_err(res: Result<(), String>, code: &str) {
    let err = res.expect_err("transaction should fail");
    assert!(err.contains(code), "expected {code}, got:\n{err}");
}

fn heir(k: &Keypair, bps: u16) -> HeirInput {
    HeirInput {
        wallet: k.pubkey(),
        bps,
    }
}

fn ready() -> (Env, Keypair) {
    let mut env = Env::new();
    let admin = env.admin.insecure_clone();
    env.init_config(&admin).unwrap();
    let h = Keypair::new();
    env.svm.airdrop(&h.pubkey(), SOL).unwrap();
    env.create_vault(vec![heir(&h, 10_000)]).unwrap();
    (env, h)
}

#[test]
fn config_requires_upgrade_authority() {
    let mut env = Env::new();
    let intruder = Keypair::new();
    env.svm.airdrop(&intruder.pubkey(), SOL).unwrap();
    assert!(env.init_config(&intruder).is_err());

    let admin = env.admin.insecure_clone();
    env.init_config(&admin).unwrap();
    let acc = env.svm.get_account(&config_pda()).unwrap();
    let config = Config::try_deserialize(&mut acc.data.as_slice()).unwrap();
    assert_eq!(config.admin, admin.pubkey());
    assert_eq!(config.fee_bps, FEE_BPS);
}

#[test]
fn guard_pulses_and_streak_tracks_days() {
    let (mut env, _) = ready();
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
    assert_eq!(v.streak, 1, "missed days reset streak");
    assert_eq!(v.best_streak, 2);
    assert_eq!(v.total_pulses, 4);
    assert_eq!(v.last_pulse, env.now());

    let stranger = Keypair::new();
    env.svm.airdrop(&stranger.pubkey(), SOL).unwrap();
    assert!(env.pulse(&stranger).is_err());
}

#[test]
fn duress_lockdown_freezes_funds_but_not_guard_rotation() {
    let (mut env, h) = ready();
    env.deposit_sol(5 * SOL);
    env.withdraw_sol(SOL).unwrap();

    let guard = env.guard.insecure_clone();
    env.lockdown(&guard).unwrap();
    assert_eq!(env.vault().locked_until, env.now() + LOCK);

    assert!(env.withdraw_sol(SOL).is_err(), "withdraw blocked");
    let new_heir = Keypair::new();
    assert!(
        env.update_policy(vec![heir(&new_heir, 10_000)], None)
            .is_err(),
        "coercer cannot redirect inheritance"
    );

    // A stolen guard key can be rotated out during lockdown.
    let new_guard = Keypair::new();
    let ix = env.owner_ix(deadman::instruction::SetGuard {
        new_guard: new_guard.pubkey(),
    });
    let owner = env.owner.insecure_clone();
    env.send(ix, &[&owner]).unwrap();
    assert_eq!(env.vault().guard, new_guard.pubkey());
    assert!(env.lockdown(&guard).is_err(), "old guard revoked");

    env.advance(LOCK + 1);
    env.withdraw_sol(SOL).unwrap();
    env.update_policy(vec![heir(&h, 10_000)], None).unwrap();
}

#[test]
fn guard_cannot_move_funds() {
    let (mut env, _) = ready();
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
fn free_plan_limits_and_plus_unlocks_guardian() {
    let (mut env, h) = ready();
    let h2 = Keypair::new();
    let guardian = Keypair::new();
    assert!(env
        .update_policy(vec![heir(&h, 5_000), heir(&h2, 5_000)], None)
        .is_err());
    assert!(env
        .update_policy(vec![heir(&h, 10_000)], Some(guardian.pubkey()))
        .is_err());

    env.give_plus();
    let treasury_skr = ata(&env.treasury.pubkey(), &env.skr_mint);
    assert_eq!(env.token_balance(&treasury_skr), PLUS_PRICE);

    assert!(
        env.update_policy(vec![heir(&h, 6_000), heir(&h2, 5_000)], None)
            .is_err(),
        "bps must sum to 10000"
    );
    assert!(
        env.update_policy(vec![heir(&h, 5_000), heir(&h, 5_000)], None)
            .is_err(),
        "duplicate heirs rejected"
    );
    env.update_policy(
        vec![heir(&h, 6_000), heir(&h2, 4_000)],
        Some(guardian.pubkey()),
    )
    .unwrap();
    assert_eq!(env.vault().heirs.len(), 2);
}

#[test]
fn guardian_can_lock_and_cosign_early_unlock() {
    let (mut env, h) = ready();
    env.give_plus();
    let guardian = Keypair::new();
    env.svm.airdrop(&guardian.pubkey(), SOL).unwrap();
    env.update_policy(vec![heir(&h, 10_000)], Some(guardian.pubkey()))
        .unwrap();
    env.deposit_sol(SOL);

    env.lockdown(&guardian).unwrap();
    assert!(env.withdraw_sol(SOL / 2).is_err());

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
fn switch_fires_only_after_deadline_and_pays_heirs() {
    let (mut env, h) = ready();
    env.give_plus();
    let h2 = Keypair::new();
    env.svm.airdrop(&h2.pubkey(), SOL).unwrap();
    env.update_policy(vec![heir(&h, 7_500), heir(&h2, 2_500)], None)
        .unwrap();
    env.deposit_sol(10 * SOL);

    env.advance(INTERVAL + GRACE);
    assert!(env.trigger(&h).is_err(), "deadline is exclusive");
    env.advance(1);
    env.trigger(&h).unwrap();

    let v = env.vault();
    assert_eq!(v.status, VaultStatus::Triggered);
    assert!(v.sol_at_trigger >= 10 * SOL);
    assert!(
        env.withdraw_sol(SOL).is_err(),
        "owner locked out after trigger"
    );
    let guard = env.guard.insecure_clone();
    assert!(env.pulse(&guard).is_err(), "cannot pulse a fired switch");

    let snapshot = v.sol_at_trigger;
    let treasury_before = env.lamports(&env.treasury.pubkey());
    let h_before = env.lamports(&h.pubkey());
    env.claim_sol(&h).unwrap();
    let gross = snapshot * 7_500 / 10_000;
    let fee = gross * u64::from(FEE_BPS) / 10_000;
    assert_eq!(env.lamports(&h.pubkey()) - h_before, gross - fee - 5_000);
    assert_eq!(env.lamports(&env.treasury.pubkey()) - treasury_before, fee);
    assert!(env.claim_sol(&h).is_err(), "no double claim");

    env.claim_sol(&h2).unwrap();
    let stranger = Keypair::new();
    env.svm.airdrop(&stranger.pubkey(), SOL).unwrap();
    assert!(env.claim_sol(&stranger).is_err());

    // Rent reserve plus rounding dust stays behind.
    let rent_floor = env.svm.minimum_balance_for_rent_exemption(
        env.svm
            .get_account(&vault_pda(&env.owner.pubkey()))
            .unwrap()
            .data
            .len(),
    );
    assert!(env.lamports(&vault_pda(&env.owner.pubkey())) >= rent_floor);
}

#[test]
fn pulse_keeps_switch_from_firing() {
    let (mut env, h) = ready();
    env.advance(INTERVAL);
    let guard = env.guard.insecure_clone();
    env.pulse(&guard).unwrap();
    env.advance(INTERVAL);
    assert!(env.trigger(&h).is_err());
}

#[test]
fn heirs_claim_tokens_pro_rata() {
    let (mut env, h) = ready();
    env.give_plus();
    let h2 = Keypair::new();
    env.svm.airdrop(&h2.pubkey(), SOL).unwrap();
    env.update_policy(vec![heir(&h, 5_000), heir(&h2, 5_000)], None)
        .unwrap();

    let admin = env.admin.insecure_clone();
    let usdc = CreateMint::new(&mut env.svm, &admin)
        .decimals(6)
        .send()
        .unwrap();
    let vault = vault_pda(&env.owner.pubkey());
    let vault_usdc = env.fund_tokens(&usdc, &vault, 1_000_000_000);

    env.advance(INTERVAL + GRACE + 1);
    assert!(env.claim_token(&h, &usdc).is_err(), "not triggered yet");
    env.trigger(&h2).unwrap();

    env.claim_token(&h, &usdc).unwrap();
    assert!(env.claim_token(&h, &usdc).is_err());
    env.claim_token(&h2, &usdc).unwrap();

    let gross = 500_000_000u64;
    let fee = gross * u64::from(FEE_BPS) / 10_000;
    assert_eq!(env.token_balance(&ata(&h.pubkey(), &usdc)), gross - fee);
    assert_eq!(env.token_balance(&ata(&h2.pubkey(), &usdc)), gross - fee);
    assert_eq!(
        env.token_balance(&ata(&env.treasury.pubkey(), &usdc)),
        2 * fee
    );
    assert_eq!(env.token_balance(&vault_usdc), 0);
}

#[test]
fn set_config_requires_admin_and_validates() {
    let mut env = Env::new();
    let admin = env.admin.insecure_clone();
    expect_err(
        env.init_config_with(&admin, Pubkey::default(), FEE_BPS),
        "InvalidConfig",
    );
    assert!(env
        .init_config_with(&admin, env.treasury.pubkey(), 101)
        .is_err());
    env.init_config(&admin).unwrap();

    let intruder = Keypair::new();
    env.svm.airdrop(&intruder.pubkey(), SOL).unwrap();
    let rogue = intruder.pubkey();
    expect_err(env.set_config(&intruder, rogue, 0, 100), "Unauthorized");
    expect_err(env.set_config(&admin, rogue, 1, 101), "FeeTooHigh");
    expect_err(
        env.set_config(&admin, Pubkey::default(), 1, 10),
        "InvalidConfig",
    );

    let new_treasury = Keypair::new().pubkey();
    env.set_config(&admin, new_treasury, 7, 100).unwrap();
    let c = env.config();
    assert_eq!(c.treasury, new_treasury);
    assert_eq!(c.plus_price, 7);
    assert_eq!(c.fee_bps, 100);
    assert_eq!(c.admin, admin.pubkey());
}

#[test]
fn subscribe_enforces_month_bounds_and_stacks() {
    let (mut env, _) = ready();
    let mint = env.skr_mint;
    let owner = env.owner.pubkey();
    env.fund_tokens(&mint, &owner, 20 * PLUS_PRICE);

    expect_err(env.subscribe(0), "InvalidMonths");
    expect_err(env.subscribe(13), "InvalidMonths");

    let now = env.now();
    env.subscribe(12).unwrap();
    assert_eq!(env.vault().plus_until, now + 12 * 30 * DAY);
    env.advance(DAY);
    env.subscribe(1).unwrap();
    assert_eq!(env.vault().plus_until, now + 13 * 30 * DAY, "stacks");
    assert_eq!(
        env.token_balance(&ata(&env.treasury.pubkey(), &mint)),
        13 * PLUS_PRICE
    );
}

#[test]
fn withdraw_token_owner_only_and_frozen_by_lockdown() {
    let (mut env, _) = ready();
    let usdc = env.new_mint();
    let vault = vault_pda(&env.owner.pubkey());
    let vault_usdc = env.fund_tokens(&usdc, &vault, 1_000);
    let owner = env.owner.pubkey();
    env.fund_tokens(&usdc, &owner, 0);
    let guard = env.guard.insecure_clone();
    env.fund_tokens(&usdc, &guard.pubkey(), 0);

    assert!(
        env.withdraw_token(&guard, &usdc, &TOKEN_ID, 100).is_err(),
        "guard cannot pull tokens"
    );
    let o = env.owner.insecure_clone();
    env.withdraw_token(&o, &usdc, &TOKEN_ID, 400).unwrap();
    assert_eq!(env.token_balance(&ata(&owner, &usdc)), 400);
    expect_err(
        env.withdraw_token(&o, &usdc, &TOKEN_ID, 601),
        "InsufficientFunds",
    );

    env.lockdown(&guard).unwrap();
    expect_err(env.withdraw_token(&o, &usdc, &TOKEN_ID, 100), "VaultLocked");
    env.advance(LOCK + 1);
    env.withdraw_token(&o, &usdc, &TOKEN_ID, 600).unwrap();
    assert_eq!(env.token_balance(&vault_usdc), 0);
}

#[test]
fn close_vault_rules_and_stranded_tokens_are_recoverable() {
    let (mut env, h) = ready();
    env.deposit_sol(3 * SOL);
    let usdc = env.new_mint();
    let vault = vault_pda(&env.owner.pubkey());
    let vault_usdc = env.fund_tokens(&usdc, &vault, 500);
    let owner = env.owner.pubkey();
    env.fund_tokens(&usdc, &owner, 0);

    let guard = env.guard.insecure_clone();
    env.lockdown(&guard).unwrap();
    expect_err(env.close_vault(), "VaultLocked");
    env.advance(LOCK + 1);

    let vault_lamports = env.lamports(&vault);
    let owner_before = env.lamports(&owner);
    env.close_vault().unwrap();
    assert!(env.svm.get_account(&vault).is_none_or(|a| a.lamports == 0));
    assert_eq!(env.lamports(&owner), owner_before + vault_lamports - 5_000);

    // Tokens left in the vault ATA survive the close; re-creating the vault
    // at the same PDA gives the owner back control of them.
    assert_eq!(env.token_balance(&vault_usdc), 500);
    env.create_vault(vec![heir(&h, 10_000)]).unwrap();
    let o = env.owner.insecure_clone();
    env.withdraw_token(&o, &usdc, &TOKEN_ID, 500).unwrap();
    assert_eq!(env.token_balance(&ata(&owner, &usdc)), 500);

    env.advance(INTERVAL + GRACE + 1);
    env.trigger(&h).unwrap();
    expect_err(env.close_vault(), "VaultNotActive");
}

#[test]
fn claim_sol_rejects_wrong_treasury() {
    let (mut env, h) = ready();
    env.deposit_sol(SOL);
    env.advance(INTERVAL + GRACE + 1);
    env.trigger(&h).unwrap();
    let rogue = h.pubkey();
    expect_err(env.claim_sol_to(&h, rogue), "Unauthorized");
    assert!(!env.vault().heirs[0].claimed_sol);
    env.claim_sol(&h).unwrap();
}

#[test]
fn claim_token_rejects_non_ata_vault_account() {
    let (mut env, h) = ready();
    let usdc = env.new_mint();
    let vault = vault_pda(&env.owner.pubkey());
    let vault_ata = env.fund_tokens(&usdc, &vault, 1_000);

    let admin = env.admin.insecure_clone();
    let side = CreateAccount::new(&mut env.svm, &admin, &usdc)
        .owner(&vault)
        .send()
        .unwrap();
    MintTo::new(&mut env.svm, &admin, &usdc, &side, 9_000)
        .send()
        .unwrap();

    env.advance(INTERVAL + GRACE + 1);
    env.trigger(&h).unwrap();
    expect_err(
        env.claim_token_with(&h, &usdc, &TOKEN_ID, side, &[]),
        "ConstraintAssociated",
    );
    assert_eq!(env.token_balance(&side), 9_000);

    // Extra remaining accounts (transfer-hook slots) are harmless for plain SPL.
    let extra = [AccountMeta::new_readonly(Keypair::new().pubkey(), false)];
    env.claim_token_with(&h, &usdc, &TOKEN_ID, vault_ata, &extra)
        .unwrap();
    assert_eq!(env.token_balance(&vault_ata), 0);
}

#[test]
fn guardian_lockdown_lapses_with_plus() {
    let (mut env, h) = ready();
    env.give_plus();
    let guardian = Keypair::new();
    env.svm.airdrop(&guardian.pubkey(), SOL).unwrap();
    env.update_policy(vec![heir(&h, 10_000)], Some(guardian.pubkey()))
        .unwrap();

    env.lockdown(&guardian).unwrap();
    env.unlock(&guardian).unwrap();

    let guard = env.guard.insecure_clone();
    env.advance(31 * DAY);
    env.pulse(&guard).unwrap();
    expect_err(env.lockdown(&guardian), "PlusRequired");
    env.lockdown(&guard).unwrap();
    let owner = env.owner.insecure_clone();
    env.lockdown(&owner).unwrap();
}

#[test]
fn sol_fee_waived_when_treasury_cannot_hold_it() {
    let (mut env, h) = ready();
    env.deposit_sol(SOL / 10);
    let treasury = env.treasury.pubkey();
    env.svm.set_account(treasury, Default::default()).unwrap();

    env.advance(INTERVAL + GRACE + 1);
    env.trigger(&h).unwrap();
    let snapshot = env.vault().sol_at_trigger;
    let before = env.lamports(&h.pubkey());
    env.claim_sol(&h).unwrap();
    assert_eq!(env.lamports(&h.pubkey()) - before, snapshot - 5_000);
    assert_eq!(env.lamports(&treasury), 0);
}

#[test]
fn token2022_transfer_fee_mint_withdraw_and_claim() {
    let (mut env, h) = ready();
    let program = spl_token_2022::ID;
    let mint = env.new_fee_mint_2022(100);
    let vault = vault_pda(&env.owner.pubkey());
    let vault_token = env.fund_tokens_with(&mint, &vault, 1_100_000, &program);
    let owner = env.owner.pubkey();
    env.fund_tokens_with(&mint, &owner, 0, &program);

    let o = env.owner.insecure_clone();
    env.withdraw_token(&o, &mint, &program, 100_000).unwrap();
    assert_eq!(
        env.token_balance(&ata_with(&owner, &mint, &program)),
        99_000,
        "1% transfer fee withheld"
    );
    assert_eq!(env.token_balance(&vault_token), 1_000_000);

    env.advance(INTERVAL + GRACE + 1);
    env.trigger(&h).unwrap();
    env.claim_token_with(&h, &mint, &program, vault_token, &[])
        .unwrap();

    let fee = 1_000_000 * u64::from(FEE_BPS) / 10_000;
    let net = 1_000_000 - fee;
    assert_eq!(env.token_balance(&vault_token), 0, "vault debited exactly");
    assert_eq!(
        env.token_balance(&ata_with(&h.pubkey(), &mint, &program)),
        net - net / 100
    );
    assert_eq!(
        env.token_balance(&ata_with(&env.treasury.pubkey(), &mint, &program)),
        fee - fee / 100
    );
}

#[test]
fn compute_unit_profile() {
    let mut env = Env::new();
    let mut rows: Vec<(&str, u64)> = Vec::new();
    let admin = env.admin.insecure_clone();
    env.init_config(&admin).unwrap();
    rows.push(("init_config", env.last_cu));
    let t = env.treasury.pubkey();
    env.set_config(&admin, t, PLUS_PRICE, FEE_BPS).unwrap();
    rows.push(("set_config", env.last_cu));

    let h = Keypair::new();
    let h2 = Keypair::new();
    let guardian = Keypair::new();
    for k in [&h, &h2, &guardian] {
        env.svm.airdrop(&k.pubkey(), SOL).unwrap();
    }
    env.create_vault(vec![heir(&h, 10_000)]).unwrap();
    rows.push(("create_vault", env.last_cu));
    env.give_plus();
    rows.push(("subscribe", env.last_cu));
    env.update_policy(
        vec![heir(&h, 5_000), heir(&h2, 5_000)],
        Some(guardian.pubkey()),
    )
    .unwrap();
    rows.push(("update_policy (2 heirs)", env.last_cu));
    let guard = env.guard.insecure_clone();
    env.pulse(&guard).unwrap();
    rows.push(("pulse", env.last_cu));
    env.lockdown(&guardian).unwrap();
    rows.push(("lockdown", env.last_cu));
    env.unlock(&guardian).unwrap();
    rows.push(("unlock", env.last_cu));
    env.set_guard(guard.pubkey()).unwrap();
    rows.push(("set_guard", env.last_cu));

    env.deposit_sol(5 * SOL);
    env.withdraw_sol(SOL).unwrap();
    rows.push(("withdraw_sol", env.last_cu));
    let usdc = env.new_mint();
    let vault = vault_pda(&env.owner.pubkey());
    env.fund_tokens(&usdc, &vault, 1_000_000);
    let owner = env.owner.pubkey();
    env.fund_tokens(&usdc, &owner, 0);
    let o = env.owner.insecure_clone();
    env.withdraw_token(&o, &usdc, &TOKEN_ID, 1_000).unwrap();
    rows.push(("withdraw_token", env.last_cu));

    env.advance(INTERVAL + GRACE + 1);
    env.trigger(&h).unwrap();
    rows.push(("trigger", env.last_cu));
    env.claim_sol(&h).unwrap();
    rows.push(("claim_sol", env.last_cu));
    env.claim_token(&h, &usdc).unwrap();
    rows.push(("claim_token (first: init claim + ATA)", env.last_cu));
    env.claim_token(&h2, &usdc).unwrap();
    rows.push(("claim_token (second heir, init ATA)", env.last_cu));

    let (mut env2, _) = ready();
    env2.close_vault().unwrap();
    rows.push(("close_vault", env2.last_cu));

    println!("\n| instruction | CU |\n|---|---|");
    for (name, cu) in &rows {
        println!("| {name} | {cu} |");
        assert!(*cu > 0 && *cu < 200_000);
    }
}
