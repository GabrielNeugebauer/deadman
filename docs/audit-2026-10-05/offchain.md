# Deadman off-chain security audit (2026-10-05)

Scope: everything off-chain that holds or moves funds or keys. That covers `lib/solana` (codec, client builders, pre-checks, paymaster and sponsor paths, claim fallback, decoding), `lib/kora`, `lib/rails` (Cloak, Zcash, Earn), `lib/wallet` (MWA bridge, web wallet bridge and its JS interop), `lib/state/secure_store.dart` and key derivation, `lib/state/actions.dart`, `lib/state/lockdown_retry.dart`, the Android MWA and foreground-service Kotlin, `tool/kora_gateway.dart`, `tool/keeper.dart`, `kora/*.toml`, `scripts/*.sh` and the Cloak WebView bundle. Source was reviewed read-only. `kora/.env` and the keypair files were not read.

Method: solana-ai-kit `/audit-solana` checklist (`commands/audit-solana.md`), applied to the off-chain side. That means account owner/discriminator checks on decoded data, signer binding, PDA derivation, instruction-shape validation (the gateway is effectively an off-chain "program" that decides what Kora signs), arithmetic and narrowing, CPI and token handling as the client builds it, lifecycle, economics, and DoS. The fixes for `docs/security-audit-2026-10-03.md` and `docs/security-review-2026-10-04.md` were re-checked against the current code. Every finding below was checked against code. PoCs ran against the real `validatePaymasterTx`, `PaymasterRoute.admit`, `decideSol` and `vestingReleaseDue` (scratch script outside the repo).

## Summary

| Severity | Count |
| -------- | ----- |
| Critical | 0     |
| High     | 0     |
| Medium   | 4     |
| Low      | 7     |
| Info     | 11    |

No path lets a third party take a user's funds remotely. Here is what the four Medium findings do:

- **M-1:** the duress mode can be escaped from inside the app, which exposes the recovery phrase and the claim keys.
- **M-2:** the web build keeps claim keys and the phrase in readable browser storage.
- **M-3:** the global quotas that cap Kora's spending can be bought out cheaply, which denies the free and paid fee paths to everyone.
- **M-4:** the keeper pays a network fee for releases of any size, and installment vesting lets anyone make it do so every sweep, forever.

---

## M-1 [Medium] Duress session can "Forget this device", re-enroll a normal PIN, and then reveal the recovery phrase or reroute claim keys

- **Where:**
  - `lib/ui/screens/settings_tab.dart:117` (`_forget`, no duress check)
  - `lib/state/providers.dart:116` (`reset` clears `duress`)
  - `lib/ui/screens/pin_setup_screen.dart:48` (`unlock(duress: false)`)
  - `lib/state/actions.dart:515` (`revealRecoveryPhrase`) and `:443` (`saveClaimProfile`), both gated only by `_decoy` and `_biometric`
