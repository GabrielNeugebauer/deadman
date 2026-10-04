import 'dart:typed_data';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:solana/base58.dart';

import '../core/config.dart';
import 'wallet_bridge.dart';
import 'web_wallet_backend_stub.dart'
    if (dart.library.js_interop) 'web_wallet_backend_js.dart';

enum WalletKind {
  phantom('Phantom'),
  solflare('Solflare');

  const WalletKind(this.label);

  final String label;

  /// The kind a Wallet Standard wallet named [name] belongs to, if any.
  static WalletKind? fromName(String? name) {
    final n = name?.trim().toLowerCase() ?? '';
    for (final kind in values) {
      if (n == kind.name || n.startsWith('${kind.name} ')) return kind;
    }
    return null;
  }
}

/// How the app talks to an installed wallet.
enum SigningPath {
  /// Wallet Standard `solana:signTransaction`: raw transaction bytes in and
  /// out.
  walletStandard,

  /// The legacy injected provider (`window.phantom.solana`, `window.solana`,
  /// `window.solflare`), which needs @solana/web3.js transaction objects.
  injected,
}

/// A wallet extension found in this browser.
class WebWallet {
  const WebWallet({
    required this.kind,
    required this.name,
    required this.path,
    this.icon,
  });

  final WalletKind kind;
  final String name;
  final SigningPath path;

  /// Data URI of the wallet's icon (Wallet Standard only).
  final String? icon;

  @override
  String toString() => 'WebWallet($name, ${path.name})';
}

/// What a Wallet Standard wallet announced, reduced to what discovery needs.
class StandardWalletInfo {
  const StandardWalletInfo({
    required this.name,
    required this.features,
    this.icon,
  });

  final String name;
  final Set<String> features;
  final String? icon;
}

/// Picks one wallet per [WalletKind], preferring the Wallet Standard path,
/// in [WalletKind] order. [injected] lists kinds with a legacy provider.
List<WebWallet> mergeDiscovered({
  required Iterable<StandardWalletInfo> standard,
  required Iterable<WalletKind> injected,
}) {
  final found = <WalletKind, WebWallet>{};
  for (final info in standard) {
    final kind = WalletKind.fromName(info.name);
    if (kind == null || found.containsKey(kind)) continue;
    if (!info.features.containsAll(requiredStandardFeatures)) continue;
    found[kind] = WebWallet(
      kind: kind,
      name: info.name,
      path: SigningPath.walletStandard,
      icon: info.icon,
    );
  }
  for (final kind in injected) {
    found.putIfAbsent(
      kind,
      () => WebWallet(kind: kind, name: kind.label, path: SigningPath.injected),
    );
  }
  return [for (final kind in WalletKind.values) ?found[kind]];
}

const requiredStandardFeatures = {'standard:connect', 'solana:signTransaction'};

/// Wallet Standard chain id for a Solana cluster name.
String solanaChain(String cluster) => switch (cluster) {
  'mainnet-beta' || 'mainnet' => 'solana:mainnet',
  'devnet' => 'solana:devnet',
  'testnet' => 'solana:testnet',
  _ => 'solana:localnet',
};

/// Base58 addresses that must sign a serialized (legacy or v0) transaction:
/// the first `numRequiredSignatures` account keys of its message.
List<String> requiredSigners(Uint8List wire) {
  var i = 0;
  int compactU16() {
    var value = 0;
    for (var shift = 0; shift < 21; shift += 7) {
      final b = wire[i++];
      value |= (b & 0x7f) << shift;
      if (b & 0x80 == 0) return value;
    }
    throw const FormatException('Bad compact-u16');
  }

  try {
    final sigs = compactU16();
    i += sigs * 64;
    if (wire[i] & 0x80 != 0) i++; // versioned message prefix
    final required = wire[i];
    i += 3;
    final keys = compactU16();
    if (required > keys) throw const FormatException('Bad message header');
    return [
      for (var k = 0; k < required; k++)
        base58encode(wire.sublist(i + k * 32, i + k * 32 + 32)),
    ];
  } on RangeError {
    throw const FormatException('Truncated transaction');
  }
}

