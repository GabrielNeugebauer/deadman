import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../../theme/tokens.dart';

/// A one-color pixel drawing: `#` is a filled cell, anything else is empty.
/// Every grid here is transcribed cell by cell from the brand book
/// (docs/brand/v2, pages 1, 3 and 9).
class PixelSprite {
  const PixelSprite(this.name, this.rows);

  final String name;
  final List<String> rows;

  int get width => rows.first.length;
  int get height => rows.length;

  /// Filled runs per row as (row, firstColumn, length), merged so adjacent
  /// cells paint as one rectangle with no hairline seams between them.
  List<(int, int, int)> get runs =>
      _runs[this] ??= [for (var y = 0; y < height; y++) ..._rowRuns(y)];

  Iterable<(int, int, int)> _rowRuns(int y) sync* {
    final row = rows[y];
    var x = 0;
    while (x < row.length) {
      if (row.codeUnitAt(x) != 0x23) {
        x++;
        continue;
      }
      final start = x;
      while (x < row.length && row.codeUnitAt(x) == 0x23) {
        x++;
      }
      yield (y, start, x - start);
    }
  }

  static final _runs = Expando<List<(int, int, int)>>();

  @override
  String toString() => 'PixelSprite($name ${width}x$height)';
}

/// The skull's expressions ("One skull, four moods", page 3), plus the
/// neutral face of the mark and the app icon (pages 1-2).
enum SkullMood { mark, alive, missed, due, released }

extension DMStatusSprite on DMStatus {
  /// The face this status wears on notifications, widgets and empty states.
  SkullMood get mood => switch (this) {
    DMStatus.alive => SkullMood.alive,
    DMStatus.missed => SkullMood.missed,
    DMStatus.due => SkullMood.due,
    DMStatus.released => SkullMood.released,
    DMStatus.locked => SkullMood.mark,
  };

  /// The small figure on this status's sticker, as in the app mockups:
  /// the mark skull (ALIVE), the missed and due faces, the ghost
  /// (RELEASED) and the lock.
  PixelSprite get sprite => switch (this) {
    DMStatus.alive => PixelSprites.skull,
    DMStatus.missed => PixelSprites.skullMissed,
    DMStatus.due => PixelSprites.skullDue,
    DMStatus.released => PixelSprites.ghost,
    DMStatus.locked => PixelSprites.lock,
  };
}

abstract final class PixelSprites {
  /// The mark: the skull on the app icon and next to the wordmark.
  static const skull = PixelSprite('skull', [
    '...#####...',
    '.#########.',
    '###########',
    '###########',
    '##...#...##',
    '##...#...##',
    '##...#...##',
    '#####.#####',
    '.#########.',
    '..#######..',
    '..#.#.#.#..',
  ]);

  /// Alive: checked in on time. One eye, one heartbeat.
  static const skullAlive = PixelSprite('skull-alive', [
    '...#####...',
    '.#########.',
    '###########',
    '###########',
    '##...######',
    '##...##.###',
    '##...#.#.##',
    '#####.#####',
    '.#########.',
    '..#######..',
    '..#.#.#.#..',
  ]);

  /// Missed a check-in: squinting.
  static const skullMissed = PixelSprite('skull-missed', [
    '...#####...',
    '.#########.',
    '###########',
    '###########',
    '##...#...##',
    '##..##..###',
    '##...#...##',
    '#####.#####',
    '.#########.',
    '..#######..',
    '..#.#.#.#..',
  ]);

  /// Silent past a release tier: crossed-out eyes.
  static const skullDue = PixelSprite('skull-due', [
    '...#####...',
    '.#########.',
    '###########',
    '###########',
    '##.#.#.#.##',
    '###.###.###',
    '##.#.#.#.##',
    '#####.#####',
    '.#########.',
    '..#######..',
    '..#.#.#.#..',
  ]);

  /// Plan fully released: eyes closed.
  static const skullReleased = PixelSprite('skull-released', [
    '...#####...',
    '.#########.',
    '###########',
    '###########',
    '###########',
    '##...#...##',
    '###########',
    '#####.#####',
    '.#########.',
    '..#######..',
    '..#.#.#.#..',
  ]);

  /// Check-ins (page 9). The dark line through it is a heartbeat.
  static const heart = PixelSprite('heart', [
    '.###...###.',
    '#####.#####',
    '###########',
    '####.######',
    '#...##....#',
    '.####.####.',
    '..#######..',
    '...#####...',
    '....###....',
    '.....#.....',
  ]);

  /// A release tier is due (page 9).
  static const tombstone = PixelSprite('tombstone', [
    '...#####...',
    '.#########.',
    '###########',
    '#..##.#..##',
    '#.#.#.#.#.#',
    '#..##.#..##',
    '#.#.#.#.###',
    '#.#.#.#.###',
    '###########',
    '###########',
    '###########',
    '.#########.',
  ]);

  /// Plan fully released (page 9).
  static const ghost = PixelSprite('ghost', [
    '...#####...',
    '.#########.',
    '.#########.',
    '##..###..##',
    '##..###..##',
    '###########',
    '###########',
    '###.....###',
    '###########',
    '###########',
    '##.##.##.##',
  ]);

  /// Lockdown. Not in the brand book; drawn on the cast's grid and weight.
  static const lock = PixelSprite('lock', [
    '..#####..',
    '.##...##.',
    '.#.....#.',
    '.#.....#.',
    '#########',
    '#########',
    '####.####',
    '####.####',
    '#########',
    '#########',
  ]);

