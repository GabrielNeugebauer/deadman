use anchor_lang::{prelude::*, system_program};
use anchor_spl::token;

use crate::{
    constants::*,
    error::DeadmanError,
    events::*,
    state::{PlanKind, RuleInput, Vault, VestingInput},
};

/// Every token mint a plan names must be passed in `remaining` (any order)
/// and be an initialised classic SPL Token mint. Token-2022 mints are
/// refused: their extensions (permanent delegate, transfer fees, hooks,
/// pausing) could take or block what the plan owes its beneficiaries.
fn require_classic_mints(
    mints: impl Iterator<Item = Pubkey>,
    remaining: &[AccountInfo],
) -> Result<()> {
    for mint in mints {
        let info = remaining
            .iter()
            .find(|a| a.key() == mint)
            .ok_or(DeadmanError::UnsupportedMint)?;
        require!(info.owner == &token::ID, DeadmanError::UnsupportedMint);
        token::Mint::try_deserialize(&mut &info.try_borrow_data()?[..])
            .map_err(|_| error!(DeadmanError::UnsupportedMint))?;
    }
    Ok(())
}

#[derive(Accounts)]
#[instruction(plan_id: u16)]
pub struct CreateVault<'info> {
    pub owner: Signer<'info>,
    /// Funds the vault's rent: the owner, or a fee sponsor such as Kora
    /// that charges the owner in USDC instead.
    #[account(mut)]
    pub payer: Signer<'info>,
    /// CHECK: the new plan's address, created in [`create_vault_account`].
    #[account(
        mut,
        seeds = [VAULT_SEED, owner.key().as_ref(), &plan_id.to_le_bytes()],
        bump
    )]
    pub vault: UncheckedAccount<'info>,
    pub system_program: Program<'info, System>,
}

/// Creates the plan account and returns the rent the payer deposited:
/// the rent minimum less whatever the address already held, so a sponsor
/// is never refunded lamports someone else sent there.
fn create_vault_account(a: &CreateVault, plan_id: u16, bump: u8) -> Result<u64> {
    let vault = a.vault.to_account_info();
    require!(
        vault.owner == &System::id() && vault.data_is_empty(),
        ErrorCode::AccountNotSystemOwned
    );
    let owner = a.owner.key();
    let plan_id = plan_id.to_le_bytes();
    let seeds: &[&[u8]] = &[VAULT_SEED, owner.as_ref(), &plan_id, &[bump]];
    let space = u64::try_from(Vault::SPACE).map_err(|_| DeadmanError::MathOverflow)?;
    let rent = Rent::get()?.minimum_balance(Vault::SPACE);
    let held = vault.lamports();
    let deposit = rent.saturating_sub(held);
    let system = a.system_program.key();
    if held == 0 {
        system_program::create_account(
            CpiContext::new_with_signer(
                system,
                system_program::CreateAccount {
                    from: a.payer.to_account_info(),
                    to: vault,
                },
                &[seeds],
            ),
            rent,
            space,
            &crate::ID,
        )?;
        return Ok(deposit);
    }
    if deposit > 0 {
        system_program::transfer(
            CpiContext::new(
                system,
                system_program::Transfer {
                    from: a.payer.to_account_info(),
                    to: vault.clone(),
                },
            ),
            deposit,
        )?;
    }
    system_program::allocate(
        CpiContext::new_with_signer(
            system,
            system_program::Allocate {
                account_to_allocate: vault.clone(),
            },
            &[seeds],
        ),
        space,
    )?;
    system_program::assign(
        CpiContext::new_with_signer(
            system,
            system_program::Assign {
                account_to_assign: vault,
            },
            &[seeds],
        ),
        &crate::ID,
    )?;
    Ok(deposit)
}

fn write_vault(info: &AccountInfo, vault: &Vault) -> Result<()> {
    let mut data = info.try_borrow_mut_data()?;
    vault.try_serialize(&mut &mut data[..])
}

pub fn handle_create_plan(
    ctx: Context<CreateVault>,
    plan_id: u16,
    label: String,
    guard: Pubkey,
    lock_secs: i64,
    skip_grace_secs: i64,
    rules: Vec<RuleInput>,
) -> Result<()> {
    let owner = ctx.accounts.owner.key();
    require!(
        guard != Pubkey::default() && guard != owner,
        DeadmanError::InvalidGuard
    );
    require_classic_mints(rules.iter().filter_map(|r| r.mint), ctx.remaining_accounts)?;
    let now = Clock::get()?.unix_timestamp;
    let rent_paid = create_vault_account(ctx.accounts, plan_id, ctx.bumps.vault)?;
    let mut vault = Vault::new(
        owner,
        plan_id,
        guard,
        PlanKind::Inheritance,
        ctx.accounts.payer.key(),
        rent_paid,
        ctx.bumps.vault,
    );
    vault.set_label(label)?;
    let key = ctx.accounts.vault.key();
    vault.apply_policy(&key, lock_secs, skip_grace_secs, &rules, None)?;
    vault.record_owner_pulse(now)?;
    write_vault(&ctx.accounts.vault, &vault)?;

    emit!(VaultCreated {
        vault: key,
        owner,
        plan_id,
        rules: vault.rules.len() as u8,
    });
    Ok(())
}

