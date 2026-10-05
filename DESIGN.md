---
name: Deadman
description: Check in, or check out. A void-black dead man's switch with a pixel skull for a mark, one pulse-green accent, and status color that means exactly one thing each.
colors:
  void: "#0A0B0D"
  pit: "#131418"
  grave: "#16181C"
  raise: "#1F2227"
  line: "#24272E"
  seam: "#2E3138"
  deep: "#0F2A21"
  bone: "#F1F0EA"
  haze: "#CED1D7"
  dust: "#A7ABB3"
  ash: "#8B8F98"
  pulse: "#3EF5A8"
  missed: "#FFB547"
  flatline: "#FF4D5E"
  status-alive: "#3EF5A8"
  status-missed: "#FFB547"
  status-due: "#FF4D5E"
  status-released: "#8B8F98"
  status-locked: "#F1F0EA"
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
    fontWeight: 600
  countdown:
    fontFamily: "JetBrains Mono"
    fontSize: "16.5% of the ring diameter, 32-104px"
    fontWeight: 500
    letterSpacing: "-0.02em"
  data:
    fontFamily: "JetBrains Mono"
    fontSize: "13px"
    fontWeight: 400
    lineHeight: 1.5
  label:
    fontFamily: "JetBrains Mono"
    fontSize: "10.5px"
    fontWeight: 400
    letterSpacing: "1.5px"
  sticker:
    fontFamily: "Silkscreen"
    fontSize: "10.5px"
    fontWeight: 400
    letterSpacing: "0.24em"
  tagline:
    fontFamily: "Silkscreen"
    fontSize: "13px"
    fontWeight: 400
    letterSpacing: "0.3em"
rounded:
  chip: "6px"
  sticker: "8px"
  tile: "10px"
  button: "14px"
  card: "16px"
  dialog: "18px"
  sheet: "22px"
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
    backgroundColor: "{colors.pulse}"
    textColor: "{colors.void}"
    typography: "{typography.button}"
    rounded: "{rounded.button}"
    height: "56px"
  button-primary-disabled:
    backgroundColor: "{colors.raise}"
    textColor: "{colors.ash}"
  button-secondary:
    backgroundColor: "{colors.grave}"
    textColor: "{colors.bone}"
    rounded: "{rounded.button}"
    height: "48px"
  button-text:
    textColor: "{colors.pulse}"
  square-button:
    backgroundColor: "{colors.grave}"
    rounded: "{rounded.button}"
    size: "44px in a 48px target"
  card:
    backgroundColor: "{colors.grave}"
    rounded: "{rounded.card}"
    padding: "{spacing.card-padding}"
  select-card-selected:
    backgroundColor: "{colors.deep}"
    borderColor: "{colors.pulse}"
    rounded: "{rounded.card}"
  icon-tile:
    backgroundColor: "{colors.void}"
    textColor: "{colors.bone}"
    rounded: "25% of size"
    size: "36px"
  sticker:
    typography: "{typography.sticker}"
    backgroundColor: "status color at 13%"
    rounded: "{rounded.sticker}"
    padding: "7px 11px"
  input:
    backgroundColor: "{colors.pit}"
    borderColor: "{colors.seam}"
    textColor: "{colors.bone}"
    rounded: "{rounded.button}"
    padding: "16px"
  nav-indicator:
    backgroundColor: "{colors.deep}"
    textColor: "{colors.pulse}"
    rounded: "stadium"
---

# Design System: Deadman

## Overview

**Creative North Star: "Proof of Life"**

Deadman is a dead man's switch, and it says so with a straight face and a pixel skull. The ground is void black, the cards are grave, and the one thing that glows is the pulse: a segmented ring of green ticks counting down to the next check-in. When the owner goes quiet the same ring turns amber, then red and starts to blink; when every tier has paid out it goes grey and the skull closes its eyes. The owner opens it to prove they are alive, often one-handed and in seconds; a beneficiary opens it to learn exactly what will happen and when.

The brand book is docs/brand/v2 (13 pages). Pages 1-9 define the identity; pages 10-13 are app mockups and the binding reference for screens.

