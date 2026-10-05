import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../theme/tokens.dart';
import 'dm_icons.g.dart';
import 'pixel_art.dart';

export 'dm_icons.g.dart';

/// One icon from the Deadman pixel pack (docs/brand/icons), drawn crisp.
///
/// Works like [Icon]: [color] falls back to the ambient [IconTheme] (so it
/// picks up button, list tile and navigation bar colors), then to Bone.
///
/// The pack is drawn on a 12x12 grid, so each cell is [size] / 12 snapped
/// down to whole device pixels (at least one). The widget always lays out
/// [size] square, like [Icon], and centers the snapped drawing inside it.
/// Sizes that are multiples of 12 (12, 24, 36, 48) fill the box exactly.
class DMIcon extends StatelessWidget {
  const DMIcon(
    this.icon, {
    super.key,
    this.size = 24,
    this.color,
    this.semanticLabel,
  });

  final DMIcons icon;
  final double size;
  final Color? color;

  /// Null keeps the icon decorative (hidden from screen readers).
  final String? semanticLabel;

  /// Cell edge in logical pixels for an icon [size] wide at [dpr].
  static double cellFor(double size, double dpr) {
    final devicePx = math.max(1, (size * dpr / DMIcons.grid).floor());
    return devicePx / dpr;
  }

  /// Edge of the drawn 12-cell box for an icon [size] wide at [dpr].
  static double extentFor(double size, double dpr) =>
      cellFor(size, dpr) * DMIcons.grid;

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1;
    final cell = cellFor(size, dpr);
    final extent = cell * DMIcons.grid;
    final theme = IconTheme.of(context);
    var tint = color ?? theme.color ?? DM.bone;
    final opacity = theme.opacity ?? 1;
    if (opacity != 1) tint = tint.withValues(alpha: tint.a * opacity);

    Widget art = SizedBox.square(
      dimension: math.max(size, extent),
      child: Center(
        child: SizedBox.square(
          dimension: extent,
          child: Padding(
            padding: EdgeInsets.only(left: icon.dx * cell, top: icon.dy * cell),
            child: Align(
              alignment: Alignment.topLeft,
              child: PixelArt(icon.sprite, cell: cell, color: tint),
            ),
          ),
        ),
      ),
    );
    final label = semanticLabel;
    if (label != null) {
      art = Semantics(label: label, image: true, child: art);
    }
    return art;
  }
}

/// A [NavigationBar] destination drawn with a pack icon. The bar's theme
/// tints it through [IconTheme] (Ash idle, Pulse selected), so one icon
/// serves both states.
class DMNavigationDestination extends StatelessWidget {
  const DMNavigationDestination({
    super.key,
    required this.icon,
    required this.label,
    this.tooltip,
    this.enabled = true,
  });

  final DMIcons icon;
  final String label;
  final String? tooltip;
  final bool enabled;

  @override
  Widget build(BuildContext context) => NavigationDestination(
    icon: DMIcon(icon),
    label: label,
    tooltip: tooltip,
    enabled: enabled,
  );
}