#[derive(Accounts)]
pub struct OwnerAction<'info> {
    #[account(mut)]
    pub owner: Signer<'info>,
    #[account(
        mut,
        seeds = [VAULT_SEED, owner.key().as_ref(), &vault.plan_id.to_le_bytes()],
        bump = vault.bump,
        has_one = owner @ DeadmanError::Unauthorized
    )]
    pub vault: Account<'info, Vault>,
}

/// Installs new pending tiers; tiers that paid or were skipped stay as
/// history so they can never pay twice. Blocked during lockdown so a
/// coercer cannot redirect the payouts, and once every tier has released
/// (`PlanCompleted`): a released plan is final.
pub fn handle_update_plan(
    ctx: Context<OwnerAction>,
    label: String,
    lock_secs: i64,
    skip_grace_secs: i64,
    rules: Vec<RuleInput>,
    guardian: Option<Pubkey>,
) -> Result<()> {
    let now = Clock::get()?.unix_timestamp;
    let vault = &mut ctx.accounts.vault;
    vault.require_kind(PlanKind::Inheritance)?;
    vault.require_unlocked(now)?;
    require!(!vault.is_completed(), DeadmanError::PlanCompleted);
    require_classic_mints(rules.iter().filter_map(|r| r.mint), ctx.remaining_accounts)?;
    vault.set_label(label)?;
    let key = vault.key();
    vault.apply_policy(&key, lock_secs, skip_grace_secs, &rules, guardian)?;
    vault.record_owner_pulse(now)?;
    emit!(PolicyUpdated {
        vault: vault.key(),
        rules: vault.rules.len() as u8,
    });
    Ok(())
}

/// Allowed during lockdown so a stolen device key cannot keep the vault
/// frozen. The guard can never move funds.
pub fn handle_set_guard(ctx: Context<OwnerAction>, new_guard: Pubkey) -> Result<()> {
    let now = Clock::get()?.unix_timestamp;
    let vault = &mut ctx.accounts.vault;
    require!(
        new_guard != Pubkey::default()
            && new_guard != vault.owner
            && Some(new_guard) != vault.guardian
            && !vault.rules.iter().any(|r| r.beneficiary == new_guard),
        DeadmanError::InvalidGuard
    );
    vault.guard = new_guard;
    vault.record_owner_pulse(now)
}

#[derive(Accounts)]
pub struct Pulse<'info> {
    pub signer: Signer<'info>,
    #[account(
        mut,
        seeds = [VAULT_SEED, vault.owner.as_ref(), &vault.plan_id.to_le_bytes()],
        bump = vault.bump,
        constraint = signer.key() == vault.owner || signer.key() == vault.guard
            @ DeadmanError::Unauthorized
    )]
    pub vault: Account<'info, Vault>,
}

/// Check-ins can stop pending tiers, but a fully released plan is over.
pub fn handle_pulse(ctx: Context<Pulse>) -> Result<()> {
    let now = Clock::get()?.unix_timestamp;
    let vault = &mut ctx.accounts.vault;
    vault.require_kind(PlanKind::Inheritance)?;
    require!(!vault.is_completed(), DeadmanError::PlanCompleted);
    if ctx.accounts.signer.key() == vault.owner {
        vault.record_owner_pulse(now)?;
    } else {
        vault.check_guard_pulse(now)?;
        vault.record_pulse(now)?;
    }
    emit!(Pulsed {
        vault: vault.key(),
        by: ctx.accounts.signer.key(),
        streak: vault.streak,
        at: now,
    });
    Ok(())
}

#[derive(Accounts)]
pub struct Lockdown<'info> {
    pub signer: Signer<'info>,
    #[account(
        mut,
        seeds = [VAULT_SEED, vault.owner.as_ref(), &vault.plan_id.to_le_bytes()],
        bump = vault.bump,
        constraint = signer.key() == vault.owner
            || signer.key() == vault.guard
            || Some(signer.key()) == vault.guardian
            @ DeadmanError::Unauthorized
    )]
    pub vault: Account<'info, Vault>,
}

