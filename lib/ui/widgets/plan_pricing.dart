import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../solana/deadman_api.dart';
import '../../state/plan_math.dart' show percentText;
import '../../state/protocol_fees.dart';
import '../../state/providers.dart';
import '../theme/tokens.dart';
import 'brand/dm_icon.dart';
import 'brand/surfaces.dart';

/// A plan card's fee row: the release fee its pending payouts pay.
class PlanFeeLine extends ConsumerWidget {
  const PlanFeeLine({super.key, required this.vault});

  final VaultState vault;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final fees = ref.watch(feesProvider).value;
    return Padding(
      padding: const EdgeInsets.only(top: DMSpace.md),
      child: Row(
        children: [
          const Icon(Icons.receipt_long_outlined, size: 16, color: DM.ash),
          const SizedBox(width: DMSpace.sm),
          Expanded(
            child: Text(
              planFeeText(vault, fees),
              style: DMType.data(size: 12.5, color: DM.dust),
            ),
          ),
        ],
      ),
    );
  }
}

/// The fee model, read from the on-chain schedule: a percentage only when
/// a payout runs, a lower rate for SKR payouts (part of it burned), and
/// free withdrawals. [compact] (the plans list) leaves out the details.
class FeeModelCard extends ConsumerWidget {
  const FeeModelCard({
    super.key,
    this.compact = false,
    this.margin = EdgeInsets.zero,
  });

  final bool compact;
  final EdgeInsetsGeometry margin;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final fees = ref.watch(feesProvider).value;
    final muted = DMType.outfit(size: 14, color: DM.dust, height: 1.4);
    return Padding(
      padding: margin,
      child: DMCard(
        padding: compact
            ? const EdgeInsets.fromLTRB(DMSpace.lg, DMSpace.md, DMSpace.lg, 14)
            : const EdgeInsets.all(DMSpace.cardPadding),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const IconTile(child: DMIcon(DMIcons.calendar)),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Fees',
                        style: DMType.outfit(size: 16, weight: FontWeight.w600),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        feeSummaryText(fees),
                        style: DMType.data(size: 12.5),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (!compact) ...[
              const SizedBox(height: DMSpace.md),
              const Divider(height: 1),
              const SizedBox(height: DMSpace.md),
              Text(
                'Charged only when a payout runs or a vesting installment is '
                'released, out of that payout. Withdrawing, closing, '
                'cancelling and revoking are free.',
                style: muted,
              ),
              if (fees != null && fees.skrMint != null) ...[
                const SizedBox(height: DMSpace.xxs),
                Text(_skrNote(fees), style: muted),
              ],
            ],
          ],
        ),
      ),
    );
  }

  static String _skrNote(FeeSchedule fees) {
    final rate = percentText(fees.feeBpsSkr / 10000);
    final burn = fees.skrBurnBps > 0
        ? ', and ${percentText(fees.skrBurnBps / 10000)} of that fee is '
              'burned'
        : '';
    return 'Payouts in SKR pay $rate on every rail$burn.';
  }
}
