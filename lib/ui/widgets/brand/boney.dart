import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../../state/boney.dart';
import '../../../state/boney_skin.dart';
import '../../theme/tokens.dart';
import 'boney_skin_art.dart';
import 'boney_sprites.g.dart';
import 'pixel_art.dart';

export 'boney_sprites.g.dart' show BoneyPose, boneyIdle;

/// How each of Boney's moods looks (docs/brand/v3-assets, "Meet Boney").
extension BoneyMoodUi on BoneyMood {
  BoneyPose get pose => switch (this) {
    BoneyMood.checking => BoneyPose.front,
    BoneyMood.checkedIn => BoneyPose.checkedIn,
    BoneyMood.onTrack => BoneyPose.onTrack,
    BoneyMood.checkInSoon => BoneyPose.checkInSoon,
    BoneyMood.tierDue => BoneyPose.tierDue,
    BoneyMood.lastTier => BoneyPose.lastTier,
    BoneyMood.released => BoneyPose.releasedGhost,
    BoneyMood.noPlan => BoneyPose.noPlan,
  };

  /// Boney's colour is always the plan's status colour.
  DMStatus get status => switch (this) {
    BoneyMood.checking ||
    BoneyMood.checkedIn ||
    BoneyMood.onTrack ||
    BoneyMood.checkInSoon => DMStatus.alive,
    BoneyMood.tierDue || BoneyMood.lastTier => DMStatus.due,
    BoneyMood.released || BoneyMood.noPlan => DMStatus.released,
  };

  /// The tile behind him, as on the widget board.
  Color get background => switch (this) {
    BoneyMood.checking || BoneyMood.checkedIn || BoneyMood.onTrack => DM.deep,
    BoneyMood.tierDue => DMStatus.due.tint,
    BoneyMood.checkInSoon || BoneyMood.released => DM.grave,
    BoneyMood.lastTier || BoneyMood.noPlan => DM.void_,
  };

  /// He fidgets (the idle loop) only while alive.
  bool get idles => status == DMStatus.alive;
}

/// Boney, drawn in whole device pixels like [PixelArt].
///
/// While [mood] is alive he holds his pose for [rest], then plays the
/// idle loop once (front, wink, wink with an arm up, happy with both arms
/// up, wink) and goes back to it. He stands still when [animate] is false,
/// under reduced motion (`MediaQuery.disableAnimations`) and when tickers
/// are muted (`TickerMode`).
///
/// [skin] is drawn over him in the same colour, following his head through
/// every pose; the released ghost wears none.
class BoneyFigure extends StatefulWidget {
  const BoneyFigure({
    super.key,
    required this.mood,
    this.size = 48,
    this.animate = true,
    this.rest = const Duration(seconds: 4),
    this.semanticLabel,
    this.skin,
  });

  final BoneyMood mood;
  final BoneySkin? skin;

  /// Target height of the 26x24 drawing; the cell snaps down to whole
  /// device pixels.
  final double size;
  final bool animate;
  final Duration rest;

  /// Null keeps him decorative.
  final String? semanticLabel;

  @override
  State<BoneyFigure> createState() => _BoneyFigureState();
}

/// Cells to shift the drawing so the figure (Boney's skull and bones, or
/// the ghost over its tombstone) sits at the centre of the grid.
(double, double) _bodyOffset(BoneyMood mood) => _offsets[mood] ??= () {
  final sprites = mood == BoneyMood.released
      ? [for (final l in mood.pose.layers) l.sprite]
      : [BoneyPose.front.layers.first.sprite];
  final sprite = sprites.first;
  var (minX, minY, maxX, maxY) = (sprite.width, sprite.height, -1, -1);
  for (final s in sprites) {
    for (var y = 0; y < s.height; y++) {
      for (var x = 0; x < s.width; x++) {
        if (s.rows[y].codeUnitAt(x) != 0x23) continue;
        if (x < minX) minX = x;
        if (x > maxX) maxX = x;
        if (y < minY) minY = y;
        if (y > maxY) maxY = y;
      }
    }
  }
  if (maxX < 0) return (0.0, 0.0);
  return (
    sprite.width / 2 - (minX + maxX + 1) / 2,
    sprite.height / 2 - (minY + maxY + 1) / 2,
  );
}();

final _offsets = <BoneyMood, (double, double)>{};

class _BoneyFigureState extends State<BoneyFigure> {
  Timer? _timer;

  /// Index into [boneyIdle] while the idle loop plays; null at rest.
  int? _frame;
  bool _running = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reschedule();
  }

  @override
  void didUpdateWidget(BoneyFigure old) {
    super.didUpdateWidget(old);
    if (old.animate != widget.animate ||
        old.mood.idles != widget.mood.idles ||
        old.rest != widget.rest) {
      _reschedule();
    }
  }

  bool get _shouldRun =>
      widget.animate &&
      widget.mood.idles &&
      TickerMode.valuesOf(context).enabled &&
      !(MediaQuery.maybeDisableAnimationsOf(context) ?? false);

  void _reschedule() {
    final run = _shouldRun;
    if (run == _running) return;
    _running = run;
    _timer?.cancel();
    _timer = null;
    _frame = null;
    if (run) _timer = Timer(widget.rest, _advance);
  }

  void _advance() {
    if (!mounted) return;
    final next = _frame == null ? 0 : _frame! + 1;
    setState(() => _frame = next < boneyIdle.length ? next : null);
    _timer = Timer(
      _frame == null ? widget.rest : Duration(milliseconds: boneyIdle[next].ms),
      _advance,
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final mood = widget.mood;
    final frame = _frame;
    final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1;
    final layers = mood.pose.layers;
    final cell = PixelArt.cellFor(layers.first.sprite, widget.size, dpr);
    final color = mood.status.color;
    final body = frame == null ? layers.first.sprite : boneyIdle[frame].sprite;
    final skin = mood == BoneyMood.released ? null : widget.skin?.art;
    final (sx, sy) = skin == null ? (0, 0) : skullShift(body);
    Widget wear(PixelSprite sprite, Color color) => Transform.translate(
      offset: Offset(sx * cell, sy * cell),
      child: PixelArt(sprite, cell: cell, color: color),
    );
    final art = Stack(
      clipBehavior: Clip.none,
      children: [
        if (frame == null)
          for (final (i, l) in layers.indexed)
            PixelArt(
              l.sprite,
              cell: cell,
              // Boney is the status colour; extras (sweat, the
              // tombstone) keep their own.
              color: i == 0 ? color : Color(l.argb),
            )
        else
          PixelArt(body, cell: cell, color: color),
        if (skin != null) ...[
          if (skin.shade case final shade?) wear(shade, DM.void_),
          wear(skin.ink, color),
        ],
      ],
    );
    // Centre Boney himself, not the 26x24 grid: his hearts, "?" and "z"
    // only grow to one side. Snapped to device pixels to stay crisp.
    final (cx, cy) = _bodyOffset(mood);
    double snap(double cells) => (cells * cell * dpr).roundToDouble() / dpr;
    final label = widget.semanticLabel;
    final figure = KeyedSubtree(
      key: ValueKey(
        'boney-${mood.wire}${frame == null ? '' : '-idle-$frame'}'
        '${skin == null ? '' : '-${widget.skin!.id}'}',
      ),
      child: Transform.translate(
        offset: Offset(snap(cx), snap(cy)),
        child: art,
      ),
    );
    if (label == null) return ExcludeSemantics(child: figure);
    return Semantics(label: label, image: true, child: figure);
  }
}
