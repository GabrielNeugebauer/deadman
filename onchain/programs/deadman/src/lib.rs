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
        fee_bps_public: u16,
        fee_bps_private: u16,
    ) -> Result<()> {
        instructions::config::handle_init_config(ctx, treasury, fee_bps_public, fee_bps_private)
    }

    pub fn set_config(
        ctx: Context<SetConfig>,
        treasury: Pubkey,
        fee_bps_public: u16,
        fee_bps_private: u16,
    ) -> Result<()> {
        instructions::config::handle_set_config(ctx, treasury, fee_bps_public, fee_bps_private)
    }

    #[allow(clippy::too_many_arguments)]
    pub fn create_vault(
        ctx: Context<CreateVault>,
        plan_id: u16,
        label: String,
        guard: Pubkey,
        interval_secs: i64,
        lock_secs: i64,
        skip_grace_secs: i64,
        rules: Vec<RuleInput>,
    ) -> Result<()> {
        instructions::vault::handle_create_vault(
            ctx,
            plan_id,
            label,
            guard,
            interval_secs,
            lock_secs,
            skip_grace_secs,
            rules,
        )
    }

    pub fn update_policy(
        ctx: Context<OwnerAction>,
        label: String,
        interval_secs: i64,
        lock_secs: i64,
        skip_grace_secs: i64,
        rules: Vec<RuleInput>,
        guardian: Option<Pubkey>,
    ) -> Result<()> {
        instructions::vault::handle_update_policy(
            ctx,
            label,
            interval_secs,
            lock_secs,
            skip_grace_secs,
            rules,
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

    pub fn execute_sol_rule(ctx: Context<ExecuteSolRule>, index: u8) -> Result<()> {
        instructions::funds::handle_execute_sol_rule(ctx, index)
    }

    pub fn skip_rule(ctx: Context<SkipRule>, index: u8) -> Result<()> {
        instructions::funds::handle_skip_rule(ctx, index)
    }

    pub fn execute_token_rule<'info>(
        ctx: Context<'info, ExecuteTokenRule<'info>>,
        index: u8,
    ) -> Result<()> {
        instructions::funds::handle_execute_token_rule(ctx, index)
    }
}
