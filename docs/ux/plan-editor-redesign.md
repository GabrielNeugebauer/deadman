# Plan editor redesign (inheritance + vesting)

Status: spec, ready to implement · 2026-10-04 · replaces the single-page editors in
`lib/ui/screens/rules_editor.dart` and `lib/ui/screens/vesting_editor.dart`.

## 0. Why

Owner report (2026-10-04): "the new plan screen is confuse, with so much unorganized settings... I set 1% USDC,
sent 1 USDC and the USDC never ended in the final address."

What happened, step by step:

1. The tier was saved as "1% of remaining USDC" (100 bps). The field showed a bare `1` next to a `%` segment, and
   the suffix "% of remaining" was easy to miss. The owner meant 100%. Several of their test plans have the same
   mistake.
2. The plan held 1 USDC, so the tier pays 0.01 USDC gross and 0.0098 USDC after the 2% fee.
3. The heir's wallet had never held USDC, so it had no USDC account. Delivering USDC there means opening one
   (~0.00204 SOL rent):
   - The keeper (`tool/keeper.dart`, `decideToken`) only pays that rent when the 2% fee is worth it, which takes a
     payout of about 17 USDC. At 0.0002 USDC of fee it waits forever.
   - The heir can claim it with 0 SOL through the Kora paymaster, but the first claim costs 0.50 USDC, which is
     more than the payout.
   - So it never arrives. After the grace period the tier gets skipped and its share stays reserved.
4. Nothing on screen said any of this: no money preview, no delivery check, no "did you mean 100%".

Goals:

- A person who has never used crypto can build a plan, and it does what they think it does.
- Every amount is shown as **money that arrives** (after fees), not only as a percentage.
- The editor catches any payout that can't arrive, before the owner signs.
- Less on screen at once: one decision per section, and rare settings collapsed.

Non-goals: program changes, keeper changes, new rails, edits to plan cards.

### Constraints for the implementer

- Keep `RulesEditorPage({Key? key, VaultState? vault})` and `VestingEditorPage({Key? key})` exactly. Callers in
  `pulse_tab.dart` don't change.
- **Do not edit** `lib/ui/screens/pulse_tab.dart`, `lib/ui/widgets/plan_pricing.dart`,
  `lib/ui/screens/settings_tab.dart`, `lib/ui/screens/circle_tab.dart`, `lib/state/providers.dart` or anything
  under `lib/solana/**`. Another workflow is editing them. Reading their providers and APIs is fine.
- Use the existing actions unchanged: `actions.createVault(...)`, `actions.updatePolicy(...)` and
  `actions.createVesting(...)` (`lib/state/actions.dart`).
- No `flutter run`, no device installs, never read keypair files. Verify with `flutter analyze` and `flutter test`.

---

## 1. Structure decision: a short step flow

**Create (inheritance): 3 steps.** `1 Payouts · 2 Fund · 3 Review`
**Edit, or start fresh on a completed plan: 2 steps.** `1 Payouts · 2 Review`. Editing can't deposit:
`update_policy` moves no funds.
**Vesting: same 3 steps.** `1 Schedules · 2 Fund · 3 Review`

Why steps, and why not the 5 steps in the brief or a single page:

- **A payout is the unit people think in**: "Ana gets everything after a month". Who, what and when belong to
  one payout. Splitting them across global steps (step 1 who, step 2 what...) breaks that as soon as there are
  2-8 payouts. So step 1 is a **list of payout summaries**. Each one opens a focused **payout editor** with three
  sections: Who · What · When.
- **Funding comes after the payouts** because the payouts decide what the plan must hold: fixed amounts add up,
  and share payouts need a balance to mean anything. Funding is also where the 1%-of-1-USDC mistake becomes
  visible as money. So Fund is its own step, with a live per-payout breakdown.
- **Review is separate** because it's the last chance to catch a payout that can't arrive. It must read as plain
  sentences, not form fields.
- **A single long page** (today's design) is what the owner called confusing: 14+ controls per tier, with cadence
  and grace chips above them. Progressive disclosure inside a single page still leaves Fund above or below the
  payouts with nothing tying them together.

Navigation rules:

- Bottom bar: `Back` (OutlinedButton) and `Next` / `Create plan` / `Save changes` (FilledButton, 54dp). `Next` is
  never disabled. Tapping it validates the step, scrolls to the first problem and shows inline errors. A disabled
  button that doesn't say why is worse.
- System back on step > 0 goes to the previous step (`PopScope`). On step 0 with changes it asks
  "Discard this plan?" (create) or "Discard your changes?" (edit).
- The step header can be tapped to go back to completed steps, never forward past an invalid step.

---

## 2. Screen maps

### 2.1 Step 1 · Payouts (inheritance)

```
┌──────────────────────────────────────────┐
│ ←  New inheritance plan                  │  AppBar
│ ●──────○──────○                          │  StepHeader: Payouts · Fund · Review
│ Payouts  Fund   Review                   │
├──────────────────────────────────────────┤
│ Who gets what if you stop checking in.   │  1-line intro (muted)
│                                          │
│ ┌ Plan ────────────────────────────────┐ │  SectionCard
│ │ Plan name            [Family       ] │ │
│ │ You check in every   [ 7 days    ▾ ] │ │  opens sheet: 7 / 30 / 90 days
│ └──────────────────────────────────────┘ │
│                                          │
│  ◉ Last check-in                         │  PayoutTimeline (sorted by delay)
│  │                                       │
│  ├─ After 10 days of silence             │
│  │ ┌──────────────────────────────────┐ │  PayoutSummaryCard (tap = edit)
│  │ │ Ana · 7xKX…9fGh        ⚡ Normal  │ │
│  │ │ Everything left of your USDC      │ │
│  │ │ ≈ 98.00 USDC                    › │ │
│  │ │ ⚠ Ana will need to claim it       │ │  first warning only, if any
│  │ └──────────────────────────────────┘ │
│  ├─ After 37 days of silence             │
│  │ ┌ Ben · 4Fq2…k8Za  ...             ┐ │
│  │                                       │
│  └─ [ + Add a payout ]                   │  OutlinedButton, hidden at 8
│                                          │
│ ▸ Advanced                               │  ExpansionTile, collapsed
├──────────────────────────────────────────┤
│ [        Next: fund the plan         ]   │  bottom bar
└──────────────────────────────────────────┘
```

Empty state (create, first open): the timeline shows the "Last check-in" node and a large dashed card:

> **Add your first payout**
> Choose who receives money if you stop checking in, how much, and when.
> `[ + Add a payout ]`

Tapping `Next` with no payouts shows the inline error "Add at least one payout." under the card.

> **Implementation note:** today's editor creates one blank tier automatically. The new one doesn't: the payout
> editor opens straight away on first create (§3), and cancelling it returns to the empty state.

#### Check-in interval: visible, but compact

The brief puts the check-in interval under Advanced. It stays visible here as a single row, because every "after
N days of silence" depends on it, and hiding it makes the delays impossible to reason about. It's one row with
the 7-day default, not a chip group. Lockdown length, skip grace, demo timings and the guardian go under
Advanced.

Interval sheet (bottom sheet, `RadioListTile`s, 56dp rows):

| Option  | Helper                             |
| ------- | ---------------------------------- |
| 7 days  | Good if you use your phone daily.  |
| 30 days | A monthly check-in.                |
| 90 days | Least effort; payouts start later. |

Sheet title: "How often will you check in?" Footer (muted): "A check-in is a fingerprint tap in Deadman. Missing
one doesn't send anything by itself: each payout waits for its own delay."

When the interval changes and a payout's delay is now too short, that payout card shows the error **D1** (§6)
with a "Move to {default}" button. `{default}` is `Cadence.release` for the new cadence.

#### Advanced (ExpansionTile, collapsed by default)

Title: "Advanced". Subtitle while collapsed, built from the values:
"Lock: 3 days · Skip after: 30 days". Add " · Demo timings" when on, and " · Guardian set" when there is one.

1. **Duress lock lasts**: chips `1 day` · `3 days` (default = `Cadence.lock`) · `7 days` · `30 days`. Demo: `5 minutes`.
   Helper: "When you use your duress PIN or Panic, withdrawals and plan changes are frozen for this long. Payouts
   are never frozen."
   > Today the lock length is tied to the cadence (`_cadence.lock`). It becomes its own field, `_lockSecs`, that
   > starts at `Cadence.lock` and follows the cadence until the user touches it. Bounds 60 s to 30 days (`Limits`).
2. **If a payout can't be delivered, move on after**: chips from `graceChoices(demo:)`. Default 30 days (2
   minutes in demo).
   Helper: "Deadman waits this long for a payout that can't be sent (for example, a wallet that can't receive
   it), then lets later payouts continue. The stuck payout's money stays set aside for that person to claim."
