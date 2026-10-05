# Deadman security audit (2026-10-05)

Scope: the whole repository at the working tree of `feat/safety-net-mvp-02-10-2026`.

- **On-chain:** the Anchor program `onchain/programs/deadman` (program id `ACHVLMoLDM3YPpGbNST4cZW4Tf2jx6nzJGuusyLJHofL`, Anchor 1.1.2, 21 instructions).
- **Off-chain:** `lib/solana`, `lib/kora`, `lib/rails`, `lib/wallet`, `lib/state`, the Android Kotlin, `tool/kora_gateway.dart`, `tool/keeper.dart`, `kora/*.toml`, `scripts/*.sh` and the Cloak WebView bundle.

Method: the solana-ai-kit `/audit-solana` checklist (owner, signer, PDAs, type confusion, duplicate mutable accounts, remaining_accounts, arithmetic, CPI, Token/Token-2022, lifecycle, close and revival, economics, CU). The gateway decides what Kora signs, so it was audited as an off-chain program. Two parallel audits fed this report:

- `docs/audit-2026-10-05/onchain.md` covers the program.
- `docs/audit-2026-10-05/offchain.md` covers the clients, gateway and keeper.

The lead auditor re-checked every Medium or higher finding against the code and re-ran the test suites. Each Medium finding was reproduced with a scratch Dart test outside the repo, which was then deleted. The audit was read-only: no source file was changed, nothing was deployed, and no keypair or `kora/.env` was read.

## Summary

| Severity | Count | On-chain | Off-chain |
| -------- | ----- | -------- | --------- |
| Critical | 0     | 0        | 0         |
| High     | 0     | 0        | 0         |
| Medium   | 4     | 0        | 4         |
| Low      | 14    | 7        | 7         |
| Info     | 20    | 9        | 11        |

No path lets an executor, beneficiary, guard, guardian, fee sponsor or third party take value they are not owed from a vault, or change a plan's authorities. The program's new code checks out:

- installment vesting (`vest_period_secs`)
- the per-rule stipend bitmask, apart from ON-L1
- `rent_paid`
- the account-wide subscription and its fee waiver
- `recover_legacy_vault` access control
- gasless claims

The four Medium findings are all off-chain:

| ID  | Title                                                                                                                                              | Lead verdict                     |
| --- | -------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------- |
| M-1 | Duress mode can be escaped through "Forget this device", which exposes the recovery phrase and claim keys                                          | CONFIRMED (PoC)                  |
| M-2 | The web build stores claim keys, the phrase, the guard key and PIN hashes in localStorage next to their AES key                                    | CONFIRMED (code, package source) |
| M-3 | Cheap Sybil signers can exhaust the gateway's global quotas, which stops sponsored pulses, duress lockdowns, claims and paid transactions for 24 h | CONFIRMED (PoC)                  |
| M-4 | The keeper pays the network fee for releases of any size, and installment vesting lets anyone drain it                                             | CONFIRMED (PoC)                  |

---

## Medium findings

### M-1 [Medium] A duress session can escape duress through "Forget this device", then reveal the recovery phrase or reroute claim keys

- **Where:**
  - `lib/ui/screens/settings_tab.dart:117` (`_forget` has no duress check)
  - `lib/state/providers.dart:116-126` (`reset()` calls `wipeDevice()`, then `state = const Session()`, which clears `duress`)
  - `lib/state/secure_store.dart:233-237` (`wipeDevice` deletes only `pin_hash`, `duress_hash`, `pin_salt` and `guard_private_key`; the phrase and claim keys stay)
  - `lib/ui/screens/pin_setup_screen.dart:48` (`unlock(duress: false)`)
  - `lib/state/actions.dart:515-527` (`revealRecoveryPhrase`) and `:443` (`saveClaimProfile`), `:640` (`executePrivateRoute`): each is gated only by `_decoy` (the session flag) and `_biometric`
  - `lib/state/actions.dart:37` (`_biometric` passes when `isDeviceSupported()` is false)
