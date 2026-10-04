# Deadman pitch deck: visual system

This file defines the deck's look. It is taken from the app's source, not from screenshots:
`lib/ui/theme.dart` (palette, type, card, button, and input shapes), `lib/ui/widgets/pulse_ring.dart` (the countdown ring),
`lib/ui/screens/pulse_tab.dart` (Pulse screen, streak card, chips, plan card), `lib/ui/screens/welcome_screen.dart` (threat rows), `lib/ui/rules_format.dart` (rail colors and badges) and `lib/ui/app.dart` (bottom navigation).

The deck uses the slide HTML subset on a fixed 1920×1080 canvas. All styles are inline, and only the properties allowed by the artifact type's `format.md` appear here. Each snippet below is a complete `<section>` (or a component to put inside one) and can be pasted as is.

---

## 1. Palette

All values were checked against `DmColors` in `lib/ui/theme.dart`. They match exactly.

| Token     | Hex       | App role (source)                                             | Deck role                                                   |
| --------- | --------- | ------------------------------------------------------------- | ----------------------------------------------------------- |
| `bg`      | `#0A0B0D` | Scaffold background                                           | Main slide background; text on the accent slide             |
| `surface` | `#14161A` | Cards, nav bar, dialogs                                       | Cards on `bg` slides; the second slide background           |
| `raised`  | `#1B1E23` | Input fill                                                    | Cards and table header row on `surface` slides; phone bezel |
| `line`    | `#262A31` | Card and button borders, ring track                           | All 1px hairlines, table rules, ring track                  |
| `text`    | `#F2F3F5` | Body and display text                                         | Headings and body on dark                                   |
| `muted`   | `#8A8F98` | Secondary text                                                | Sub-lines, captions, footer, inactive nav                   |
| `alive`   | `#3DF5A7` | `primary`; ring and button when healthy; Solana rail          | The one accent: eyebrows, key numbers, the statement slide  |
| `warn`    | `#FFB547` | Grace period; LOCKED chip; streak flame; Zcash rail; Coercion | Status only: coercion, grace, Zcash                         |
| `danger`  | `#FF4D5E` | `error`; ring once a tier is releasing                        | Status only: "tier releasing". Never a background           |
| `plus`    | `#9B7BFF` | `secondary`; Cloak rail; guardian; Loss                       | Status only: loss, guardian, Cloak                          |

Derived tones. These are the app's own alpha tints, flattened to hex so the contrast numbers below hold.

| Use                                          | Value                              | Flattened                                 |
| -------------------------------------------- | ---------------------------------- | ----------------------------------------- |
| Chip fill, alive (app: `alive` at 14% alpha) | `rgba(61,245,167,.14)`             | `#112C23` on `bg`, `#1A352E` on `surface` |
| Chip fill, warn                              | `rgba(255,181,71,.14)`             | `#2C2315` on `bg`, `#352C20` on `surface` |
| Chip fill, plus                              | `rgba(155,123,255,.14)`            | `#1E1B2F` on `bg`, `#27243A` on `surface` |
| Chip fill, danger                            | `rgba(255,77,94,.14)`              | `#2C1418` on `bg`, `#351E24` on `surface` |
| Icon tile (app: color at 12% alpha)          | `rgba(<color>,.12)`                | n/a                                       |
| Nav indicator (app: `0x333DF5A7`)            | `#1C4336`                          | on `surface`                              |
| Ring glow (app: color at 8% alpha, blurred)  | `#3DF5A7` at `stroke-opacity 0.08` | n/a                                       |
| Secondary text on the alive slide            | `#145238` (deck-only, a dark mint) | n/a                                       |

### Backgrounds per slide type

The deck uses two background tones plus one accent slide. Every `<section>` sets `background` explicitly.

| Slide type                                   | Background                                                                                                        | Cards / panels                          |
| -------------------------------------------- | ----------------------------------------------------------------------------------------------------------------- | --------------------------------------- |
| Cover and closing                            | `radial-gradient(circle at 78% 50%, #0E1E19 0%, #0A0B0D 55%)`, the ring's glow. This is the deck's only gradient. | n/a                                     |
| Content (cards, big numbers, phone, diagram) | `#0A0B0D`                                                                                                         | `#14161A`, 1px `#262A31`, radius 20px   |
| Data and dividers (table, section header)    | `#14161A`                                                                                                         | `#1B1E23`, 1px `#262A31`, radius 20px   |
| Statement (exactly one per deck)             | `#3DF5A7`                                                                                                         | none. Text `#0A0B0D`, eyebrow `#145238` |

Do not use `warn`, `danger` or `plus` as a slide background. In the app they only mean state, and the deck keeps that meaning.

### Color semantics (keep the app's mapping)

- **alive** means healthy, Silence (the release plan), the Solana rail, and the call to action.
- **warn** means Coercion and duress lock, the grace period, the Zcash rail, and the streak flame.
- **plus** means Loss, the guard key and the guardian, and the Cloak rail.
- **danger** means "a tier is releasing now". Use it at most once, for example on the ring of a "what happens when you go silent" slide.

Color never carries meaning alone. Every colored chip, icon or rail also has its word next to it ("Solana", "LOCKED", "Coercion").

### Contrast (WCAG 2.x, computed from the hex values)

| Foreground on background    | Ratio   | Allowed use                                              |
| --------------------------- | ------- | -------------------------------------------------------- |
| `#F2F3F5` on `#0A0B0D`      | 17.73:1 | Everything                                               |
| `#F2F3F5` on `#14161A`      | 16.31:1 | Everything                                               |
| `#F2F3F5` on `#1B1E23`      | 15.05:1 | Everything                                               |
| `#8A8F98` on `#0A0B0D`      | 6.06:1  | Body and captions                                        |
| `#8A8F98` on `#14161A`      | 5.57:1  | Body and captions                                        |
| `#8A8F98` on `#1B1E23`      | 5.14:1  | Body and captions                                        |
| `#3DF5A7` on `#0A0B0D`      | 13.89:1 | Everything                                               |
| `#3DF5A7` on `#14161A`      | 12.78:1 | Everything                                               |
| `#FFB547` on `#0A0B0D`      | 11.21:1 | Everything                                               |
| `#9B7BFF` on `#0A0B0D`      | 6.25:1  | Body and up                                              |
| `#9B7BFF` on `#14161A`      | 5.75:1  | Body and up                                              |
| `#FF4D5E` on `#0A0B0D`      | 6.07:1  | Body and up                                              |
| `#0A0B0D` on `#3DF5A7`      | 13.89:1 | Statement slide text; text on the alive button           |
| `#145238` on `#3DF5A7`      | 6.46:1  | Eyebrow and footer on the statement slide                |
| `#3DF5A7` on chip `#112C23` | 10.52:1 | Alive chip on `bg`                                       |
| `#FFB547` on chip `#2C2315` | 8.80:1  | Warn chip on `bg`                                        |
| `#9B7BFF` on chip `#27243A` | 4.77:1  | Plus chip on `surface`. Keep it at 24px bold or larger   |
| `#FF4D5E` on chip `#351E24` | 4.75:1  | Danger chip on `surface`. Keep it at 24px bold or larger |
| `#262A31` on `#0A0B0D`      | 1.37:1  | Hairlines only, never text                               |