3. **Demo timings**: `SwitchListTile`, same as the vesting editor.
   Title "Demo timings". Subtitle: "Check-ins every 2 minutes and payouts within minutes, so you can show it
   live."
   Turning it on sets `Cadence.demo` and the grace to 120 s (same logic as `_setCadence`). The interval row then
   reads "You check in every 2 minutes" and its sheet is disabled while demo is on.
4. **Guardian (optional)** (edit only, same as today): the existing TextField with label "Guardian wallet
   (optional)". Helper: "A person you trust who can freeze this plan and co-sign an early unlock. They can never
   move funds."

### 2.2 Payout editor (full-screen, `fullscreenDialog: true`)

Opened from "Add a payout" or by tapping a summary card. It returns a `PayoutDraft`, or null when cancelled.
Title: "New payout" or "Payout {n}". Its AppBar has `Cancel` (left, closes and asks if dirty) and a `Remove`
action (edit of an existing draft only, confirmation "Remove this payout?").

```
┌──────────────────────────────────────────┐
│ ✕  Payout 1                      Remove  │
├──────────────────────────────────────────┤
│ 1  Who gets it                           │  SectionCard
│   [ Their wallet address or claim code ]📋│  paste icon button
│   [ Their name (optional)            ]   │
│   How it arrives                         │
│   ◉ ⚡ Normal transfer                    │  RailOptionTile ×3
│       Straight to their Solana wallet.   │
│       2% fee                             │
│   ○ 👁 Private (Cloak)    mainnet only   │
│   ○ 🛡 Private as Zcash   mainnet only   │
│                                          │
│ 2  What they get                         │
│   [ SOL ][ USDC ][ More… ]               │  asset ChoiceChips
│   ┌ Share of what's left │ Fixed amount ┐│  SegmentedButton, full width
│   │        [   100  ] %                 ││  large field
│   │  Everything that's left             ││  words line
│   │ [25%] [50%] [Everything left]       ││  quick chips
│   └─────────────────────────────────────┘│
│                                          │
│ 3  When                                  │
│   After [10 days][14 days][30 days]      │
│         [90 days][Custom]  of silence    │
│   ── timeline strip ──                   │
│   You check in every 7 days. If you stop,│
│   this is sent 10 days after your last   │
│   check-in (3 days after you miss one).  │
├──────────────────────────────────────────┤
│ ≈ 98.00 USDC to Ana after 10 days of     │  LivePreview (sticky, above button)
│ silence (after the 2% fee)               │
│ ⚠ Ana will need to claim it  ›           │  top warning, tap scrolls to it
│ [               Done                ]    │
└──────────────────────────────────────────┘
```

#### Section 1 · Who gets it

- Address field. Label "Their wallet address or claim code". Hint "Solana address, or zcash:… / cloak:…". Suffix
  is a paste `IconButton` (48dp, tooltip "Paste").
  - Pasting or typing a claim code still runs `applyClaimCode()`. That strips the prefix, selects the rail and
    shows a confirmation line (alive color, check icon): "Claim code recognised: they'll receive it privately via
    {Cloak|Zcash}."
  - Invalid on blur or Done: "This isn't a valid Solana address or claim code."
  - Same as the owner's wallet: warn **B1** (§6).
- Name field. Label "Their name (optional)". Helper "Only saved on this phone, to make your plan easier to read."
  Max 24 characters.
  - Stored in `SharedPreferences` (`prefsProvider`, read only) under `contact_name.<address>`. Put this in a new
    file, `lib/state/contact_names.dart`. Don't touch `providers.dart`.
  - Everywhere this spec writes `{who}`, use the name when set, otherwise `short(address)`. Before an address is
    entered, use "this person".
- How it arrives: three `RailOptionTile`s. These are radio cards with an icon in `rail.color`, a title, one helper
  line and a fee line. They replace the `SegmentedButton<Rail>`, whose "Solana / Cloak / Zcash" labels mean
  nothing to a newcomer.

  | Rail   | Title            | Helper                                                                              | Fee line     |
  | ------ | ---------------- | ----------------------------------------------------------------------------------- | ------------ |
  | solana | Normal transfer  | Straight to their Solana wallet. Anyone can see it on the blockchain.               | `{fee}% fee` |
  | cloak  | Private (Cloak)  | Hidden on Solana. They need the Deadman app and must send you a claim code.         | `{fee}% fee` |
  | zcash  | Private as Zcash | Arrives as private Zcash. They need the Deadman app and must send you a claim code. | `{fee}% fee` |
  - `{fee}` comes from `feesProvider` (`percentText(bpsFor(rail)/10000)`). While it's loading, show "fee loading…".
    On an edit where `vault.subscriptionActive(now)`: "No fee: monthly plan active".
  - When `privateRailsLiveProvider` is false, private tiles show a muted "mainnet only" badge. They stay
    selectable (same as today). Field label: a private rail changes the address label to "Their claim code" and
    the helper to "Ask them to open Deadman → Security → Receive privately and send you the code."