/// Browser side of [WebWalletBridge]; the real one lives in
/// web_wallet_backend_js.dart, the stub reports no wallets off the web.
abstract class WebWalletBackend {
  /// Installed Phantom/Solflare wallets.
  Future<List<WebWallet>> discover();

  /// Connects (asks for approval when not yet trusted) and returns the base58
  /// address of the account the wallet shares.
  Future<String> connect(WebWallet wallet, {required String chain});

  /// Signs serialized unsigned transactions with the connected account and
  /// returns them serialized, same order.
  Future<List<Uint8List>> sign(
    WebWallet wallet,
    List<Uint8List> transactions, {
    required String chain,
  });

  Future<void> disconnect(WebWallet wallet);
}

/// [WalletBridge] for Phantom and Solflare browser extensions.
class WebWalletBridge implements WalletBridge {
  WebWalletBridge({
    WebWalletBackend? backend,
    this._prefs,
    String cluster = AppConfig.cluster,
  }) : _backend = backend ?? createWebWalletBackend(),
       _chain = solanaChain(cluster);

  /// Browser wallets have no MWA-style auth token.
  static const authToken = 'web';
  static const _lastKey = 'web_wallet';

  final WebWalletBackend _backend;
  final SharedPreferences? _prefs;
  final String _chain;

  WebWallet? _wallet;
  String? _address;

  WebWallet? get wallet => _wallet;
  String? get address => _address;

  /// The wallet chosen last on this browser, if remembered.
  WalletKind? get lastKind {
    final name = _prefs?.getString(_lastKey);
    return WalletKind.values.where((k) => k.name == name).firstOrNull;
  }

  Future<List<WebWallet>> available() => _backend.discover();

  /// Connects [kind]; other code then signs with it.
  Future<WalletSession> connect(WalletKind kind) async {
    final wallets = await available();
    final wallet = wallets.where((w) => w.kind == kind).firstOrNull;
    if (wallet == null) {
      throw WalletException(
        'NO_WALLET',
        '${kind.label} is not installed in this browser',
      );
    }
    final address = await _backend.connect(wallet, chain: _chain);
    _wallet = wallet;
    _address = address;
    await _prefs?.setString(_lastKey, kind.name);
    return WalletSession(
      publicKey: address,
      authToken: authToken,
      walletLabel: wallet.name,
    );
  }

  /// Connects the wallet used last, else the first installed one (Phantom,
  /// then Solflare). Use [connect] to let the user pick.
  @override
  Future<WalletSession> authorize() async {
    final wallets = await available();
    if (wallets.isEmpty) {
      throw const WalletException(
        'NO_WALLET',
        'No Solana wallet found. Install Phantom or Solflare in this browser.',
      );
    }
    final last = lastKind;
    final kind = wallets.any((w) => w.kind == last)
        ? last!
        : wallets.first.kind;
    return connect(kind);
  }

  @override
  Future<List<Uint8List>> signTransactions(List<Uint8List> transactions) async {
    if (transactions.isEmpty) return const [];
    // After a page reload the session survives in prefs but not the wallet
    // connection; trusted sites reconnect without a prompt.
    if (_wallet == null) await authorize();
    final address = _address!;
    for (final tx in transactions) {
      if (!requiredSigners(tx).contains(address)) {
        throw WalletException(
          'WRONG_ACCOUNT',
          '${_wallet!.name} is connected to $address, which does not sign '
              'this transaction. Switch accounts in the wallet or reconnect.',
        );
      }
    }
    final signed = await _backend.sign(_wallet!, transactions, chain: _chain);
    if (signed.length != transactions.length) {
      throw WalletException(
        'WALLET_ERROR',
        '${_wallet!.name} returned ${signed.length} of '
            '${transactions.length} transactions',
      );
    }
    return signed;
  }

  @override
  Future<void> deauthorize(String authToken) async {
    final wallet = _wallet;
    _wallet = null;
    _address = null;
    if (wallet != null) await _backend.disconnect(wallet);
  }
}
