import 'dart:math';

import 'package:flutter/material.dart';

import '../../theme/tokens.dart';

/// The two-half mark (docs/brand/logos/deadman-mark-color.svg): an upper
/// half-ring in [top] and a lower half-ring in [bottom], offset like a
/// pulse that slipped.
class DeadmanMark extends StatelessWidget {
  const DeadmanMark({
    super.key,
    this.size = 28,
    this.top = DM.signal,
    this.bottom = DM.tide,
    this.semanticLabel,
  });

  /// Single-color mark (white, black or signal variants of the logo).
  const DeadmanMark.mono({
    super.key,
    this.size = 28,
    Color color = DM.bone,
    this.semanticLabel,
  }) : top = color,
       bottom = color;

  final double size;
  final Color top;
  final Color bottom;

  /// Null keeps the mark decorative (hidden from screen readers).
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final mark = SizedBox.square(
      dimension: size,
      child: CustomPaint(painter: _MarkPainter(top, bottom)),
    );
    final label = semanticLabel;
    if (label == null) return ExcludeSemantics(child: mark);
    return Semantics(label: label, image: true, child: mark);
  }
}

class _MarkPainter extends CustomPainter {
  _MarkPainter(this.top, this.bottom);

  final Color top;
  final Color bottom;

  // SVG geometry in a 64-unit box: rings of radius 28/14 around (32, 32),
  // the top half shifted (-3, -2.5), the bottom half (+3, +2.5).
  static const _c = Offset(32, 32);
  static final _outer = Rect.fromCircle(center: _c, radius: 28);
  static final _inner = Rect.fromCircle(center: _c, radius: 14);

  static final Path _topHalf =
      (Path()
            ..moveTo(4, 32)
            ..arcTo(_outer, pi, pi, false)
            ..lineTo(46, 32)
            ..arcTo(_inner, 0, -pi, false)
            ..close())
          .shift(const Offset(-3, -2.5));

  static final Path _bottomHalf =
      (Path()
            ..moveTo(4, 32)
            ..arcTo(_outer, pi, -pi, false)
            ..lineTo(46, 32)
            ..arcTo(_inner, 0, pi, false)
            ..close())
          .shift(const Offset(3, 2.5));

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 64, size.height / 64);
    canvas.drawPath(_topHalf, Paint()..color = top);
    canvas.drawPath(_bottomHalf, Paint()..color = bottom);
  }

  @override
  bool shouldRepaint(_MarkPainter old) =>
      old.top != top || old.bottom != bottom;
}

/// "Deadman" set in Outfit ExtraBold, as in the wordmark files.
class DeadmanWordmark extends StatelessWidget {
  const DeadmanWordmark({super.key, this.fontSize = 28, this.color = DM.bone});

  final double fontSize;
  final Color color;

  @override
  Widget build(BuildContext context) => Text(
    'Deadman',
    maxLines: 1,
    style: DMType.outfit(
      size: fontSize,
      color: color,
      weight: FontWeight.w800,
      spacing: -0.03 * fontSize,
      height: 1,
    ),
  );
}

/// Mark + wordmark, proportioned like deadman-lockup-on-dark.png.
class DeadmanLockup extends StatelessWidget {
  const DeadmanLockup({super.key, this.height = 32, this.color = DM.bone});

  /// Height of the mark; the wordmark scales from it.
  final double height;
  final Color color;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      DeadmanMark(size: height),
      SizedBox(width: height * 0.34),
      DeadmanWordmark(fontSize: height * 1.08, color: color),
    ],
  );
}
