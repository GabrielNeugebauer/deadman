import 'package:flutter/material.dart';

import '../../theme/tokens.dart';
import 'labels.dart';

/// Graphite card with a 1px line border. Cards never nest: group rows with
/// [DMListGroup] and separate blocks inside a card with a [Divider].
class DMCard extends StatelessWidget {
  const DMCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(DMSpace.cardPadding),
    this.onTap,
    this.borderColor = DM.line,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;

  /// Only for the panic / alert card, which takes a faint status border
  /// (e.g. `DM.due.withValues(alpha: 0.35)`); the fill stays graphite.
  final Color borderColor;

  @override
  Widget build(BuildContext context) {
    final body = Padding(padding: padding, child: child);
    return Material(
      color: DM.graphite,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(DMRadius.card),
        side: BorderSide(color: borderColor),
      ),
      child: onTap == null ? body : InkWell(onTap: onTap, child: body),
    );
  }
}

/// One card holding rows split by full-width 1px lines (Security's
/// "Owner wallet / Guard key", the rail picker).
class DMListGroup extends StatelessWidget {
  const DMListGroup({
    super.key,
    required this.children,
    this.header,
    this.borderColor = DM.line,
  });

  final List<Widget> children;

  /// Optional block above the first row ("Receive privately" + lead).
  final Widget? header;
  final Color borderColor;

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[
      if (header != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(
            DMSpace.lg,
            DMSpace.lg,
            DMSpace.lg,
            DMSpace.md,
          ),
          child: header,
        ),
    ];
    for (final child in children) {
      if (rows.isNotEmpty) {
        rows.add(const Divider(height: 1, thickness: 1, color: DM.line));
      }
      rows.add(child);
    }
    return DMCard(
      padding: EdgeInsets.zero,
      borderColor: borderColor,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: rows,
      ),
    );
  }
}

/// Row inside a [DMListGroup] or a [DMCard]: icon tile, title, mono
/// detail line, trailing value or action.
class DMListRow extends StatelessWidget {
  const DMListRow({
    super.key,
    required this.title,
    this.subtitle,
    this.leading,
    this.trailing,
    this.onTap,
    this.monoSubtitle = true,
    this.padding = const EdgeInsets.symmetric(
      horizontal: DMSpace.lg,
      vertical: 14,
    ),
  });

  final String title;
  final String? subtitle;
  final Widget? leading;
  final Widget? trailing;
  final VoidCallback? onTap;

  /// Addresses, amounts and durations read in mono; plain sentences don't.
  final bool monoSubtitle;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final sub = subtitle;
    final row = Padding(
      padding: padding,
      child: Row(
        children: [
          if (leading != null) ...[leading!, const SizedBox(width: 14)],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: DMType.outfit(size: 16, weight: FontWeight.w600),
                ),
                if (sub != null) ...[
                  const SizedBox(height: 3),
                  Text(
                    sub,
                    style: monoSubtitle
                        ? DMType.data(size: 12.5)
                        : DMType.outfit(size: 14, color: DM.sub),
                  ),
                ],
              ],
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: DMSpace.md),
            trailing!,
          ],
        ],
      ),
    );
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 56),
      child: onTap == null ? row : InkWell(onTap: onTap, child: row),
    );
  }
}

/// Raised square holding an icon. [tone] tints it (the panic tile uses
/// [DM.due]); otherwise it is raise + bone.
class IconTile extends StatelessWidget {
  const IconTile({super.key, required this.icon, this.tone, this.size = 36});

  final IconData icon;
  final Color? tone;
  final double size;

  @override
  Widget build(BuildContext context) {
    final tone = this.tone;
    return SizedBox.square(
      dimension: size,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: tone == null ? DM.raise : tone.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(size * 0.25),
        ),
        child: Icon(icon, size: size * 0.5, color: tone ?? DM.bone),
      ),
    );
  }
}

/// One cell of [StatTiles]: mono value over a mono caps label.
class StatTile extends StatelessWidget {
  const StatTile({
    super.key,
    required this.value,
    required this.label,
    this.color = DM.bone,
  });

  final String value;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Semantics(
    label: '$label: $value',
    excludeSemantics: true,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(value, maxLines: 1, style: DMType.stat(color: color)),
          ),
          const SizedBox(height: 8),
          MonoLabel(label, maxLines: 1),
        ],
      ),
    ),
  );
}

/// The 3-up row under the check-in button: DAY STREAK / BEST / PLAN.
class StatTiles extends StatelessWidget {
  const StatTiles({super.key, required this.children});

  final List<StatTile> children;

  @override
  Widget build(BuildContext context) {
    final cells = <Widget>[];
    for (final tile in children) {
      if (cells.isNotEmpty) {
        cells.add(
          const VerticalDivider(width: 1, thickness: 1, color: DM.line),
        );
      }
      cells.add(Expanded(child: tile));
    }
    return DMCard(
      padding: EdgeInsets.zero,
      child: IntrinsicHeight(child: Row(children: cells)),
    );
  }
}
