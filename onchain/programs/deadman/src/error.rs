use anchor_lang::prelude::*;

#[error_code]
pub enum DeadmanError {
    #[msg("Signer is not allowed to perform this action")]
    Unauthorized,
    #[msg("Fee exceeds the 1% cap")]
    FeeTooHigh,
    #[msg("Interval, grace or lock duration out of range")]
    InvalidDuration,
    #[msg("Heirs must be unique, non-empty and sum to 10000 bps")]
    InvalidHeirs,
    #[msg("Too many heirs for this plan")]
    TooManyHeirs,
    #[msg("A guardian requires Deadman Plus")]
    PlusRequired,
    #[msg("Guardian cannot be the owner, the guard key or an heir")]
    InvalidGuardian,
    #[msg("Vault is locked down")]
    VaultLocked,
    #[msg("Vault is not active")]
    VaultNotActive,
    #[msg("Vault has not been triggered")]
    VaultNotTriggered,
    #[msg("The owner is still within the heartbeat window")]
    StillAlive,
    #[msg("Signer is not an heir of this vault")]
    NotAnHeir,
    #[msg("Share already claimed")]
    AlreadyClaimed,
    #[msg("Amount exceeds the withdrawable balance")]
    InsufficientFunds,
    #[msg("Subscription months out of range")]
    InvalidMonths,
    #[msg("Guard key must differ from the owner, heirs and guardian")]
    InvalidGuard,
    #[msg("Vault has no guardian")]
    NoGuardian,
    #[msg("Arithmetic overflow")]
    MathOverflow,
    #[msg("Treasury and SKR mint must be set")]
    InvalidConfig,
}
