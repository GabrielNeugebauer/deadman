# Deadman pitch narrative (judges' deck)

Written 2026-10-04. Replaces the slide content of [`../PITCH_OUTLINE.md`](../PITCH_OUTLINE.md), which still describes the removed Plus/SKR subscription.

- **Targets:**
  - Solana Mobile CLOCK IN: APK + GitHub + demo video + deck, due **2026-10-08**. Judged on stickiness/PMF, UX, innovation and presentation. $125k USDC across 10 places, plus a $10k SKR track ([`../JUDGING.md`](../JUDGING.md)).
  - Colosseum Crypto World's Fair, Solana track: due **2026-10-13 06:59 UTC** (Oct 12 in the Americas). One product per builder. Judged on founder-market fit, insight, product and execution, and market size ([`../JUDGING.md`](../JUDGING.md)).
- **Shape:** 15 slides. The arc is problem, insight, product, three demo moments, then the startup slides. Slides 5 to 7 follow the beats of the 90-second video in [`../DEMO_SCRIPT.md`](../DEMO_SCRIPT.md), so the deck and the video tell the same story.
- **Rules for every slide:**
  - No invented numbers. A bracketed `[...]` is a placeholder for the founder to fill in or cut. All placeholders are listed at the end.
  - Every external number cites a doc in this repo. Revenue figures are labelled **estimate**.
  - Claim on a slide only what the build does. Private rails and Earn are mainnet-only and have not moved real funds yet.
- **Visual language** (from `lib/ui/theme.dart`):
  - Colors: background `#0A0B0D`, cards `#14161A` with a `#262A31` hairline border and 20 px radius.
  - Type: Space Grotesk 700 for headlines, Inter for body text.
  - Semantic colors, used the way the app uses them: **alive green `#3DF5A7`** for the pulse, healthy states and the primary accent; **amber `#FFB547`** for a missed check-in or a due tier; **red `#FF4D5E`** for duress and lockdown; **violet `#9B7BFF`** for private rails and Family Circle; **muted `#8A8F98`** for footnotes and sources.

---

## Positioning line options

1. **"The self-custody safety net for Seeker."** The current line, used in the README and the app. Safe and clear, and it names the platform.
2. **"One vault. Three threats."** Works as a subline. It pairs with "Silence. Coercion. Loss."
3. **"Self-custody that outlives you."** Emotional. It leads with inheritance, though, which is the crowded part of the category.
4. **"Check in daily. Release on silence. Lock on duress."** Explains the mechanism in one line. Good for the dApp Store listing.
5. **"Your keys, your rules, even when you can't answer."** Broad enough to cover vesting and USDC payouts as well as inheritance.

Recommendation: lead with 1, use 2 as the subline, and close the deck on 5.

---

## Slide 1: `title`

**Purpose:** Name the product, state the promise, and open the founder-market-fit beat.

**On slide:**

- **Headline:** Deadman: the self-custody safety net for Seeker
- **Body:** One vault. Three threats: silence, coercion, loss.
- **Footer:** [Founder name] · [one-line founder background] · Solana Mobile CLOCK IN · Colosseum Crypto World's Fair (Solana track)

**Visual:** A Seeker in hand showing the Pulse tab, with the "I'm alive" button glowing alive green.

**Speaker notes:**
I'm [Founder name]. [One or two sentences on why you, personally, care: an incident you saw, your background, a person you'd want covered. Write this yourself; Colosseum scores founder-market fit.] Deadman is a vault on Solana that you control from your Seeker. If you go silent, it releases your crypto to the people you chose, in the order you chose. If someone forces you to open it, it locks itself. A lost phone can't move a single lamport. Deadman is free to use; we earn only when funds actually move.

---

## Slide 2: `problem`

**Purpose:** Show that self-custody has three failure modes that hardware key storage doesn't address.

**On slide:**

