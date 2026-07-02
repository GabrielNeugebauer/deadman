> Research report produced 2026-10-02 while building the rail. Sources are linked inline.

I added the Zcash rail as `ZcashRoute` using the NEAR Intents 1Click API. The beneficiary's ZEC can land in a shielded address, as long as they give a unified `u1` address. `dart analyze lib/rails test/rails` reports no issues and all 20 tests in `flutter test test/rails/zcash_route_test.dart` pass.

**Files** (no other files touched, no new packages):
- `lib/rails/zcash_route.dart`
- `test/rails/zcash_route_test.dart`

**Live calls I made on 2026-10-02:** one `GET /v0/tokens`, six dry quotes, one real quote and two status checks. The real quote created deposit address `E5RdW4ip1B4wx1Loy83zr2dVadYywJazHvB22JBKq1Dg`. I sent no funds to it, and the address goes inactive on 2026-10-05. The responses I captured are used as test data, so the tests check signatures against real 1Click output. The tests themselves make no network calls.

## Verified facts (all checked 2026-10-02)

| Fact | Source |
|---|---|
| Base URL is `https://1click.chaindefuser.com`. Endpoints: `POST /v0/quote`, `POST /v0/deposit/submit` (optional), `GET /v0/status?depositAddress=…`, `GET /v0/tokens` | https://docs.near-intents.org/integration/distribution-channels/1click-api/quickstart/making-a-request.md and https://1click.chaindefuser.com/docs/v0/openapi.yaml |
| A partner token (JWT) is **optional**. It goes in `X-API-Key` or `Authorization: Bearer`. Without it the docs say 1Click adds 25 bps; my live quotes without a token were accepted (HTTP 201) and 1Click added 20 bps | https://docs.near-intents.org/integration/distribution-channels/1click-api/authentication.md and live calls |
| Required quote fields: `dry`, `swapType`, `slippageTolerance` (in bps), `originAsset`, `depositType`, `destinationAsset`, `amount` (whole-number string in base units), `refundTo`, `refundType`, `recipient`, `recipientType`, `deadline` (ISO time). Optional fields include `appFees`, `referral`, `confidentiality` and `quoteWaitingTimeMs` | OpenAPI `QuoteRequest` |
| The deposit address comes back in `quote.depositAddress`. For Solana input it is a base58 Solana address. A dry quote (`dry: true`) has no deposit address | OpenAPI `Quote` and live call |
| Status values: `PENDING_DEPOSIT`, `KNOWN_DEPOSIT_TX`, `PROCESSING`, `SUCCESS`, `INCOMPLETE_DEPOSIT`, `REFUNDED`, `FAILED`. An unknown address returns 404 | making-a-request.md and live call |
| Deposit notification: `POST /v0/deposit/submit {txHash, depositAddress}`. It is optional and only speeds things up | OpenAPI |
| 1Click signs every quote. The signing key `reYaWhvwu8Jzo3WUM3zhn6VrhuMEF4eADL17qtRVifc` comes from the TypeScript SDK `@defuse-protocol/one-click-sdk-typescript` 0.1.26, not from the docs. My Dart port checks real quotes correctly and rejects a quote with a swapped deposit address | https://docs.near-intents.org/integration/distribution-channels/1click-api/verify-quote-signature.md and the npm package |
| Asset IDs: native SOL `nep141:sol.omft.near` (9 decimals); Solana USDC (mint `EPjF…Dt1v`) `nep141:sol-5ce3bf3a31af18be40ba30f721101b4341690186.omft.near` (6); Solana USDT `nep141:sol-c800a4bd850783ccb82c2b2c7e84175443606352.omft.near` (6); ZEC `nep141:zec.omft.near` (8) | Live `GET /v0/tokens` |
| Costs seen in quotes: Zcash withdrawal fee 0.00032 ZEC; refund fee about 0.087 SOL-equivalent on SOL input and **about 0.32 USDC on USDC input**; estimated time about 135 s | Live quotes |

## Can the payout land in a shielded address?

