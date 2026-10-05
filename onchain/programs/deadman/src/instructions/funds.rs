use anchor_lang::{prelude::*, solana_program::program::invoke_signed};
use anchor_spl::{
    associated_token::get_associated_token_address_with_program_id,
    token_2022::spl_token_2022,
    token_interface::{Mint, TokenAccount, TokenInterface},
};

use crate::{
    constants::*,
    error::DeadmanError,
    events::*,
    state::{split_fee, Config, PlanKind, Rail, Subscription, Vault},
};

/// Lamports above the rent reserve (see [`Vault::rent_reserve`]).
fn withdrawable_lamports(vault: &Account<Vault>) -> Result<u64> {
    let info = vault.to_account_info();
    Ok(info
        .lamports()
        .saturating_sub(vault.rent_reserve(info.data_len())?))
}

/// Payout fee for `rail`: 0 while the owner's account subscription covers
/// the payout. `subscription` must be the owner's subscription PDA, created
/// or not, so an executor cannot drop the waiver by passing another account.
fn payout_fee_bps(
    vault: &Vault,
    config: &Config,
    subscription: &AccountInfo,
    rail: Rail,
    now: i64,
) -> Result<u16> {
    let covered =
        Subscription::load(subscription, &vault.owner)?.is_some_and(|sub| sub.covers(vault, now));
    Ok(if covered { 0 } else { config.fee_bps(rail) })
}

/// Private-rail token payouts also send the rail's SOL stipend so a fresh
/// claim key can pay to route the tokens onward, but only when the key
/// holds less and only from SOL nobody else is owed (vesting commitments
/// and shares reserved for skipped SOL tiers stay untouched).
/// At most once per rule ([`Vault::stipend_paid`]), so a beneficiary who
/// spends it between vesting releases cannot drain the owner's spare SOL.
fn pay_stipend<'info>(
    vault: &mut Account<'info, Vault>,
    beneficiary: &UncheckedAccount<'info>,
    rail: Rail,
    index: usize,
) -> Result<()> {
    let stipend = rail.gas_stipend();
    let bit = u32::try_from(index)
        .ok()
        .and_then(|i| 1u8.checked_shl(i))
        .ok_or(DeadmanError::InvalidRuleIndex)?;
    if stipend == 0 || vault.stipend_paid & bit != 0 || beneficiary.lamports() >= stipend {
        return Ok(());
    }
    let spare = withdrawable_lamports(vault)?
        .saturating_sub(vault.committed(None)?)
        .saturating_sub(vault.reserved_for(None, usize::MAX)?);
    if spare >= stipend {
        vault.sub_lamports(stipend)?;
        beneficiary.add_lamports(stipend)?;
        vault.stipend_paid |= bit;
    }
    Ok(())
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
    let free = withdrawable_lamports(vault)?;
    require!(amount <= free, DeadmanError::InsufficientFunds);
    require!(
        amount <= free.saturating_sub(vault.committed(None)?),
        DeadmanError::FundsCommitted
    );
    vault.sub_lamports(amount)?;
    ctx.accounts.owner.add_lamports(amount)?;
    vault.record_owner_pulse(now)
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
    require!(
        amount
            <= a.vault_token
                .amount
                .saturating_sub(a.vault.committed(Some(a.mint.key()))?),
        DeadmanError::FundsCommitted
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
    ctx.accounts.vault.record_owner_pulse(now)
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
    /// CHECK: the owner's subscription PDA `[SUBSCRIPTION_SEED, vault.owner]`,
    /// possibly not created yet; verified in [`Subscription::load`].
    pub subscription: UncheckedAccount<'info>,
}

/// Permissionless: pays a due SOL rule. Destinations are fixed in the rule,
/// so who executes it does not matter.
pub fn handle_execute_sol_rule(ctx: Context<ExecuteSolRule>, index: u8) -> Result<()> {
    let now = Clock::get()?.unix_timestamp;
    let i = usize::from(index);
    ctx.accounts.vault.require_kind(PlanKind::Inheritance)?;
    ctx.accounts.vault.check_executable(i, None, now)?;
    let rule = ctx.accounts.vault.rules[i];
    require_keys_eq!(
        ctx.accounts.beneficiary.key(),
        rule.beneficiary,
        DeadmanError::Unauthorized
    );

    let balance = withdrawable_lamports(&ctx.accounts.vault)?;
    let gross = ctx.accounts.vault.payout_gross(i, balance)?;
    // An empty payout would burn the tier; leave it pending instead.
    require!(gross > 0, DeadmanError::NothingToPay);
    let (mut net, mut fee) = split_fee(
        gross,
        payout_fee_bps(
            &ctx.accounts.vault,
            &ctx.accounts.config,
            &ctx.accounts.subscription,
            rule.rail,
            now,
        )?,
    )?;

    let rent = Rent::get()?;
    let treasury = &ctx.accounts.treasury;
    if fee > 0
        && treasury.lamports().saturating_add(fee) < rent.minimum_balance(treasury.data_len())
    {
        net = net.checked_add(fee).ok_or(DeadmanError::MathOverflow)?;
        fee = 0;
    }
    // A brand-new account cannot be funded below rent exemption. The tier
    // stays pending (and can be skipped after the grace period) rather than
    // being consumed with nothing paid.
    let beneficiary = &ctx.accounts.beneficiary;
    require!(
        beneficiary.lamports().saturating_add(net) >= rent.minimum_balance(beneficiary.data_len()),
        DeadmanError::BeneficiaryCannotReceive
    );

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
    /// The beneficiary's ATA, or any other token account it owns when the
    /// beneficiary signs (e.g. its ATA was frozen or reassigned).
    #[account(
        mut,
        token::mint = mint,
        token::authority = beneficiary,
        token::token_program = token_program
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
    /// CHECK: the owner's subscription PDA `[SUBSCRIPTION_SEED, vault.owner]`,
    /// possibly not created yet; verified in [`Subscription::load`].
    pub subscription: UncheckedAccount<'info>,
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
    a.vault.require_kind(PlanKind::Inheritance)?;
    a.vault.check_executable(i, Some(a.mint.key()), now)?;
    let rule = a.vault.rules[i];
    require_keys_eq!(
        a.beneficiary.key(),
        rule.beneficiary,
        DeadmanError::Unauthorized
    );

    let canonical = get_associated_token_address_with_program_id(
        &rule.beneficiary,
        &a.mint.key(),
        &a.token_program.key(),
    );
    // Only the beneficiary may redirect its payout away from its ATA, so an
    // executor cannot pick an account the beneficiary cannot use.
    require!(
        a.beneficiary_token.key() == canonical || a.beneficiary.is_signer,
        DeadmanError::Unauthorized
    );

    let gross = a.vault.payout_gross(i, a.vault_token.amount)?;
    require!(gross > 0, DeadmanError::NothingToPay);
    let (net, fee) = split_fee(
        gross,
        payout_fee_bps(&a.vault, &a.config, &a.subscription, rule.rail, now)?,
    )?;
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

    pay_stipend(
        &mut ctx.accounts.vault,
        &ctx.accounts.beneficiary,
        rule.rail,
        i,
    )?;

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

#[derive(Accounts)]
pub struct SkipRule<'info> {
    /// Anyone: usually a later beneficiary or the keeper.
    pub caller: Signer<'info>,
    #[account(
        mut,
        seeds = [VAULT_SEED, vault.owner.as_ref(), &vault.plan_id.to_le_bytes()],
        bump = vault.bump
    )]
    pub vault: Box<Account<'info, Vault>>,
    /// The vault's ATA of the tier's mint; required for token tiers so the
    /// skipped share can be reserved from the real balance.
    pub vault_token: Option<Box<InterfaceAccount<'info, TokenAccount>>>,
}