- **Context:** the fix for M-7 of the 10-03 audit made receiving-profile changes, private routing and phrase reveal fail under duress, through `_decoy`.
- **Exploit:**
  1. A coercer makes a beneficiary open Deadman. The victim enters the duress PIN. The duress lockdown starts and the session is `duress: true`.
  2. The coercer taps Settings → "Forget this device" → "Keep them". This is not decoyed. `reset()` deletes the PINs and the guard key, keeps the receiving keys and the recovery phrase, and sets `state = const Session()`, so `duress` becomes false.
  3. The app returns to the welcome screen. The coercer has the victim approve the MWA authorize, then chooses a new PIN and duress PIN. `PinSetupScreen` calls `unlock(duress: false)`, which gives a normal session.
  4. Settings → recovery phrase → `revealRecoveryPhrase()` asks only for biometrics, which the coercer gets from the victim's finger. If the device reports no biometrics, `biometricProvider` returns true. The coercer now holds the 12-word phrase, which controls every current and future claim key (`m/44'/501'/1'|2'/0'`).
  5. Alternatively, `saveClaimProfile(Rail.cloak, <attacker Solana address>)` followed by `executePrivateRoute` sends the claim-key balance to the attacker through the Cloak pool.
- **Impact:** M-7's guarantee no longer holds. The duress PIN protects the beneficiary's inheritance only until the coercer finds a button that is clearly labelled.
- **Fix:**
  - Under duress, make `_forget`/`reset` a decoy: fake success and change nothing, or fail like the other decoys.
  - Persist a `duress_tripped` flag in secure storage that survives `reset`/`wipeDevice` and keeps phrase reveal, profile edits and routing disabled until a cooldown expires or the original (non-duress) PIN is entered.
  - Require the real PIN, not only biometrics, for `revealRecoveryPhrase`.

## M-2 [Medium] Web build stores claim keys, the recovery phrase, the guard key and PIN hashes in localStorage next to their AES key; biometrics always pass

- **Where:**
  - `lib/state/secure_store.dart:57` (`const FlutterSecureStorage()`, no `WebOptions`)
  - `lib/state/actions.dart:35` (`if (web) return true;`)
  - `lib/ui/screens/settings_tab.dart` ("Receive privately" card is enabled on web: "Payouts land on a fresh key on this browser")
  - `web/index.html` (no CSP)
- **Issue:** `flutter_secure_storage_web` 2.1.1 without a `wrapKey` generates an AES-GCM key and stores it raw in `localStorage` (`exportKey('raw')` → `setItem`), next to the ciphertexts. Anything that can read the origin's localStorage gets the plaintext: a browser extension with host access, XSS, another person on a shared browser profile, or malware reading the profile directory. That plaintext includes:
  - `claim_cloak`/`claim_zcash` (claim key secrets)
  - `recovery_phrase`
  - `guard_private_key`
  - the salted SHA-256 PIN and duress hashes, which an offline 10^6 search breaks instantly (see L-3)
- **Exploit:**
  1. A beneficiary uses the web app (deadman web build) to create a Cloak receiving profile and hands the claim code to the owner.
  2. The owner dies and the rule pays the claim key.
  3. Anyone with read access to that browser profile's localStorage for the site decrypts `recovery_phrase` with the stored key, derives the claim keys, and sweeps the payout. Private routing is Android-only, so on web the funds sit on the claim key until the user acts.
- **Fix:**
  - Do not offer receiving profiles (claim keys or the phrase) on web. Point web users to the Android app or a wallet address.
  - If web must keep them, wrap the storage key with a key derived from the PIN (`WebOptions(wrapKey: ...)` from a slow KDF of the PIN), so nothing at rest is usable without the PIN.
  - Add a CSP to `web/index.html`.

## M-3 [Medium] Global quotas on the sponsor and the paymaster are cheap to exhaust with Sybil signers: free check-ins, duress lockdowns and claims, and every paid transaction, stop for everyone for 24 h

- **Where:**
  - `tool/kora_gateway.dart:1957-1966` (sponsor `GATEWAY_GLOBAL` 2000, `GATEWAY_CLAIMS_GLOBAL` 500)
  - `:2024-2052` (paymaster `PAYMASTER_GLOBAL` 2000, `PAYMASTER_CREATES_GLOBAL` 20, `PAYMASTER_ATAS_GLOBAL` 100)
  - `UsageLimiter.check` `:1130`
  - client fallbacks: `lib/solana/deadman_client.dart:2159` (`_shouldFundGuard` leaves the guard unfunded for USDC-fee owners) and `:1184` (claims fall back to wallet SOL)
- **Issue:** each quota is keyed by signer plus one global counter, and the global counter is the binding limit. Signers are free to create. The gateway admits any transaction that passes the shape, signature and on-chain checks and that Kora then signs, so an attacker's own valid transactions consume the global slots.
- **Exploit (sponsor):**
  1. The attacker creates about 84 vaults of their own: 24 pulses per vault and 48 per guard, using about 42 guard keys. Each vault's rent (about 0.0077 SOL on devnet) can be recovered with `close_vault`.
  2. The attacker sends about 2000 guard-signed `pulse` transactions to :8080. That takes about 34 minutes from one IP at 60 per minute.
  3. Kora pays about 10,000 lamports each, so about 0.02 SOL per day comes from the float. The attacker pays nothing.
  4. For the next 24 h, every guard pulse and every guard lockdown gets `Rate limit: the sponsor reached its cap`. The client falls back to the guard paying (`_sendWithKey`), but a USDC-fee owner's guard holds no SOL (`_shouldFundGuard` → false). For those owners, the **duress lockdown** (`LockdownRetrier`) keeps failing until the window rolls.
  5. The same applies to the 500 sponsored SOL claims: rules paying attacker keys, then each claimer claims. Heirs with 0 SOL then cannot claim (`SponsorUnavailable`).
- **Exploit (paymaster):** a payment-only transaction `[transfer_checked(signer ATA → paymaster ATA)]` is a valid basic-tier paid transaction.
  - On mainnet (margin pricing, no gateway floor) Kora prices it at about (10,000 lamports × 1.15), about 0.002 USDC. So 2000 such transactions from 34 Sybil owners (60 per owner) cost about $4 per day and block every paymaster transaction for all users: wallet check-ins, withdrawals, and token claims paid from the payout.
  - `PAYMASTER_CREATES_GLOBAL` = 20 is blocked for 20 Kora-funded creates, about $25 per day on mainnet, recoverable minus fees.
  - On devnet, Circle USDC from the faucet makes all of this free.
- **PoC:** scratch `poc.dart` (outside the repo).
  - Policy as on mainnet (`minAmounts: {}`), global cap 5: five Sybil owners each have a 1-unit payment-only transaction admitted (`tier=basic`). The sixth, legitimate owner gets `Rate limit: ... reached its cap of 5`.
  - The sponsor path uses the same `UsageLimiter`, and the existing test `accepts a guard-signed pulse` plus `checkVaultAccounts` show that an attacker-owned vault with an attacker guard is admitted.
- **Fix:**
  - Do not let one global counter gate everything. Give lockdowns their own uncapped (or much larger) budget: they are rare and protect funds.
  - Budget the float in lamports actually spent rather than transaction count, and weight by vault age or value (e.g. vaults older than N days with a deposit get priority).
  - Add a per-tier minimum price on mainnet (the gateway `minFee` floor) so a basic transaction costs at least a few cents.
  - Fund the guard with a small SOL stipend even for USDC-fee owners. Alternatively, when the sponsor refuses a duress lockdown, fall back to the paymaster or an owner-signed lockdown.

## M-4 [Medium] Keeper pays the network fee for releases of any size; installment vesting lets anyone make it send one transaction per vault per sweep, indefinitely

- **Where:** `tool/keeper.dart:135` (`decideSol`: only `gross > 0` and the beneficiary rent are checked, no fee-versus-cost check), `:188` (`decideToken`: executes whenever both ATAs exist), `:243-244` (`vestingReleaseDue`: `installments` → always due), `:485-529` (`_sweepVesting`).
- **Exploit:**
  1. The attacker creates vesting plans. Each has up to 8 SOL schedules to their own pre-funded beneficiary keys, `duration_secs` up to 20 y and `vest_period_secs = 60`. For example, a total of 10,512,000 lamports gives 1 lamport per installment.
  2. Every minute each schedule unlocks about 1 lamport. `vestingReleaseDue(installments: true)` returns true, and `decideSol` returns `execute: pays 1 lamports, fee 0`: the fee floors to 0, and is 0 anyway with a subscription.
  3. The keeper (`--every 60`) sends one `release_vested_sol` per vault per sweep and pays 5,000 lamports plus `--cu-price` each time. That is about 7.2M lamports per vault per day. 100 attacker vaults (about 1 SOL of recoverable capital) drain about 0.72 SOL per day from the keeper.
  4. Each send is a sequential `sendAndConfirmTransaction`, so 1,000 such vaults also stretch one sweep to tens of minutes. That delays legitimate inheritance executions and releases.
- **PoC:** `vestingReleaseDue(claimable: 1, installments: true, lastRelease: now-60)` → `true`, and `decideSol(vestingAsTier(rule, 1), feeBps: 200, ...)` → `execute: pays 1 lamports, fee 0`.
- **Fix:**
  - Execute only when the protocol fee's value covers the keeper's network fee: `fee × price ≥ 5000 + priority`, or a configured minimum payout.
  - Rate-limit installment releases per schedule as for continuous vesting (`--vest-interval`), except the final one.
  - Cap work per sweep and order it by value.
  - Beneficiaries can always release for themselves (sponsored or paymaster), so the keeper does not need to serve dust.

---

## L-1 [Low] Account tier still sells two closable ATAs per 0.50 USDC; break-even is about $168/SOL, not the documented $335 (devnet fixed pricing)

- **Where:** `tool/kora_gateway.dart:1011-1028` (payout ATAs are justified with no closability check), `scripts/kora_start.sh:108` (account tier 500,000), `docs/KORA.md:400`.
- **Exploit:**
  - The attacker's vesting vault has two schedules (B1, B2, two keys the attacker controls) of a worthless mint.
  - The transaction is `[ata(Kora→B1), ata(Kora→B2), release_vested_token(B1), release_vested_token(B2), pay 0.50 USDC]`. It passes as `tier=account koraAtas=2 vaultChecks=[]` (PoC B).
  - B1 and B2 burn the tokens and `CloseAccount` the ATAs: +2 × 1,488,440 lamports for 0.50 USDC.
  - The total is bounded by `PAYMASTER_ATAS_GLOBAL` (100 per day, about 0.15 SOL per day).
  - On devnet the Circle faucet makes USDC free. On mainnet, margin pricing bills outflow (see Needs verification 1).
- **Fix:** price the account tier per Kora-funded ATA (or at ≥ 2 × rent at a conservative SOL price), or fund payout ATAs only for the claimer's own claim of the payment mint. Correct the break-even figure in KORA.md.

## L-2 [Low] Zcash 1Click: signed dry quote plus injected `depositAddress` still verifies (10-03 L-7 not fixed)

- **Where:** `lib/rails/zcash_route.dart:236-245` (`echoed['dry'] == dry` is never checked; the `amountIn` check was added), `:528` (`depositAddress` is signed only when `dry != true`).
- **Exploit:** an on-path attacker who can break TLS to `1click.chaindefuser.com` replays a genuinely signed `dry:true` quote for the same refundTo, recipient and amount, and adds their own `depositAddress`. `execute()` then sends the claim key's SOL or USDC to it.
- **Fix:** reject unless `echoed['dry'] == false` for executable quotes, and require `q['deadline']` to be present and signed.

## L-3 [Low] PIN is one salted SHA-256 with no attempt limit (10-03 L-8 not fixed)

- **Where:** `lib/state/secure_store.dart:242`, `lib/ui/screens/lock_screen.dart:17`.
- **Issue:** 10^6 online guesses are possible on an unlocked phone. The offline search is instant once storage is readable, which on web is trivial (M-2). The separate `pin_hash`/`duress_hash` entries reveal which PIN is the real one.
- **Fix:** add backoff and lockout, a slow KDF, and one indistinguishable verifier record.

## L-4 [Low] Duress session can still create and fund an inheritance plan (`createVault` is not decoyed, `createVesting` is)

- **Where:** `lib/state/actions.dart:116`.
- **Exploit:** under duress, the coercer creates a plan funded from the wallet with a tier to themselves at the minimum delay (`interval + 60 s`), then executes it. The program allows anyone to execute. This needs the coerced Seed Vault approval, which could also just sign a transfer, so the impact is mainly inconsistency, and Low.
- **Fix:** wrap `createVault` in `_decoy`.

## L-5 [Low] Earn deposits the owner's whole JitoSOL balance, and the Jupiter transaction is checked only for the signer (10-03 L-10 not fixed)

- **Where:** `lib/state/actions.dart:763-771`, `lib/rails/earn_jupiter.dart:318`.
- **Fix:** deposit only the post-swap delta, bounded by `outAmount`.

## L-6 [Low] Confirmation timeout and re-tap can still duplicate `createVault` or deposits (10-03 L-11 partly fixed)

- **Where:** `lib/solana/deadman_client.dart:2367` (throws after 60 s, with no `lastValidBlockHeight` tracking), `:1505-1544`.
- **Issue:** `_inflight` de-duplicates only identical signed bytes. A re-tap rebuilds the transaction with a new blockhash, and for `createVault` with a new `nextFreePlanId`.
- **Fix:** keep polling until the blockhash expires before failing.

## L-7 [Low] Recovery phrase screen does not set FLAG_SECURE

- **Where:** `lib/ui/screens/recovery_phrase_screen.dart:9`. A grep for FLAG_SECURE or secure-window handling in `lib` and `android` finds nothing.
- **Issue:** the 12 words appear in the recents thumbnail and in screenshots and screen recordings (accessibility or recording malware).
- **Fix:** set `FLAG_SECURE` while the phrase is shown.

---

## Info

1. Gateway `Access-Control-Allow-Origin: *` (`tool/kora_gateway.dart:1554`): no credentials are involved, so this is fine. It does let any website turn its visitors into a distributed client against the global quotas (M-3).
2. `GET /liveness` is answered before the per-IP limiter and proxies an upstream call per request (`:1563`): unthrottled amplification toward Kora.
3. The sponsor's `getPayerSigner` is not pinned for guard sends (`deadman_client.dart:2250`). A lying sponsor can make the guard its own fee payer. The cost is fees only, because the instructions are local.
4. `maxFee` is one flat 3 USDC cap for every tier (`config.dart` `koraMaxFee`). A paymaster can charge up to 3 USDC for a basic transaction, but the payment goes only to the pinned key. Consider a per-tier cap.
5. Kora's `usage_limit.max_transactions = 1000` is lifetime per wallet and never expires (`kora/sponsor.toml`). Long-lived guards and claimers silently move to guard-paid or wallet-paid sends.
6. Devnet default `USDC_MINT` `Ew8Z…PMFGk` has mint authority `A9Sft…nvtH` (the admin), checked on devnet. Only the operator can mint it, which is fine for devnet. Mainnet refuses `TEST_USDC_MINT` (`kora_start.sh:73`).
7. `README.md:249` still says the gateway sends no CORS headers. It now does (doc drift).
8. Cloak bundle `npm audit --omit=dev` reports 4 high, 2 moderate and 12 low issues, all transitive through `@cloak.dev/sdk`: `ws`, `underscore`→`jsonpath`→`bfj` (snarkjs) and `elliptic`/ethers. None looks reachable from the WebView's ops. The page CSP is `script-src 'self' 'wasm-unsafe-eval' blob:; connect-src https:`.
9. Web u64 decoding (`BorshReader._int64`) loses precision above 2^53. The comment acknowledges this. High-supply token balances on web can be mis-shown, and "max" withdraws can fail.
10. The biometric gate passes when `isDeviceSupported()` is false (10-03 OFF-9 still open, `actions.dart:37`).
11. Web Wallet Standard discovery keys wallets by name (`_standard[name] = wallet`). An extension registering as "Phantom" replaces the real one. That needs a malicious extension, which already has page access.

## Needs verification

1. That Kora 2.0.5 `margin` pricing bills the fee payer's outflow from simulated inner `create_account` (vault and ATA rent). This closes 10-04 M-1 and L-1 above on mainnet. The `paymaster.mainnet.toml` comment asserts it, and it was not checked against the Kora source here.
2. That `GET /metrics` on :8090-8093 bypasses the API key (docs/KORA.md:102 says so). It exposes the fee payer balance only if the firewall is open.
3. Whether Kora's `signAndSendTransaction` uses preflight (10-04 L-5): a transaction that fails after simulation still costs Kora its fee.
4. That Seed Vault's MWA approval screen shows the final USDC fee transfer clearly. The app relies on it as the user's last check.

## Prior findings re-checked

| Finding                                      | Status now                                                                                                                                                                                   |
| -------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 10-03 H-2 claim keys unrecoverable           | Fixed: BIP39 phrase (`Random.secure`), keys at `m/44'/501'/1'/0'` and `2'`; `wipeDevice` keeps them. New exposure on web (M-2).                                                              |
| 10-03 M-3 keeper pays ATA rent               | Fixed (`decideToken` price check). A new fee-drain variant exists (M-4).                                                                                                                     |
| 10-03 M-4 sponsor drain                      | Fixed: the gateway is the only entry, guard signature and on-chain guard binding are checked, Kora is never referenced, instruction allowlist. Residual global-quota DoS (M-3).              |
| 10-03 M-5 silent lockdown                    | Fixed: `LockReport`, `LockdownRetrier` (persisted, backoff, Workmanager), guard-paid fallback.                                                                                               |
| 10-03 M-6 check-in skips plans               | Fixed (`PlanCoverage`).                                                                                                                                                                      |
| 10-03 M-7 duress can redirect claims         | Partly fixed: decoy plus biometrics, bypassed through "Forget this device" (M-1).                                                                                                            |
| 10-03 L-7 / L-8 / L-10 / L-11 / OFF-9        | Still open (L-2, L-3, L-5, L-6, Info 10).                                                                                                                                                    |
| 10-03 L-9 token payouts never routed         | Fixed: USDC is routed with the gas reserve kept (`routableAssets`).                                                                                                                          |
| 10-03 OFF-13 plaintext sponsor               | Fixed for mainnet: `KoraClient.checkUrl` requires https; http only on devnet.                                                                                                                |
| 10-04 M-1 ATAs sold for any wallet or mint   | Mostly fixed: ATAs must be paid into (deposit to a Deadman vault, or a payout beneficiary or treasury), per-owner and global ATA quotas. Residual (L-1).                                     |
| 10-04 M-2 quota spent before payment checked | Fixed: the payment-source pre-check (owner, mint, unfrozen, balance ≥ outflow − withdraw credits) runs before `acquire`, and quota is released on a Kora or HTTP rejection (`_signAndSend`). |
| 10-04 M-3 client trusts fee amount and payee | Fixed: `KORA_PAYMASTER_SIGNER` pinned as fee payer and payment address, `KORA_MAX_FEE` cap, https on mainnet, devnet default signer pinned.                                                  |

