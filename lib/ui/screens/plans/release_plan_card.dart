import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config.dart';
import '../../../solana/deadman_api.dart';
import '../../../state/actions.dart';
import '../../../state/assets.dart';
import '../../../state/plan_math.dart';
import '../../../state/providers.dart';
import '../../format.dart';
import '../../rules_format.dart';
import '../../widgets/brand/brand.dart';
import '../../widgets/feedback.dart';
import '../../widgets/plan_pricing.dart';
import 'plan_actions.dart';
import 'plan_card_shell.dart';

/// Status of pending tier [index] of [v]: due once its time has come,
/// else alive (counting down from the last check-in).
DMStatus tierStatus(VaultState v, int index, int now) =>
    now >= v.ruleDueAt(index) ? DMStatus.due : DMStatus.alive;

/// The plan card's header sticker: only when something is happening.
Widget? _planSticker(VaultState v, int now) {
  if (v.completed) return const StatusSticker(DMStatus.released);
  final next = v.nextReleaseAt;
  if (next != null && now > next) return const StatusSticker(DMStatus.due);
  final released = v.rules.where((r) => r.executed).length;
  if (released > 0) {
    // Part-way: the ghost is for a plan that has fully paid out.
    return StatusSticker(
      DMStatus.released,
      label: '$released/${v.rules.length} released',
      showSprite: false,
    );
  }
  return null;
}

/// What happens next on inheritance plan [v], in the status color: the
/// next tier's countdown, or when it finished releasing.
(String, Color) _nextEvent(VaultState v, int now) {
  if (planReleased(v)) {
    final last = v.rules.map((r) => r.executedAt).reduce(math.max);
    return ('All tiers released ${ago(last, now)}', DM.ash);
  }
  int? index;
  for (final (i, r) in v.rules.indexed) {
    if (r.settled) continue;
    if (index == null || v.ruleDueAt(i) < v.ruleDueAt(index)) index = i;
  }
  if (index == null) return ('A skipped tier awaits its claim', DM.dust);
  final status = tierStatus(v, index, now);
  final due = v.ruleDueAt(index);
  return status == DMStatus.due
      ? ('Tier ${index + 1} due now', status.color)
      : ('Tier ${index + 1} in ${span(due - now)}', status.color);
}

/// An inheritance plan on the Plans screen, collapsed to its header until
/// tapped: holdings, tiers in order, rails, guard notes and the owner's
/// actions. A fully released plan is read-only: its history, and a way to
/// take back what is left.
class ReleasePlanCard extends ConsumerWidget {
  const ReleasePlanCard({
    super.key,
    required this.vault,
    required this.now,
    this.otherGuard = false,
  });

  final VaultState vault;
  final int now;

  /// Guarded by a key that isn't this phone's.
  final bool otherGuard;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final actions = ref.read(actionsProvider);
    final earn = ref.watch(earnProvider);
    final duress = ref.watch(sessionProvider.select((s) => s.duress));
    final id = vault.planId;
    final released = planReleased(vault);
    final usdc = ref.watch(planUsdcProvider(vault.address)).value;
    final tokens = ref
        .watch(planTokenBalancesProvider)
        .whenOrNull(data: (b) => b[vault.address] ?? const <String, int>{});
    final held = <String, int>{...?tokens, AppConfig.usdcMint: ?usdc};
    final unfunded = released
        ? const <String?>[]
        : unfundedAssets(vault, tokens);
    final rails = {for (final r in vault.rules) r.rail};
    final (next, nextColor) = _nextEvent(vault, now);
    final leftovers = holdingsText(vault, held);

    Future<void> run(
      String title,
      Future<void> Function(int) action,
      String done,
    ) async {
      final lamports = await askAmount(context, title);
      if (lamports == null || !context.mounted) return;
      await runGuarded(context, () => action(lamports), success: done);
    }

    void withdraw() => withdrawFromPlan(context, ref, vault, {
      null: vault.withdrawableLamports,
      AppConfig.usdcMint: ?usdc,
    });