- **Component:** app session and duress state (`SessionController`, `VaultActions`).
- **Exploit:**
  1. A coercer forces a beneficiary to open Deadman. The victim enters the duress PIN. `LockdownRetrier` starts and the session is `duress: true`. `revealRecoveryPhrase` is decoyed at this point.
  2. The coercer opens Settings, taps "Forget this device", then "Keep them". `reset()` deletes the PINs and the guard key, keeps `recovery_phrase` and `claim_*`, and resets the session to `Session()`, so `duress` is now false.
  3. `app.dart:39` returns to `WelcomeScreen`. The victim is made to approve the wallet authorize. `PinSetupScreen` stores new PINs and calls `unlock(duress: false)`.
  4. `revealRecoveryPhrase()` asks only for biometrics, which the coercer gets from the victim. On a device without biometrics the check passes automatically. The coercer gets the 12 words, which derive every current and future claim key (`m/44'/501'/1'|2'/0'`).
  5. Alternatively, `saveClaimProfile(Rail.cloak, <attacker address>)` followed by `executePrivateRoute` sends the claim-key balance to the attacker through the Cloak pool.
- **Lead verification:** CONFIRMED. A scratch test drove the real `SessionController`, `SecureStore` (mock `FlutterSecureStorage`) and `VaultActions`:
  1. `unlock(duress: true)`, then `revealRecoveryPhrase()` throws the decoy error.
  2. `reset()`, then `setOwner`, `setPins` and `unlock(duress: false)`.
  3. `revealRecoveryPhrase()` returns the stored phrase.
- **Impact:** this undoes the 10-03 M-7 fix. The duress PIN protects a beneficiary's inheritance only until the coercer finds a clearly labelled button. Severity is Medium, not High, because the attack needs physical coercion and the victim's biometrics or wallet approval.
- **Fix:**
  - Under duress, make `_forget`/`reset` a decoy: route it through `_decoy`, or fake success without deleting anything.
  - Persist a `duress_tripped` flag in secure storage. It must survive `wipeDevice` and keep phrase reveal, profile edits, restore and routing blocked until a cooldown expires or the original (non-duress) PIN is entered.
  - Require the real PIN, not only biometrics, for `revealRecoveryPhrase`.
  - Fail closed when biometrics are unsupported for these three actions.

### M-2 [Medium] The web build stores claim keys, the recovery phrase, the guard key and PIN hashes in localStorage next to their AES key

- **Where:**
  - `lib/state/secure_store.dart:57` (`const FlutterSecureStorage()` with no `WebOptions`)
  - `lib/state/providers.dart:28` (`SecureStore()` on every platform)
  - `lib/state/actions.dart:35` (`if (web) return true;` in the biometric gate)
  - `lib/ui/screens/settings_tab.dart` ("Receive privately", "Show recovery phrase" and "Restore" are all enabled on web)
  - `web/index.html` (still has no Content-Security-Policy after the UI rebuild)
- **Component:** web key storage.
- **Issue:** `flutter_secure_storage_web` 2.1.1 (`~/.pub-cache/.../flutter_secure_storage_web-2.1.1/lib/flutter_secure_storage_web.dart:164-190`) works like this when no `wrapKey` is set:
  1. It generates an AES-GCM key with `extractable: true`.
  2. It exports the key with `exportKey('raw')`.
  3. It writes the key with `localStorage.setItem` next to the ciphertexts.

  Anything that can read the origin's localStorage can decrypt every entry: a browser extension with host access, an XSS bug, another person on a shared browser profile, or malware that reads the profile directory. The entries are `recovery_phrase`, `claim_cloak`, `claim_zcash`, `guard_private_key`, `pin_hash`, `duress_hash` and `pin_salt`. The PIN hashes are single salted SHA-256 over a 10^6 space (OFF-L3), so both PINs fall at once.

- **Exploit:**
  1. A beneficiary creates a Cloak receiving profile in the web app and hands the claim code to the owner.
  2. The owner dies and the rule pays the claim key.
  3. An attacker with read access to that browser profile reads the raw key and the `recovery_phrase` ciphertext from localStorage and decrypts them.
  4. The attacker derives the claim keys and sweeps the payout. Private routing is Android-only, so on web the funds sit on the claim key until the user acts.
