import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../solana/deadman_api.dart';
import '../core/config.dart';
import 'assets.dart';
import 'providers.dart';
import 'token_list.dart';

/// What the app can say about NFTs it cannot put in a plan.
const nftSupportNote =
    'Classic Solana NFTs only. Programmable NFTs, compressed NFTs, Metaplex '
    "Core assets and Token-2022 NFTs aren't supported yet.";

/// Why [nft] cannot go into a plan; null when it can.
String? nftUnsupportedReason(WalletNft nft) => nft.programmable
    ? 'Programmable NFT: not supported yet'
    : nft.frozen
    ? 'Frozen in your wallet (staked or listed)'
    : null;

/// Names [nft] for the rest of the app (see [rememberNft]).
WalletNft _remember(WalletNft nft) {
  rememberNft(nft.mint, nft.name, imageUrl: nft.imageUrl);
  return nft;
}

/// Classic NFTs in the connected wallet, supported ones first; pNFTs and
/// frozen ones are listed so the picker can say why they can't be used.
final walletNftsProvider = FutureProvider<List<WalletNft>>((ref) async {
  final owner = ref.watch(sessionProvider.select((s) => s.owner));
  if (owner == null) return const [];
  final nfts = await ref.watch(viewApiProvider).fetchWalletNfts(owner);
  return [
    for (final n in nfts)
      if (n.supported) _remember(n),
    for (final n in nfts)
      if (!n.supported) _remember(n),
  ];
});

/// Token Metadata of [mint]; null when it isn't a classic NFT, or can't be
/// read. Remembers the name, so amounts of it read as the NFT.
final nftMetadataProvider = FutureProvider.family<WalletNft?, String>((
  ref,
  mint,
) async {
  try {
    final nft = await ref.watch(viewApiProvider).fetchNftMetadata(mint);
    return nft == null ? null : _remember(nft);
  } on Object {
    return null;
  }
});

/// Looks up every mint in [mints] the app can't name yet, so NFTs among
/// them get their names, and on mainnet the other tokens their Jupiter
/// symbol and decimals; rebuilds the caller as each one resolves.
void watchNftNames(WidgetRef ref, Iterable<String?> mints) {
  for (final m in {...mints}) {
    if (m == null || knownAsset(m) != null) continue;
    final nft = ref.watch(nftMetadataProvider(m));
    if (AppConfig.isMainnet && nft is AsyncData && nft.value == null) {
      ref.watch(listedTokenProvider(m));
    }
  }
}
