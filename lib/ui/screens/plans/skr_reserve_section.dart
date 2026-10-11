import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../solana/deadman_api.dart';
import '../../../state/actions.dart';
import '../../../state/assets.dart';
import '../../../state/plan_draft.dart' show moneyText;
import '../../../state/plan_math.dart' show percentText;
import '../../../state/prices.dart';
import '../../../state/providers.dart';
import '../../../state/skr_reserve.dart';
import '../../widgets/amount_dialog.dart';
import '../../widgets/brand/brand.dart';
import '../../widgets/feedback.dart';

/// How far [vault]'s SKR fee reserve goes: [need] is the SKR its remaining
/// payouts would take at today's prices (null = unknown).
String reserveCoverageText(VaultState vault, FeeSchedule fees, int? need) {
  final skr = fees.skrMint!;
  if (need == null) return "Couldn't price the remaining payouts right now.";
  if (need == 0) return 'No remaining payout needs it.';
  if (need <= vault.skrFeeReserve) {
    return 'Covers the remaining payouts (≈ ${moneyText(need, skr)} at '
        "today's prices).";
  }
  return "May not cover the remaining payouts: ≈ ${moneyText(need, skr)} at "
      "today's prices. Payouts it can't cover pay "
      '${percentText(fees.feeBpsPublic / 10000)} in their own asset.';
}

/// A plan card's SKR fee reserve: how much it holds, whether it covers the
/// remaining payouts, and Top up / Withdraw. A plan without one offers to
/// start paying fees in SKR. [tokens] are the plan's token balances (mint
/// -> base units), for the coverage estimate.
class SkrReserveSection extends ConsumerWidget {
  const SkrReserveSection({
    super.key,
    required this.vault,
    required this.tokens,
    this.released = false,
  });

  final VaultState vault;
  final Map<String, int>? tokens;

  /// Nothing left to pay: only withdrawing the reserve makes sense.
  final bool released;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final fees = ref.watch(feesProvider).value;
    final skr = fees?.skrMint;
    final reserve = vault.skrFeeReserve;
    if (fees == null || skr == null) return const SizedBox.shrink();
    final covered = vault.rules.any((r) => skrReserveCovers(fees, r.mint));
    if (reserve == 0 && (released || !covered)) return const SizedBox.shrink();
    final muted = DMType.outfit(size: 13.5, color: DM.dust, height: 1.4);
    final stale = reserve > 0 && vault.skrReserveMint != skr;

    Future<void> topUp() async {
      final wallet = await ref
          .read(walletTokenProvider(skr).future)
          .then<int?>((v) => v, onError: (Object _) => null);
      if (!context.mounted) return;
      final pick = await askAssetAmount(
        context,
        reserve == 0 ? 'Pay fees in SKR' : 'Top up SKR fee reserve',
        assets: [assetInfo(skr)],
        available: {skr: ?wallet},
        availableLabel: 'in your wallet',
        capped: true,
        note:
            'Each payout then pays its fee in SKR from this reserve, at '
            '${percentText(fees.feeBpsSkr / 10000)} instead of '
            '${percentText(fees.feeBpsPublic / 10000)}.',
      );
      if (pick == null || !context.mounted) return;
      await runGuarded(
        context,
        () =>
            ref.read(actionsProvider).fundSkrReserve(vault.planId, pick.amount),
        success: 'Added ${amountText(pick.amount, skr)} to the fee reserve',
      );
    }

    Future<void> withdraw() async {
      final mint = vault.skrReserveMint!;
      final pick = await askAssetAmount(
        context,
        'Withdraw SKR fee reserve',
        assets: [assetInfo(mint)],
        available: {mint: reserve},
        availableLabel: 'in the reserve',
        capped: true,
        note:
            'Free, like every withdrawal. Payouts the reserve no longer '
            'covers pay the normal fee in their own asset.',
      );
      if (pick == null || !context.mounted) return;
      await runGuarded(
        context,
        () => ref
            .read(actionsProvider)
            .withdrawSkrReserve(vault.planId, pick.amount),
        success: 'Withdrew ${amountText(pick.amount, mint)} from the reserve',
      );
    }

    if (reserve == 0) {
      return Padding(
        padding: const EdgeInsets.only(top: DMSpace.sm),
        child: Row(
          children: [
            const Icon(
              Icons.local_fire_department_outlined,
              size: 16,
              color: DM.ash,
            ),
            const SizedBox(width: DMSpace.sm),
            Expanded(
              child: Text(
                'Pay fees in SKR: ${percentText(fees.feeBpsSkr / 10000)} '
                'instead of ${percentText(fees.feeBpsPublic / 10000)}',
                style: DMType.data(size: 12.5, color: DM.dust),
              ),
            ),
            TextButton(onPressed: topUp, child: const Text('Add SKR')),
          ],
        ),
      );
    }

    final need = stale || released
        ? null
        : ref
              .watch(
                usdPricesProvider(priceKey(reservePricedAssets(vault, fees))),
              )
              .whenData((usd) => skrReserveNeed(vault, tokens, fees, usd));
    final (status, color) = stale
        ? (
            'This reserve is in an older SKR token and no longer pays fees. '
                'Withdraw it.',
            DM.missed,
          )
        : released
        ? ('Every payout has run: withdraw what is left.', DM.dust)
        : switch (need) {
            AsyncData(:final value) => (
              reserveCoverageText(vault, fees, value),
              value != null && value > reserve ? DM.missed : DM.dust,
            ),
            AsyncLoading() => ('Checking prices…', DM.dust),
            _ => (reserveCoverageText(vault, fees, null), DM.dust),
          };
    return Padding(
      padding: const EdgeInsets.only(top: DMSpace.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.local_fire_department_outlined,
                size: 16,
                color: DM.ash,
              ),
              const SizedBox(width: DMSpace.sm),
              Expanded(
                child: Text(
                  'SKR fee reserve: '
                  '${amountText(reserve, vault.skrReserveMint)}',
                  style: DMType.data(size: 12.5, color: DM.bone),
                ),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(left: 24, top: 2),
            child: Text(
              status,
              style: color == DM.dust ? muted : muted.copyWith(color: color),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(left: 12),
            child: Wrap(
              spacing: DMSpace.sm,
              children: [
                if (!stale && !released)
                  TextButton(onPressed: topUp, child: const Text('Top up')),
                TextButton(
                  onPressed: withdraw,
                  child: const Text('Withdraw reserve'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
