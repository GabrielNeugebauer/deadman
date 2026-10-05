---
name: Deadman
description: The self-custody safety net for Seeker. Near-black instrument panel, one signal accent, status color only where time is running out.
colors:
  void: "#050707"
  graphite: "#0F1615"
  raise: "#141D1C"
  line: "#1D2928"
  track: "#17211F"
  deep: "#0B3A36"
  tide: "#1FA597"
  signal: "#54F9E8"
  bone: "#E8F1F0"
  sub: "#8FA3A1"
  mist: "#6F8482"
  status-on-track: "#54F9E8"
  status-attention: "#FFB547"
  status-due: "#FF5D73"
  status-locked: "#A493FF"
  status-released: "#8FA3A1"
typography:
  headline:
    fontFamily: "Outfit"
    fontSize: "30px"
    fontWeight: 700
    lineHeight: 1.15
    letterSpacing: "-0.9px"
  title-large:
    fontFamily: "Outfit"
    fontSize: "20px"
    fontWeight: 700
    lineHeight: 1.25
    letterSpacing: "-0.4px"
  title-medium:
    fontFamily: "Outfit"
    fontSize: "17px"
    fontWeight: 600
    lineHeight: 1.3
    letterSpacing: "-0.2px"
  body:
    fontFamily: "Outfit"
    fontSize: "15px"
    fontWeight: 400
    lineHeight: 1.45
  body-small:
    fontFamily: "Outfit"
    fontSize: "13px"
    fontWeight: 400
    lineHeight: 1.4
  button:
    fontFamily: "Outfit"
    fontSize: "17px"
    fontWeight: 700
  countdown:
    fontFamily: "JetBrains Mono"
    fontSize: "44px"
    fontWeight: 400
    letterSpacing: "-1px"
  stat:
    fontFamily: "JetBrains Mono"
    fontSize: "22px"
    fontWeight: 400
  data:
    fontFamily: "JetBrains Mono"
    fontSize: "13px"
    fontWeight: 400
    lineHeight: 1.5
  chip:
    fontFamily: "JetBrains Mono"
    fontSize: "11px"
    fontWeight: 500
    letterSpacing: "1.3px"
  label:
    fontFamily: "JetBrains Mono"
    fontSize: "10.5px"
    fontWeight: 400
    letterSpacing: "1.5px"
rounded:
  chip: "6px"
  tile: "10px"
  button: "12px"
  card: "14px"
  dialog: "16px"
  sheet: "20px"
spacing:
  xxs: "4px"
  xs: "6px"
  sm: "8px"
  md: "12px"
  lg: "16px"
  xl: "20px"
  xxl: "24px"
  xxxl: "32px"
  gutter: "20px"
  card-padding: "18px"
components:
  button-primary:
    backgroundColor: "{colors.signal}"
    textColor: "{colors.void}"
    typography: "{typography.button}"
    rounded: "{rounded.button}"
    height: "56px"
  button-primary-disabled:
    backgroundColor: "{colors.raise}"
    textColor: "{colors.mist}"
  button-secondary:
    backgroundColor: "{colors.graphite}"
    textColor: "{colors.bone}"
    rounded: "{rounded.button}"
    height: "48px"
  button-text:
    textColor: "{colors.signal}"
  card:
    backgroundColor: "{colors.graphite}"
    rounded: "{rounded.card}"
    padding: "{spacing.card-padding}"
  icon-tile:
    backgroundColor: "{colors.raise}"
    textColor: "{colors.bone}"
    rounded: "9px"
    size: "36px"
  status-chip:
    typography: "{typography.chip}"
    rounded: "{rounded.chip}"
    padding: "6px 10px"
  input:
    backgroundColor: "{colors.raise}"
    textColor: "{colors.bone}"
    rounded: "{rounded.button}"
    padding: "16px"
  nav-indicator:
    backgroundColor: "{colors.deep}"
    textColor: "{colors.signal}"
    rounded: "{rounded.tile}"
  segment-selected:
    backgroundColor: "{colors.deep}"
    textColor: "{colors.signal}"
    rounded: "{rounded.tile}"
---

# Design System: Deadman

## Overview

**Creative North Star: "The Instrument Panel at Night"**

Deadman is read the way a pilot reads a cockpit after dark: a near-black field, a few calm readouts, and color only on the gauge that needs you. The owner opens it to prove they are alive, often one-handed and in seconds; a beneficiary opens it to learn exactly what will happen and when. Both want precision, not reassurance.

The canvas is void, cards are graphite with a 1px line, and there is one accent, **signal**, that marks the thing to do (Check in, Release this tier, + New plan) and the healthy state (on track). Every number that matters, from countdowns and amounts to addresses, durations and status words, is set in JetBrains Mono; everything a person reads as language is Outfit. Status colors live only on rings, chips and time labels, so the screen stays quiet until a window is closing.