/// Duress / panic: freezes withdrawals and policy changes for `lock_secs`.
/// Does not reset the switch, so inheritance keeps working.
///
/// A guardian lockdown is rate-limited: after any lockdown expires the
/// owner gets an unlocked window of `lock_secs` to remove a rogue guardian,
/// so a later guard lockdown cannot shrink that window.
pub fn handle_lockdown(ctx: Context<Lockdown>) -> Result<()> {
    let now = Clock::get()?.unix_timestamp;
    let signer = ctx.accounts.signer.key();
    let vault = &mut ctx.accounts.vault;
    if signer != vault.owner && signer != vault.guard {
        require!(
            now >= vault.guardian_ready_at,
            DeadmanError::GuardianCooldown
        );
    }
    let until = now
        .checked_add(vault.lock_secs)
        .ok_or(DeadmanError::MathOverflow)?;
    vault.locked_until = vault.locked_until.max(until);
    if vault.guardian.is_some() {
        let ready = vault
            .locked_until
            .checked_add(vault.lock_secs)
            .ok_or(DeadmanError::MathOverflow)?;
        vault.guardian_ready_at = vault.guardian_ready_at.max(ready);
    }
    emit!(LockedDown {
        vault: vault.key(),
        by: signer,
        until: vault.locked_until,
    });
    Ok(())
}

#[derive(Accounts)]
pub struct Unlock<'info> {
    pub owner: Signer<'info>,
    pub guardian: Signer<'info>,
    #[account(
        mut,
        seeds = [VAULT_SEED, owner.key().as_ref(), &vault.plan_id.to_le_bytes()],
        bump = vault.bump,
        has_one = owner @ DeadmanError::Unauthorized
    )]
    pub vault: Account<'info, Vault>,
}

/// Early unlock needs both the owner and the guardian in person.
pub fn handle_unlock(ctx: Context<Unlock>) -> Result<()> {
    let now = Clock::get()?.unix_timestamp;
    let vault = &mut ctx.accounts.vault;
    let guardian = vault.guardian.ok_or(DeadmanError::NoGuardian)?;
    require_keys_eq!(
        guardian,
        ctx.accounts.guardian.key(),
        DeadmanError::Unauthorized
    );
    vault.locked_until = now;
    vault.record_owner_pulse(now)?;
    emit!(Unlocked {
        vault: vault.key(),
        at: now,
    });
    Ok(())
}

#[derive(Accounts)]
pub struct CloseVault<'info> {
    #[account(mut)]
    pub owner: Signer<'info>,
    #[account(
        mut,
        seeds = [VAULT_SEED, owner.key().as_ref(), &vault.plan_id.to_le_bytes()],
        bump = vault.bump,
        has_one = owner @ DeadmanError::Unauthorized,
        has_one = rent_payer @ DeadmanError::Unauthorized,
        close = rent_payer
    )]
    pub vault: Account<'info, Vault>,
    /// CHECK: lamport destination only; pinned to the stored rent payer.
    #[account(mut)]
    pub rent_payer: UncheckedAccount<'info>,
}

/// The rent payer (the owner, or a fee sponsor) gets back exactly the rent
/// it deposited and the owner everything else, even if the rent sysvar
/// changed since. Plans close only once nothing is owed: every vesting
/// schedule released, and no skipped tier still holds a reserved share.
pub fn handle_close_vault(ctx: Context<CloseVault>) -> Result<()> {
    let now = Clock::get()?.unix_timestamp;
    let vault = &ctx.accounts.vault;
    vault.require_unlocked(now)?;
    require!(!vault.has_pending_reserve(), DeadmanError::FundsCommitted);
    if vault.kind == PlanKind::Vesting {
        for (i, r) in vault.rules.iter().enumerate() {
            require!(
                vault.vesting_cap(i)? <= r.released,
                DeadmanError::FundsCommitted
            );
        }
    }
    let excess = vault
        .to_account_info()
        .lamports()
        .saturating_sub(vault.rent_paid);
    if excess > 0 && ctx.accounts.rent_payer.key() != ctx.accounts.owner.key() {
        ctx.accounts.vault.sub_lamports(excess)?;
        ctx.accounts.owner.add_lamports(excess)?;
    }
    Ok(())
}

