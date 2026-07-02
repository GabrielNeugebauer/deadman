use anchor_lang::prelude::*;

use crate::{constants::*, error::DeadmanError};

#[account]
#[derive(InitSpace)]
pub struct Config {
    pub admin: Pubkey,
    pub treasury: Pubkey,
    /// Payout fee for the plain Solana rail.
    pub fee_bps_public: u16,
    /// Payout fee for private rails (Cloak, Zcash).
    pub fee_bps_private: u16,
    pub bump: u8,
}

impl Config {
    pub fn fee_bps(&self, rail: Rail) -> u16 {
        match rail {
            Rail::Solana => self.fee_bps_public,
            Rail::Cloak | Rail::Zcash => self.fee_bps_private,
        }
    }
}

/// Delivery rail. On-chain every rail pays a Solana key; for private rails
/// that key is a fresh claim key whose app routes the funds onward.
#[derive(AnchorSerialize, AnchorDeserialize, Clone, Copy, InitSpace, PartialEq, Eq, Debug)]
pub enum Rail {
    Solana,
    Cloak,
    Zcash,
}

impl Rail {
    pub fn is_private(self) -> bool {
        self != Rail::Solana
    }
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone, Copy, InitSpace, PartialEq, Eq, Debug)]
pub enum AmountMode {
    /// `amount` in lamports or token base units (capped at the balance).
    Fixed,
    /// `amount` in bps of the asset's balance when the rule executes.
    Percent,
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone, Copy, InitSpace, PartialEq, Eq, Debug)]
pub struct RuleInput {
    pub beneficiary: Pubkey,
    pub rail: Rail,
    /// Seconds of owner silence (since the last pulse) before this rule fires.
    pub after_secs: i64,
    /// `None` = SOL.
    pub mint: Option<Pubkey>,
    pub mode: AmountMode,
    pub amount: u64,
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone, Copy, InitSpace, PartialEq, Eq, Debug)]
pub struct Rule {
    pub beneficiary: Pubkey,
    pub rail: Rail,
    pub after_secs: i64,
    pub mint: Option<Pubkey>,
    pub mode: AmountMode,
    pub amount: u64,
    /// 0 while pending.
    pub executed_at: i64,
    /// Net amount the beneficiary received.
    pub paid: u64,
}

#[account]
#[derive(InitSpace)]
pub struct Vault {
    pub owner: Pubkey,
    /// Device key: may only pulse and lock down, never move funds.
    pub guard: Pubkey,
    /// Trusted contact: may lock down (rate-limited) and co-sign early unlock.
    pub guardian: Option<Pubkey>,
    /// Check-in cadence; drives reminders and the minimum rule delay.
    pub interval_secs: i64,
    pub lock_secs: i64,
    pub last_pulse: i64,
    pub locked_until: i64,
    /// Earliest time the guardian may lock down again.
    pub guardian_ready_at: i64,
    pub total_pulses: u64,
    pub streak: u32,
    pub best_streak: u32,
    #[max_len(MAX_RULES)]
    pub rules: Vec<Rule>,
    pub bump: u8,
}

impl Vault {
    pub fn is_locked(&self, now: i64) -> bool {
        now < self.locked_until
    }

    pub fn require_unlocked(&self, now: i64) -> Result<()> {
        require!(!self.is_locked(now), DeadmanError::VaultLocked);
        Ok(())
    }

    pub fn rule_due_at(&self, index: usize) -> Result<i64> {
        self.last_pulse
            .checked_add(self.rules[index].after_secs)
            .ok_or_else(|| error!(DeadmanError::MathOverflow))
    }

    /// Resets every pending rule's clock and advances the daily streak.
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

