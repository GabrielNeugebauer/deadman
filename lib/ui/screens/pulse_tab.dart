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
import '../widgets/amount_dialog.dart';
import '../widgets/brand/brand.dart';
import '../widgets/feedback.dart';
import '../widgets/plan_pricing.dart';
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
        data: (list) => list.isEmpty
            ? const _ArmIntro()
            : RefreshIndicator(
                onRefresh: () async => _refresh(ref),
                child: _Dashboard(plans: list, now: _now),
              ),
      ),
    );
  }
}

void _refresh(WidgetRef ref) {
  ref.invalidate(vaultsProvider);
  ref.invalidate(planUsdcProvider);
  ref.invalidate(planTokenBalancesProvider);
  ref.invalidate(accountSubscriptionProvider);
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
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          DMSpace.gutter,
          0,
          DMSpace.gutter,
          DMSpace.gutter,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('New plan', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: DMSpace.lg),
            DMListGroup(
              children: [
                for (final (kind, icon, title, blurb) in [
                  (
                    PlanKind.inheritance,
                    Icons.monitor_heart_outlined,
                    'Inheritance',
                    'Release when I go silent. Tiers pay out if you stop checking in.',
                  ),
                  (
                    PlanKind.vesting,
                    Icons.stacked_line_chart,
                    'Vesting',
                    'Release in installments over time, with an optional cliff. No check-ins.',
                  ),
                ])
                  DMListRow(
                    leading: IconTile(icon: icon),
                    title: title,
                    subtitle: blurb,
                    monoSubtitle: false,
                    trailing: const Icon(Icons.chevron_right, color: DM.mist),
                    onTap: () => Navigator.pop(context, kind),
                  ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
  if (kind == null || !context.mounted) return;
  kind == PlanKind.vesting ? openVestingEditor(context) : openEditor(context);
}

/// Index of [v]'s pending tier that comes due first, or null.
int? _nextTier(VaultState v) {
  int? next;
  for (var i = 0; i < v.rules.length; i++) {
    if (v.rules[i].settled) continue;
    if (next == null || v.ruleDueAt(i) < v.ruleDueAt(next)) next = i;
  }
  return next;
}

/// What the ring says: status, countdown, captions and how full it is.
typedef _Readout = ({
  DMStatus status,
  String chip,
  String big,
  String caption,
  double progress,
});

/// One check-in covers every active plan, so the ring follows the most
/// urgent one.
class _Dashboard extends ConsumerWidget {
  const _Dashboard({required this.plans, required this.now});

  final List<VaultState> plans;
  final int now;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final duress = ref.watch(sessionProvider.select((s) => s.duress));
    final guard = ref.watch(guardAddressProvider);
    // On the web a check-in is wallet-signed, so guard coverage is moot.
    final web = ref.watch(isWebProvider);
    // A check-in covers inheritance plans only; vesting runs on its own.
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
    final tier = urgent == null ? null : _nextTier(urgent);

    final _Readout ring;
    if (urgent == null) {
      final allReleased = switches.every((v) => v.completed);
      ring = switches.isEmpty
          ? (
              status: DMStatus.released,
              chip: 'NOT ARMED',
              big: 'Off',
              caption: 'no inheritance plan to check in',
              progress: 0.0,
            )
          : (
              status: DMStatus.released,
              chip: allReleased ? 'ALL RELEASED' : 'NOTHING PENDING',
              big: 'Done',
              caption: allReleased
                  ? 'every plan released'
                  : 'no tier pending; reserved shares await claim',
              progress: 0.0,
            );
    } else if (firing) {
      ring = (
        status: DMStatus.due,
        chip: 'TIER DUE',
        big: span(now - next),
        caption: tier == null
            ? 'tier due, releasing'
            : 'past due, releasing to '
                  '${short(urgent.rules[tier].beneficiary)}',
        progress: 0.0,
      );
    } else if (inGrace) {
      ring = (
        status: DMStatus.attention,
        chip: 'CHECK-IN OVERDUE',
        big: span(next! - now),
        caption: tier == null
            ? 'until next tier'
            : 'until tier ${tier + 1} releases',
        progress: (next - now) / (next - urgent.pulseDue),
      );
    } else {
      final left = (urgent.pulseDue - now) / urgent.intervalSecs;
      final soon = left <= 0.25;
      ring = (
        status: soon ? DMStatus.attention : DMStatus.onTrack,
        chip: soon ? 'CHECK IN SOON' : 'ON TRACK',
        big: span(urgent.pulseDue - now),
        caption: 'until next check-in',
        progress: left,
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(
        DMSpace.gutter,
        DMSpace.md,
        DMSpace.gutter,
        DMSpace.xxxl,
      ),
      children: [
        PageHeader(
          title: 'Pulse',
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (locked) ...[
                const StatusChip(DMStatus.locked),
                const SizedBox(width: DMSpace.sm),
              ],
              // No pull-to-refresh with a mouse.
              if (web)
                IconButton(
                  tooltip: 'Refresh',
                  onPressed: () => _refresh(ref),
                  icon: const Icon(Icons.refresh),
                ),
              const DeadmanMark(size: 30),
            ],
          ),
        ),
        const _LegacyPlansCard(),
        const SizedBox(height: DMSpace.xl),
        Center(
          child: LayoutBuilder(
            builder: (context, box) => PulseRing(
              progress: ring.progress,
              status: ring.status,
              size: box.maxWidth < 300 ? box.maxWidth * 0.8 : 240,
              child: PulseReadout(
                status: ring.status,
                statusLabel: ring.chip,
                countdown: ring.big,
                countdownKey: const Key('pulse-countdown'),
                caption: ring.caption,
                detail: urgent != null && active.length > 1
                    ? planName(urgent)
                    : null,
              ),
            ),
          ),
        ),
        const SizedBox(height: DMSpace.xxl),
        _PulseButton(
          activePlans: active.length,
          hasSwitch: switches.isNotEmpty,
          firing: firing,
          wallet: web,
        ),
        if (web && active.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: DMSpace.sm),
            child: Text(
              'On the web you check in with your wallet. Reminders and one-tap '
              'check-ins are in the Android app.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        if (cover != null && cover.otherGuard.isNotEmpty) ...[
          const SizedBox(height: DMSpace.md),
          _OtherGuardBanner(plans: cover.otherGuard),
        ],
        if (switches.isNotEmpty) ...[
          const SizedBox(height: DMSpace.md),
          _StreakTiles(plans: active.isEmpty ? switches : active),
        ],
        const SizedBox(height: DMSpace.xxl),
        SectionHeader(
          title: switches.isEmpty ? 'Vesting plans' : 'Release plans',
          actionLabel: 'New plan',
          actionKey: const Key('new-plan'),
          onAction: () => chooseNewPlan(context),
        ),
        const SizedBox(height: DMSpace.sm),
        for (final v in switches) ...[
          _PlanCard(
            vault: v,
            now: now,
            otherGuard: cover?.otherGuard.contains(v) ?? false,
          ),
          const SizedBox(height: DMSpace.md),
        ],
        if (switches.isNotEmpty && vestings.isNotEmpty) ...[
          const SizedBox(height: DMSpace.md),
          const SectionHeader(title: 'Vesting plans'),
          Text(
            'Release on their own schedule; check-ins do not affect them. '
            'Panic lockdown still covers them.',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: DMSpace.md),
        ],
        for (final v in vestings) ...[
          VestingPlanCard(vault: v, now: now),
          const SizedBox(height: DMSpace.md),
        ],
        const MonthlyPlanCard(
          compact: true,
          margin: EdgeInsets.only(top: DMSpace.md),
        ),
      ],
    );
  }
}

class _PulseButton extends ConsumerStatefulWidget {
  const _PulseButton({
    required this.activePlans,
    required this.hasSwitch,
    this.firing = false,
    this.wallet = false,
  });

  final int activePlans;

  /// Check in with the owner's wallet (web) instead of the guard key.
  final bool wallet;

  /// The owner has at least one inheritance plan.
  final bool hasSwitch;

  /// A tier is due; checking in now stops it.
  final bool firing;

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
      key: const Key('check-in'),
      style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
      onPressed: _busy || closed ? null : _pulse,
      icon: _busy
          ? const SizedBox.square(
              dimension: 20,
              child: CircularProgressIndicator(strokeWidth: 2, color: DM.mist),
            )
          : Icon(
              widget.wallet
                  ? Icons.account_balance_wallet_outlined
                  : Icons.fingerprint,
              size: 24,
            ),
      label: Text(
        !widget.hasSwitch
            ? 'No plan to check in'
            : closed
            ? 'All plans released'
            : widget.firing
            ? 'Check in to stop'
            : 'Check in',
      ),
    );
  }
}

