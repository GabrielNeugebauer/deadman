import 'dart:typed_data';

import 'wallet_bridge.dart';
import 'web_wallet_bridge.dart';

/// Off the web there are no browser extensions.
WebWalletBackend createWebWalletBackend() => const _NoBrowserBackend();

class _NoBrowserBackend implements WebWalletBackend {
  const _NoBrowserBackend();

  static const _error = WalletException(
    'NO_WALLET',
    'Browser wallets are only available on the web',
  );

  @override
  Future<List<WebWallet>> discover() async => const [];

  @override
  Future<String> connect(WebWallet wallet, {required String chain}) =>
      Future.error(_error);

  @override
  Future<List<Uint8List>> sign(
    WebWallet wallet,
    List<Uint8List> transactions, {
    required String chain,
  }) => Future.error(_error);

  @override
  Future<void> disconnect(WebWallet wallet) async {}
}
