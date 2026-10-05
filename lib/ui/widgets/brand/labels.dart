import 'package:flutter/material.dart';

import '../../theme/tokens.dart';
import 'pixel_art.dart';

/// Mono caption, uppercase and letter-spaced: "PLAN", "TIER 2".
class MonoLabel extends StatelessWidget {
  const MonoLabel(
    this.text, {
    super.key,
    this.color = DM.ash,
    this.size = 10.5,
    this.upper = true,
    this.spacing = 1.5,
    this.weight = FontWeight.w400,
    this.maxLines,
    this.textAlign,
  });

  final String text;
  final Color color;
  final double size;
  final bool upper;
  final double spacing;
  final FontWeight weight;
  final int? maxLines;
  final TextAlign? textAlign;

  @override
  Widget build(BuildContext context) => Text(
    upper ? text.toUpperCase() : text,
    maxLines: maxLines,
    overflow: maxLines == null ? null : TextOverflow.ellipsis,
    textAlign: textAlign,
    style: DMType.mono(
      size: size,
      color: color,
      spacing: spacing,
      weight: weight,
    ),
  );
}

/// The brand's sticker: a Silkscreen word in caps, optionally led by a
/// pixel figure, on a 13% tint of its color ("ALIVE", "TIER DUE",
/// "STEP 1/3"). Keep the word to one or two short words.
class Sticker extends StatelessWidget {
  const Sticker(
    this.label, {
    super.key,
    this.color = DM.pulse,
    this.sprite,
    this.dense = false,
    this.fill,
    this.textColor,
  });

  final String label;
  final Color color;

  /// Leading pixel figure, drawn in [color].
  final PixelSprite? sprite;

  /// Smaller sticker for list rows and plan cards.
  final bool dense;

  /// Overrides the 13% tint.
  final Color? fill;

  /// Overrides [color] for the word only.
  final Color? textColor;

  @override
  Widget build(BuildContext context) {
    final sprite = this.sprite;
    final text = label.toUpperCase();
    return Semantics(
      label: label,
      excludeSemantics: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: fill ?? color.withValues(alpha: 0.13),
          borderRadius: BorderRadius.circular(
            dense ? DMRadius.chip : DMRadius.sticker,
          ),
        ),
        child: Padding(
          padding: dense
              ? const EdgeInsets.symmetric(horizontal: 8, vertical: 5)
              : const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (sprite != null) ...[
                PixelArt(sprite, size: dense ? 11 : 13, color: color),
                SizedBox(width: dense ? 6 : 9),
              ],
              Flexible(
                child: Text(
                  text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: DMType.sticker(
                    textColor ?? color,
                    size: dense ? 9.5 : 10.5,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A [Sticker] for a [DMStatus]: its color, its figure and (unless
/// [label] says otherwise) its word. Set [showSprite] false for plain
/// outcomes that are not a plan's state ("PASS", "FAIL", "DONE").
class StatusSticker extends StatelessWidget {
  const StatusSticker(
    this.status, {
    super.key,
    this.label,
    this.dense = false,
    this.showSprite = true,
  });

  final DMStatus status;
  final String? label;
  final bool dense;
  final bool showSprite;

  @override
  Widget build(BuildContext context) => Sticker(
    label ?? status.label,
    color: status.color,
    fill: status.tint,
    sprite: showSprite ? status.sprite : null,
    dense: dense,
  );
}

@Deprecated('Use StatusSticker')
typedef StatusChip = StatusSticker;

/// Outlined tag: "Solana" in Outfit, or a data word like "mainnet only"
/// in mono when [mono] is set.
class DMTag extends StatelessWidget {
  const DMTag({super.key, required this.label, this.icon, this.mono = false});

  final String label;
  final IconData? icon;
  final bool mono;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      border: Border.all(color: DM.seam),
      borderRadius: BorderRadius.circular(DMRadius.chip),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 14, color: DM.bone),
            const SizedBox(width: 6),
          ],
          Text(
            label,
            style: mono
                ? DMType.mono(size: 12, color: DM.haze)
                : DMType.outfit(size: 13, weight: FontWeight.w500),
          ),
        ],
      ),
    ),
  );
}
