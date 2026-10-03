use anchor_lang::{prelude::*, solana_program::program::invoke_signed};
use anchor_spl::{
    associated_token::AssociatedToken,
    token_2022::spl_token_2022,
    token_interface::{Mint, TokenAccount, TokenInterface},
};

use crate::{
    constants::*,
    error::DeadmanError,
    events::*,
    state::{rule_gross, split_fee, Config, Vault},
};

fn withdrawable_lamports(vault: &AccountInfo) -> Result<u64> {
    let rent = Rent::get()?.minimum_balance(vault.data_len());
    Ok(vault.lamports().saturating_sub(rent))
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
    let plan_id = vault.plan_id.to_le_bytes();
    let seeds: &[&[u8]] = &[VAULT_SEED, vault.owner.as_ref(), &plan_id, &[vault.bump]];
    invoke_signed(&ix, &infos, &[seeds]).map_err(Into::into)
}

#[derive(Accounts)]
pub struct WithdrawSol<'info> {
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

pub fn handle_withdraw_sol(ctx: Context<WithdrawSol>, amount: u64) -> Result<()> {
    let now = Clock::get()?.unix_timestamp;
    let vault = &mut ctx.accounts.vault;
    vault.require_unlocked(now)?;
    require!(
        amount <= withdrawable_lamports(&vault.to_account_info())?,
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
        seeds = [VAULT_SEED, owner.key().as_ref(), &vault.plan_id.to_le_bytes()],
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
pub struct ExecuteSolRule<'info> {
    /// Anyone: the beneficiary, a keeper, or the protocol's own bot.
    pub executor: Signer<'info>,
    #[account(
        mut,
        seeds = [VAULT_SEED, vault.owner.as_ref(), &vault.plan_id.to_le_bytes()],
        bump = vault.bump
    )]
    pub vault: Box<Account<'info, Vault>>,
    #[account(seeds = [CONFIG_SEED], bump = config.bump)]
    pub config: Box<Account<'info, Config>>,
    /// CHECK: lamport destination; must equal the rule's beneficiary.
    #[account(mut)]
    pub beneficiary: UncheckedAccount<'info>,
    /// CHECK: lamport destination only; pinned to the configured treasury.
    #[account(mut, address = config.treasury @ DeadmanError::Unauthorized)]
    pub treasury: UncheckedAccount<'info>,
}

/// Permissionless: pays a due SOL rule. Destinations are fixed in the rule,
/// so who executes it does not matter.
pub fn handle_execute_sol_rule(ctx: Context<ExecuteSolRule>, index: u8) -> Result<()> {
    let now = Clock::get()?.unix_timestamp;
    let i = usize::from(index);
    let vault_info = ctx.accounts.vault.to_account_info();
    ctx.accounts.vault.check_executable(i, None, now)?;
    let rule = ctx.accounts.vault.rules[i];
    require_keys_eq!(
        ctx.accounts.beneficiary.key(),
        rule.beneficiary,
        DeadmanError::Unauthorized
    );

    let available = withdrawable_lamports(&vault_info)?;
    let gross = rule_gross(&rule, available)?;
    let (mut net, mut fee) = split_fee(gross, ctx.accounts.config.fee_bps(rule.rail))?;

    let rent = Rent::get()?;
    let treasury = &ctx.accounts.treasury;
    if fee > 0
        && treasury.lamports().saturating_add(fee) < rent.minimum_balance(treasury.data_len())
    {
        net = net.checked_add(fee).ok_or(DeadmanError::MathOverflow)?;
        fee = 0;
    }
    // A brand-new account cannot be funded below rent exemption; leave the
    // dust in the vault rather than failing and blocking later rules.
    let beneficiary = &ctx.accounts.beneficiary;
    if net > 0
        && beneficiary.lamports().saturating_add(net) < rent.minimum_balance(beneficiary.data_len())
    {
        net = 0;
        fee = 0;
    }

    let total = net.checked_add(fee).ok_or(DeadmanError::MathOverflow)?;
    ctx.accounts.vault.sub_lamports(total)?;
    beneficiary.add_lamports(net)?;
    if fee > 0 {
        treasury.add_lamports(fee)?;
    }

    let vault = &mut ctx.accounts.vault;
    vault.rules[i].executed_at = now;
    vault.rules[i].paid = net;
    emit!(RuleExecuted {
        vault: vault.key(),
        index,
        beneficiary: rule.beneficiary,
        rail: rule.rail,
        mint: None,
        amount: net,
        fee,
        by: ctx.accounts.executor.key(),
    });
    Ok(())
}

#[derive(Accounts)]
pub struct ExecuteTokenRule<'info> {
    #[account(mut)]
    pub executor: Signer<'info>,
    #[account(
        mut,
        seeds = [VAULT_SEED, vault.owner.as_ref(), &vault.plan_id.to_le_bytes()],
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
    /// CHECK: must equal the rule's beneficiary; receives the gas stipend.
    #[account(mut)]
    pub beneficiary: UncheckedAccount<'info>,
    #[account(
        init_if_needed,
        payer = executor,
        associated_token::mint = mint,
        associated_token::authority = beneficiary,
        associated_token::token_program = token_program
    )]
    pub beneficiary_token: Box<InterfaceAccount<'info, TokenAccount>>,
    #[account(
        mut,
        token::mint = mint,
        token::authority = config.treasury,
        token::token_program = token_program
    )]
    pub treasury_token: Box<InterfaceAccount<'info, TokenAccount>>,
    pub token_program: Interface<'info, TokenInterface>,
    pub associated_token_program: Program<'info, AssociatedToken>,
    pub system_program: Program<'info, System>,
}

/// Permissionless: pays a due token rule. Private rails also receive a small
/// SOL stipend so a fresh claim key can pay to route the tokens onward.
pub fn handle_execute_token_rule<'info>(
    ctx: Context<'info, ExecuteTokenRule<'info>>,
    index: u8,
) -> Result<()> {
    let now = Clock::get()?.unix_timestamp;
    let i = usize::from(index);
    let a = &ctx.accounts;
    a.vault.check_executable(i, Some(a.mint.key()), now)?;
    let rule = a.vault.rules[i];
    require_keys_eq!(
        a.beneficiary.key(),
        rule.beneficiary,
        DeadmanError::Unauthorized
    );

    let gross = rule_gross(&rule, a.vault_token.amount)?;
    let (net, fee) = split_fee(gross, a.config.fee_bps(rule.rail))?;
    vault_transfer(
        &a.token_program,
        &a.vault_token,
        &a.mint,
        a.beneficiary_token.to_account_info(),
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

    let stipend = if rule.rail.is_private()
        && a.beneficiary.lamports() < PRIVATE_GAS_STIPEND
        && withdrawable_lamports(&a.vault.to_account_info())? >= PRIVATE_GAS_STIPEND
    {
        PRIVATE_GAS_STIPEND
    } else {
        0
    };
    if stipend > 0 {
        ctx.accounts.vault.sub_lamports(stipend)?;
        ctx.accounts.beneficiary.add_lamports(stipend)?;
    }

    let vault = &mut ctx.accounts.vault;
    vault.rules[i].executed_at = now;
    vault.rules[i].paid = net;
    emit!(RuleExecuted {
        vault: vault.key(),
        index,
        beneficiary: rule.beneficiary,
        rail: rule.rail,
        mint: Some(ctx.accounts.mint.key()),
        amount: net,
        fee,
        by: ctx.accounts.executor.key(),
    });
    Ok(())
}
