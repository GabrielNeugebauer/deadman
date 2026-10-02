use anchor_lang::{prelude::*, solana_program::program::invoke_signed};
use anchor_spl::{
    associated_token::AssociatedToken,
    token_2022::spl_token_2022,
    token_interface::{self, Mint, TokenAccount, TokenInterface, TransferChecked},
};

use crate::{
    constants::*,
    error::DeadmanError,
    events::*,
    state::{split_share, Config, TokenClaim, Vault, VaultStatus},
};

fn withdrawable_lamports(vault: &Account<Vault>) -> Result<u64> {
    let info = vault.to_account_info();
    let rent = Rent::get()?.minimum_balance(info.data_len());
    Ok(info.lamports().saturating_sub(rent))
}

/// Vault-signed `transfer_checked`. `extra` (the instruction's remaining
/// accounts) is appended so Token-2022 transfer-hook mints can resolve their
/// hook accounts; the token program ignores them otherwise.
fn vault_transfer<'info>(
    token_program: &Interface<'info, TokenInterface>,
    from: &InterfaceAccount<'info, TokenAccount>,
    mint: &InterfaceAccount<'info, Mint>,
    to: AccountInfo<'info>,
    vault: &Account<'info, Vault>,
    extra: &[AccountInfo<'info>],
    amount: u64,
) -> Result<()> {
    if amount == 0 {
        return Ok(());
    }
    let mut ix = spl_token_2022::instruction::transfer_checked(
        token_program.key,
        &from.key(),
        &mint.key(),
        to.key,
        &vault.key(),
        &[],
        amount,
        mint.decimals,
    )?;
    let mut infos = Vec::with_capacity(4 + extra.len());
    infos.push(from.to_account_info());
    infos.push(mint.to_account_info());
    infos.push(to);
    infos.push(vault.to_account_info());
    for acc in extra {
        ix.accounts.push(AccountMeta {
            pubkey: *acc.key,
            is_signer: false,
            is_writable: acc.is_writable,
        });
        infos.push(acc.clone());
    }
    let seeds: &[&[u8]] = &[VAULT_SEED, vault.owner.as_ref(), &[vault.bump]];
    invoke_signed(&ix, &infos, &[seeds]).map_err(Into::into)
}

#[derive(Accounts)]
pub struct WithdrawSol<'info> {
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

pub fn handle_withdraw_sol(ctx: Context<WithdrawSol>, amount: u64) -> Result<()> {
    let now = Clock::get()?.unix_timestamp;
    let vault = &mut ctx.accounts.vault;
    vault.require_active()?;
    vault.require_unlocked(now)?;
    require!(
        amount <= withdrawable_lamports(vault)?,
        DeadmanError::InsufficientFunds
    );
    vault.sub_lamports(amount)?;
    ctx.accounts.owner.add_lamports(amount)?;
    vault.record_pulse(now)
}

#[derive(Accounts)]
pub struct WithdrawToken<'info> {
    #[account(mut)]
    pub owner: Signer<'info>,
    #[account(
        mut,
        seeds = [VAULT_SEED, owner.key().as_ref()],
        bump = vault.bump,
        has_one = owner @ DeadmanError::Unauthorized
    )]
    pub vault: Box<Account<'info, Vault>>,
    #[account(mint::token_program = token_program)]
    pub mint: Box<InterfaceAccount<'info, Mint>>,
    #[account(
        mut,
        associated_token::mint = mint,
        associated_token::authority = vault,
        associated_token::token_program = token_program
    )]
    pub vault_token: Box<InterfaceAccount<'info, TokenAccount>>,
    #[account(
        mut,
        token::mint = mint,
        token::authority = owner,
        token::token_program = token_program
    )]
    pub owner_token: Box<InterfaceAccount<'info, TokenAccount>>,
    pub token_program: Interface<'info, TokenInterface>,
}

pub fn handle_withdraw_token<'info>(
    ctx: Context<'info, WithdrawToken<'info>>,
    amount: u64,
) -> Result<()> {
    let now = Clock::get()?.unix_timestamp;
    let a = &ctx.accounts;
    a.vault.require_active()?;
    a.vault.require_unlocked(now)?;
    require!(
        amount <= a.vault_token.amount,
        DeadmanError::InsufficientFunds
    );
    vault_transfer(
        &a.token_program,
        &a.vault_token,
        &a.mint,
        a.owner_token.to_account_info(),
        &a.vault,
        ctx.remaining_accounts,
        amount,
    )?;
    ctx.accounts.vault.record_pulse(now)
}

