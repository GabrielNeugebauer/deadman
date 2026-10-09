# Deadman Pitch Outline

> **Pricing current as of 2026-10-08:** 2% only on release, 1.5% for payouts in $SKR with 10% of that fee burned, no subscription. The SKR open question below is answered by that SKR rate; older mentions of Plus are historical.

This is a working outline for the founder. Rewrite it in your own words before recording. Bracketed items such as `[source]` are placeholders: fill them in, or cut the claim.

- **Targets:**
  - Solana Mobile CLOCK IN (deck + demo video, due 2026-10-08). Judged on stickiness/PMF, UX, innovation and presentation.
  - Colosseum Crypto World's Fair, Solana track (due 2026-10-12). Judged on founder-market fit, insight, product and execution, and market size.
- **Length:** 10 slides. Aim for 3 minutes spoken. The demo slide can embed the 90-second video from `docs/DEMO_SCRIPT.md`.
- **Background for Q&A:** [HOW_IT_WORKS.md](HOW_IT_WORKS.md) and [ARCHITECTURE.md](ARCHITECTURE.md).

---

## 1. Title

**On slide:** Deadman: the self-custody safety net for Seeker. One vault. Three threats.

**Speaker notes:**

- Say who you are and why you care. This is the founder-market-fit beat: a personal reason, an incident you saw, or your background. Write this one yourself.
- One sentence on what Deadman is: "A vault on your phone that releases your crypto to the right people, in the order you choose, if you go silent, and that locks itself if you are coerced or lose your device."

## 2. Problem

**On slide:** Self-custody has three failure modes, and no hardware solves them.

- **Silence.** You die or become incapacitated. Your family cannot reach your keys. `[source: estimate of crypto lost to death or lost keys]`
- **Coercion.** Someone forces you to unlock and send. `[source: public list of physical crypto attacks, e.g. Jameson Lopp's physical-bitcoin-attacks repo]`
- **Loss.** The phone is gone, and with it the app session and any keys on it.

**Speaker notes:**

- The Seed Vault makes key theft by malware much harder. It does nothing for death, for a wrench attack, or for a family that cannot reach your keys.
- Existing inheritance tools are all-or-nothing: one trigger, everything moves. That makes setting one up feel risky. A missed check-in during a long trip should not hand over the estate.
- Use only figures you can cite on the slide. If you cannot source a number, describe the problem without one.

## 3. Why now

**On slide:**

- Seeker ships a hardware-isolated Seed Vault and its own dApp Store.
- Phones are becoming the primary wallet. Holdings that used to sit on exchanges now sit on a device you carry around.
- Solana fees make an on-chain check-in affordable. At the 5,000-lamport base fee, a year of daily pulses costs about 0.0018 SOL.
- Private delivery is now practical from a phone: Cloak's shielded pool is live on Solana mainnet, and NEAR Intents delivers shielded ZEC.

**Speaker notes:**

- The Pulse only works because a transaction costs a fraction of a cent. On most chains a daily heartbeat would be absurd.
- Seeker gives us a user base that already self-custodies on the phone, which is exactly the population exposed to these three threats.

## 4. Product

**On slide:** One vault, a release plan, and a 3-second habit.

- **Pulse:** fingerprint, about 3 s, no wallet prompt. It restarts every pending tier's clock.
- **Release plan:** up to 8 tiers. "After 10 days of silence, 1 SOL to my partner. After 30 days, the rest to my brother." Tiers fire in order; one Pulse stops the rest.
- **Private delivery:** any tier can pay out through Cloak or as shielded ZEC instead of a public Solana transfer.
- **Duress PIN:** looks like a normal unlock and silently locks the vault on-chain.
- **Guard key and guardian:** a lost phone cannot move funds, and you rotate its key from your restored wallet.
- **Family Circle:** beneficiaries and the guardian see "checked in 2h ago" and the state of their tier.
- **Earn (mainnet):** idle SOL becomes JitoSOL inside the vault, and tiers can pay it out.