---

## 2. Type

The faces are the app's: **Space Grotesk** for display (`displayLarge`, `headlineMedium`, `titleLarge`) and **Inter** for text (`GoogleFonts.interTextTheme`). The checklist warns against Inter as an overused face, but here it is a deliberate choice: the deck has to look like the app.

`<head>` link (95 characters):

```html
<link
  rel="stylesheet"
  href="https://fonts.googleapis.com/css2?family=Space+Grotesk:wght@500..700&family=Inter:wght@400..700&display=swap"
/>
```

Stacks:

- Display: `font-family:'Space Grotesk', Arial, sans-serif`
- Text: `font-family:'Inter', Arial, sans-serif` (set once on `<body>`)

### Scale (1920×1080, five steps, nothing under 24px)

| Step | Size  | Face / weight         | Line-height | Letter-spacing         | Used for                                                          |
| ---- | ----- | --------------------- | ----------- | ---------------------- | ----------------------------------------------------------------- |
| XL   | 160px | Space Grotesk 700     | 1.0         | -4px                   | Cover wordmark, big numbers                                       |
| L    | 72px  | Space Grotesk 700     | 1.1         | -1.5px                 | Slide titles (`h2`), statement sentence                           |
| M    | 44px  | Space Grotesk 600     | 1.2         | -0.5px                 | Card titles, cover sub-line, countdown inside the phone ring      |
| S    | 32px  | Inter 400 / 600       | 1.4         | 0                      | Body, table cells, button labels, stat values (Space Grotesk 600) |
| XS   | 24px  | Inter 400 / 600 / 700 | 1.35        | 0, or 3px for eyebrows | Eyebrows, chips, captions, footer, nav labels                     |

Rules:

- **Eyebrows** are XS, Inter 600, `letter-spacing:3px`, `text-transform:uppercase`, color `#3DF5A7` (or `#145238` on the statement slide).
- **Chips** are XS, Inter 700, `letter-spacing:1px`, uppercase, the status color on its 14% tint, `border-radius:99px`, `padding:6px 16px`. This is the app's `_Chip` scaled up.
- **Numbers** in the footer use `font-variant-numeric:tabular-nums`.
- **Width:** sentences go in an 880–960px column. Display lines go up to 1400px.

Deck defaults on `<body>`:

```html
<body
  style="font-family:'Inter', Arial, sans-serif; font-size:32px; line-height:1.4; color:#F2F3F5; background:#0A0B0D"
></body>
```

---

## 3. Shapes and spacing (from the app)

| Element         | App value                                                                                                    | Deck value                                                                                  |
| --------------- | ------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------- |
| Card            | `surface`, radius 20, 1px `line`, no elevation                                                               | `background:#14161A; border:1px solid #262A31; border-radius:20px; padding:40px`. No shadow |
| Filled button   | radius 16, height 54 to 64, `alive` fill, `bg` label                                                         | `border-radius:16px; padding:18px 32px; background:#3DF5A7; color:#0A0B0D`                  |
| Outlined button | radius 16, 1px `line`                                                                                        | `border:1px solid #262A31; border-radius:16px`                                              |
| Icon tile       | 12% tint, radius 12, 22dp icon                                                                               | 80×80, `border-radius:16px`, `rgba(color,.12)`, 44px `x-icon`                               |
| Chip            | 14% tint, radius 99, 12dp bold, spacing 1                                                                    | See Type rules                                                                              |
| Ring            | stroke 14 on 260 (5.4%), round cap, track `line`, sweep from 35% to 100% of the state color, 8% blurred glow | Same proportions in inline SVG (section 5.7)                                                |

- Margins are 128px. Content slides with a footer use `padding:128px 128px 160px` (a 792px vertical budget).
- Gaps are 48px between blocks, 32px between cards and 20px inside cards.
- Effects: there is one effect idea, the **mint glow**. It appears on the cover gradient, the ring glow and the phone's `box-shadow:0 0 120px rgba(61,245,167,.08)`. Use no other shadows. Do not add left-border accent cards. Do not use emoji.

---

## 4. Footer band

Content slides get a footer. The cover, the statement slide and the closing slide do not.

- The footer is one 24px row pinned at `bottom:64px` (y ≈ 984–1016), in the same place on every slide that has one.
- The **page number** goes on the right: `right:128px`, `width:160px`, `text-align:right`, tabular numbers, two digits (`03`).
- A **source line** (for slides with external numbers) goes on the left: `left:128px`, `width:1400px`. When a slide has no source, put the wordmark `Deadman` there in `#8A8F98`.
- That slide gets `padding:128px 128px 160px`, so flow content stops at y 920. Keep pinned content at `top + height ≤ 920`.
- Color is `#8A8F98` on dark slides and `#145238` on the statement slide.

```html
<p
  style="position:absolute; left:128px; bottom:64px; width:1400px; font-size:24px; line-height:1.35; color:#8A8F98"
>
  Source: README.md, Deadman repository
</p>
<p
  style="position:absolute; right:128px; bottom:64px; width:160px; text-align:right; font-size:24px; line-height:1.35; color:#8A8F98; font-variant-numeric:tabular-nums"
>
  03
</p>
```

---

## 5. Slide templates

Every template is a complete `<section>`. The copy is example text taken from the repo docs. Swap it for the deck's words, and keep the structure.

### 5.1 Cover

The ring is listed first so that it paints as the backdrop. It shows 70% progress (`stroke-dasharray` = 0.70 × 2π × 286 = 1257.9 of 1797.0).

