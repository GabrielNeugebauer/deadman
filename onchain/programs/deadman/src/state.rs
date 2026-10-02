use anchor_lang::prelude::*;

use crate::{constants::*, error::DeadmanError};

#[account]
#[derive(InitSpace)]
pub struct Config {
    pub admin: Pubkey,
    pub treasury: Pubkey,
    pub skr_mint: Pubkey,
    /// Deadman Plus price per 30 days, in SKR base units.
    pub plus_price: u64,
    pub fee_bps: u16,
    pub bump: u8,
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone, Copy, InitSpace, PartialEq, Eq, Debug)]
pub struct HeirInput {
    pub wallet: Pubkey,
    pub bps: u16,
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone, Copy, InitSpace, PartialEq, Eq, Debug)]
pub struct Heir {
    pub wallet: Pubkey,
    pub bps: u16,
    pub claimed_sol: bool,
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone, Copy, InitSpace, PartialEq, Eq, Debug)]
pub enum VaultStatus {
    Active,
    Triggered,
}

#[account]
#[derive(InitSpace)]
pub struct Vault {
    pub owner: Pubkey,
    /// Device key: may only pulse and lock down, never move funds.
    pub guard: Pubkey,
    /// Optional trusted contact (Plus): may lock down, co-signs early unlock.
    pub guardian: Option<Pubkey>,
    pub interval_secs: i64,
    pub grace_secs: i64,
    pub lock_secs: i64,
    pub last_pulse: i64,
    pub locked_until: i64,
    pub plus_until: i64,
    pub triggered_at: i64,
    pub sol_at_trigger: u64,
    pub total_pulses: u64,
    pub streak: u32,
    pub best_streak: u32,
    pub status: VaultStatus,
    #[max_len(MAX_HEIRS)]
    pub heirs: Vec<Heir>,
    pub bump: u8,
}

impl Vault {
    pub fn deadline(&self) -> Result<i64> {
        self.last_pulse
            .checked_add(self.interval_secs)
            .and_then(|t| t.checked_add(self.grace_secs))
            .ok_or_else(|| error!(DeadmanError::MathOverflow))
    }

    pub fn is_locked(&self, now: i64) -> bool {
        now < self.locked_until
    }

    pub fn is_plus(&self, now: i64) -> bool {
        now < self.plus_until
    }

    pub fn require_active(&self) -> Result<()> {
        require!(
            self.status == VaultStatus::Active,
            DeadmanError::VaultNotActive
        );
        Ok(())
    }

    pub fn require_unlocked(&self, now: i64) -> Result<()> {
        require!(!self.is_locked(now), DeadmanError::VaultLocked);
        Ok(())
    }

    /// Resets the switch and advances the daily streak.
    pub fn record_pulse(&mut self, now: i64) -> Result<()> {
        let day = now / SECS_PER_DAY;
        let last_day = self.last_pulse / SECS_PER_DAY;
        if self.total_pulses == 0 {
            self.streak = 1;
        } else if day == last_day.checked_add(1).ok_or(DeadmanError::MathOverflow)? {
            self.streak = self
                .streak
                .checked_add(1)
                .ok_or(DeadmanError::MathOverflow)?;
        } else if day != last_day {
            self.streak = 1;
        }
        self.best_streak = self.best_streak.max(self.streak);
        self.total_pulses = self
            .total_pulses
            .checked_add(1)
            .ok_or(DeadmanError::MathOverflow)?;
        self.last_pulse = now;
        Ok(())
    }

    pub fn heir_index(&self, wallet: &Pubkey) -> Result<usize> {
        self.heirs
            .iter()
            .position(|h| h.wallet == *wallet)
            .ok_or_else(|| error!(DeadmanError::NotAnHeir))
    }

    /// Validates and applies the full vault policy. Caller enforces auth.
    #[allow(clippy::too_many_arguments)]
    pub fn apply_policy(
        &mut self,
        now: i64,
        interval_secs: i64,
        grace_secs: i64,
        lock_secs: i64,
        heirs: &[HeirInput],
        guardian: Option<Pubkey>,
    ) -> Result<()> {
        require!(
            (MIN_INTERVAL_SECS..=MAX_INTERVAL_SECS).contains(&interval_secs)
                && (MIN_GRACE_SECS..=MAX_GRACE_SECS).contains(&grace_secs)
                && (MIN_LOCK_SECS..=MAX_LOCK_SECS).contains(&lock_secs),
            DeadmanError::InvalidDuration
        );

        let max_heirs = if self.is_plus(now) {
            MAX_HEIRS
        } else {
            FREE_MAX_HEIRS
        };
        require!(!heirs.is_empty(), DeadmanError::InvalidHeirs);
        require!(heirs.len() <= max_heirs, DeadmanError::TooManyHeirs);

        let mut total: u64 = 0;
        for (i, h) in heirs.iter().enumerate() {
            require!(
                h.bps > 0
                    && h.wallet != Pubkey::default()
                    && h.wallet != self.owner
                    && h.wallet != self.guard
                    && !heirs[..i].iter().any(|o| o.wallet == h.wallet),
                DeadmanError::InvalidHeirs
            );
            total = total
                .checked_add(u64::from(h.bps))
                .ok_or(DeadmanError::MathOverflow)?;
        }
        require!(total == BPS_DENOMINATOR, DeadmanError::InvalidHeirs);

        if let Some(g) = guardian {
            require!(self.is_plus(now), DeadmanError::PlusRequired);
            require!(
                g != Pubkey::default()
                    && g != self.owner
                    && g != self.guard
                    && !heirs.iter().any(|h| h.wallet == g),
                DeadmanError::InvalidGuardian
            );
        }

        self.interval_secs = interval_secs;
        self.grace_secs = grace_secs;
        self.lock_secs = lock_secs;
        self.guardian = guardian;
        self.heirs = heirs
            .iter()
            .map(|h| Heir {
                wallet: h.wallet,
                bps: h.bps,
                claimed_sol: false,
            })
            .collect();
        Ok(())
    }
}

/// Per-mint claim ledger, snapshotted at the first claim after trigger.
#[account]
#[derive(InitSpace)]
pub struct TokenClaim {
    pub vault: Pubkey,
    pub mint: Pubkey,
    pub amount_at_snapshot: u64,
    pub claimed_mask: u8,
    pub initialized: bool,
    pub bump: u8,
}

/// `amount * bps / 10_000`, then the protocol fee on that share.
pub fn split_share(amount: u64, bps: u16, fee_bps: u16) -> Result<(u64, u64)> {
    let gross = u128::from(amount)
        .checked_mul(u128::from(bps))
        .and_then(|v| v.checked_div(u128::from(BPS_DENOMINATOR)))
        .ok_or(DeadmanError::MathOverflow)?;
    let fee = gross
        .checked_mul(u128::from(fee_bps))
        .and_then(|v| v.checked_div(u128::from(BPS_DENOMINATOR)))
        .ok_or(DeadmanError::MathOverflow)?;
    let net = gross.checked_sub(fee).ok_or(DeadmanError::MathOverflow)?;
    Ok((
        u64::try_from(net).map_err(|_| DeadmanError::MathOverflow)?,
        u64::try_from(fee).map_err(|_| DeadmanError::MathOverflow)?,
    ))
}
