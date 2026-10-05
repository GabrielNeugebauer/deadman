import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../state/assets.dart';
import '../../../state/plan_draft.dart';
import '../brand/brand.dart';
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
    return DMCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Semantics(
                  header: true,
                  child: Text(
                    assetSymbol(mint),
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
              ),
              const SizedBox(width: DMSpace.md),
              TextButton(
                onPressed: useAll == null ? null : () => onUseAll(useAll!),
                child: const Text('Use all'),
              ),
            ],
          ),
          Text(
            needs,
            style: DMType.outfit(size: 14, color: DM.dust, height: 1.4),
          ),
          const SizedBox(height: DMSpace.xl),
          LabeledField(
            label: 'Put in this plan',
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
              style: DMType.mono(size: 18, weight: FontWeight.w500),
              decoration: InputDecoration(
                hintText: '0',
                hintStyle: DMType.mono(size: 18, color: DM.ash),
                suffixText: symbol,
                suffixStyle: DMType.mono(size: 14, color: DM.dust),
                helperText: helper,
                helperStyle: DMType.mono(size: 12, color: DM.dust),
                helperMaxLines: 2,
                errorText: errorText,
                errorMaxLines: 3,
              ),
            ),
          ),
          if (lines.isNotEmpty) ...[
            const SizedBox(height: DMSpace.lg),
            const Divider(height: 1),
            const SizedBox(height: DMSpace.lg),
            Text(
              breakdownTitle,
              style: DMType.outfit(size: 15, weight: FontWeight.w600),
            ),
            for (final l in lines) _FundLineRow(l),
          ],
          if (leftover != null)
            Padding(
              padding: const EdgeInsets.only(top: DMSpace.md),
              child: Text(
                leftover!,
                style: DMType.data(
                  size: 12.5,
                  color: leftoverWarn ? DM.missed : DM.dust,
                ),
              ),
            ),
          ...issues,
        ],
      ),
    );
  }
}

class _FundLineRow extends StatelessWidget {
  const _FundLineRow(this.line);

  final FundLine line;

  @override
  Widget build(BuildContext context) {
    final issue = line.issue;
    return Padding(
      padding: const EdgeInsets.only(top: DMSpace.md),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(line.title, style: DMType.outfit(size: 14, height: 1.35)),
                const SizedBox(height: 2),
                Text(line.detail, style: DMType.data(size: 12.5)),
              ],
            ),
          ),
          if (issue != null)
            Padding(
              padding: const EdgeInsets.only(left: DMSpace.sm, top: 2),
              child: Tooltip(
                message: issue.headline,
                child: Icon(
                  severityIcon(issue.severity),
                  size: 18,
                  color: severityColor(issue.severity),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