```html
<section
  id="cover"
  data-section="Who we are and what Deadman is"
  data-transition="fade"
  style="background:radial-gradient(circle at 78% 50%, #0E1E19 0%, #0A0B0D 55%); padding:128px; display:flex; flex-direction:column; justify-content:center; gap:32px"
>
  <svg
    style="position:absolute; left:1152px; top:220px"
    width="640"
    height="640"
    viewBox="0 0 640 640"
  >
    <defs>
      <linearGradient id="coverArc" x1="1" y1="0" x2="0" y2="1">
        <stop offset="0" stop-color="#3DF5A7" stop-opacity="0.35" />
        <stop offset="1" stop-color="#3DF5A7" />
      </linearGradient>
      <filter id="coverGlow" x="-20%" y="-20%" width="140%" height="140%">
        <feGaussianBlur stdDeviation="14" />
      </filter>
    </defs>
    <circle
      cx="320"
      cy="320"
      r="286"
      fill="none"
      stroke="#262A31"
      stroke-width="34"
    />
    <circle
      cx="320"
      cy="320"
      r="286"
      fill="none"
      stroke="#3DF5A7"
      stroke-opacity="0.08"
      stroke-width="60"
      stroke-dasharray="1257.9 1797"
      transform="rotate(-90 320 320)"
      filter="url(#coverGlow)"
    />
    <circle
      cx="320"
      cy="320"
      r="286"
      fill="none"
      stroke="url(#coverArc)"
      stroke-width="34"
      stroke-linecap="round"
      stroke-dasharray="1257.9 1797"
      transform="rotate(-90 320 320)"
    />
  </svg>
  <div
    style="width:88px; height:88px; border-radius:20px; background:rgba(61,245,167,.12); display:flex; align-items:center; justify-content:center"
  >
    <x-icon
      name="Activity"
      style="color:#3DF5A7; width:52px; height:52px"
    ></x-icon>
  </div>
  <h1
    style="font-family:'Space Grotesk', Arial, sans-serif; font-size:160px; font-weight:700; line-height:1; letter-spacing:-4px; color:#F2F3F5"
  >
    Deadman
  </h1>
  <p
    style="width:900px; font-family:'Space Grotesk', Arial, sans-serif; font-size:44px; font-weight:600; line-height:1.2; letter-spacing:-0.5px; color:#8A8F98"
  >
    The self-custody safety net for Seeker.
  </p>
  <div style="display:flex; gap:16px">
    <p
      style="font-size:24px; font-weight:700; letter-spacing:1px; text-transform:uppercase; color:#3DF5A7; background:rgba(61,245,167,.14); padding:6px 16px; border-radius:99px"
    >
      Silence
    </p>
    <p
      style="font-size:24px; font-weight:700; letter-spacing:1px; text-transform:uppercase; color:#FFB547; background:rgba(255,181,71,.14); padding:6px 16px; border-radius:99px"
    >
      Coercion
    </p>
    <p
      style="font-size:24px; font-weight:700; letter-spacing:1px; text-transform:uppercase; color:#9B7BFF; background:rgba(155,123,255,.14); padding:6px 16px; border-radius:99px"
    >
      Loss
    </p>
  </div>
  <p
    style="position:absolute; left:128px; bottom:128px; width:1000px; font-size:24px; line-height:1.35; color:#8A8F98"
  >
    [Founder name] · [Hackathon name] · October 2026
  </p>
</section>
```

### 5.2 Statement (the one alive-green slide)

```html
<section
  id="statement"
  data-transition="fade"
  style="background:#3DF5A7; padding:128px; display:flex; flex-direction:column; justify-content:center; gap:32px"
>
  <p
    style="font-size:24px; font-weight:600; letter-spacing:3px; text-transform:uppercase; color:#145238"
  >
    The habit
  </p>
  <h2
    style="width:1400px; font-family:'Space Grotesk', Arial, sans-serif; font-size:72px; font-weight:700; line-height:1.1; letter-spacing:-1.5px; color:#0A0B0D"
  >
    One fingerprint keeps every plan alive. Miss it, and your crypto still ends
    up where you decided.
  </h2>
</section>
```

### 5.3 Title + three cards (the threat rows from the welcome screen)

The icon tiles use the welcome screen's colors: Silence is alive, Coercion is warn and Loss is plus. The icons are the closest `x-icon` matches to the app's Material icons: `hourglass_bottom` becomes Clock, `front_hand` becomes Lock and `phonelink_erase` becomes Key.

```html
<section
  id="threats"
  data-section="The problem: three ways self-custody fails"
  data-transition="fade"
  style="background:#0A0B0D; padding:128px 128px 160px; display:flex; flex-direction:column; justify-content:space-between"
>
  <div style="display:flex; flex-direction:column; gap:24px">
    <p
      style="font-size:24px; font-weight:600; letter-spacing:3px; text-transform:uppercase; color:#3DF5A7"
    >
      The problem
    </p>
    <h2
      style="font-family:'Space Grotesk', Arial, sans-serif; font-size:72px; font-weight:700; line-height:1.1; letter-spacing:-1.5px; color:#F2F3F5"
    >
      Self-custody fails in three ways
    </h2>
    <p style="width:960px; font-size:32px; line-height:1.4; color:#8A8F98">
      A Seed Vault protects keys from malware. It does nothing for death, a
      wrench, or a lost phone.
    </p>
  </div>
  <div style="display:flex; gap:32px">
    <div
      style="flex:1; background:#14161A; border:1px solid #262A31; border-radius:20px; padding:40px; display:flex; flex-direction:column; gap:20px"
    >
      <div
        style="width:80px; height:80px; border-radius:16px; background:rgba(61,245,167,.12); display:flex; align-items:center; justify-content:center"
      >
        <x-icon
          name="Clock"
          style="color:#3DF5A7; width:44px; height:44px"
        ></x-icon>
      </div>
      <h3
        style="font-family:'Space Grotesk', Arial, sans-serif; font-size:44px; font-weight:600; line-height:1.2; letter-spacing:-0.5px; color:#F2F3F5"
      >
        Silence
      </h3>
      <p style="font-size:32px; line-height:1.4; color:#8A8F98">
        Miss your check-ins and your vault passes to your heirs, tier by tier.
      </p>
    </div>
    <div
      style="flex:1; background:#14161A; border:1px solid #262A31; border-radius:20px; padding:40px; display:flex; flex-direction:column; gap:20px"
    >
      <div
        style="width:80px; height:80px; border-radius:16px; background:rgba(255,181,71,.12); display:flex; align-items:center; justify-content:center"
      >
        <x-icon
          name="Lock"
          style="color:#FFB547; width:44px; height:44px"
        ></x-icon>
      </div>
      <h3
        style="font-family:'Space Grotesk', Arial, sans-serif; font-size:44px; font-weight:600; line-height:1.2; letter-spacing:-0.5px; color:#F2F3F5"
      >
        Coercion
      </h3>
      <p style="font-size:32px; line-height:1.4; color:#8A8F98">
        A duress PIN silently freezes your vault while the app looks normal.
      </p>
    </div>
    <div
      style="flex:1; background:#14161A; border:1px solid #262A31; border-radius:20px; padding:40px; display:flex; flex-direction:column; gap:20px"
    >
      <div
        style="width:80px; height:80px; border-radius:16px; background:rgba(155,123,255,.12); display:flex; align-items:center; justify-content:center"
      >
        <x-icon
          name="Key"
          style="color:#9B7BFF; width:44px; height:44px"
        ></x-icon>
      </div>
      <h3
        style="font-family:'Space Grotesk', Arial, sans-serif; font-size:44px; font-weight:600; line-height:1.2; letter-spacing:-0.5px; color:#F2F3F5"
      >
        Loss
      </h3>
      <p style="font-size:32px; line-height:1.4; color:#8A8F98">
        Your device key can only check in or lock. It can never move funds.
      </p>
    </div>
  </div>
  <p
    style="position:absolute; left:128px; bottom:64px; width:1400px; font-size:24px; line-height:1.35; color:#8A8F98"
  >
    Deadman
  </p>
  <p
    style="position:absolute; right:128px; bottom:64px; width:160px; text-align:right; font-size:24px; line-height:1.35; color:#8A8F98; font-variant-numeric:tabular-nums"
  >
    02
  </p>
</section>
```

