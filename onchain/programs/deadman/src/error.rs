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
    #[msg("Treasury must be set")]
    InvalidConfig,
    #[msg("Arithmetic overflow")]
    MathOverflow,
}