    const button = Size.fromHeight(48);
    final List<Widget> footer = released
        ? [
            if (leftovers.isNotEmpty) ...[
              const SizedBox(height: DMSpace.lg),
              OutlinedButton(
                style: OutlinedButton.styleFrom(minimumSize: button),
                onPressed: withdraw,
                child: const Text('Withdraw leftovers'),
              ),
            ],
            const SizedBox(height: DMSpace.md),
            OutlinedButton(
              style: OutlinedButton.styleFrom(minimumSize: button),
              onPressed: () => closePlanFlow(
                context,
                ref,
                vault,
                cancel: false,
                held: held,
                now: now,
              ),
              child: const Text('Close plan'),
            ),
          ]
        : [
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
                    onPressed: withdraw,
                    child: const Text('Withdraw'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: DMSpace.md),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(minimumSize: button),
                    onPressed: () => openEditor(context, vault: vault),
                    child: const Text('Edit'),
                  ),
                ),
                const SizedBox(width: DMSpace.md),
                Expanded(
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      minimumSize: button,
                      foregroundColor: DM.pulse,
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
                ),
              ],
            ),
            const SizedBox(height: DMSpace.sm),
            CancelPlanButton(
              onPressed: () => closePlanFlow(
                context,
                ref,
                vault,
                cancel: true,
                held: held,
                now: now,
              ),
            ),
          ];

    return PlanCardShell(
      vault: vault,
      // The lock outranks the tiers' state; under duress it stays hidden.
      sticker: vault.isLocked(now) && !duress
          ? const StatusSticker(DMStatus.locked)
          : _planSticker(vault, now),
      summary: released
          ? (leftovers.isEmpty ? 'Nothing left in the plan' : '$leftovers left')
          : '${sol(vault.withdrawableLamports)} SOL'
                '${usdc == null ? '' : ' · ${amountText(usdc, AppConfig.usdcMint)}'}'
                ' protected',
      next: next,
      nextColor: nextColor,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final mint in unfunded)
            Padding(
              padding: const EdgeInsets.only(bottom: DMSpace.lg),
              child: Row(
                children: [
                  const DMIcon(DMIcons.warning, size: 12, color: DM.missed),
                  const SizedBox(width: DMSpace.sm),
                  Expanded(
                    child: Text(
                      'No ${assetSymbol(mint)} in this plan',
                      style: DMType.outfit(size: 14, color: DM.missed),
                    ),
                  ),
                  TextButton(
                    onPressed: () =>
                        depositToPlan(context, ref, id, asset: assetInfo(mint)),
                    child: Text('Deposit ${assetSymbol(mint)}'),
                  ),
                ],
              ),
            ),
          for (final (i, r) in vault.rules.indexed)
            _TierRow(vault: vault, index: i, rule: r, now: now),
          Wrap(
            spacing: DMSpace.sm,
            runSpacing: DMSpace.sm,
            children: [
              for (final rail in rails)
                DMTag(label: rail.label, icon: rail.icon),
            ],
          ),
          if (otherGuard && !released)
            const _NoteLine(
              icon: Icons.phonelink_lock_outlined,
              color: DM.missed,
              text: 'Guarded by another device',
            ),
          if (vault.guardian != null && !released)
            _NoteLine(
              icon: Icons.shield_outlined,
              text: 'Guardian ${short(vault.guardian!)}',
              mono: true,
            ),
          // Every web check-in is already wallet-signed.
          if (!released &&
              needsWalletCheckIn(vault, now) &&
              !ref.watch(isWebProvider))
            _WalletCheckIn(vault: vault, now: now),
          if (vault.isLocked(now) && !duress)
            LockedLine(until: vault.lockedUntil, now: now),
          ...footer,
        ],
      ),
    );
  }
}

/// "Cancel plan": the danger action under a plan's other actions.
class CancelPlanButton extends StatelessWidget {
  const CancelPlanButton({super.key, required this.onPressed});

  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.centerLeft,
    child: TextButton.icon(
      style: TextButton.styleFrom(
        foregroundColor: DM.flatline,
        minimumSize: const Size(48, 48),
      ),
      onPressed: onPressed,
      icon: const DMIcon(DMIcons.warning),
      label: const Text('Cancel plan'),
    ),
  );
}