This is an Operate surface. Brand lives in precise details: the offset two-half mark, butt-ended rings, square status dots, letter-spaced mono captions. Nothing glows, nothing is glass, nothing is a gradient.

**Key Characteristics:**

- Near-black canvas, graphite cards, 1px line borders, no shadows.
- One accent (signal) for actions and the on-track state.
- Status color confined to rings, chips and time labels.
- Mono for data and status, Outfit for language.
- Flat, butt-capped rings; dashed ring when a tier is due.

## Colors

A cold teal-black ladder with one electric cyan, plus four status hues that only appear when time is involved.

### Primary

- **Signal** (#54F9E8): primary buttons (with void text), text actions, selected icons, the on-track ring and chip, focus borders, the caret. Its rarity is the point.
- **Tide** (#1FA597): the lower half of the mark. Secondary brand color for the mark and the rare second series; never a button fill on its own screen next to signal.

### Neutral

- **Void** (#050707): scaffold, app bar, navigation bar, text on signal.
- **Graphite** (#0F1615): cards, dialogs, sheets, outlined buttons.
- **Raise** (#141D1C): icon tiles, inputs, chips, snackbars.
- **Line** (#1D2928): every 1px border and divider.
- **Track** (#17211F): empty part of rings and progress bars.
- **Deep** (#0B3A36): selected containers: navigation pill, selected segment, selected chip, tonal button.
- **Bone** (#E8F1F0): primary text and icons.
- **Sub** (#8FA3A1): secondary text, body copy (`bodyMedium`), released status.
- **Mist** (#6F8482): captions and mono labels only (4.6:1 on graphite, 4.3:1 on raise: never body text on raise).

### Status

- **On track** (= signal): check-in inside its window.
- **Attention** (#FFB547): check-in overdue, or the last 25% of a window.
- **Due** (#FF5D73): a tier is due or releasing; panic lockdown.
- **Locked** (#A493FF): duress lock / lockdown active. The only purple in the product.
- **Released** (= sub): paid, history only.

Chip and tile tints are the status color at 12–14% alpha over the surface.

### Named Rules

**The One Signal Rule.** Signal is the only accent. A screen has one filled signal button at most; everything else is text actions, outlined graphite buttons, or neutral.

**The Status Lives on the Clock Rule.** Status colors appear only on rings, status chips, countdowns and time labels ("Due now", "IN 2M 40S"). Never as a card fill, a button fill or a full-width banner. The panic card may take a faint due border (`due` at 35%) and a due-tinted icon tile; its fill stays graphite.

**The No-Purple-Selection Rule.** Selected and active states are deep + signal. Purple means locked and nothing else.

## Typography

**Body Font:** Outfit (bundled in `assets/brand/fonts`, Regular to ExtraBold)
**Data Font:** JetBrains Mono (bundled, Regular to Bold, ligatures off)

**Character:** Outfit is a geometric sans with tight, confident headlines; JetBrains Mono gives every number a fixed width, so countdowns don't jitter and addresses read character by character.

Fonts ship with the app; `GoogleFonts.config.allowRuntimeFetching` is false. Only use weights 400–800 (Outfit) and 400–700 (Mono).

### Hierarchy

- **Headline** (Outfit 700, 30, -0.9): screen titles "Pulse", "Family Circle", "Security" (`headlineMedium`).
- **Title large** (Outfit 700, 20, -0.4): section headers "Release plans" (`titleLarge`), dialog titles.
- **Title medium** (Outfit 600, 17): card titles, plan names (`titleMedium`); list rows use 16/600.
- **Body** (Outfit 400, 15, 1.45, sub): lead paragraphs, explanations (`bodyMedium`, which is **sub**, not bone). Use `bodyLarge` (16, bone) for primary prose.
- **Body small** (Outfit 400, 13, mist): fine print under buttons (`bodySmall`).
- **Button** (Outfit 700, 17) on primary; Outfit 600, 15 on secondary and text buttons.
- **Countdown** (Mono 400, 44, -1): ring readout, colored by status (`DMType.countdown`).
- **Stat** (Mono 400, 22): stat tile values (`DMType.stat`).
- **Data** (Mono 400, 13, sub, 1.5): amounts, addresses, durations in running lines: "0.100 SOL · 0 USDC protected" (`DMType.data`).
- **Chip** (Mono 500, 11, +1.3, caps): status chips (`DMType.chip`).
- **Label** (Mono 400, 10.5, +1.5, caps, mist): "DAY STREAK", "BEST" (`DMType.label`, `MonoLabel`).

### Named Rules

**The Mono Means Measured Rule.** Mono is for things that are counted, timed, addressed or a status word. Never for headings, buttons or sentences.

## Layout

Phone-first single column. Horizontal gutter 20 (`DMSpace.gutter`). Card padding 18; list rows 16 × 14. Vertical rhythm on a 4pt scale: 8 between a section header and its first card, 12–16 between cards, 24 above a new section. Screens open with a `PageHeader` (title + trailing mark or status chip, optional lead paragraph in sub), then content. On web the app stays phone-shaped inside `WebFrame`.

The Pulse tab order is fixed: header → ring → Check in → stat tiles → Release plans. The check-in button is always the most prominent element.

## Elevation & Depth

Flat. No shadows anywhere (`elevation: 0` on every component). Depth comes from the tonal ladder void → graphite → raise and from 1px line borders. Scrims are void at 80%.

## Shapes

Soft rectangles: chip 6, icon tile 9–10, button and input 12, card 14, dialog 16, bottom sheet 20 (top corners). Status dots are **squares** (6px), never circles. Rings are butt-capped, 10px stroke. The mark is two offset half-annuli; never redraw it round-capped, rotated or glowing.

## Components

All shared pieces live in `lib/ui/widgets/brand/` (import `brand.dart`).

### Buttons

- **Primary** (`FilledButton`): signal fill, void text, 56 high, radius 12, Outfit 17/700, optional leading icon 20. Disabled: raise fill, mist text. One per screen.
- **Secondary** (`OutlinedButton`): graphite fill, 1px line, bone text, 48 high, radius 12. Pairs like Deposit / Withdraw sit side by side with 10 between.
- **Text** (`TextButton`): signal, Outfit 15/500. Section actions use an add icon: "+ New plan".
- **Tonal** (`FilledButton.tonal`): deep fill, signal text, for a secondary call in a selected context.

### Status chips

`StatusChip(status, label:)`: square dot + mono caps on the status tint, radius 6. Dense variant inside rows. Label states facts: "TIER IN 56S", "2 H SILENT", "DUE NOW", "UNLOCKED".

### Tags

`DMTag`: 1px line outline, radius 6, icon 14 + Outfit 13/500 bone. Used for rails (Solana, Cloak, Zcash).

### Cards / Containers

- `DMCard`: graphite, radius 14, 1px line, padding 18, flat. Optional tap ink.
- `DMListGroup`: one card holding `DMListRow`s split by full-width 1px lines, with an optional header block. Use it instead of stacking small cards.
- Cards never nest. Inside a card, separate blocks with a `Divider`, not a second card.

### List rows

`DMListRow`: `IconTile` (36, raise, bone icon) + title (Outfit 16/600) + mono detail (12.5, sub) + trailing value, chip or icon action. Minimum height 56.

### Stat tiles

`StatTiles`: one graphite card split into equal cells by 1px lines; each `StatTile` is a mono value (22) over a mono caps label (mist).

### Inputs / Fields

Raise fill, 1px line, radius 12, padding 16. Focus: 1.5px signal border, label turns signal. Error: due border and due helper text. Hint text is sub.

### Navigation

`NavigationBar`: void background (add a 1px line above it), height 72, deep rounded pill (radius 10) behind the selected icon, signal selected icon, bone selected label, mist unselected.

### Selection controls

Switch: signal track with void thumb when on; raise track, mist thumb, line outline when off. Checkbox and radio: signal. Segmented buttons: deep + signal when selected, graphite + sub otherwise.

### Dialogs, sheets, snackbars

Graphite, 1px line, radius 16 (sheets 20 top), no elevation, void scrim. Snackbars float on raise with a line border and a signal action.

### Pulse ring (signature)

`PulseRing(progress:, status:, child: PulseReadout(...))`. Track color `track`; arc in the status color from 12 o'clock clockwise, butt ends, no glow; progress eases over 600ms. When `status` is due, the whole ring becomes 48 dashes on a due-tinted track. `PulseReadout` stacks the status chip, the mono countdown (scales down to fit) and a sub caption ("until next check-in", "releasing to AppA…9PbA").

### Mark

`DeadmanMark` (painted, signal over tide; `.mono` for single-color), `DeadmanWordmark` (Outfit 800), `DeadmanLockup`. In app headers the mark sits top-right at about 28–30.

## Do's and Don'ts

### Do:

- **Do** keep one filled signal button per screen and make it the action the screen exists for.
- **Do** put every amount, address, duration, countdown and status word in mono.
- **Do** pair every status color with a word or a countdown.
- **Do** group related rows in one `DMListGroup` with 1px dividers.
- **Do** use `DM.*` tokens and `DMType.*` styles; `DmColors` is a deprecated alias kept only for migration.

### Don't:

- **Don't** fill cards, buttons or banners with a status color.
- **Don't** use purple for selection or decoration; purple means locked.
- **Don't** add gradients, glows, blur, glass or shadows.
- **Don't** nest cards, or build screens out of identical icon + heading + text cards.
- **Don't** use emoji or Unicode glyphs as icons; use Material outlined icons at one weight.
- **Don't** put a kicker or eyebrow label above a heading.
- **Don't** show any lock, duress or "frozen" indicator in a duress session; it must look normal.