- **Headline:** Self-custody fails in three quiet ways
- **Body:**
  - **Silence:** you die or can't respond, and your family can't reach the keys.
  - **Coercion:** someone forces you to unlock and send.
  - **Loss:** the phone is gone.
- **Footer (optional, only if sourced):** [sourced figure on crypto lost to death or lost keys — source] · [sourced count of physical "wrench" attacks — source]

**Visual:** Three cards, each with an icon: a clock for silence (amber), a hand for coercion (red), a phone for loss (muted).

**Speaker notes:**
The Seed Vault makes key theft by malware much harder. It does nothing when you die, when someone holds a wrench to you, or when your family simply can't reach your keys. The tools that exist are all-or-nothing: one trigger, and everything moves. That makes setting one up feel risky, because a long trip shouldn't hand over the estate. So people don't set anything up. [If you have a sourced statistic for either footer line, say it here. Otherwise describe the problem without a number; don't improvise one.]

---

## Slide 3: `insight`

**Purpose:** Present the core design insight: split authority so the key used every day can only defend.

**On slide:**

- **Headline:** A phone key that can only defend
- **Body (table):**

| Key                     | Lives in                    | Can                     | Never                |
| ----------------------- | --------------------------- | ----------------------- | -------------------- |
| **Owner**               | Seed Vault                  | move funds, edit plans  | —                    |
| **Guard**               | phone, behind a fingerprint | check in, lock          | withdraw, edit plans |
| **Guardian** (optional) | a trusted person's wallet   | lock, co-sign an unlock | move funds           |

- **Caption:** Daily life needs no wallet prompt. A stolen phone takes nothing.

**Visual:** The Guard row highlighted in alive green, with "Never" in red.

**Speaker notes:**
This is the insight the whole product hangs on. Most dead-man switches make you sign with your main wallet for every check-in, so people stop checking in; the alternative, a hot key that can drain funds, is worse. We split authority on-chain. The guard key lives in Android secure storage and the program lets it only check in and lock; a test proves it can't move funds. That's why a check-in is a fingerprint and the duress path is silent. And a guard key alone can't keep a plan alive forever: it stops counting 365 days after your last wallet-signed action (fix for audit finding M-1, `docs/security-audit-2026-10-03.md`).

---

## Slide 4: `product`

**Purpose:** Give the full product at a glance before the demo.

**On slide:**

- **Headline:** One vault, release plans, a daily habit
- **Body:**
  - **Pulse:** fingerprint check-in, no wallet prompt
  - **Release plans:** up to 8 ordered tiers; SOL, USDC or any token
  - **Duress PIN:** silent on-chain lockdown
  - **Family Circle:** heirs see "checked in 2h ago"
  - **Vesting:** linear, with a cliff
  - **Private delivery:** Cloak or shielded ZEC

**Visual:** Three phone screenshots side by side: Pulse tab, release-plan editor, Family Circle.

**Speaker notes:**
One Anchor program holds the funds; everything else signs, schedules or routes. You can run several named plans, such as "Kids" or "Emergency fund". Each one is up to eight tiers, and each tier sends a fixed amount or a percentage of one asset to one person after a set period of silence. Beneficiaries open the same app and see your liveness and their own tiers. That gives them a reason to install it, and it gives you a reason to keep checking in. Everything on this slide runs in the program today. Private delivery and Earn need a mainnet build.

---

## Slide 5: `demo-pulse`

**Purpose:** Demo moment 1: the daily check-in is effortless and costs the user nothing.

**On slide:**

- **Headline:** Three seconds, one fingerprint, no wallet prompt
- **Big numbers:**
  - **~3 s** per check-in
  - **0 SOL** needed on the phone: a Kora paymaster pays guard-key fees
  - **~0.0018 SOL** for a year of daily pulses at the 5,000-lamport base fee
- **Source line:** `docs/HOW_IT_WORKS.md` §2, `docs/KORA.md`, `docs/PITCH_OUTLINE.md` §3