/// One tier: what goes where, after how long, and where it stands. A due
/// tier wears the tombstone; a pending one counts down in mono.
class _TierRow extends StatelessWidget {
  const _TierRow({
    required this.vault,
    required this.index,
    required this.rule,
    required this.now,
  });

  final VaultState vault;
  final int index;
  final RuleState rule;
  final int now;

  @override
  Widget build(BuildContext context) {
    final r = rule;
    final pending = !r.executed && !r.skipped;
    final status = pending ? tierStatus(vault, index, now) : DMStatus.released;
    final dueAt = vault.ruleDueAt(index);
    final Widget figure = status == DMStatus.due
        ? const PixelArt(PixelSprites.tombstone, size: 16, color: DM.flatline)
        : Icon(
            r.executed
                ? Icons.check
                : r.skipped
                ? Icons.savings_outlined
                : Icons.schedule,
            size: 17,
            color: pending ? status.color : DM.ash,
          );
    final Widget state = r.executed
        ? const StatusSticker(DMStatus.released, dense: true, showSprite: false)
        : r.skipped
        ? const StatusSticker(
            DMStatus.released,
            label: 'Skipped',
            dense: true,
            showSprite: false,
          )
        : status == DMStatus.due
        ? const StatusSticker(DMStatus.due, label: 'Due now', dense: true)
        : Text(
            'in ${span(dueAt - now)}',
            style: DMType.data(size: 12.5, color: status.color),
          );
    return Padding(
      padding: const EdgeInsets.only(bottom: DMSpace.lg),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          IconTile(size: 32, child: figure),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${amountLabel(r)} → ${short(r.beneficiary)}',
                  style: DMType.outfit(size: 15.5, height: 1.3),
                ),
                const SizedBox(height: 3),
                Text(
                  r.executed
                      ? '${doneLabel(r)} ${ago(r.executedAt, now)}'
                      : r.skipped
                      ? skippedLabel(r)
                      : '${span(r.afterSecs)} after last check-in',
                  style: DMType.data(size: 12.5),
                ),
                const SizedBox(height: DMSpace.xs),
                state,
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Small icon + one line under a plan's tiers.
class _NoteLine extends StatelessWidget {
  const _NoteLine({
    required this.icon,
    required this.text,
    this.color = DM.ash,
    this.mono = false,
  });

  final IconData icon;
  final String text;
  final Color color;
  final bool mono;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: DMSpace.md),
    child: Row(
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: DMSpace.sm),
        Expanded(
          child: Text(
            text,
            style: mono
                ? DMType.data()
                : DMType.outfit(
                    size: 14,
                    color: color == DM.ash ? DM.dust : color,
                  ),
          ),
        ),
      ],
    ),
  );
}

/// "Locked down for 2d 3h" beside the pixel lock. The caller hides it
/// under duress.
class LockedLine extends StatelessWidget {
  const LockedLine({super.key, required this.until, required this.now});

  final int until;
  final int now;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: DMSpace.md),
    child: Row(
      children: [
        const PixelArt(PixelSprites.lock, size: 14, color: DM.bone),
        const SizedBox(width: DMSpace.sm),
        Expanded(
          child: Text(
            'Locked down for ${span(until - now)}',
            style: DMType.data(color: DM.bone),
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
                child: Icon(Icons.update, size: 18, color: DM.missed),
              ),
              const SizedBox(width: DMSpace.md),
              Expanded(
                child: Text(
                  stopped
                      ? 'This phone can no longer check in for this plan. '
                            'Confirm with your wallet, or the next tier '
                            'releases on schedule.'
                      : 'This phone can check in for this plan for '
                            '${span(v.guardWindowEnd - widget.now)} more. '
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
              icon: const DMIcon(DMIcons.wallet),
              label: const Text('Confirm with wallet'),
            ),
          ),
        ],
      ),
    );
  }
}
