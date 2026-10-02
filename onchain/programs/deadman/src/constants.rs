pub const CONFIG_SEED: &[u8] = b"config";
pub const VAULT_SEED: &[u8] = b"vault";
pub const CLAIM_SEED: &[u8] = b"claim";

pub const MAX_HEIRS: usize = 4;
pub const FREE_MAX_HEIRS: usize = 1;

pub const BPS_DENOMINATOR: u64 = 10_000;
/// Hard cap on the inheritance success fee: 1%.
pub const MAX_FEE_BPS: u16 = 100;

pub const SECS_PER_DAY: i64 = 86_400;
pub const SECS_PER_MONTH: i64 = 30 * SECS_PER_DAY;

/// One minute minimum so the switch can be demoed live.
pub const MIN_INTERVAL_SECS: i64 = 60;
pub const MAX_INTERVAL_SECS: i64 = 366 * SECS_PER_DAY;
pub const MIN_GRACE_SECS: i64 = 60;
pub const MAX_GRACE_SECS: i64 = 90 * SECS_PER_DAY;
pub const MIN_LOCK_SECS: i64 = 60;
pub const MAX_LOCK_SECS: i64 = 30 * SECS_PER_DAY;

pub const MAX_SUBSCRIBE_MONTHS: u8 = 12;
