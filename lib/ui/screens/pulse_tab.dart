import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config.dart';
import '../../solana/deadman_api.dart';
import '../../state/actions.dart';
import '../../state/assets.dart';
import '../../state/plan_math.dart';
import '../../state/providers.dart';
import '../../state/subscription.dart';
import '../../state/vesting.dart';
import '../format.dart';
import '../rules_format.dart';
import '../theme.dart';
import '../widgets/amount_dialog.dart';
import '../widgets/feedback.dart';
import '../widgets/plan_pricing.dart';
import '../widgets/pulse_ring.dart';
import '../widgets/vesting_progress.dart';
import 'rules_editor.dart';
import 'vesting_editor.dart';

class PulseTab extends ConsumerStatefulWidget {
  const PulseTab({super.key});

  @override
  ConsumerState<PulseTab> createState() => _PulseTabState();
}

class _PulseTabState extends ConsumerState<PulseTab> {
  late final Timer _tick;
  late final AppLifecycleListener _lifecycle;
  int _now = nowSecs();
  bool _foreground = true;

  @override
  void initState() {
    super.initState();
    // The countdown is local; the chain is re-read once a minute, and only
    // while the app is visible, to stay under public RPC rate limits.
    _tick = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!_foreground) return;
      setState(() => _now = nowSecs());
      if (t.tick % 60 == 0) ref.invalidate(vaultsProvider);
    });
    _lifecycle = AppLifecycleListener(
      onResume: () => _foreground = true,
      onPause: () => _foreground = false,
    );
  }

  @override
  void dispose() {
    _tick.cancel();
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final vaults = ref.watch(vaultsProvider);
    return SafeArea(
      child: vaults.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => _Retry(
          message: '$e',
          onRetry: () => ref.invalidate(vaultsProvider),
        ),
        data: (list) => Column(
          children: [
            const _LegacyPlansCard(),
            Expanded(
              child: list.isEmpty
                  ? const _ArmIntro()
                  : RefreshIndicator(
                      onRefresh: () async {
                        ref.invalidate(vaultsProvider);
                        ref.invalidate(planUsdcProvider);
                        ref.invalidate(planTokenBalancesProvider);
                        ref.invalidate(accountSubscriptionProvider);
                      },
                      child: _Dashboard(plans: list, now: _now),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

void openEditor(BuildContext context, {VaultState? vault}) => Navigator.push(
  context,
  MaterialPageRoute<void>(builder: (_) => RulesEditorPage(vault: vault)),
);

void openVestingEditor(BuildContext context) => Navigator.push(
  context,
  MaterialPageRoute<void>(builder: (_) => const VestingEditorPage()),
);

/// "New plan": inheritance (dead man's switch) or vesting.
Future<void> chooseNewPlan(BuildContext context) async {
  final kind = await showModalBottomSheet<PlanKind>(
    context: context,
    backgroundColor: DmColors.surface,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('New plan', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            for (final (kind, icon, color, title, blurb) in [
              (
                PlanKind.inheritance,
                Icons.monitor_heart_outlined,
                DmColors.alive,
                'Inheritance',
                'Release when I go silent. Tiers pay out if you stop checking in.',
              ),
              (
                PlanKind.vesting,
                Icons.stacked_line_chart,
                DmColors.plus,
                'Vesting',
                'Release gradually over time, with an optional cliff. No check-ins.',
              ),
            ])
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Card(
                  color: DmColors.raised,
                  child: ListTile(
                    contentPadding: const EdgeInsets.fromLTRB(16, 6, 12, 6),
                    leading: Icon(icon, color: color, size: 28),
                    title: Text(title),
                    subtitle: Text(
                      blurb,
                      style: const TextStyle(color: DmColors.muted),
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.pop(context, kind),
                  ),
                ),
              ),
          ],
        ),
      ),
    ),
  );
  if (kind == null || !context.mounted) return;
  kind == PlanKind.vesting ? openVestingEditor(context) : openEditor(context);
}

/// One check-in covers every active plan, so the ring follows the most
/// urgent one.
class _Dashboard extends ConsumerWidget {
  const _Dashboard({required this.plans, required this.now});

  final List<VaultState> plans;
  final int now;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    final duress = ref.watch(sessionProvider.select((s) => s.duress));
    final guard = ref.watch(guardAddressProvider);
    // On the web "I'm alive" is wallet-signed, so guard coverage is moot.
    final web = ref.watch(isWebProvider);
    // "I'm alive" covers inheritance plans only; vesting runs on its own.
    final switches = switchPlans(plans);
    final vestings = [
      for (final v in plans)
        if (v.isVesting) v,
    ];
    // Plans with a pending tier; skipped tiers only await their claim.
    final active = activeSwitchPlans(plans);
    final locked = plans.any((v) => v.isLocked(now)) && !duress;
    final cover = guard.hasValue && !web
        ? PlanCoverage.of(plans, guard.value, now)
        : null;

    final urgent = active.isEmpty
        ? null
        : active.reduce((a, b) => a.nextRuleDue! <= b.nextRuleDue! ? a : b);
    final next = urgent?.nextRuleDue;
    final inGrace = urgent != null && now > urgent.pulseDue;
    final firing = next != null && now > next;

    final color = urgent == null
        ? DmColors.muted
        : firing
        ? DmColors.danger
        : inGrace
        ? DmColors.warn
        : DmColors.alive;
    final (big, label, progress) = urgent == null && switches.isEmpty
        ? ('Off', 'no inheritance plan to check in', 0.0)
        : urgent == null
        ? (
            'Done',
            switches.every((v) => v.completed)
                ? 'every plan released'
                : 'no tier pending; reserved shares await claim',
            0.0,
          )
        : firing
        ? (span(now - next), 'tier due, releasing', 0.0)
        : inGrace
        ? (
            span(next! - now),
            'until next tier',
            (next - now) / (next - urgent.pulseDue),
          )
        : (
            span(urgent.pulseDue - now),
            'until next check-in',
            (urgent.pulseDue - now) / urgent.intervalSecs,
          );

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
      children: [
        Row(
          children: [
            Text('Pulse', style: t.headlineMedium),
            const Spacer(),
            if (locked) const _Chip(text: 'LOCKED', color: DmColors.warn),
            // No pull-to-refresh with a mouse.
            if (web)
              IconButton(
                tooltip: 'Refresh',
                onPressed: () {
                  ref.invalidate(vaultsProvider);
                  ref.invalidate(planUsdcProvider);
                  ref.invalidate(planTokenBalancesProvider);
                  ref.invalidate(accountSubscriptionProvider);
                },
                icon: const Icon(Icons.refresh),
              ),
          ],
        ),
        const SizedBox(height: 8),
        const MonthlyPlanCard(
          compact: true,
          margin: EdgeInsets.only(bottom: 4),
        ),
        const SizedBox(height: 12),
        Center(
          child: PulseRing(
            progress: progress,
            color: color,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  big,
                  style: t.displayLarge?.copyWith(fontSize: 38, color: color),
                ),
                const SizedBox(height: 4),
                Text(label, style: const TextStyle(color: DmColors.muted)),
                if (urgent != null && active.length > 1) ...[
                  const SizedBox(height: 2),
                  Text(
                    urgent.label,
                    style: const TextStyle(color: DmColors.muted, fontSize: 12),
                  ),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 24),
        _PulseButton(
          color: color,
          activePlans: active.length,
          hasSwitch: switches.isNotEmpty,
          wallet: web,
        ),
        if (web && active.isNotEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text(
              'On the web you check in with your wallet. Reminders and one-tap '
              'check-ins are in the Android app.',
              textAlign: TextAlign.center,
              style: TextStyle(color: DmColors.muted, fontSize: 12),
            ),
          ),
        if (cover != null && cover.otherGuard.isNotEmpty) ...[
          const SizedBox(height: 12),
          _OtherGuardBanner(plans: cover.otherGuard),
        ],
        if (switches.isNotEmpty) ...[
          const SizedBox(height: 16),
          _StreakCard(plans: active.isEmpty ? switches : active),
        ],
        const SizedBox(height: 18),
        Row(
          children: [
            Text(
              switches.isEmpty ? 'Vesting plans' : 'Release plans',
              style: t.titleLarge,
            ),
            const Spacer(),
            TextButton.icon(
              onPressed: () => chooseNewPlan(context),
              icon: const Icon(Icons.add),
              label: const Text('New plan'),
            ),
          ],
        ),
        const SizedBox(height: 6),
        for (final v in switches) ...[
          _PlanCard(
            vault: v,
            now: now,
            otherGuard: cover?.otherGuard.contains(v) ?? false,
          ),
          const SizedBox(height: 12),
        ],
        if (switches.isNotEmpty && vestings.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text('Vesting plans', style: t.titleLarge),
          const SizedBox(height: 4),
          const Text(
            'Release on their own schedule; check-ins do not affect them. Panic lockdown still covers them.',
            style: TextStyle(color: DmColors.muted, fontSize: 12, height: 1.35),
          ),
          const SizedBox(height: 10),
        ],
        for (final v in vestings) ...[
          VestingPlanCard(vault: v, now: now),
          const SizedBox(height: 12),
        ],
      ],
    );
  }
}

class _PulseButton extends ConsumerStatefulWidget {
  const _PulseButton({
    required this.color,
    required this.activePlans,
    required this.hasSwitch,
    this.wallet = false,
  });

  final Color color;
  final int activePlans;

  /// Check in with the owner's wallet (web) instead of the guard key.
  final bool wallet;

  /// The owner has at least one inheritance plan.
  final bool hasSwitch;

  @override
  ConsumerState<_PulseButton> createState() => _PulseButtonState();
}

class _PulseButtonState extends ConsumerState<_PulseButton> {
  bool _busy = false;

  Future<void> _pulse() async {
    if (widget.wallet) return _pulseWithWallet();
    setState(() => _busy = true);
    PlanCoverage? cover;
    final ok = await runGuarded(
      context,
      () async => cover = await ref.read(actionsProvider).pulse(),
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok && cover != null) {
      toast(context, cover!.reportText(pulsed: true), error: !cover!.complete);
    }
  }

  Future<void> _pulseWithWallet() async {
    setState(() => _busy = true);
    List<VaultState>? done;
    await runGuarded(
      context,
      () async => done = await ref.read(actionsProvider).pulseWithWallet(),
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (done != null) {
      toast(
        context,
        done!.length == 1
            ? 'Pulse recorded on ${planName(done!.single)}.'
            : 'Pulse recorded on ${done!.length} plans.',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final closed = widget.activePlans == 0;
    return FilledButton.icon(
      style: FilledButton.styleFrom(
        backgroundColor: widget.color,
        minimumSize: const Size.fromHeight(64),
      ),
      onPressed: _busy || closed ? null : _pulse,
      icon: _busy
          ? const SizedBox.square(
              dimension: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(
              widget.wallet
                  ? Icons.account_balance_wallet_outlined
                  : Icons.fingerprint,
              size: 28,
            ),
      label: Text(
        !widget.hasSwitch
            ? 'No plan to check in'
            : closed
            ? 'All plans released'
            : "I'm alive",
        style: const TextStyle(fontSize: 18),
      ),
    );
  }
}

class _StreakCard extends StatelessWidget {
  const _StreakCard({required this.plans});

  final List<VaultState> plans;

  @override
  Widget build(BuildContext context) {
    final streak = plans.map((v) => v.streak).fold(0, (a, b) => a > b ? a : b);
    final best = plans
        .map((v) => v.bestStreak)
        .fold(0, (a, b) => a > b ? a : b);
    Widget stat(String value, String label) => Expanded(
      child: Column(
        children: [
          Text(value, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 2),
          Text(
            label,
            style: const TextStyle(color: DmColors.muted, fontSize: 12),
          ),
        ],
      ),
    );
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 8),
        child: Row(
          children: [
            const Padding(
              padding: EdgeInsets.only(left: 10),
              child: Icon(
                Icons.local_fire_department,
                color: DmColors.warn,
                size: 30,
              ),
            ),
            stat('$streak', 'day streak'),
            stat('$best', 'best'),
            stat('${plans.length}', plans.length == 1 ? 'plan' : 'plans'),
          ],
        ),
      ),
    );
  }
}

/// Plans this phone's guard key can't check in (e.g. after "Forget this
/// device"): they would release while the owner is alive.
class _OtherGuardBanner extends ConsumerStatefulWidget {
  const _OtherGuardBanner({required this.plans});

  final List<VaultState> plans;

  @override
  ConsumerState<_OtherGuardBanner> createState() => _OtherGuardBannerState();
}

class _OtherGuardBannerState extends ConsumerState<_OtherGuardBanner> {
  bool _busy = false;

  Future<void> _move() async {
    setState(() => _busy = true);
    await runGuarded(
      context,
      ref.read(actionsProvider).rotateGuard,
      success: 'Guard moved to this phone',
    );
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final n = widget.plans.length;
    return Card(
      color: DmColors.warn.withValues(alpha: 0.12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 12, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${n == 1 ? '1 plan is' : '$n plans are'} guarded by another device '
              '(${widget.plans.map(planName).join(', ')}). "I\'m alive" can\'t check '
              '${n == 1 ? 'it' : 'them'} in from this phone.',
              style: const TextStyle(color: DmColors.warn, height: 1.35),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: _busy ? null : _move,
                child: const Text('Move guard to this phone'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PlanCard extends ConsumerWidget {
  const _PlanCard({
    required this.vault,
    required this.now,
    required this.otherGuard,
  });

  final VaultState vault;
  final int now;

  /// Guarded by a key that isn't this phone's.
  final bool otherGuard;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    final actions = ref.read(actionsProvider);
    final earn = ref.watch(earnProvider);
    final duress = ref.watch(sessionProvider.select((s) => s.duress));
    final released = vault.rules.where((r) => r.executed).length;
    final id = vault.planId;
    final usdc = ref.watch(planUsdcProvider(vault.address)).value;
    final unfunded = unfundedAssets(
      vault,
      ref
          .watch(planTokenBalancesProvider)
          .whenOrNull(data: (b) => b[vault.address] ?? const <String, int>{}),
    );

    Future<void> run(
      String title,
      Future<void> Function(int) action,
      String done,
    ) async {
      final lamports = await askAmount(context, title);
      if (lamports == null || !context.mounted) return;
      await runGuarded(context, () => action(lamports), success: done);
    }

    final small = OutlinedButton.styleFrom(minimumSize: const Size(0, 42));
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 14, 8, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    vault.label.isEmpty ? 'Plan ${id + 1}' : vault.label,
                    style: t.titleLarge,
                  ),
                ),
                if (vault.completed)
                  const _Chip(text: 'RELEASED', color: DmColors.muted)
                else if (released > 0)
                  _Chip(
                    text: '$released/${vault.rules.length} RELEASED',
                    color: DmColors.warn,
                  ),
                TextButton(
                  onPressed: () => openEditor(context, vault: vault),
                  child: Text(vault.completed ? 'Start again' : 'Edit'),
                ),
              ],
            ),
            Text(
              '${sol(vault.withdrawableLamports)} SOL'
              '${usdc == null ? '' : ' · ${amountText(usdc, AppConfig.usdcMint)}'} protected'
              '${vault.completed ? '' : ' · check in every ${span(vault.intervalSecs)}'}',
              style: const TextStyle(color: DmColors.muted),
            ),
            for (final mint in unfunded)
              Padding(
                padding: const EdgeInsets.only(top: 8, right: 10),
                child: Wrap(
                  spacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    _Chip(
                      text: 'No ${assetSymbol(mint)} in this plan',
                      color: DmColors.warn,
                    ),
                    TextButton(
                      onPressed: () => depositToPlan(
                        context,
                        ref,
                        id,
                        asset: assetInfo(mint),
                      ),
                      child: Text('Deposit ${assetSymbol(mint)}'),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 10),
            for (final (i, r) in vault.rules.indexed)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Row(
                  children: [
                    Icon(
                      r.executed
                          ? Icons.check_circle
                          : r.skipped
                          ? Icons.savings_outlined
                          : Icons.schedule,
                      size: 18,
                      color: r.executed
                          ? DmColors.muted
                          : r.skipped
                          ? DmColors.warn
                          : r.rail.color,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('${amountLabel(r)} → ${short(r.beneficiary)}'),
                          const SizedBox(height: 2),
                          Text(
                            r.executed
                                ? '${doneLabel(r)} ${ago(r.executedAt, now)}'
                                : r.skipped
                                ? skippedLabel(r)
                                : 'After ${span(r.afterSecs)} silent · '
                                      '${vault.ruleDueAt(i) > now ? 'in ${span(vault.ruleDueAt(i) - now)}' : 'due now'}',
                            style: const TextStyle(
                              color: DmColors.muted,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: RailBadge(r.rail),
                    ),
                  ],
                ),
              ),
            if (vault.guardian != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Row(
                  children: [
                    const Icon(
                      Icons.shield_outlined,
                      size: 18,
                      color: DmColors.plus,
                    ),
                    const SizedBox(width: 10),
                    Text('Guardian ${short(vault.guardian!)}'),
                  ],
                ),
              ),
            if (otherGuard)
              const Padding(
                padding: EdgeInsets.only(top: 6),
                child: Text(
                  'Guarded by another device',
                  style: TextStyle(color: DmColors.warn),
                ),
              ),
            // Every web check-in is already wallet-signed.
            if (needsWalletCheckIn(vault, now) && !ref.watch(isWebProvider))
              _WalletCheckIn(vault: vault, now: now),
            if (vault.isLocked(now) && !duress)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  'Locked down for ${span(vault.lockedUntil - now)}',
                  style: const TextStyle(color: DmColors.warn),
                ),
              ),
            PlanFeeLine(vault: vault, now: now),
            const SizedBox(height: 10),
            Padding(
              padding: const EdgeInsets.only(right: 10),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton(
                    style: small,
                    onPressed: () => depositToPlan(context, ref, id),
                    child: const Text('Deposit'),
                  ),
                  OutlinedButton(
                    style: small,
                    onPressed: () => withdrawFromPlan(context, ref, vault, {
                      null: vault.withdrawableLamports,
                      AppConfig.usdcMint: ?usdc,
                    }),
                    child: const Text('Withdraw'),
                  ),
                  OutlinedButton.icon(
                    style: small.copyWith(
                      foregroundColor: const WidgetStatePropertyAll(
                        DmColors.alive,
                      ),
                    ),
                    onPressed: earn.available
                        ? () => run(
                            'Earn with SOL',
                            (l) => actions.earn(id, l),
                            'Earning in this plan',
                          )
                        : null,
                    icon: const Icon(Icons.trending_up, size: 18),
                    label: Text(earn.available ? 'Earn' : 'Earn · mainnet'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Guard-key check-ins stop a year after the owner's last wallet action,
/// or once a tier has released since then.
class _WalletCheckIn extends ConsumerStatefulWidget {
  const _WalletCheckIn({required this.vault, required this.now});

  final VaultState vault;
  final int now;

  @override
  ConsumerState<_WalletCheckIn> createState() => _WalletCheckInState();
}

class _WalletCheckInState extends ConsumerState<_WalletCheckIn> {
  bool _busy = false;

  Future<void> _confirm() async {
    setState(() => _busy = true);
    await runGuarded(
      context,
      () => ref.read(actionsProvider).pulseByOwner([widget.vault.planId]),
      success: 'Checked in with your wallet on ${planName(widget.vault)}',
    );
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final v = widget.vault;
    final stopped = !v.guardCanPulse(widget.now);
    return Container(
      margin: const EdgeInsets.only(top: 8, right: 10),
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 4),
      decoration: BoxDecoration(
        color: DmColors.warn.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            stopped
                ? "This phone can no longer check in for this plan. Confirm with your wallet, or the next tier releases on schedule."
                : 'This phone can check in for this plan for ${span(v.guardWindowEnd - widget.now)} more. '
                      'Confirm with your wallet to extend it by a year.',
            style: const TextStyle(color: DmColors.warn, height: 1.35),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: _busy ? null : _confirm,
              icon: const Icon(Icons.account_balance_wallet_outlined, size: 18),
              label: const Text('Confirm with wallet'),
            ),
          ),
        ],
      ),
    );
  }
}

/// Plans an upgrade left in an older layout: the app cannot show them, but
/// the owner can take their SOL back.
class _LegacyPlansCard extends ConsumerStatefulWidget {
  const _LegacyPlansCard();

  @override
  ConsumerState<_LegacyPlansCard> createState() => _LegacyPlansCardState();
}

class _LegacyPlansCardState extends ConsumerState<_LegacyPlansCard> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final ids = ref.watch(legacyPlansProvider).value ?? const [];
    if (ids.isEmpty) return const SizedBox.shrink();
    final n = ids.length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Card(
        color: DmColors.raised,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.history, color: DmColors.warn),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      n == 1
                          ? '1 plan from an older version'
                          : '$n plans from an older version',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              const Text(
                'An upgrade changed the plan format, so these plans no longer '
                'run. Recover them to close them and return all their SOL to '
                'your wallet, then create new plans.',
                style: TextStyle(color: DmColors.muted, height: 1.4),
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

class _ArmIntro extends ConsumerWidget {
  const _ArmIntro();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    final fees = ref.watch(feesProvider).value;
    final terms = ref.watch(subscriptionTermsProvider).value;
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text('Arm your switch', style: t.headlineMedium),
        const SizedBox(height: 10),
        Text(
          'Build a release plan: who receives what, after how long without a check-in, '
          'and how it gets there: a plain Solana transfer, privately through Cloak, or as shielded Zcash. '
          'Create as many plans as you like; one check-in keeps them all alive.',
          style: t.bodyMedium?.copyWith(color: DmColors.muted, height: 1.45),
        ),
        const SizedBox(height: 22),
        for (final r in Rail.values)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Card(
              child: ListTile(
                leading: Icon(r.icon, color: r.color),
                title: Text(r.label),
                subtitle: Text(r.blurb),
              ),
            ),
          ),
        const SizedBox(height: 14),
        FilledButton(
          onPressed: () => openEditor(context),
          child: const Text('Build release plan'),
        ),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          onPressed: () => openVestingEditor(context),
          icon: const Icon(Icons.stacked_line_chart, color: DmColors.plus),
          label: const Text('Or set up vesting: release gradually over time'),
        ),
        const SizedBox(height: 10),
        Text(
          '${fees == null ? 'Deadman only charges when a tier releases funds.' : 'Deadman only charges when a tier releases funds: '
                    '${percentText(fees.feeBpsPublic / 10000)} on Solana transfers, ${percentText(fees.feeBpsPrivate / 10000)} on private rails.'}'
          '${terms == null ? '' : ' Or pay a flat ${amountText(terms.pricePerPeriod, terms.mint)} '
                    '${terms.monthly ? 'a month' : 'per ${span(terms.periodSecs)}'} for all your plans instead '
                    '(${terms.minPeriods} ${periodWord(terms, terms.minPeriods)} minimum).'}',
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: DmColors.muted,
            fontSize: 12,
            height: 1.4,
          ),
        ),
      ],
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.14),
      borderRadius: BorderRadius.circular(99),
    ),
    child: Text(
      text,
      style: TextStyle(
        color: color,
        fontWeight: FontWeight.w700,
        fontSize: 12,
        letterSpacing: 1,
      ),
    ),
  );
}

