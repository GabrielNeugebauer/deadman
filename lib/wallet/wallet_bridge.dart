import 'dart:typed_data';

/// Result of a Mobile Wallet Adapter authorization.
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

/// Signs with the user's Seed Vault-backed wallet through Mobile Wallet
/// Adapter. Every call opens the wallet app for user approval.
abstract class WalletBridge {
  Future<WalletSession> authorize();

  /// Signs serialized, unsigned legacy/v0 transactions and returns the signed
  /// transactions (same order). The app submits them itself.
  Future<List<Uint8List>> signTransactions(List<Uint8List> transactions);

  Future<void> deauthorize(String authToken);
}
