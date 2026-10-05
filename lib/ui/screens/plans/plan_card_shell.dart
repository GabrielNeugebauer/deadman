import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../solana/deadman_api.dart';
import '../../../state/plan_math.dart';
import '../../widgets/brand/brand.dart';

/// Every tier has paid (inheritance) or every schedule has released all it
/// will ever owe (vesting): the program refuses any change to the plan.
bool planReleased(VaultState v) => v.rules.isNotEmpty && v.completed;

/// Which plan cards (by vault address) and sections are open. Kept in
/// memory only: everything starts collapsed on the next launch.
class ExpandedPlans extends Notifier<Set<String>> {
  @override
  Set<String> build() => const {};

  void toggle(String id) =>
      state = state.contains(id) ? ({...state}..remove(id)) : {...state, id};
}

final expandedPlansProvider = NotifierProvider<ExpandedPlans, Set<String>>(
  ExpandedPlans.new,
);

/// Id of the "Released" section in [expandedPlansProvider].
const releasedSectionId = 'section:released';

Duration _motion(BuildContext context) =>
    MediaQuery.disableAnimationsOf(context)
    ? Duration.zero
    : const Duration(milliseconds: 260);

/// The row chevron, turned down while [open].
class CollapseChevron extends StatelessWidget {
  const CollapseChevron({super.key, required this.open});

  final bool open;

  @override
  Widget build(BuildContext context) => AnimatedRotation(
    turns: open ? 0.25 : 0,
    duration: _motion(context),
    curve: Curves.easeOutQuart,
    child: const DMIcon(DMIcons.chevronRight, color: DM.ash),
  );
}

/// A tap target of at least 48 that opens and closes a section, announced
/// as a button with its expanded state.
class ExpandToggle extends StatelessWidget {
  const ExpandToggle({
    super.key,
    required this.open,
    required this.onTap,
    required this.child,
    this.padding = EdgeInsets.zero,
  });

  final bool open;
  final VoidCallback onTap;
  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    expanded: open,
    onTapHint: open ? 'collapse' : 'expand',
    child: InkWell(
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48),
        child: Padding(padding: padding, child: child),
      ),
    ),
  );
}

/// Grows from nothing to [child] while [open], easing out.
class ExpandBody extends StatelessWidget {
  const ExpandBody({super.key, required this.open, required this.child});

  final bool open;
  final Widget child;

  @override
  Widget build(BuildContext context) => ClipRect(
    child: AnimatedSize(
      duration: _motion(context),
      curve: Curves.easeOutQuart,
      alignment: Alignment.topCenter,
      child: open ? child : const SizedBox(width: double.infinity),
    ),
  );
}

/// A plan card that starts collapsed to one header: name, status sticker,
/// what it holds and what happens next. Tapping the header shows [body]
/// (tiers or schedules, fee, actions).
class PlanCardShell extends ConsumerWidget {
  const PlanCardShell({
    super.key,
    required this.vault,
    required this.summary,
    required this.body,
    this.sticker,
    this.next,
    this.nextColor = DM.dust,
  });

  final VaultState vault;

  /// Holdings, in mono ("0.500 SOL · 250 USDC protected").
  final String summary;

  /// What happens next ("Tier 1 in 19d 23h"); null when nothing will.
  final String? next;
  final Color nextColor;
  final Widget? sticker;
  final Widget body;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = vault.address;
    final open = ref.watch(expandedPlansProvider.select((s) => s.contains(id)));
    final t = Theme.of(context).textTheme;
    final next = this.next;
    return DMCard(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ExpandToggle(
            key: ValueKey('plan-$id'),
            open: open,
            onTap: () => ref.read(expandedPlansProvider.notifier).toggle(id),
            padding: const EdgeInsets.fromLTRB(
              DMSpace.cardPadding,
              14,
              DMSpace.md,
              14,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              planName(vault),
                              style: t.titleMedium,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (sticker != null) ...[
                            const SizedBox(width: DMSpace.sm),
                            sticker!,
                          ],
                        ],
                      ),
                      const SizedBox(height: DMSpace.xxs),
                      Text(summary, style: DMType.data()),
                      if (next != null)
                        Text(next, style: DMType.data(color: nextColor)),
                    ],
                  ),
                ),
                const SizedBox(width: DMSpace.sm),
                CollapseChevron(open: open),
              ],
            ),
          ),
          ExpandBody(
            open: open,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                DMSpace.cardPadding,
                0,
                DMSpace.cardPadding,
                DMSpace.cardPadding,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Divider(height: 1),
                  const SizedBox(height: DMSpace.lg),
                  body,
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// "Released · 3": the fully released plans, collapsed under one header
/// at the bottom of the list.
class ReleasedSection extends ConsumerWidget {
  const ReleasedSection({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final open = ref.watch(
      expandedPlansProvider.select((s) => s.contains(releasedSectionId)),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ExpandToggle(
          key: const Key('released-section'),
          open: open,
          onTap: () => ref
              .read(expandedPlansProvider.notifier)
              .toggle(releasedSectionId),
          child: Row(
            children: [
              Expanded(
                child: Semantics(
                  header: true,
                  child: Text(
                    'Released · ${children.length}',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
              ),
              CollapseChevron(open: open),
              const SizedBox(width: DMSpace.md),
            ],
          ),
        ),
        ExpandBody(
          open: open,
          child: Padding(
            padding: const EdgeInsets.only(top: DMSpace.sm),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Every tier or installment has paid out. These plans can no '
                  'longer change; close one to take back what is left and '
                  'its account rent.',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                for (final c in children) ...[
                  const SizedBox(height: DMSpace.md),
                  c,
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}
