# Product

<!-- impeccable:product-schema 1 -->

> Written from README.md, docs/HOW_IT_WORKS.md and the v2 brand book (docs/brand/v2) on 2026-10-05, without a live interview. Facts below come from those files; lines marked _(inferred)_ are assumptions to confirm.

## Platform

android

Flutter app for the Solana Seeker (Android), also built for web (phone-shaped frame in a desktop browser, wallets through the Wallet Standard). Material 3 governs structure; the brand themes it.

## Users

- **Owner.** A Seeker user who self-custodies SOL and USDC and wants the funds to reach family if they go silent, stay frozen if they are coerced, and stay safe if the phone is lost. Opens the app daily or every few days to check in (one biometric touch, about 3 seconds), less often to edit a plan, deposit or withdraw.
- **Beneficiary.** Someone named in an owner's release or vesting plan. Uses **Family Circle** to see each owner's liveness and tier countdowns, to release a due tier, claim vested installments, or route a private payout. May hold no SOL.
- **Guardian** (optional). A trusted wallet that can freeze a vault and co-sign an early unlock.
- **Under duress** _(context, not a user)_: an attacker may be watching the screen. The duress PIN opens an app that must look exactly like a normal session.

## Product Purpose

Deadman is a vault on Solana controlled from the Seeker. It covers three threats: **silence** (stop checking in and the release plan's tiers fire in order), **coercion** (a duress PIN silently signs a lockdown), and **loss** (the phone holds only a guard key that can pulse and lock, never move funds). Vesting plans release SOL or USDC in installments next to inheritance plans. Success: the owner checks in without thinking about it, and a beneficiary always knows exactly what will happen and when.

## Positioning

Execution on the phone: a guard key in secure storage makes check-ins and the duress path need no wallet prompt and no SOL; duress is a time-lock, not a decoy wallet; tiered release instead of one trigger; optional private delivery through Cloak or shielded Zcash; Family Circle shows beneficiaries what will happen without the owner present.

## Operating Context

- The daily check-in: open, PIN, **Check in**, fingerprint. Usually seconds, often one-handed. The Pulse tab is only this: the ring, the countdown and the button. Release plans live on their own screen, opened from Pulse's app bar.
- Reminder notifications when a check-in is due.
- Mobile Wallet Adapter to Seed Vault for owner transactions; Kora sponsor/paymaster for fee-less guard actions and USDC network fees.
- Keeper bot and beneficiaries execute due tiers; anyone can skip a tier that cannot pay after the grace period.
- Devnet build for demos; private rails and Earn are mainnet-only.

## Capabilities and Constraints

- Up to 8 tiers per release plan and up to 8 schedules per vesting plan; SOL and USDC per plan.
- Rails: Solana (2% release fee), Cloak and Zcash (3%). Free to use otherwise, or an account-wide monthly plan that waives the release fee. UI copy reads the fee from the on-chain FeeSchedule wherever it can; static copy says 2% and 3%.
- Lockdown blocks withdraw, edit and close; it never stops inheritance or vesting releases.
- Panic (Security tab) locks every plan this phone guards and names any it could not lock.
- Duress sessions disable receiving profiles and private routing, and must not reveal the lock.
- Unaudited hackathon build on devnet. Do not put real funds in it.

Terminology: **Pulse** / **check in**, **release plan**, **tier**, **vesting plan**, **installment**, **Family Circle**, **guard key**, **duress PIN**, **Panic lockdown**, **rail**, **claim code**, **Earn**.

## Brand Commitments

- Name **Deadman**; tagline **"Check in, or check out."** Descriptor: "A dead man's switch for your Solana wallet." Splash line: "Proof of life, on Solana."
- Mark: an 11×11 pixel skull, pulse (#3EF5A8) on void (#0A0B0D); inverse is void on pulse. Wordmark: pixel DEADMAN, 7 cells tall. Both are drawn from the grids in `lib/ui/widgets/brand/pixel_art.dart`, never from a font or a bitmap.
- One skull, four moods: Alive (pulse), Missed a check-in (amber), Silent past a release tier (red), Plan fully released (grey). The pixel cast: Heart (check-ins), Skull (missed check-ins), Tombstone (a release tier is due), Ghost (plan fully released).
- The v2 brand book (docs/brand/v2, pages 1-13) is the binding visual reference; pages 10-13 are the app mockups. DESIGN.md records it. The v1 cyan two-half mark and docs/brand/logos are retired.
- Voice: plain and exact, with one dark joke allowed per surface (the tagline, a sticker). Controls name their action ("Check in", "Check in to stop", "Release this tier"). Numbers are stated, never rounded into reassurance. No hype, no emoji.

## Evidence on Hand

- Real product copy in the app and README; flows and fees in docs/HOW_IT_WORKS.md; prior art and judging notes in docs/JUDGING.md.
- No customers, testimonials, audit report or mainnet track record. Never imply any of them.

## Product Principles

1. **Calm until it matters.** Status color appears only when something needs attention; the default state is quiet pulse green.
2. **State the stakes exactly.** Every countdown, amount, address and fee is shown in full precision, in mono.
3. **The duress session is indistinguishable.** No UI may reveal that a lock was sent.
4. **One touch to prove life.** The check-in is the only job of the Pulse tab; the ring fills the screen and the button sits under it.
5. **Beneficiaries are users too.** Family Circle explains what will happen without the owner present.
6. **No vanity counters.** The app does not count streaks or reward check-ins; it shows time left and what happens next.

## Accessibility & Inclusion

- 48dp touch targets; text follows the system font scale. _(inferred from Android baseline)_
- Status is never color-only: every status color comes with a sticker word, a skull face and a countdown.
- Contrast: bone, haze, dust and ash on void and grave all pass 4.5:1; Silkscreen is never used below 9.5 or for anything a person must read exactly.
- Pixel figures are decorative unless they carry meaning on their own; then they take a semantic label.
