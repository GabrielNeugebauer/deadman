use anchor_lang::prelude::*;

use crate::{constants::*, error::DeadmanError, state::Config};

#[derive(Accounts)]
pub struct InitConfig<'info> {
    #[account(mut)]
    pub admin: Signer<'info>,
    #[account(
        init,
        payer = admin,
        space = 8 + Config::INIT_SPACE,
        seeds = [CONFIG_SEED],
        bump
    )]
    pub config: Account<'info, Config>,
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

fn validate_config(treasury: &Pubkey, fee_bps_public: u16, fee_bps_private: u16) -> Result<()> {
    require!(
        fee_bps_public <= MAX_FEE_BPS && fee_bps_private <= MAX_FEE_BPS,
        DeadmanError::FeeTooHigh
    );
    require!(*treasury != Pubkey::default(), DeadmanError::InvalidConfig);
    Ok(())
}

pub fn handle_init_config(
    ctx: Context<InitConfig>,
    treasury: Pubkey,
    fee_bps_public: u16,
    fee_bps_private: u16,
) -> Result<()> {
    validate_config(&treasury, fee_bps_public, fee_bps_private)?;
    ctx.accounts.config.set_inner(Config {
        admin: ctx.accounts.admin.key(),
        treasury,
        fee_bps_public,
        fee_bps_private,
        bump: ctx.bumps.config,
    });
    Ok(())
}

#[derive(Accounts)]
pub struct SetConfig<'info> {
    pub admin: Signer<'info>,
    #[account(
        mut,
        seeds = [CONFIG_SEED],
        bump = config.bump,
        has_one = admin @ DeadmanError::Unauthorized
    )]
    pub config: Account<'info, Config>,
}

pub fn handle_set_config(
    ctx: Context<SetConfig>,
    treasury: Pubkey,
    fee_bps_public: u16,
    fee_bps_private: u16,
) -> Result<()> {
    validate_config(&treasury, fee_bps_public, fee_bps_private)?;
    let config = &mut ctx.accounts.config;
    config.treasury = treasury;
    config.fee_bps_public = fee_bps_public;
    config.fee_bps_private = fee_bps_private;
    Ok(())
}
