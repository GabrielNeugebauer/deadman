use anchor_lang::{prelude::*, solana_program::program::invoke_signed};
use anchor_spl::{
    associated_token::get_associated_token_address_with_program_id,
    token::{self, Token},
    token_2022::spl_token_2022,
    token_interface::{self, Burn, Mint, TokenAccount, TokenInterface, TransferChecked},
};

use crate::{
    constants::*,
    error::DeadmanError,
    events::*,
    state::{
        bps_of, skr_fee_quote, split_fee, stipend_bit, Config, PlanKind, PriceFeed, Rail, Vault,
    },
};

/// Lamports above the rent reserve (see [`Vault::rent_reserve`]).
fn withdrawable_lamports(vault: &Account<Vault>) -> Result<u64> {
    let info = vault.to_account_info();
    Ok(info
        .lamports()
        .saturating_sub(vault.rent_reserve(info.data_len())?))
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
    let bit = stipend_bit(index)?;
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
    token_program: &AccountInfo<'info>,
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

/// Price of `mint` per the registry. `feed` must be the mint's PriceFeed
/// and `price` that feed's price account, or, when no feed is registered,
/// `feed` the still-empty PriceFeed address (then there is no price).
/// None also when the price is unusable (see [`PriceFeed::usable_price`]).
fn registered_price(
    feed: &AccountInfo,
    price: &AccountInfo,
    mint: &Pubkey,
    now: i64,
) -> Result<Option<(u64, i32)>> {
    if feed.owner == &crate::ID {
        let f = PriceFeed::try_deserialize(&mut &feed.try_borrow_data()?[..])?;
        require!(
            f.mint == *mint && price.key() == f.price_account,
            DeadmanError::InvalidSkrFeeAccounts
        );
        return Ok(f.usable_price(price, now));
    }
    let (pda, _) = Pubkey::find_program_address(&[PRICE_FEED_SEED, mint.as_ref()], &crate::ID);
    require!(
        feed.key() == pda && feed.data_is_empty(),
        DeadmanError::InvalidSkrFeeAccounts
    );
    Ok(None)
}

/// Whether the treasury's SKR account can take a fee: an SKR account the
/// treasury owns and that is not frozen. The treasury's ATA address while
/// still uncreated is a "no"; any other account is refused.
fn treasury_takes_skr(info: &AccountInfo, config: &Config) -> Result<bool> {
    if info.owner == &token::ID {
        let t = TokenAccount::try_deserialize(&mut &info.try_borrow_data()?[..])?;
        require!(
            t.mint == config.skr_mint && t.owner == config.treasury,
            DeadmanError::InvalidSkrFeeAccounts
        );
        return Ok(!t.is_frozen());
    }
    let ata = get_associated_token_address_with_program_id(
        &config.treasury,
        &config.skr_mint,
        &token::ID,
    );
    require!(
        info.key() == ata && info.data_is_empty(),
        DeadmanError::InvalidSkrFeeAccounts
    );
    Ok(false)
}

/// Pays the release fee of a payout of `gross` units of `asset_mint` (SOL:
/// the wrapped SOL mint) in SKR from the plan's fee reserve:
/// `fee_bps_skr` of the payout's value, rounded up, `skr_burn_bps` of it
/// burned and the rest sent to the treasury. Returns true if it did, so
/// the beneficiary gets the whole payout. Returns false, leaving the asset
/// fee to be charged, when the plan has no reserve in the config's SKR
/// mint, a price is unregistered, disabled, stale, not fully verified or
/// too uncertain, the reserve cannot cover the fee, or the treasury has no
/// usable SKR account.
///
/// With a reserve the executor must pass, as remaining accounts in this
/// order: the asset's PriceFeed and its price account, SKR's PriceFeed and
/// its price account, the vault's SKR ATA, the SKR mint (writable), the
/// treasury's SKR ATA (writable) and the Token program. All are checked
/// against the registry, the config and the plan, so an executor cannot
/// choose the price.
#[allow(clippy::too_many_arguments)]
fn pay_fee_in_skr<'info>(
    vault: &mut Account<'info, Vault>,
    config: &Config,
    remaining: &'info [AccountInfo<'info>],
    asset_mint: Pubkey,
    asset_decimals: u8,
    gross: u64,
    index: u8,
    now: i64,
) -> Result<bool> {
    let skr_mint = config.skr_mint;
    if vault.skr_fee_reserve == 0
        || skr_mint == Pubkey::default()
        || vault.skr_reserve_mint != skr_mint
    {
        return Ok(false);
    }
    let [asset_feed, asset_price, skr_feed, skr_price, vault_skr, mint, treasury_skr, token_program, ..] =
        remaining
    else {
        return err!(DeadmanError::SkrFeeAccountsRequired);
    };
    let vault_key = vault.key();
    require!(
        token_program.key() == token::ID
            && mint.key() == skr_mint
            && vault_skr.key()
                == get_associated_token_address_with_program_id(&vault_key, &skr_mint, &token::ID),
        DeadmanError::InvalidSkrFeeAccounts
    );
    let (Some(asset_px), Some(skr_px)) = (
        registered_price(asset_feed, asset_price, &asset_mint, now)?,
        registered_price(skr_feed, skr_price, &skr_mint, now)?,
    ) else {
        return Ok(false);
    };
    let source = TokenAccount::try_deserialize(&mut &vault_skr.try_borrow_data()?[..])?;
    let decimals = token::Mint::try_deserialize(&mut &mint.try_borrow_data()?[..])?.decimals;
    if source.is_frozen() || !treasury_takes_skr(treasury_skr, config)? {
        return Ok(false);
    }
    let Some(fee) = skr_fee_quote(
        gross,
        asset_px,
        asset_decimals,
        skr_px,
        decimals,
        config.fee_bps_skr,
    )
    .filter(|f| *f <= vault.skr_fee_reserve && *f <= source.amount) else {
        return Ok(false);
    };

    let (burned, to_treasury) = config.split_burn(fee, Some(skr_mint))?;
    let plan_id = vault.plan_id.to_le_bytes();
    let seeds: &[&[u8]] = &[VAULT_SEED, vault.owner.as_ref(), &plan_id, &[vault.bump]];
    let authority = vault.to_account_info();
    if burned > 0 {
        token_interface::burn(
            CpiContext::new_with_signer(
                token::ID,
                Burn {
                    mint: mint.clone(),
                    from: vault_skr.clone(),
                    authority: authority.clone(),
                },
                &[seeds],
            ),
            burned,
        )?;
    }
    if to_treasury > 0 {
        token_interface::transfer_checked(
            CpiContext::new_with_signer(
                token::ID,
                TransferChecked {
                    from: vault_skr.clone(),
                    mint: mint.clone(),
                    to: treasury_skr.clone(),
                    authority,
                },
                &[seeds],
            ),
            to_treasury,
            decimals,
        )?;
    }
    vault.skr_fee_reserve = vault
        .skr_fee_reserve
        .checked_sub(fee)
        .ok_or(DeadmanError::MathOverflow)?;
    emit!(SkrFeePaid {
        vault: vault_key,
        index,
        fee,
        burned,
    });
    Ok(true)
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
        amount <= free.saturating_sub(vault.locked_for_owner(None)?),
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
                .saturating_sub(a.vault.locked_for_owner(Some(a.mint.key()))?)
                .saturating_sub(a.vault.fee_reserve_in(Some(a.mint.key()))),
        DeadmanError::FundsCommitted
    );
    vault_transfer(
        a.token_program.as_ref(),
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
}

