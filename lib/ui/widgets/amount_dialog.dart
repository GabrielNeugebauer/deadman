import 'package:flutter/material.dart';

import '../../state/assets.dart';
import '../theme/tokens.dart';

typedef AssetAmount = ({String? mint, int amount});

/// Asks for an amount of one of [assets], typed in whole units (SOL, USDC)
/// and returned in base units. [available] (base units per mint) is shown
/// as a hint, and enforced as a maximum when [capped].
Future<AssetAmount?> askAssetAmount(
  BuildContext context,
  String title, {
  List<AssetInfo> assets = const [solAsset, usdcAsset],
  Map<String?, int> available = const {},
  String availableLabel = 'available',
  bool capped = false,
}) {
  final controller = TextEditingController();
  var asset = assets.first;
  String? error;
  return showDialog<AssetAmount>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) {
        final max = available[asset.mint];
        void submit() {
          final v = parseAmount(controller.text, asset.mint);
          if (v == null || v <= 0) {
            setState(() => error = 'Enter an amount in ${asset.symbol}');
            return;
          }
          if (capped && max != null && v > max) {
            setState(
              () =>
                  error = 'Only ${amountText(max, asset.mint)} $availableLabel',
            );
            return;
          }
          Navigator.pop(context, (mint: asset.mint, amount: v));
        }

        return AlertDialog(
          title: Text(title),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (assets.length > 1) ...[
                SegmentedButton<AssetInfo>(
                  showSelectedIcon: false,
                  segments: [
                    for (final a in assets)
                      ButtonSegment(value: a, label: Text(a.symbol)),
                  ],
                  selected: {asset},
                  onSelectionChanged: (s) => setState(() {
                    asset = s.first;
                    error = null;
                  }),
                ),
                const SizedBox(height: DMSpace.lg),
              ],
              TextField(
                controller: controller,
                autofocus: true,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                onSubmitted: (_) => submit(),
                style: DMType.mono(size: 20),
                decoration: InputDecoration(
                  suffixText: asset.symbol,
                  labelText: 'Amount',
                  errorText: error,
                  errorMaxLines: 2,
                ),
              ),
              if (max != null)
                Padding(
                  padding: const EdgeInsets.only(top: DMSpace.sm),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          '${amountText(max, asset.mint)} $availableLabel',
                          style: DMType.data(size: 12.5),
                        ),
                      ),
                      if (capped && max > 0)
                        TextButton(
                          onPressed: () => setState(
                            () =>
                                controller.text = amountInput(max, asset.mint),
                          ),
                          child: const Text('Max'),
                        ),
                    ],
                  ),
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size(96, 44)),
              onPressed: submit,
              child: const Text('Confirm'),
            ),
          ],
        );
      },
    ),
  );
}
