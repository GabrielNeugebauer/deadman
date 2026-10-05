import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config.dart';
import '../../../solana/deadman_api.dart';
import '../../../state/actions.dart';
import '../../../state/assets.dart';
import '../../../state/plan_math.dart';
import '../../../state/providers.dart';
import '../../../state/vesting.dart';
import '../../format.dart';
import '../../widgets/brand/brand.dart';
import '../../widgets/feedback.dart';
import '../../widgets/plan_pricing.dart';
import '../../widgets/vesting_progress.dart';
import 'plan_actions.dart';
import 'plan_card_shell.dart';
import 'release_plan_card.dart';

/// What happens next on vesting plan [v]: its start, the next installment
/// or unlock, or that it finished.
(String, Color) vestingNext(VaultState v, int now) {
  if (planReleased(v)) {
    final last = v.rules.map((r) => r.executedAt).reduce(math.max);
    return ('Paid out ${ago(last, now)}', DM.ash);
  }
  final progress = [
    for (var i = 0; i < v.rules.length; i++) scheduleProgress(v, i, now),
  ];
  if (v.revokedAt != 0) {
    final owed = progress.any((p) => p.owed > 0);
    return (
      owed ? 'Revoked · vested amounts still to release' : 'Revoked',
      DM.bone,
    );
  }
  if (progress.any((p) => p.claimable > 0)) {
    return ('Ready to release', DM.pulse);
  }
  if (now < v.startAt) return ('Starts in ${span(v.startAt - now)}', DM.dust);
  (int, int, String?)? soonest;
  for (final (i, p) in progress.indexed) {
    final at = p.nextInstallmentAt;
    if (!p.installments || at == null || p.nextInstallmentAmount <= 0) {
      continue;
    }
    if (soonest == null || at < soonest.$1) {
      soonest = (at, p.nextInstallmentAmount, v.rules[i].mint);
    }
  }
  if (soonest case (final at, final amount, final mint)) {
    return (
      'Next installment ${amountText(amount, mint)} in ${span(at - now)}',
      DM.pulse,
    );
  }
  final pending = [
    for (final p in progress)
      if (!p.fullyVested) p,
  ];
  if (pending.isEmpty) return ('Fully vested', DM.dust);
  final cliff = pending.where((p) => now < p.cliffAt).map((p) => p.cliffAt);
  if (cliff.isNotEmpty) {
    return ('First unlock in ${span(cliff.reduce(math.min) - now)}', DM.dust);
  }
  final end = pending.map((p) => p.endAt).reduce(math.max);
  return ('Fully vested in ${span(end - now)}', DM.pulse);
}