**Visual:** Video still from beat 0:17–0:27: thumb on the sensor, the tick ring refilling, and the countdown resetting.

**Speaker notes:**
Watch the screen: no Seed Vault pop-up appears. The device's guard key signs the check-in, and the ring refills. Each pulse restarts every pending tier's clock. The phone doesn't even need SOL: a Kora node, the Solana Foundation's paymaster, pays the fee, but only for guard-signed check-ins and locks, behind a rate-limited gateway. This is our answer to the stickiness problem, because a proof-of-life app's core loop is "nothing happens". Family members who can see "checked in 2h ago" give everyone a reason to open the app.

---

## Slide 6: `demo-duress`

**Purpose:** Demo moment 2: coercion is answered with a silent time-lock, not a decoy wallet.

**On slide:**

- **Headline:** The duress PIN locks the vault silently
- **Body:** The attacker sees a normal app. Withdraw fails with "Seed Vault timed out." On-chain, withdrawals and plan edits stay frozen for up to 30 days. Inheritance still runs.

**Visual:** Split screen. Left: the normal-looking app and the fake timeout. Right: the explorer showing the `lockdown` transaction signed by the guard key, in red.

**Speaker notes:**
I typed my duress PIN. The app looks normal, but the guard key has already sent a lockdown on-chain, with no prompt for the attacker to notice. Withdrawals and plan changes are frozen, so the attacker can't redirect payouts to themselves, and I can't lift the lock alone: an early unlock needs my guardian too. It's a time-lock on purpose. A decoy wallet only moves the target, because the attacker makes you open the other wallet next. Be honest if asked: the lock is visible on-chain, so the defense is time, not secrecy (`docs/ARCHITECTURE.md`, threat model).

---

## Slide 7: `demo-release`

**Purpose:** Demo moments 3 and 4: tiers release on silence, and one pulse stops the rest.

**On slide:**

- **Headline:** Silence releases tiers. One pulse stops the rest.
- **Body (example plan):**
  - After 30 days of silence: 10% of SOL to my partner
  - After 90 days: the rest to my kids
  - A long trip costs one tier, not the estate.
- **Demo callout:** devnet: 0.5 SOL tier → 0.49 SOL to the beneficiary, 0.01 SOL fee

**Visual:** Family Circle on the beneficiary's phone: tier 1 flips from an amber "Due now" to "Released", and tier 2 resets to a full countdown after the owner's pulse.

**Speaker notes:**
Three minutes of silence on the demo cadence (real plans use days) and tier one is due. Anyone can release it, usually our keeper or the beneficiary, and it can only pay the person I chose, because the destination is fixed on-chain. Deadman takes 2%, and only on what is released. Then I come back: one fingerprint, and tier two resets. Paid tiers stay paid and can never pay twice. A tier that can't pay doesn't block the others: after a grace period it can be skipped, and its share stays reserved for its beneficiary (fix for audit finding H-1).

---

## Slide 8: `private-delivery`

**Purpose:** Show the privacy option for heirs, with its limits stated plainly.

**On slide:**

- **Headline:** Heirs can receive privately
- **Body (table):**

| Rail      | How                                                                        |
| --------- | -------------------------------------------------------------------------- |
| **Cloak** | Shielded pool on Solana; the zero-knowledge proof runs on the heir's phone |
| **Zcash** | Shielded ZEC through the NEAR Intents 1Click API                           |

- **Footnote:** The vault-to-claim-key payout is public. Mainnet only, and not yet run with real funds.

**Visual:** Violet rail chips over a simple flow: vault → claim key → shielded destination.

**Speaker notes:**
A tier can pay a claim key that the beneficiary's own Deadman app created. Their phone then routes the funds: into Cloak's shielded pool, with a Groth16 proof generated on the device, or out as shielded ZEC. The privacy breaks the link to the heir's real wallet and to what they do next. It doesn't hide that the vault paid someone, and we don't say "untraceable". Costs on top of our 5%: about 0.2% plus 0.00032 ZEC on Zcash, and 0.3% plus 0.005 SOL for a Cloak private send (`docs/HOW_IT_WORKS.md` §4). Claim keys restore from a 12-word phrase.

