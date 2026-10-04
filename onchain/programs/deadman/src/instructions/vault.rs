use anchor_lang::prelude::*;

use crate::{
    constants::*,
    error::DeadmanError,
    events::*,
    state::{PlanKind, RuleInput, Vault, VestingInput},
};

#[derive(Accounts)]
#[instruction(plan_id: u16)]
pub struct CreateVault<'info> {
    pub owner: Signer<'info>,
    /// Funds the vault's rent: the owner, or a fee sponsor such as Kora
    /// that charges the owner in USDC instead.
    #[account(mut)]
    pub payer: Signer<'info>,
    #[account(
        init,
        payer = payer,
        space = Vault::SPACE,
        seeds = [VAULT_SEED, owner.key().as_ref(), &plan_id.to_le_bytes()],
        bump
    )]
    pub vault: Account<'info, Vault>,
    pub system_program: Program<'info, System>,
}

/// Rent deposited by `init` for the account's actual size.
fn init_rent(vault: &Account<Vault>) -> Result<u64> {
    Ok(Rent::get()?.minimum_balance(vault.to_account_info().data_len()))
}

#[allow(clippy::too_many_arguments)]
pub fn handle_create_vault(
    ctx: Context<CreateVault>,
    plan_id: u16,
    label: String,
    guard: Pubkey,
    interval_secs: i64,
    lock_secs: i64,
    skip_grace_secs: i64,
    rules: Vec<RuleInput>,
) -> Result<()> {
    let owner = ctx.accounts.owner.key();
    require!(
        guard != Pubkey::default() && guard != owner,
        DeadmanError::InvalidGuard
    );
    let now = Clock::get()?.unix_timestamp;
    let vault = &mut ctx.accounts.vault;
    vault.owner = owner;
    vault.plan_id = plan_id;
    vault.guard = guard;
    vault.bump = ctx.bumps.vault;
    vault.kind = PlanKind::Inheritance;
    vault.rent_payer = ctx.accounts.payer.key();
    vault.rent_paid = init_rent(vault)?;
    vault.set_label(label)?;
    let key = vault.key();
    vault.apply_policy(
        &key,
        interval_secs,
        lock_secs,
        skip_grace_secs,
        &rules,
        None,
    )?;
    vault.record_owner_pulse(now)?;

    emit!(VaultCreated {
        vault: vault.key(),
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
/// coercer cannot redirect the payouts.
pub fn handle_update_policy(
    ctx: Context<OwnerAction>,
    label: String,
    interval_secs: i64,
    lock_secs: i64,
    skip_grace_secs: i64,
    rules: Vec<RuleInput>,
    guardian: Option<Pubkey>,
) -> Result<()> {
    let now = Clock::get()?.unix_timestamp;
    let vault = &mut ctx.accounts.vault;
    vault.require_kind(PlanKind::Inheritance)?;
    vault.require_unlocked(now)?;
    vault.set_label(label)?;
    let key = vault.key();
    vault.apply_policy(
        &key,
        interval_secs,
        lock_secs,
        skip_grace_secs,
        &rules,
        guardian,
    )?;
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
/// A guardian lockdown is rate-limited: after it expires the owner gets an
/// unlocked window of `lock_secs` to remove a rogue guardian.
pub fn handle_lockdown(ctx: Context<Lockdown>) -> Result<()> {
    let now = Clock::get()?.unix_timestamp;
    let signer = ctx.accounts.signer.key();
    let vault = &mut ctx.accounts.vault;
    let until = now
        .checked_add(vault.lock_secs)
        .ok_or(DeadmanError::MathOverflow)?;
    vault.locked_until = vault.locked_until.max(until);
    if signer != vault.owner && signer != vault.guard {
        require!(
            now >= vault.guardian_ready_at,
            DeadmanError::GuardianCooldown
        );
        vault.guardian_ready_at = vault
            .locked_until
            .checked_add(vault.lock_secs)
            .ok_or(DeadmanError::MathOverflow)?;
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
/// changed since. Vesting plans close only once nothing is owed to their
/// beneficiaries.
pub fn handle_close_vault(ctx: Context<CloseVault>) -> Result<()> {
    let now = Clock::get()?.unix_timestamp;
    let vault = &ctx.accounts.vault;
    vault.require_unlocked(now)?;
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
/// regardless of check-ins. Revocable plans let the owner stop future
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
    let now = Clock::get()?.unix_timestamp;
    let vault = &mut ctx.accounts.vault;
    vault.owner = owner;
    vault.plan_id = plan_id;
    vault.guard = guard;
    vault.bump = ctx.bumps.vault;
    vault.kind = PlanKind::Vesting;
    vault.revocable = revocable;
    vault.lock_secs = lock_secs;
    vault.rent_payer = ctx.accounts.payer.key();
    vault.rent_paid = init_rent(vault)?;
    vault.set_label(label)?;
    let key = vault.key();
    vault.apply_vesting(&key, now, start_at, &schedules)?;
    vault.record_owner_pulse(now)?;
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
/// lockdown so a coercer cannot force it.
pub fn handle_revoke_vesting(ctx: Context<OwnerAction>) -> Result<()> {
    let now = Clock::get()?.unix_timestamp;
    let vault = &mut ctx.accounts.vault;
    vault.require_kind(PlanKind::Vesting)?;
    vault.require_unlocked(now)?;
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
