import 'dart:math';

import 'package:flutter/material.dart';

import '../theme/tokens.dart';
import 'brand/labels.dart';

/// Countdown ring: full when just pulsed, empties toward the pulse due time.
/// Flat ends, no glow. The arc takes the [status] color; a due tier turns
/// the whole ring into dashes on a due-tinted track.
class PulseRing extends StatelessWidget {
  const PulseRing({
    super.key,
    required this.progress,
    required this.child,
    this.status = DMStatus.onTrack,
    this.color,
    this.size = 240,
    this.strokeWidth = 10,
  });

  /// Remaining share of the window, 0..1.
  final double progress;
  final Widget child;
  final DMStatus status;

  /// Overrides the status color of the arc. Prefer [status].
  final Color? color;
  final double size;
  final double strokeWidth;

  @override
  Widget build(BuildContext context) {
    final dashed = status == DMStatus.due;
    final arcColor = color ?? status.color;
    return SizedBox.square(
      dimension: size,
      child: TweenAnimationBuilder<double>(
        tween: Tween(end: progress.clamp(0, 1).toDouble()),
        duration: const Duration(milliseconds: 600),
        curve: Curves.easeOutCubic,
        builder: (context, value, inner) => CustomPaint(
          painter: _RingPainter(
            progress: value,
            color: arcColor,
            dashed: dashed,
            strokeWidth: strokeWidth,
          ),
          child: inner,
        ),
        // Keeps the readout inside the ring: the chord is widest across the
        // middle, so the side inset is smaller than the top/bottom one.
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: strokeWidth + size * 0.07,
            vertical: strokeWidth + size * 0.12,
          ),
          child: Center(child: child),
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter({
    required this.progress,
    required this.color,
    required this.dashed,
    required this.strokeWidth,
  });

  final double progress;
  final Color color;
  final bool dashed;
  final double strokeWidth;

  static const _dashes = 48;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromCircle(
      center: size.center(Offset.zero),
      radius: size.width / 2 - strokeWidth / 2,
    );
    final track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..color = dashed ? color.withValues(alpha: 0.2) : DM.track;
    canvas.drawArc(rect, 0, 2 * pi, false, track);

    final arc = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.butt
      ..color = color;
    if (dashed) {
      const step = 2 * pi / _dashes;
      for (var i = 0; i < _dashes; i++) {
        canvas.drawArc(rect, -pi / 2 + i * step, step * 0.32, false, arc);
      }
    } else if (progress > 0) {
      canvas.drawArc(rect, -pi / 2, 2 * pi * progress, false, arc);
    }
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.progress != progress ||
      old.color != color ||
      old.dashed != dashed ||
      old.strokeWidth != strokeWidth;
}

/// What sits inside the ring: status chip, mono countdown, caption.
class PulseReadout extends StatelessWidget {
  const PulseReadout({
    super.key,
    required this.status,
    required this.countdown,
    this.statusLabel,
    this.caption,
    this.detail,
    this.countdownKey,
  });

  final DMStatus status;

  /// "1m 49s". Scales down to fit long values ("12d 23h 59m").
  final String countdown;

  /// Chip text; defaults to the status word ("CHECK-IN OVERDUE").
  final String? statusLabel;

  /// "until next check-in", "releasing to AppA…9PbA".
  final String? caption;

  /// Optional second caption line (e.g. the most urgent plan's name).
  final String? detail;
  final Key? countdownKey;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      FittedBox(
        fit: BoxFit.scaleDown,
        child: StatusChip(status, label: statusLabel),
      ),
      const SizedBox(height: 14),
      FittedBox(
        fit: BoxFit.scaleDown,
        child: Text(
          countdown,
          key: countdownKey,
          maxLines: 1,
          style: DMType.countdown(status.color),
        ),
      ),
      if (caption != null) ...[
        const SizedBox(height: 6),
        Text(
          caption!,
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: DMType.outfit(size: 15, color: DM.sub),
        ),
      ],
      if (detail != null) ...[
        const SizedBox(height: 2),
        Text(
          detail!,
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: DMType.outfit(size: 13, color: DM.mist),
        ),
      ],
    ],
  );
}
