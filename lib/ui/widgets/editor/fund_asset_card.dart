import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../state/assets.dart';
import '../../../state/plan_draft.dart';
import '../../theme.dart';
import 'plan_steps.dart';

/// One line of a Fund breakdown.
class FundLine {
  const FundLine(this.title, this.detail, {this.issue});

  /// "Payout 1 · Ana · after 10 days".
  final String title;

  /// "1% of what's left → ≈ 0.0098 USDC".
  final String detail;

  /// The line's worst warning.
  final PlanIssue? issue;
}

/// How much of one asset goes into a plan, and what each payout gets.
class FundAssetCard extends StatelessWidget {
  const FundAssetCard({
    super.key,
    required this.mint,
    required this.needs,
    required this.controller,
    required this.wallet,
    required this.onChanged,
    required this.onUseAll,
    required this.breakdownTitle,
    required this.lines,
    required this.issues,
    this.useAll,
    this.leftover,
    this.leftoverWarn = false,
    this.errorText,
    this.focusNode,
    this.fieldKey,
  });

  final String? mint;

  /// What the payouts need, in one muted line.
  final String needs;
  final TextEditingController controller;

  /// The owner's wallet balance of [mint].
  final AsyncValue<int> wallet;
  final VoidCallback onChanged;
  final ValueChanged<int> onUseAll;

  /// What "Use all" fills in; null disables it.
  final int? useAll;
  final String breakdownTitle;
  final List<FundLine> lines;
  final String? leftover;
  final bool leftoverWarn;
  final List<Widget> issues;
  final String? errorText;
  final FocusNode? focusNode;
  final Key? fieldKey;

  @override
  Widget build(BuildContext context) {
    final symbol = unitLabel(mint);
    final helper = switch (wallet) {
      AsyncData(:final value) => 'In your wallet: ${moneyText(value, mint)}',
      AsyncError() => "Couldn't read your wallet balance.",
      _ => 'Checking your wallet…',
    };
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              assetSymbol(mint),
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 2),
            Text(needs, style: const TextStyle(color: DmColors.muted)),
            const SizedBox(height: 14),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: TextField(
                    key: fieldKey,
                    controller: controller,
                    focusNode: focusNode,
                    onChanged: (_) => onChanged(),
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
                    ],
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: InputDecoration(
                      labelText: 'Put in this plan',
                      hintText: '0',
                      suffixText: symbol,
                      helperText: helper,
                      helperMaxLines: 2,
                      errorText: errorText,
                      errorMaxLines: 3,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: ActionChip(
                    label: const Text('Use all'),
                    onPressed: useAll == null ? null : () => onUseAll(useAll!),
                  ),
                ),
              ],
            ),
            if (lines.isNotEmpty) ...[
              const SizedBox(height: 18),
              Text(
                breakdownTitle,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              for (final l in lines)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(l.title, style: const TextStyle(fontSize: 13)),
                      Padding(
                        padding: const EdgeInsets.only(left: 12, top: 2),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                l.detail,
                                style: const TextStyle(
                                  color: DmColors.muted,
                                  fontSize: 13,
                                ),
                              ),
                            ),
                            if (l.issue != null)
                              Tooltip(
                                message: l.issue!.headline,
                                child: Icon(
                                  severityIcon(l.issue!.severity),
                                  size: 18,
                                  color: severityColor(l.issue!.severity),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
            ],
            if (leftover != null)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(
                  leftover!,
                  style: TextStyle(
                    fontSize: 13,
                    color: leftoverWarn ? DmColors.warn : DmColors.muted,
                  ),
                ),
              ),
            ...issues,
          ],
        ),
      ),
    );
  }
}