- **Lead verification:** CONFIRMED from the code and the package source. No live browser PoC was run.
- **Fix:**
  - Do not offer receiving profiles (claim keys or the phrase) on web. Point web users to the Android app or a plain wallet address.
  - If web must keep them, pass `WebOptions(wrapKey: ..., wrapKeyIv: ...)` with a key derived from the PIN through a slow KDF (PBKDF2 or Argon2), so nothing at rest is usable without the PIN.
  - Add a strict CSP to `web/index.html`.

### M-3 [Medium] Cheap Sybil signers can exhaust the gateway's global quotas, which stops free check-ins, duress lockdowns and claims, and every paid transaction, for everyone for 24 h

- **Where:**
  - `tool/kora_gateway.dart:1310` (`final quota = claim == null ? limiter : claims;`: pulses and lockdowns share one limiter)
  - `:1957-1966` (sponsor: `GATEWAY_GLOBAL` 2000, `GATEWAY_CLAIMS_GLOBAL` 500)
  - `:2024-2052` (paymaster: `PAYMASTER_GLOBAL` 2000, `PAYMASTER_CREATES_GLOBAL` 20, `PAYMASTER_ATAS_GLOBAL` 100)
  - `UsageLimiter.check` at `:1122-1150`: the global counter is checked before the per-signer counter, and signers cost nothing to create
  - `:1849-1851`: with mainnet `margin` pricing there is no gateway price floor
  - `lib/solana/deadman_client.dart:2209-2229`: a sponsor refusal falls back to `_sendPaidBy(guard)`
  - `:2159-2167` (`_shouldFundGuard`): for owners who pay fees in USDC, the guard is funded only if the wallet holds spare SOL beyond the deposit
- **Component:** Kora sponsor gateway (:8080) and paymaster gateway (:8081).
- **Exploit (sponsor):**
  1. The attacker creates about 84 vaults with about 42 guard keys of their own. Each vault's rent can be recovered later with `close_vault`.
  2. The attacker sends about 2000 guard-signed `pulse` transactions: 24 per vault and 48 per guard, about 34 minutes at the per-IP limit of 60 per minute. Every one passes `validateSponsorTx`, `verifyGuardSignature` and `checkVaultAccounts`, because the vaults and guards are genuine. Kora pays about 0.02 SOL in total. The attacker pays nothing.
  3. For the next 24 h every guard pulse and every guard **lockdown** gets "Rate limit: the sponsor reached its cap". The client then makes the guard pay. Any guard holding less than the fee fails, which is typical for a USDC-fee owner whose wallet had no spare SOL at plan creation. Its duress `LockdownRetrier` keeps failing until the window rolls over.
  4. The same works against the 500 sponsored SOL claims: rules that pay attacker keys, each then claimed. Heirs with 0 SOL get `SponsorUnavailable` and cannot claim.
- **Exploit (paymaster):** a transaction with only `[transfer_checked(signer ATA → paymaster ATA)]` is a valid basic-tier paid transaction.
  - On mainnet, margin pricing makes it cost about 0.002 USDC. 2000 such transactions from 34 Sybil owners (60 each) cost about $4 per day and block every paymaster transaction for every user.
  - Blocking the 20 Kora-funded creates costs about $25 per day, which is recoverable apart from the fees.
  - On devnet the Circle USDC faucet makes all of this free.
- **Lead verification:** CONFIRMED.
  - A scratch test on the real `UsageLimiter(global: 5)`: five distinct Sybil signers and vaults call `acquire`, then a sixth, legitimate guard is refused with "Rate limit: the sponsor reached its cap of 5 sponsored transactions per 24h".
  - The off-chain PoC reproduced the same thing end to end through `PaymasterRoute.admit` with mainnet policy.
- **Impact:** availability only; no funds are lost. It matters because the duress lockdown is a safety function, and an attacker can time the denial.
- **Fix:**
  - Give lockdowns their own uncapped or much larger budget. They are rare and protect funds.
  - Budget the float in lamports actually spent, not in transaction count, and give priority to established vaults (age, deposit).
  - Add a per-tier minimum price (the gateway `minFee` floor) on mainnet.
  - Fund the guard with a small SOL stipend even for USDC-fee owners. Alternatively, when the sponsor refuses a duress lockdown, fall back to the paymaster or to an owner-signed lockdown.

