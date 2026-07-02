> Research report produced 2026-10-02 while building the rail. Sources are linked inline.

I've added `JupiterEarn` and its tests, and it uses Jupiter Swap API V2 with the integrator fee. `dart analyze lib/rails test/rails` reports no issues and all 15 tests pass. Two things need your attention first. The app must send the wallet-signed bytes to a new `JupiterEarn.execute()`, not to its own RPC. And with Jupiter's fee at 50 bps or more, the user pays at least 0.5% per swap, which is about 38 days of JitoSOL yield.

Files: `lib/rails/earn_jupiter.dart`, `test/rails/earn_jupiter_test.dart`

## Verified facts (2026-10-02)

1. **Ultra API and Swap API v1 are both deprecated.** The docs say both are "no longer actively maintained and superseded by Swap V2". Ultra's `/order` and `/execute` moved unchanged from `ultra-api.jup.ag` to `api.jup.ag/swap/v2`. The old `lite-api.jup.ag/swap/v1/quote` still answers today.
   - https://developers.jup.ag/docs/ultra
   - https://developers.jup.ag/docs/swap/v1
   - https://developers.jup.ag/docs/swap/migration/ultra-to-order.md
2. **Swap V2 has two paths.**
   - The Meta-Aggregator (`GET /order` + `POST /execute`) has all routers competing (Metis, JupiterZ RFQ, Dflow, OKX). Jupiter charges its own fee, and integrators earn through `referralAccount` + `referralFee`.
   - The Router (`GET /build`) uses Metis only and returns raw instructions. Jupiter charges no swap fee there, and the integrator sets `platformFeeBps` + `feeAccount`.
   - https://developers.jup.ag/docs/swap/index.md
3. **API key: the docs contradict each other, and the live API works without one.**
   - The overview says "All endpoints require an API key".
   - The rate-limits page lists a Keyless tier: 0.5 RPS, no key needed, and a separate `/execute` limit of 20 RPS keyless, 50 Free, 100 paid.
   - My live `/order` calls without a key returned HTTP 200 today.
   - https://developers.jup.ag/docs/portal/rate-limits.md
   - https://developers.jup.ag/docs/portal/api-keys.md
4. **The `/order` transaction is unsigned and versioned (v0).**
   - The docs say "The transaction returned by `/order` is unsigned… versioned transaction (v0)." Sign it, then `POST /execute {signedTransaction, requestId}`.
   - JupiterZ routes get the market maker's signature during `/execute`, so the app cannot send these transactions through its own RPC.
   - A live check matched: 1 signature slot, all zero, prefix `0x80`, 596 bytes.
   - https://developers.jup.ag/docs/swap/order-and-execute.md
5. **How the referral fee works on `/order`:**
   - `referralFee` must be 50 to 255 bps.
   - Jupiter keeps 20% of it, and charges no separate platform fee while a referral is active.
   - You need a `referralTokenAccount` for each fee mint. The fee mint is picked by priority: SOL first, then stablecoins, then LSTs.
   - If the token account for the fee mint is missing, the swap still runs but you collect no fee.
   - Sources: the same order-and-execute page, and https://developers.jup.ag/docs/openapi-spec/swap/v2/swap.yaml
6. **A wrong referral account breaks the swap entirely.** Passing an account that was never initialised returned HTTP 400: "Please check that referralAccount is initialized under REFER4ZgmyYx9c6He5XfaTMiGfdLwRnkV4RPp9t9iF3 for project DkiqsTrw1u1bYFumumC7sCG2S8K25qc2vemJFHyW2wJc". So a bad constant means Earn fails, not that the fee is skipped. (Live probe.)
7. **`/build` fee:** `platformFeeBps` can be 0 to 10000, and `feeAccount` is required when it is above zero. `/execute` is not available for `/build`, so the client assembles and sends its own transaction. (swap.yaml)
8. **Jupiter's own fee on SOL→JitoSOL is 0 bps today.** Live: `platformFee.feeBps: 0`, `feeMint` = wSOL. Its docs table says pegged pairs (LST to LST) are 0, but SOL to LST is not listed explicitly, so this is observed, not documented.
9. **JitoSOL APY:**
   - `GET https://kobe.mainnet.jito.network/api/v1/stake_pool_stats` (POST also works). `apy[].data` is a fraction; the latest is 0.04814, i.e. 481 bps.
   - Short date ranges are not smoothed; ranges over 10 epochs use a moving average. The Jito docs page returned 403 to my fetch; the GitHub README confirms the endpoint.
   - Sanctum's `extra-api.sanctum.so/v1/apy/latest` returned `0.0` for JitoSOL, so I don't use it.
   - https://github.com/jito-foundation/kobe and https://www.jito.network/docs/jitosol/jitosol-liquid-staking/for-developers/stake-pool-api/