The type has three jobs and three faces. **Outfit** (the app's own type, kept from v1 as the book instructs) carries every word a person reads. **JetBrains Mono** carries addresses, amounts and timers. **Silkscreen** carries stickers, step counters and the tagline, and nothing else.

This is an Operate surface. The pixel art is the brand, used in precise places: the mark, stickers, section figures, the app-bar button, empty states. Layout, controls and navigation stay Material 3.

**Key Characteristics:**

- Void ground, grave cards, 1px line borders, no shadows.
- One accent (pulse) for actions and the alive state.
- Four status colors, each tied to one skull mood and one sticker word.
- Pixel figures drawn from grids in whole device pixels; never scaled bitmaps, never antialiased.
- The Pulse tab is the ring, the countdown and the button, and the ring takes all the height it can get.

## Colors

Seven colors from the book (Void, Grave, Bone, Pulse, Missed, Flatline, Ash) plus the steps the mockups use between them. Tokens live in `DM` (`lib/ui/theme/tokens.dart`).

### Ground and surfaces

- **Void** (#0A0B0D): scaffold, app bar, navigation bar, icon tiles inside cards, text on pulse.
- **Pit** (#131418): text inputs, sunk below the card.
- **Grave** (#16181C): cards, dialogs, sheets, outlined buttons, the square app-bar button.
- **Raise** (#1F2227): snackbars, tooltips, disabled primary buttons.
- **Line** (#24272E): every 1px border and divider; the dim ticks of the ring.
- **Seam** (#2E3138): input and tag outlines.
- **Deep** (#0F2A21, pulse at 13% on void): selected containers: navigation pill, selected radio card, selected segment, alive sticker.

### Text

| Token            | Use                                                                      | on void | on grave | on raise |
| ---------------- | ------------------------------------------------------------------------ | ------- | -------- | -------- |
| **Bone** #F1F0EA | primary text, titles, addresses in the ring                              | 17.2    | 15.6     | 14.0     |
| **Haze** #CED1D7 | ring captions, footnotes on unselected cards                             | 12.9    | 11.6     | 10.4     |
| **Dust** #A7ABB3 | body copy (`bodyMedium`), data lines                                     | 8.5     | 7.7      | 6.9      |
| **Ash** #8B8F98  | secondary text, captions, hints, plan name under the countdown, released | 6.1     | 5.5      | 4.9      |

### Status

`DMStatus` maps one value to one color, one word, one figure:

| Status     | Color                       | Sticker  | Figure            | Skull mood               | Means                                                   |
| ---------- | --------------------------- | -------- | ----------------- | ------------------------ | ------------------------------------------------------- |
| `alive`    | Pulse #3EF5A8               | ALIVE    | mark skull        | alive (wink + heartbeat) | checked in on time; nothing moves                       |
| `missed`   | Missed #FFB547              | MISSED   | squinting skull   | missed                   | the check-in window ran out; the next tier counts down  |
| `due`      | Flatline #FF4D5E            | TIER DUE | crossed-out skull | due                      | silent past a release tier; funds go to the beneficiary |
| `released` | Ash #8B8F98                 | RELEASED | ghost             | released (eyes closed)   | every tier has paid out                                 |
| `locked`   | Bone #F1F0EA on an ash tint | LOCKED   | pixel lock        | mark                     | lockdown (Panic or duress)                              |

Locked is not in the book; it borrows bone and the lock so it never competes with the four moods. There is no purple anywhere.

Sticker and tile tints are the status color at 13% (locked: ash at 18%). Unlit ring ticks are `line`, or flatline at 33% while a tier is due. `statusForWindow(remaining, releasing:, locked:)` returns `missed` once the window reaches 0, never earlier: amber means a check-in was actually missed.

### Named Rules

**The One Pulse Rule.** Pulse is the only accent. One filled pulse button per screen; everything else is text actions, grave outlined buttons, or neutral.

**The One Meaning Rule.** Missed, Flatline and Ash are statuses, not decoration. Amber never means "warning" in general, red never means "error" in general on a plan surface: errors in forms use flatline only on the field and its helper text.

**The Status Lives on the Clock Rule.** Status color appears on the ring, stickers, countdowns, skull faces and time labels. Never as a card fill, a button fill or a full-width banner. The panic card may take a faint flatline border (35%); its fill stays grave.

## Typography

**Text:** Outfit (bundled, 400-800). **Data:** JetBrains Mono (bundled, 400-700, ligatures off). **Pixel:** Silkscreen (bundled, 400 and 700). All three ship in `assets/brand/fonts` with their OFL licenses; `GoogleFonts.config.allowRuntimeFetching` is false. Outfit has no math symbols, so every Outfit style falls back to JetBrains Mono (`DMType.symbolFallback`) for glyphs like "≈".

The book's Schibsted Grotesk is for marketing and pitch copy only; "the app keeps its current type", and the mockups confirm Outfit.

### Hierarchy

- **Headline** (Outfit 700, 30, -0.9): screen titles "Pulse", "Family Circle", "Security" (`headlineMedium`).
- **Title large** (Outfit 700, 20): section headers, dialog titles, "New payout" (`titleLarge`).
- **Title medium** (Outfit 600, 17): card titles, plan names (`titleMedium`). Radio-card titles are 17/700.
- **Body** (Outfit 400, 15, 1.45, dust): lead paragraphs (`bodyMedium`). `bodyLarge` (16, bone) for primary prose.
- **Body small** (Outfit 400, 13, ash): fine print (`bodySmall`).
- **Button** (Outfit 600, 17) on primary; Outfit 600, 15 on secondary and text buttons.
- **Countdown** (Mono 500, 16.5% of the ring diameter, 32-104): `DMType.countdown(color, size:)`; `PulseReadout` sizes it from the ring.
- **Data** (Mono 400, 13, dust): amounts, addresses, durations in running lines (`DMType.data`).
- **Label** (Mono 400, 10.5, +1.5, caps, ash): small mono captions (`DMType.label`, `MonoLabel`).
- **Sticker** (Silkscreen 400, 10.5, +0.24em, caps): `DMType.sticker(color)`, via `Sticker`.
- **Tagline** (Silkscreen 400, 13, +0.3em, caps, pulse): "CHECK IN, OR CHECK OUT." (`DMType.tagline()`).

### Named Rules

**The Silkscreen Is a Sticker Rule.** Silkscreen sets one to three short words in caps: sticker words, "STEP 1/3", the tagline, a splash headline. Never sentences, buttons, amounts, addresses or anything someone must read exactly.

**The Mono Means Measured Rule.** Mono is for things counted, timed or addressed. Never headings, buttons or sentences.

## Pixel art

All figures are `PixelSprite` grids in `lib/ui/widgets/brand/pixel_art.dart`, transcribed cell by cell from the book and checked by tests. `PixelArt` draws them with a custom render object: the cell snaps down to whole device pixels (at least one), the origin snaps to the device grid, and nothing is antialiased. Pass the target height as `size`; the result may come out a pixel or two smaller, never blurred.

- **Mark skull** (11×11): the logo and app icon. Neutral square eyes.
- **Moods** (11×11, same outline and jaw): alive (one eye, heartbeat), missed (squint), due (X eyes), released (closed eyes).
- **Heart** (11×10): check-ins. Section figure on the payout editor.
- **Tombstone** (11×12, RIP): a release tier is due.
- **Ghost** (11×11): plan fully released; the RELEASED sticker.
- **Lock** (9×10): lockdown. Drawn for the app on the cast's grid.
- **Wordmark** (41×7): DEADMAN.

### Usage rules

- Figures appear in one color at a time (the status color, bone, or void on pulse). No outlines, gradients, shadows or two-tone fills.
- Sizes: 11-13 in stickers, 20-22 in the app-bar button and section headers, 40-64 in empty states, 96+ only on the splash.
- Use a mood skull for notifications, widgets and empty states; use the cast figure for the thing it names (heart beside check-in history, tombstone beside a due tier, ghost on a finished plan).
- The skull never wears a status it does not have. The alive face is for the alive state only.
- Pixel figures are decorative (excluded from semantics) unless they stand alone; then give `semanticLabel`.

## Layout

Phone-first single column, gutter 20, card padding 18, 4pt rhythm. On web the app stays phone-shaped inside `WebFrame`, but the Pulse ring still sizes from the space it gets.

**The Pulse tab** is: header ("Pulse" + square app-bar buttons: release plans with a count badge, then the skull button), the ring filling every remaining pixel of height (`SegmentedRing` with no `size`, inside an `Expanded`), and the Check in button under it. Nothing else: no stat tiles, no plan list, no streak. Release plans have their own screen.

## Elevation & Depth

Flat. No shadows (`elevation: 0` everywhere). Depth is the ladder pit → void → grave → raise and 1px line borders. Scrims are void at 80%.

## Shapes

Soft rectangles: chip 6, sticker 8, tile 10, button and input 14, card 16, dialog 18, sheet 22 (top corners), navigation pill stadium. Ring ticks are square-ended. Pixel figures are only squares.

## Components

All shared pieces live in `lib/ui/widgets/brand/` (import `brand.dart`).

### Segmented ring (signature)

`SegmentedRing(progress:, status:, child:, size:, ticks: 56, phase:)`. 56 square ticks; tick length 5% of the diameter, each tick 62% of its step. Lit ticks are the time left, from 12 o'clock clockwise; spent ticks go dim at the end of the sweep. Progress eases over 600ms (instant with reduced motion). While `status` is `due` the ring alternates lit and dim ticks; pass a once-a-second counter as `phase` to flip them. The ring never runs an endless animation of its own. With `size: null` it takes the largest circle that fits, and exposes the diameter through `RingScope.of(context)`.

`PulseReadout(status:, countdown:, caption:, address:, detail:)` stacks the status sticker, the mono countdown in the status color, a haze caption ("until next check-in", "until tier 1 releases", "past due, releasing to"), an optional mono bone address ("4Ywp…KMbF") and the plan name in ash. Its type scales with the ring.

### Stickers

`Sticker(label, color:, sprite:, dense:)`: Silkscreen caps on the color at 13%, radius 8, optional leading pixel figure. `StatusSticker(status, label:, dense:, showSprite:)` takes the status's color, word and figure; turn `showSprite` off for outcomes that are not a plan state (PASS, FAIL, DONE). The editor's "STEP 1/3" is a plain `Sticker`.

### Buttons

- **Primary** (`FilledButton`): pulse fill, void text, 56 high, radius 14, Outfit 17/600, leading icon 22 ("Check in" with the fingerprint). Disabled: raise fill, ash text. One per screen.
- **Secondary** (`OutlinedButton`): grave fill, 1px line, bone text, 48 high.
- **Text** (`TextButton`): pulse, Outfit 15/500.
- **Square app-bar button** (`DMSquareButton`): grave, 1px line, radius 14, 44 inside a 48 target, holds a pixel figure or icon at 20-22, optional pulse count badge. The skull button and the release-plans button.

### Cards and selection

- `DMCard`: grave, radius 16, 1px line, padding 18. Cards never nest.
- `DMListGroup` + `DMListRow`: rows split by full-width lines; `IconTile` (void square, bone icon) + Outfit title + mono detail.
- `SelectCard`: radio card for a choice with a sentence of explanation (delivery rail). Selected: deep fill, 1.5px pulse border, pulse radio dot, pulse mono footnote. Unselected: grave, line border, ash ring, haze footnote. Optional `DMTag(mono: true)` beside the title ("mainnet only").

### Inputs

Pit fill, 1px seam, radius 14, padding 16. Focus: 1.5px pulse border. Error: flatline border and helper. Hints in ash.

### Navigation

`NavigationBar`: void, height 72, deep stadium pill behind the selected icon, pulse selected icon, bone selected label (600), ash unselected.

### Mark and wordmark

`SkullMark(size:, color:)` is the mark (pulse on void; `color: DM.void_` on a pulse field for the inverse). `DeadmanWordmark(height:)` draws the pixel DEADMAN. `DeadmanLockup(height:, stacked:)` pairs them: horizontal with the wordmark 7/11 of the skull (page 1), or stacked for the splash (page 6). The v1 `DeadmanMark` is a deprecated alias that draws the skull.

### App icon

Pixel skull, pulse on void, whole pixels at every density: adaptive foreground on a 108dp canvas with 4dp cells (skull 44dp, inside the 66dp safe circle), void background layer, white monochrome layer for themed icons. Web favicon and PWA icons are rendered from the same grid; maskable icons keep the skull inside the 80% safe zone.

## Do's and Don'ts

### Do:

- **Do** let the ring fill the Pulse tab's height and keep Check in directly under it.
- **Do** pair every status color with its sticker word and skull face.
- **Do** put every amount, address, duration and countdown in mono.
- **Do** read fees from the FeeSchedule; where copy is static, Solana is 2% and private rails are 3%.
- **Do** use `DM.*`, `DMType.*` and the brand widgets; the v1 names (`DM.signal`, `DM.graphite`, `DMStatus.onTrack`, `StatusChip`, `DeadmanMark`, `PulseRing`) are aliases kept only for migration. The stat strip (`StatTiles`) left with the day streak.

### Don't:

- **Don't** show a streak, a best streak or any check-in counter. The product does not reward check-ins.
- **Don't** set sentences, buttons or numbers in Silkscreen.
- **Don't** scale, blur or antialias pixel figures, or draw them from bitmaps.
- **Don't** fill cards, buttons or banners with a status color.
- **Don't** use purple, gradients, glows, glass or shadows.
- **Don't** nest cards, or build screens out of identical icon + heading + text cards.
- **Don't** use emoji or Unicode glyphs as icons; use Material outlined icons or the pixel cast.
- **Don't** put a kicker or eyebrow label above a heading.
- **Don't** show any lock, duress or "frozen" indicator in a duress session; it must look normal.
