# Deadman security review (2026-10-04)

Scope: code added since `docs/security-audit-2026-10-03.md`, reviewed read-only.

- On-chain vesting and rent refund: `state.rs` (`PlanKind`, `vested`, `vesting_cap`, `committed`, `apply_vesting`), `instructions/vault.rs` (`create_vesting`, `revoke_vesting`, `close_vault` with `rent_payer`), `instructions/funds.rs` (`release_vested_sol/token`, committed checks in `withdraw_*`).
- Paymaster gateway: `tool/kora_gateway.dart` (`validatePaymasterTx`, `PaymasterRoute`, tiers), `kora/paymaster.toml`, `scripts/kora_start.sh` (`render_tier`).
- Client: `lib/solana/deadman_client.dart` (`_buildPaid`, `_withoutExistingKoraAtas`, vesting builders).

## Summary

| Severity | Count |
| -------- | ----- |
| Critical | 0     |
| High     | 0     |
| Medium   | 3     |
| Low      | 5     |
| Info     | 7     |

The on-chain vesting logic holds up. Account validation, PDAs, kind separation, checked math, the committed-funds accounting and the close/revoke lifecycle are correct, and no path lets an owner, executor or beneficiary take value they are not owed. All three Medium findings are in the off-chain paymaster: Kora's SOL can be bought below cost through the account tier, the shared quotas can be burned for free, and the client trusts the server's fee amount and destination.

---

## M-1 [Medium] Account tier sells Kora-funded ATAs for any wallet and any mint; the buyer closes them and keeps the rent (CONFIRMED)

- **Where:** `tool/kora_gateway.dart:603-625` (ATA branch), `:1000` (only vault creates have a separate quota). `scripts/kora_start.sh:62` (account tier 1.00 USDC, cap 4,150,000 lamports).
- **Issue:** The gateway checks only that Kora is the payer (slot 0) and not in another slot. The ATA's `wallet` and `mint` are not restricted. Kora pays 2,039,280 lamports for each SPL ATA. The wallet owner can close the empty ATA at any time and send the rent anywhere.
- **Exploit:**
  1. Send `[ata.create_idempotent(payer=Kora, wallet=attacker, mint=A), ata.create_idempotent(payer=Kora, wallet=attacker, mint=B), transfer_checked(1 USDC -> Kora)]`. The gateway routes it to the account tier. Kora allows it: `allow_create_account = true`, and the outflow of 4,078,560 lamports is under 4,150,000.
  2. In a separate self-paid transaction, `CloseAccount` both ATAs to the attacker. Net per cycle: −1 USDC, +0.00408 SOL.
  3. This profits whenever SOL is above about $245. On devnet the Circle faucet gives USDC for free, so the drain costs nothing.
  4. With Sybil owners (fresh keypairs), the only bound is `PAYMASTER_GLOBAL` = 2000 per 24 h, about 8.2 SOL per day. Draining also uses up that global quota (see M-2).