**Speaker notes:**

- Explain the guard key, because it is the core design insight. It is a device key that can only check in and lock. It can never withdraw. That is why the Pulse and the duress path need no wallet prompt, and why a stolen phone loses nothing.
- Explain tiers as the answer to "what if I'm just on a trip?" The cost of a false alarm is the first tier, not everything.
- Duress is a time-lock, not a decoy wallet. A decoy only moves the target: the attacker makes you open the other wallet next. A lock that you cannot lift alone removes the payoff.
- Be precise about privacy if asked: the vault-to-claim-key payout is public, Cloak deposit amounts are visible, and the NEAR Intents explorer maps the deposit address to the `u1` address. What is hidden is what the beneficiary does afterwards. Do not say "untraceable".

## 5. Demo

**On slide:** Embedded 90-second video (see `docs/DEMO_SCRIPT.md`).

**Speaker notes:**

- If presenting live, narrate four moments:
  1. Pulse with no wallet prompt.
  2. The duress PIN, followed by a withdrawal that fails while the vault is locked on-chain.
  3. Tier 1 releasing after 3 minutes of silence, executed by the keeper (or the beneficiary), with the 2% fee visible in the explorer.
  4. One Pulse resetting tier 2 while tier 1 stays paid.
- Point out that every action is a devnet transaction the judges can open in the explorer. The private rails and Earn are mainnet-only; say so rather than imply they ran in the video.

## 6. Why Seeker

**On slide:**

- The owner key stays in the Seed Vault, and every money movement needs Seed Vault approval.
- The device guard key handles daily life without a prompt.
- Beneficiaries' claim keys live in their own phone's secure storage, and their phone does the private routing, including a zero-knowledge proof for Cloak.
- dApp Store distribution goes straight to self-custody users.

**Speaker notes:**

- The split of authority is Seeker-specific. The cold key sits in secure hardware and the hot key sits on the device, and the program enforces that the hot key can only defend.
- This matters for the CLOCK IN "innovation" criterion. A web dashboard cannot sign a silent duress lockdown from the device in your hand, and it cannot hold a beneficiary's claim key.
- Roadmap item, only if implemented by submission: a Seeker Genesis Token check to gate Seeker perks.

## 7. Business model

**On slide:**

- **Free to use.** No subscription, no sign-up fee.
- **Payout fee, on-chain, only when a tier releases funds:** 2% on the Solana rail, 3% on private rails. Both are admin-configurable under a 5% hard cap in the program (`MAX_FEE_BPS = 500`).
- **Integrator fees (optional):** a Jupiter referral fee on Earn swaps (minimum 50 bps, Jupiter keeps 20%), and NEAR Intents `appFees` on Zcash routing (split 50/50 with 1Click).
- **Estimates:**

| Line                      | Assumption                                          | Estimate (illustrative) |
| ------------------------- | --------------------------------------------------- | ----------------------- |
| Payout fee, Solana rail   | $5M TVL (1,000 × $5k) × ~1%/yr released × 2%        | ~$1k/yr                 |
| Payout fee, private rails | same base, released privately, × 3%                 | ~$1.5k/yr               |
| Earn referral             | 30% of TVL swapped once ($1.5M) × 50 bps × 80% kept | ~$6k, one-time          |
| Same model at $100M TVL   | ~1%/yr released × 2–3%, plus Earn on new deposits   | ~$20k–30k/yr + Earn     |

_TVL and release-rate assumptions come from docs/JUDGING.md (DeFi judge). Earn figures use the fee table in docs/research/earn-jupiter-jito.md. None of this is traction._

**Speaker notes:**