class _Retry extends StatelessWidget {
  const _Retry({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.cloud_off, color: DmColors.muted, size: 36),
          const SizedBox(height: 12),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(color: DmColors.muted),
          ),
          const SizedBox(height: 12),
          TextButton(onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
    ),
  );
}

Future<int?> askAmount(BuildContext context, String title) {
  final controller = TextEditingController();
  return showDialog<int>(
    context: context,
    builder: (context) => AlertDialog(
      backgroundColor: DmColors.surface,
      title: Text(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: const InputDecoration(
          suffixText: 'SOL',
          labelText: 'Amount',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, parseSol(controller.text)),
          child: const Text('Confirm'),
        ),
      ],
    ),
  );
}

/// Deposits SOL or USDC from the wallet into plan [planId]; only [asset]
/// when given.
Future<void> depositToPlan(
  BuildContext context,
  WidgetRef ref,
  int planId, {
  AssetInfo? asset,
}) async {
  final wallet = <String?, int>{
    null: ?ref.read(walletBalanceProvider).value,
    AppConfig.usdcMint: ?ref.read(walletUsdcProvider).value,
  };
  final mint = asset?.mint;
  if (mint != null && !wallet.containsKey(mint)) {
    try {
      wallet[mint] = await ref.read(walletTokenProvider(mint).future);
    } catch (_) {
      // The hint is optional; the deposit itself reports real failures.
    }
    if (!context.mounted) return;
  }
  final pick = await askAssetAmount(
    context,
    asset == null ? 'Deposit' : 'Deposit ${asset.symbol}',
    assets: asset == null ? const [solAsset, usdcAsset] : [asset],
    available: wallet,
    availableLabel: 'in your wallet',
  );
  if (pick == null || !context.mounted) return;
  final actions = ref.read(actionsProvider);
  await runGuarded(
    context,
    () => pick.mint == null
        ? actions.deposit(planId, pick.amount)
        : actions.depositToken(planId, pick.mint!, pick.amount),
    success: 'Deposited ${amountText(pick.amount, pick.mint)}',
  );
}