#### Section 2 · What they get

- Asset: `ChoiceChip`s for `presetAssets`, then `More…` (the existing "Other token" dialog, unchanged). Default is
  USDC when the owner's wallet holds USDC and no SOL beyond fees, otherwise SOL.
- **Amount mode**: `SegmentedButton<AmountMode>` at full width with two segments. Order and copy:
  1. `Share of what's left` (default for a new payout)
  2. `Fixed amount`

  The field **keeps a separate value per mode** (two controllers). Today switching modes reinterprets the same
  text, so "100" (%) silently becomes 100 USDC. Switching shows the other mode's last value. On first switch to
  Fixed it's empty, with the hint "0.00".

- **Share field** (`AmountModeField`, percent mode):
  - Large input: `headlineMedium` (Space Grotesk 28), right-aligned, with a large `%` suffix and a fixed width
    that fits "100.00". Label for semantics: "Share of what's left, in percent".
  - Accepts 0.01 to 100 with at most 2 decimals (`FilteringTextInputFormatter` + validator). Edit mode loads it
    as `percentText(bps/10000)` without the `%`, so it shows "100", never "100.0" (today `'${r.amount / 100}'`
    renders "100.0").
  - **Words line** right under the number. It always shows, so "1" can't be read as "100":

    | Value           | Words line                                      |
    | --------------- | ----------------------------------------------- |
    | 100             | "Everything that's left"                        |
    | 75              | "Three quarters of what's left"                 |
    | 50              | "Half of what's left"                           |
    | 25              | "A quarter of what's left"                      |
    | 10              | "A tenth of what's left"                        |
    | 1               | "1 out of every 100 {asset} left"               |
    | other           | "{p} out of every 100 {asset} left"             |
    | empty/0/invalid | "Enter a share from 0.01 to 100" (danger color) |

  - Quick chips: `25%` · `50%` · `Everything left`. "Everything left" sets 100. 100% and Everything left are the
    same thing, so they're one chip, which avoids a choice that looks like two different options. The selected
    chip mirrors the typed value.
  - Under the chips, muted: "Shares are taken from what is left of this {asset} when the payout runs, after
    earlier payouts."
- **Fixed field** (fixed mode): the existing amount field with the asset symbol as suffix. Label "Amount".
  Helper: "If the plan holds less when this payout runs, they get what's there."
  - Unknown token: suffix "units", and the helper adds "Other tokens are entered in base units."
  - Fixed SOL under 0.001: error **A2** (existing rule).
- **Did-you-mean check** (inline warning **A1**, under the field): show it when all of these hold:
  - mode = share,
  - value ≤ 5,
  - this payout is the **last** (longest delay) payout of its asset.

  Copy: "Only {p}% of your {asset} goes to {who}. The other {100-p}% stays locked in the plan after you're gone.
  Did you mean 100%?" Action: `TextButton("Use 100%")`.

#### Section 3 · When

- Label "Send it after this long without a check-in". Chips depend on the cadence. Any chip ≤ interval + 60 s is
  hidden, and the first chip is the default (`Cadence.release`):

  | Cadence      | Chips                                           |
  | ------------ | ----------------------------------------------- |
  | demo (2 min) | 3 minutes · 5 minutes · 10 minutes · 30 minutes |
  | 7 days       | 10 days · 14 days · 30 days · 90 days           |
  | 30 days      | 37 days · 45 days · 60 days · 180 days          |
  | 90 days      | 104 days · 120 days · 180 days · 365 days       |

  Plus a `Custom` chip that opens a number field with a unit dropdown (days; minutes only in demo).
  Unit dropdown: `DropdownButtonFormField`, 48dp. Bounds: > interval + 60 s, ≤ 3 × 366 days (`Limits.maxRuleDelaySecs`).

- **Timeline strip** (`DelayStrip`, 40dp tall, decorative, `ExcludeSemantics`): a line from "Last check-in" with
  a tick at the next due check-in and a mint dot at this payout's delay.
- Explanation (body, muted), built from the values:
  "You check in every {interval}. If you stop, this is sent {delay} after your last check-in ({delay − interval}
  after you miss one)."
  Second line: "Any check-in before then restarts the clock."
- Other payouts with **the same asset and an earlier delay** are listed in one muted line:
  "Runs after: Payout 1 (Ana, 10 days)." Same-asset payouts pay in delay order.

#### Live preview (sticky footer of the payout editor)

`LivePreview` sits pinned above the Done button, so it is always visible while typing. Format:

- Known amount: "≈ **{net}** to {who} after {delay} of silence (after the {fee}% fee)".
  When the fee is waived: "(no fee)".
- Example amount: when the plan's balance for this asset isn't known yet (create mode before step 2), base it on
  an example, chosen in this order:
  1. the step 2 draft deposit if already typed;
  2. else the fixed payouts of that asset;
  3. else the wallet balance;
  4. else 100 units.

  Phrase it as "If the plan holds {X}: ≈ {net} to {who} after {delay} of silence."

- Under it, the most severe warning for this payout (one line, icon + title) as an `InkWell` that scrolls to the
  full warning.
- Amounts: `formatUnits` with **at least 2 significant digits**, so it's never "0.00". Examples: 0.0098 USDC,
  0.00049 SOL. Use `amountText` for normal sizes.

`Done` validates this payout only (address, share/amount, delay). It pops with the draft. Delivery warnings
don't block Done.

### 2.3 Step 2 · Fund (create only)

One `FundAssetCard` per asset the payouts use, in order SOL, USDC, then others. A SOL card is also shown when a
private-rail **token** payout exists (stipend, §5).

```
┌ USDC ────────────────────────────────────┐
│ Put in this plan                          │
│ [        1.00      ] USDC   [Use all]     │  amount field + chip
│ In your wallet: 12.40 USDC                │  helper
│                                           │
│ What each payout gets                     │  breakdown, live
│  Payout 1 · Ana · after 10 days           │
│   1% of what's left → ≈ 0.0098 USDC   ⛔  │
│  Left in the plan afterwards: 0.99 USDC ⚠ │
│                                           │
│ ⛔ Too small to arrive                     │  WarningTile(s)
│   Ana would get ≈ 0.0098 USDC ...         │
│   [Use 100%]                              │
└───────────────────────────────────────────┘
```

- Title row: asset symbol (titleLarge) and a muted line saying what the payouts need:
  - only fixed payouts: "Your payouts add up to {sum}."
  - only shares: "Your payouts are shares, so they pay from whatever you put in."
  - mixed: "Fixed payouts need {sum}; shares pay from the rest."
