import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../solana/deadman_api.dart';
import '../../state/actions.dart';
import '../../state/plan_math.dart';
import '../../state/providers.dart';
import '../format.dart';
import '../rules_format.dart';
import '../theme.dart';
import '../widgets/feedback.dart';
import '../widgets/pulse_ring.dart';
import 'rules_editor.dart';

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
                onRefresh: () async => ref.invalidate(vaultsProvider),
                child: _Dashboard(plans: list, now: _now),
              ),
      ),
    );
  }
}

void openEditor(BuildContext context, {VaultState? vault}) => Navigator.push(
  context,
  MaterialPageRoute<void>(builder: (_) => RulesEditorPage(vault: vault)),
);

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
    // Plans with a pending tier; skipped tiers only await their claim.
    final active = plans.where((v) => v.nextRuleDue != null).toList();
    final locked = plans.any((v) => v.isLocked(now)) && !duress;
    final cover = guard.hasValue
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
    final (big, label, progress) = urgent == null
        ? (
            'Done',
            plans.every((v) => v.completed)
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
          ],
        ),
        const SizedBox(height: 20),
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
        _PulseButton(color: color, activePlans: active.length),
        if (cover != null && cover.otherGuard.isNotEmpty) ...[
          const SizedBox(height: 12),
          _OtherGuardBanner(plans: cover.otherGuard),
        ],
        const SizedBox(height: 16),
        _StreakCard(plans: active.isEmpty ? plans : active),
        const SizedBox(height: 18),
        Row(
          children: [
            Text('Release plans', style: t.titleLarge),
            const Spacer(),
            TextButton.icon(
              onPressed: () => openEditor(context),
              icon: const Icon(Icons.add),
              label: const Text('New plan'),
            ),
          ],
        ),
        const SizedBox(height: 6),
        for (final v in plans) ...[
          _PlanCard(
            vault: v,
            now: now,
            otherGuard: cover?.otherGuard.contains(v) ?? false,
          ),
          const SizedBox(height: 12),
        ],
      ],
    );
  }
}

class _PulseButton extends ConsumerStatefulWidget {
  const _PulseButton({required this.color, required this.activePlans});

  final Color color;
  final int activePlans;

  @override
  ConsumerState<_PulseButton> createState() => _PulseButtonState();
}

class _PulseButtonState extends ConsumerState<_PulseButton> {
  bool _busy = false;

  Future<void> _pulse() async {
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
          : const Icon(Icons.fingerprint, size: 28),
      label: Text(
        closed ? 'All plans released' : "I'm alive",
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
              '${sol(vault.withdrawableLamports)} SOL protected'
              '${vault.completed ? '' : ' · check in every ${span(vault.intervalSecs)}'}',
              style: const TextStyle(color: DmColors.muted),
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
            if (needsWalletCheckIn(vault, now))
              _WalletCheckIn(vault: vault, now: now),
            if (vault.isLocked(now) && !duress)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  'Locked down for ${span(vault.lockedUntil - now)}',
                  style: const TextStyle(color: DmColors.warn),
                ),
              ),
            const SizedBox(height: 10),
            Padding(
              padding: const EdgeInsets.only(right: 10),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton(
                    style: small,
                    onPressed: () => run(
                      'Deposit SOL',
                      (l) => actions.deposit(id, l),
                      'Deposited',
                    ),
                    child: const Text('Deposit'),
                  ),
                  OutlinedButton(
                    style: small,
                    onPressed: () => run(
                      'Withdraw SOL',
                      (l) => actions.withdraw(id, l),
                      'Withdrawn',
                    ),
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

class _ArmIntro extends ConsumerWidget {
  const _ArmIntro();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    final fees = ref.watch(feesProvider).value;
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
        Text(
          fees == null
              ? 'No subscription. Deadman only charges when a tier releases funds.'
              : 'No subscription. Deadman only charges when a tier releases funds: '
                    '${fees.feeBpsPublic / 100}% on Solana transfers, ${fees.feeBpsPrivate / 100}% on private rails.',
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
