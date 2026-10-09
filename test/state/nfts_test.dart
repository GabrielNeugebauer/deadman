import 'package:deadman/solana/deadman_api.dart';
import 'package:deadman/state/assets.dart';
import 'package:deadman/state/nfts.dart';
import 'package:deadman/state/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes.dart';

class _NftApi extends FakeApi {
  _NftApi() : super(const []);

  List<WalletNft> nfts = const [];
  final metadata = <String, WalletNft>{};
  final asked = <String>[];
  bool broken = false;

  @override
  Future<List<WalletNft>> fetchWalletNfts(String owner) async {
    asked.add(owner);
    return nfts;
  }

  @override
  Future<WalletNft?> fetchNftMetadata(String mint) async {
    if (broken) throw StateError('rpc down');
    return metadata[mint];
  }
}

WalletNft nft(int seed, String name, {bool programmable = false}) => WalletNft(
  mint: addr(seed),
  name: name,
  symbol: 'X',
  imageUrl: 'https://example.com/$seed.png',
  programmable: programmable,
);

Future<ProviderContainer> _container(_NftApi api, {String? owner}) async {
  SharedPreferences.setMockInitialValues({'owner': ?owner});
  final prefs = await SharedPreferences.getInstance();
  final c = ProviderContainer(
    overrides: [
      prefsProvider.overrideWithValue(prefs),
      apiProvider.overrideWithValue(api),
    ],
  );
  addTearDown(c.dispose);
  return c;
}

void main() {
  setUp(forgetNfts);
  tearDown(forgetNfts);

  test('wallet NFTs: supported first, every name remembered', () async {
    final api = _NftApi()
      ..nfts = [
        nft(90, 'Locked pNFT', programmable: true),
        nft(91, 'Saga Genesis #7'),
      ];
    final c = await _container(api, owner: addr(1));
    final got = await c.read(walletNftsProvider.future);
    expect(got.map((n) => n.name), ['Saga Genesis #7', 'Locked pNFT']);
    expect(api.asked, [addr(1)]);
    expect(amountText(1, addr(91)), 'Saga Genesis #7');
    expect(knownAsset(addr(91))!.imageUrl, 'https://example.com/91.png');
    expect(isNft(addr(90)), isTrue);
    expect(nftUnsupportedReason(got.last), contains('not supported yet'));
    expect(nftUnsupportedReason(got.first), isNull);
  });

  test('no wallet: no NFTs, nothing asked', () async {
    final api = _NftApi();
    final c = await _container(api);
    expect(await c.read(walletNftsProvider.future), isEmpty);
    expect(api.asked, isEmpty);
  });

  test("a plan's mint is named once its metadata is read", () async {
    final api = _NftApi()..metadata[addr(92)] = nft(92, 'Chapter 2');
    final c = await _container(api, owner: addr(1));
    expect(await c.read(nftMetadataProvider(addr(92)).future), isNotNull);
    expect(assetSymbol(addr(92)), 'Chapter 2');
    expect(await c.read(nftMetadataProvider(addr(93)).future), isNull);
    expect(isNft(addr(93)), isFalse);
  });

  test('a failed metadata read is just unknown', () async {
    final api = _NftApi()..broken = true;
    final c = await _container(api, owner: addr(1));
    expect(await c.read(nftMetadataProvider(addr(94)).future), isNull);
  });
}