#[derive(Accounts)]
pub struct Trigger<'info> {
    pub caller: Signer<'info>,
    #[account(
        mut,
        seeds = [VAULT_SEED, vault.owner.as_ref()],
        bump = vault.bump
    )]
    pub vault: Box<Account<'info, Vault>>,
}

/// Permissionless: anyone (usually an heir) may fire an expired switch.
pub fn handle_trigger(ctx: Context<Trigger>) -> Result<()> {
    let now = Clock::get()?.unix_timestamp;
    let sol_at_trigger = withdrawable_lamports(&ctx.accounts.vault)?;
    let vault = &mut ctx.accounts.vault;
    vault.require_active()?;
    require!(now > vault.deadline()?, DeadmanError::StillAlive);
    vault.status = VaultStatus::Triggered;
    vault.triggered_at = now;
    vault.sol_at_trigger = sol_at_trigger;
    emit!(Triggered {
        vault: vault.key(),
        by: ctx.accounts.caller.key(),
        sol_at_trigger,
        at: now,
    });
    Ok(())
}

#[derive(Accounts)]
pub struct ClaimSol<'info> {
    #[account(mut)]
    pub heir: Signer<'info>,
    #[account(
        mut,
        seeds = [VAULT_SEED, vault.owner.as_ref()],
        bump = vault.bump
    )]
    pub vault: Box<Account<'info, Vault>>,
    #[account(seeds = [CONFIG_SEED], bump = config.bump)]
    pub config: Box<Account<'info, Config>>,
    /// CHECK: lamport destination only; pinned to the configured treasury.
    #[account(mut, address = config.treasury @ DeadmanError::Unauthorized)]
    pub treasury: UncheckedAccount<'info>,
}

pub fn handle_claim_sol(ctx: Context<ClaimSol>) -> Result<()> {
    let fee_bps = ctx.accounts.config.fee_bps;
    let heir_key = ctx.accounts.heir.key();
    let vault = &mut ctx.accounts.vault;
    require!(
        vault.status == VaultStatus::Triggered,
        DeadmanError::VaultNotTriggered
    );
    let idx = vault.heir_index(&heir_key)?;
    require!(!vault.heirs[idx].claimed_sol, DeadmanError::AlreadyClaimed);
    vault.heirs[idx].claimed_sol = true;

    let (mut net, mut fee) = split_share(vault.sol_at_trigger, vault.heirs[idx].bps, fee_bps)?;
    let total = net.checked_add(fee).ok_or(DeadmanError::MathOverflow)?;
    // A fee that would leave the treasury below rent exemption would fail the
    // whole claim; waive it to the heir instead of blocking the inheritance.
    let treasury = &ctx.accounts.treasury;
    if fee > 0
        && treasury.lamports().saturating_add(fee)
            < Rent::get()?.minimum_balance(treasury.data_len())
    {
        net = total;
        fee = 0;
    }
    vault.sub_lamports(total)?;
    ctx.accounts.heir.add_lamports(net)?;
    if fee > 0 {
        ctx.accounts.treasury.add_lamports(fee)?;
    }
    emit!(Claimed {
        vault: vault.key(),
        heir: heir_key,
        mint: None,
        amount: net,
        fee,
    });
    Ok(())
}

#[derive(Accounts)]
pub struct ClaimToken<'info> {
    #[account(mut)]
    pub heir: Signer<'info>,
    #[account(
        seeds = [VAULT_SEED, vault.owner.as_ref()],
        bump = vault.bump
    )]
    pub vault: Box<Account<'info, Vault>>,
    #[account(seeds = [CONFIG_SEED], bump = config.bump)]
    pub config: Box<Account<'info, Config>>,
    #[account(mint::token_program = token_program)]
    pub mint: Box<InterfaceAccount<'info, Mint>>,
    #[account(
        mut,
        associated_token::mint = mint,
        associated_token::authority = vault,
        associated_token::token_program = token_program
    )]
    pub vault_token: Box<InterfaceAccount<'info, TokenAccount>>,
    #[account(
        init_if_needed,
        payer = heir,
        associated_token::mint = mint,
        associated_token::authority = heir,
        associated_token::token_program = token_program
    )]
    pub heir_token: Box<InterfaceAccount<'info, TokenAccount>>,
    #[account(
        mut,
        token::mint = mint,
        token::authority = config.treasury,
        token::token_program = token_program
    )]
    pub treasury_token: Box<InterfaceAccount<'info, TokenAccount>>,
    #[account(
        init_if_needed,
        payer = heir,
        space = 8 + TokenClaim::INIT_SPACE,
        seeds = [CLAIM_SEED, vault.key().as_ref(), mint.key().as_ref()],
        bump
    )]
    pub claim: Box<Account<'info, TokenClaim>>,
    pub token_program: Interface<'info, TokenInterface>,
    pub associated_token_program: Program<'info, AssociatedToken>,
    pub system_program: Program<'info, System>,
}