### 5.4 Big numbers

Use three tiles when each number has 4 characters or fewer at 160px (about 530px per tile). For a longer figure such as `0.0018 SOL`, use two tiles, or put the unit in the caption. Every external number needs a source in the footer.

```html
<section
  id="numbers"
  data-transition="fade"
  style="background:#0A0B0D; padding:128px 128px 160px; display:flex; flex-direction:column; justify-content:space-between"
>
  <div style="display:flex; flex-direction:column; gap:24px">
    <p
      style="font-size:24px; font-weight:600; letter-spacing:3px; text-transform:uppercase; color:#3DF5A7"
    >
      The Pulse
    </p>
    <h2
      style="font-family:'Space Grotesk', Arial, sans-serif; font-size:72px; font-weight:700; line-height:1.1; letter-spacing:-1.5px; color:#F2F3F5"
    >
      A check-in costs one touch
    </h2>
  </div>
  <div style="display:grid; grid-template-columns:repeat(3, 1fr); gap:32px">
    <div
      style="background:#14161A; border:1px solid #262A31; border-radius:20px; padding:48px 40px; display:flex; flex-direction:column; gap:8px"
    >
      <p
        style="font-family:'Space Grotesk', Arial, sans-serif; font-size:160px; font-weight:700; line-height:1; letter-spacing:-4px; color:#3DF5A7"
      >
        ~3 s
      </p>
      <p style="font-size:32px; line-height:1.4; color:#8A8F98">
        per check-in, one biometric touch
      </p>
    </div>
    <div
      style="background:#14161A; border:1px solid #262A31; border-radius:20px; padding:48px 40px; display:flex; flex-direction:column; gap:8px"
    >
      <p
        style="font-family:'Space Grotesk', Arial, sans-serif; font-size:160px; font-weight:700; line-height:1; letter-spacing:-4px; color:#F2F3F5"
      >
        0
      </p>
      <p style="font-size:32px; line-height:1.4; color:#8A8F98">
        wallet prompts to check in
      </p>
    </div>
    <div
      style="background:#14161A; border:1px solid #262A31; border-radius:20px; padding:48px 40px; display:flex; flex-direction:column; gap:8px"
    >
      <p
        style="font-family:'Space Grotesk', Arial, sans-serif; font-size:160px; font-weight:700; line-height:1; letter-spacing:-4px; color:#F2F3F5"
      >
        8
      </p>
      <p style="font-size:32px; line-height:1.4; color:#8A8F98">
        ordered tiers per release plan, at most
      </p>
    </div>
  </div>
  <p
    style="position:absolute; left:128px; bottom:64px; width:1400px; font-size:24px; line-height:1.35; color:#8A8F98"
  >
    Source: README.md, Deadman repository
  </p>
  <p
    style="position:absolute; right:128px; bottom:64px; width:160px; text-align:right; font-size:24px; line-height:1.35; color:#8A8F98; font-variant-numeric:tabular-nums"
  >
    05
  </p>
</section>
```

Only the key number is colored alive. The others stay `#F2F3F5`, so the eye lands once.

### 5.5 Table (a `surface` slide)

The rail color goes on the rail-name cell, and the name says it in words too. The header row uses `raised`, and the rules come from the table's `#262A31` border.

```html
<section
  id="rails"
  data-transition="fade"
  style="background:#14161A; padding:128px 128px 160px; display:flex; flex-direction:column; gap:48px"
>
  <div style="display:flex; flex-direction:column; gap:24px">
    <p
      style="font-size:24px; font-weight:600; letter-spacing:3px; text-transform:uppercase; color:#3DF5A7"
    >
      Delivery
    </p>
    <h2
      style="font-family:'Space Grotesk', Arial, sans-serif; font-size:72px; font-weight:700; line-height:1.1; letter-spacing:-1.5px; color:#F2F3F5"
    >
      Each tier picks how it pays out
    </h2>
  </div>
  <table
    style="width:1664px; font-size:32px; color:#F2F3F5; border:1px solid #262A31"
  >
    <tr style="background:#1B1E23">
      <th style="width:22%; text-align:left; font-weight:600; color:#8A8F98">
        Rail
      </th>
      <th style="width:48%; text-align:left; font-weight:600; color:#8A8F98">
        How it arrives
      </th>
      <th style="width:30%; text-align:left; font-weight:600; color:#8A8F98">
        Network
      </th>
    </tr>
    <tr>
      <td style="color:#3DF5A7">Solana</td>
      <td>Direct transfer to a Solana wallet</td>
      <td>Devnet and mainnet</td>
    </tr>
    <tr>
      <td style="color:#9B7BFF">Cloak</td>
      <td>Shielded pool on Solana</td>
      <td>Mainnet only</td>
    </tr>
    <tr>
      <td style="color:#FFB547">Zcash</td>
      <td>Delivered as shielded ZEC</td>
      <td>Mainnet only</td>
    </tr>
  </table>
  <p
    style="position:absolute; left:128px; bottom:64px; width:1400px; font-size:24px; line-height:1.35; color:#8A8F98"
  >
    Source: README.md and lib/ui/rules_format.dart, Deadman repository
  </p>
  <p
    style="position:absolute; right:128px; bottom:64px; width:160px; text-align:right; font-size:24px; line-height:1.35; color:#8A8F98; font-variant-numeric:tabular-nums"
  >
    07
  </p>
</section>
```