- Deposit field: label "Put in this plan", suffix symbol, helper "In your wallet: {balance}". Wallet balances
  come from `walletBalanceProvider` and `walletTokenProvider(mint)`. While loading: "Checking your wallet…".
  On error: "Couldn't read your wallet balance."
- **Defaults** (applied once, then follow the payouts until the user types, like the vesting `_edited` set):
  - Asset has fixed payouts: the sum of those fixed payouts, capped at the wallet balance (for SOL, at wallet
    minus the reserve below).
  - Shares only: **empty**, and the field gets focus when the step opens. The old blanket default of `0.1` SOL is
    removed.
  - SOL card shown only for a private-rail stipend: the stipend sum (0.012 SOL per Cloak token payout,
    0.003 SOL per Zcash one).
- `Use all` chip: the wallet balance. For SOL, wallet minus the **fee reserve**: 0.02 SOL, plus
  `AppConfig.guardFundingLamports` (0.01 SOL) when `AppConfig.koraSponsorUrl` is empty and the fee mode is SOL.
  The reserve is 0 when fees are paid in USDC.
- **Breakdown**: every payout of this asset, in delay order:
  - one line "Payout {n} · {who} · after {delay}";
  - indented under it, "{amountLabel} → ≈ {net}", with the payout's worst warning icon.
  - Last line: "Left in the plan afterwards: {leftover}". Use warn color when the leftover is > 0.
- Warnings for this asset (§6) show as `WarningTile`s at the bottom of the card, most severe first.
- Footer under the cards (muted): "You can add more later from the plan card. Payouts that are shares grow with
  whatever you add."
- Blocking on Next: a deposit over the wallet balance (**F1**), and an unparseable amount: "Check this amount".
  A 0 deposit isn't blocking; it raises **F2** and is acknowledged in Review.

### 2.4 Step 3 (or 2) · Review

Plain sentences, then problems, then costs, then the button. Nothing here is editable. Each block has an
`Edit` text button that jumps to the step or payout.

```
┌──────────────────────────────────────────┐
│ Family                          Edit     │  plan name, or "Unnamed plan"
│ You check in every 7 days.               │
│                                          │
│ If you stop checking in                  │  titleLarge
│ ① After 10 days of silence               │  numbered, delay order
│   Ana gets everything left of your USDC  │
│   (≈ 0.98 USDC) as a normal transfer to  │
│   7xKX…9fGh.                     Edit ›  │
│   ⛔ Too small to arrive                  │  attached warnings
│ ② After 37 days of silence               │
│   ...                                    │
│ Nothing is left behind.  /  ⚠ 0.99 USDC  │  leftover sentence per asset
│ stays locked in the plan.                │
│                                          │
│ Costs                                    │
│ Put in now        1.00 USDC · 0.05 SOL   │
│ Release fee       ≈ 0.02 USDC if all     │
│                   payouts run            │
│ Network & setup   a few thousandths of   │
│                   a SOL                  │
│ Check-in key      0.01 SOL (only if no   │
│                   sponsor)               │
│                                          │
│ ☐ Create it anyway. I understand the     │  only when ⛔ warnings exist
│   payouts marked ⛔ may never arrive.     │
│ [          Create plan            ]      │
│ One wallet approval creates the plan and │
│ makes your deposits.                     │
└──────────────────────────────────────────┘
```

Sentence template (`payoutSentence`, pure, in `lib/state/plan_review.dart`):

- `{When}`: "After {delay} of silence". Add " ({delay − interval} after a missed check-in)" when the interval is
  shorter than the delay.
- `{Who gets what}`:
  - share 100: "{who} gets everything left of your {asset}"
  - share p: "{who} gets {p}% of the {asset} left at that point"
  - fixed: "{who} gets {amount}"
- Then " (≈ {net})" when known.
- `{How}`:
  - solana: "as a normal transfer to {short(address)}"
  - cloak: "privately through Cloak, using their claim code"
  - zcash: "privately as Zcash, using their claim code"

Leftover sentence per asset:

- When `lastTakesAll`: "Nothing of your {asset} is left behind."
- Otherwise: "{leftover} of your {asset} ({percent} of today's) stays locked in the plan after the last payout.
  Nobody can withdraw it once you're gone." Use warn color and the **L1** action "Make the last payout
  'Everything left'". That action sets the last payout of that asset to share 100.

Costs block (`ListTile`-like rows, label left, value right, `Wrap` at large text):

| Row             | Value                                                                                                                                               | Show when                                                      |
| --------------- | --------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------- |
| Put in now      | deposits joined by " · "                                                                                                                            | create                                                         |
| The plan holds  | `withdrawableLamports` SOL · `planUsdcProvider` / `planTokenBalancesProvider`                                                                       | edit / fresh                                                   |
| Release fee     | "{2}% of each normal payout, {5}% of each private one, taken when it runs. If every payout runs: ≈ {sum per asset}."                                | always; when waived: "None: monthly plan active"               |
| Network & setup | SOL fee mode: "A few thousandths of a SOL (plan storage comes back if you close the plan)". USDC fee mode with paymaster: "3.00 USDC, paid in USDC" | create                                                         |
| Check-in key    | "0.01 SOL so this phone can check in"                                                                                                               | create, and `AppConfig.koraSponsorUrl` empty, and SOL fee mode |
| Network fee     | "A tiny SOL network fee" / "0.02 USDC, paid in USDC"                                                                                                | edit                                                           |

Edit-only line above the button (muted): "Saving also counts as a check-in: every payout's clock restarts."

> The comment at `rules_editor.dart:488` says saving checks in. Confirm against `update_policy` before shipping
> this line, and drop it if that isn't true.

Button: `Create plan` (create), `Save changes` (edit), `Start new plan` (fresh). While busy, a 20px progress
indicator inside the button, and Back is disabled. The old label "Arm Deadman" is dropped: it doesn't say what
happens.

- **Danger warnings (⛔) present**: the checkbox (`CheckboxListTile`, 48dp) is required. The button stays
  enabled. Tapping it without the box scrolls to the box and shakes it, with the error text "Tick the box, or fix
  the payouts marked ⛔."
- **Amber warnings (⚠)**: shown, never blocking.
- The old dialogs `_confirmUnfunded` and `_confirmLeftovers` are **removed**. Their content now lives inline in
  Fund and Review, so the owner sees it before pressing the button, not as a surprise afterwards.

Success toasts are unchanged ("Deadman armed" → "Plan created"; "Release plan updated" → "Plan updated"), and so
is the unguarded-plans message.

---

## 3. Edit mode, and plans whose payouts have all released

