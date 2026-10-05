import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../solana/deadman_api.dart';
import '../../state/actions.dart';
import '../../state/assets.dart';
import '../../state/providers.dart';
import '../../state/subscription.dart';
import '../format.dart';
import '../theme/tokens.dart';
import 'brand/dm_icon.dart';
import 'brand/surfaces.dart';
import 'feedback.dart';

/// A plan card's fee row: the release fee, or 0% while the owner's
/// account-wide monthly plan covers this plan. Hidden while the monthly
/// plan is not offered and does not cover the plan.
class PlanFeeLine extends ConsumerWidget {
  const PlanFeeLine({super.key, required this.vault, required this.now});

  final VaultState vault;
  final int now;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final terms = ref.watch(subscriptionTermsProvider).value;
    final sub = ref.watch(accountSubscriptionProvider).value;
    final waived = feeWaivedFor(vault, sub, now);
    if (terms == null && !waived) return const SizedBox.shrink();
    final fees = ref.watch(feesProvider).value;
    return Padding(
      padding: const EdgeInsets.only(top: DMSpace.md),
      child: Row(
        children: [
          Icon(
            Icons.receipt_long_outlined,
            size: 16,
            color: waived ? DM.pulse : DM.ash,
          ),
          const SizedBox(width: DMSpace.sm),
          Expanded(
            child: Text(
              planFeeText(vault, sub, fees, now),
              style: DMType.data(size: 12.5, color: waived ? DM.bone : DM.dust),
            ),
          ),
        ],
      ),
    );
  }
}

/// How the monthly plan covers each kind of plan.
const subscriptionRulesText =
    'Inheritance: covers releases if your last check-in happened while '
    'subscribed. Vesting: fee-free while active.';

/// The owner's account-wide monthly plan: its status and a button to
/// subscribe or extend. [compact] (the Pulse dashboard) leaves out the
/// rules. Hidden, [margin] included, while the monthly plan is not
/// offered.
class MonthlyPlanCard extends ConsumerStatefulWidget {
  const MonthlyPlanCard({
    super.key,
    this.compact = false,
    this.margin = EdgeInsets.zero,
  });

  final bool compact;
  final EdgeInsetsGeometry margin;

  @override
  ConsumerState<MonthlyPlanCard> createState() => _MonthlyPlanCardState();
}

class _MonthlyPlanCardState extends ConsumerState<MonthlyPlanCard> {
  bool _busy = false;

  Future<void> _subscribe(
    SubscriptionTerms terms,
    AccountSubscription? sub,
  ) async {
    final periods = await showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => SubscribeSheet(terms: terms, sub: sub),
    );
    if (periods == null || !mounted) return;
    final until = terms.paidUntilAfter(sub, periods, nowSecs());
    setState(() => _busy = true);
    await runGuarded(
      context,
      () => ref.read(actionsProvider).subscribe(periods),
      success: 'Monthly plan paid until ${dateText(until)}',
    );
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final terms = ref.watch(subscriptionTermsProvider).value;
    final subState = ref.watch(accountSubscriptionProvider);
    if (terms == null || !subState.hasValue) return const SizedBox.shrink();
    final sub = subState.value;
    final now = nowSecs();
    final status = subscriptionStatus(sub, now);
    final active = status == SubscriptionStatus.active;
    final muted = DMType.outfit(size: 14, color: DM.dust, height: 1.4);
    final price =
        '${amountText(terms.pricePerPeriod, terms.mint)} '
        '${terms.monthly ? 'a month' : 'per ${span(terms.periodSecs)}'}';

