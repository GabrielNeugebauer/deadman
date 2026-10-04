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

/// Inheritance plans release tiers after owner silence; vesting plans
/// release linearly over time from a fixed start, whatever the owner does.
#[derive(AnchorSerialize, AnchorDeserialize, Clone, Copy, InitSpace, PartialEq, Eq, Debug)]
pub enum PlanKind {
    Inheritance,
    Vesting,
}

/// One beneficiary's vesting schedule: `total` of `mint` (None = SOL) vests
/// linearly from `start_at` over `duration_secs`; nothing is claimable
/// before `cliff_secs` have passed.
#[derive(AnchorSerialize, AnchorDeserialize, Clone, Copy, InitSpace, PartialEq, Eq, Debug)]
pub struct VestingInput {
    pub beneficiary: Pubkey,
    pub rail: Rail,
    pub mint: Option<Pubkey>,
    pub total: u64,
    pub cliff_secs: i64,
    pub duration_secs: i64,
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
    /// When later tiers were allowed to run past this one because it could
    /// not pay within the grace period; 0 if never skipped. A skipped tier
    /// stays claimable by its own beneficiary.
    pub skipped_at: i64,
    /// Share set aside for a skipped tier, so skipping never moves value to
    /// later tiers. 0 = recompute from the balance when claimed.
    pub reserved: u64,
    /// Vesting only: seconds from the plan start to fully vested (the cliff
    /// is `after_secs`, the total is `amount`). 0 for inheritance tiers.
    pub duration_secs: i64,
    /// Vesting only: gross amount released so far.
    pub released: u64,
}

#[account]
#[derive(InitSpace)]
pub struct Vault {
    pub owner: Pubkey,
    /// Owner-chosen id; one owner can hold many independent plans.
    pub plan_id: u16,
    /// Device key: may only pulse and lock down, never move funds.
    pub guard: Pubkey,
    /// Trusted contact: may lock down (rate-limited) and co-sign early unlock.
    pub guardian: Option<Pubkey>,
    /// Check-in cadence; drives reminders and the minimum rule delay.
    pub interval_secs: i64,
    pub lock_secs: i64,
    /// Owner-chosen time a due tier gets to pay before anyone may skip it.
    pub skip_grace_secs: i64,
    pub last_pulse: i64,
    /// Last wallet-signed (owner) action; bounds guard-only check-ins.
    pub owner_last_seen: i64,
    pub locked_until: i64,
    /// Earliest time the guardian may lock down again.
    pub guardian_ready_at: i64,
    pub total_pulses: u64,
    pub streak: u32,
    pub best_streak: u32,
    pub kind: PlanKind,
    /// Vesting: when every schedule starts vesting.
    pub start_at: i64,
    /// Vesting: the owner may stop future vesting (already vested stays).
    pub revocable: bool,
    /// Vesting: when it was revoked; 0 if never.
    pub revoked_at: i64,
    /// Who funded the account rent (the owner, or a fee sponsor). Closing
    /// the plan returns the rent to them, never to someone else.
    pub rent_payer: Pubkey,
    #[max_len(MAX_RULES)]
    pub rules: Vec<Rule>,
    /// Display name, e.g. "Kids" or "Emergency fund".
    #[max_len(MAX_LABEL_LEN)]
    pub label: String,
    pub bump: u8,
}

impl Vault {
    pub fn require_kind(&self, kind: PlanKind) -> Result<()> {
        require!(self.kind == kind, DeadmanError::WrongPlanKind);
        Ok(())
    }

    /// Gross amount of rule `index` vested at `now` (stops at revocation).
    pub fn vested(&self, index: usize, now: i64) -> Result<u64> {
        let rule = &self.rules[index];
        let end = if self.revoked_at != 0 {
            now.min(self.revoked_at)
        } else {
            now
        };
        let elapsed = end.saturating_sub(self.start_at);
        if elapsed < rule.after_secs {
            return Ok(0);
        }
        if elapsed >= rule.duration_secs {
            return Ok(rule.amount);
        }
        let v = u128::from(rule.amount)
            .checked_mul(u128::try_from(elapsed).map_err(|_| DeadmanError::MathOverflow)?)
            .and_then(|v| v.checked_div(u128::try_from(rule.duration_secs).ok()?))
            .ok_or(DeadmanError::MathOverflow)?;
        u64::try_from(v).map_err(|_| error!(DeadmanError::MathOverflow))
    }