## Checked and clean

- `codec.dart` layouts match `state.rs`:
  - `Vault` field order, `Vault::SPACE` = 1390, `Rule` = 131 bytes, `rent_paid`, `stipend_paid`, `vest_period_secs`.
  - `Subscription` (81 bytes) and `SubscriptionConfig`.
  - The 19 discriminators match the IDL (tested).
  - `decodeVault` bounds-checks every read, caps the rule count at 8, and rejects bad enum or option tags.
  - `_decodeVault` accepts only program-owned accounts of exactly 1390 bytes.
- PDAs (`vault`, `config`, `sub_config`, `sub`, classic ATA) are derived locally. Deposits, withdrawals and payouts never use RPC-supplied addresses. A malicious RPC can only make transactions fail or mislead the UI, because beneficiary, treasury and subscription are enforced on-chain.
- Gateway transaction parsing (`_Tx`):
  - It rejects lookup tables, versions other than 0, trailing bytes, out-of-range indices, duplicate keys, a fee payer other than Kora, and anything other than exactly 2 signatures.
  - Kora (index 0) is always writable and never appears in a sponsored instruction.
  - In paid instructions Kora may appear only as the ATA payer, the `create_vault`/`create_vesting`/`subscribe` payer (at most one), or the `close_vault` `rent_payer`. It is never a token authority or account, and never a System source or destination.
  - The ComputeBudget fee is computed in BigInt and capped (no overflow).