- Title: "Edit plan"; "Start a new plan" when `vault.completed`.
- Steps: Payouts · Review (no Fund). Previews use the vault's balances:
  - SOL: `vault.withdrawableLamports`;
  - USDC: `planUsdcProvider(vault.address)`;
  - other mints: `planTokenBalancesProvider[vault.address]`, or unknown.
- **History payouts** (released or skipped, from `splitRules`) appear on the timeline before the pending ones,
  as `HistoryPayoutCard`s:
  - 55% opacity, a lock icon, not tappable, Semantics "read only";
  - title "Payout {n} · {doneLabel}";
  - body "{amountLabel} → {who}";
  - footer: "Already paid. It won't pay again." (executed) or "Its money is set aside until {who} claims it."
    (skipped).

  They count towards the 8-payout limit. When the limit is reached, the Add button is replaced by the text
  "A plan holds up to 8 payouts, paid ones included."

- Fresh mode (all released) banner, above the timeline (warn `WarningTile`, info severity): "Every payout of this
  plan has been sent. Saving starts a new set of payouts on the same plan."
- Edit-only warning **F3**: when a payout's asset balance in the vault is 0: "This plan holds no {asset} yet.
  After saving, use Deposit on the plan card."
- The guardian field lives under Advanced (§2.1).
- The rule that leaving an unsaved edit asks first applies here too.

---

## 4. Vesting editor (same pattern)

Steps: `1 Schedules · 2 Fund · 3 Review`. Title "New vesting plan".

**Step 1 · Schedules.**

- Plan card:
  - Plan name.
  - "Starts": chips `Today` · `Pick a date` (same as now).
  - "Can you stop it later?": `SegmentedButton`, full width, segments `Yes, I can stop it` (revocable, default)
    and `No, it's locked in`. Helper per choice: the existing revocable/irrevocable subtitles.
- Schedule summary cards, like payout cards:
  - "{who} · {total}"
  - "over {duration}" + ", nothing for the first {cliff}"
  - a **mini progress preview** (`VestingBar` fed with a synthetic `ScheduleProgress` at `vested = 0`), with tick
    labels "Start", "Cliff", "End" under it.
- `+ Add a schedule` (max 8).
- `▸ Advanced` holds only "Demo timings" (existing switch and copy).

**Schedule editor** (full-screen, same shell as the payout editor). Sections:

1. **Who gets it**: identical to the payout editor (address/claim code, name, `RailOptionTile`s).
2. **How much**: asset chips SOL/USDC, then a "Total" field. No share mode: vesting totals are fixed.
3. **Timing**: "Nothing unlocks for" (cliff chips) and "Fully unlocked after" (duration chips). Chip sets come
   from `cliffChoices` / `durationChoices`. A cliff longer than the duration stays disabled, as today.
4. **Progress preview** (`SchedulePreview`, new widget):
   - a `VestingBar` that animates from 0 to the fraction at a selected milestone;
   - three to four milestone rows built from `ScheduleProgress` math:
     - "{start date}: 0"
     - "{cliff date}: {atCliff} unlocks at once" (only with a cliff)
     - "Each month after: about {total/durationMonths}"
     - "{end date}: all {total}"
   - Dates use `dateText`. Start comes from the plan's start date.
   - Footer: "Deadman sends what has unlocked about once a day. {who} can also claim it any time."

Sticky preview line: "{total} to {who} over {duration} (after the {fee}% fee: ≈ {net})."

**Step 2 · Fund**: the same `FundAssetCard`. "What each payout gets" becomes "What the schedules need", listing
each schedule's total. The deposit defaults to the totals (current behaviour). The underfunded case keeps
today's copy as warning **V1**.

**Step 3 · Review**:

- Sentences: "Starting {date|today}, {who} receives {total} gradually over {duration}". Add ": nothing for the
  first {cliff}, then {atCliff} at once, then the rest evenly" when there is a cliff. Then ", {as a normal
  transfer | privately ...}."
- Then "You {can stop future unlocking at any time | can never stop these schedules or take back what they
  owe}."
- Then costs, the danger checkbox when needed, and `Create vesting plan`. The irrevocable confirm dialog is
  replaced by an extra required checkbox when irrevocable: "I understand I can never stop these schedules or
  withdraw what they owe."

Vesting delivery warnings use **total net** (§5): ⛔ when even the full total can't arrive, ⚠ when it needs a
claim.

---

## 5. Delivery math (new pure module `lib/state/delivery.dart`)

Pure Dart, no Flutter, unit-tested. It mirrors the program and keeper rules. The constants below copy values
that live elsewhere: link each one with a comment to its source.

```dart
/// Rent-exempt minimum of a 0-byte system account (a fresh wallet).
const walletRentMinLamports = 890880;            // program/keeper beneficiaryRentMin
/// Rent of one token account (165 bytes).
const tokenAccountRentLamports = 2039280;        // keeper tokenAccountSize
/// Keeper's default USDC price: lamports per USDC base unit.
const keeperUsdcLamportsPerUnit = 6.0;           // tool/keeper.dart defaultUsdcLamportsPerUnit
/// What a 0-SOL beneficiary pays the paymaster to claim tokens:
const firstTokenClaimCost = 500000;              // 0.50 USDC, account tier (kora/paymaster-account.run.toml)
const laterTokenClaimCost = 20000;               // 0.02 USDC, basic tier
/// SOL a private rail needs to move a payout on.
// minRoutableLamports in lib/state/private_rails.dart (zcash 0.002, cloak 0.015)
```

Functions (all amounts in base units):

- `(int net, int fee) splitFee(int gross, int bps)`. Copy the semantics of `keeper.dart`'s `splitFee` (floor);
  don't import the tool.
- `int? keeperAutoDeliverMin(String? mint, int feeBps)`: the smallest gross where the fee covers one token
  account's rent:
  `ceil(tokenAccountRentLamports / lamportsPerUnit / (feeBps/10000))`.
  - Returns `null` (never) when `feeBps == 0` (fee waived) or the price is unknown (non-USDC tokens).
  - USDC at 2%: 16.994 USDC ("about 17 USDC"). At 5%: 6.80 USDC.
- `class DeliveryFacts { int? walletLamports; int? tokenUnits; }`: what the beneficiary holds. `null` means
  unknown.
  - `tokenUnits > 0` means the token account exists.
  - `0` or unknown means "may not exist". The API can't tell a missing account from an empty one, so an empty
    account is treated as missing. That's acceptable: only a warning is wrong in that case.
- `final beneficiaryFactsProvider = FutureProvider.autoDispose.family<DeliveryFacts, (String address, String? mint)>`
  reads `ref.read(apiProvider).balance(address)` and `.tokenBalance(address, mint)`. Errors give unknown. The
  editor fetches it debounced, 400 ms after a valid address. This is defined in `delivery.dart`, **not** in
  `providers.dart`.
