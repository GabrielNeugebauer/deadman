import 'dart:math';

import 'package:flutter/material.dart';

import '../theme.dart';

/// Countdown ring: full when just pulsed, empties toward the pulse due time,
/// then turns amber through the grace period and red once triggerable.
class PulseRing extends StatelessWidget {
  const PulseRing({
    super.key,
    required this.progress,
    required this.color,
    required this.child,
    this.size = 260,
  });

  final double progress;
  final Color color;
  final Widget child;
  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: size,
      child: TweenAnimationBuilder<double>(
        tween: Tween(end: progress.clamp(0, 1)),
        duration: const Duration(milliseconds: 600),
        curve: Curves.easeOutCubic,
        builder: (context, value, _) => CustomPaint(
          painter: _RingPainter(value, color),
          child: Center(child: child),
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter(this.progress, this.color);

  final double progress;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.width / 2 - 14;
    final track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 14
      ..color = DmColors.line;
    canvas.drawCircle(center, radius, track);

    final rect = Rect.fromCircle(center: center, radius: radius);
    final arc = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 14
      ..strokeCap = StrokeCap.round
      ..shader = SweepGradient(
        startAngle: -pi / 2,
        endAngle: 3 * pi / 2,
        colors: [color.withValues(alpha: 0.35), color],
        transform: const GradientRotation(-pi / 2),
      ).createShader(rect);
    canvas.drawArc(rect, -pi / 2, 2 * pi * progress, false, arc);

    final glow = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 26
      ..color = color.withValues(alpha: 0.08)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 12);
    canvas.drawArc(rect, -pi / 2, 2 * pi * progress, false, glow);
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.progress != progress || old.color != color;
}
