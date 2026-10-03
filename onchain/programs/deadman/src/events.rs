use anchor_lang::prelude::*;

use crate::state::Rail;

#[event]
pub struct VaultCreated {
    pub vault: Pubkey,
    pub owner: Pubkey,
    pub plan_id: u16,
    pub rules: u8,
}

#[event]
pub struct PolicyUpdated {
    pub vault: Pubkey,
    pub rules: u8,
}

#[event]
pub struct Pulsed {
    pub vault: Pubkey,
    pub by: Pubkey,
    pub streak: u32,
    pub at: i64,
}

#[event]
pub struct LockedDown {
    pub vault: Pubkey,
    pub by: Pubkey,
    pub until: i64,
}

#[event]
pub struct Unlocked {
    pub vault: Pubkey,
    pub at: i64,
}

#[event]
pub struct RuleExecuted {
    pub vault: Pubkey,
    pub index: u8,
    pub beneficiary: Pubkey,
    pub rail: Rail,
    pub mint: Option<Pubkey>,
    pub amount: u64,
    pub fee: u64,
    pub by: Pubkey,
}