- `List<PayoutIssue> deliveryIssues({required PayoutDraft p, required int? gross, required int feeBps, required DeliveryFacts facts})`:
  returns the warnings of §6 rows D2-D6.

Payout amounts:

- Gross per payout: `previewShares` share × balance. For fixed payouts, `min(amount, remaining)`. Reuse
  `lib/state/plan_math.dart`; add a `previewGross` helper there if needed. `plan_math.dart` is not locked.
- Net: `splitFee(gross, waived ? 0 : fees.bpsFor(rail))`.

The incident, worked through: share 100 bps of 1 000 000 (1 USDC) gives gross 10 000, fee 200, net 9 800 =
0.0098 USDC. The heir holds no USDC and net < `firstTokenClaimCost`, so **D2 ⛔**. The payout is the only USDC
payout and 1 ≤ 5, so **A1**. The last USDC payout is below 100%, so **L1**. All three appear in the payout editor
preview, the Fund card and Review.

---

## 6. Warning catalogue (exact copy)

Severity:

- ⛔ danger: `DmColors.danger`, `Icons.error_outline`. Needs the Review checkbox.
- ⚠ warn: `DmColors.warn`, `Icons.warning_amber_rounded`.
- ✖ error: blocks Next or Done; shown as an `errorText` on the field.
- ⓘ info: muted, `Icons.info_outline`.

`{who}` is the name or short address, `{net}` is formatted per §2.2, `{asset}` is the symbol.