/// Permissionless: pays a due SOL rule. Destinations are fixed in the rule,
/// so who executes it does not matter.
pub fn handle_execute_sol_rule<'info>(
    ctx: Context<'info, ExecuteSolRule<'info>>,
    index: u8,
) -> Result<()> {
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
    let (mut net, mut fee) = split_fee(gross, ctx.accounts.config.fee_bps(rule.rail, None))?;

    let rent = Rent::get()?;
    let treasury = &ctx.accounts.treasury;
    if fee > 0
        && treasury.lamports().saturating_add(fee) < rent.minimum_balance(treasury.data_len())
    {
        net = net.checked_add(fee).ok_or(DeadmanError::MathOverflow)?;
        fee = 0;
    }
    if fee > 0
        && pay_fee_in_skr(
            &mut ctx.accounts.vault,
            &ctx.accounts.config,
            ctx.remaining_accounts,
            NATIVE_MINT,
            SOL_DECIMALS,
            gross,
            index,
            now,
        )?
    {
        net = gross;
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
    /// Writable so the burned share of an SKR fee can leave the supply.
    #[account(mut, mint::token_program = token_program)]
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
    /// The treasury's ATA; only needed when the payout leaves a fee for
    /// the treasury (not for fee-free payouts such as a single NFT).
    #[account(
        mut,
        associated_token::mint = mint,
        associated_token::authority = config.treasury,
        associated_token::token_program = token_program
    )]
    pub treasury_token: Option<Box<InterfaceAccount<'info, TokenAccount>>>,
    /// Plans hold classic SPL Token mints only.
    pub token_program: Program<'info, Token>,
}

