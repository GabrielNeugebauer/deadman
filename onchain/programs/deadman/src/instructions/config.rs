use anchor_lang::{prelude::*, system_program};

use crate::{
    constants::*,
    error::DeadmanError,
    events::{AdminChanged, AdminProposed},
    state::{Config, ConfigV1},
};

/// The treasury must be able to receive lamports as a writable account:
/// a system-owned, non-executable wallet (or a not yet funded address).
/// Sysvars, programs and program-owned accounts are refused, because the
/// runtime would demote them to read-only and block every SOL payout.
fn validate_treasury(treasury: &AccountInfo) -> Result<()> {
    require!(
        treasury.key() != Pubkey::default()
            && treasury.owner == &system_program::ID
            && !treasury.executable,
        DeadmanError::InvalidConfig
    );
    Ok(())
}

fn validate_fees(
    fee_bps_public: u16,
    fee_bps_private: u16,
    fee_bps_skr: u16,
    skr_burn_bps: u16,
) -> Result<()> {
    require!(
        fee_bps_public <= MAX_FEE_BPS
            && fee_bps_private <= MAX_FEE_BPS
            && fee_bps_skr <= MAX_FEE_BPS,
        DeadmanError::FeeTooHigh
    );
    require!(
        u64::from(skr_burn_bps) <= BPS_DENOMINATOR,
        DeadmanError::InvalidConfig
    );
    Ok(())
}

#[derive(Accounts)]
pub struct InitConfig<'info> {
    #[account(mut)]
    pub admin: Signer<'info>,
    #[account(
        init,
        payer = admin,
        space = Config::SPACE,
        seeds = [CONFIG_SEED],
        bump
    )]
    pub config: Account<'info, Config>,
    /// CHECK: fee destination; must be a system-owned wallet
    /// ([`validate_treasury`]).
    pub treasury: UncheckedAccount<'info>,
    #[account(
        constraint = program.programdata_address()? == Some(program_data.key())
            @ DeadmanError::Unauthorized
    )]
    pub program: Program<'info, crate::program::Deadman>,
    #[account(
        constraint = program_data.upgrade_authority_address == Some(admin.key())
            @ DeadmanError::Unauthorized
    )]
    pub program_data: Account<'info, ProgramData>,
    pub system_program: Program<'info, System>,
}

/// Creates the config with the default fees: 2% per release on every
/// rail, 1.5% for payouts in `skr_mint`, 10% of which is burned.
pub fn handle_init_config(ctx: Context<InitConfig>, skr_mint: Pubkey) -> Result<()> {
    validate_treasury(&ctx.accounts.treasury)?;
    ctx.accounts.config.set_inner(Config {
        admin: ctx.accounts.admin.key(),
        treasury: ctx.accounts.treasury.key(),
        fee_bps_public: DEFAULT_FEE_BPS,
        fee_bps_private: DEFAULT_FEE_BPS,
        bump: ctx.bumps.config,
        skr_mint,
        fee_bps_skr: DEFAULT_FEE_BPS_SKR,
        skr_burn_bps: DEFAULT_SKR_BURN_BPS,
        pending_admin: Pubkey::default(),
        _reserved: [0; 64],
    });
    Ok(())
}

#[derive(Accounts)]
pub struct SetConfig<'info> {
    /// Pays the rent of a v1 config's reallocation.
    #[account(mut)]
    pub admin: Signer<'info>,
    /// CHECK: the config PDA in the current or the v1 layout; its
    /// discriminator and admin are checked in [`load_config`].
    #[account(mut, owner = crate::ID, seeds = [CONFIG_SEED], bump)]
    pub config: UncheckedAccount<'info>,
    /// CHECK: fee destination; must be a system-owned wallet
    /// ([`validate_treasury`]).
    pub treasury: UncheckedAccount<'info>,
    pub system_program: Program<'info, System>,
}