    /// Checks that rule `index` may execute now for `mint`, enforcing the
    /// per-asset order so percentages apply to a deterministic balance.
    pub fn check_executable(&self, index: usize, mint: Option<Pubkey>, now: i64) -> Result<()> {
        require!(index < self.rules.len(), DeadmanError::InvalidRuleIndex);
        let rule = &self.rules[index];
        require!(rule.mint == mint, DeadmanError::WrongAsset);
        require!(rule.executed_at == 0, DeadmanError::RuleAlreadyExecuted);
        require!(now > self.rule_due_at(index)?, DeadmanError::RuleNotDue);
        require!(
            self.rules[..index]
                .iter()
                .all(|r| r.mint != mint || r.executed_at != 0),
            DeadmanError::RuleOutOfOrder
        );
        Ok(())
    }

    /// Validates and installs the full policy. Caller enforces auth.
    pub fn apply_policy(
        &mut self,
        interval_secs: i64,
        lock_secs: i64,
        rules: &[RuleInput],
        guardian: Option<Pubkey>,
    ) -> Result<()> {
        require!(
            (MIN_INTERVAL_SECS..=MAX_INTERVAL_SECS).contains(&interval_secs)
                && (MIN_LOCK_SECS..=MAX_LOCK_SECS).contains(&lock_secs),
            DeadmanError::InvalidDuration
        );
        require!(
            !rules.is_empty() && rules.len() <= MAX_RULES,
            DeadmanError::InvalidRules
        );
        let min_delay = interval_secs
            .checked_add(MIN_RULE_MARGIN_SECS)
            .ok_or(DeadmanError::MathOverflow)?;
        for (i, r) in rules.iter().enumerate() {
            let amount_ok = match r.mode {
                AmountMode::Fixed => r.amount > 0,
                AmountMode::Percent => (1..=BPS_DENOMINATOR).contains(&r.amount),
            };
            require!(
                amount_ok
                    && (min_delay..=MAX_RULE_DELAY_SECS).contains(&r.after_secs)
                    && (i == 0 || rules[i - 1].after_secs <= r.after_secs)
                    && r.beneficiary != Pubkey::default()
                    && r.beneficiary != self.owner
                    && r.beneficiary != self.guard
                    && r.mint != Some(Pubkey::default()),
                DeadmanError::InvalidRules
            );
        }
        if let Some(g) = guardian {
            require!(
                g != Pubkey::default()
                    && g != self.owner
                    && g != self.guard
                    && !rules.iter().any(|r| r.beneficiary == g),
                DeadmanError::InvalidGuardian
            );
        }

        self.interval_secs = interval_secs;
        self.lock_secs = lock_secs;
        self.guardian = guardian;
        self.rules = rules
            .iter()
            .map(|r| Rule {
                beneficiary: r.beneficiary,
                rail: r.rail,
                after_secs: r.after_secs,
                mint: r.mint,
                mode: r.mode,
                amount: r.amount,
                executed_at: 0,
                paid: 0,
            })
            .collect();
        Ok(())
    }
}

/// Gross payout for a rule given the asset's current available balance.
pub fn rule_gross(rule: &Rule, available: u64) -> Result<u64> {
    Ok(match rule.mode {
        AmountMode::Fixed => rule.amount.min(available),
        AmountMode::Percent => {
            let v = u128::from(available)
                .checked_mul(u128::from(rule.amount))
                .and_then(|v| v.checked_div(u128::from(BPS_DENOMINATOR)))
                .ok_or(DeadmanError::MathOverflow)?;
            u64::try_from(v).map_err(|_| DeadmanError::MathOverflow)?
        }
    })
}

/// Splits `gross` into (net, fee) at `fee_bps`.
pub fn split_fee(gross: u64, fee_bps: u16) -> Result<(u64, u64)> {
    let fee = u128::from(gross)
        .checked_mul(u128::from(fee_bps))
        .and_then(|v| v.checked_div(u128::from(BPS_DENOMINATOR)))
        .ok_or(DeadmanError::MathOverflow)?;
    let fee = u64::try_from(fee).map_err(|_| DeadmanError::MathOverflow)?;
    let net = gross.checked_sub(fee).ok_or(DeadmanError::MathOverflow)?;
    Ok((net, fee))
}
