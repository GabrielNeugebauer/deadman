pub mod constants;
pub mod error;
pub mod events;
pub mod instructions;
pub mod state;

use anchor_lang::prelude::*;

pub use constants::*;
pub use instructions::*;
pub use state::*;

declare_id!("ACHVLMoLDM3YPpGbNST4cZW4Tf2jx6nzJGuusyLJHofL");

#[program]
pub mod deadman {
    use super::*;

    pub fn init_config(
        ctx: Context<InitConfig>,
        treasury: Pubkey,
        skr_mint: Pubkey,
        plus_price: u64,
        fee_bps: u16,
    ) -> Result<()> {
        instructions::config::handle_init_config(ctx, treasury, skr_mint, plus_price, fee_bps)
    }

    pub fn set_config(
        ctx: Context<SetConfig>,
        treasury: Pubkey,
        skr_mint: Pubkey,
        plus_price: u64,
        fee_bps: u16,
    ) -> Result<()> {
        instructions::config::handle_set_config(ctx, treasury, skr_mint, plus_price, fee_bps)
    }

    pub fn create_vault(
        ctx: Context<CreateVault>,
        guard: Pubkey,
        interval_secs: i64,
        grace_secs: i64,
        lock_secs: i64,
        heirs: Vec<HeirInput>,
    ) -> Result<()> {
        instructions::vault::handle_create_vault(
            ctx,
            guard,
            interval_secs,
            grace_secs,
            lock_secs,
            heirs,
        )
    }

    pub fn update_policy(
        ctx: Context<OwnerAction>,
        interval_secs: i64,
        grace_secs: i64,
        lock_secs: i64,
        heirs: Vec<HeirInput>,
        guardian: Option<Pubkey>,
    ) -> Result<()> {
        instructions::vault::handle_update_policy(
            ctx,
            interval_secs,
            grace_secs,
            lock_secs,
            heirs,
            guardian,
        )
    }

    pub fn set_guard(ctx: Context<OwnerAction>, new_guard: Pubkey) -> Result<()> {
        instructions::vault::handle_set_guard(ctx, new_guard)
    }

    pub fn pulse(ctx: Context<Pulse>) -> Result<()> {
        instructions::vault::handle_pulse(ctx)
    }

    pub fn lockdown(ctx: Context<Lockdown>) -> Result<()> {
        instructions::vault::handle_lockdown(ctx)
    }

    pub fn unlock(ctx: Context<Unlock>) -> Result<()> {
        instructions::vault::handle_unlock(ctx)
    }

    pub fn close_vault(ctx: Context<CloseVault>) -> Result<()> {
        instructions::vault::handle_close_vault(ctx)
    }

    pub fn withdraw_sol(ctx: Context<WithdrawSol>, amount: u64) -> Result<()> {
        instructions::funds::handle_withdraw_sol(ctx, amount)
    }

    pub fn withdraw_token<'info>(
        ctx: Context<'info, WithdrawToken<'info>>,
        amount: u64,
    ) -> Result<()> {
        instructions::funds::handle_withdraw_token(ctx, amount)
    }

    pub fn trigger(ctx: Context<Trigger>) -> Result<()> {
        instructions::funds::handle_trigger(ctx)
    }

    pub fn claim_sol(ctx: Context<ClaimSol>) -> Result<()> {
        instructions::funds::handle_claim_sol(ctx)
    }

    pub fn claim_token<'info>(ctx: Context<'info, ClaimToken<'info>>) -> Result<()> {
        instructions::funds::handle_claim_token(ctx)
    }

    pub fn subscribe(ctx: Context<Subscribe>, months: u8) -> Result<()> {
        instructions::funds::handle_subscribe(ctx, months)
    }
}