- Say it plainly: we earn only when we deliver. No subscription means no friction at setup, which is where inheritance products lose people.
- The judging report called a fee "at death" bad optics. Answer it directly: the fee is charged per tier, only on funds that actually move, and the cap is in code. The higher private-rail rate pays for the keeper and the routing work. `[source: typical estate-service or probate fees, if you want a comparison; otherwise cut]`
- Be honest that the revenue is small at hackathon scale and lumpy, because it depends on releases. It grows with TVL, and Earn adds revenue at deposit time rather than at death.
- Replace the estimates with real numbers if you have any by the deadline: installs, vaults, tiers released on devnet.

**Open question: the SKR track.** CLOCK IN has a separate $10k SKR track ([JUDGING.md](JUDGING.md#hackathon-facts-verified-2026-10-02)). v1 addressed it with Plus paid in SKR; v2 removed Plus, so nothing in the product is tied to SKR today. Decide before the deck is final:

- Leave the track unaddressed and focus on the main prize.
- Point out that a vault can hold SKR and a tier can pay it out, since rules accept any SPL mint. This needs no code, but it may not meet the track's bar. Check the track's criteria first.
- Add an SKR-specific feature, such as a payout-fee discount for SKR holders. This would need program and app changes before 2026-10-08.

## 8. Competition

**On slide:**

- **The inheritance graveyard:** 15+ near-identical dead-man and inheritance projects in Colosseum's archive, none awarded (Bequest, Terminus, Afterlife, Relic, Lazarus Protocol and others).
- **SolGuard** (Frontier): heartbeat inheritance, a duress key with a 30-day wait, defend-only guardians. It is an Anchor program with a Next.js web app.
- **Twin Keys** (Cypherpunk): a decoy wallet for coercion.
- **Deadman's difference:** phone-native (a guard key that never prompts, a silent duress path from the device), a tiered plan instead of one all-or-nothing trigger, private delivery to beneficiaries, and a daily habit with a social loop.

**Speaker notes:**

- Be candid. The basic mechanism is solved, and SolGuard's design overlaps ours heavily. Do not claim to be the first dead-man switch.
- Our claim is narrower and testable. Those projects shipped a contract plus a form, and the winners in this lane shipped something people touch: Unruggable's hardware wallet, and One-Time Action Codes demoed on Saga/Seeker.
- The retention answer is a real differentiator. Most proof-of-life apps die because nothing happens. The Pulse and Family Circle give the owner and the beneficiaries a reason to open the app.

## 9. Go-to-market

**On slide:**

- **Launch:** Solana dApp Store. CLOCK IN winners must publish there.
- **Built-in loop:** each vault names up to 8 tiers of beneficiaries plus a guardian. They install the app to see liveness, and private-rail beneficiaries must install it to generate a claim code.
- **Channels:** Seeker community, self-custody security content, privacy communities (Zcash, Cloak users), and partnerships with wallets that want an inheritance feature.

**Speaker notes:**

- Family Circle is the acquisition loop. Every owner brings in other people, and those people are themselves self-custody users with something to protect.
- Name the first 100 users concretely: which communities and which people. Write this yourself.
- Do not promise wallet partnerships you do not have.

## 10. Roadmap and ask

**On slide:**

- **Now:** devnet build with the Solana rail end to end; private rails and Earn in a mainnet build; APK; open source.
- **Before mainnet:** external audit, multisig upgrade authority, verifiable build, a small real-funds run of each rail, claim-key backup, and fixes for the known limitations in `docs/ARCHITECTURE.md`.
- **Next:**
  - Private routing for SPL payouts, and receiving Cloak shielded transfers.
  - DAO signer recovery: the same switch, applied to multisig signers who go silent.
- **The ask:** `[what you want from judges, accelerator or users]`

**Speaker notes:**

- Being honest about the audit is a strength with technical judges. Say it once and move on.
- For Colosseum, close on market size and the wider vision: every self-custody user and every multisig signer is exposed to silence, coercion and loss.
- Open question for the World's Fair: the event also has a Zcash track, and it allows one product per builder. Whether a Solana app that delivers shielded ZEC through NEAR Intents counts as "building on Zcash" is unverified. Ask the organizers before positioning for it.
