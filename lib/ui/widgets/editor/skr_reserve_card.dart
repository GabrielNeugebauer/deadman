import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../solana/deadman_api.dart';
import '../../../state/assets.dart';
import '../../../state/plan_draft.dart' show moneyText;
import '../../../state/plan_math.dart' show percentText;
import '../../../state/protocol_fees.dart';
import '../../../state/skr_reserve.dart';
import '../brand/brand.dart';
import 'plan_steps.dart';

/// The Fund step's "Pay fees in $SKR (1.5% instead of 2%)" option: a
/// switch and, when on, how much SKR goes into the plan's fee reserve. An
/// empty field means [suggested], sized from what goes into the plan.
class SkrReserveCard extends StatelessWidget {
  const SkrReserveCard({
    super.key,
    required this.fees,
    required this.on,
    required this.onToggle,
    required this.controller,
    required this.onChanged,
    required this.suggested,
    required this.wallet,
    this.errorText,
    this.fieldKey,
    this.noun = 'payout',
  });

  final FeeSchedule fees;
  final bool on;
  final ValueChanged<bool> onToggle;
  final TextEditingController controller;
  final VoidCallback onChanged;

  /// The suggested reserve; null inside while prices are missing.
  final AsyncValue<int?> suggested;

  /// SKR in the owner's wallet.
  final AsyncValue<int> wallet;
  final String? errorText;
  final Key? fieldKey;

  /// "payout" or "release".
  final String noun;

  String get _skr => fees.skrMint!;

  String _pct(int bps) => percentText(bps / 10000);

  String get _suggestion => switch (suggested) {
    AsyncData(value: final v?) when v > 0 =>
      'Suggested: ${moneyText(v, _skr)}, ${_pct(fees.feeBpsSkr)} of what '
          "goes into the plan at today's prices, plus "
          '${((skrReserveBuffer - 1) * 100).round()}% for price moves.',
    AsyncData(value: 0) =>
      'Put something in the plan above to get a suggested amount.',
    AsyncLoading() => 'Checking prices…',
    _ => "Couldn't read today's prices: enter an amount.",
  };

  @override
  Widget build(BuildContext context) {
    final muted = DMType.outfit(size: 14, color: DM.dust, height: 1.4);
    final burn = fees.skrBurnBps > 0
        ? ' ${_pct(fees.skrBurnBps)} of that SKR is burned, the rest goes to '
              'Deadman.'
        : '';
    final hint = suggested.value;
    return DMCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: on,
            onChanged: onToggle,
            title: Text(
              skrOptionTitle(fees),
              style: DMType.outfit(size: 16, weight: FontWeight.w600),
            ),
            subtitle: Padding(
              padding: const EdgeInsets.only(top: DMSpace.xxs),
              child: Text(
                'Each $noun pays its fee in SKR from a reserve kept in this '
                'plan, so every beneficiary receives the whole $noun.$burn',
                style: muted,
              ),
            ),
          ),
          if (on) ...[
            const SizedBox(height: DMSpace.md),
            LabeledField(
              label: 'SKR fee reserve',
              child: TextField(
                key: fieldKey,
                controller: controller,
                onChanged: (_) => onChanged(),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
                ],
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                style: DMType.mono(size: 18, weight: FontWeight.w500),
                decoration: InputDecoration(
                  hintText: hint == null || hint <= 0
                      ? '0'
                      : amountInput(hint, _skr),
                  hintStyle: DMType.mono(size: 18, color: DM.ash),
                  suffixText: assetSymbol(_skr),
                  suffixStyle: DMType.mono(size: 14, color: DM.dust),
                  helperText: switch (wallet) {
                    AsyncData(:final value) =>
                      'In your wallet: ${moneyText(value, _skr)}',
                    AsyncError() => "Couldn't read your wallet balance.",
                    _ => 'Checking your wallet…',
                  },
                  helperStyle: DMType.mono(size: 12, color: DM.dust),
                  errorText: errorText,
                  errorMaxLines: 3,
                ),
              ),
            ),
            const SizedBox(height: DMSpace.sm),
            Text(_suggestion, style: muted),
            const SizedBox(height: DMSpace.sm),
            Text(
              "If the reserve can't cover a $noun, or a price can't be read "
              'when it runs, that $noun pays the normal '
              '${_pct(fees.feeBpsPublic)} in its own asset. Top up or '
              'withdraw the reserve any time from the plan card.',
              style: muted,
            ),
          ],
        ],
      ),
    );
  }
}
