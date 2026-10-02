# Deadman Pitch Outline

This is a working outline for the founder. Rewrite it in your own words before recording. Bracketed items such as `[source]` are placeholders: fill them in, or cut the claim.

- **Targets:**
  - Solana Mobile CLOCK IN (deck + demo video, due 2026-10-08). Judged on stickiness/PMF, UX, innovation and presentation.
  - Colosseum Crypto World's Fair, Solana track (due 2026-10-12). Judged on founder-market fit, insight, product and execution, and market size.
- **Length:** 10 slides. Aim for 3 minutes spoken. The demo slide can embed the 90-second video from `docs/DEMO_SCRIPT.md`.

---

## 1. Title

**On slide:** Deadman: the self-custody safety net for Seeker. One vault. Three threats.

**Speaker notes:**

- Say who you are and why you care. This is the founder-market-fit beat: a personal reason, an incident you saw, or your background. Write this one yourself.
- One sentence on what Deadman is: "A vault on your phone that protects your crypto if you go silent, get coerced, or lose your device."

## 2. Problem

**On slide:** Self-custody has three failure modes, and no hardware solves them.

- **Silence.** You die or become incapacitated. Your family cannot reach your keys. `[source: estimate of crypto lost to death or lost keys]`
- **Coercion.** Someone forces you to unlock and send. `[source: public list of physical crypto attacks, e.g. Jameson Lopp's physical-bitcoin-attacks repo]`
- **Loss.** The phone is gone, and with it the app session and any keys on it.

**Speaker notes:**

- The Seed Vault makes key theft by malware much harder. It does nothing for death, for a wrench attack, or for a family that cannot reach your keys.
- Use only figures you can cite on the slide. If you cannot source a number, describe the problem without one.

## 3. Why now

**On slide:**

- Seeker ships a hardware-isolated Seed Vault and its own dApp Store.
- Phones are becoming the primary wallet. Holdings that used to sit on exchanges now sit on a device you carry around.
- Solana fees make a daily on-chain check-in affordable. At the 5,000-lamport base fee, a year of daily pulses costs about 0.0018 SOL.

**Speaker notes:**

- The daily pulse only works because a transaction costs a fraction of a cent. On most chains a daily heartbeat would be absurd.
- Seeker gives us a user base that already self-custodies on the phone, which is exactly the population exposed to these three threats.

## 4. Product

**On slide:** One vault, three protections, and a 3-second daily habit.

- **Pulse:** fingerprint, about 3 s, no wallet prompt. It keeps an on-chain streak.
- **Dead-man switch:** miss your interval and the grace period, and your heirs can claim fixed shares.
- **Duress PIN:** looks like a normal unlock and silently locks the vault on-chain.
- **Guard key and guardian:** a lost phone cannot move funds, and you rotate its key from your restored wallet.
- **Family Circle:** heirs and the guardian see "checked in 2h ago."

**Speaker notes:**

- Explain the guard key, because it is the core design insight. It is a device key that can only check in and lock. It can never withdraw. That is why the daily Pulse and the duress path need no wallet prompt, and why a stolen phone loses nothing.
- Duress is a time-lock, not a decoy wallet. A decoy only moves the target: the attacker makes you open the other wallet next. A lock that you cannot lift alone removes the payoff.

## 5. Demo

**On slide:** Embedded 90-second video (see `docs/DEMO_SCRIPT.md`).

**Speaker notes:**

- If presenting live, narrate three moments:
  1. Pulse with no wallet prompt.
  2. The duress PIN, followed by the withdrawal failing with `VaultLocked`.
  3. The switch firing on a 2-minute interval and the heir claiming.
- Point out that every action is a devnet transaction the judges can open in the explorer.

## 6. Why Seeker

**On slide:**

- The owner key stays in the Seed Vault, and every money movement needs Seed Vault approval.
- The device guard key handles daily life without a prompt.
- dApp Store distribution goes straight to self-custody users.
- Plus is paid in SKR.