    /// Most rule `index` can ever release: the total, or what had vested
    /// when the plan was revoked.
    pub fn vesting_cap(&self, index: usize) -> Result<u64> {
        if self.revoked_at != 0 {
            self.vested(index, self.revoked_at)
        } else {
            Ok(self.rules[index].amount)
        }
    }

    /// Amount of `mint` the owner may not withdraw: what vesting
    /// beneficiaries are still owed. Always 0 for inheritance plans.
    pub fn committed(&self, mint: Option<Pubkey>) -> Result<u64> {
        if self.kind != PlanKind::Vesting {
            return Ok(0);
        }
        let mut total: u64 = 0;
        for (i, r) in self.rules.iter().enumerate() {
            if r.mint == mint {
                let owed = self.vesting_cap(i)?.saturating_sub(r.released);
                total = total.checked_add(owed).ok_or(DeadmanError::MathOverflow)?;
            }
        }
        Ok(total)
    }

    /// Validates and installs vesting schedules. Caller enforces auth.
    pub fn apply_vesting(
        &mut self,
        vault: &Pubkey,
        now: i64,
        start_at: i64,
        schedules: &[VestingInput],
    ) -> Result<()> {
        require!(
            !schedules.is_empty() && schedules.len() <= MAX_RULES,
            DeadmanError::InvalidVesting
        );
        let earliest = now
            .checked_sub(MAX_VEST_START_SKEW_SECS)
            .ok_or(DeadmanError::MathOverflow)?;
        let latest = now
            .checked_add(MAX_VEST_START_SKEW_SECS)
            .ok_or(DeadmanError::MathOverflow)?;
        require!(
            (earliest..=latest).contains(&start_at),
            DeadmanError::InvalidVesting
        );
        for v in schedules {
            require!(
                v.total > 0
                    && v.cliff_secs >= 0
                    && v.duration_secs > 0
                    && v.cliff_secs <= v.duration_secs
                    && v.duration_secs <= MAX_VEST_SECS
                    && v.beneficiary != Pubkey::default()
                    && v.beneficiary != self.owner
                    && v.beneficiary != self.guard
                    && v.beneficiary != *vault
                    && v.mint != Some(Pubkey::default()),
                DeadmanError::InvalidVesting
            );
        }
        self.start_at = start_at;
        self.rules = schedules
            .iter()
            .map(|v| Rule {
                beneficiary: v.beneficiary,
                rail: v.rail,
                after_secs: v.cliff_secs,
                mint: v.mint,
                mode: AmountMode::Fixed,
                amount: v.total,
                executed_at: 0,
                paid: 0,
                skipped_at: 0,
                reserved: 0,
                duration_secs: v.duration_secs,
                released: 0,
            })
            .collect();
        Ok(())
    }

    pub fn is_locked(&self, now: i64) -> bool {
        now < self.locked_until
    }

    /// Every tier has released.
    pub fn is_completed(&self) -> bool {
        self.rules.iter().all(|r| r.executed_at != 0)
    }