/// Creates a vesting plan: each schedule vests linearly from `start_at`
/// regardless of check-ins, continuously (`period_secs` 0) or in
/// installments of `period_secs`. Revocable plans let the owner stop future
/// vesting; what already vested always stays with the beneficiary.
#[allow(clippy::too_many_arguments)]
pub fn handle_create_vesting(
    ctx: Context<CreateVault>,
    plan_id: u16,
    label: String,
    guard: Pubkey,
    lock_secs: i64,
    start_at: i64,
    revocable: bool,
    schedules: Vec<VestingInput>,
    period_secs: i64,
) -> Result<()> {
    let owner = ctx.accounts.owner.key();
    require!(
        guard != Pubkey::default() && guard != owner,
        DeadmanError::InvalidGuard
    );
    require!(
        (MIN_LOCK_SECS..=MAX_LOCK_SECS).contains(&lock_secs),
        DeadmanError::InvalidDuration
    );
    require_classic_mints(
        schedules.iter().filter_map(|v| v.mint),
        ctx.remaining_accounts,
    )?;
    let now = Clock::get()?.unix_timestamp;
    let rent_paid = create_vault_account(ctx.accounts, plan_id, ctx.bumps.vault)?;
    let mut vault = Vault::new(
        owner,
        plan_id,
        guard,
        PlanKind::Vesting,
        ctx.accounts.payer.key(),
        rent_paid,
        ctx.bumps.vault,
    );
    vault.revocable = revocable;
    vault.lock_secs = lock_secs;
    vault.set_label(label)?;
    let key = ctx.accounts.vault.key();
    vault.apply_vesting(&key, now, start_at, period_secs, &schedules)?;
    vault.record_owner_pulse(now)?;
    write_vault(&ctx.accounts.vault, &vault)?;
    emit!(VaultCreated {
        vault: key,
        owner,
        plan_id,
        rules: vault.rules.len() as u8,
    });
    Ok(())
}

/// Stops future vesting of a revocable plan. Already vested amounts stay
/// claimable; the owner may then withdraw the rest. Blocked during
/// lockdown so a coercer cannot force it, and once every schedule has
/// released in full (`PlanCompleted`).
pub fn handle_revoke_vesting(ctx: Context<OwnerAction>) -> Result<()> {
    let now = Clock::get()?.unix_timestamp;
    let vault = &mut ctx.accounts.vault;
    vault.require_kind(PlanKind::Vesting)?;
    vault.require_unlocked(now)?;
    require!(!vault.is_completed(), DeadmanError::PlanCompleted);
    require!(vault.revocable, DeadmanError::NotRevocable);
    require!(vault.revoked_at == 0, DeadmanError::AlreadyRevoked);
    vault.revoked_at = now;
    vault.record_owner_pulse(now)?;
    emit!(VestingRevoked {
        vault: vault.key(),
        at: now,
    });
    Ok(())
}

#[derive(Accounts)]
#[instruction(plan_id: u16)]
pub struct RecoverLegacyVault<'info> {
    #[account(mut)]
    pub owner: Signer<'info>,
    /// CHECK: a vault in an older layout that no longer decodes as `Vault`;
    /// pinned to this owner's plan address here and its bytes are checked
    /// in the handler.
    #[account(
        mut,
        owner = crate::ID @ DeadmanError::NotLegacyVault,
        seeds = [VAULT_SEED, owner.key().as_ref(), &plan_id.to_le_bytes()],
        bump
    )]
    pub legacy: UncheckedAccount<'info>,
}

/// Closes a plan account left in an older layout by a program upgrade,
/// which no other instruction can read: every lamport goes to the owner
/// recorded in it. Tokens in that plan's token accounts are not moved; a
/// later plan at the same address controls them again.
pub fn handle_recover_legacy_vault(ctx: Context<RecoverLegacyVault>, plan_id: u16) -> Result<()> {
    let owner = &ctx.accounts.owner;
    let legacy = ctx.accounts.legacy.to_account_info();
    let data_len = legacy.data_len();
    {
        let data = legacy.try_borrow_data()?;
        require!(
            data_len != Vault::SPACE
                && data_len >= 42
                && data[..8] == *Vault::DISCRIMINATOR
                && data[40..42] == plan_id.to_le_bytes(),
            DeadmanError::NotLegacyVault
        );
        require!(
            data[8..40] == owner.key().to_bytes(),
            DeadmanError::Unauthorized
        );
    }
    let lamports = legacy.lamports();
    legacy.sub_lamports(lamports)?;
    owner.add_lamports(lamports)?;
    legacy.assign(&System::id());
    legacy.resize(0)?;
    emit!(LegacyVaultRecovered {
        vault: legacy.key(),
        owner: owner.key(),
        plan_id,
        data_len: u32::try_from(data_len).map_err(|_| DeadmanError::MathOverflow)?,
        lamports,
    });
    Ok(())
}