/// Pays the release fee of a token payout of `gross` in SKR from the fee
/// reserve when it can (see [`pay_fee_in_skr`]): only for payouts that
/// would pay a fee in the asset and are not themselves in SKR.
fn token_fee_in_skr<'info>(
    ctx: &mut Context<'info, ExecuteTokenRule<'info>>,
    rail: Rail,
    gross: u64,
    index: u8,
    now: i64,
) -> Result<bool> {
    let a = &mut ctx.accounts;
    let mint = Some(a.mint.key());
    if a.config.is_skr(mint) || bps_of(gross, a.config.fee_bps(rail, mint))? == 0 {
        return Ok(false);
    }
    pay_fee_in_skr(
        &mut a.vault,
        &a.config,
        ctx.remaining_accounts,
        a.mint.key(),
        a.mint.decimals,
        gross,
        index,
        now,
    )
}

/// Sends a token payout of `gross`: the net to the beneficiary's account,
/// then the fee (for SKR, `skr_burn_bps` of it burned from the vault and
/// the rest to the treasury). No fee when it was paid in SKR from the
/// reserve. Returns (net, fee).
fn pay_token<'info>(
    a: &ExecuteTokenRule<'info>,
    rail: Rail,
    gross: u64,
    fee_paid: bool,
) -> Result<(u64, u64)> {
    let mint = a.mint.key();
    let fee_bps = if fee_paid {
        0
    } else {
        a.config.fee_bps(rail, Some(mint))
    };
    let (net, fee) = split_fee(gross, fee_bps)?;
    let (burned, to_treasury) = a.config.split_burn(fee, Some(mint))?;
    let token_program = a.token_program.to_account_info();
    vault_transfer(
        &token_program,
        &a.vault_token,
        &a.mint,
        a.beneficiary_token.to_account_info(),
        &a.vault,
        &[],
        net,
    )?;
    if burned > 0 {
        let plan_id = a.vault.plan_id.to_le_bytes();
        let seeds: &[&[u8]] = &[
            VAULT_SEED,
            a.vault.owner.as_ref(),
            &plan_id,
            &[a.vault.bump],
        ];
        token_interface::burn(
            CpiContext::new_with_signer(
                a.token_program.key(),
                Burn {
                    mint: a.mint.to_account_info(),
                    from: a.vault_token.to_account_info(),
                    authority: a.vault.to_account_info(),
                },
                &[seeds],
            ),
            burned,
        )?;
        emit!(FeeBurned {
            vault: a.vault.key(),
            mint,
            amount: burned,
        });
    }
    if to_treasury > 0 {
        let treasury = a
            .treasury_token
            .as_ref()
            .ok_or(DeadmanError::TreasuryAccountRequired)?;
        vault_transfer(
            &token_program,
            &a.vault_token,
            &a.mint,
            treasury.to_account_info(),
            &a.vault,
            &[],
            to_treasury,
        )?;
    }
    Ok((net, fee))
}