10. **The Jito stake pool, read and decoded from chain** (`Jito4APyf642JPZPx3hGc6WWJ8zPKtRbRs4P815Awbb`, owned by the SPL stake-pool program `SPoo1Ku8WFXoNDMHPsrGSTSG1Y47rzgn41SLUNakuHy`; fields from https://github.com/solana-program/stake-pool `program/src/state.rs`):
    - SOL deposit fee 0, and anyone can deposit.
    - Referral share on deposits 0%, so a direct deposit earns the protocol nothing.
    - Withdrawal fee 0.1% (for both SOL and stake withdrawals); pool management fee 4% of rewards.
    - Exchange rate 1.30417 SOL per JitoSOL.
    - At the same moment, Jupiter quoted 1 SOL → 0.767327 JitoSOL, against 0.766770 from a direct deposit. With no fee, Jupiter was about 0.07% better.

## Chosen API and why

I chose Swap V2 `/order` + `/execute` with `referralAccount` + `referralFee`:
- It is the path Jupiter recommends and the current one; Ultra and v1 are deprecated.
- `/order` returns a complete unsigned v0 transaction, which fits the existing `WalletBridge.signTransactions` (it returns signed bytes).
- It has the best price (RFQ competes), and Jupiter handles landing and slippage.

`/build` would allow a fee below 50 bps and without Jupiter's 20% cut. But it uses Metis only, and the app would have to compile the v0 transaction and look up address tables itself in Dart. I suggest it only if you want a fee under 0.5%.

A direct `DepositSol` into the stake pool is cheaper for the user (0% deposit fee) and needs no API. But it pays the protocol nothing, so it doesn't match a fee-based plan. It is a reasonable fallback for a fee-free mode.

## What I built

- **`available`:** true only when `cluster == 'mainnet-beta'` (the cluster can be injected for tests). `buildStake` and `buildUnstake` throw `StateError` off mainnet.
- **`buildStake` / `buildUnstake`:**
  - They call `/order` and return the unsigned v0 bytes.
  - Before returning, they check: the transaction is v0, the owner is a required signer, and the mints and input amount match the request.
  - They store the `requestId`, keyed by the message bytes, which signing does not change.
- **`buildStake` has an optional `receiver`** (for example the vault PDA). Jupiter then sends JitoSOL to that address's token account and creates the account if needed. I have not confirmed Jupiter accepts a PDA address; test it on mainnet with a small amount first.
- **`execute(signedBytes)`:** a new method outside `EarnService`. It posts to `/execute` and returns the transaction signature, or throws `JupiterException(code)`.
- **`orderFor(tx)`:** returns the order details for display: `outAmount`, `feeBps`, `router`, and `referralApplied` (false when Jupiter fell back to its default fee).
- **`apyBps()`:** reads Kobe and caches the value for 30 minutes.

## One-time setup for the protocol

1. Create a `referralAccount` under Jupiter's project `DkiqsTrw1u1bYFumumC7sCG2S8K25qc2vemJFHyW2wJc`, with the treasury as partner. Use `@jup-ag/referral-sdk` `initializeReferralAccountWithName` or https://referral.jup.ag/.
2. Create a referral token account for wSOL (`So111…112`) with `initializeReferralTokenAccountV2`. That is the fee mint for SOL↔JitoSOL in both directions. Adding JitoSOL and USDC accounts is optional.
3. Set `--dart-define=JUP_REFERRAL_ACCOUNT=…` (the constant has a TODO for the treasury). The rate is `kJupiterReferralFeeBps = 50`, also marked TODO. An empty account turns the fee off.
4. Create an API key in Portal limited to the Swap product, with firewall rules, and pass it as `--dart-define=JUP_API_KEY=…`. It ships inside the APK; keyless works but only allows 0.5 RPS.
5. Claim collected fees from time to time through the Referral dashboard or SDK.

## Risks

- **JitoSOL depeg:** the market price can fall below the pool rate. Redeeming through the pool always pays the rate minus 0.1%, but instant SOL is limited by the pool's reserve; the other route is a stake account that unstakes over about one epoch.
- **Contract risk:** the stake pool, Jupiter and the DEX on the route (the live route used AlphaQ) are all contracts that could fail.
- **Swap slippage:** Jupiter sets slippage per trade by default. If you pass `slippageBps`, the order switches to "manual" mode. The quote is only valid until `lastValidBlockHeight`, or `expireAt` for RFQ routes, so sign right away.
- **The fee's cost to the user:** 50 bps is about 38 days of yield at 4.81% APY, and a stake plus unstake costs about 2.5 months. At 255 bps one swap costs about 6.4 months of yield. For small or short positions this can wipe out the yield; a direct `DepositSol` costs 0%.
- **Configuration:** a wrong referral account gives HTTP 400 and Earn stops working. A missing wSOL token account means the swap runs but no fee is collected (`referralApplied=false`).
- **Dependency:** Jupiter deprecated its last two APIs; expect V2 to change too. The API key is exposed in the APK.
- **Heirs receive JitoSOL, not SOL:** the payout carries the same depeg exposure.

## Revenue per $1M swapped (estimate)

| Setup | Fee | Gross | Protocol keeps |
|---|---|---|---|
| `/order`, minimum fee | 50 bps | $5,000 | **~$4,000** (Jupiter keeps 20%) |
| `/order` | 100 bps | $10,000 | **~$8,000** |
| `/order`, maximum fee | 255 bps | $25,500 | **~$20,400** |
| `/build` (not built) | 10 bps | $1,000 | ~$1,000 |
| `/build` (not built) | 25 bps | $2,500 | ~$2,500 |
| `DepositSol` | 0 | $0 | $0 |

Volume that is both staked and unstaked pays twice. The program's 2–5% payout fee is separate, and it applies to a vault balance that grows by about 4.8% a year.

## Decisions for you

- **Contract change in `rails.dart` (your file):**
  - Add `Future<String> submit(Uint8List signed)` to `EarnService`.
  - Add `String? receiver` to `buildStake`.

  Today both exist only on `JupiterEarn`.
- **Fee level and setup:** pick the referral fee rate (50 to 255 bps), or switch to `/build` if you want it below 50 bps.