pub fn handle_claim_token<'info>(ctx: Context<'info, ClaimToken<'info>>) -> Result<()> {
    let a = &ctx.accounts;
    require!(
        a.vault.status == VaultStatus::Triggered,
        DeadmanError::VaultNotTriggered
    );
    let idx = a.vault.heir_index(&a.heir.key())?;
    let bit = 1u8 << idx;

    let claim = &mut ctx.accounts.claim;
    if !claim.initialized {
        claim.vault = ctx.accounts.vault.key();
        claim.mint = ctx.accounts.mint.key();
        claim.amount_at_snapshot = ctx.accounts.vault_token.amount;
        claim.initialized = true;
        claim.bump = ctx.bumps.claim;
    }
    require!(claim.claimed_mask & bit == 0, DeadmanError::AlreadyClaimed);
    claim.claimed_mask |= bit;

    let a = &ctx.accounts;
    let (net, fee) = split_share(
        a.claim.amount_at_snapshot,
        a.vault.heirs[idx].bps,
        a.config.fee_bps,
    )?;
    vault_transfer(
        &a.token_program,
        &a.vault_token,
        &a.mint,
        a.heir_token.to_account_info(),
        &a.vault,
        ctx.remaining_accounts,
        net,
    )?;
    vault_transfer(
        &a.token_program,
        &a.vault_token,
        &a.mint,
        a.treasury_token.to_account_info(),
        &a.vault,
        ctx.remaining_accounts,
        fee,
    )?;
    emit!(Claimed {
        vault: a.vault.key(),
        heir: a.heir.key(),
        mint: Some(a.mint.key()),
        amount: net,
        fee,
    });
    Ok(())
}

#[derive(Accounts)]
pub struct Subscribe<'info> {
    #[account(mut)]
    pub owner: Signer<'info>,
    #[account(
        mut,
        seeds = [VAULT_SEED, owner.key().as_ref()],
        bump = vault.bump,
        has_one = owner @ DeadmanError::Unauthorized
    )]
    pub vault: Box<Account<'info, Vault>>,
    #[account(seeds = [CONFIG_SEED], bump = config.bump)]
    pub config: Box<Account<'info, Config>>,
    #[account(
        address = config.skr_mint @ DeadmanError::Unauthorized,
        mint::token_program = token_program
    )]
    pub skr_mint: Box<InterfaceAccount<'info, Mint>>,
    #[account(
        mut,
        token::mint = skr_mint,
        token::authority = owner,
        token::token_program = token_program
    )]
    pub owner_skr: Box<InterfaceAccount<'info, TokenAccount>>,
    #[account(
        mut,
        token::mint = skr_mint,
        token::authority = config.treasury,
        token::token_program = token_program
    )]
    pub treasury_skr: Box<InterfaceAccount<'info, TokenAccount>>,
    pub token_program: Interface<'info, TokenInterface>,
}

/// Deadman Plus, paid in SKR: up to 4 heirs and a guardian.
pub fn handle_subscribe(ctx: Context<Subscribe>, months: u8) -> Result<()> {
    require!(
        (1..=MAX_SUBSCRIBE_MONTHS).contains(&months),
        DeadmanError::InvalidMonths
    );
    let now = Clock::get()?.unix_timestamp;
    let a = &ctx.accounts;
    a.vault.require_active()?;
    let cost = a
        .config
        .plus_price
        .checked_mul(u64::from(months))
        .ok_or(DeadmanError::MathOverflow)?;
    token_interface::transfer_checked(
        CpiContext::new(
            a.token_program.key(),
            TransferChecked {
                from: a.owner_skr.to_account_info(),
                mint: a.skr_mint.to_account_info(),
                to: a.treasury_skr.to_account_info(),
                authority: a.owner.to_account_info(),
            },
        ),
        cost,
        a.skr_mint.decimals,
    )?;

    let vault = &mut ctx.accounts.vault;
    let extension = SECS_PER_MONTH
        .checked_mul(i64::from(months))
        .ok_or(DeadmanError::MathOverflow)?;
    vault.plus_until = vault
        .plus_until
        .max(now)
        .checked_add(extension)
        .ok_or(DeadmanError::MathOverflow)?;
    emit!(Subscribed {
        vault: vault.key(),
        months,
        plus_until: vault.plus_until,
    });
    Ok(())
}
