use anchor_lang::prelude::*;

#[event]
pub struct VaultCreated {
    pub vault: Pubkey,
    pub owner: Pubkey,
    pub deadline: i64,
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
pub struct Triggered {
    pub vault: Pubkey,
    pub by: Pubkey,
    pub sol_at_trigger: u64,
    pub at: i64,
}

#[event]
pub struct Claimed {
    pub vault: Pubkey,
    pub heir: Pubkey,
    pub mint: Option<Pubkey>,
    pub amount: u64,
    pub fee: u64,
}

#[event]
pub struct Subscribed {
    pub vault: Pubkey,
    pub months: u8,
    pub plus_until: i64,
}