/// Permissionless: lets later tiers of the same asset run past a tier that
/// still has not paid when the plan's grace period ends. The skipped tier's
/// share is reserved for it and stays claimable by its own beneficiary, so a
/// skip never moves value to anyone else or strands it.
pub fn handle_skip_rule(ctx: Context<SkipRule>, index: u8) -> Result<()> {
    let now = Clock::get()?.unix_timestamp;
    let i = usize::from(index);
    ctx.accounts.vault.require_kind(PlanKind::Inheritance)?;
    ctx.accounts.vault.check_skippable(i, now)?;
    let mint = ctx.accounts.vault.rules[i].mint;
    let balance = match mint {
        None => withdrawable_lamports(&ctx.accounts.vault)?,
        Some(mint) => {
            let token = ctx
                .accounts
                .vault_token
                .as_ref()
                .ok_or(DeadmanError::WrongAsset)?;
            let expected = get_associated_token_address_with_program_id(
                &ctx.accounts.vault.key(),
                &mint,
                token.to_account_info().owner,
            );
            require_keys_eq!(token.key(), expected, DeadmanError::WrongAsset);
            token.amount
        }
    };
    let reserved = ctx.accounts.vault.payout_gross(i, balance)?;

    let vault = &mut ctx.accounts.vault;
    vault.rules[i].skipped_at = now;
    vault.rules[i].reserved = reserved;
    emit!(RuleSkipped {
        vault: vault.key(),
        index,
        reserved,
        by: ctx.accounts.caller.key(),
    });
    Ok(())
}

