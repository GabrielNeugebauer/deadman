import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../solana/deadman_api.dart';
import '../../state/assets.dart';
import '../../state/nfts.dart';
import 'brand/brand.dart';

/// A picture frame in pixels: where an NFT's image would be.
const nftFrameSprite = PixelSprite('nft-frame', [
  '###########',
  '#.........#',
  '#......##.#',
  '#......##.#',
  '#...#.....#',
  '#..###..#.#',
  '#.#####.###',
  '###########',
]);

/// An NFT's image at [size], square; the pixel frame while it loads, when
/// there is none, or when the link is broken.
class NftImage extends StatelessWidget {
  const NftImage({super.key, required this.url, this.size = 40});

  final String? url;
  final double size;

  Widget _frame() => ColoredBox(
    color: DM.void_,
    child: Center(
      child: PixelArt(nftFrameSprite, size: size * 0.45, color: DM.ash),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final url = this.url;
    return ClipRRect(
      borderRadius: BorderRadius.circular(size * 0.18),
      child: SizedBox.square(
        dimension: size,
        child: url == null
            ? _frame()
            : Image.network(
                url,
                fit: BoxFit.cover,
                width: size,
                height: size,
                cacheWidth: (size * 3).round(),
                loadingBuilder: (_, child, progress) =>
                    progress == null ? child : _frame(),
                errorBuilder: (_, _, _) => _frame(),
              ),
      ),
    );
  }
}

/// The thumbnail of NFT [mint], looked up when not known yet; nothing for
/// a mint that isn't an NFT.
class NftThumb extends ConsumerWidget {
  const NftThumb(this.mint, {super.key, this.size = 20});

  final String? mint;
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    watchNftNames(ref, [mint]);
    final info = knownAsset(mint);
    if (info == null || !info.nft) return const SizedBox.shrink();
    return NftImage(url: info.imageUrl, size: size);
  }
}

/// [child] led by the thumbnail of [mint] when it's an NFT.
class WithNftThumb extends ConsumerWidget {
  const WithNftThumb({
    super.key,
    required this.mint,
    required this.child,
    this.size = 20,
  });

  final String? mint;
  final Widget child;
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    watchNftNames(ref, [mint]);
    if (!isNft(mint)) return child;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 1, right: DMSpace.sm),
          child: NftThumb(mint, size: size),
        ),
        Expanded(child: child),
      ],
    );
  }
}

/// Lets the owner pick one of their wallet's classic NFTs; pops with it.
Future<WalletNft?> pickNft(BuildContext context) =>
    showModalBottomSheet<WalletNft>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const NftPickerSheet(),
    );

/// The wallet's NFTs in a grid. Programmable and frozen ones are shown,
/// disabled, with the reason.
class NftPickerSheet extends ConsumerWidget {
  const NftPickerSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final nfts = ref.watch(walletNftsProvider);
    final muted = DMType.outfit(size: 14, color: DM.dust, height: 1.4);
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.8,
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            DMSpace.gutter,
            0,
            DMSpace.gutter,
            DMSpace.gutter,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Choose an NFT',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: DMSpace.xs),
              Text(
                'It goes to one person, whole. $nftSupportNote',
                style: muted,
              ),
              const SizedBox(height: DMSpace.lg),
              Flexible(
                child: switch (nfts) {
                  AsyncData(:final value) when value.isEmpty => Padding(
                    padding: const EdgeInsets.symmetric(vertical: DMSpace.xxl),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const PixelArt(nftFrameSprite, size: 32, color: DM.ash),
                        const SizedBox(height: DMSpace.md),
                        Text(
                          'No NFTs in this wallet',
                          textAlign: TextAlign.center,
                          style: muted,
                        ),
                      ],
                    ),
                  ),
                  AsyncData(:final value) => GridView.builder(
                    shrinkWrap: true,
                    gridDelegate:
                        const SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 160,
                          mainAxisSpacing: DMSpace.md,
                          crossAxisSpacing: DMSpace.md,
                          childAspectRatio: 0.72,
                        ),
                    itemCount: value.length,
                    itemBuilder: (context, i) => _NftTile(value[i]),
                  ),
                  AsyncError() => Padding(
                    padding: const EdgeInsets.symmetric(vertical: DMSpace.xl),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          "Couldn't read this wallet's NFTs.",
                          textAlign: TextAlign.center,
                          style: muted,
                        ),
                        TextButton(
                          onPressed: () => ref.invalidate(walletNftsProvider),
                          child: const Text('Retry'),
                        ),
                      ],
                    ),
                  ),
                  _ => const Padding(
                    padding: EdgeInsets.symmetric(vertical: DMSpace.xxl),
                    child: Center(child: CircularProgressIndicator()),
                  ),
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NftTile extends StatelessWidget {
  const _NftTile(this.nft);

  final WalletNft nft;

  @override
  Widget build(BuildContext context) {
    final reason = nftUnsupportedReason(nft);
    final name = assetSymbol(nft.mint);
    return Semantics(
      button: reason == null,
      enabled: reason == null,
      label: reason == null ? name : '$name, $reason',
      excludeSemantics: true,
      child: Opacity(
        opacity: reason == null ? 1 : 0.45,
        child: DMCard(
          padding: const EdgeInsets.all(DMSpace.sm),
          onTap: reason == null ? () => Navigator.pop(context, nft) : null,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: LayoutBuilder(
                  builder: (context, box) => Center(
                    child: NftImage(
                      url: nft.imageUrl,
                      size: math.min(box.maxWidth, box.maxHeight),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: DMSpace.xs),
              Text(
                name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: DMType.outfit(
                  size: 13.5,
                  weight: FontWeight.w600,
                  height: 1.25,
                ),
              ),
              if (reason != null)
                Text(
                  reason,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: DMType.data(size: 11, color: DM.missed),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
