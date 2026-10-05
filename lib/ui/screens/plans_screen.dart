import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../solana/deadman_api.dart';
import '../../state/plan_math.dart';
import '../../state/providers.dart';
import '../widgets/brand/brand.dart';
import '../widgets/plan_pricing.dart';
import 'plans/legacy_plans_card.dart';
import 'plans/plan_actions.dart';
import 'plans/plan_card_shell.dart';
import 'plans/release_plan_card.dart';
import 'plans/vesting_plan_card.dart';

/// Opens the Plans screen over the tabs; Back returns to Pulse.
void openPlans(BuildContext context) => Navigator.push(
  context,
  MaterialPageRoute<void>(builder: (_) => const PlansScreen()),
);

/// Every release and vesting plan, with its tiers and the owner's actions.
/// Opened from the release-plans button on Pulse.
class PlansScreen extends ConsumerStatefulWidget {
  const PlansScreen({super.key});

  @override
  ConsumerState<PlansScreen> createState() => _PlansScreenState();
}

class _PlansScreenState extends ConsumerState<PlansScreen> {
  late final Timer _tick;
  int _now = nowSecs();

  @override
  void initState() {
    super.initState();
    // Tier countdowns are local; Pulse below keeps re-reading the chain.
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _now = nowSecs());
    });
  }

  @override
  void dispose() {
    _tick.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final vaults = ref.watch(vaultsProvider);
    final web = ref.watch(isWebProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Release plans'),
        titleSpacing: 0,
        actions: [
          // No pull-to-refresh with a mouse.
          if (web)
            IconButton(
              tooltip: 'Refresh',
              onPressed: () => refreshPlans(ref),
              icon: const Icon(Icons.refresh),
            ),
          const SizedBox(width: DMSpace.sm),
        ],
        bottom: const PreferredSize(
          preferredSize: Size.fromHeight(1),
          child: Divider(height: 1, thickness: 1, color: DM.line),
        ),
      ),
      body: vaults.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(DMSpace.xxl),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '$e',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: DMSpace.md),
                TextButton(
                  onPressed: () => ref.invalidate(vaultsProvider),
                  child: const Text('Retry'),
                ),
              ],
            ),
          ),
        ),
        data: (plans) => RefreshIndicator(
          onRefresh: () async => refreshPlans(ref),
          child: _PlanList(plans: plans, now: _now),
        ),
      ),
    );
  }
}

class _PlanList extends ConsumerWidget {
  const _PlanList({required this.plans, required this.now});

  final List<VaultState> plans;
  final int now;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final guard = ref.watch(guardAddressProvider);
    // On the web a check-in is wallet-signed, so guard coverage is moot.
    final web = ref.watch(isWebProvider);
    final cover = guard.hasValue && !web
        ? PlanCoverage.of(plans, guard.value, now)
        : null;
    final active = [
      for (final v in plans)
        if (!planReleased(v)) v,
    ];
    final released = [
      for (final v in plans)
        if (planReleased(v)) v,
    ];
    final switches = switchPlans(active);
    final vestings = [
      for (final v in active)
        if (v.isVesting) v,
    ];
    Widget card(VaultState v) => v.isVesting
        ? VestingPlanCard(key: ValueKey(v.address), vault: v, now: now)
        : ReleasePlanCard(
            key: ValueKey(v.address),
            vault: v,
            now: now,
            otherGuard: cover?.otherGuard.contains(v) ?? false,
          );
    const gap = SizedBox(height: DMSpace.md);

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(
        DMSpace.gutter,
        DMSpace.lg,
        DMSpace.gutter,
        DMSpace.xxxl,
      ),
      children: [
        const LegacyPlansCard(margin: EdgeInsets.only(bottom: DMSpace.xl)),
        FilledButton.icon(
          key: const Key('new-plan'),
          onPressed: () => chooseNewPlan(context),
          icon: const DMIcon(DMIcons.plus),
          label: const Text('New plan'),
        ),
        const SizedBox(height: DMSpace.xl),
        if (plans.isEmpty) const _NoPlans(),
        for (final v in switches) ...[card(v), gap],
        if (vestings.isNotEmpty) ...[
          if (switches.isNotEmpty) const SizedBox(height: DMSpace.lg),
          const SectionHeader(title: 'Vesting plans'),
          Text(
            'Release on their own schedule; check-ins do not affect them. '
            'Panic lockdown still covers them.',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: DMSpace.lg),
        ],
        for (final v in vestings) ...[card(v), gap],
        const MonthlyPlanCard(
          compact: true,
          margin: EdgeInsets.only(top: DMSpace.md),
        ),
        if (released.isNotEmpty) ...[
          const SizedBox(height: DMSpace.xxl),
          ReleasedSection(children: [for (final v in released) card(v)]),
        ],
      ],
    );
  }
}

/// Every plan closed while the screen was open, or none yet. The New plan
/// button sits above it.
class _NoPlans extends StatelessWidget {
  const _NoPlans();

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: DMSpace.xxl),
      child: Column(
        children: [
          const DMIcon(DMIcons.heartbeat, size: 48, color: DM.ash),
          const SizedBox(height: DMSpace.xl),
          Text('No plans yet', style: t.titleLarge),
          const SizedBox(height: DMSpace.sm),
          Text(
            'A release plan pays out in tiers if you stop checking in. A '
            'vesting plan pays out in installments on a schedule.',
            textAlign: TextAlign.center,
            style: t.bodyMedium,
          ),
        ],
      ),
    );
  }
}
