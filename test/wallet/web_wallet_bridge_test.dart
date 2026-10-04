import 'dart:typed_data';

import 'package:deadman/wallet/wallet_bridge.dart';
import 'package:deadman/wallet/web_wallet_bridge.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:solana/base58.dart';

const _full = {
  'standard:connect',
  'standard:disconnect',
  'solana:signTransaction',
};

Uint8List _key(int fill) => Uint8List(32)..fillRange(0, 32, fill);

/// Unsigned wire transaction whose message has [keys] and [required] signers.
Uint8List _tx(List<Uint8List> keys, int required, {bool v0 = false}) =>
    Uint8List.fromList([
      required,
      ...Uint8List(64 * required),
      if (v0) 0x80,
      required,
      0,
      1,
      keys.length,
      for (final k in keys) ...k,
      ...Uint8List(32),
      0,
      if (v0) 0,
    ]);

class FakeBackend implements WebWalletBackend {
  FakeBackend(this.wallets, {this.address});

  List<WebWallet> wallets;
  String? address;
  final connected = <WalletKind>[];
  final disconnected = <WalletKind>[];
  List<Uint8List>? signedReply;

  @override
  Future<List<WebWallet>> discover() async => wallets;

  @override
  Future<String> connect(WebWallet wallet, {required String chain}) async {
    expect(chain, 'solana:devnet');
    connected.add(wallet.kind);
    return address ?? (throw const WalletException('DECLINED', 'no'));
  }

  @override
  Future<List<Uint8List>> sign(
    WebWallet wallet,
    List<Uint8List> transactions, {
    required String chain,
  }) async =>
      signedReply ??
      [
        for (final tx in transactions) Uint8List.fromList([...tx, 1]),
      ];

  @override
  Future<void> disconnect(WebWallet wallet) async =>
      disconnected.add(wallet.kind);
}

const _phantom = WebWallet(
  kind: WalletKind.phantom,
  name: 'Phantom',
  path: SigningPath.walletStandard,
);
const _solflare = WebWallet(
  kind: WalletKind.solflare,
  name: 'Solflare',
  path: SigningPath.injected,
);