/// A vesting plan, collapsed to its header until tapped: per-schedule
/// progress, committed funds, and owner actions. A check-in does not touch
/// it; panic lockdown still freezes it. A fully paid-out plan is read-only.
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

  /// Revokes after asking; what has vested stays the beneficiaries'.
  Future<void> _cancel() async {
    final v = widget.vault;
    final now = widget.now;
    if (v.isLocked(now) && !ref.read(sessionProvider).duress) {
      return explainLocked(context, v, now);
    }
    final owed = <String?, int>{};
    for (var i = 0; i < v.rules.length; i++) {
      final p = scheduleProgress(v, i, now);
      final unpaid = p.vested - p.released;
      if (unpaid > 0) {
        owed[v.rules[i].mint] = (owed[v.rules[i].mint] ?? 0) + unpaid;
      }
    }
    final vested = [
      for (final MapEntry(key: m, value: a) in owed.entries) amountText(a, m),
    ].join(' · ');
    final ok = await confirmPlanAction(
      context,
      title: 'Cancel ${planName(v)}?',
      body:
          'Vesting stops now for every schedule. '
          '${vested.isEmpty ? 'Nothing vested is waiting to be released, so the beneficiaries get nothing more.' : 'What has already vested ($vested) stays with the beneficiaries and can still be released to them.'} '
          'Everything else becomes yours to withdraw, and you can close the '
          "plan once nothing is owed. This can't be undone.",
      confirm: 'Cancel plan',
    );
    if (!ok || !mounted) return;
    await _run(
      () => ref.read(actionsProvider).revokeVesting(v.planId),
      'Vesting stopped; withdraw what is no longer owed',
    );
  }

  @override
  Widget build(BuildContext context) {
    final v = widget.vault;
    final now = widget.now;
    final duress = ref.watch(sessionProvider.select((s) => s.duress));
    final usdc = ref.watch(planUsdcProvider(v.address)).value;
    final released = planReleased(v);
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
    final held = <String, int>{AppConfig.usdcMint: ?usdc};
    final leftovers = holdingsText(v, held);
    final (next, nextColor) = vestingNext(v, now);
    const button = Size.fromHeight(48);

    void withdraw() => withdrawFromPlan(context, ref, v, {
      null: uncommitted(v, null, v.withdrawableLamports),
      if (usdc != null)
        AppConfig.usdcMint: uncommitted(v, AppConfig.usdcMint, usdc),
    });
    void close() =>
        closePlanFlow(context, ref, v, cancel: false, held: held, now: now);

    final List<Widget> footer;
    if (released) {
      footer = [
        if (leftovers.isNotEmpty) ...[
          const SizedBox(height: DMSpace.lg),
          OutlinedButton(
            style: OutlinedButton.styleFrom(minimumSize: button),
            onPressed: _busy ? null : withdraw,
            child: const Text('Withdraw leftovers'),
          ),
        ],
        const SizedBox(height: DMSpace.md),
        OutlinedButton(
          style: OutlinedButton.styleFrom(minimumSize: button),
          onPressed: _busy ? null : close,
          child: const Text('Close plan'),
        ),
      ];
    } else {
      footer = [
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
                onPressed: _busy ? null : withdraw,
                child: const Text('Withdraw'),
              ),
            ),
          ],
        ),
        if (revoked) ...[
          const SizedBox(height: DMSpace.md),
          if (committed.isEmpty)
            OutlinedButton(
              style: OutlinedButton.styleFrom(minimumSize: button),
              onPressed: _busy ? null : close,
              child: const Text('Close plan'),
            )
          else
            _Note(
              icon: DMIcons.lock,
              text:
                  'You can close this plan once the beneficiaries have been '
                  'paid what vested (${committed.join(' · ')} still owed).',
            ),
        ] else if (v.revocable) ...[
          const SizedBox(height: DMSpace.sm),
          CancelPlanButton(onPressed: _busy ? null : _cancel),
        ] else ...[
          const SizedBox(height: DMSpace.md),
          const _Note(
            icon: DMIcons.lock,
            text:
                "Irrevocable: this plan can't be cancelled. Every schedule "
                'keeps vesting to its beneficiary; you can still withdraw '
                'what is not committed.',
          ),
        ],
      ];
    }

    return PlanCardShell(
      vault: v,
      // Vesting has no check-in, so it never wears a skull mood; only a
      // finished plan gets the ghost.
      sticker: v.isLocked(now) && !duress
          ? const StatusSticker(DMStatus.locked)
          : revoked
          ? const Sticker('Revoked', color: DM.ash)
          : settled
          ? const StatusSticker(DMStatus.released, label: 'Paid out')
          : const Sticker('Vesting'),
      summary: released
          ? (leftovers.isEmpty ? 'Nothing left in the plan' : '$leftovers left')
          : '${sol(v.withdrawableLamports)} SOL'
                '${usdc == null ? '' : ' · ${amountText(usdc, AppConfig.usdcMint)}'}'
                ' in plan',
      next: next,
      nextColor: nextColor,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${v.revocable ? 'revocable' : 'irrevocable'} · '
            '${now < v.startAt ? 'starts in ${span(v.startAt - now)}' : 'started ${ago(v.startAt, now)}'}',
            style: DMType.data(),
          ),
          if (committed.isNotEmpty)
            Text(
              'Committed: ${committed.join(' · ')}',
              style: DMType.data(color: DM.bone),
            ),
          if (shortBy.isNotEmpty && !released)
            Padding(
              padding: const EdgeInsets.only(top: DMSpace.md),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Padding(
                    padding: EdgeInsets.only(top: 3),
                    child: DMIcon(DMIcons.warning, size: 12, color: DM.missed),
                  ),
                  const SizedBox(width: DMSpace.md),
                  Expanded(
                    child: Text(
                      'Underfunded by ${shortBy.join(' · ')}: deposit more '
                      'or releases stop when the plan runs dry.',
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
                    if (p.claimable > 0 && !released)
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
            LockedLine(until: v.lockedUntil, now: now),
          ...footer,
        ],
      ),
    );
  }
}

/// A pixel icon beside a muted line, under a plan's actions.
class _Note extends StatelessWidget {
  const _Note({required this.icon, required this.text});

  final DMIcons icon;
  final String text;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Padding(
        padding: const EdgeInsets.only(top: 3),
        child: DMIcon(icon, size: 12, color: DM.ash),
      ),
      const SizedBox(width: DMSpace.md),
      Expanded(
        child: Text(
          text,
          style: DMType.outfit(size: 14, color: DM.dust, height: 1.4),
        ),
      ),
    ],
  );
}