---

## Slide 9: `vesting-and-usdc`

**Purpose:** Show that the same vault also covers releases while you're alive, not only when you go silent.

**On slide:**

- **Headline:** Same vault, now with vesting and USDC
- **Body:**
  - **Vesting:** linear, with a cliff; revocable or irrevocable
  - **USDC:** deposits, USDC tiers, optional network fees paid in USDC
  - **Fair close:** rent goes back to whoever paid it

**Visual:** A vesting curve: flat to the cliff, then a straight line, in alive green. A USDC chip on a tier card.

**Speaker notes:**
Inheritance happens rarely; vesting is used every day. With a vesting plan the same program releases funds on a schedule, whatever the owner does: a gift to a child over four years, an allowance for a parent, a contributor's tokens. If the plan is revocable, the owner can stop future vesting, and whatever already vested stays claimable. The owner can't withdraw what beneficiaries are still owed. USDC works for deposits and payouts, and a Kora paymaster can take network fees in USDC. Status: in the program with LiteSVM tests; [app UI status for vesting and the USDC paymaster — confirm before recording].

---

## Slide 10: `why-seeker`

**Purpose:** Explain why this has to be a mobile, Seeker-native product rather than a web app.

**On slide:**

- **Headline:** Built for the phone in your hand
- **Body:**
  - Owner key stays in the Seed Vault, reached through Mobile Wallet Adapter
  - Guard key in Android secure storage, behind biometrics
  - Heirs' phones hold claim keys and prove Cloak deposits
  - Distribution: Solana dApp Store

**Visual:** Phone outline with three labelled key slots (owner, guard, claim), and a dApp Store badge.

**Speaker notes:**
The split of authority only works on a phone. The cold key sits in Seed Vault hardware, the hot key sits on the device, and the program makes sure the hot key can only defend. A web dashboard can't sign a silent duress lockdown from the device in your hand, and it can't hold a beneficiary's claim key. We wrote a native Kotlin bridge to Mobile Wallet Adapter because the Dart package hasn't been maintained since May 2025 (`docs/HOW_IT_WORKS.md` §2). CLOCK IN winners must publish on the dApp Store; our listing plan is [dApp Store submission date].

---

## Slide 11: `business-model`

**Purpose:** Show a fee model that charges nothing at setup and earns when value moves, with candid estimates.

**On slide:**

- **Headline:** Free to use. We earn when funds move.
- **Body (table):**

| Stream                   | Rate                                                         |
| ------------------------ | ------------------------------------------------------------ |
| **Release fee**          | 2% Solana rail, 3% private rails; 5% hard cap in the program |
| **Earn** (SOL → JitoSOL) | Jupiter referral, at least 0.5%; Jupiter keeps 20%           |
| **Later**                | Margin on the USDC fee paymaster                             |

- **Footer:** Estimates, not traction. Sources: `docs/HOW_IT_WORKS.md` §6, `docs/research/earn-jupiter-jito.md`

**Visual:** A clean table on a dark card. Put "5% hard cap" in alive green as the trust signal.

**Speaker notes:**
No subscription: setup is where inheritance products lose people. The fee lives in the program and is capped in code at 5%. Estimates only: $10M protected, 1% released a year, half of it privately, is about $2.5k a year (`HOW_IT_WORKS.md` §6). Earn makes about $4,000 per $1M swapped at 0.5% (`earn-jupiter-jito.md`). At $100M protected the release fee comes to about $20k–30k a year, plus Earn (`PITCH_OUTLINE.md` §7). To be candid, releases are rare, so the release fee stays small until protected assets are large. Earn and vesting releases happen on a schedule and bring revenue earlier. [No vesting revenue estimate exists yet.]

---

## Slide 12: `market`

