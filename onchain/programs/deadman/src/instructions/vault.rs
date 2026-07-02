use anchor_lang::prelude::*;

use crate::{
    constants::*,
    error::DeadmanError,
    events::*,
    state::{RuleInput, Vault},
};

#[derive(Accounts)]
pub struct CreateVault<'info> {
    #[account(mut)]
    pub owner: Signer<'info>,
    #[account(
        init,
        payer = owner,
        space = 8 + Vault::INIT_SPACE,
        seeds = [VAULT_SEED, owner.key().as_ref()],
        bump
    )]
    pub vault: Account<'info, Vault>,
    pub system_program: Program<'info, System>,
}

pub fn handle_create_vault(
    ctx: Context<CreateVault>,
    guard: Pubkey,
    interval_secs: i64,
    lock_secs: i64,
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
    vault.guard = guard;
    vault.bump = ctx.bumps.vault;
    vault.apply_policy(interval_secs, lock_secs, &rules, None)?;
    vault.record_pulse(now)?;

    emit!(VaultCreated {
        vault: vault.key(),
        owner,
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
        seeds = [VAULT_SEED, owner.key().as_ref()],
        bump = vault.bump,
        has_one = owner @ DeadmanError::Unauthorized
    )]
    pub vault: Account<'info, Vault>,
}

/// Replaces every rule (all pending again). Blocked during lockdown so a
/// coercer cannot redirect the payouts.
pub fn handle_update_policy(
    ctx: Context<OwnerAction>,
    interval_secs: i64,
    lock_secs: i64,
    rules: Vec<RuleInput>,
    guardian: Option<Pubkey>,
) -> Result<()> {
    let now = Clock::get()?.unix_timestamp;
    let vault = &mut ctx.accounts.vault;
    vault.require_unlocked(now)?;
    vault.apply_policy(interval_secs, lock_secs, &rules, guardian)?;
    vault.record_pulse(now)?;
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
    vault.record_pulse(now)
}

#[derive(Accounts)]
pub struct Pulse<'info> {
    pub signer: Signer<'info>,
    #[account(
        mut,
        seeds = [VAULT_SEED, vault.owner.as_ref()],
        bump = vault.bump,
        constraint = signer.key() == vault.owner || signer.key() == vault.guard
            @ DeadmanError::Unauthorized
    )]
    pub vault: Account<'info, Vault>,
}

pub fn handle_pulse(ctx: Context<Pulse>) -> Result<()> {
    let now = Clock::get()?.unix_timestamp;
    let vault = &mut ctx.accounts.vault;
    vault.record_pulse(now)?;
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
        seeds = [VAULT_SEED, vault.owner.as_ref()],
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
        seeds = [VAULT_SEED, owner.key().as_ref()],
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
    vault.record_pulse(now)?;
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
        seeds = [VAULT_SEED, owner.key().as_ref()],
        bump = vault.bump,
        has_one = owner @ DeadmanError::Unauthorized,
        close = owner
    )]
    pub vault: Account<'info, Vault>,
}

pub fn handle_close_vault(ctx: Context<CloseVault>) -> Result<()> {
    let now = Clock::get()?.unix_timestamp;
    ctx.accounts.vault.require_unlocked(now)
}
