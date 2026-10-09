import 'package:flutter/material.dart';

import '../../theme/tokens.dart';

/// Grave card with a 1px line border. Cards never nest: group rows with
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
  /// (e.g. `DM.flatline.withValues(alpha: 0.35)`); the fill stays grave.
  final Color borderColor;

  @override
  Widget build(BuildContext context) {
    final body = Padding(padding: padding, child: child);
    return Material(
      color: DM.grave,
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
/// "Owner wallet / Guard key").
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
                        : DMType.outfit(size: 14, color: DM.dust),
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

/// Square holding an icon, sunk into the card in void (as on the payout
/// editor's rail cards). [tone] tints it (the panic tile uses
/// [DM.flatline]). [child] replaces the icon, e.g. with a [PixelArt].
class IconTile extends StatelessWidget {
  const IconTile({super.key, this.icon, this.tone, this.size = 36, this.child})
    : assert(icon != null || child != null);

  final IconData? icon;
  final Color? tone;
  final double size;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final tone = this.tone;
    return SizedBox.square(
      dimension: size,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: tone == null ? DM.void_ : tone.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(size * 0.25),
        ),
        child: Center(
          child: child ?? Icon(icon, size: size * 0.5, color: tone ?? DM.bone),
        ),
      ),
    );
  }
}

/// The square app-bar button from the Pulse mockups (the skull button):
/// grave, 1px line, 44 visible inside a 48 touch target. [badge] adds a
/// count, e.g. the number of release plans.
class DMSquareButton extends StatelessWidget {
  const DMSquareButton({
    super.key,
    required this.child,
    required this.onPressed,
    required this.tooltip,
    this.badge,
    this.selected = false,
  });

  final Widget child;
  final VoidCallback? onPressed;

  /// Also the button's accessible name.
  final String tooltip;

  /// Count shown on a pulse badge; null or 0 hides it.
  final int? badge;

  /// Deep fill and pulse border while the screen it opens is showing.
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final count = badge ?? 0;
    final face = Material(
      color: selected ? DM.deep : DM.grave,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(DMRadius.button),
        side: BorderSide(color: selected ? DM.pulse : DM.line),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onPressed,
        child: SizedBox.square(dimension: 44, child: Center(child: child)),
      ),
    );
    return Tooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        enabled: onPressed != null,
        label: count > 0 ? '$tooltip, $count' : tooltip,
        excludeSemantics: true,
        onTap: onPressed,
        child: SizedBox.square(
          dimension: 48,
          child: Center(
            child: count > 0
                ? Badge(
                    label: Text('$count'),
                    offset: const Offset(-2, -2),
                    child: face,
                  )
                : face,
          ),
        ),
      ),
    );
  }
}

/// Radio card for a choice that needs a sentence of explanation (the
/// payout editor's "How it arrives"). Selected: deep fill, pulse border,
/// pulse footnote. Group several in a Column with 12 between them.
class SelectCard extends StatelessWidget {
  const SelectCard({
    super.key,
    required this.selected,
    required this.title,
    required this.onTap,
    this.icon,
    this.body,
    this.footnote,
    this.tag,
  });

  final bool selected;
  final String title;

  /// Null disables the card.
  final VoidCallback? onTap;
  final IconData? icon;
  final String? body;

  /// Mono line under the body: "2% fee".
  final String? footnote;

  /// Beside the title, e.g. `DMTag(label: 'mainnet only', mono: true)`.
  final Widget? tag;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    final body = this.body;
    final footnote = this.footnote;
    final card = Material(
      color: selected ? DM.deep : DM.grave,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(DMRadius.card),
        side: BorderSide(
          color: selected ? DM.pulse : DM.line,
          width: selected ? 1.5 : 1,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 14, 16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (icon != null) ...[
                IconTile(
                  size: 44,
                  child: Icon(
                    icon,
                    size: 22,
                    color: selected ? DM.pulse : DM.bone,
                  ),
                ),
                const SizedBox(width: 14),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          title,
                          style: DMType.outfit(
                            size: 17,
                            weight: FontWeight.w700,
                            color: enabled ? DM.bone : DM.ash,
                          ),
                        ),
                        ?tag,
                      ],
                    ),
                    if (body != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        body,
                        style: DMType.outfit(
                          size: 14.5,
                          color: DM.dust,
                          height: 1.4,
                        ),
                      ),
                    ],
                    if (footnote != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        footnote,
                        style: DMType.data(
                          size: 12.5,
                          color: selected ? DM.pulse : DM.haze,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 10),
              _RadioDot(selected: selected, enabled: enabled),
            ],
          ),
        ),
      ),
    );
    return Semantics(
      inMutuallyExclusiveGroup: true,
      checked: selected,
      enabled: enabled,
      child: card,
    );
  }
}

class _RadioDot extends StatelessWidget {
  const _RadioDot({required this.selected, required this.enabled});

  final bool selected;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final color = selected ? DM.pulse : (enabled ? DM.ash : DM.line);
    return SizedBox.square(
      dimension: 24,
      child: DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: color, width: 2),
        ),
        child: selected
            ? Padding(
                padding: const EdgeInsets.all(5),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: color,
                  ),
                ),
              )
            : null,
      ),
    );
  }
}