- **PoC:** A scratch script built that transaction (two Kora-paid ATAs on the attacker's own wallet, one of them for an arbitrary mint, plus a 1 USDC payment). `validatePaymasterTx` returned `ACCEPTED tier=account koraAtas=2`.
- **Fix:** Any of these, ideally combined:
  - Price the account tier from live rent and a conservative SOL price, or use Kora margin pricing that includes outflow (as planned for mainnet).
  - Only fund ATAs that the rest of the transaction needs: wallet equals the vault PDA of a Deadman instruction in the same transaction, the beneficiary of a `release_vested_token`/`execute_token_rule` in it, or `config.treasury`, and mint equals that instruction's mint.
  - Add a per-owner and global quota for Kora-funded ATAs, as `creates` does for vaults.

## M-2 [Medium] Paymaster quotas are spent before Kora checks the payment, so unfunded wallets can block the paymaster for everyone at zero cost (CONFIRMED)

- **Where:** `tool/kora_gateway.dart:996-1001` (`PaymasterRoute.admit`). `validatePaymasterTx` and the owner-signature check are pure. Nothing checks that the payment can succeed before `creates.acquire` and `limiter.acquire` record the transaction. Kora rejects it later in simulation, and the slot is never given back.
- **Exploit:**
  1. Make 20 fresh keypairs (no SOL, no USDC, no ATA).
  2. Each signs `create_vault(payer=Kora) + transfer_checked(3 USDC from its non-existent ATA -> Kora)`.
  3. All 20 pass `admit` and fill `PAYMASTER_CREATES_GLOBAL` = 20. No Kora-funded plan can be created by anyone for 24 h.
  4. The same works with 2000 basic-shaped transactions against `PAYMASTER_GLOBAL`, about 34 minutes from one IP at 60 per minute. That blocks every paid transaction, which strands the users the paymaster exists for (wallets without SOL).
  5. Repeat daily for free.
- **PoC:** A scratch script ran 20 such creates from empty wallets: all were admitted. The 21st got `Rate limit: ... reached its cap of 20`.
- **Fix:**
  - Call `check()` at admit, but `acquire()` only after the upstream `signAndSendTransaction` returns a signature.
  - Alternatively, before acquiring, fetch the payment source account and require `amount >= payment`, owner = signer and mint = the payment mint.
  - Keep a separate, cheap per-IP counter for rejected transactions.

## M-3 [Medium] Client signs a USDC payment whose amount and destination come from the paymaster's response, with no cap or pinning, over plain HTTP (CONFIRMED by code reading)

- **Where:** `lib/solana/deadman_client.dart:1283` (fee payer from `getPayerSigner`), `:1296` (`fee = estimate.feeInToken`, only `< 0` is rejected), `:1326` (`destination: ataAddress(estimate.paymentAddress, token)`). `docs/KORA.md:26` and `README.md:218` configure `KORA_PAYMASTER_URL=http://<LAN>:8081`.
- **Exploit:**
  1. Anyone on the network path (public Wi‑Fi at the event, or a compromised gateway) rewrites the `estimateTransactionFee` response: `fee_in_token` = the user's whole USDC balance (the client only checks `held >= needed`), and `payment_address` = the attacker.
  2. They can also rewrite `getPayerSigner` so that the attacker's own key is the fee payer, which can then sign and land the transaction.
  3. The user sees a normal action (for example "check in") and approves it in the wallet. One signature moves all their USDC to the attacker. Wallet simulation is the only defence.
- **Fix:**
  - Pin the paymaster signer and payment address in `AppConfig` (or check them against a pinned value), and reject anything else.
  - Cap `fee` at the known tier price for what the transaction funds (≤ 3 USDC today), or at a configured maximum, and show the fee in the app before signing.
  - Require `https` for `KORA_PAYMASTER_URL` outside debug builds.

---

## L-1 [Low] Vault layout changed without migration; existing devnet vaults become unreadable after the upgrade

- **Where:** `state.rs:132-141` adds `kind`, `start_at`, `revocable`, `revoked_at` and `rent_payer` before `rules`. `Rule` gains `duration_secs` and `released`. The program ID is unchanged (`lib.rs:13`).
- **Issue:** `getProgramAccounts` on devnet shows 4 vaults at the old sizes (958, 996 ×2 and 1140 bytes; the new size is 1318). Two of them hold about 0.1 SOL each. Once the new binary is deployed, `Account<Vault>` fails to deserialize them, so their owners cannot withdraw, close or update.
- **Fix:**
  - Close or drain them with the old binary before upgrading.
  - Or add a one-off `migrate_vault` (realloc to the new size, `kind = Inheritance`, `rent_payer = owner`, zeroed vesting fields).
  - For mainnet, add a version byte and reserved padding.

## L-2 [Low] Rent is recomputed from the current Rent sysvar, so a future rent reduction lets the owner withdraw part of the sponsor's rent

- **Where:** `funds.rs:15-18` (`withdrawable_lamports`), `vault.rs:283-288` (`close_vault` excess to the owner).
- **Issue:** Kora's deposit is `minimum_balance(1318)` at creation time. If lamports-per-byte is lowered (rent-reduction proposals exist), the difference becomes "withdrawable": `withdraw_sol` or the `close_vault` excess sends it to the owner, and Kora gets back only the new, smaller minimum.
- **Fix:** Store `rent_paid: u64` at creation. Exclude it from `withdrawable_lamports` and return exactly `min(lamports, rent_paid)` to `rent_payer` on close.

## L-3 [Low] Underfunded vesting plans pay on a first-come basis, in an order any executor can choose

- **Where:** `funds.rs:437` and `:501` (`gross = due.min(balance)`), `vault.rs:296-336` (no funding requirement).
- **Issue:** `create_vesting` does not require the schedules to be funded. When the balance of a mint is below what is owed, whoever calls `release_vested_*` first takes their full vested amount. The release is permissionless, so the keeper or another beneficiary can drain it towards one schedule. The owner cannot withdraw either way (`committed > balance`), so this is a fairness and trust issue, not theft.
- **Fix:**
  - Show funded/owed coverage in the UI and keeper, and warn beneficiaries about plans that are not fully funded.
  - Optionally, when underfunded, release pro-rata: `due * balance / committed(mint)`.

## L-4 [Low] The vesting guarantee does not hold for mints the owner controls (freeze authority or Token-2022 permanent delegate)

- **Where:** `state.rs:226-240` accepts any mint, and `release_vested_token` and `withdraw_token` accept Token-2022.
- **Issue:** An owner who is a mint's permanent delegate can pull "committed" tokens out of the vault ATA. A freeze authority can freeze the vault ATA, which blocks every release. The app rejects Token-2022 mints (`_mintDecimals`), but a custom client can create such a plan, and the app would then show it to the beneficiary as committed.
- **Fix:** Reject Token-2022 mints with `PermanentDelegate` in `create_vesting`, or have the app flag vesting plans whose mint has a permanent delegate or a non-issuer freeze authority.

## L-5 [Low] A paid transaction that fails after Kora's simulation costs Kora the fee and pays nothing (PLAUSIBLE)

- **Where:** `tool/kora_gateway.dart:1201-1230`, `kora/paymaster.toml`.
- **Issue:** The USDC payment is in the same transaction. If an attacker empties their USDC ATA, or races any state the transaction depends on, between Kora's simulation and landing, the transaction fails on-chain. Kora still pays up to 50,000 lamports in fees, and the payment reverts. That is about 10:1 griefing per attempt, bounded by the quotas (≤ 0.1 SOL per day at 2000 per day).
- **Fix:** Accept as a known cost, or ban owners whose paid transactions fail on-chain (track the signature result).

---

## Info

- **Release fee rounding:** `split_fee` floors, so the protocol loses less than 1 base unit per release. A beneficiary could avoid the fee entirely only with releases smaller than `10_000 / fee_bps` units, which costs far more in transaction fees than it saves.
- **Vesting plans cannot have a guardian:** `update_policy` is Inheritance-only, so `unlock` is impossible. A guard lockdown (not rate-limited) blocks `revoke_vesting` and `withdraw` for up to `lock_secs` and can be repeated. `set_guard`, which works during lockdown, is the remedy. Releases are not blocked by lockdown, which is correct.
- **Events:** vesting releases emit `RuleExecuted`. Indexers can no longer treat that event as "tier finished".
- **Kora-funded vault ATAs:** `close_vault` leaves token accounts behind (prior L-6), so Kora never recovers the rent of vault ATAs it funded. This is priced into the tiers.
- **Token-2022 ATAs in the account tier:** `max_allowed_lamports = 4,150,000` in the account tier rejects two Token-2022 ATAs (2 × 2,074,080 + fee). This is a functional limit only.
- **Keeper:** `_lastRelease` is held in memory, so after a restart the keeper releases every due schedule once immediately. This is harmless.
- **Client:** `_withoutExistingKoraAtas` has a race (an ATA is created between the check and landing). It only makes the transaction fail Kora simulation, at no cost to anyone.

## Needs verification

1. Whether the new program build is already deployed to devnet. If so, the 4 old-layout vaults (L-1) are already unreadable.
2. Whether Kora's `sign_and_send_transaction` uses preflight, which affects how easy L-5 is to trigger.
3. That the mainnet paymaster's margin pricing includes the fee payer's outflow (ATA and vault rent) in the price, which would close M-1 for mainnet.

## Checked and clean

- **Kind separation:** `execute_*`, `skip_rule`, `pulse` and `update_policy` require Inheritance. `release_vested_*` and `revoke_vesting` require Vesting.
- **`release_vested_*`:**
  - Checks index bounds, mint match, `executed_at == 0`, that the beneficiary equals `rule.beneficiary`, and the canonical ATA or a beneficiary signature.
  - Treasury is pinned by `address`, and config and vault by PDA seeds and stored bump.
  - Gross is capped at `vested − released` and at the balance. Rent is excluded for SOL.
- **`vested`:** u128 math with checked mul/div. A negative `elapsed` (start in the future) returns 0 before the u128 cast. The cliff is checked before the end, and `cliff ≤ duration`, `duration > 0` and `duration ≤ 20y` are validated.
- **Revoke:** `vested` is monotonic and every release happens at or before `revoked_at`, so `released ≤ vesting_cap` always holds after a revoke. Revoke followed by withdraw frees exactly `amount − vested(revoked_at)`.
- **Committed funds:**
  - `committed()` covers both SOL and tokens.
  - `withdraw_sol` and `withdraw_token` refuse to dip into committed funds.
  - `pay_stipend` uses only uncommitted SOL.
  - `close_vault` refuses while any schedule is owed.
  - Multiple releases accumulate `released` and `paid` with checked add, and set `executed_at` once the cap is reached.
- **`close_vault`:**
  - `has_one = rent_payer` plus `close = rent_payer`: rent goes only to the stored payer and the excess to the owner.
  - `owner == rent_payer` (duplicate writable account) works; this is tested.
  - A vault that is closed and recreated is a fresh `init`.
- **Gateway transaction shape:**
  - Distinct keys and no lookup tables.
  - Exactly two signatures (Kora and the owner).
  - Kora is allowed only as ATA payer, `create_vault`/`create_vesting` payer (at most one per transaction) or `close_vault` `rent_payer`.
  - Kora is never a token authority or account, never a System transfer source or destination, and never in Token-2022 hook extra-account slots.
  - The last instruction must be the payment, checked against the tier price.
- **Kora as a second line of defence:** Kora 2.0.5 simulates and validates inner instructions (`fetch_inner_instructions`), so CPI `create_account` from Anchor `init` or the ATA program is checked against `fee_payer_policy` and `max_allowed_lamports`. Each tier's node caps outflow independently: basic does not allow `create_account`, account is capped below a vault's rent, and plan allows ≤ 1 vault + 2 ATAs + fee. Misrouting cannot make Kora fund more than its tier.

## Tests run

`cd onchain && cargo test`: unit 1 passed, integration `test_deadman.rs` 42 passed, 0 failed. Two scratch PoCs (outside the repo) confirmed M-1 and M-2 against `validatePaymasterTx` and `PaymasterRoute.admit`.

## Verdict

**The on-chain vesting and rent-refund code is ready.** No Critical or High findings. Before the paymaster is exposed publicly, fix the three Medium findings in the paymaster path:

- **M-2:** acquire quota only after Kora succeeds.
- **M-1:** restrict which ATAs Kora funds, or price them from outflow.
- **M-3:** pin the payment address and cap the fee in the client.

Resolve L-1 (migrate or drain old vaults) before upgrading the devnet program.