### 5.6 Diagram (boxes + `x-connector`)

The host is 1664×640 under a 72px title, so 80 + 48 + 640 = 768 fits the 792px footer budget. It has 4 boxes, 3 connectors and 3 labels, which makes 10 pinned children (the limit is 24). The program box is the focal node, so it gets a 2px alive border. All the other boxes keep the 1px `line` border.

```html
<section
  id="system"
  data-section="How it works under the hood"
  data-transition="fade"
  style="background:#0A0B0D; padding:128px 128px 160px; display:flex; flex-direction:column; gap:48px"
>
  <h2
    style="font-family:'Space Grotesk', Arial, sans-serif; font-size:72px; font-weight:700; line-height:1.1; letter-spacing:-1.5px; color:#F2F3F5"
  >
    One program, one vault, three keys
  </h2>
  <!-- phone 0,40,400,160  program 632,40,400,160  tiers 1264,40,400,160  kora 632,440,400,160 -->
  <div style="position:relative; width:1664px; height:640px">
    <div
      style="position:absolute; left:0; top:40px; width:400px; height:160px; background:#14161A; border:1px solid #262A31; border-radius:20px; padding:28px 32px; display:flex; flex-direction:column; justify-content:center; gap:4px"
    >
      <p
        style="font-family:'Space Grotesk', Arial, sans-serif; font-size:32px; font-weight:600; line-height:1.2; color:#F2F3F5"
      >
        1. Seeker phone
      </p>
      <p style="font-size:24px; line-height:1.35; color:#8A8F98">
        Guard key signs the Pulse
      </p>
    </div>
    <div
      style="position:absolute; left:632px; top:40px; width:400px; height:160px; background:#14161A; border:2px solid #3DF5A7; border-radius:20px; padding:28px 32px; display:flex; flex-direction:column; justify-content:center; gap:4px"
    >
      <p
        style="font-family:'Space Grotesk', Arial, sans-serif; font-size:32px; font-weight:600; line-height:1.2; color:#F2F3F5"
      >
        2. Deadman program
      </p>
      <p style="font-size:24px; line-height:1.35; color:#8A8F98">
        Vault PDA on Solana
      </p>
    </div>
    <div
      style="position:absolute; left:1264px; top:40px; width:400px; height:160px; background:#14161A; border:1px solid #262A31; border-radius:20px; padding:28px 32px; display:flex; flex-direction:column; justify-content:center; gap:4px"
    >
      <p
        style="font-family:'Space Grotesk', Arial, sans-serif; font-size:32px; font-weight:600; line-height:1.2; color:#F2F3F5"
      >
        3. Release tiers
      </p>
      <p style="font-size:24px; line-height:1.35; color:#8A8F98">
        Up to 8, fired in order
      </p>
    </div>
    <div
      style="position:absolute; left:632px; top:440px; width:400px; height:160px; background:#14161A; border:1px solid #262A31; border-radius:20px; padding:28px 32px; display:flex; flex-direction:column; justify-content:center; gap:4px"
    >
      <p
        style="font-family:'Space Grotesk', Arial, sans-serif; font-size:32px; font-weight:600; line-height:1.2; color:#F2F3F5"
      >
        Kora fee sponsor
      </p>
      <p style="font-size:24px; line-height:1.35; color:#8A8F98">
        Guard key never needs SOL
      </p>
    </div>
    <x-connector
      x1="400"
      y1="120"
      x2="632"
      y2="120"
      style="color:#3DF5A7; border-width:3px"
    ></x-connector>
    <x-connector
      x1="1032"
      y1="120"
      x2="1264"
      y2="120"
      style="color:#8A8F98; border-width:3px"
    ></x-connector>
    <x-connector
      x1="832"
      y1="440"
      x2="832"
      y2="200"
      style="color:#8A8F98; border-width:3px; border-style:dashed"
    ></x-connector>
    <p
      style="position:absolute; left:416px; top:72px; width:200px; text-align:center; font-size:24px; line-height:1.35; color:#3DF5A7"
    >
      pulse, lockdown
    </p>
    <p
      style="position:absolute; left:1048px; top:72px; width:200px; text-align:center; font-size:24px; line-height:1.35; color:#8A8F98"
    >
      after silence
    </p>
    <p
      style="position:absolute; left:856px; top:300px; width:320px; font-size:24px; line-height:1.35; color:#8A8F98"
    >
      co-signs, pays the fee
    </p>
  </div>
  <p
    style="position:absolute; left:128px; bottom:64px; width:1400px; font-size:24px; line-height:1.35; color:#8A8F98"
  >
    Source: docs/ARCHITECTURE.md and docs/KORA.md, Deadman repository
  </p>
  <p
    style="position:absolute; right:128px; bottom:64px; width:160px; text-align:right; font-size:24px; line-height:1.35; color:#8A8F98; font-variant-numeric:tabular-nums"
  >
    08
  </p>
</section>
```

Geometry check: every connector endpoint is a box edge midpoint. The horizontal legs run at y 120, inside the 232px column gaps. The vertical leg runs at x 832 (the column center) between the rows. Each label sits at least 8px clear of its line: label bottoms at about y 104 against the line at y 120, and the side label starts at x 856 against the line at x 832.

For a straight chain with no branch, skip the host. Use a flow row of the same boxes with `<x-connector style="width:96px"></x-connector>` between them and `align-items:center` on the row.

### 5.7 Phone mockup: the Pulse screen