- Signatures: the gateway verifies the non-Kora signer's Ed25519 signature over the message before touching quotas. `partiallySign` fills only the device key's slot. The web bridge refuses to sign transactions that do not name the connected account (`requiredSigners`).
- Sponsored claims: executor and beneficiary must be the signer, the config PDA is pinned, the vault must be current-layout and of the right kind, the rule must be pending and pay SOL, and the subscription must be the owner's PDA. Token claims are refused on the sponsor.
- Paymaster payment: it must be the last instruction, use the right mint and token program, meet the tier floor (fixed pricing), and come from the signer's own unfrozen ATA holding the outflow. A claim-funded payment must come from the claim's own beneficiary ATA in the payment mint.
- Kora configs: `transfer_transaction` disabled, durable nonces off, every `fee_payer_policy` flag false except `allow_create_account` on the plan and account tiers, outflow caps per tier (basic 60k, account 4.15M, plan 11.5M), Token-2022 `permanent_delegate`/`transfer_hook` mints blocked, Redis bound to 127.0.0.1, API keys generated with `openssl rand` into a 0600 `.env`. `kora/.gitignore` covers `.env*`, `*.json` (keypairs, counters), logs, pid and run tomls, and git history has no committed secrets.
- Mainnet guard rails: `kora_start.sh` requires `CONFIRM_MAINNET=yes`, a mainnet RPC, `JUPITER_API_KEY`, and no `TEST_USDC_MINT`. The keeper checks the RPC genesis hash against `--cluster`. `set_subscription.dart` requires `--mainnet`.
- Android:
  - Only `MainActivity` is exported.
  - `WalletSessionService` and the notification receivers are `exported=false`.
  - The MWA auth token is kept only in memory.
  - Channel calls are serialized by a mutex.
  - `signTransactions` only (the app submits).
