/// Boney's skins: pixel-art accessories unlocked by holding a Boney NFT
/// (Token Metadata symbol [boneySkinSymbol], the skin's id in its name,
/// e.g. "Boney Crown"). Boney keeps his status colour; the accessory is
/// drawn in it too.
library;

import '../solana/deadman_api.dart';

enum BoneySkin {
  crown('crown', 'Crown'),
  cap('cap', 'Cap'),
  glasses('glasses', 'Glasses');

  const BoneySkin(this.id, this.label);

  /// Stable id: in the NFT's name, in prefs and on the home-screen widget.
  final String id;
  final String label;

  static BoneySkin? byId(String? id) {
    for (final s in values) {
      if (s.id == id) return s;
    }
    return null;
  }
}

/// Token Metadata symbol of every Boney skin NFT.
const boneySkinSymbol = 'BONEY';

/// Prefs key of the skin on show, and the home_widget key the Android
/// widget reads ('' or absent: none).
const boneySkinKey = 'boney_skin';

/// The skin [nft] unlocks, or null when it isn't a Boney skin.
BoneySkin? skinOfNft(WalletNft nft) {
  if (nft.symbol.trim().toUpperCase() != boneySkinSymbol) return null;
  final words = nft.name.toLowerCase().split(RegExp('[^a-z0-9]+'));
  for (final s in BoneySkin.values) {
    if (words.contains(s.id)) return s;
  }
  return null;
}

/// Skins unlocked by [nfts] (a wallet's NFTs).
Set<BoneySkin> ownedSkins(Iterable<WalletNft> nfts) => {
  for (final n in nfts) ?skinOfNft(n),
};
