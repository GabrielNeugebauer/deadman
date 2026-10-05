import 'package:flutter/material.dart';

import '../../theme/tokens.dart';

/// Mono caption, uppercase and letter-spaced: "DAY STREAK", "PLAN".
class MonoLabel extends StatelessWidget {
  const MonoLabel(
    this.text, {
    super.key,
    this.color = DM.mist,
    this.size = 10.5,
    this.upper = true,
    this.spacing = 1.5,
    this.weight = FontWeight.w400,
    this.maxLines,
    this.textAlign,
  });

  final String text;
  final Color color;
  final double size;
  final bool upper;
  final double spacing;
  final FontWeight weight;
  final int? maxLines;
  final TextAlign? textAlign;

  @override
  Widget build(BuildContext context) => Text(
    upper ? text.toUpperCase() : text,
    maxLines: maxLines,
    overflow: maxLines == null ? null : TextOverflow.ellipsis,
    textAlign: textAlign,
    style: DMType.mono(
      size: size,
      color: color,
      spacing: spacing,
      weight: weight,
    ),
  );
}

/// Status chip: square dot + mono caps label on the status tint.
/// [label] overrides the status's own word ("TIER IN 56S", "UNLOCKED").
class StatusChip extends StatelessWidget {
  const StatusChip(this.status, {super.key, this.label, this.dense = false});

  final DMStatus status;
  final String? label;

  /// Tighter padding for chips inside list rows.
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final color = status.color;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: status.tint,
        borderRadius: BorderRadius.circular(DMRadius.chip),
      ),
      child: Padding(
        padding: dense
            ? const EdgeInsets.symmetric(horizontal: 8, vertical: 4)
            : const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox.square(dimension: 6, child: ColoredBox(color: color)),
            const SizedBox(width: 7),
            Flexible(
              child: Text(
                (label ?? status.label).toUpperCase(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: DMType.chip(color),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Rail / asset tag with an outline: "⚡ Solana" on plan cards.
class DMTag extends StatelessWidget {
  const DMTag({super.key, required this.label, this.icon});

  final String label;
  final IconData? icon;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      border: Border.all(color: DM.line),
      borderRadius: BorderRadius.circular(DMRadius.chip),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 14, color: DM.bone),
            const SizedBox(width: 6),
          ],
          Text(label, style: DMType.outfit(size: 13, weight: FontWeight.w500)),
        ],
      ),
    ),
  );
}