/// Withdraws up to [available] (base units per mint; for vesting plans
/// only what is not committed to beneficiaries).
Future<void> withdrawFromPlan(
  BuildContext context,
  WidgetRef ref,
  VaultState vault,
  Map<String?, int> available,
) async {
  final pick = await askAssetAmount(
    context,
    'Withdraw',
    available: available,
    availableLabel: vault.isVesting ? 'not committed' : 'withdrawable',
    capped: true,
  );
  if (pick == null || !context.mounted) return;
  final actions = ref.read(actionsProvider);
  await runGuarded(
    context,
    () => pick.mint == null
        ? actions.withdraw(vault.planId, pick.amount)
        : actions.withdrawToken(vault.planId, pick.mint!, pick.amount),
    success: 'Withdrew ${amountText(pick.amount, pick.mint)}',
  );
}

/// A vesting plan: per-schedule progress, committed funds, and owner
/// actions. Not part of "I'm alive"; panic lockdown still freezes it.
class VestingPlanCard extends ConsumerStatefulWidget {
  const VestingPlanCard({super.key, required this.vault, required this.now});

  final VaultState vault;
  final int now;

  @override
  ConsumerState<VestingPlanCard> createState() => _VestingPlanCardState();
}

class _VestingPlanCardState extends ConsumerState<VestingPlanCard> {
  bool _busy = false;

