import 'package:flutter/material.dart';

import '../../state/assets.dart';
import '../theme/tokens.dart';
import 'editor/asset_chips.dart' show askMint;
import 'editor/plan_steps.dart' show pickChip;
import 'nft.dart';

typedef AssetAmount = ({String? mint, int amount});

/// Asks for an amount of one of [assets], typed in whole units (SOL, USDC)
/// and returned in base units; an NFT moves whole (amount 1). [available]
/// (base units per mint) is shown as a hint, and enforced as a maximum when
/// [capped]. [allowOther] adds any token by mint, [allowNft] one of the
/// wallet's NFTs.
Future<AssetAmount?> askAssetAmount(
  BuildContext context,
  String title, {
  List<AssetInfo> assets = const [solAsset, usdcAsset],
  Map<String?, int> available = const {},
  String availableLabel = 'available',
  bool capped = false,
  bool allowOther = false,
  bool allowNft = false,
  String? note,
}) {
  final controller = TextEditingController();
  var asset = assets.first;
  String? error;
  return showDialog<AssetAmount>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) {
        final max = available[asset.mint];
        final custom = !assets.contains(asset);
        void choose(AssetInfo a) => setState(() {
          asset = a;
          error = null;
        });

        void submit() {
          final v = asset.nft ? 1 : parseAmount(controller.text, asset.mint);
          if (v == null || v <= 0) {
            setState(
              () => error = 'Enter an amount in ${unitLabel(asset.mint)}',
            );
            return;
          }
          if (capped && max != null && v > max) {
            setState(
              () => error = max == 0
                  ? 'None $availableLabel'
                  : 'Only ${amountText(max, asset.mint)} $availableLabel',
            );
            return;
          }
          Navigator.pop(context, (mint: asset.mint, amount: v));
        }

        Future<void> other() async {
          final mint = await askMint(
            context,
            initial: custom && !asset.nft ? asset.mint : null,
          );
          if (mint != null) choose(assetInfo(mint));
        }

        Future<void> nft() async {
          final picked = await pickNft(context);
          if (picked != null && context.mounted) {
            Navigator.pop(context, (mint: picked.mint, amount: 1));
          }
        }

        return AlertDialog(
          title: Text(title),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (assets.length > 1 || allowOther || allowNft) ...[
                  Wrap(
                    spacing: DMSpace.sm,
                    runSpacing: DMSpace.xxs,
                    children: [
                      for (final a in assets)
                        pickChip(
                          label: a.symbol,
                          mono: !a.nft,
                          avatar: a.nft ? NftThumb(a.mint, size: 18) : null,
                          selected: asset == a,
                          onSelected: (_) => choose(a),
                        ),
                      if (allowOther)
                        pickChip(
                          label: custom
                              ? 'Other: ${asset.symbol}'
                              : 'Other token',
                          selected: custom,
                          onSelected: (_) => other(),
                        ),
                      if (allowNft)
                        pickChip(
                          key: const ValueKey('deposit-nft'),
                          label: 'NFT',
                          selected: false,
                          onSelected: (_) => nft(),
                        ),
                    ],
                  ),
                  const SizedBox(height: DMSpace.lg),
                ],
                if (asset.nft)
                  Row(
                    children: [
                      NftThumb(asset.mint, size: 48),
                      const SizedBox(width: DMSpace.md),
                      Expanded(
                        child: Text(
                          '${asset.symbol} moves whole.',
                          style: DMType.outfit(size: 15, height: 1.35),
                        ),
                      ),
                    ],
                  )
                else
                  TextField(
                    controller: controller,
                    autofocus: true,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    onSubmitted: (_) => submit(),
                    style: DMType.mono(size: 20),
                    decoration: InputDecoration(
                      suffixText: unitLabel(asset.mint),
                      labelText: 'Amount',
                      helperText: knownAsset(asset.mint) == null
                          ? 'In base units of this token.'
                          : null,
                      errorText: error,
                      errorMaxLines: 2,
                    ),
                  ),
                if (asset.nft && error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: DMSpace.sm),
                    child: Text(
                      error!,
                      style: DMType.outfit(size: 13, color: DM.flatline),
                    ),
                  ),
                if (max != null && !asset.nft)
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
                              () => controller.text = amountInput(
                                max,
                                asset.mint,
                              ),
                            ),
                            child: const Text('Max'),
                          ),
                      ],
                    ),
                  ),
                if (note != null)
                  Padding(
                    padding: const EdgeInsets.only(top: DMSpace.md),
                    child: Text(
                      note,
                      style: DMType.outfit(
                        size: 13.5,
                        color: DM.dust,
                        height: 1.4,
                      ),
                    ),
                  ),
              ],
            ),
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