    return Padding(
      padding: widget.margin,
      child: DMCard(
        padding: widget.compact
            ? const EdgeInsets.fromLTRB(DMSpace.lg, DMSpace.md, DMSpace.sm, 14)
            : const EdgeInsets.fromLTRB(
                DMSpace.cardPadding,
                DMSpace.lg,
                DMSpace.sm,
                DMSpace.cardPadding,
              ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                IconTile(
                  tone: active ? DM.pulse : null,
                  child: DMIcon(
                    DMIcons.calendar,
                    color: active ? DM.pulse : DM.bone,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: active
                      ? Text(
                          'Monthly plan · covers all your plans · paid '
                          'until ${dateText(sub!.paidUntil)}',
                          style: DMType.outfit(size: 15, height: 1.4),
                        )
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Monthly plan',
                              style: DMType.outfit(
                                size: 16,
                                weight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              status == SubscriptionStatus.lapsed
                                  ? 'Not subscribed · ended '
                                        '${dateText(sub!.paidUntil)}'
                                  : 'Not subscribed',
                              style: DMType.data(size: 12.5),
                            ),
                            Text(
                              '$price, no release fee on any plan',
                              style: DMType.data(size: 12.5),
                            ),
                          ],
                        ),
                ),
                TextButton(
                  onPressed: _busy ? null : () => _subscribe(terms, sub),
                  child: Text(active ? 'Extend' : 'Subscribe'),
                ),
              ],
            ),
            if (!widget.compact) ...[
              const SizedBox(height: DMSpace.md),
              const Divider(height: 1),
              const SizedBox(height: DMSpace.md),
              Padding(
                padding: const EdgeInsets.only(right: DMSpace.md),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'One subscription covers all your plans, present and '
                      'future.',
                      style: muted,
                    ),
                    const SizedBox(height: DMSpace.xxs),
                    Text(subscriptionRulesText, style: muted),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Picks how many periods of the account-wide monthly plan to prepay, for
/// an owner whose subscription is [sub]; pops with the count.
class SubscribeSheet extends ConsumerStatefulWidget {
  const SubscribeSheet({super.key, required this.terms, this.sub});

  final SubscriptionTerms terms;
  final AccountSubscription? sub;

  @override
  ConsumerState<SubscribeSheet> createState() => _SubscribeSheetState();
}

class _SubscribeSheetState extends ConsumerState<SubscribeSheet> {
  final int _now = nowSecs();
  late final List<int> _choices = subscriptionChoices(
    widget.terms,
    widget.sub,
    _now,
  );
  late int _periods = _choices.first;

  @override
  Widget build(BuildContext context) {
    final sub = widget.sub;
    final terms = widget.terms;
    final mint = terms.mint;
    final t = Theme.of(context).textTheme;
    final status = subscriptionStatus(sub, _now);
    final active = status == SubscriptionStatus.active;
    final min = terms.minPeriodsFor(sub, _now);
    final cost = terms.cost(_periods);
    final wallet = ref.watch(walletTokenProvider(mint)).value;
    final short = wallet != null && wallet < cost;
    final fees = ref.watch(feesProvider).value;
    final plans = ref.watch(vaultsProvider).value;
    final held = ref.watch(ownerPlanHoldingsProvider(mint)).value;
    final muted = DMType.outfit(size: 14, color: DM.dust, height: 1.4);
    String n(int p) => '$p ${periodWord(terms, p)}';

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              active ? 'Extend monthly plan' : 'Subscribe monthly',
              style: t.titleLarge,
            ),
            const SizedBox(height: DMSpace.sm),
            Text(
              '${amountText(terms.pricePerPeriod, mint)} / '
              '${terms.monthly ? 'month' : span(terms.periodSecs)}',
              style: DMType.stat(),
            ),
            const SizedBox(height: DMSpace.lg),
            Text(
              'One subscription covers all your plans, present and future.',
              style: muted,
            ),
            const SizedBox(height: DMSpace.sm),
            Text(subscriptionRulesText, style: muted),
            const SizedBox(height: DMSpace.sm),
            Text(
              active
                  ? 'Paid until ${dateText(sub!.paidUntil)}. Extend by any '
                        'number of ${periodWord(terms, 2)}.'
                  : '${status == SubscriptionStatus.none ? 'A new' : 'A lapsed'} '
                        'subscription starts with at least ${n(min)} paid at '
                        'once, so it cannot be bought for one '
                        '${periodWord(terms, 1)} just before a release to '
                        'skip the fee.',
              style: muted,
            ),
            const SizedBox(height: DMSpace.xl),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final p in _choices)
                  ChoiceChip(
                    label: Text(n(p)),
                    selected: _periods == p,
                    onSelected: (_) => setState(() => _periods = p),
                  ),
              ],
            ),
            const SizedBox(height: DMSpace.xl),
            const Divider(height: 1),
            const SizedBox(height: DMSpace.lg),
            Text(
              'Total ${amountText(cost, mint)} · paid until '
              '${dateText(terms.paidUntilAfter(sub, _periods, _now))}',
              style: DMType.mono(size: 14, weight: FontWeight.w500),
            ),
            const SizedBox(height: DMSpace.xxs),
            Text(
              'Your wallet: ${wallet == null ? '…' : amountText(wallet, mint)}',
              style: DMType.data(color: short ? DM.flatline : DM.dust),
            ),
            if (short)
              Padding(
                padding: const EdgeInsets.only(top: DMSpace.xxs),
                child: Text(
                  'Not enough ${assetSymbol(mint)} for ${n(_periods)}.',
                  style: DMType.outfit(size: 14, color: DM.flatline),
                ),
              ),
            if (fees != null && held != null && plans != null)
              ..._savings(plans, fees, held, cost, n(_periods), muted),
            const SizedBox(height: DMSpace.xxl),
            FilledButton(
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(56),
              ),
              onPressed: short ? null : () => Navigator.pop(context, _periods),
              child: Text('Pay ${amountText(cost, mint)}'),
            ),
          ],
        ),
      ),
    );
  }

  /// The percentage fee on what all of the owner's [plans] hold of the
  /// subscription token, against [cost]. SOL has no price here, so it is
  /// only mentioned.
  List<Widget> _savings(
    List<VaultState> plans,
    FeeSchedule fees,
    Map<String, int> held,
    int cost,
    String periods,
    TextStyle style,
  ) {
    if (plans.isEmpty) return const [];
    final mint = widget.terms.mint;
    final fee = plansReleaseFeeEstimate(plans, fees, mint, held);
    final solFee = plansReleaseFeeEstimate(plans, fees, null);
    final all = plans.length == 1 ? 'your plan' : 'all your plans';
    return [
      const SizedBox(height: DMSpace.md),
      Text(
        'At ${plansPendingFeeRates(plans, fees)}, releasing $all would cost '
        '~${amountText(fee, mint)}; $periods cost ${amountText(cost, mint)}.',
        style: style,
      ),
      if (solFee > 0)
        Text(
          'SOL has no price in the app, so this compares '
          '${assetSymbol(mint)} only. The SOL in $all would add '
          '~${amountText(solFee, null)} in fees.',
          style: style.copyWith(fontSize: 13, color: DM.ash),
        ),
    ];
  }
}