  /// The DEADMAN wordmark (page 1), 7 cells tall.
  static const wordmark = PixelSprite('wordmark', [
    '####..#####..###..####..#...#..###..#...#',
    '#...#.#.....#...#.#...#.##.##.#...#.##..#',
    '#...#.#.....#...#.#...#.#.#.#.#...#.##..#',
    '#...#.####..#####.#...#.#.#.#.#####.#.#.#',
    '#...#.#.....#...#.#...#.#...#.#...#.#..##',
    '#...#.#.....#...#.#...#.#...#.#...#.#..##',
    '####..#####.#...#.####..#...#.#...#.#...#',
  ]);

  static PixelSprite forMood(SkullMood mood) => switch (mood) {
    SkullMood.mark => skull,
    SkullMood.alive => skullAlive,
    SkullMood.missed => skullMissed,
    SkullMood.due => skullDue,
    SkullMood.released => skullReleased,
  };
}

/// Draws a [PixelSprite] in whole device pixels.
///
/// [size] is the target height. The cell size snaps down to a whole number
/// of device pixels (at least one), so the drawing can come out slightly
/// smaller than asked but never blurs. The origin snaps to the device grid
/// too, so cells never straddle a pixel boundary.
class PixelArt extends StatelessWidget {
  const PixelArt(
    this.sprite, {
    super.key,
    this.size = 24,
    this.color = DM.bone,
    this.semanticLabel,
    this.cell,
  });

  final PixelSprite sprite;
  final double size;
  final Color color;

  /// Cell edge in logical pixels, for callers that already snapped it to
  /// the device grid. Overrides [size] when set.
  final double? cell;

  /// Null keeps the drawing decorative (hidden from screen readers).
  final String? semanticLabel;

  /// Cell edge in logical pixels for a sprite drawn [size] tall.
  static double cellFor(PixelSprite sprite, double size, double dpr) {
    final devicePx = math.max(1, (size * dpr / sprite.height).floor());
    return devicePx / dpr;
  }

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1;
    final art = _PixelBox(
      sprite: sprite,
      color: color,
      cell: cell ?? cellFor(sprite, size, dpr),
      dpr: dpr,
    );
    final label = semanticLabel;
    if (label == null) return ExcludeSemantics(child: art);
    return Semantics(label: label, image: true, child: art);
  }
}

/// A skull in one of its moods. Defaults to the mark's neutral face.
class PixelSkull extends StatelessWidget {
  const PixelSkull({
    super.key,
    this.mood = SkullMood.mark,
    this.size = 24,
    this.color = DM.pulse,
    this.semanticLabel,
  });

  /// The face for [status], in the status color.
  PixelSkull.status(
    DMStatus status, {
    super.key,
    this.size = 24,
    this.semanticLabel,
  }) : mood = status.mood,
       color = status.color;

  final SkullMood mood;
  final double size;
  final Color color;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) => PixelArt(
    PixelSprites.forMood(mood),
    size: size,
    color: color,
    semanticLabel: semanticLabel,
  );
}

class _PixelBox extends LeafRenderObjectWidget {
  const _PixelBox({
    required this.sprite,
    required this.color,
    required this.cell,
    required this.dpr,
  });

  final PixelSprite sprite;
  final Color color;
  final double cell;
  final double dpr;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderPixels(sprite, color, cell, dpr);

  @override
  void updateRenderObject(BuildContext context, _RenderPixels render) {
    render
      ..sprite = sprite
      ..color = color
      ..cell = cell
      ..dpr = dpr;
  }
}

class _RenderPixels extends RenderBox {
  _RenderPixels(this._sprite, this._color, this._cell, this._dpr);

  PixelSprite _sprite;
  set sprite(PixelSprite v) {
    if (identical(v, _sprite)) return;
    _sprite = v;
    markNeedsLayout();
  }

  Color _color;
  set color(Color v) {
    if (v == _color) return;
    _color = v;
    markNeedsPaint();
  }

  double _cell;
  set cell(double v) {
    if (v == _cell) return;
    _cell = v;
    markNeedsLayout();
  }

  double _dpr;
  set dpr(double v) {
    if (v == _dpr) return;
    _dpr = v;
    markNeedsPaint();
  }

  Size get _natural => Size(_sprite.width * _cell, _sprite.height * _cell);

  @override
  void performLayout() => size = constraints.constrain(_natural);

  @override
  double computeMinIntrinsicWidth(double height) => _natural.width;
  @override
  double computeMaxIntrinsicWidth(double height) => _natural.width;
  @override
  double computeMinIntrinsicHeight(double width) => _natural.height;
  @override
  double computeMaxIntrinsicHeight(double width) => _natural.height;

  @override
  Size computeDryLayout(BoxConstraints constraints) =>
      constraints.constrain(_natural);

  @override
  void paint(PaintingContext context, Offset offset) {
    double snap(double v) => (v * _dpr).roundToDouble() / _dpr;
    final origin = Offset(snap(offset.dx), snap(offset.dy));
    final path = Path();
    for (final (y, x, len) in _sprite.runs) {
      path.addRect(
        Rect.fromLTWH(
          origin.dx + x * _cell,
          origin.dy + y * _cell,
          len * _cell,
          _cell,
        ),
      );
    }
    context.canvas.drawPath(
      path,
      Paint()
        ..color = _color
        ..isAntiAlias = false,
    );
  }
}
