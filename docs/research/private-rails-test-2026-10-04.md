# Private rails test report (2026-10-04)

Branch `feat/safety-net-mvp-02-10-2026`. QA and integration pass over the Cloak and Zcash (NEAR Intents 1Click) rails, the app state, and the screens. **No funds moved and nothing was signed on mainnet.** Every mainnet call was read-only: 1Click dry quotes, one real quote with no deposit, status reads, Cloak relay reads and RPC reads.

## Results

| Check                                                                  | Result                   | Time  |
| ---------------------------------------------------------------------- | ------------------------ | ----- |
| `dart analyze` (whole project)                                         | No issues                |       |
| `flutter test` (whole project)                                         | **419 passed**, 0 failed | 1m08s |
| `dart run tool/rail_smoke_zcash.dart` (live, run twice)                | **10/10** both runs      | 15.9s |
| `cd tool/cloak_bundle && node smoke.mjs` (live, headless Chromium 153) | **18/18 ALL PASS**       | 3m20s |

Unit test counts:

| Suite        | Tests                                                        |
| ------------ | ------------------------------------------------------------ |
| `test/rails` | 97 (`zcash_route_test` 52, `cloak_route_test` 30, others 15) |
| `test/state` | 81 (`private_rails_test` 33)                                 |
| `test/ui`    | 24 (`private_rails_ui_test` 10)                              |

The QA pass added 11 regression tests to `private_rails_test` and 1 to `private_rails_ui_test`.

### Zcash live smoke (no funds)

- **Tokens:** `GET /v0/tokens` returned 202 tokens with the SOL, USDC, USDT and ZEC asset ids and decimals.
- **Address check:** u1 validation ran offline. An Orchard-only u1 (ZIP 316 test vector) decodes; t1, zs and a bad checksum are rejected.
- **Dry quotes, all with verified signatures:**

  | Input                         | Output                     |
  | ----------------------------- | -------------------------- |
  | 0.1 SOL                       | 0.00883 ZEC                |
  | 5 USDC                        | 0.00345 ZEC                |
  | 5 USDT                        | 0.00345 ZEC                |
  | 5 USDC with `appFees` 100 bps | echoed back as 50 + 50 bps |

  Each quote estimated about 135 s for the swap.

- **Real quote, 5 USDC → ZEC, nothing deposited:**
  - It returned a deposit address with a 30 min deadline (inactive after 3 days).
  - The signature verifies, and a tampered copy is rejected.
  - Its `amountIn` equals the requested amount, which the new check requires.
  - `GET /v0/status` and the first `track()` emission both show `PENDING_DEPOSIT`.
- **`spendable()`:** on an unfunded claim key, a read-only RPC call returns SOL 0 and USDC 0.

### Cloak live smoke (no funds, random unfunded keys)

- **Bundle:** `ping` reports `deadman-cloak/2 sdk/0.2.5`.
- **Receive addresses:**
  - `receiveAddress` from a spend key works.
  - The address from a claim key is deterministic: a repeat call matches.
  - The bundle derives the same address as the unbundled SDK.
- **`selfTest`:** it runs the proof and risk quote and stops before signing.

  | Run            | Download | Prove | Total  |
  | -------------- | -------- | ----- | ------ |
  | SOL, first run | 3.9 s    | 5.5 s | 12.9 s |
  | SOL, cached    | 1.0 s    | 5.0 s | 8.3 s  |
  | USDC 1.0       | 0.9 s    | 4.9 s | 10.4 s |

- **`scanReceived`:**
  - It read all 27 real mainnet delivery records (29 RPC calls) in 46 s.
  - It refuses the history-less publicnode RPC with a clear error.
  - It finds a synthetic note sealed to it (2.5 USDC, 59.5 s).
  - It ignores a note sealed to someone else.
- **`withdrawReceived`:**
  - It accepts its own note and stops at the relay leaf lookup ("not indexed yet").
  - It rejects a foreign note.
- **`shieldAndSend`:**
  - It rejects USDC below the 1 USDC minimum.
  - Unfunded USDC private send and shielded send both stop before the deposit.
- **CSP:** the policy allows every host the SDK fetched: `api.cloak.ag`, the RPC, `solana-rpc.publicnode.com` and `storage.googleapis.com`.

## Money-safety review: bugs fixed