/// Releases what has vested so far on a SOL vesting schedule. Anyone may
/// call it; the destination is fixed in the schedule.
pub fn handle_release_vested_sol(ctx: Context<ExecuteSolRule>, index: u8) -> Result<()> {
    let now = Clock::get()?.unix_timestamp;
    let i = usize::from(index);
    let vault = &ctx.accounts.vault;
    vault.require_kind(PlanKind::Vesting)?;
    require!(i < vault.rules.len(), DeadmanError::InvalidRuleIndex);
    let rule = vault.rules[i];
    require!(rule.mint.is_none(), DeadmanError::WrongAsset);
    require!(rule.executed_at == 0, DeadmanError::RuleAlreadyExecuted);
    require_keys_eq!(
        ctx.accounts.beneficiary.key(),
        rule.beneficiary,
        DeadmanError::Unauthorized
    );

    let due = vault.vested(i, now)?.saturating_sub(rule.released);
    let gross = due.min(withdrawable_lamports(vault)?);
    require!(gross > 0, DeadmanError::NothingToPay);
    let (mut net, mut fee) = split_fee(
        gross,
        payout_fee_bps(
            &ctx.accounts.vault,
            &ctx.accounts.config,
            &ctx.accounts.subscription,
            rule.rail,
            now,
        )?,
    )?;
    let rent = Rent::get()?;
    let treasury = &ctx.accounts.treasury;
    if fee > 0
        && treasury.lamports().saturating_add(fee) < rent.minimum_balance(treasury.data_len())
    {
        net = net.checked_add(fee).ok_or(DeadmanError::MathOverflow)?;
        fee = 0;
    }
    let beneficiary = &ctx.accounts.beneficiary;
    require!(
        beneficiary.lamports().saturating_add(net) >= rent.minimum_balance(beneficiary.data_len()),
        DeadmanError::BeneficiaryCannotReceive
    );
    ctx.accounts.vault.sub_lamports(gross)?;
    beneficiary.add_lamports(net)?;
    if fee > 0 {
        treasury.add_lamports(fee)?;
    }
    record_release(&mut ctx.accounts.vault, i, now, gross, net)?;
    emit!(RuleExecuted {
        vault: ctx.accounts.vault.key(),
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

/// Token version of [`handle_release_vested_sol`].
pub fn handle_release_vested_token<'info>(
    ctx: Context<'info, ExecuteTokenRule<'info>>,
    index: u8,
) -> Result<()> {
    let now = Clock::get()?.unix_timestamp;
    let i = usize::from(index);
    let a = &ctx.accounts;
    a.vault.require_kind(PlanKind::Vesting)?;
    require!(i < a.vault.rules.len(), DeadmanError::InvalidRuleIndex);
    let rule = a.vault.rules[i];
    require!(rule.mint == Some(a.mint.key()), DeadmanError::WrongAsset);
    require!(rule.executed_at == 0, DeadmanError::RuleAlreadyExecuted);
    require_keys_eq!(
        a.beneficiary.key(),
        rule.beneficiary,
        DeadmanError::Unauthorized
    );
    let canonical = get_associated_token_address_with_program_id(
        &rule.beneficiary,
        &a.mint.key(),
        &a.token_program.key(),
    );
    require!(
        a.beneficiary_token.key() == canonical || a.beneficiary.is_signer,
        DeadmanError::Unauthorized
    );

    let due = a.vault.vested(i, now)?.saturating_sub(rule.released);
    let gross = due.min(a.vault_token.amount);
    require!(gross > 0, DeadmanError::NothingToPay);
    let (net, fee) = split_fee(
        gross,
        payout_fee_bps(&a.vault, &a.config, &a.subscription, rule.rail, now)?,
    )?;
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
    pay_stipend(
        &mut ctx.accounts.vault,
        &ctx.accounts.beneficiary,
        rule.rail,
        i,
    )?;
    record_release(&mut ctx.accounts.vault, i, now, gross, net)?;
    emit!(RuleExecuted {
        vault: ctx.accounts.vault.key(),
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

fn record_release(
    vault: &mut Account<Vault>,
    i: usize,
    now: i64,
    gross: u64,
    net: u64,
) -> Result<()> {
    let released = vault.rules[i]
        .released
        .checked_add(gross)
        .ok_or(DeadmanError::MathOverflow)?;
    vault.rules[i].released = released;
    vault.rules[i].paid = vault.rules[i]
        .paid
        .checked_add(net)
        .ok_or(DeadmanError::MathOverflow)?;
    if released >= vault.vesting_cap(i)? {
        vault.rules[i].executed_at = now;
    }
    Ok(())
}
