import 'dart:typed_data';

/// Thrown when a wallet call fails (Mobile Wallet Adapter on Android, a
/// browser extension on the web).
class WalletException implements Exception {
  const WalletException(this.code, this.message);

  /// `NO_WALLET`, `DECLINED`, `NO_IDENTITY`, `BAD_ARGS`, `WRONG_ACCOUNT`,
  /// `MWA_ERROR` or `WALLET_ERROR`.
  final String code;
  final String message;

  bool get noWallet => code == 'NO_WALLET';
  bool get declined => code == 'DECLINED';

  @override
  String toString() => 'WalletException($code): $message';
}

/// Result of a wallet authorization.
class WalletSession {
  const WalletSession({
    required this.publicKey,
    required this.authToken,
    this.walletLabel,
  });

  /// Base58 address of the authorized account.
  final String publicKey;
  final String authToken;
  final String? walletLabel;
}

/// Signs with the user's wallet: Seed Vault through Mobile Wallet Adapter on
/// Android, Phantom or Solflare on the web. Every call asks the wallet for
/// user approval.
abstract class WalletBridge {
  Future<WalletSession> authorize();

  /// Signs serialized, unsigned legacy/v0 transactions and returns the signed
  /// transactions (same order). The app submits them itself.
  Future<List<Uint8List>> signTransactions(List<Uint8List> transactions);

  Future<void> deauthorize(String authToken);
}