| ID  | Sev | Condition                                                                                                | Title                         | Body                                                                                                                                                                                                                                  | Action                                                |
| --- | --- | -------------------------------------------------------------------------------------------------------- | ----------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------- |
| A1  | ⚠   | share mode, value ≤ 5, last payout of its asset                                                          | Did you mean 100%?            | Only {p}% of your {asset} goes to {who}. The other {100−p}% stays locked in the plan after you're gone.                                                                                                                               | Use 100%                                              |
| A2  | ✖   | fixed SOL < 0.001                                                                                        | —                             | Fixed SOL payouts must be at least 0.001 SOL.                                                                                                                                                                                         | —                                                     |
| A3  | ✖   | share empty / ≤ 0 / > 100 / > 2 decimals                                                                 | —                             | Enter a share from 0.01 to 100.                                                                                                                                                                                                       | —                                                     |
| A4  | ✖   | fixed empty / ≤ 0 / unparseable                                                                          | —                             | Enter an amount in {unit}.                                                                                                                                                                                                            | —                                                     |
| B1  | ⚠   | beneficiary == owner wallet                                                                              | That's your own wallet        | This payout would go back to you. Use the address of the person who should receive it.                                                                                                                                                | —                                                     |
| B2  | ✖   | not an address/claim code                                                                                | —                             | This isn't a valid Solana address or claim code.                                                                                                                                                                                      | —                                                     |
| D1  | ✖   | delay ≤ interval + 60 s                                                                                  | —                             | Must be longer than your check-in interval ({interval}).                                                                                                                                                                              | Move to {default}                                     |
| D2  | ⛔  | token payout, net < `firstTokenClaimCost`, token account missing or unknown                              | Too small to arrive           | {who} would get ≈ {net}. Sending {asset} to a wallet that has never held {asset} costs more than that (about 0.50 USDC the first time), so it would never arrive. If {who} already holds {asset}, it's fine.                          | Use 100% (share) · Raise the amount (focus the field) |
| D3  | ⚠   | token payout, no/unknown account, `firstTokenClaimCost` ≤ net < `keeperAutoDeliverMin` (or that is null) | {who} will need to claim it   | Payouts under about {autoMin} to a wallet new to {asset} aren't sent automatically. {who} claims it in the Deadman app (Family Circle → Claim); with no SOL, the first claim costs about 0.50 USDC, taken from the payout.            | —                                                     |
| D4  | ⛔  | SOL payout, `walletLamports + net < walletRentMinLamports` (unknown balance counts as 0)                 | Too small to arrive           | A Solana wallet must hold at least 0.00089 SOL to exist. {who}'s wallet is empty, so ≈ {net} can't be sent there.                                                                                                                     | Raise the amount                                      |
| D5  | ⚠   | private rail, SOL, net < `minRoutableLamports[rail]`                                                     | Too small to move privately   | Private delivery needs at least {min} to move it on. A smaller amount stays on {who}'s claim key.                                                                                                                                     | —                                                     |
| D6  | ⚠   | private rail, token payout                                                                               | Private USDC isn't routed yet | {who} receives the {asset} on their private claim key, but the app can't move private {asset} onward yet (it can for SOL). Deadman also sends {0.012/0.003} SOL with it so they can, when it's ready; keep that much SOL in the plan. | —                                                     |
| F1  | ✖   | deposit > wallet balance (create)                                                                        | —                             | Your wallet has only {balance}.                                                                                                                                                                                                       | Use all                                               |
| F2  | ⛔  | an asset used by payouts has deposit 0 (create) or vault balance 0 (edit/fresh)                          | Nothing to pay out            | The plan will hold no {asset}, so payouts {n, m} have nothing to send until you deposit some from the plan card.                                                                                                                      | Add {asset} (create: focus field)                     |
| F3  | ⓘ   | edit, F2 case                                                                                            | —                             | After saving, use Deposit on the plan card to add {asset}.                                                                                                                                                                            | —                                                     |
| F4  | ⚠   | fixed payouts of an asset sum > deposit/balance                                                          | Not enough for every payout   | Fixed payouts add up to {sum}, but the plan will hold {deposit}. Later payouts get less, or nothing.                                                                                                                                  | Put in {sum}                                          |
| F5  | ⚠   | SOL deposit > wallet − reserve (create, SOL fee mode)                                                    | Keep some SOL for fees        | Leave about {reserve} in your wallet to pay network fees{ and fund this phone's check-ins}.                                                                                                                                           | Use {wallet − reserve}                                |
| F6  | ⚠   | private-rail token payouts exist and SOL deposit < stipend sum                                           | Add SOL for private delivery  | Private {asset} payouts carry {stipend} so {who} can move them. Put at least {sum} in the plan.                                                                                                                                       | Put in {sum}                                          |
| L1  | ⚠   | last payout of an asset is not share 100                                                                 | Some money stays behind       | {leftover} of your {asset} stays locked in the plan after the last payout. Nobody can withdraw it once you're gone.                                                                                                                   | Make the last payout "Everything left"                |
| P1  | ✖   | no payouts                                                                                               | —                             | Add at least one payout.                                                                                                                                                                                                              | —                                                     |
| P2  | ✖   | > 8 incl. history                                                                                        | —                             | A plan holds up to 8 payouts, paid ones included.                                                                                                                                                                                     | —                                                     |
| N1  | ✖   | label > 32 bytes                                                                                         | —                             | Plan name must be 32 characters or fewer.                                                                                                                                                                                             | —                                                     |
| V1  | ⚠   | vesting deposit < totals                                                                                 | Not fully funded              | The deposit is {short} short. Unlocking pauses when the plan runs dry, until you deposit more.                                                                                                                                        | Put in {totals}                                       |

Placement:

- The payout editor shows A*, B*, D* for that payout.
- Payout cards show their worst warning, title only.
- Fund shows D*, F*, L1 per asset.
- Review shows everything except ✖ (those block earlier) and ⓘ, grouped under the payout they belong to. Plan-wide
  warnings go under the leftover sentence.
- D2/D3/D4 need `DeliveryFacts`. While those are loading, show nothing. When they're unknown, use the "missing"
  branch: D2 already contains "If {who} already holds {asset}, it's fine."

---

## 7. Components

Existing widgets reused: `Card` (theme: 20px radius, `DmColors.line` border), `ChoiceChip`, `SegmentedButton`,
`FilledButton` / `OutlinedButton` (theme heights 54/50), `TextField` with the theme decoration,
`ExpansionTile`, `SwitchListTile`, `CheckboxListTile`, `RailBadge`, `VestingBar`, `toast`, `runGuarded`,
`amountText`, `formatUnits`, `percentText`, `previewShares`, `splitRules`, `graceChoices`, `cliffChoices`,
`durationChoices`, `durationLabel`, `dateText`, `short`.

New, in files that aren't locked:

| Widget / unit                                      | File                                         | Purpose                                                                                                                                                                        |
| -------------------------------------------------- | -------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `StepHeader`                                       | `lib/ui/widgets/plan_steps.dart`             | 2-3 labelled dots; current = mint filled, done = mint outline + check, next = line. Tappable for done steps. Semantics "Step {i} of {n}, {label}".                             |
| `StepScaffold`                                     | same                                         | AppBar + `StepHeader` + scrollable body + bottom bar (`SafeArea`, 16px padding, Back/Next). Handles `PopScope`.                                                                |
| `SectionCard`                                      | same                                         | Card with a numbered title ("1 Who gets it") in titleLarge 18 and 16px padding.                                                                                                |
| `WarningTile`                                      | same                                         | Icon + bold title + body + optional action `TextButton`; severity colors at 12% alpha background; `Semantics(liveRegion: true)`.                                               |
| `RailOptionTile`                                   | same                                         | Radio card for a rail (§2.2).                                                                                                                                                  |
| `AmountModeField`                                  | same                                         | Segmented mode + big share field + words line + quick chips, or fixed field. Two controllers.                                                                                  |
| `LivePreview`                                      | same                                         | Sticky preview line + top warning.                                                                                                                                             |
| `DelayStrip`                                       | same                                         | Decorative timeline strip.                                                                                                                                                     |
| `PayoutSummaryCard` / `HistoryPayoutCard`          | `lib/ui/screens/rules_editor.dart` (private) | Timeline cards.                                                                                                                                                                |
| `PayoutEditorPage`                                 | `lib/ui/screens/payout_editor.dart`          | Full-screen payout editor; returns `PayoutDraft?`.                                                                                                                             |
| `FundAssetCard`                                    | `lib/ui/widgets/fund_asset_card.dart`        | Shared by both editors.                                                                                                                                                        |
| `ReviewSection`, `CostRow`                         | `lib/ui/widgets/plan_steps.dart`             | Review blocks.                                                                                                                                                                 |
| `ScheduleEditorPage`, `SchedulePreview`            | `lib/ui/screens/schedule_editor.dart`        | Vesting schedule editor + milestones.                                                                                                                                          |
| `PayoutDraft`                                      | `lib/state/plan_review.dart`                 | Plain immutable draft (beneficiary, rail, mint, mode, bps/amount, afterSecs, name) with `toRuleSpec()` and `validate()` returning issue codes. `RuleSpec` stays the wire type. |
| `payoutSentence`, `leftoverSentence`, `planIssues` | `lib/state/plan_review.dart`                 | Pure text and warning builders.                                                                                                                                                |
| `delivery.dart`, `contact_names.dart`              | `lib/state/`                                 | §5, §2.2.                                                                                                                                                                      |

The `_Unit` dropdown row ("After [72px] [min|days] of silence") and the `_SharePreview` card are removed. Their
information now lives in When and in the Fund breakdown.

---

## 8. States

| State                        | Behaviour                                                                                    |
| ---------------------------- | -------------------------------------------------------------------------------------------- |
| Empty (create)               | §2.1 empty card. The payout editor opens on first entry.                                     |
| Loading fees                 | Fee lines show "fee loading…"; previews say "before fees". Nothing blocks.                   |
| Fees error                   | "Couldn't load fees. Amounts shown before fees." (ⓘ under the first preview).                |
| Loading wallet balance       | "Checking your wallet…" helper. `Use all` is disabled.                                       |
| Wallet balance error         | "Couldn't read your wallet balance." F1 isn't evaluated.                                     |
| Loading plan balances (edit) | Previews show the share only ("Everything left of your USDC"), no ≈ amount.                  |
| Beneficiary facts loading    | No delivery warning yet; a small 12px progress indicator next to the address field's suffix. |
| Beneficiary facts error      | Treated as unknown (§6 placement).                                                           |
| Busy (saving)                | The button shows the spinner. Back, step taps and system back are disabled.                  |
| Save failed                  | `runGuarded` toast, as today. Stay on Review with all input kept.                            |
| Offline                      | Same as the error rows. Saving fails with the existing error text.                           |
| Unguarded plans after create | Existing toast text, unchanged.                                                              |

---

## 9. Accessibility

- Touch targets ≥ 48×48dp: chips (`materialTapTargetSize: padded`), the paste/remove `IconButton`s, radio tiles
  (≥ 64dp), checkbox rows and step dots (the hit area covers dot + label).
- Contrast on `DmColors.surface` #14161A:
  - text #F2F3F5 ≈ 16:1;
  - muted #8A8F98 ≈ 5.6:1;
  - warn #FFB547 ≈ 10:1;
  - danger #FF4D5E ≈ 5.4:1;
  - alive #3DF5A7 ≈ 13:1.

  All pass AA for body text. Don't put muted text on `DmColors.raised` below 13px.

- Warnings never rely on color: each has an icon and a text title. ⛔ and ⚠ in this doc are just shorthand; the UI
  uses Material icons.
- Text scaling to 200%: no fixed-height rows. Cost rows `Wrap`; the share field has a minimum width, not a
  maximum; summary cards grow.
- Semantics:
  - the share field reads "Share of what's left, {p} percent, {words line}";
  - previews and new warnings are `liveRegion`s, so TalkBack announces changes;
  - history cards say "read only";
  - the step header announces "Step 2 of 3, Fund".
- Focus order follows the visual order. `Next` moves focus to the step's first field. A validation error moves
  focus to the first invalid field and scrolls it into view (`Scrollable.ensureVisible`).
- Numbers: keyboards are `numberWithOptions(decimal: true)`, and both `,` and `.` are accepted (as today).

---

## 10. Copy reference (everything not already quoted above)

| Where                        | Text                                                                                                          |
| ---------------------------- | ------------------------------------------------------------------------------------------------------------- |
| AppBar create / edit / fresh | New inheritance plan · Edit plan · Start a new plan                                                           |
| Steps                        | Payouts · Fund · Review                                                                                       |
| Step 1 intro                 | Who gets what if you stop checking in.                                                                        |
| Plan card title              | Plan                                                                                                          |
| Plan name label / hint       | Plan name · e.g. Family, Emergency fund                                                                       |
| Interval row                 | You check in every · {7 days}                                                                                 |
| Timeline root                | Last check-in                                                                                                 |
| Timeline node                | After {delay} of silence                                                                                      |
| Add button                   | Add a payout                                                                                                  |
| Next buttons                 | Next: fund the plan · Next: review · Create plan · Save changes · Start new plan                              |
| Back                         | Back                                                                                                          |
| Payout editor title          | New payout · Payout {n}                                                                                       |
| Section titles               | Who gets it · What they get · When                                                                            |
| Name label/helper            | Their name (optional) · Only saved on this phone, to make your plan easier to read.                           |
| Rail heading                 | How it arrives                                                                                                |
| Asset heading                | Which money                                                                                                   |
| Mode segments                | Share of what's left · Fixed amount                                                                           |
| Quick chips                  | 25% · 50% · Everything left                                                                                   |
| When label                   | Send it after this long without a check-in                                                                    |
| Custom chip / field          | Custom · Number · days / minutes                                                                              |
| Done                         | Done                                                                                                          |
| Discard dialog               | Discard this plan? / Discard your changes? · Your payouts won't be saved. · Keep editing · Discard            |
| Remove dialog                | Remove this payout? · Remove · Keep                                                                           |
| Fund step intro              | How much goes into the plan now. You can add more later.                                                      |
| Fund field                   | Put in this plan · In your wallet: {balance} · Use all                                                        |
| Breakdown heading            | What each payout gets                                                                                         |
| Leftover line                | Left in the plan afterwards: {amount}                                                                         |
| Review headings              | If you stop checking in · Costs                                                                               |
| Review empty name            | Unnamed plan                                                                                                  |
| Danger checkbox              | Create it anyway. I understand the payouts marked with a red sign may never arrive. (edit: "Save it anyway…") |
| Review footer create         | One wallet approval creates the plan, sets up this phone's check-ins and makes your deposits.                 |
| Review footer edit           | One wallet approval saves these payouts.                                                                      |
| Toasts                       | Plan created · Plan updated                                                                                   |
| Vesting titles               | New vesting plan · Schedules · Fund · Review · Add a schedule · Create vesting plan                           |
| Vesting revocable segment    | Can you stop it later? · Yes, I can stop it · No, it's locked in                                              |
| Vesting timing labels        | Nothing unlocks for · Fully unlocked after                                                                    |
| Vesting irrevocable checkbox | I understand I can never stop these schedules or withdraw what they owe.                                      |

The wording calls a tier a **payout** throughout the editors. Plan cards (`pulse_tab.dart`) and Family Circle
still say "tier". Align them in a follow-up once those files are free (§12).

---

## 11. Acceptance criteria and tests

Unit tests (`test/state/delivery_test.dart`, `test/state/plan_review_test.dart`):

1. The incident: share 100 bps of 1 USDC with 2% fees and an unknown heir account gives net 9 800 units and
   issues {D2, A1, L1}. Share 10 000 bps of 1 USDC gives net 980 000 and D3 (needs a claim), not D2.
2. `keeperAutoDeliverMin(usdc, 200)` = 16 994 000; `(usdc, 500)` = 6 797 600 (± rounding to the keeper's
   floor); `(usdc, 0)` = null.
3. SOL: net 500 000 lamports to an empty wallet gives D4. The same payout to a wallet holding 1 000 000 gives no
   D4.
4. A heir token account that exists (`tokenUnits > 0`) clears D2/D3.
5. `payoutSentence` for share 100 / share 25 / fixed, on each rail, matches §2.4 exactly.
6. `PayoutDraft` round-trips `RuleSpec` (bps 10000 shows as "100", never "100.0").

Widget tests (`test/ui/rules_editor_test.dart`, rewritten; `test/ui/vesting_editor_test.dart`, updated):

1. **Regression**: create a payout, USDC, share; type `1`.
   - The words line shows "1 out of every 100 USDC left" and "Did you mean 100%?".
   - Fund: type `1` USDC. The breakdown shows "≈ 0.0098 USDC" and "Too small to arrive".
   - Review: `Create plan` without ticking the box doesn't call `createVault`. Tapping "Use 100%" in Review
     removes D2 (D3 remains), and Create calls `createVault` with rule amount 10000 bps.
2. Switching Share ↔ Fixed keeps each mode's value (100% doesn't become 100 USDC).
3. Edit: history payouts render read-only. Save sends only pending payouts (existing test, new labels).
4. A last payout under 100% shows L1 in Review, and its action sets 100%. The old "Funds will be left behind"
   dialog no longer exists.
