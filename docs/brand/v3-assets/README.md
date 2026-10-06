# Deadman brand assets

Everything here is exported from the current Deadman brand canvas. Nothing was redrawn.

## Folders

| Folder | What's inside |
|---|---|
| `01-logo` | Pixel skull (pulse, bone, void), pixel wordmark (bone for dark grounds, void for light), and the lockup (skull + wordmark) for dark and light grounds. SVG + PNG. |
| `02-app-icon` | App icon: primary (pulse on void), inverse (void on pulse), round mask, plus the skull expression variants (wink, side-eye, X, rest). PNG at 512, 192, 144, 96, 72, 48, 32. `adaptive-foreground` is the skull alone on a 432 px transparent canvas for Android adaptive icons. |
| `03-characters` | Skull expressions in status colours (alive, missed, tier due, released) and the pixel cast (heart, skull, tombstone, ghost). SVG + PNG at 4×, 8×, 16×. |
| `04-boney-mascot` | Boney in every state: front, checked in, on track, check-in soon, missed, tier due, last tier, no plan, and the released ghost. SVG + transparent PNG at 4×, 8×, 16×. |
| `05-icons` | The 19 pixel UI icons. SVGs use `currentColor`; PNGs in bone, pulse and ash at 24, 48, 72, 96 px. |
| `06-colors-and-type` | `tokens.json` (colours, type styles, spacing, radii) and the font files with their licences. |
| `07-widgets` | Rendered widgets at 3×, transparent corners. `small/` has all 8 states; `sizes/` has small, medium and large for on track, missed, tier due and released. |
| `08-stickers` | Every sticker from both sheets as a transparent PNG at 3×, with its die-cut border. |
| `09-reference-boards` | Full renders of every artboard on the canvas, for reference. |

## Pixel art rules
- Scale only by whole numbers (2×, 3×, 4×…) and keep `shape-rendering: crispEdges` / nearest-neighbour scaling, so edges stay sharp.
- One colour per drawing, no outlines, no gradients.
- Boney's colour always matches the plan's status: pulse (alive), missed (warning), flatline (tier due), ash (released / no plan).

## Colours
| Name | Hex | Use |
|---|---|---|
| Void | #0A0B0D | Ground |
| Grave | #16181C | Cards |
| Bone | #F1F0EA | Text |
| Pulse | #3EF5A8 | Alive, primary action |
| Missed | #FFB547 | Warning |
| Flatline | #FF4D5E | Tier due |
| Ash | #8B8F98 | Secondary, released |

## Fonts
- **Outfit**: app UI. **JetBrains Mono**: timers, addresses, amounts. **Silkscreen**: status pills and short taglines only. All three are included (SIL Open Font License).
- **Schibsted Grotesk** (marketing and decks) is not included; get it from Google Fonts: https://fonts.google.com/specimen/Schibsted+Grotesk

## Note on the PNG renders
The widget, sticker and reference-board PNGs were rendered without Schibsted Grotesk installed, so the few places that use it (the "Check in" button sticker and the headings on some reference boards) use a similar fallback font. Everything set in Outfit, JetBrains Mono and Silkscreen, and all pixel art, is exact.