/// Permissionless: pays a due token rule. Private rails also receive a small
/// SOL stipend so a fresh claim key can pay to route the tokens onward.
pub fn handle_execute_token_rule<'info>(
    mut ctx: Context<'info, ExecuteTokenRule<'info>>,
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

    let tier_funds = a
        .vault_token
        .amount
        .saturating_sub(a.vault.fee_reserve_in(Some(a.mint.key())));
    let gross = a.vault.payout_gross(i, tier_funds)?;
    require!(gross > 0, DeadmanError::NothingToPay);
    let fee_paid = token_fee_in_skr(&mut ctx, rule.rail, gross, index, now)?;
    let (net, fee) = pay_token(ctx.accounts, rule.rail, gross, fee_paid)?;

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
            token
                .amount
                .saturating_sub(ctx.accounts.vault.fee_reserve_in(Some(mint)))
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
pub fn handle_release_vested_sol<'info>(
    ctx: Context<'info, ExecuteSolRule<'info>>,
    index: u8,
) -> Result<()> {
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
    let (mut net, mut fee) = split_fee(gross, ctx.accounts.config.fee_bps(rule.rail, None))?;
    let rent = Rent::get()?;
    let treasury = &ctx.accounts.treasury;
    if fee > 0
        && treasury.lamports().saturating_add(fee) < rent.minimum_balance(treasury.data_len())
    {
        net = net.checked_add(fee).ok_or(DeadmanError::MathOverflow)?;
        fee = 0;
    }
    if fee > 0
        && pay_fee_in_skr(
            &mut ctx.accounts.vault,
            &ctx.accounts.config,
            ctx.remaining_accounts,
            NATIVE_MINT,
            SOL_DECIMALS,
            gross,
            index,
            now,
        )?
    {
        net = gross;
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
    mut ctx: Context<'info, ExecuteTokenRule<'info>>,
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
    let tier_funds = a
        .vault_token
        .amount
        .saturating_sub(a.vault.fee_reserve_in(Some(a.mint.key())));
    let gross = due.min(tier_funds);
    require!(gross > 0, DeadmanError::NothingToPay);
    let fee_paid = token_fee_in_skr(&mut ctx, rule.rail, gross, index, now)?;
    let (net, fee) = pay_token(ctx.accounts, rule.rail, gross, fee_paid)?;
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

#[derive(Accounts)]
pub struct FundSkrReserve<'info> {
    pub owner: Signer<'info>,
    #[account(
        mut,
        seeds = [VAULT_SEED, owner.key().as_ref(), &vault.plan_id.to_le_bytes()],
        bump = vault.bump,
        has_one = owner @ DeadmanError::Unauthorized
    )]
    pub vault: Box<Account<'info, Vault>>,
    #[account(seeds = [CONFIG_SEED], bump = config.bump)]
    pub config: Box<Account<'info, Config>>,
    #[account(
        address = config.skr_mint @ DeadmanError::WrongAsset,
        mint::token_program = token_program
    )]
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
    pub token_program: Program<'info, Token>,
}

/// Moves `amount` SKR from the owner into the plan's fee reserve, which
/// pays release fees in SKR instead of in the payout asset. Allowed at any
/// time, like any deposit.
pub fn handle_fund_skr_reserve(ctx: Context<FundSkrReserve>, amount: u64) -> Result<()> {
    let a = &ctx.accounts;
    let mint = a.mint.key();
    require!(
        a.vault.skr_fee_reserve == 0 || a.vault.skr_reserve_mint == mint,
        DeadmanError::WrongAsset
    );
    token_interface::transfer_checked(
        CpiContext::new(
            a.token_program.key(),
            TransferChecked {
                from: a.owner_token.to_account_info(),
                mint: a.mint.to_account_info(),
                to: a.vault_token.to_account_info(),
                authority: a.owner.to_account_info(),
            },
        ),
        amount,
        a.mint.decimals,
    )?;
    let vault = &mut ctx.accounts.vault;
    vault.skr_reserve_mint = mint;
    vault.skr_fee_reserve = vault
        .skr_fee_reserve
        .checked_add(amount)
        .ok_or(DeadmanError::MathOverflow)?;
    Ok(())
}

/// Returns up to the whole SKR fee reserve to the owner, without a fee.
/// Like every withdrawal, blocked during lockdown.
pub fn handle_withdraw_skr_reserve<'info>(
    ctx: Context<'info, WithdrawToken<'info>>,
    amount: u64,
) -> Result<()> {
    let now = Clock::get()?.unix_timestamp;
    let a = &ctx.accounts;
    a.vault.require_unlocked(now)?;
    require_keys_eq!(
        a.mint.key(),
        a.vault.skr_reserve_mint,
        DeadmanError::WrongAsset
    );
    require!(
        amount <= a.vault.skr_fee_reserve,
        DeadmanError::InsufficientFunds
    );
    vault_transfer(
        a.token_program.as_ref(),
        &a.vault_token,
        &a.mint,
        a.owner_token.to_account_info(),
        &a.vault,
        &[],
        amount,
    )?;
    let vault = &mut ctx.accounts.vault;
    vault.skr_fee_reserve = vault
        .skr_fee_reserve
        .checked_sub(amount)
        .ok_or(DeadmanError::MathOverflow)?;
    vault.record_owner_pulse(now)
}
