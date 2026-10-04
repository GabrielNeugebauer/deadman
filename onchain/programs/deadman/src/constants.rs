pub const CONFIG_SEED: &[u8] = b"config";
pub const VAULT_SEED: &[u8] = b"vault";

pub const MAX_RULES: usize = 8;
/// Plan label length in bytes.
pub const MAX_LABEL_LEN: usize = 32;
pub const BPS_DENOMINATOR: u64 = 10_000;
/// Hard cap on the payout fee for any rail: 5%.
pub const MAX_FEE_BPS: u16 = 500;

pub const SECS_PER_DAY: i64 = 86_400;

/// One minute minimum so the switch can be demoed live.
pub const MIN_INTERVAL_SECS: i64 = 60;
pub const MAX_INTERVAL_SECS: i64 = 366 * SECS_PER_DAY;
/// A rule may only fire at least this long after a missed check-in.
pub const MIN_RULE_MARGIN_SECS: i64 = 60;
pub const MAX_RULE_DELAY_SECS: i64 = 3 * 366 * SECS_PER_DAY;
/// Bounds for the owner-chosen skip grace: a due tier that still cannot pay
/// that long after it fell due may be skipped by anyone, so one broken
/// destination cannot block later tiers forever.
pub const MIN_SKIP_GRACE_SECS: i64 = 60;
pub const MAX_SKIP_GRACE_SECS: i64 = 366 * SECS_PER_DAY;
/// Guard-key check-ins keep a plan alive for at most this long after the
/// owner's last wallet-signed action.
pub const MAX_GUARD_ONLY_SECS: i64 = 365 * SECS_PER_DAY;
pub const MIN_LOCK_SECS: i64 = 60;
pub const MAX_LOCK_SECS: i64 = 30 * SECS_PER_DAY;

/// Vesting schedules: up to this long from start to fully vested, and a
/// start at most this far in the past or future of creation.
pub const MAX_VEST_SECS: i64 = 20 * 366 * SECS_PER_DAY;
pub const MAX_VEST_START_SKEW_SECS: i64 = 366 * SECS_PER_DAY;

/// SOL sent along with token payouts on private rails so a fresh claim key
/// can pay the fees to route its funds onward.
pub const PRIVATE_GAS_STIPEND: u64 = 3_000_000;