class _StreakTiles extends StatelessWidget {
  const _StreakTiles({required this.plans});

  final List<VaultState> plans;

  @override
  Widget build(BuildContext context) {
    final streak = plans.map((v) => v.streak).fold(0, (a, b) => a > b ? a : b);
    final best = plans
        .map((v) => v.bestStreak)
        .fold(0, (a, b) => a > b ? a : b);
    return StatTiles(
      children: [
        StatTile(value: '$streak', label: 'Day streak'),
        StatTile(value: '$best', label: 'Best'),
        StatTile(
          value: '${plans.length}',
          label: plans.length == 1 ? 'Plan' : 'Plans',
        ),
      ],
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
    return DMCard(
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
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const IconTile(
                icon: Icons.phonelink_lock_outlined,
                tone: DM.attention,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(right: DMSpace.sm),
                  child: Text(
                    '${n == 1 ? '1 plan is' : '$n plans are'} guarded by '
                    'another device (${widget.plans.map(planName).join(', ')}). '
                    'Check in on this phone can\'t reach '
                    '${n == 1 ? 'it' : 'them'}.',
                    style: DMType.outfit(size: 15, height: 1.4),
                  ),
                ),
              ),
            ],
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
    );
  }
}

/// Status of pending tier [index] of [v]: due once its time has come,
/// attention while the owner is past the check-in, else on track.
DMStatus _tierStatus(VaultState v, int index, int now) =>
    now >= v.ruleDueAt(index)
    ? DMStatus.due
    : now > v.pulseDue
    ? DMStatus.attention
    : DMStatus.onTrack;