  Future<void> _run(Future<void> Function() action, String success) async {
    setState(() => _busy = true);
    await runGuarded(context, action, success: success);
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _revoke() async {
    final v = widget.vault;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: DmColors.surface,
        title: const Text('Revoke vesting?'),
        content: Text(
          'Vesting on ${planName(v)} stops now for every schedule. What has vested so far '
          'stays claimable by each beneficiary; the rest becomes yours to withdraw. '
          'This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: DmColors.danger),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Revoke'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await _run(
      () => ref.read(actionsProvider).revokeVesting(v.planId),
      'Vesting revoked; vested amounts stay claimable',
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final v = widget.vault;
    final now = widget.now;
    final duress = ref.watch(sessionProvider.select((s) => s.duress));
    final usdc = ref.watch(planUsdcProvider(v.address)).value;
    final mints = <String?>{for (final r in v.rules) r.mint};
    int? balanceOf(String? mint) => mint == null
        ? v.withdrawableLamports
        : mint == AppConfig.usdcMint
        ? usdc
        : null;
    final committed = [
      for (final m in mints)
        if (v.committed(m) > 0) amountText(v.committed(m), m),
    ];
    final shortBy = [
      for (final m in mints)
        if (balanceOf(m) case final bal? when shortfall(v, m, bal) > 0)
          amountText(shortfall(v, m, bal), m),
    ];
    final revoked = v.revokedAt != 0;
    final settled = vestingSettled(v);
    final small = OutlinedButton.styleFrom(minimumSize: const Size(0, 42));

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 14, 18, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text(planName(v), style: t.titleLarge)),
                if (revoked)
                  const _Chip(text: 'REVOKED', color: DmColors.warn)
                else if (settled)
                  const _Chip(text: 'PAID OUT', color: DmColors.muted)
                else
                  const _Chip(text: 'VESTING', color: DmColors.plus),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '${sol(v.withdrawableLamports)} SOL'
              '${usdc == null ? '' : ' · ${amountText(usdc, AppConfig.usdcMint)}'} in plan · '
              '${v.revocable ? 'revocable' : 'irrevocable'} · '
              '${now < v.startAt ? 'starts in ${span(v.startAt - now)}' : 'started ${ago(v.startAt, now)}'}',
              style: const TextStyle(color: DmColors.muted),
            ),
            if (committed.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                'Committed: ${committed.join(' · ')}',
                style: const TextStyle(color: DmColors.plus, fontSize: 13),
              ),
            ],
            if (shortBy.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'Underfunded by ${shortBy.join(' · ')}: deposit more or releases stop when the plan runs dry.',
                  style: const TextStyle(
                    color: DmColors.warn,
                    fontSize: 12,
                    height: 1.35,
                  ),
                ),
              ),
            for (final (i, r) in v.rules.indexed) ...[
              const Divider(height: 24, color: DmColors.line),
              Builder(
                builder: (context) {
                  final p = scheduleProgress(v, i, now);
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      VestingScheduleView(rule: r, progress: p, now: now),
                      if (p.claimable > 0)
                        Align(
                          alignment: Alignment.centerRight,
                          child: TextButton.icon(
                            onPressed: _busy
                                ? null
                                : () => _run(
                                    () => ref
                                        .read(actionsProvider)
                                        .releaseVested(v, i),
                                    'Released to ${short(r.beneficiary)}',
                                  ),
                            icon: const Icon(Icons.call_made, size: 18),
                            label: Text(
                              'Release ${amountText(p.claimable, r.mint)}',
                            ),
                          ),
                        ),
                    ],
                  );
                },
              ),
            ],
            if (v.isLocked(now) && !duress)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'Locked down for ${span(v.lockedUntil - now)}',
                  style: const TextStyle(color: DmColors.warn),
                ),
              ),
            PlanFeeLine(vault: v, now: now),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton(
                  style: small,
                  onPressed: _busy
                      ? null
                      : () => depositToPlan(context, ref, v.planId),
                  child: const Text('Deposit'),
                ),
                OutlinedButton(
                  style: small,
                  onPressed: _busy
                      ? null
                      : () => withdrawFromPlan(context, ref, v, {
                          null: uncommitted(v, null, v.withdrawableLamports),
                          if (usdc != null)
                            AppConfig.usdcMint: uncommitted(
                              v,
                              AppConfig.usdcMint,
                              usdc,
                            ),
                        }),
                  child: const Text('Withdraw'),
                ),
                if (v.revocable && !revoked)
                  OutlinedButton(
                    style: small.copyWith(
                      foregroundColor: const WidgetStatePropertyAll(
                        DmColors.danger,
                      ),
                    ),
                    onPressed: _busy ? null : _revoke,
                    child: const Text('Revoke'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
