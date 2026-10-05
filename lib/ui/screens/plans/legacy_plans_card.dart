import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../state/actions.dart';
import '../../../state/providers.dart';
import '../../widgets/brand/brand.dart';
import '../../widgets/feedback.dart';

/// Plans an upgrade left in an older layout: the app cannot show them, but
/// the owner can take their SOL back. Renders nothing when there are none;
/// otherwise [margin] spaces it from its neighbours.
class LegacyPlansCard extends ConsumerStatefulWidget {
  const LegacyPlansCard({super.key, this.margin = EdgeInsets.zero});

  final EdgeInsetsGeometry margin;

  @override
  ConsumerState<LegacyPlansCard> createState() => _LegacyPlansCardState();
}

class _LegacyPlansCardState extends ConsumerState<LegacyPlansCard> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final ids = ref.watch(legacyPlansProvider).value ?? const [];
    if (ids.isEmpty) return const SizedBox.shrink();
    final n = ids.length;
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: widget.margin,
      child: DMCard(
        padding: const EdgeInsets.fromLTRB(
          DMSpace.lg,
          DMSpace.lg,
          DMSpace.sm,
          DMSpace.xs,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const IconTile(child: DMIcon(DMIcons.history)),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    n == 1
                        ? '1 plan from an older version'
                        : '$n plans from an older version',
                    style: t.titleMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: DMSpace.md),
            Padding(
              padding: const EdgeInsets.only(right: DMSpace.sm),
              child: Text(
                'An upgrade changed the plan format, so these plans no longer '
                'run. Recover them to close them and return all their SOL to '
                'your wallet, then create new plans.',
                style: t.bodyMedium,
              ),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: _busy ? null : () => _recover(ids),
                child: Text(_busy ? 'Recovering…' : 'Recover SOL'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _recover(List<int> ids) async {
    setState(() => _busy = true);
    final ok = await runGuarded(
      context,
      () => ref.read(actionsProvider).recoverLegacyPlans(ids),
      success: 'SOL returned to your wallet',
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) ref.invalidate(legacyPlansProvider);
  }
}