/// The plan card's header chip: only when something is happening.
StatusChip? _planChip(VaultState v, int now) {
  if (v.completed) return const StatusChip(DMStatus.released);
  final next = v.nextRuleDue;
  if (next != null && now > next) {
    return const StatusChip(DMStatus.due, label: 'Due now');
  }
  if (next != null && now > v.pulseDue) {
    return StatusChip(DMStatus.attention, label: 'Tier in ${span(next - now)}');
  }
  final released = v.rules.where((r) => r.executed).length;
  if (released > 0) {
    return StatusChip(
      DMStatus.released,
      label: '$released/${v.rules.length} released',
    );
  }
  return null;
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
    final id = vault.planId;
    final usdc = ref.watch(planUsdcProvider(vault.address)).value;
    final unfunded = unfundedAssets(
      vault,
      ref
          .watch(planTokenBalancesProvider)
          .whenOrNull(data: (b) => b[vault.address] ?? const <String, int>{}),
    );
    final chip = _planChip(vault, now);
    final rails = {for (final r in vault.rules) r.rail};

    Future<void> run(
      String title,
      Future<void> Function(int) action,
      String done,
    ) async {
      final lamports = await askAmount(context, title);
      if (lamports == null || !context.mounted) return;
      await runGuarded(context, () => action(lamports), success: done);
    }

    const button = Size.fromHeight(48);
    return DMCard(
      padding: const EdgeInsets.fromLTRB(
        DMSpace.cardPadding,
        DMSpace.sm,
        DMSpace.cardPadding,
        DMSpace.cardPadding,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  planName(vault),
                  style: t.titleLarge,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (chip != null) ...[const SizedBox(width: DMSpace.sm), chip],
              Transform.translate(
                offset: const Offset(DMSpace.md, 0),
                child: TextButton(
                  onPressed: () => openEditor(context, vault: vault),
                  child: Text(vault.completed ? 'Start again' : 'Edit'),
                ),
              ),
            ],
          ),
          Text(
            '${sol(vault.withdrawableLamports)} SOL'
            '${usdc == null ? '' : ' · ${amountText(usdc, AppConfig.usdcMint)}'} protected',
            style: DMType.data(),
          ),
          if (!vault.completed)
            Text(
              'check in every ${span(vault.intervalSecs)}',
              style: DMType.data(),
            ),
          for (final mint in unfunded)
            Padding(
              padding: const EdgeInsets.only(top: DMSpace.sm),
              child: Wrap(
                spacing: DMSpace.sm,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  StatusChip(
                    DMStatus.attention,
                    label: 'No ${assetSymbol(mint)} in this plan',
                    dense: true,
                  ),
                  TextButton(
                    onPressed: () =>
                        depositToPlan(context, ref, id, asset: assetInfo(mint)),
                    child: Text('Deposit ${assetSymbol(mint)}'),
                  ),
                ],
              ),
            ),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: DMSpace.lg),
            child: Divider(height: 1),
          ),
          for (final (i, r) in vault.rules.indexed)
            _TierRow(
              icon: r.executed
                  ? Icons.check
                  : r.skipped
                  ? Icons.savings_outlined
                  : Icons.schedule,
              iconColor: r.executed || r.skipped
                  ? DM.sub
                  : _tierStatus(vault, i, now).color,
              title: '${amountLabel(r)} → ${short(r.beneficiary)}',
              detail: r.executed
                  ? '${doneLabel(r)} ${ago(r.executedAt, now)}'
                  : r.skipped
                  ? skippedLabel(r)
                  : 'After ${span(r.afterSecs)} silent',
              chip: r.executed
                  ? const StatusChip(DMStatus.released, dense: true)
                  : r.skipped
                  ? const StatusChip(
                      DMStatus.released,
                      label: 'Skipped',
                      dense: true,
                    )
                  : StatusChip(
                      _tierStatus(vault, i, now),
                      label: vault.ruleDueAt(i) > now
                          ? 'In ${span(vault.ruleDueAt(i) - now)}'
                          : 'Due now',
                      dense: true,
                    ),
            ),
          Padding(
            padding: const EdgeInsets.only(top: DMSpace.xxs),
            child: Wrap(
              spacing: DMSpace.sm,
              runSpacing: DMSpace.sm,
              children: [
                for (final rail in rails)
                  DMTag(label: rail.label, icon: rail.icon),
                if (otherGuard)
                  const StatusChip(
                    DMStatus.attention,
                    label: 'Guarded by another device',
                  ),
              ],
            ),
          ),
          if (vault.guardian != null)
            Padding(
              padding: const EdgeInsets.only(top: DMSpace.md),
              child: Row(
                children: [
                  const Icon(Icons.shield_outlined, size: 16, color: DM.mist),
                  const SizedBox(width: DMSpace.sm),
                  Text(
                    'Guardian ${short(vault.guardian!)}',
                    style: DMType.data(),
                  ),
                ],
              ),
            ),
          // Every web check-in is already wallet-signed.
          if (needsWalletCheckIn(vault, now) && !ref.watch(isWebProvider))
            _WalletCheckIn(vault: vault, now: now),
          if (vault.isLocked(now) && !duress)
            _LockedLine(until: vault.lockedUntil, now: now),
          PlanFeeLine(vault: vault, now: now),
          const SizedBox(height: DMSpace.lg),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(minimumSize: button),
                  onPressed: () => depositToPlan(context, ref, id),
                  child: const Text('Deposit'),
                ),
              ),
              const SizedBox(width: DMSpace.md),
              Expanded(
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(minimumSize: button),
                  onPressed: () => withdrawFromPlan(context, ref, vault, {
                    null: vault.withdrawableLamports,
                    AppConfig.usdcMint: ?usdc,
                  }),
                  child: const Text('Withdraw'),
                ),
              ),
            ],
          ),
          const SizedBox(height: DMSpace.md),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              minimumSize: button,
              foregroundColor: DM.signal,
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
    );
  }
}

