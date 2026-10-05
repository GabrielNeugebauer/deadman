# Deadman pixel icons

19 icons drawn on a 12×12 pixel grid, in the Deadman brand style (same pixel language as the skull and wordmark).

## Folders
- `svg/` — vector, `fill="currentColor"`, 24×24 by default. Tint them in code.
- `png/bone|pulse|ash/{24,48,72,96}px/` — ready-made PNGs. 24px = 1x, 48px = 2x, 72px = 3x.
- `preview.png` — every icon at a glance.

Always render at whole multiples of 12px (12, 24, 36, 48…) so the pixels stay sharp.

## Where each icon goes in the app
| Icon | Use |
|---|---|
| wallet | Owner wallet |
| key | Guard key, Show recovery phrase |
| warning | Panic lockdown (use Flatline #FF4D5E) |
| swap | Move guard to this phone |
| cloak | Cloak (simplified Cloak mark, used with the Cloak team's permission) |
| eye-off | Generic private / hidden |
| shield-z | Zcash |
| plus | Set up (Cloak, Zcash), New plan |
| history | Restore receiving profiles from phrase |
| calendar | Monthly plan |
| shield-plus | Private rails check |
| chevron-right | Row navigation |
| lock | Lock app |
| logout | Forget this device |
| pulse | Tab bar: Pulse (the Heart from the pixel cast) |
| users | Tab bar: Circle |
| shield | Tab bar: Security |
| heartbeat | Beat line on its own (charts, empty states) |
| fingerprint | Check in button |

## Colors
Bone #F1F0EA (default), Pulse #3EF5A8 (active / actions), Ash #8B8F98 (inactive tabs), Flatline #FF4D5E (danger), Missed #FFB547 (warning).

## Flutter
```dart
SvgPicture.asset('assets/icons/wallet.svg', width: 24, height: 24,
  colorFilter: const ColorFilter.mode(Color(0xFFF1F0EA), BlendMode.srcIn));
```
