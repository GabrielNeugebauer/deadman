use anchor_lang::prelude::*;
use anchor_spl::token_interface::{self, Mint, TokenAccount, TokenInterface, TransferChecked};

use crate::{
    constants::*,
    error::DeadmanError,
    events::AccountSubscribed,
    state::{Config, Subscription, SubscriptionConfig},
};

#[derive(Accounts)]
pub struct SetSubscription<'info> {
    #[account(mut)]
    pub admin: Signer<'info>,
    #[account(
        seeds = [CONFIG_SEED],
        bump = config.bump,
        has_one = admin @ DeadmanError::Unauthorized
    )]
    pub config: Account<'info, Config>,
    #[account(
        init_if_needed,
        payer = admin,
        space = 8 + SubscriptionConfig::INIT_SPACE,
        seeds = [SUB_CONFIG_SEED],
        bump
    )]
    pub sub_config: Account<'info, SubscriptionConfig>,
    pub system_program: Program<'info, System>,
}

pub fn handle_set_subscription(
    ctx: Context<SetSubscription>,
    price_per_period: u64,
    period_secs: i64,
    mint: Pubkey,
    enabled: bool,
    min_periods: u16,
) -> Result<()> {
    require!(
        price_per_period > 0
            && (MIN_SUB_PERIOD_SECS..=MAX_SUB_PERIOD_SECS).contains(&period_secs)
            && (1..=MAX_SUB_PERIODS).contains(&min_periods)
            && mint != Pubkey::default(),
        DeadmanError::InvalidSubscription
    );
    ctx.accounts.sub_config.set_inner(SubscriptionConfig {
        price_per_period,
        period_secs,
        mint,
        enabled,
        bump: ctx.bumps.sub_config,
        min_periods,
    });
    Ok(())
}

#[derive(Accounts)]
pub struct Subscribe<'info> {
    pub owner: Signer<'info>,
    /// Funds the subscription account's rent: the owner, or a fee sponsor.
    #[account(mut)]
    pub payer: Signer<'info>,
    #[account(
        init_if_needed,
        payer = payer,
        space = Subscription::SPACE,
        seeds = [SUBSCRIPTION_SEED, owner.key().as_ref()],
        bump
    )]
    pub subscription: Box<Account<'info, Subscription>>,
    #[account(seeds = [CONFIG_SEED], bump = config.bump)]
    pub config: Box<Account<'info, Config>>,
    #[account(
        seeds = [SUB_CONFIG_SEED],
        bump = sub_config.bump,
        constraint = sub_config.enabled @ DeadmanError::SubscriptionDisabled
    )]
    pub sub_config: Box<Account<'info, SubscriptionConfig>>,
    #[account(
        address = sub_config.mint @ DeadmanError::InvalidSubscription,
        mint::token_program = token_program
    )]
    pub mint: Box<InterfaceAccount<'info, Mint>>,
    #[account(
        mut,
        token::mint = mint,
        token::authority = owner,
        token::token_program = token_program
    )]
    pub owner_token: Box<InterfaceAccount<'info, TokenAccount>>,
    #[account(
        mut,
        associated_token::mint = mint,
        associated_token::authority = config.treasury,
        associated_token::token_program = token_program
    )]
    pub treasury_token: Box<InterfaceAccount<'info, TokenAccount>>,
    pub token_program: Interface<'info, TokenInterface>,
    pub system_program: Program<'info, System>,
}

/// Prepays `periods` subscription periods for the owner's account (at
/// least `min_periods` when starting or after a lapse). While covered, no
/// plan of the owner, present or future, pays the payout fee (see
/// [`Subscription::covers`]).
pub fn handle_subscribe(ctx: Context<Subscribe>, periods: u16) -> Result<()> {
    require!(
        (1..=MAX_SUB_PERIODS).contains(&periods),
        DeadmanError::InvalidSubscription
    );
    let now = Clock::get()?.unix_timestamp;
    let sub = &ctx.accounts.sub_config;
    let current = ctx.accounts.subscription.paid_until;
    // A new or lapsed subscription commits to the minimum term; an active
    // one may be extended by any number of periods.
    if current < now {
        require!(
            periods >= sub.min_periods,
            DeadmanError::InvalidSubscription
        );
    }
    let amount = sub
        .price_per_period
        .checked_mul(u64::from(periods))
        .ok_or(DeadmanError::MathOverflow)?;
    let paid_until = current
        .max(now)
        .checked_add(
            sub.period_secs
                .checked_mul(i64::from(periods))
                .ok_or(DeadmanError::MathOverflow)?,
        )
        .ok_or(DeadmanError::MathOverflow)?;

    token_interface::transfer_checked(
        CpiContext::new(
            ctx.accounts.token_program.key(),
            TransferChecked {
                from: ctx.accounts.owner_token.to_account_info(),
                mint: ctx.accounts.mint.to_account_info(),
                to: ctx.accounts.treasury_token.to_account_info(),
                authority: ctx.accounts.owner.to_account_info(),
            },
        ),
        amount,
        ctx.accounts.mint.decimals,
    )?;

    let owner = ctx.accounts.owner.key();
    let subscription = &mut ctx.accounts.subscription;
    subscription.owner = owner;
    subscription.bump = ctx.bumps.subscription;
    subscription.paid_until = paid_until;
    emit!(AccountSubscribed {
        owner,
        paid_until,
        amount,
    });
    Ok(())
}