void main() {
  group('discovery', () {
    test('wallet names map to kinds', () {
      expect(WalletKind.fromName('Phantom'), WalletKind.phantom);
      expect(WalletKind.fromName(' solflare '), WalletKind.solflare);
      expect(WalletKind.fromName('Solflare Snap'), WalletKind.solflare);
      expect(WalletKind.fromName('Backpack'), isNull);
      expect(WalletKind.fromName('PhantomX'), isNull);
      expect(WalletKind.fromName(null), isNull);
    });

    test('Wallet Standard wins; injected fills in; Phantom first', () {
      final wallets = mergeDiscovered(
        standard: const [
          StandardWalletInfo(name: 'Backpack', features: _full),
          StandardWalletInfo(name: 'Solflare', features: _full, icon: 'data:'),
          StandardWalletInfo(name: 'Phantom', features: _full),
        ],
        injected: const [WalletKind.phantom, WalletKind.solflare],
      );
      expect(wallets.map((w) => (w.kind, w.path)), [
        (WalletKind.phantom, SigningPath.walletStandard),
        (WalletKind.solflare, SigningPath.walletStandard),
      ]);
      expect(wallets.last.icon, 'data:');
    });

    test('a standard wallet without solana:signTransaction falls back', () {
      final wallets = mergeDiscovered(
        standard: const [
          StandardWalletInfo(name: 'Phantom', features: {'standard:connect'}),
        ],
        injected: const [WalletKind.phantom],
      );
      expect(wallets.single.path, SigningPath.injected);
      expect(wallets.single.name, 'Phantom');
      expect(
        mergeDiscovered(
          standard: const [
            StandardWalletInfo(name: 'Phantom', features: {'standard:connect'}),
          ],
          injected: const [],
        ),
        isEmpty,
      );
    });

    test('cluster to Wallet Standard chain', () {
      expect(solanaChain('devnet'), 'solana:devnet');
      expect(solanaChain('mainnet-beta'), 'solana:mainnet');
      expect(solanaChain('testnet'), 'solana:testnet');
      expect(solanaChain('localnet'), 'solana:localnet');
    });
  });

  group('requiredSigners', () {
    test('legacy and v0 messages', () {
      final keys = [_key(1), _key(2), _key(3)];
      for (final v0 in [false, true]) {
        expect(requiredSigners(_tx(keys, 2, v0: v0)), [
          base58encode(keys[0]),
          base58encode(keys[1]),
        ]);
      }
    });

    test('rejects malformed bytes', () {
      expect(
        () => requiredSigners(Uint8List.fromList([1])),
        throwsFormatException,
      );
      expect(() => requiredSigners(_tx([_key(1)], 2)), throwsFormatException);
      final tx = _tx([_key(1), _key(2)], 1);
      expect(
        () => requiredSigners(Uint8List.sublistView(tx, 0, 70)),
        throwsFormatException,
      );
    });
  });

  group('WebWalletBridge', () {
    late SharedPreferences prefs;
    final owner = base58encode(_key(7));
    final tx = _tx([_key(7), _key(8)], 1);

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
    });

    test('no wallet installed', () async {
      final bridge = WebWalletBridge(backend: FakeBackend([]), prefs: prefs);
      await expectLater(
        bridge.authorize(),
        throwsA(
          isA<WalletException>().having((e) => e.noWallet, 'noWallet', true),
        ),
      );
      await expectLater(
        bridge.connect(WalletKind.solflare),
        throwsA(
          isA<WalletException>().having((e) => e.code, 'code', 'NO_WALLET'),
        ),
      );
    });

    test('connect returns the session and remembers the wallet', () async {
      final backend = FakeBackend([_phantom, _solflare], address: owner);
      final bridge = WebWalletBridge(backend: backend, prefs: prefs);
      final session = await bridge.connect(WalletKind.solflare);
      expect(session.publicKey, owner);
      expect(session.authToken, WebWalletBridge.authToken);
      expect(session.walletLabel, 'Solflare');
      expect(bridge.wallet, _solflare);
      expect(prefs.getString('web_wallet'), 'solflare');

      // A new page load prefers it over Phantom.
      final reloaded = WebWalletBridge(backend: backend, prefs: prefs);
      expect(reloaded.lastKind, WalletKind.solflare);
      await reloaded.authorize();
      expect(backend.connected, [WalletKind.solflare, WalletKind.solflare]);
    });

    test('authorize defaults to the first installed wallet', () async {
      final backend = FakeBackend([_phantom, _solflare], address: owner);
      await WebWalletBridge(backend: backend, prefs: prefs).authorize();
      expect(backend.connected, [WalletKind.phantom]);
    });

    test('signs, reconnecting first after a reload', () async {
      final backend = FakeBackend([_phantom], address: owner);
      final bridge = WebWalletBridge(backend: backend, prefs: prefs);
      expect(await bridge.signTransactions(const []), isEmpty);
      final signed = await bridge.signTransactions([tx, tx]);
      expect(backend.connected, [WalletKind.phantom]);
      expect(signed, hasLength(2));
      expect(signed.first.last, 1);
    });

    test('refuses when the wallet account does not sign', () async {
      final backend = FakeBackend([_phantom], address: base58encode(_key(9)));
      final bridge = WebWalletBridge(backend: backend, prefs: prefs);
      await expectLater(
        bridge.signTransactions([tx]),
        throwsA(
          isA<WalletException>().having((e) => e.code, 'code', 'WRONG_ACCOUNT'),
        ),
      );
    });

    test('a short reply from the wallet is an error', () async {
      final backend = FakeBackend([_phantom], address: owner)
        ..signedReply = [tx];
      final bridge = WebWalletBridge(backend: backend, prefs: prefs);
      await expectLater(
        bridge.signTransactions([tx, tx]),
        throwsA(
          isA<WalletException>().having((e) => e.code, 'code', 'WALLET_ERROR'),
        ),
      );
    });

    test('deauthorize disconnects once', () async {
      final backend = FakeBackend([_phantom], address: owner);
      final bridge = WebWalletBridge(backend: backend, prefs: prefs);
      await bridge.authorize();
      await bridge.deauthorize(WebWalletBridge.authToken);
      await bridge.deauthorize(WebWalletBridge.authToken);
      expect(backend.disconnected, [WalletKind.phantom]);
      expect(bridge.wallet, isNull);
      expect(bridge.address, isNull);
    });

    test('off the web the default backend finds nothing', () async {
      final bridge = WebWalletBridge(prefs: prefs);
      expect(await bridge.available(), isEmpty);
      await expectLater(bridge.authorize(), throwsA(isA<WalletException>()));
    });
  });
}
