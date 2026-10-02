import 'dart:typed_data';

import 'package:solana/solana.dart';

/// How a rule's payout reaches the beneficiary.
///
/// On-chain, every rail pays a Solana key. For private rails that key is a
/// fresh *claim key* held by the beneficiary's Deadman app, which then routes
/// the funds onward (shielded pool or cross-chain) so the vault is never
/// publicly linked to the beneficiary's real wallet.
enum Rail { solana, cloak, zcash }

class RouteQuote {
  const RouteQuote({
    required this.rail,
    required this.amountIn,
    required this.inputMint,
    required this.estimatedOut,
    required this.expiresAt,
    this.depositAddress,
    this.raw,
  });

  final Rail rail;

  /// Base units of [inputMint] that leave the claim key.
  final int amountIn;

  /// `null` for native SOL.
  final String? inputMint;

  /// Human-readable, e.g. "0.412 ZEC".
  final String estimatedOut;
  final DateTime expiresAt;
  final String? depositAddress;
  final Object? raw;
}

/// Moves funds that landed on a claim key to their private destination.
abstract class PrivateRoute {
  Rail get rail;

  /// Mainnet-only services return false on devnet builds.
  bool get available;

  /// [destination] is a Zcash unified/shielded address or a Cloak address.
  Future<RouteQuote> quote({
    required String claimKey,
    required String? inputMint,
    required int amount,
    required String destination,
  });

  /// Signs with the claim key and submits. Returns a tracking id/signature.
  Future<String> execute({
    required Ed25519HDKeyPair claimKey,
    required RouteQuote quote,
  });

  /// Optional status polling for asynchronous routes (cross-chain swaps).
  Future<String> status(String trackingId);
}

/// Yield: convert idle SOL into a liquid staking token held in the vault.
abstract class EarnService {
  bool get available;

  /// Mint of the LST the vault holds (e.g. JitoSOL).
  String get lstMint;

  /// Current APY in basis points, for display.
  Future<int> apyBps();

  /// Unsigned swap transaction (SOL -> LST) for the owner to sign with MWA.
  /// Includes the protocol's integrator/platform fee.
  Future<Uint8List> buildStake({required String owner, required int lamports});

  /// Unsigned swap transaction (LST -> SOL).
  Future<Uint8List> buildUnstake({
    required String owner,
    required int lstAmount,
  });

  /// Submits a wallet-signed stake/unstake transaction through the swap
  /// provider (some routes need its co-signature). Returns the signature.
  Future<String> execute(Uint8List signedTx);
}
