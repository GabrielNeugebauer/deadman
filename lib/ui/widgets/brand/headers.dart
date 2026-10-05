import 'package:flutter/material.dart';

import '../../theme/tokens.dart';

/// Screen title row: "Pulse" + the mark, "Security" + a status chip, with
/// an optional lead paragraph below ("People who named you in…").
class PageHeader extends StatelessWidget {
  const PageHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing,
  });

  final String title;
  final String? subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Semantics(
                header: true,
                child: Text(title, style: t.headlineMedium),
              ),
            ),
            if (trailing != null) ...[
              const SizedBox(width: DMSpace.md),
              trailing!,
            ],
          ],
        ),
        if (subtitle != null) ...[
          const SizedBox(height: DMSpace.sm),
          Text(subtitle!, style: t.bodyMedium),
        ],
      ],
    );
  }
}

/// Section title with an optional trailing action: "Release plans
/// + New plan".
class SectionHeader extends StatelessWidget {
  const SectionHeader({
    super.key,
    required this.title,
    this.actionLabel,
    this.onAction,
    this.actionIcon = Icons.add,
    this.actionKey,
    this.trailing,
  });

  final String title;
  final String? actionLabel;
  final VoidCallback? onAction;
  final IconData? actionIcon;
  final Key? actionKey;

  /// Replaces the text action, e.g. a [StatusChip] or a count.
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final label = actionLabel;
    Widget? action = trailing;
    if (action == null && label != null) {
      action = actionIcon == null
          ? TextButton(key: actionKey, onPressed: onAction, child: Text(label))
          : TextButton.icon(
              key: actionKey,
              onPressed: onAction,
              icon: Icon(actionIcon, size: 18),
              label: Text(label),
            );
    }
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 48),
      child: Row(
        children: [
          Expanded(
            child: Semantics(
              header: true,
              child: Text(title, style: t.titleLarge),
            ),
          ),
          ?action,
        ],
      ),
    );
  }
}
