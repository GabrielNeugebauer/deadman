import 'package:flutter/material.dart';

import '../../solana/deadman_api.dart';
import '../rules_format.dart';
import 'brand/brand.dart';

/// [IconTile] holding a pack icon, in Bone or in [tone] (the panic tile is
/// Flatline). The icon is two thirds of the tile: 24 in the usual 36.
class DMIconTile extends StatelessWidget {
  const DMIconTile(this.icon, {super.key, this.tone, this.size = 36});

  final DMIcons icon;
  final Color? tone;
  final double size;

  @override
  Widget build(BuildContext context) => IconTile(
    tone: tone,
    size: size,
    child: DMIcon(icon, size: size * 2 / 3, color: tone ?? DM.bone),
  );
}

/// A rail's icon: Cloak and Zcash from the pack. Solana has no pack icon,
/// so it keeps the Material bolt at the size it had before the pack.
class RailIcon extends StatelessWidget {
  const RailIcon(this.rail, {super.key, this.size = 24, this.color});

  final Rail rail;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) => switch (rail.dmIcon) {
    final icon? => DMIcon(icon, size: size, color: color),
    null => Icon(rail.icon, size: size * 0.75, color: color),
  };
}

/// The rail's [IconTile], for rows that list rails.
class RailTile extends StatelessWidget {
  const RailTile(this.rail, {super.key});

  final Rail rail;

  @override
  Widget build(BuildContext context) =>
      IconTile(child: RailIcon(rail, color: DM.bone));
}
