import 'dart:math';

import 'package:flutter/material.dart';

import '../theme/tokens.dart';
import 'brand/labels.dart';

/// The Pulse ring from the v2 mockups: [ticks] square-ended segments around
/// a circle. Lit ticks (status color) are the time left, starting at
/// 12 o'clock and running clockwise; spent ticks go dim at the end of the
/// sweep, just left of 12. When a tier is due the ring stops counting and
/// alternates lit and dim ticks instead.
///
/// With [size] null the ring takes the largest circle that fits its
/// constraints, so it can fill whatever height the screen gives it. The
/// [child] sits inside and can read the diameter with [RingScope.of].
class SegmentedRing extends StatelessWidget {
  const SegmentedRing({
    super.key,
    required this.progress,
    this.status = DMStatus.alive,
    this.child,
    this.size,
    this.ticks = 56,
    this.phase = 0,
    this.alternate,
    this.color,
  });

  /// Remaining share of the window, 0..1. Ignored while alternating.
  final double progress;
  final DMStatus status;
  final Widget? child;

  /// Diameter. Null fills the available space (min of width and height).
  final double? size;
  final int ticks;

  /// Shifts the due pattern by one tick per step. Pass a counter that
  /// changes once a second (e.g. the countdown's seconds) for a slow
  /// alternation; the ring itself never runs an endless animation.
  final int phase;

  /// Forces the alternating pattern on or off. Defaults to
  /// `status == DMStatus.due`.
  final bool? alternate;

  /// Overrides the status color of lit ticks. Prefer [status].
  final Color? color;

  /// Diameter used when the constraints are unbounded both ways.
  static const fallbackSize = 280.0;

  @override
  Widget build(BuildContext context) {
    final fixed = size;
    if (fixed != null) return _ring(context, fixed);
    return LayoutBuilder(
      builder: (context, box) {
        final w = box.maxWidth, h = box.maxHeight;
        final d = w.isFinite && h.isFinite
            ? min(w, h)
            : w.isFinite
            ? w
            : h.isFinite
            ? h
            : fallbackSize;
        return Center(child: _ring(context, d));
      },
    );
  }

  Widget _ring(BuildContext context, double d) {
    final reduce = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final tickLength = _tickLength(d);
    final inner = d - 2 * tickLength;
    final alternating = alternate ?? status == DMStatus.due;
    return SizedBox.square(
      dimension: d,
      child: TweenAnimationBuilder<double>(
        tween: Tween(end: progress.clamp(0, 1).toDouble()),
        duration: reduce ? Duration.zero : const Duration(milliseconds: 600),
        curve: Curves.easeOutCubic,
        builder: (context, value, inside) => CustomPaint(
          painter: _TickPainter(
            progress: value,
            ticks: ticks,
            lit: color ?? status.color,
            dim: status.dimTick,
            tickLength: tickLength,
            alternating: alternating,
            phase: phase,
          ),
          child: inside,
        ),
        child: RingScope(
          diameter: d,
          child: Padding(
            // The readout's widest line runs across the middle, so the
            // sides inset less than the top and bottom.
            padding: EdgeInsets.symmetric(
              horizontal: tickLength + inner * 0.08,
              vertical: tickLength + inner * 0.12,
            ),
            child: Center(child: child),
          ),
        ),
      ),
    );
  }

  static double _tickLength(double d) => max(6, d * 0.05);
}

/// The diameter of the [SegmentedRing] around a widget.
class RingScope extends InheritedWidget {
  const RingScope({super.key, required this.diameter, required super.child});

  final double diameter;

  static double? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<RingScope>()?.diameter;

  @override
  bool updateShouldNotify(RingScope old) => old.diameter != diameter;
}

class _TickPainter extends CustomPainter {
  _TickPainter({
    required this.progress,
    required this.ticks,
    required this.lit,
    required this.dim,
    required this.tickLength,
    required this.alternating,
    required this.phase,
  });

  final double progress;
  final int ticks;
  final Color lit;
  final Color dim;
  final double tickLength;
  final bool alternating;
  final int phase;