**Speaker notes:**

- The split of authority is Seeker-specific. The cold key sits in secure hardware and the hot key sits on the device, and the program enforces that the hot key can only defend.
- This matters for the CLOCK IN "innovation" criterion. A web dashboard cannot sign a silent duress lockdown from the device in your hand.
- Roadmap item, only if implemented by submission: a Seeker Genesis Token check to gate Seeker perks.

## 7. Business model

**On slide:**

- **Deadman Plus, paid in SKR:** up to 4 heirs (Free: 1) and a guardian. The price is set on-chain per 30 days.
- **Success fee:** at most 1% of each heir's payout, capped in the program (`MAX_FEE_BPS = 100`).
- **Estimates:**

| Line              | Assumption                                  | Estimate (illustrative) |
| ----------------- | ------------------------------------------- | ----------------------- |
| Subscription      | 1,000 users × $3/mo                         | ~$36k/yr                |
| Success fee at 1% | $5M TVL (1,000 × $5k) × ~1%/yr trigger rate | ~$500/yr                |

_Source: docs/JUDGING.md, DeFi judge. The 1% line halves that report's 2% figure (about $1k/yr)._

**Speaker notes:**

- Say it plainly: the subscription is the business. The success fee is small by design. A large death tax is bad optics and a reason not to use the product, so it is capped at 1% in code.
- These are assumptions, not traction. Replace them with real numbers if you have any by the deadline: installs, vaults or pulses on devnet.

## 8. Competition

**On slide:**

- **The inheritance graveyard:** 15+ near-identical dead-man and inheritance projects in Colosseum's archive, none awarded (Bequest, Terminus, Afterlife, Relic, Lazarus Protocol and others).
- **SolGuard** (Frontier): heartbeat inheritance, a duress key with a 30-day wait, defend-only guardians. It is an Anchor program with a Next.js web app.
- **Twin Keys** (Cypherpunk): a decoy wallet for coercion.
- **Deadman's difference:** the same class of mechanism, but phone-native. It adds a guard key that never prompts, a silent duress path from the device, a daily habit and a social loop.

**Speaker notes:**

- Be candid. The mechanism is solved, and SolGuard's design overlaps ours heavily. Do not claim to be the first.
- Our claim is narrower and testable. Those projects shipped a contract plus a form, and the winners in this lane shipped something people touch: Unruggable's hardware wallet, and One-Time Action Codes demoed on Saga/Seeker.
- The retention answer is the real differentiator. Most proof-of-life apps die because nothing happens. Pulse streaks and Family Circle give the owner and the heirs a reason to open the app.

## 9. Go-to-market

**On slide:**

- **Launch:** Solana dApp Store. CLOCK IN winners must publish there.
- **Built-in loop:** each vault invites 1 to 4 heirs and a guardian, and they install the app to see liveness.
- **Channels:** Seeker and SKR community, self-custody security content, and partnerships with wallets that want an inheritance feature.

**Speaker notes:**

- Family Circle is the acquisition loop. Every owner brings in other people, and those people are themselves self-custody users with something to protect.
- Name the first 100 users concretely: which communities and which people. Write this yourself.
- Do not promise wallet partnerships you do not have.

## 10. Roadmap and ask

**On slide:**

- **Now:** devnet build, APK, open source.
- **Before mainnet:** external audit, multisig upgrade authority, verifiable build, and fixes for the known limitations listed in `docs/ARCHITECTURE.md`.
- **Next:**
  - Cloak private payouts to heirs.
  - Zcash shielded inheritance.
  - DAO signer recovery: the same switch, applied to multisig signers who go silent.
- **The ask:** `[what you want from judges, accelerator or users]`

**Speaker notes:**

- Being honest about the audit is a strength with technical judges. Say it once and move on.
- For Colosseum, close on market size and the wider vision: every self-custody user and every multisig signer is exposed to silence, coercion and loss.
