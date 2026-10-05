# Deadman — Judging Report (2026-10-02)

Four judge passes (architect, ecosystem researcher, mobile/Seeker, DeFi/business) plus Colosseum Copilot evidence.

## Hackathon facts (verified 2026-10-02)

| Event                                                                                        | Deadline                                                                                                                                                            | What qualifies                                                                                                                                                          | Judged on                                                                                                       |
| -------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------- |
| [Colosseum Crypto World's Fair](https://colosseum.com/worldsfair/resources)                  | 2026-10-13 06:59 UTC (Oct 12 Americas)                                                                                                                              | One product per builder ([FAQ](https://colosseum.com/hackathon#h-faq-15)); tracks per chain: Solana, Ethereum, Hyperliquid, Base, Tempo, Arbitrum, **Zcash**, Robinhood | Founder-market fit, insight, product + execution, market size ([FAQ](https://colosseum.com/hackathon#h-faq-12)) |
| [Solana Mobile CLOCK IN](https://solanamobile.com/blog/clock-in-the-solana-mobile-hackathon) | 2026-10-08                                                                                                                                                          | APK + GitHub + demo video + deck; winners must publish on dApp Store                                                                                                    | Stickiness/PMF, UX, innovation, presentation. $125k USDC (10 places) + $10k SKR track                           |
| Zcash                                                                                        | = World's Fair Zcash track                                                                                                                                          | Build on Zcash (Android Wallet SDK, librustzcash, Zebra/lightwalletd)                                                                                                   | —                                                                                                               |
| Cloak                                                                                        | **No live Cloak hackathon/bounty found.** Cloak is live on mainnet ([cloak.ag](https://www.cloak.ag/)), SDK is TypeScript `@cloak.dev/sdk` (snarkjs), no mobile SDK | —                                                                                                                                                                       |

## Prior art (Colosseum Copilot)

Copilot returned 15+ near-identical dead-man/inheritance projects — 11 of the top 15 matches from Frontier alone — **none awarded**:
[Bequest](https://colosseum.com/projects/explore/bequest), [Terminus](https://colosseum.com/projects/explore/terminus-1), [Afterlife](https://colosseum.com/projects/explore/afterlife), [Relic](https://colosseum.com/projects/explore/relic), [Herita](https://colosseum.com/projects/explore/herita), [Legacy Protocol](https://colosseum.com/projects/explore/legacy-protocol), [Lazarus Protocol](https://colosseum.com/projects/explore/lazarus-protocol), [HEIRLOOM](https://colosseum.com/projects/explore/heirloom), [Solwill](https://colosseum.com/projects/explore/solwill), [Welt Protocol](https://colosseum.com/projects/explore/welt-protocol) (Radar), [Keep Sake](https://colosseum.com/projects/explore/keep-sake) (Renaissance)…

Closest to the "improved" Deadman:

- [SolGuard](https://colosseum.com/projects/explore/solguard-5) (Frontier, no award): SOL vault, amount-scaled withdrawal timelock, duress key that looks normal but forces a 30-day wait, defend-only guardians (2-of-3), heartbeat inheritance. Anchor + **Next.js web**.
- [Twin Keys](https://colosseum.com/projects/explore/twin-keys) (Cypherpunk, no award): decoy wallet for coercion.

What does win in the security lane: [Unruggable](https://colosseum.com/projects/explore/unruggable-3) (hardware wallet, Cypherpunk Grand Prize), [Verve](https://colosseum.com/projects/explore/verve) (guardian recovery, Radar 4th Infra), [One-Time Action Codes](https://colosseum.com/projects/explore/one-time-action-codes-1) (Breakout 4th Infra, demoed on Saga/Seeker).

**Lesson:** the mechanism is solved and crowded. Winners shipped a _product people touch_ (hardware, phone-native UX), not another vault contract with a web form.

## Scores — idea as written

| Judge                           | Colosseum | Seeker CLOCK IN | Zcash | Cloak |
| ------------------------------- | --------- | --------------- | ----- | ----- |
| Architect (technical soundness) | 5         | 5               | —     | —     |
| Researcher (crowdedness/fit)    | 3         | 5               | 1     | 2     |
| Mobile (Seeker fit, stickiness) | —         | 5               | —     | —     |
| DeFi (business model)           | 3         | —               | —     | —     |

## Architect — key flaws

1. **"Allowance" doesn't exist for native SOL** and an SPL delegate can be revoked by a thief as easily as by the owner. Only a program-owned vault protects against theft; delegate = inheritance only.
2. **Duress PIN → "safe wallet"** just moves the coercion target: the attacker makes you open the safe wallet next. Duress must move funds into a _time-locked_ state the victim can't undo quickly, and must not require a visible Seed Vault prompt.
3. **2% of the estate at death** is bad optics, lumpy revenue, and a reason to avoid the product.
4. Keepers are unnecessary: trigger is permissionless and payouts are fixed in state, so front-running is harmless; heirs are the natural keepers.
5. Yield via CPI (Kamino/Marginfi) inside the vault adds CPI risk and withdraw delays at trigger time — hold an LST (JitoSOL) as a plain token instead.
6. "Scorched earth" phone wipe requires device-owner provisioning on modern Android — not shippable in a dApp Store app this week.

**Core design insight to keep:** a **guard key** — a hot, biometric-gated device key that can only `heartbeat` and `lockdown`, never withdraw. Daily check-ins and the duress PIN then need no Seed Vault prompt, and a stolen guard key is harmless.

## Mobile — Flutter feasibility

- MWA: `solana_mobile_client` 0.1.2 (espresso-cash; last published 2025-05-25) — stale; `solana` 0.32.0+1 (2026-04-10) for RPC/tx building. Seed Vault is reached only through MWA → Seed Vault Wallet (correct by design).
- `local_auth` 3.0.2, `flutter_secure_storage` 11.2.0, `workmanager` 0.10.10, `flutter_local_notifications` 22.3.1, `flutter_riverpod` 3.4.3, `go_router` 18.0.2.
- Background reminders under Doze are inexact (fine — the on-chain timer is the source of truth).
- SGT check: Token-2022 mint group membership, per [Solana Mobile docs](https://docs.solanamobile.com/recipes/general/detecting-seeker-users); SGTs are transferable, so key uniqueness on the SGT mint address.
- Stickiness problem: a proof-of-life app's core loop is "nothing happens." Needs a daily reason to open.

## DeFi — business model (estimates)

1k users × $5k = $5M TVL. At an assumed ~1%/yr trigger rate × 2% fee ≈ **$1k/yr**. 5% of JitoSOL yield at an assumed ~7% APY ≈ **$17.5k/yr**. A $3/mo subscription ≈ **$36k/yr**. → Subscription (payable in SKR with discount) is the primary model; trigger fee should be small and capped, or dropped.

## Recommendation

Reposition from "inheritance app" (graveyard) to **Deadman — the self-custody safety net for Seeker**, competing on mobile execution where SolGuard (web) didn't:

- **One vault, three threats**: silence (inheritance), coercion (duress PIN → silent lockdown), loss (guardian recovery).
- **Guard key** in the phone's secure storage + biometrics → 3-second daily "Pulse".
- **Family Circle**: heirs/guardians see your liveness ("Mom checked in 2h ago") — a social loop that gives _them_ a reason to open the app.
- **SKR**: Deadman Plus subscription paid in SKR (more heirs, guardian, shorter intervals).
- Roadmap only: Cloak private payout to heirs, Zcash nLockTime-rollover switch, DAO signer recovery.
- Cut: phone wipe, yield CPI, cross-chain, keeper network.