/// Reads the config in either layout. A v1 config gets the defaults for
/// the fields it lacks.
fn load_config(info: &AccountInfo) -> Result<Config> {
    let data = info.try_borrow_data()?;
    if data.len() >= Config::SPACE {
        return Config::try_deserialize(&mut &data[..]);
    }
    require!(
        data.len() >= 8 && data[..8] == *Config::DISCRIMINATOR,
        ErrorCode::AccountDiscriminatorMismatch
    );
    let v1 = ConfigV1::deserialize(&mut &data[8..])?;
    Ok(Config {
        admin: v1.admin,
        treasury: v1.treasury,
        fee_bps_public: v1.fee_bps_public,
        fee_bps_private: v1.fee_bps_private,
        bump: v1.bump,
        skr_mint: Pubkey::default(),
        fee_bps_skr: DEFAULT_FEE_BPS_SKR,
        skr_burn_bps: DEFAULT_SKR_BURN_BPS,
        pending_admin: Pubkey::default(),
        _reserved: [0; 64],
    })
}

/// Updates every fee setting, and migrates a v1 config to the current
/// layout first (the admin pays the extra rent).
pub fn handle_set_config(
    ctx: Context<SetConfig>,
    fee_bps_public: u16,
    fee_bps_private: u16,
    skr_mint: Pubkey,
    fee_bps_skr: u16,
    skr_burn_bps: u16,
) -> Result<()> {
    validate_treasury(&ctx.accounts.treasury)?;
    validate_fees(fee_bps_public, fee_bps_private, fee_bps_skr, skr_burn_bps)?;
    let info = ctx.accounts.config.to_account_info();
    let mut config = load_config(&info)?;
    require_keys_eq!(
        config.admin,
        ctx.accounts.admin.key(),
        DeadmanError::Unauthorized
    );

    if info.data_len() < Config::SPACE {
        let needed = Rent::get()?
            .minimum_balance(Config::SPACE)
            .saturating_sub(info.lamports());
        if needed > 0 {
            system_program::transfer(
                CpiContext::new(
                    ctx.accounts.system_program.key(),
                    system_program::Transfer {
                        from: ctx.accounts.admin.to_account_info(),
                        to: info.clone(),
                    },
                ),
                needed,
            )?;
        }
        info.resize(Config::SPACE)?;
    }

    config.treasury = ctx.accounts.treasury.key();
    config.fee_bps_public = fee_bps_public;
    config.fee_bps_private = fee_bps_private;
    config.skr_mint = skr_mint;
    config.fee_bps_skr = fee_bps_skr;
    config.skr_burn_bps = skr_burn_bps;
    let mut data = info.try_borrow_mut_data()?;
    config.try_serialize(&mut &mut data[..])
}

#[derive(Accounts)]
pub struct ProposeAdmin<'info> {
    pub admin: Signer<'info>,
    #[account(
        mut,
        seeds = [CONFIG_SEED],
        bump = config.bump,
        has_one = admin @ DeadmanError::Unauthorized
    )]
    pub config: Account<'info, Config>,
}

/// First step of an admin rotation; `Pubkey::default()` cancels a pending
/// proposal. Nothing changes until the new admin accepts.
pub fn handle_propose_admin(ctx: Context<ProposeAdmin>, new_admin: Pubkey) -> Result<()> {
    let config = &mut ctx.accounts.config;
    config.pending_admin = new_admin;
    emit!(AdminProposed {
        admin: config.admin,
        pending_admin: new_admin,
    });
    Ok(())
}

#[derive(Accounts)]
pub struct AcceptAdmin<'info> {
    pub new_admin: Signer<'info>,
    #[account(
        mut,
        seeds = [CONFIG_SEED],
        bump = config.bump,
        constraint = config.pending_admin != Pubkey::default()
            && config.pending_admin == new_admin.key() @ DeadmanError::Unauthorized
    )]
    pub config: Account<'info, Config>,
}

/// Second step: the proposed admin signs to take over.
pub fn handle_accept_admin(ctx: Context<AcceptAdmin>) -> Result<()> {
    let config = &mut ctx.accounts.config;
    let old_admin = config.admin;
    config.admin = ctx.accounts.new_admin.key();
    config.pending_admin = Pubkey::default();
    emit!(AdminChanged {
        old_admin,
        new_admin: config.admin,
    });
    Ok(())
}
