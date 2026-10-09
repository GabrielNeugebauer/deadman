use trident_fuzz::fuzzing::*;

/// Storage for all account addresses used in fuzz testing.
///
/// This struct serves as a centralized repository for account addresses,
/// enabling their reuse across different instruction flows and test scenarios.
///
/// Docs: https://ackee.xyz/trident/docs/latest/trident-api-macro/trident-types/fuzz-accounts/
#[derive(Default)]
pub struct AccountAddresses {
    pub owner: AddressStorage,

    pub vault: AddressStorage,

    pub rent_payer: AddressStorage,

    pub payer: AddressStorage,

    pub system_program: AddressStorage,

    pub executor: AddressStorage,

    pub config: AddressStorage,

    pub beneficiary: AddressStorage,

    pub treasury: AddressStorage,

    pub mint: AddressStorage,

    pub vault_token: AddressStorage,

    pub beneficiary_token: AddressStorage,

    pub treasury_token: AddressStorage,

    pub token_program: AddressStorage,

    pub admin: AddressStorage,

    pub program: AddressStorage,

    pub program_data: AddressStorage,

    pub signer: AddressStorage,

    pub legacy: AddressStorage,

    pub caller: AddressStorage,

    pub owner_token: AddressStorage,

    pub guardian: AddressStorage,
}