**Purpose:** Size the opportunity from the Seeker wedge outward without unsourced numbers.

**On slide:**

- **Headline:** Everyone who self-custodies carries these risks
- **Big numbers (placeholders, sourced or cut):**
  - [Seeker devices in users' hands — source]
  - [Solana self-custody wallets — source]
  - [Value held in Solana self-custody — source]
- **Body:** Wedge: Seeker owners. Then: any Android wallet, multisig signers, vesting.

**Visual:** Three concentric rings: Seeker → Android self-custody → every self-custody and multisig user.

**Speaker notes:**
Our docs contain no sourced market figures yet, so fill these three numbers from a citable source or drop the row. The framing holds either way: every self-custody user and every multisig signer is exposed to silence, coercion and loss. Seeker owners are the wedge, because they already self-custody on the phone. The Flutter app ports to any Android phone (`HOW_IT_WORKS.md` §2). Growth is built into the product: each plan names beneficiaries and a guardian, they install the app to see your liveness, and private-rail heirs must install it to receive. Our first 100 users: [communities or people].

---

## Slide 13: `competition`

**Purpose:** Acknowledge a crowded category and state precisely what is different.

**On slide:**

- **Headline:** A crowded idea. A different product.
- **Body:**
  - **Inheritance graveyard:** 15+ near-identical Colosseum projects, none awarded
  - **SolGuard:** heartbeat inheritance, a duress key and guardians, as a web app
  - **Deadman:** Seeker-native guard key · silent duress lockdown · multi-tier release · private rails · vesting
- **Source line:** `docs/JUDGING.md` (Colosseum Copilot)

**Visual:** Two muted rows (graveyard, SolGuard) and one highlighted Deadman row with five green chips.

**Speaker notes:**
Be candid: the mechanism is solved, and we're not the first dead-man switch. Colosseum's archive has more than 15 near-identical projects, 11 of the top 15 matches from Frontier alone, and none won an award. SolGuard overlaps heavily, with a duress key that forces a 30-day wait and defend-only guardians, but it's a web app. Twin Keys used a decoy wallet. What wins in this lane is something people touch: Unruggable's hardware wallet, and One-Time Action Codes, demoed on Saga and Seeker (`JUDGING.md`). Vesting tools also exist on Solana, [name 1–2 verified vesting competitors]; our angle is one vault with a guard key, a duress lock and private rails.

---

## Slide 14: `status`

**Purpose:** Show execution and security work honestly, and leave room for real traction numbers.

**On slide:**

- **Headline:** Live on devnet, audited internally, honest about gaps
- **Big numbers:**
  - **0** critical findings; **2** high and **7** medium fixed and re-audited
  - **[N]** LiteSVM program tests (35 at the audit fix)
  - **~14.9k CU** per release
  - [X testers] · [Y devnet plans] · [Z tiers released]
- **Source line:** `docs/security-audit-2026-10-03.md`

**Visual:** A stat grid. The traction placeholders go in a separate row so they're easy to cut.

**Speaker notes:**
The program is on devnet (`ACHVLMoL…HofL`). We ran an internal audit with four lenses, plus an adversarial verifier that wrote a proof of concept for every program finding. All in-scope findings were fixed, then re-audited, and the three new issues that re-audit found were fixed as well. 127 Flutter tests passed at the audit. Releasing a tier costs 14,886 compute units. It isn't externally audited, the upgrade authority is a single key, and the private rails and Earn haven't moved real funds. [Replace the bracketed traction with real numbers by the deadline, or cut the row.]

---

## Slide 15: `roadmap-and-ask`

**Purpose:** Show the path to mainnet and make a specific ask.

**On slide:**

- **Headline:** From devnet to dApp Store to mainnet
- **Body:**
  - **Now:** devnet build, APK, CLOCK IN submission (Oct 8)
  - **Before mainnet:** external audit, multisig with a timelock, verifiable build, Trident fuzzing, real-funds rail runs
  - **Next:** private USDC routing, Cloak shielded receive, DAO signer recovery
  - **Ask:** [your ask]
- **Closing line:** Your keys, your rules, even when you can't answer.

**Visual:** A three-step horizontal timeline with the ask in an alive-green card.

**Speaker notes:**
Before mainnet we need Trident fuzzing of the rules engine, a verifiable build, a multisig upgrade authority with a timelock on fee changes, and an external audit, because this program holds user funds. Next comes private routing for USDC payouts and receiving Cloak shielded transfers. The bigger idea is DAO signer recovery: the same switch, applied to a multisig signer who goes silent. Our ask: [specific ask, e.g. audit funding, dApp Store featuring, design partners, a target number of beta testers]. Close on the positioning line and say the program ID is live on devnet.

---

## Open decisions before the deck is final

- **SKR track ($10k, CLOCK IN):** nothing in the product is tied to SKR since the subscription was removed. The options are to skip the track, to note that vaults and tiers accept any SPL mint including SKR, or to add an SKR feature before 2026-10-08 (`../PITCH_OUTLINE.md` §7).
- **Zcash track (World's Fair):** it's unverified whether a Solana app that delivers shielded ZEC through NEAR Intents counts as "building on Zcash". One product per builder applies. Ask the organizers before positioning for it.
- **Vesting fee:** the program applies the per-rail release fee to vesting releases (`vesting_tokens_release_with_fee` test). Decide whether 2% is right for vesting before presenting it.
- **Docs drift:** `docs/KORA.md` says owners never pay fees in tokens (product decision, 2026-10-03). The USDC paymaster in `lib/core/config.dart` supersedes that, so update `KORA.md` before judges read it.

## Placeholders to fill (or cut)

| Placeholder                                                     | Slide |
| --------------------------------------------------------------- | ----- |
| [Founder name]                                                  | 1     |
| [one-line founder background]                                   | 1     |
| [Founder story: why you personally care]                        | 1     |
| [sourced figure on crypto lost to death or lost keys — source]  | 2     |
| [sourced count of physical "wrench" attacks — source]           | 2     |
| [app UI status for vesting and the USDC paymaster]              | 9     |
| [dApp Store submission date]                                    | 10    |
| [No vesting revenue estimate exists yet]                        | 11    |
| [Seeker devices in users' hands — source]                       | 12    |
| [Solana self-custody wallets — source]                          | 12    |
| [Value held in Solana self-custody — source]                    | 12    |
| [communities or people: first 100 users]                        | 12    |
| [name 1–2 verified vesting competitors]                         | 13    |
| [N] LiteSVM program tests (current count after the final build) | 14    |
| [X testers]                                                     | 14    |
| [Y devnet plans]                                                | 14    |
| [Z tiers released]                                              | 14    |
| [your ask] / [specific ask]                                     | 15    |
| GitHub repository URL (end card; repo must be public)           | 15    |

## Sources used

- `docs/JUDGING.md`: hackathon facts, prior art, SolGuard, Twin Keys, the winners in the security lane, estimate assumptions.
- `docs/HOW_IT_WORKS.md`: fees, pulse, duress, private-rail costs, Kora, business-model estimates (§6).
- `docs/PITCH_OUTLINE.md`: pulse cost per year, the $100M estimate, go-to-market loop, open questions.
- `docs/research/earn-jupiter-jito.md`: Jupiter referral terms, Earn estimate.
- `docs/security-audit-2026-10-03.md`: finding counts, fix status, test counts, compute units.
- `docs/ARCHITECTURE.md`, `docs/KORA.md`, `docs/DEMO_SCRIPT.md`: trust model, threat model, sponsor scope, demo beats.
- Program source (uncommitted on `feat/safety-net-mvp-02-10-2026`): vesting (`state.rs`, `create_vesting`, `revoke_vesting`), `rent_payer`, and the USDC mint and paymaster settings in `lib/core/config.dart`.