- Cloak WebView: `WebViewAssetLoader` with file and content access off. The claim secret goes only to bundled JS, and the Dart-side copy is destroyed. The page CSP pins scripts to `'self'`.
- Zcash: the quote signature is verified against the pinned 1Click key. refundTo, recipient, assets, `amount` and `amountIn` are echo-checked. `execute` re-checks refundTo == claim key, expiry and asset, and leaves the claim key rent-exempt or empty.
- Secrets in tools: keypairs are read only from paths the operator passes in. `mainnet_e2e` sets mode 0600 before it writes. Nothing prints secret material.

## Tests run

- `flutter test test/kora test/rails test/solana test/state test/tool test/wallet`: **602 passed**, 0 failed. UI tests were not run here because the UI rebuild is in progress in parallel.
- `dart analyze lib/solana lib/kora lib/rails lib/wallet lib/state tool`: no issues.
- PoCs (scratch `poc.dart`, run with the repo's package config, nothing written to the repo):
  - A: global-quota exhaustion with payment-only transactions (M-3).
  - B: two closable payout ATAs at account tier (L-1).
  - C: keeper executes a 1-lamport installment (M-4).

  All three reproduce.

- `npm audit --omit=dev` in `tool/cloak_bundle` (Info 8).
- Not run for this off-chain lens: `cargo test`/clippy/Trident on the program, and no devices or deploys. One read-only devnet RPC call was made: `getAccountInfo` of the test USDC mint.

## Verdict

Fix before any public mainnet exposure:

- **M-1:** decoy `reset` under duress and persist the duress state.
- **M-2:** remove or PIN-wrap receiving keys on web.
- **M-3:** separate and prioritise lockdown quota, and set a mainnet price floor.
- **M-4:** add the keeper profitability check and throttle installments.

L-2 and L-3 are carried over from 10-03 and are cheap to fix. No Critical or High issues were found in the off-chain code. An external review of the gateway and of the Kora configuration should precede a mainnet paymaster.