This recreates `PulseTab` at slide scale. The structure, colors and proportions come from the source. Text sizes are raised to the 24px floor, which needs two simplifications: the streak labels read `streak / best / plans` (the app says `day streak`), and the multi-plan sub-label under the countdown is left out. The ring follows `_RingPainter`: track `#262A31`, stroke 15 on 280 (the app's 14 on 260), round cap, start at 12 o'clock, clockwise, a 35%→100% alive gradient and a blurred 8% glow. Progress is 0.70 (`stroke-dasharray` 549.8 of 785.4), which matches `4d 21h` left on a 7-day cadence.

The phone is 440×792, so it fits the footer slide's 792px budget exactly. All values in it (`4d 21h`, `12`, `31`, `2`) are illustrative demo state, not metrics.

**Component (paste as a flow child; `flex:none` keeps it from shrinking):**

```html
<div
  style="flex:none; width:440px; height:792px; background:#1B1E23; border:1px solid #262A31; border-radius:64px; padding:14px; box-shadow:0 0 120px rgba(61,245,167,.08)"
>
  <div
    style="position:relative; width:410px; height:762px; background:#0A0B0D; border-radius:50px; overflow:hidden; padding:48px 24px 0; display:flex; flex-direction:column; gap:20px"
  >
    <p
      style="font-family:'Space Grotesk', Arial, sans-serif; font-size:44px; font-weight:700; line-height:1.1; letter-spacing:-0.5px; color:#F2F3F5"
    >
      Pulse
    </p>
    <div
      style="position:relative; width:280px; height:280px; align-self:center"
    >
      <svg
        style="position:absolute; left:0; top:0"
        width="280"
        height="280"
        viewBox="0 0 280 280"
      >
        <defs>
          <linearGradient id="pulseArc" x1="1" y1="0" x2="0" y2="1">
            <stop offset="0" stop-color="#3DF5A7" stop-opacity="0.35" />
            <stop offset="1" stop-color="#3DF5A7" />
          </linearGradient>
          <filter id="pulseGlow" x="-20%" y="-20%" width="140%" height="140%">
            <feGaussianBlur stdDeviation="6" />
          </filter>
        </defs>
        <circle
          cx="140"
          cy="140"
          r="125"
          fill="none"
          stroke="#262A31"
          stroke-width="15"
        />
        <circle
          cx="140"
          cy="140"
          r="125"
          fill="none"
          stroke="#3DF5A7"
          stroke-opacity="0.08"
          stroke-width="28"
          stroke-dasharray="549.8 785.4"
          transform="rotate(-90 140 140)"
          filter="url(#pulseGlow)"
        />
        <circle
          cx="140"
          cy="140"
          r="125"
          fill="none"
          stroke="url(#pulseArc)"
          stroke-width="15"
          stroke-linecap="round"
          stroke-dasharray="549.8 785.4"
          transform="rotate(-90 140 140)"
        />
      </svg>
      <p
        style="position:absolute; left:0; top:82px; width:280px; text-align:center; white-space:nowrap; font-family:'Space Grotesk', Arial, sans-serif; font-size:44px; font-weight:700; line-height:1.15; color:#3DF5A7"
      >
        4d 21h
      </p>
      <p
        style="position:absolute; left:40px; top:140px; width:200px; text-align:center; font-size:24px; line-height:1.3; color:#8A8F98"
      >
        until next check-in
      </p>
    </div>
    <div
      style="display:flex; align-items:center; justify-content:center; gap:12px; background:#3DF5A7; border-radius:16px; padding:18px 24px"
    >
      <x-icon
        name="Activity"
        style="color:#0A0B0D; width:40px; height:40px"
      ></x-icon>
      <p
        style="font-size:32px; font-weight:600; line-height:1.2; color:#0A0B0D"
      >
        I'm alive
      </p>
    </div>
    <div
      style="display:flex; align-items:center; gap:8px; background:#14161A; border:1px solid #262A31; border-radius:20px; padding:18px 16px"
    >
      <svg width="36" height="36" viewBox="0 0 24 24">
        <path
          fill="#FFB547"
          d="M19.48 12.35c-1.57-4.08-7.16-4.3-5.81-10.23.1-.44-.37-.78-.75-.55C9.29 3.71 6.68 8 8.87 13.62c.18.46-.36.89-.75.59-1.81-1.37-2-3.34-1.84-4.75.06-.52-.62-.77-.91-.34C4.69 10.16 4 11.84 4 14.37c.38 5.6 5.11 7.32 6.81 7.54 2.43.31 5.06-.14 6.95-1.87 2.08-1.93 2.84-5.01 1.72-7.69zM10.2 17.38c1.44-.35 2.18-1.39 2.38-2.31.33-1.43-.96-2.83-.09-5.09.33 1.87 3.27 3.04 3.27 5.08.08 2.53-2.66 4.7-5.56 2.32z"
        />
      </svg>
      <div
        style="flex:1; display:flex; flex-direction:column; align-items:center"
      >
        <p
          style="font-family:'Space Grotesk', Arial, sans-serif; font-size:32px; font-weight:600; line-height:1.2; color:#F2F3F5"
        >
          12
        </p>
        <p style="font-size:24px; line-height:1.3; color:#8A8F98">streak</p>
      </div>
      <div
        style="flex:1; display:flex; flex-direction:column; align-items:center"
      >
        <p
          style="font-family:'Space Grotesk', Arial, sans-serif; font-size:32px; font-weight:600; line-height:1.2; color:#F2F3F5"
        >
          31
        </p>
        <p style="font-size:24px; line-height:1.3; color:#8A8F98">best</p>
      </div>
      <div
        style="flex:1; display:flex; flex-direction:column; align-items:center"
      >
        <p
          style="font-family:'Space Grotesk', Arial, sans-serif; font-size:32px; font-weight:600; line-height:1.2; color:#F2F3F5"
        >
          2
        </p>
        <p style="font-size:24px; line-height:1.3; color:#8A8F98">plans</p>
      </div>
    </div>
    <div
      style="position:absolute; left:197px; top:16px; width:16px; height:16px; border-radius:50%; background:#1B1E23"
    ></div>
    <div
      style="position:absolute; left:0; right:0; bottom:0; height:92px; background:#14161A; border-top:1px solid #262A31; display:flex; justify-content:space-around; align-items:center"
    >
      <div
        style="display:flex; flex-direction:column; align-items:center; gap:2px"
      >
        <div style="background:#1C4336; border-radius:99px; padding:2px 18px">
          <x-icon
            name="Activity"
            style="color:#3DF5A7; width:32px; height:32px"
          ></x-icon>
        </div>
        <p style="font-size:24px; line-height:1.2; color:#F2F3F5">Pulse</p>
      </div>
      <div
        style="display:flex; flex-direction:column; align-items:center; gap:2px"
      >
        <div style="padding:2px 18px">
          <x-icon
            name="Users"
            style="color:#8A8F98; width:32px; height:32px"
          ></x-icon>
        </div>
        <p style="font-size:24px; line-height:1.2; color:#8A8F98">Circle</p>
      </div>
      <div
        style="display:flex; flex-direction:column; align-items:center; gap:2px"
      >
        <div style="padding:2px 18px">
          <x-icon
            name="Lock"
            style="color:#8A8F98; width:32px; height:32px"
          ></x-icon>
        </div>
        <p style="font-size:24px; line-height:1.2; color:#8A8F98">Security</p>
      </div>
    </div>
  </div>
</div>
```

Vertical budget inside the screen: 48 (top pad) + 48 (title) + 280 (ring) + 74 (button) + 105 (streak card) + 3 × 20 (gaps) = 615. The nav starts at 670, which leaves 55px clear. Pinned children of the screen are the camera dot and the nav (2). The ring host has 3.

**State variants.** Swap the ring and button color with the app's state logic (`pulse_tab.dart`): **grace** uses `#FFB547` with the label `until next tier`. **Releasing** uses `#FF4D5E` with the label `tier due, releasing`, and the arc goes to 0 (remove both arc circles). **Locked** adds a `LOCKED` warn chip to the right of the title (put the title in a row `div` with `align-items:center`). The `linearGradient` stop color and the glow stroke change with it. Give each SVG unique ids (`pulseArcGrace`, ...) when two phones share a deck.

**Slide using it:**

```html
<section
  id="pulse"
  data-section="The product: one vault, a release plan and a three-second habit"
  data-transition="fade"
  style="background:#0A0B0D; padding:128px 128px 160px; display:flex; gap:128px"
>
  <div
    style="flex:1; display:flex; flex-direction:column; justify-content:space-between"
  >
    <div style="display:flex; flex-direction:column; gap:24px">
      <p
        style="font-size:24px; font-weight:600; letter-spacing:3px; text-transform:uppercase; color:#3DF5A7"
      >
        Product
      </p>
      <h2
        style="font-family:'Space Grotesk', Arial, sans-serif; font-size:72px; font-weight:700; line-height:1.1; letter-spacing:-1.5px; color:#F2F3F5"
      >
        The Pulse is a three-second habit
      </h2>
      <p style="width:880px; font-size:32px; line-height:1.4; color:#8A8F98">
        One fingerprint resets every pending tier and adds to an on-chain
        streak. No wallet prompt.
      </p>
    </div>
    <div style="display:flex; flex-direction:column; gap:20px">
      <div style="display:flex; align-items:center; gap:20px">
        <x-icon
          name="Check"
          style="color:#3DF5A7; width:40px; height:40px"
        ></x-icon>
        <p style="font-size:32px; line-height:1.4; color:#F2F3F5">
          One check-in covers every plan
        </p>
      </div>
      <div style="display:flex; align-items:center; gap:20px">
        <x-icon
          name="Check"
          style="color:#3DF5A7; width:40px; height:40px"
        ></x-icon>
        <p style="font-size:32px; line-height:1.4; color:#F2F3F5">
          Guard key can only check in or lock
        </p>
      </div>
      <div style="display:flex; align-items:center; gap:20px">
        <x-icon
          name="Check"
          style="color:#3DF5A7; width:40px; height:40px"
        ></x-icon>
        <p style="font-size:32px; line-height:1.4; color:#F2F3F5">
          The streak gives a reason to open it
        </p>
      </div>
    </div>
  </div>
  <!-- phone component from above goes here -->
  <p
    style="position:absolute; left:128px; bottom:64px; width:1400px; font-size:24px; line-height:1.35; color:#8A8F98"
  >
    Deadman
  </p>
  <p
    style="position:absolute; right:128px; bottom:64px; width:160px; text-align:right; font-size:24px; line-height:1.35; color:#8A8F98; font-variant-numeric:tabular-nums"
  >
    04
  </p>
</section>
```

### 5.8 Release-plan card (tier list), at slide scale

This recreates `_PlanCard` and `RailBadge`. At phone scale, a tier row does not fit the 24px floor (icon + "1 SOL → 7xKq…3fPa" + badge needs about 400px), so the tier list is shown as its own card next to or instead of the phone. The width is 1000px. Icons map as follows: `schedule` becomes Clock in the rail color, `check_circle` becomes CheckCircle in `muted`, `shield_outlined` becomes Trust in `plus`. Rail badge icons: `bolt` becomes Lightning, `visibility_off` becomes Lock, `shield_moon` becomes Trust. The addresses and amounts are illustrative.

```html
<div
  style="width:1000px; background:#14161A; border:1px solid #262A31; border-radius:20px; padding:40px; display:flex; flex-direction:column; gap:24px"
>
  <div style="display:flex; align-items:center; gap:16px">
    <p
      style="flex:1; font-family:'Space Grotesk', Arial, sans-serif; font-size:44px; font-weight:600; line-height:1.2; letter-spacing:-0.5px; color:#F2F3F5"
    >
      Family
    </p>
    <p
      style="font-size:24px; font-weight:700; letter-spacing:1px; color:#FFB547; background:rgba(255,181,71,.14); padding:6px 16px; border-radius:99px"
    >
      1/3 RELEASED
    </p>
  </div>
  <p style="font-size:32px; line-height:1.4; color:#8A8F98">
    2.5 SOL and 400 USDC protected · check in every 7d 0h
  </p>
  <div style="display:flex; align-items:center; gap:20px">
    <x-icon
      name="CheckCircle"
      style="color:#8A8F98; width:40px; height:40px"
    ></x-icon>
    <div style="flex:1; display:flex; flex-direction:column">
      <p style="font-size:32px; line-height:1.4; color:#F2F3F5">
        1 SOL → 7xKq…3fPa
      </p>
      <p style="font-size:24px; line-height:1.35; color:#8A8F98">
        Released 2d 4h ago
      </p>
    </div>
    <div
      style="display:flex; align-items:center; gap:8px; background:rgba(61,245,167,.14); border-radius:99px; padding:6px 16px"
    >
      <x-icon
        name="Lightning"
        style="color:#3DF5A7; width:32px; height:32px"
      ></x-icon>
      <p style="font-size:24px; font-weight:600; color:#3DF5A7">Solana</p>
    </div>
  </div>
  <div style="display:flex; align-items:center; gap:20px">
    <x-icon
      name="Clock"
      style="color:#9B7BFF; width:40px; height:40px"
    ></x-icon>
    <div style="flex:1; display:flex; flex-direction:column">
      <p style="font-size:32px; line-height:1.4; color:#F2F3F5">
        50% of remaining USDC → 4fRt…Kq2e
      </p>
      <p style="font-size:24px; line-height:1.35; color:#8A8F98">
        After 30d 0h silent · in 25d 3h
      </p>
    </div>
    <div
      style="display:flex; align-items:center; gap:8px; background:rgba(155,123,255,.14); border-radius:99px; padding:6px 16px"
    >
      <x-icon
        name="Lock"
        style="color:#9B7BFF; width:32px; height:32px"
      ></x-icon>
      <p style="font-size:24px; font-weight:600; color:#9B7BFF">Cloak</p>
    </div>
  </div>
  <div style="display:flex; align-items:center; gap:20px">
    <x-icon
      name="Clock"
      style="color:#FFB547; width:40px; height:40px"
    ></x-icon>
    <div style="flex:1; display:flex; flex-direction:column">
      <p style="font-size:32px; line-height:1.4; color:#F2F3F5">
        100% of remaining SOL → 9pQe…a1Lk
      </p>
      <p style="font-size:24px; line-height:1.35; color:#8A8F98">
        After 60d 0h silent · in 55d 3h
      </p>
    </div>
    <div
      style="display:flex; align-items:center; gap:8px; background:rgba(255,181,71,.14); border-radius:99px; padding:6px 16px"
    >
      <x-icon
        name="Trust"
        style="color:#FFB547; width:32px; height:32px"
      ></x-icon>
      <p style="font-size:24px; font-weight:600; color:#FFB547">Zcash</p>
    </div>
  </div>
  <div
    style="display:flex; align-items:center; gap:20px; border-top:1px solid #262A31; padding:20px 0 0"
  >
    <x-icon
      name="Trust"
      style="color:#9B7BFF; width:40px; height:40px"
    ></x-icon>
    <p style="font-size:32px; line-height:1.4; color:#F2F3F5">
      Guardian 2mWd…Hs8c
    </p>
  </div>
</div>
```

Height: 40 + 53 + 45 + 3 × 76 + 65 + 5 × 24 + 40 ≈ 590. It fits under a 72px title on a footer slide (80 + 48 + 590 = 718 of 792).

**Vesting variant (same card, new plan kind).** Replace the tier rows with one row per beneficiary and a progress track. The track uses `alive` for vested and `line` for unvested, with the numbers in words beside it:

```html
<div style="display:flex; flex-direction:column; gap:12px">
  <div style="display:flex; align-items:center; gap:16px">
    <p style="flex:1; font-size:32px; line-height:1.4; color:#F2F3F5">
      [Amount] USDC → [address]
    </p>
    <p
      style="font-size:24px; font-weight:700; letter-spacing:1px; color:#9B7BFF; background:rgba(155,123,255,.14); padding:6px 16px; border-radius:99px"
    >
      REVOCABLE
    </p>
  </div>
  <div
    style="height:16px; border-radius:99px; background:#262A31; overflow:hidden; display:flex"
  >
    <div style="flex:25; background:#3DF5A7"></div>
    <div style="flex:75"></div>
  </div>
  <p style="font-size:24px; line-height:1.35; color:#8A8F98">
    [25]% vested · cliff [6 months] · fully vested [date]
  </p>
</div>
```

Use `IRREVOCABLE` in the alive chip style for the irrevocable case.

### 5.9 Section header / closing

Section headers use the `surface` background, an eyebrow with the section number and one 72px line, placed low on the slide (`justify-content:flex-end`). The closing slide reuses the cover (gradient and ring). Replace the sub-line with the ask and contact placeholders: `[Contact]`, `[Repo or dApp Store link]`.

```html
<section
  id="section-2"
  data-section="How it works"
  data-transition="push"
  style="background:#14161A; padding:128px; display:flex; flex-direction:column; justify-content:flex-end; gap:24px"
>
  <p
    style="font-size:24px; font-weight:600; letter-spacing:3px; text-transform:uppercase; color:#3DF5A7"
  >
    02 · How it works
  </p>
  <h2
    style="width:1400px; font-family:'Space Grotesk', Arial, sans-serif; font-size:72px; font-weight:700; line-height:1.1; letter-spacing:-1.5px; color:#F2F3F5"
  >
    One vault on Solana covers all three threats
  </h2>
</section>
```

---

## 6. Rhythm for a ten-to-twelve slide deck

| #   | Type                | Background           |
| --- | ------------------- | -------------------- |
| 1   | Cover               | Gradient (only one)  |
| 2   | Title + 3 cards     | `#0A0B0D`            |
| 3   | Big numbers or text | `#0A0B0D`            |
| 4   | Phone mockup        | `#0A0B0D`            |
| 5   | Plan card           | `#0A0B0D`            |
| 6   | Statement           | `#3DF5A7` (only one) |
| 7   | Diagram             | `#0A0B0D`            |
| 8   | Table               | `#14161A`            |
| …   | Section header      | `#14161A`            |
| n   | Closing             | Cover gradient       |

Headings on content slides all start at y 128, because the column is top-aligned and the body is spread with `space-between`. Do not vertically center content slides.

---

## 7. Placeholders this system introduces

These must be filled by the founder or cut. Never replace them with invented values.

- `[Founder name]`, `[Hackathon name]` (cover)
- `[Contact]`, `[Repo or dApp Store link]` (closing)
- Vesting example: `[Amount]`, `[address]`, `[25]% vested`, `[6 months]`, `[date]`

These mock UI values are illustrative app state, not metrics, and should be labeled "Illustrative" in the speaker notes if asked: `4d 21h`, streak `12` / best `31` / `2` plans, the "Family" plan amounts, and the shortened addresses.

## 8. Checklist before publishing

- Every `<section>` sets `background`, and only one slide uses alive green.
- No text below 24px. No `<text>` inside an SVG. Labels are `<p>` over it.
- The `warn`, `danger` and `plus` colors appear only as status, and always next to a word.
- Every external number has a `Source:` line in the footer band at `bottom:64px`.
- Content slides use `padding:128px 128px 160px`, and pinned content ends at y ≤ 920.
- SVG ids are unique across the deck (`coverArc`, `pulseArc`, ...).
- The flame path in the streak card is Material `local_fire_department` (Apache 2.0). Check it on the first render, and replace it with `<x-icon name="Lightning">` in `#FFB547` if it draws wrong.