1. **A Cloak route could not be resumed, and the funds were stranded.**
   - **Problem:**
     - A route is a deposit followed by a send. If the send failed, or the app died after the deposit, the deposit stayed in the claim key's own Cloak note.
     - The bundle can resume only with the same (mint, amount). But `quotePrivateRoute` recomputed the amount from the now-empty claim key and answered "Nothing to route yet".
     - A failed `execute` also left no history record, although the UI text said "route again to resume".
   - **Fix:**
     - A `SENDING` record is saved before signing. A Cloak failure turns it into `INTERRUPTED`, and a restart turns any leftover `SENDING` record into `INTERRUPTED`.
     - When the funds have left the claim key, the quote reuses the record's amount, so the bundle finds the deposited note and only sends it on.
     - A **Resume** button sits on the record. On success it updates that same record.
2. **Cloak USDC could not route with the 0.003 SOL stipend, and a SOL route used up the SOL it needs.**
   - **Problem:** a Cloak USDC deposit needs 0.01 SOL on the claim key. Routing SOL first kept only 0.003 SOL plus Cloak's own reserve, which is not enough.
   - **Fix:**
     - With USDC present, a Cloak SOL route now keeps 0.01 SOL (`gasKeptForTokens`).
     - Quoting Cloak USDC with less than 0.01 SOL on the key now fails at the quote, with the shortfall and the claim key address to top up. Before, it failed only after confirmation.
     - The program-side stipend was 0.003 SOL at test time; the build prepared for mainnet pays 0.012 SOL on Cloak (see the open items).
3. **The Zcash history lost track of a deposit when the outcome was unknown.**
   - **Problem:** the record was written only after `execute` returned. A dropped RPC connection after `sendTransaction`, or the app dying, left a deposit nobody was tracking.
   - **Fix:**
     - The record, with its deposit address, is saved before signing.
     - A `ZcashRouteException`, raised by the pre-checks or an RPC error, means nothing was sent, so the record is removed.
     - Any other error keeps the record as `PENDING_DEPOSIT`, so 1Click's status shows whether the deposit landed.
4. **Two sends could run at once.** `executePrivateRoute` now refuses while any transfer is `SENDING`. A second send would fail on-chain anyway, because each route spends the whole balance, but it would still waste a deposit quote and fees.
5. **Destinations were not validated when saved.**
   - **Zcash:**
     - It used to check only `startsWith('u1')`. It now decodes the address fully (bech32m, F4Jumble, receivers).
     - Input that is all uppercase is lowercased.
     - **Addresses with a transparent receiver are refused**, so the payout cannot go to a transparent receiver.
   - **Cloak:** the destination must be a Solana pubkey or a well-formed `cloak:` address.
6. **The shielded inbox scanned for the wrong address.**
   - **Problem:** `scanReceived` finds only notes sent to `receiveAddressFor(claimKey)`. A pasted `cloak:` address from another wallet gave a silently empty inbox.
   - **Fix:**
     - The inbox now checks that the address matches and otherwise explains the problem.
     - Settings → Receive privately → Cloak has a **"Use this phone's shielded address"** button (`useOwnCloakAddress`). The address comes from the claim key, so the recovery phrase restores it.
7. **A 1Click quote was not checked for `quote.amountIn == amount`.** Before, the code checked only the echoed request. `execute` sends `quote.amountIn`, so it must match the request.

### Reviewed, no change needed

| Area              | Finding                                                                                                                                                                                                           |
| ----------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Refund address    | It is always the claim key. Checked in the quote echo and again in `execute`.                                                                                                                                     |
| Recipient         | Checked against the profile destination in the quote echo.                                                                                                                                                        |
| Quote checks      | The signature is verified on every quote. Expiry is checked in both `executePrivateRoute` and the routes.                                                                                                         |
| Units             | USDC/USDT use 6 decimals and SOL uses 9 in both rails' tables. The ZEC fee shows with 8 decimals. Cloak minimums and exit fees are in base units.                                                                 |
| Zcash fee reserve | A SOL route spends the balance minus the 5,000-lamport fee, leaving 0. A token route takes the fee plus 2,039,280 deposit-ATA rent out of the stipend and leaves 955,720 lamports, above the rent-exempt minimum. |
| WebView           | Only created from screen-triggered actions (`_route`, `useOwnCloakAddress`, rails check). Status polling uses a runtime-less `CloakRoute`. No workmanager path touches it.                                        |
| Duress            | Every routing, withdrawal and profile action goes through the decoy, and the inbox shows as empty. Claim-key balances stay visible, the same as plans.                                                            |

## Still needs a real-funds mainnet run

Nothing below has run with real money. That includes:

- the claim key's payout transaction and `deposit/submit` against a real transaction;
- `track` through to `SUCCESS`;
- a Cloak deposit, shielded transfer and withdrawal;
- whether a Cloak USDC withdrawal creates the recipient's token account;
- 1Click crediting USDC sent to a deposit-address ATA the claim key created;
- proof time on the Seeker, where the desktop takes 5–6 s;
- `CloakWebViewRuntime` on a real device;
- the resume path against the live relay.

### Minimal plan (about $22 of funds, about $3 spent on fees)

Build a mainnet APK with browser-friendly RPCs. `api.mainnet-beta.solana.com` returns 403 to the WebView, and publicnode serves no registry history.

```
flutter build apk --dart-define=CLUSTER=mainnet-beta \
  --dart-define=RPC_URL=<helius mainnet url> \
  --dart-define=CLOAK_RPC_URL=<helius mainnet url> \
  --dart-define=ONECLICK_JWT=<optional 1Click key>
```

To fund the claim keys you do not need the vault program. Send directly to each claim key; this behaves like a payout.

1. **Setup:**
   - Security → Receive privately: set up a Zcash profile with a shielded-only u1 from your own wallet (Zashi).
   - Set up a Cloak profile with **"Use this phone's shielded address"**.
   - Save the recovery phrase.
   - Run Security → Private rails check; both checks must pass. Note the Seeker proof time.
2. **Zcash, SOL:**
   - Send **0.05 SOL** to the Zcash claim key.
   - Family Circle → Ready to route → Route privately via Zcash → Send.
   - Expect `PENDING_DEPOSIT` → `KNOWN_DEPOSIT_TX`/`PROCESSING` → `SUCCESS` within about 3 min, and ZEC arriving in Zashi.
   - The claim key should end at 0 lamports.
3. **Zcash, USDC:**
   - Send **5 USDC + 0.003 SOL** to the Zcash claim key, the same as a token payout's stipend.
   - Route the USDC.
   - Check on an explorer that the transaction creates the deposit address's USDC ATA and transfers 5 USDC.
   - Expect `SUCCESS`. About 0.00096 SOL should be left on the key.
4. **Cloak, SOL:**
   - Send **0.03 SOL** to the Cloak claim key.
   - Route via Cloak: a deposit of 0.025 SOL, then a shielded transfer to this phone's address.
   - Expect `SUCCESS`.
   - Open the Shielded inbox; expect a 0.025 SOL note within about 1 min, once the relay indexes it.
   - Withdraw to the wallet. The exit fee is 0.005 SOL + 0.3%, so expect about 0.0199 SOL in the wallet.
5. **Cloak, USDC:**
   - Send **2 USDC + 0.01 SOL** to the Cloak claim key.
   - Route the USDC, then withdraw it from the inbox to a wallet that has **no** USDC ATA. This checks whether the withdrawal creates the ATA.
   - The exit fee is 0.45 USDC + 0.3%, so expect about 1.54 USDC.
6. **Optional, resume:**
   - Repeat step 4 with 0.03 SOL.
   - Force-close the app as soon as the deposit signature appears in the logs, after "Deposit" and before the transfer.
   - Reopen the app. The row should show "Interrupted… tap Resume". Tap Resume, and expect a send only (no second deposit) and `SUCCESS`.

Expected cost:

| Item                 | Cost                                         |
| -------------------- | -------------------------------------------- |
| 1Click swap spread   | about 4% on 0.05 SOL and 9% on 5 USDC (2026-10-04 quotes), so about $0.75 |
| Cloak exit fees      | about $1                                     |
| Solana fees and rent | under $0.50                                  |

## Open items (not fixed here)

- **Program stipend:** addressed in the program build prepared for mainnet (not yet deployed). Token payouts now top the claim key up per rail: 0.012 SOL on Cloak (`CLOAK_GAS_STIPEND`, above the 0.01 SOL a Cloak USDC deposit needs) and 0.003 SOL on Zcash. Until that build is deployed, devnet still pays 0.003 SOL and a Cloak USDC tier needs a manual SOL top-up; the app's quote check still reports the shortfall.
- **Status updates:** they run only while the Circle tab is open; there is no background tracking.
- **Zcash records that cannot be dismissed:**
  - A Zcash record kept after a network error before signing can show `PENDING_DEPOSIT` for an address that was never funded.
  - There is no way to dismiss such a record yet.
- **No priority fee on the Zcash payout:** the transaction may land slowly when the network is congested. A deposit that misses the 30-minute deadline is refunded to the claim key.
- **Docs out of date:** `docs/research/cloak.md` still lists receiving as "not built" (docs agent).
