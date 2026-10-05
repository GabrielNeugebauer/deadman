import 'package:flutter/material.dart';

import '../../theme/tokens.dart';
import 'pixel_art.dart';

/// The mark: the pixel skull, pulse on void (or [inverse]: void on pulse).
class SkullMark extends StatelessWidget {
  const SkullMark({
    super.key,
    this.size = 28,
    this.color = DM.pulse,
    this.mood = SkullMood.mark,
    this.semanticLabel,
  });

  final double size;
  final Color color;
  final SkullMood mood;

  /// Null keeps the mark decorative (hidden from screen readers).
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) => PixelSkull(
    mood: mood,
    size: size,
    color: color,
    semanticLabel: semanticLabel,
  );
}

/// The two-half cyan mark is gone; this draws the skull in its place.
@Deprecated('Use SkullMark')
class DeadmanMark extends StatelessWidget {
  const DeadmanMark({
    super.key,
    this.size = 28,
    this.top = DM.pulse,
    this.bottom = DM.pulse,
    this.semanticLabel,
  });

  const DeadmanMark.mono({
    super.key,
    this.size = 28,
    Color color = DM.bone,
    this.semanticLabel,
  }) : top = color,
       bottom = color;

  final double size;
  final Color top;

  /// Ignored: the skull is one color.
  final Color bottom;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) =>
      SkullMark(size: size, color: top, semanticLabel: semanticLabel);
}

/// The pixel DEADMAN wordmark (page 1). [height] snaps to whole pixels.
class DeadmanWordmark extends StatelessWidget {
  const DeadmanWordmark({super.key, this.height = 20, this.color = DM.bone});

  final double height;
  final Color color;

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Deadman',
    excludeSemantics: true,
    child: PixelArt(PixelSprites.wordmark, size: height, color: color),
  );
}

/// Skull + wordmark. Horizontal (page 1) by default; [stacked] is the
/// splash arrangement (page 6) with the wordmark centred under the skull.
class DeadmanLockup extends StatelessWidget {
  const DeadmanLockup({
    super.key,
    this.height = 32,
    this.color = DM.bone,
    this.markColor = DM.pulse,
    this.stacked = false,
    this.mood = SkullMood.mark,
  });

  /// Height of the skull. The wordmark is 7/11 of it, as on page 1.
  final double height;

  /// Wordmark color.
  final Color color;
  final Color markColor;
  final bool stacked;

  /// The splash (page 6) wears the alive face; the logo lockup stays
  /// neutral.
  final SkullMood mood;

  @override
  Widget build(BuildContext context) {
    final mark = SkullMark(size: height, color: markColor, mood: mood);
    final word = DeadmanWordmark(
      height: stacked ? height * 0.42 : height * 7 / 11,
      color: color,
    );
    return Semantics(
      label: 'Deadman',
      container: true,
      excludeSemantics: true,
      child: stacked
          ? Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                mark,
                SizedBox(height: height * 0.26),
                word,
              ],
            )
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                mark,
                SizedBox(width: height * 0.27),
                word,
              ],
            ),
    );
  }
}
