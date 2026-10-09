import 'package:flutter/material.dart';

import '../../../state/assets.dart';
import '../brand/brand.dart';
import '../nft.dart';
import 'plan_steps.dart' show pickChip;
import 'token_picker.dart';

/// Asks for a token: one from the Jupiter list or a pasted mint address;
/// null when cancelled.
Future<String?> askMint(BuildContext context, {String? initial}) async {
  final mint = await pickToken(context, initial: initial);
  return mint == null ? null : knownAsset(mint)?.mint ?? mint;
}

/// "Which money": one chip per asset in [assets], plus "Other token" for
/// any other token when [allowOther], and "NFT" (one of the wallet's
/// classic NFTs) when [allowNft].
class AssetChips extends StatelessWidget {
  const AssetChips({
    super.key,
    required this.mint,
    required this.onChanged,
    this.assets = presetAssets,
    this.allowOther = true,
    this.allowNft = false,
  });

  final String? mint;
  final ValueChanged<String?> onChanged;
  final List<AssetInfo> assets;
  final bool allowOther;
  final bool allowNft;

  bool get _nft => isNft(mint);
  bool get _custom => !_nft && !assets.any((a) => a.mint == mint);

  Future<void> _pickNft(BuildContext context) async {
    final nft = await pickNft(context);
    if (nft != null) onChanged(nft.mint);
  }

  Future<void> _pickOther(BuildContext context) async {
    final result = await askMint(context, initial: _custom ? mint : null);
    if (result != null) onChanged(result);
  }

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: DMSpace.sm,
    runSpacing: DMSpace.xxs,
    children: [
      for (final a in assets)
        pickChip(
          label: a.symbol,
          mono: true,
          selected: mint == a.mint,
          onSelected: (_) => onChanged(a.mint),
        ),
      if (allowOther)
        pickChip(
          label: _custom ? 'Other: ${assetSymbol(mint)}' : 'Other token',
          selected: _custom,
          onSelected: (_) => _pickOther(context),
        ),
      if (allowNft || _nft)
        pickChip(
          key: const ValueKey('asset-nft'),
          label: _nft ? assetSymbol(mint) : 'NFT',
          avatar: _nft ? NftThumb(mint, size: 18) : null,
          selected: _nft,
          onSelected: allowNft ? (_) => _pickNft(context) : null,
        ),
    ],
  );
}