/// One tier on a plan card: icon tile, what goes where, when, and a chip.
class _TierRow extends StatelessWidget {
  const _TierRow({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.detail,
    required this.chip,
  });

  final IconData icon;
  final Color iconColor;
  final String title;
  final String detail;
  final Widget chip;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: DMSpace.lg),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox.square(
          dimension: 32,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: DM.raise,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, size: 17, color: iconColor),
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: DMType.outfit(size: 15.5, height: 1.3)),
              const SizedBox(height: 3),
              Text(detail, style: DMType.data(size: 12.5)),
              const SizedBox(height: DMSpace.sm),
              chip,
            ],
          ),
        ),
      ],
    ),
  );
}

/// "Locked down for 2d 3h", in the lockdown color. Hidden under duress by
/// the caller.
class _LockedLine extends StatelessWidget {
  const _LockedLine({required this.until, required this.now});

  final int until;
  final int now;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: DMSpace.md),
    child: Row(
      children: [
        const Icon(Icons.lock_outline, size: 16, color: DM.locked),
        const SizedBox(width: DMSpace.sm),
        Expanded(
          child: Text(
            'Locked down for ${span(until - now)}',
            style: DMType.data(color: DM.locked),
          ),
        ),
      ],
    ),
  );
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
    return Padding(
      padding: const EdgeInsets.only(top: DMSpace.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Divider(height: 1),
          const SizedBox(height: DMSpace.lg),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.only(top: 2),
                child: Icon(Icons.update, size: 18, color: DM.attention),
              ),
              const SizedBox(width: DMSpace.md),
              Expanded(
                child: Text(
                  stopped
                      ? "This phone can no longer check in for this plan. Confirm with your wallet, or the next tier releases on schedule."
                      : 'This phone can check in for this plan for ${span(v.guardWindowEnd - widget.now)} more. '
                            'Confirm with your wallet to extend it by a year.',
                  style: DMType.outfit(size: 14, height: 1.4),
                ),
              ),
            ],
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
    // Sits under the page title, inside the tab's gutter.
    return Padding(
      padding: const EdgeInsets.only(top: DMSpace.xl),
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
                const IconTile(icon: Icons.history, tone: DM.attention),
                const SizedBox(width: 14),
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
            const SizedBox(height: DMSpace.md),
            Padding(
              padding: const EdgeInsets.only(right: DMSpace.sm),
              child: Text(
                'An upgrade changed the plan format, so these plans no longer '
                'run. Recover them to close them and return all their SOL to '
                'your wallet, then create new plans.',
                style: Theme.of(context).textTheme.bodyMedium,
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

class _ArmIntro extends ConsumerWidget {
  const _ArmIntro();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final fees = ref.watch(feesProvider).value;
    final terms = ref.watch(subscriptionTermsProvider).value;
    String? fee(Rail r) => fees == null
        ? null
        : percentText(
            (r == Rail.solana ? fees.feeBpsPublic : fees.feeBpsPrivate) / 10000,
          );
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        DMSpace.gutter,
        DMSpace.md,
        DMSpace.gutter,
        DMSpace.xxxl,
      ),
      children: [
        const PageHeader(
          title: 'Arm your switch',
          subtitle:
              'Build a release plan: who receives what, after how long without '
              'a check-in, and how it gets there. Create as many plans as you '
              'like; one check-in keeps them all alive.',
          trailing: DeadmanMark(size: 30),
        ),
        const _LegacyPlansCard(),
        const SizedBox(height: DMSpace.xxl),
        DMListGroup(
          children: [
            for (final r in Rail.values)
              DMListRow(
                leading: IconTile(icon: r.icon),
                title: r.label,
                subtitle: r.blurb,
                trailing: switch (fee(r)) {
                  final f? => Text(f, style: DMType.data(color: DM.mist)),
                  null => null,
                },
              ),
          ],
        ),
        const SizedBox(height: DMSpace.xxl),
        FilledButton(
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
          onPressed: () => openEditor(context),
          child: const Text('Build release plan'),
        ),
        const SizedBox(height: DMSpace.md),
        OutlinedButton(
          style: OutlinedButton.styleFrom(
            minimumSize: const Size.fromHeight(48),
            padding: const EdgeInsets.symmetric(
              horizontal: DMSpace.lg,
              vertical: DMSpace.md,
            ),
          ),
          onPressed: () => openVestingEditor(context),
          child: const Text(
            'Or set up vesting: release in installments over time',
            textAlign: TextAlign.center,
          ),
        ),
        const SizedBox(height: DMSpace.xl),
        Text(
          terms == null
              ? 'No subscription. Deadman only charges when a tier releases '
                    'funds.'
              : 'Deadman only charges when a tier releases funds. Or pay a '
                    'flat ${amountText(terms.pricePerPeriod, terms.mint)} '
                    '${terms.monthly ? 'a month' : 'per ${span(terms.periodSecs)}'} '
                    'for all your plans instead (${terms.minPeriods} '
                    '${periodWord(terms, terms.minPeriods)} minimum).',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(height: 1.45),
        ),
      ],
    );
  }
}

