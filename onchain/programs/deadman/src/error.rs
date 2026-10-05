use anchor_lang::prelude::*;

#[error_code]
pub enum DeadmanError {
    #[msg("Signer is not allowed to perform this action")]
    Unauthorized,
    #[msg("Fee exceeds the 5% cap")]
    FeeTooHigh,
    #[msg("Interval or lock duration out of range")]
    InvalidDuration,
    #[msg("Rules must be 1-8, sorted by delay, with valid amounts and beneficiaries")]
    InvalidRules,
    #[msg("Guardian cannot be the owner, the guard key or a beneficiary")]
    InvalidGuardian,
    #[msg("Guard key must differ from the owner, beneficiaries and guardian")]
    InvalidGuard,
    #[msg("Vault is locked down")]
    VaultLocked,
    #[msg("The owner is still within this rule's inactivity window")]
    RuleNotDue,
    #[msg("Rule already executed")]
    RuleAlreadyExecuted,
    #[msg("An earlier rule for the same asset must execute first")]
    RuleOutOfOrder,
    #[msg("Rule asset does not match this instruction or mint")]
    WrongAsset,
    #[msg("Rule index out of range")]
    InvalidRuleIndex,
    #[msg("Amount exceeds the withdrawable balance")]
    InsufficientFunds,
    #[msg("Vault has no guardian")]
    NoGuardian,
    #[msg("Guardian lockdown is cooling down")]
    GuardianCooldown,
    #[msg("Every tier of this plan has released; check-ins are closed")]
    PlanCompleted,
    #[msg("Plan label is too long")]
    LabelTooLong,
    #[msg("The owner's wallet must confirm before the guard key can check in again")]
    OwnerConfirmationRequired,
    #[msg("Nothing to pay for this tier yet")]
    NothingToPay,
    #[msg("Beneficiary account cannot receive this amount")]
    BeneficiaryCannotReceive,
    #[msg("This tier can only be skipped once the plan's grace period has passed")]
    SkipTooEarly,
    #[msg("This instruction does not apply to this kind of plan")]
    WrongPlanKind,
    #[msg("Vesting schedules need a total, a cliff no longer than the duration, a duration up to 20 years, and an installment period of 0 or 60s up to the shortest duration")]
    InvalidVesting,
    #[msg("This vesting plan cannot be revoked")]
    NotRevocable,
    #[msg("Vesting was already revoked")]
    AlreadyRevoked,
    #[msg("Those funds are committed to vesting beneficiaries")]
    FundsCommitted,
    #[msg("Treasury must be set")]
    InvalidConfig,
    #[msg("Arithmetic overflow")]
    MathOverflow,
    #[msg("Not a plan account in an older layout")]
    NotLegacyVault,
    #[msg("Subscriptions are disabled")]
    SubscriptionDisabled,
    #[msg("Invalid subscription parameters or accounts")]
    InvalidSubscription,
}