  /// Share of each step a tick covers (the mockups' tick-to-gap ratio).
  static const _fill = 0.62;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final outer = size.shortestSide / 2;
    final inner = outer - tickLength;
    final step = 2 * pi / ticks;
    final halfWidth = (outer + inner) / 2 * step * _fill / 2;
    final litCount = (progress * ticks).ceil().clamp(0, ticks);

    final on = Path(), off = Path();
    for (var i = 0; i < ticks; i++) {
      final a = -pi / 2 + i * step;
      final u = Offset(cos(a), sin(a));
      final v = Offset(-u.dy, u.dx) * halfWidth;
      final p0 = c + u * inner, p1 = c + u * outer;
      final isLit = alternating ? (i + phase).isEven : i < litCount;
      (isLit ? on : off).addPolygon([p0 - v, p1 - v, p1 + v, p0 + v], true);
    }
    canvas
      ..drawPath(off, Paint()..color = dim)
      ..drawPath(on, Paint()..color = lit);
  }

  @override
  bool shouldRepaint(_TickPainter old) =>
      old.progress != progress ||
      old.ticks != ticks ||
      old.lit != lit ||
      old.dim != dim ||
      old.tickLength != tickLength ||
      old.alternating != alternating ||
      old.phase != phase;
}

/// What sits inside the ring, top to bottom: status sticker, mono
/// countdown in the status color, caption ("until tier 1 releases"), an
/// optional mono address line ("4Ywp…KMbF") and the plan name.
///
/// Inside a [SegmentedRing] the type scales with the ring's diameter.
class PulseReadout extends StatelessWidget {
  const PulseReadout({
    super.key,
    required this.status,
    required this.countdown,
    this.statusLabel,
    this.caption,
    this.address,
    this.detail,
    this.countdownKey,
  });

  final DMStatus status;

  /// "1m 55s". Scales down to fit long values ("12d 23h 59m").
  final String countdown;

  /// Sticker word; defaults to the status word ("TIER DUE").
  final String? statusLabel;

  /// "until tier 1 releases", "past due, releasing to".
  final String? caption;

  /// Mono line under the caption: who the release goes to.
  final String? address;

  /// The most urgent plan's name.
  final String? detail;
  final Key? countdownKey;

  @override
  Widget build(BuildContext context) {
    final d = RingScope.of(context) ?? 240;
    double scaled(double share, double lo, double hi) =>
        (d * share).clamp(lo, hi).toDouble();
    final captionSize = scaled(0.06, 14, 20);
    final address = this.address;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        FittedBox(
          fit: BoxFit.scaleDown,
          child: StatusSticker(status, label: statusLabel, dense: d < 200),
        ),
        SizedBox(height: scaled(0.045, 8, 18)),
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            countdown,
            key: countdownKey,
            maxLines: 1,
            style: DMType.countdown(status.color, size: scaled(0.165, 32, 104)),
          ),
        ),
        if (caption != null) ...[
          SizedBox(height: scaled(0.03, 4, 12)),
          Text(
            caption!,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: DMType.outfit(
              size: captionSize,
              color: DM.haze,
              height: 1.3,
            ),
          ),
        ],
        if (address != null) ...[
          const SizedBox(height: 2),
          Text(
            address,
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: DMType.mono(size: captionSize * 0.94, height: 1.4),
          ),
        ],
        if (detail != null) ...[
          SizedBox(height: scaled(0.015, 2, 6)),
          Text(
            detail!,
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: DMType.outfit(size: scaled(0.05, 13, 16), color: DM.ash),
          ),
        ],
      ],
    );
  }
}

/// v1 name of the ring. Draws a [SegmentedRing].
@Deprecated('Use SegmentedRing')
class PulseRing extends StatelessWidget {
  const PulseRing({
    super.key,
    required this.progress,
    required this.child,
    this.status = DMStatus.alive,
    this.color,
    this.size = 240,
    this.strokeWidth = 10,
  });

  final double progress;
  final Widget child;
  final DMStatus status;
  final Color? color;
  final double size;

  /// Ignored: tick length follows the diameter.
  final double strokeWidth;

  @override
  Widget build(BuildContext context) => SegmentedRing(
    progress: progress,
    status: status,
    color: color,
    size: size,
    child: child,
  );
}
