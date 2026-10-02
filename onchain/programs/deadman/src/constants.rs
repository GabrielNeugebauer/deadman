pub const CONFIG_SEED: &[u8] = b"config";
pub const VAULT_SEED: &[u8] = b"vault";

pub const MAX_RULES: usize = 8;
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
pub const MIN_LOCK_SECS: i64 = 60;
pub const MAX_LOCK_SECS: i64 = 30 * SECS_PER_DAY;

/// SOL sent along with token payouts on private rails so a fresh claim key
/// can pay the fees to route its funds onward.
pub const PRIVATE_GAS_STIPEND: u64 = 3_000_000;