class _Retry extends StatelessWidget {
  const _Retry({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(DMSpace.xxl),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.cloud_off, color: DM.mist, size: 32),
          const SizedBox(height: DMSpace.md),
          Text(
            message,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: DMSpace.md),
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
      title: Text(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        style: DMType.mono(size: 20),
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
        FilledButton(
          style: FilledButton.styleFrom(minimumSize: const Size(96, 44)),
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
/// actions. A check-in does not touch it; panic lockdown still freezes it.
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
            style: TextButton.styleFrom(foregroundColor: DM.due),
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
    const button = Size.fromHeight(48);

    return DMCard(
      padding: const EdgeInsets.all(DMSpace.cardPadding),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  planName(v),
                  style: t.titleLarge,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: DMSpace.sm),
              if (revoked)
                const StatusChip(DMStatus.attention, label: 'Revoked')
              else if (settled)
                const StatusChip(DMStatus.released, label: 'Paid out')
              else
                const StatusChip(DMStatus.onTrack, label: 'Vesting'),
            ],
          ),
          const SizedBox(height: DMSpace.sm),
          Text(
            '${sol(v.withdrawableLamports)} SOL'
            '${usdc == null ? '' : ' · ${amountText(usdc, AppConfig.usdcMint)}'} in plan · '
            '${v.revocable ? 'revocable' : 'irrevocable'} · '
            '${now < v.startAt ? 'starts in ${span(v.startAt - now)}' : 'started ${ago(v.startAt, now)}'}',
            style: DMType.data(),
          ),
          if (committed.isNotEmpty)
            Text(
              'Committed: ${committed.join(' · ')}',
              style: DMType.data(color: DM.bone),
            ),
          if (shortBy.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: DMSpace.md),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Padding(
                    padding: EdgeInsets.only(top: 2),
                    child: Icon(
                      Icons.warning_amber_rounded,
                      size: 18,
                      color: DM.attention,
                    ),
                  ),
                  const SizedBox(width: DMSpace.md),
                  Expanded(
                    child: Text(
                      'Underfunded by ${shortBy.join(' · ')}: deposit more or releases stop when the plan runs dry.',
                      style: DMType.outfit(size: 14, height: 1.4),
                    ),
                  ),
                ],
              ),
            ),
          for (final (i, r) in v.rules.indexed) ...[
            const Padding(
              padding: EdgeInsets.symmetric(vertical: DMSpace.lg),
              child: Divider(height: 1),
            ),
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
                        child: Transform.translate(
                          offset: const Offset(DMSpace.md, 0),
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
                      ),
                  ],
                );
              },
            ),
          ],
          if (v.isLocked(now) && !duress)
            _LockedLine(until: v.lockedUntil, now: now),
          PlanFeeLine(vault: v, now: now),
          const SizedBox(height: DMSpace.lg),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(minimumSize: button),
                  onPressed: _busy
                      ? null
                      : () => depositToPlan(context, ref, v.planId),
                  child: const Text('Deposit'),
                ),
              ),
              const SizedBox(width: DMSpace.md),
              Expanded(
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(minimumSize: button),
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
              ),
            ],
          ),
          if (v.revocable && !revoked) ...[
            const SizedBox(height: DMSpace.md),
            OutlinedButton(
              style: OutlinedButton.styleFrom(
                minimumSize: button,
                foregroundColor: DM.due,
              ),
              onPressed: _busy ? null : _revoke,
              child: const Text('Revoke'),
            ),
          ],
        ],
      ),
    );
  }
}