**Yes, to a unified `u1` address.** Live quotes with a `u1` recipient were accepted, both dry and real. A real-funds test on 2026-09-27 sent ZEC from NEAR Intents to a `u1` address, and it arrived in the shielded pool (the PR's on-chain readout shows the full amount entering it). That test used near.com's withdrawal through the same bridge, not a 1Click swap (ZecHub PR #2245, merged 2026-09-29: https://github.com/ZecHub/zechub/pull/2245).

One source disagrees: SwapKit's docs say NEAR Intents cannot quote `u1` addresses (https://docs.swapkit.dev/spotlights/chain-specific-guides/zcash-shielded-and-unified-addresses, undated). My live quotes contradict it.

Older Sapling `zs` addresses are not supported, per SwapKit. The route only accepts `u1…` and rejects `t1`/`t3`/`zs` before making any network call.

I did not need an alternative such as Maya or THORChain, because NEAR Intents works for this.

## Fees (matters for the 2%/5% plan)

- The API supports app fees: `appFees: [{recipient, fee}]`, where `fee` is a whole number of bps taken from the input. `recipient` must be a NEAR Intents account, either named or the 64-hex form of an Ed25519 public key (https://docs.near-intents.org/integration/distribution-channels/1click-api/fee-config.md).
- **What I observed live, without a token:** the `fee` you send is the **total** charge, and it is split 50/50 with 1Click. Sending 200 gave Deadman 100 bps; 400 gave 200; 500 gave 250. The total cap is 500 bps. The docs say that without a token you keep your full fee and 1Click adds 25 on top, which is not what happened.
- **Consequences:**
  - A 2% fee for Deadman through this rail costs the beneficiary 4%.
  - A 5% fee for Deadman through this rail is impossible; the most Deadman can get is 2.5%.
  - Fees land as balances inside NEAR Intents, not in a Solana wallet.
  - My recommendation: charge the 2–5% protocol fee on-chain in the Deadman program when a rule fires, and keep this rail's fee small.
- Settings at the top of the file:
  - `zcashAppFeeBps = 100`.
  - `zcashAppFeeRecipient = ''` with `// TODO(treasury)`. While it is empty, no `appFees` are sent.

## How the route works

- **`available`:** true only when the cluster is `'mainnet-beta'`. Cluster, RPC URL, HTTP client and clock can be passed in, which is how the tests run.
- **`quote()`:**
  - Real quote, exact input, 1% slippage, 30-minute deposit window.
  - `refundTo` is the claim key, and refunds go back to the origin chain (Solana).
  - It checks the 1Click signature, then checks that the returned refund address, recipient, assets and amount match the request.
  - `estimate()` is an extra dry-run version for price previews; it reserves no deposit address.
- **`execute()`:**
  - It refuses if the quote refunds to a different key or has expired.
  - SOL: a plain transfer of `amountIn`.
  - USDC/USDT: creates the deposit address's token account if missing, then a `transferChecked`.
  - The claim key signs; the transaction goes out over raw JSON-RPC to the RPC URL.
  - It then calls `deposit/submit` (a failure there is ignored) and returns the deposit address as the tracking id.
- **`status()`:** polls `/v0/status` and returns the status string.
- **Partner token:** read from `String.fromEnvironment('ONECLICK_JWT')`. A token built into the app can be extracted from it; use a small server proxy if you get a partner key.
- **Funds the claim key must keep back:**
  - SOL: leave at least 5,000 lamports for the transaction fee.
  - Small SOL deposits to a fresh deposit address may fail below the about 0.00089 SOL rent minimum.
  - USDC: the claim key also needs about 0.00204 SOL to create the deposit address's token account, plus the transaction fee.

## Privacy: what is still linkable

**Public:**
- The vault paying the claim key on Solana.
- The claim key paying the 1Click deposit address on Solana, with the amount and time.
- **The NEAR Intents explorer publicly maps the deposit address to the recipient `u1` address and the amounts.** I took the test `u1` straight from that explorer.
- So anyone can link vault → claim key → `u1` address. Refunds go back to the claim key in public.
- On the Zcash side, the amount entering the shielded pool at that time is visible, so amount and timing can be matched.

**Not public:** the beneficiary's shielded balance and anything they do with the ZEC afterwards. The `u1` string reveals nothing more if the beneficiary uses a fresh, shielded-only `u1` for each payout. They should, so the public link ends at a single-use address.

**Seen by operators:**
- 1Click/NEAR see the IP address, claim key, `u1` address and amounts, and can hold funds for compliance (one such hold was reported in 2026).
- The Solana RPC provider sees the IP address and the claim key.

**Confidential mode:** `confidentiality: "basic"` returned 401 "User authentication is required for confidential intent quotes", so it is not usable without a partner token. The claim key pays its own fees, so it is never linked to a funding wallet.

## Still unverified

- A full 1Click swap with real funds to a `u1` address. Only near.com's withdrawal over the same bridge was tested by someone else.
- What happens with a `u1` that also contains a transparent receiver. It may be paid transparently, so beneficiaries should use a shielded-only `u1`.
- How fees split with a partner token or a custom deal (the docs and live behaviour already disagree), and whether `confidentiality` works with a partner token.
- Minimum amounts. The bridge publishes a 0.01 ZEC minimum, but quotes for about 0.0034 ZEC were accepted.
- That 1Click credits USDC sent to the token account created for the deposit address. This is the standard pattern but I did not test it.
- The quote signing key comes from the SDK, not the docs; I confirmed it only against real quotes.
- Whether new shielded ZEC lands in the "Ironwood" pool instead of Orchard. This comes only from the ZecHub PR.
