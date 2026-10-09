import 'package:deadman/solana/deadman_api.dart';
import 'package:deadman/state/boney_skin.dart';
import 'package:deadman/state/boney_skins.dart';
import 'package:deadman/state/boney_widget_sync.dart';
import 'package:deadman/state/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'boney_test.dart' show now, plan;
import 'boney_widget_sync_test.dart' show FakeHost;
import 'fakes.dart';

WalletNft _nft(String name, {String symbol = 'BONEY', int seed = 70}) =>
    WalletNft(mint: addr(seed), name: name, symbol: symbol);

Future<(ProviderContainer, FakeApi, FakeHost)> _rig({
  List<WalletNft> nfts = const [],
  Map<String, Object> saved = const {},
  FakeApi? chain,
}) async {
  SharedPreferences.setMockInitialValues({'owner': addr(1), ...saved});
  final prefs = await SharedPreferences.getInstance();
  final api = (chain ?? FakeApi(const []))..walletNfts = nfts;
  final host = FakeHost();
  final c = ProviderContainer(
    overrides: [
      prefsProvider.overrideWithValue(prefs),
      apiProvider.overrideWithValue(api),
      boneyHostProvider.overrideWithValue(host),
    ],
  );
  addTearDown(c.dispose);
  return (c, api, host);
}

void main() {
  group('which NFT unlocks which skin', () {
    test('symbol BONEY and the skin id in the name', () {
      expect(skinOfNft(_nft('Boney Crown')), BoneySkin.crown);
      expect(skinOfNft(_nft('Boney Cap #12')), BoneySkin.cap);
      expect(skinOfNft(_nft('boney: glasses')), BoneySkin.glasses);
      expect(
        skinOfNft(_nft('Boney Crown', symbol: ' boney ')),
        BoneySkin.crown,
      );
    });

    test('anything else unlocks nothing', () {
      expect(skinOfNft(_nft('Boney Crown', symbol: 'DMSK')), isNull);
      expect(skinOfNft(_nft('Boney Hat')), isNull);
      // A whole word, not part of one.
      expect(skinOfNft(_nft('Boney Capybara')), isNull);
      expect(skinOfNft(_nft('Crowned Boney')), isNull);
    });

    test('a wallet owns the skins of its NFTs', () {
      expect(
        ownedSkins([
          _nft('Boney Crown'),
          _nft('Boney Glasses', seed: 71),
          _nft('Saga Genesis', symbol: 'SAGA', seed: 72),
        ]),
        {BoneySkin.crown, BoneySkin.glasses},
      );
      expect(ownedSkins(const []), isEmpty);
    });

    test('ids round-trip', () {
      for (final s in BoneySkin.values) {
        expect(BoneySkin.byId(s.id), s);
      }
      expect(BoneySkin.byId('hat'), isNull);
      expect(BoneySkin.byId(null), isNull);
    });
  });

  group('the skin on show', () {
    test('picked: saved, and sent to the home-screen widget', () async {
      final (c, _, host) = await _rig(nfts: [_nft('Boney Cap')]);
      expect(await c.read(ownedSkinsProvider.future), {BoneySkin.cap});
      await c.read(boneySkinProvider.notifier).choose(BoneySkin.cap);
      expect(c.read(activeSkinProvider), BoneySkin.cap);
      expect(c.read(prefsProvider).getString(boneySkinKey), 'cap');
      expect(host.data[boneySkinKey], 'cap');
      expect(host.updates, 1);

      await c.read(boneySkinProvider.notifier).choose(null);
      expect(c.read(activeSkinProvider), isNull);
      expect(c.read(prefsProvider).getString(boneySkinKey), isNull);
      expect(host.data[boneySkinKey], '');
    });

    test('kept across restarts while the NFT is held', () async {
      final (c, _, _) = await _rig(
        nfts: [_nft('Boney Crown')],
        saved: {boneySkinKey: 'crown'},
      );
      // Worn before the wallet is read.
      expect(c.read(activeSkinProvider), BoneySkin.crown);
      await c.read(ownedSkinsProvider.future);
      expect(c.read(activeSkinProvider), BoneySkin.crown);
    });

    test('the NFT left the wallet: taken off, and forgotten', () async {
      final (c, _, host) = await _rig(saved: {boneySkinKey: 'crown'});
      c.listen(activeSkinProvider, (_, _) {});
      expect(c.read(boneySkinProvider), BoneySkin.crown);
      await c.read(ownedSkinsProvider.future);
      await Future<void>.delayed(Duration.zero);
      expect(c.read(activeSkinProvider), isNull);
      expect(c.read(boneySkinProvider), isNull);
      expect(c.read(prefsProvider).getString(boneySkinKey), isNull);
      expect(host.data[boneySkinKey], '');
    });

    test('the wallet cannot be read: still worn', () async {
      final (c, _, _) = await _rig(
        saved: {boneySkinKey: 'glasses'},
        chain: _FailingNfts(),
      );
      c.listen(activeSkinProvider, (_, _) {});
      await expectLater(c.read(ownedSkinsProvider.future), throwsStateError);
      expect(c.read(activeSkinProvider), BoneySkin.glasses);
      expect(c.read(boneySkinProvider), BoneySkin.glasses);
    });
  });

  test('every widget sync sends the skin', () async {
    SharedPreferences.setMockInitialValues({boneySkinKey: 'glasses'});
    final prefs = await SharedPreferences.getInstance();
    final host = FakeHost();
    await BoneyWidgetSync(
      host,
      clock: () => now,
    ).syncPlans([plan()], prefs: prefs);
    expect(host.data[boneySkinKey], 'glasses');
    await prefs.remove(boneySkinKey);
    await BoneyWidgetSync(
      host,
      clock: () => now,
    ).syncPlans([plan()], prefs: prefs);
    expect(host.data[boneySkinKey], '');
  });
}

/// [FakeApi] whose wallet NFT read fails.
class _FailingNfts extends FakeApi {
  _FailingNfts() : super(const []);

  @override
  Future<List<WalletNft>> fetchWalletNfts(String owner) async =>
      throw StateError('rpc down');
}
