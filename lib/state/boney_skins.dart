import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'boney_skin.dart';
import 'nfts.dart';
import 'providers.dart';

/// Skins the connected wallet's NFTs unlock.
final ownedSkinsProvider = FutureProvider<Set<BoneySkin>>(
  (ref) async => ownedSkins(await ref.watch(walletNftsProvider.future)),
);

/// The skin the owner picked, persisted on this phone. Cleared once the
/// wallet's NFTs are read and its NFT is no longer there (never under
/// duress).
class BoneySkinChoice extends Notifier<BoneySkin?> {
  @override
  BoneySkin? build() {
    final saved = BoneySkin.byId(
      ref.read(prefsProvider).getString(boneySkinKey),
    );
    // Only a skin saved earlier needs checking; one picked now is owned.
    if (saved != null) {
      ref.listen(ownedSkinsProvider, (_, next) {
        final owned = next.value;
        final chosen = state;
        if (owned == null || chosen == null || owned.contains(chosen)) return;
        final session = ref.read(sessionProvider);
        if (session.duress || session.owner == null) return;
        unawaited(choose(null));
      });
    }
    return saved;
  }

  /// Puts [skin] on Boney (null takes it off), here and on the home-screen
  /// widget.
  Future<void> choose(BoneySkin? skin) async {
    state = skin;
    final prefs = ref.read(prefsProvider);
    if (skin == null) {
      await prefs.remove(boneySkinKey);
    } else {
      await prefs.setString(boneySkinKey, skin.id);
    }
    final host = ref.read(boneyHostProvider);
    if (host == null) return;
    try {
      await host.save({boneySkinKey: skin?.id ?? ''});
      await host.update();
    } on Object {
      // The next widget sync sends it again.
    }
  }
}

final boneySkinProvider = NotifierProvider<BoneySkinChoice, BoneySkin?>(
  BoneySkinChoice.new,
);

/// The skin Boney wears: the one picked, while the wallet holds its NFT
/// (or while the wallet's NFTs can't be read).
final activeSkinProvider = Provider<BoneySkin?>((ref) {
  final chosen = ref.watch(boneySkinProvider);
  if (chosen == null) return null;
  final owned = ref.watch(ownedSkinsProvider).value;
  return owned == null || owned.contains(chosen) ? chosen : null;
});