    pub fn set_label(&mut self, label: String) -> Result<()> {
        require!(label.len() <= MAX_LABEL_LEN, DeadmanError::LabelTooLong);
        self.label = label;
        Ok(())
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

    /// A wallet-signed check-in: also restarts the guard-only window.
    pub fn record_owner_pulse(&mut self, now: i64) -> Result<()> {
        self.owner_last_seen = now;
        self.record_pulse(now)
    }

    /// A guard key may keep the plan alive only within a year of the owner's
    /// last wallet action, and never after a tier released or was skipped
    /// without the owner confirming since: only the owner can stop later
    /// tiers.
    pub fn check_guard_pulse(&self, now: i64) -> Result<()> {
        let window_end = self
            .owner_last_seen
            .checked_add(MAX_GUARD_ONLY_SECS)
            .ok_or(DeadmanError::MathOverflow)?;
        require!(
            now <= window_end
                && !self.rules.iter().any(|r| {
                    r.executed_at > self.owner_last_seen || r.skipped_at > self.owner_last_seen
                }),
            DeadmanError::OwnerConfirmationRequired
        );
        Ok(())
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

    /// Earlier tiers of `mint` before `index` have all paid or been skipped.
    fn earlier_settled(&self, index: usize, mint: Option<Pubkey>) -> bool {
        self.rules[..index]
            .iter()
            .all(|r| r.mint != mint || r.executed_at != 0 || r.skipped_at != 0)
    }

    /// Sum of shares set aside for skipped, still unpaid tiers of `mint`,
    /// excluding tier `except`.
    pub fn reserved_for(&self, mint: Option<Pubkey>, except: usize) -> Result<u64> {
        self.rules
            .iter()
            .enumerate()
            .filter(|(i, r)| {
                *i != except && r.mint == mint && r.executed_at == 0 && r.skipped_at != 0
            })
            .try_fold(0u64, |acc, (_, r)| acc.checked_add(r.reserved))
            .ok_or_else(|| error!(DeadmanError::MathOverflow))
    }

    /// Gross payout for tier `index` given the vault's whole balance of its
    /// asset: a skipped tier gets its reserved share; any other tier works
    /// on the balance minus every reserved share.
    pub fn payout_gross(&self, index: usize, balance: u64) -> Result<u64> {
        let rule = &self.rules[index];
        if rule.skipped_at != 0 && rule.reserved > 0 {
            return Ok(rule.reserved.min(balance));
        }
        let available = balance.saturating_sub(self.reserved_for(rule.mint, index)?);
        rule_gross(rule, available)
    }

    /// Checks that rule `index` may execute now for `mint`, enforcing the
    /// per-asset order so percentages apply to a deterministic balance. A
    /// skipped tier was already due and in order, so it can be claimed at
    /// any time afterwards.
    pub fn check_executable(&self, index: usize, mint: Option<Pubkey>, now: i64) -> Result<()> {
        require!(index < self.rules.len(), DeadmanError::InvalidRuleIndex);
        let rule = &self.rules[index];
        require!(rule.mint == mint, DeadmanError::WrongAsset);
        require!(rule.executed_at == 0, DeadmanError::RuleAlreadyExecuted);
        if rule.skipped_at == 0 {
            require!(now > self.rule_due_at(index)?, DeadmanError::RuleNotDue);
            require!(
                self.earlier_settled(index, mint),
                DeadmanError::RuleOutOfOrder
            );
        }
        Ok(())
    }

    /// Rule `index` is pending, next for its asset, and has been due for
    /// longer than the skip grace period.
    pub fn check_skippable(&self, index: usize, now: i64) -> Result<()> {
        require!(index < self.rules.len(), DeadmanError::InvalidRuleIndex);
        let mint = self.rules[index].mint;
        require!(
            self.rules[index].executed_at == 0 && self.rules[index].skipped_at == 0,
            DeadmanError::RuleAlreadyExecuted
        );
        require!(
            self.earlier_settled(index, mint),
            DeadmanError::RuleOutOfOrder
        );
        let skippable_at = self
            .rule_due_at(index)?
            .checked_add(self.skip_grace_secs)
            .ok_or(DeadmanError::MathOverflow)?;
        require!(now > skippable_at, DeadmanError::SkipTooEarly);
        Ok(())
    }

    /// Validates and installs the policy. Caller enforces auth.
    ///
    /// Tiers that already released stay in place as history (they can never
    /// pay again) and `rules` becomes the new pending tiers after them. Once
    /// every tier has released the plan starts over with only `rules`.
    pub fn apply_policy(
        &mut self,
        vault: &Pubkey,
        interval_secs: i64,
        lock_secs: i64,
        skip_grace_secs: i64,
        rules: &[RuleInput],
        guardian: Option<Pubkey>,
    ) -> Result<()> {
        require!(
            (MIN_INTERVAL_SECS..=MAX_INTERVAL_SECS).contains(&interval_secs)
                && (MIN_LOCK_SECS..=MAX_LOCK_SECS).contains(&lock_secs)
                && (MIN_SKIP_GRACE_SECS..=MAX_SKIP_GRACE_SECS).contains(&skip_grace_secs),
            DeadmanError::InvalidDuration
        );
        let history: Vec<Rule> = if self.is_completed() {
            Vec::new()
        } else {
            self.rules
                .iter()
                .filter(|r| r.executed_at != 0 || r.skipped_at != 0)
                .copied()
                .collect()
        };
        let total = history
            .len()
            .checked_add(rules.len())
            .ok_or(DeadmanError::MathOverflow)?;
        require!(
            !rules.is_empty() && total <= MAX_RULES,
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
                    && r.beneficiary != *vault
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
        self.skip_grace_secs = skip_grace_secs;
        self.guardian = guardian;
        self.rules = history;
        self.rules.extend(rules.iter().map(|r| Rule {
            beneficiary: r.beneficiary,
            rail: r.rail,
            after_secs: r.after_secs,
            mint: r.mint,
            mode: r.mode,
            amount: r.amount,
            executed_at: 0,
            paid: 0,
            skipped_at: 0,
            reserved: 0,
            duration_secs: 0,
            released: 0,
        }));
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