5. A USDC payout with deposit 0 shows F2 in Fund and Review. Saving requires the checkbox.
6. Monthly plan active: the rail tile fee line reads "No fee: monthly plan active".
7. Changing the interval to 30 days flags a 10-day payout with D1, and "Move to 37 days" fixes it.
8. Vesting: the schedule editor preview shows the cliff milestone; an irrevocable plan requires its checkbox.
9. Text scale 2.0: no overflow on any step (`tester.view` + `MediaQuery(textScaler)`).

Done when `flutter analyze` is clean and `flutter test` is green.

---

## 12. Follow-ups outside this change (locked files)

- `pulse_tab.dart` plan card and `circle_tab.dart`:
  - say "payout" instead of "tier";
  - show the D2/D3 status on existing plans (the owner's current 1% plans);
  - offer "Edit plan" from that warning.
- `docs/HOW_IT_WORKS.md` §3.8 still lists the account tier at 1.00 USDC; `KORA.md` and the run configs use 0.50.
- A tool to find existing plans whose last payout per asset is a share ≤ 5% (the owner's test plans), so they
  can be fixed.
- Optional: the keeper could create the heir's USDC account for **subscribed** plans out of the subscription
  revenue. Today a fee-waived plan never gets automatic token delivery to a new wallet (D3 always applies).