### M-4 [Medium] The keeper pays the network fee for releases of any size, and installment vesting lets anyone make it send one transaction per vault per sweep, indefinitely

- **Where:**
  - `tool/keeper.dart:135-151` (`decideSol`: checks only `gross > 0` and the beneficiary's rent; never compares the fee with the network cost)
  - `:188-232` (`decideToken`: executes whenever both ATAs exist)
  - `:244` (`if (installments || ...) return true;`: installments bypass `--vest-interval`)
  - `:485-529` (`_sweepVesting`: one release per vault per sweep, sent sequentially)
  - The program allows `vest_period_secs` down to `MIN_VEST_PERIOD_SECS = 60` (`constants.rs:37`) and durations up to 20 years (`MAX_VEST_SECS`).
- **Component:** protocol keeper.
- **Exploit:**
  1. The attacker calls `create_vesting` for plans with up to 8 SOL schedules to their own pre-funded beneficiary keys, with `vest_period_secs = 60` and a duration of up to 20 years. For example, 10,512,000 lamports over 20 years gives 1 lamport per installment.
  2. Every minute each schedule unlocks about 1 lamport. `vestingReleaseDue(installments: true)` returns true, and `decideSol` returns "execute: pays 1 lamports, fee 0". The 2% fee floors to 0, and it is 0 anyway under a subscription.
  3. With `--every 60`, the keeper sends `release_vested_sol` once per vault per sweep and pays 5,000 lamports plus the priority fee each time. That is about 7.2M lamports per vault per day. 100 such vaults (about 1 SOL of recoverable capital) drain about 0.72 SOL per day from the keeper.
  4. Sends are sequential `sendAndConfirmTransaction` calls, so 1,000 such vaults stretch one sweep to tens of minutes. That delays legitimate inheritance executions.

  Token vesting works the same way once both ATAs exist.

- **Lead verification:** CONFIRMED. A scratch test on the real keeper functions:
  - `vestingReleaseDue(claimable: 1, installments: true, lastRelease: now - 60)` returns `true`.
  - `decideSol(vestingAsTier(rule, 1), feeBps: 200, ...)` returns `execute: pays 1 lamports, fee 0`.
- **Fix:**
  - Execute only when the protocol fee's value covers the keeper's cost (`fee × price ≥ 5000 + priority`) or the payout is above a configured minimum.
  - Throttle installment releases per schedule as for continuous vesting, except the final one.
  - Cap work per sweep and order it by value.
  - Beneficiaries can always release for themselves (sponsored or paymaster), so the keeper does not need to serve dust.

---

## Low findings

### On-chain

| ID    | Title                                                                                                                                                                                                                                               | Where                                                                       | Instruction                                  | Fix                                                                                                                       |
| ----- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------- | -------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------- |
| ON-L1 | **New, PoC confirmed.** The stipend bitmask is indexed by rule position but never remapped or cleared. After a restart or reorder, a new private-rail tier gets tokens but no SOL to move them. It can only deny a stipend, never pay one twice.    | `state.rs:228`; `funds.rs:51-64`; `apply_policy` `state.rs:540-548,591-605` | `update_policy`, then `execute_token_rule`   | Rebuild `stipend_paid` from the kept tiers in `apply_policy`; set it to 0 when the plan restarts                          |
| ON-L2 | **New, latent.** `recover_legacy_vault` sends every lamport to the owner. It ignores `rent_payer`, vesting commitments, skipped-tier reserves and lockdown. It becomes a drain if `Vault::SPACE` ever changes again. Devnet holds no exposed vault. | `instructions/vault.rs:389-411`                                             | `recover_legacy_vault`                       | Allow it only for the known legacy sizes (958 and 996), or remove it after migrating; add a test that pins `Vault::SPACE` |
| ON-L3 | Underfunded vesting plans pay first-come, and any executor picks the order (10-04 L-3, open)                                                                                                                                                        | `funds.rs:488-489,561-562`                                                  | `release_vested_*`                           | Release pro-rata when committed > balance, or require full funding                                                        |
| ON-L4 | The vesting guarantee doesn't hold when the owner controls the mint (Token-2022 permanent delegate or freeze authority) (10-04 L-4, open)                                                                                                           | `state.rs:333-351`, `funds.rs:303-311`                                      | `create_vesting`, `release_vested_token`     | Reject `PermanentDelegate` mints; flag freeze authority in the client                                                     |
| ON-L5 | With Token-2022 transfer-fee mints, `paid` overstates what the beneficiary received (10-03 L-5, open)                                                                                                                                               | `funds.rs:400-401,617-621`                                                  | `execute_token_rule`, `release_vested_token` | Record the received delta, or document it                                                                                 |
| ON-L6 | The gas stipend comes out of SOL that pending SOL tiers would get, so execution order decides who gets it (10-03 L-4, partly mitigated)                                                                                                             | `funds.rs:58-60`                                                            | `execute_token_rule`                         | Reserve pending stipends before paying SOL tiers; add the stipend to the event                                            |
| ON-L7 | `close_vault` ignores tokens still in the vault's token accounts (10-03 L-6, open)                                                                                                                                                                  | `vault.rs:277-298`                                                          | `close_vault`                                | Require empty vault ATAs in `remaining_accounts`, or have the client sweep them first                                     |

Lead spot-check:

- ON-L1: `stipend_paid` is written only at `funds.rs:64` and never cleared anywhere (`grep`).
- ON-L2: the handler checks only the size, discriminator, `plan_id` bytes and owner bytes, then drains to the owner.

### Off-chain

| ID     | Title                                                                                                                                                                                     | Where                                                                               | Fix                                                             |
| ------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------- | --------------------------------------------------------------- |
| OFF-L1 | For 0.50 USDC the paymaster's account tier pays for two payout ATAs that a colluding beneficiary can close. Break-even is about $168/SOL, not the $335 in KORA.md (devnet fixed pricing). | `tool/kora_gateway.dart:1011-1028`, `scripts/kora_start.sh:108`, `docs/KORA.md:400` | Price per Kora-funded ATA; correct the docs                     |
| OFF-L2 | Zcash 1Click: a signed dry quote with an injected `depositAddress` still verifies (10-03 L-7, open)                                                                                       | `lib/rails/zcash_route.dart:236-245,528`                                            | Require `echoed['dry'] == false` and a signed `deadline`        |
| OFF-L3 | The PIN is one salted SHA-256 with no attempt limit, and separate records reveal which hash is the real PIN (10-03 L-8, open)                                                             | `lib/state/secure_store.dart:242`, `lib/ui/screens/lock_screen.dart`                | Backoff and lockout, a slow KDF, one indistinguishable verifier |
| OFF-L4 | Under duress, `createVault` isn't blocked, while `createVesting` is                                                                                                                       | `lib/state/actions.dart:116`                                                        | Wrap it in `_decoy`                                             |
| OFF-L5 | Earn deposits the owner's whole JitoSOL balance, and the Jupiter transaction is checked only for the signer (10-03 L-10, open)                                                            | `lib/state/actions.dart:755-771`, `lib/rails/earn_jupiter.dart:318`                 | Deposit only the post-swap delta, bounded by `outAmount`        |
| OFF-L6 | A re-tap after a confirmation timeout can still duplicate `createVault` or a deposit (10-03 L-11, partly fixed)                                                                           | `lib/solana/deadman_client.dart:2367`, `:1505-1544`                                 | Poll until the blockhash expires before failing                 |
| OFF-L7 | The recovery phrase screen doesn't set FLAG_SECURE                                                                                                                                        | `lib/ui/screens/recovery_phrase_screen.dart`                                        | Set FLAG_SECURE while the phrase is shown                       |

## Info

On-chain (details in `onchain.md`):

- **ON-I1:** the pre-`plan_id` devnet vault `zkzYYoAskiTUzBNTHhYUBAxh3rpuStpyLKpZbCvf5vs` (5,516,880 lamports) can never be reached.
- **ON-I2:** for vesting, the fee waiver is evaluated at release time, not at vest time.
- **ON-I3:** a treasury token account is required even when the fee is 0. A beneficiary equal to the treasury collides with the treasury ATA.
- **ON-I4:** there is a single admin key with no rotation and no timelock.
- **ON-I5:** `set_guard` is allowed during lockdown, by design.
- **ON-I6:** `guardian_ready_at` is not reset when the guardian changes.
- **ON-I7:** skipped tiers stay claimable after the owner returns.
- **ON-I8:** there is no sweep path for assets left after the last tier.
- **ON-I9:** strict clippy reports 2 harmless arithmetic hits in program code (`funds.rs:94`, `state.rs:568`).

Off-chain (details in `offchain.md`):

- **OFF-I1:** the gateway sends `Access-Control-Allow-Origin: *`. This is fine on its own, but it widens M-3.
- **OFF-I2:** `/liveness` is not covered by the per-IP limiter.
- **OFF-I3:** the sponsor's `getPayerSigner` is not pinned for guard sends.
- **OFF-I4:** `KORA_MAX_FEE` is one flat cap for every tier.
- **OFF-I5:** Kora's `max_transactions` is a lifetime limit per wallet.
- **OFF-I6:** the admin is the mint authority of the devnet test USDC.
- **OFF-I7:** README drift on CORS.
- **OFF-I8:** `npm audit` on the Cloak bundle reports 4 high, all transitive and apparently unreachable.
- **OFF-I9:** web u64 decoding loses precision above 2^53.
- **OFF-I10:** the biometric gate passes when the device has no biometrics (10-03 OFF-9). This feeds M-1.
- **OFF-I11:** the web Wallet Standard registry is keyed by wallet name.

## Needs verification

These are not counted as findings.

1. Whether Token-2022 removes the vault PDA's signer privilege before it calls a transfer-hook program (`vault_transfer` forwards `remaining_accounts` with `is_signer = false`). This was not proven with a malicious hook. It would need the owner to name such a mint in a rule.
2. Whether the deployed devnet binary matches this source. `anchor build --verifiable` needs Docker, which is not available. Devnet does hold 15 accounts in the current 1390-byte layout.
3. Whether any other cluster holds vaults in the intermediate `0c91602` layout (`rent_payer` present, no `rent_paid`), which ON-L2 would expose. Devnet holds none.
4. Whether Kora 2.0.5 `margin` pricing bills vault and ATA rent as outflow. This decides whether OFF-L1 and 10-04 M-1 are closed on mainnet.
5. Whether `GET /metrics` on the Kora nodes (:8090-8093) bypasses the API key.
6. Whether Kora's `signAndSendTransaction` uses preflight (10-04 L-5).
7. Whether the Seed Vault MWA approval screen shows the USDC fee transfer clearly.

## Tests run

| Check                                                                                                                                              | Result                                                                                                                                                           |
| -------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `cd onchain && cargo test` (lead re-run)                                                                                                           | **73 passed**, 0 failed: 72 LiteSVM integration tests in `tests/test_deadman.rs` plus 1 unit test. The on-chain report's "70" is superseded.                     |
| `cargo clippy -p deadman --lib -- -W clippy::arithmetic_side_effects -W clippy::unwrap_used -W clippy::expect_used -W clippy::panic` (lead re-run) | 2 warnings, both `arithmetic_side_effects` (ON-I9). No `unwrap`, `expect` or `panic` in program code.                                                            |
| `flutter test` (full suite, after the UI rebuild, lead run)                                                                                        | **770 passed**, 7 skipped, 0 failed                                                                                                                              |
| `dart analyze` (whole project)                                                                                                                     | No issues found                                                                                                                                                  |
| Off-chain non-UI subset (`test/kora test/rails test/solana test/state test/tool test/wallet`)                                                      | 602 passed (off-chain auditor)                                                                                                                                   |
| CU profile (`compute_unit_profile`)                                                                                                                | `create_vault` (8 rules) 16,782; `pulse` 13,354; `update_policy` 16,406; `lockdown` 12,817; `execute_sol_rule` 21,381. All loops are bounded by `MAX_RULES = 8`. |
| solana-dev `program_autofixer`                                                                                                                     | No issues on `subscription.rs` and `recover_legacy_vault`                                                                                                        |
| Scratch PoCs (outside the repo, deleted afterwards)                                                                                                | ON-L1: 2 LiteSVM tests. M-1, M-3 and M-4: Dart tests by the lead. M-3 (paymaster), OFF-L1 and M-4: the off-chain auditor's `poc.dart`. All reproduce.            |
| `npm audit --omit=dev` (`tool/cloak_bundle`)                                                                                                       | 4 high, 2 moderate, 12 low, all transitive (OFF-I8)                                                                                                              |
| `cargo audit`, `cargo geiger`                                                                                                                      | Not installed, not run                                                                                                                                           |
| Fuzzing (Trident)                                                                                                                                  | Not set up, not run (0 minutes)                                                                                                                                  |
| `anchor build --verifiable`                                                                                                                        | Not run (needs Docker)                                                                                                                                           |

## Previous findings re-checked

| Finding                                               | Status now                                                                                                                                  |
| ----------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------- |
| 10-03 H-1: a stuck token tier blocks later tiers      | Fixed: `skip_rule` reserves the share, and a non-ATA destination needs the beneficiary's signature                                          |
| 10-03 H-2: claim keys can't be recovered              | Fixed: BIP39 phrase. New exposure on web (M-2)                                                                                              |
| 10-03 M-1: the guard can delay forever                | Fixed: 365-day window from `owner_last_seen` (`check_guard_pulse`)                                                                          |
| 10-03 M-3: the keeper pays ATA and empty-tier rent    | Fixed (`NothingToPay`, `decideToken` price check). A new fee-drain variant exists (M-4)                                                     |
| 10-03 M-4: sponsor drain                              | Fixed: the gateway is the only entry, with guard signature, on-chain binding and an instruction allowlist. A global-quota DoS remains (M-3) |
| 10-03 M-5: lockdown fails silently                    | Fixed (`LockReport`, `LockdownRetrier`, guard-paid fallback)                                                                                |
| 10-03 M-6: check-in skips plans                       | Fixed (`PlanCoverage`)                                                                                                                      |
| 10-03 M-7: duress can redirect claims                 | **Bypassed** through "Forget this device" (M-1)                                                                                             |
| 10-03 L-1, L-2, FUNDS-8, NEW-1/2/3                    | Fixed                                                                                                                                       |
| 10-03 L-4 / L-5 / L-6                                 | Still open (ON-L6, ON-L5, ON-L7)                                                                                                            |
| 10-03 L-7 / L-8 / L-10 / L-11 / OFF-9                 | Still open (OFF-L2, OFF-L3, OFF-L5, OFF-L6, OFF-I10)                                                                                        |
| 10-03 L-9: token payouts never routed                 | Fixed                                                                                                                                       |
| 10-03 OFF-13: plaintext sponsor URL                   | Fixed for mainnet (https required)                                                                                                          |
| 10-04 M-1: ATAs sold for any wallet or mint           | Mostly fixed; residual OFF-L1                                                                                                               |
| 10-04 M-2: quota spent before the payment is checked  | Fixed                                                                                                                                       |
| 10-04 M-3: the client trusts the fee amount and payee | Fixed (pinned signer and payment address, `KORA_MAX_FEE`, https)                                                                            |
| 10-04 L-1: legacy layouts                             | Partly addressed by `recover_legacy_vault` (ON-L2, ON-I1)                                                                                   |
| 10-04 L-2: rent recomputed from the sysvar            | Fixed (`rent_paid`)                                                                                                                         |
| 10-04 L-3 / L-4                                       | Still open (ON-L3, ON-L4)                                                                                                                   |

## Verdict

**The program is ready for an external audit. The app, gateway and keeper need fixes first.**

- **On-chain:** no Critical, High or Medium findings. Before mainnet:
  - fix ON-L1;
  - restrict or remove `recover_legacy_vault` (ON-L2);
  - decide on ON-L3 and ON-L4;
  - move the admin and upgrade authority to a multisig with a timelock (ON-I4).
- **Off-chain:** fix all four Medium findings before any public mainnet exposure:
  - M-1: block reset under duress, and make the duress state persistent and PIN-gated;
  - M-2: remove or PIN-wrap receiving keys on web, and add a CSP;
  - M-3: a separate lockdown budget, a mainnet price floor, and a guard SOL stipend or fallback;
  - M-4: a keeper profitability check and installment throttling.

  OFF-L2 and OFF-L3 are carried over from 10-03 and are cheap to fix.

The program holds user funds, so an external audit is recommended before mainnet. It should cover the program, the Kora gateway and the Kora configuration.
