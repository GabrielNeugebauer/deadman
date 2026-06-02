import 'dart:typed_data';

import 'package:solana/solana.dart';

enum VaultStatus { active, triggered }

class Heir {
  const Heir({required this.wallet, required this.bps, this.claimedSol = false});

  final String wallet;
  final int bps;
  final bool claimedSol;
}

/// Mirror of the on-chain `Vault` account plus its lamport balance.
class VaultState {
  const VaultState({
    required this.address,
    required this.owner,
    required this.guard,
    required this.guardian,
    required this.intervalSecs,
    required this.graceSecs,
    required this.lockSecs,
    required this.lastPulse,
    required this.lockedUntil,
    required this.plusUntil,
    required this.triggeredAt,
    required this.solAtTrigger,
    required this.totalPulses,
    required this.streak,
    required this.bestStreak,
    required this.status,
    required this.heirs,
    required this.lamports,
    required this.withdrawableLamports,
  });

  final String address;
  final String owner;
  final String guard;
  final String? guardian;
  final int intervalSecs;
  final int graceSecs;
  final int lockSecs;

  /// Unix seconds.
  final int lastPulse;
  final int lockedUntil;
  final int plusUntil;
  final int triggeredAt;
  final int solAtTrigger;
  final int totalPulses;
  final int streak;
  final int bestStreak;
  final VaultStatus status;
  final List<Heir> heirs;
  final int lamports;

  /// Lamports above the rent-exempt minimum.
  final int withdrawableLamports;

  int get pulseDue => lastPulse + intervalSecs;
  int get deadline => lastPulse + intervalSecs + graceSecs;
  bool isLocked(int now) => now < lockedUntil;
  bool isPlus(int now) => now < plusUntil;
  bool canTrigger(int now) => status == VaultStatus.active && now > deadline;
}

/// Client for the Deadman program. `build*` methods return serialized,
/// unsigned transactions (fee payer = the signer named first) to hand to
/// [WalletBridge.signTransactions]. Guard-key methods sign and send directly.
abstract class DeadmanApi {
  String vaultAddressFor(String owner);

  Future<VaultState?> fetchVault(String owner);

  /// Vaults where [wallet] is an heir or the guardian ("Family Circle").
  Future<List<VaultState>> fetchWatchedVaults(String wallet);

  Future<int> balance(String address);

  /// Creates the vault, funds the guard key with fee money, and optionally
  /// deposits [depositLamports], in one transaction.
  Future<Uint8List> buildCreateVault({
    required String owner,
    required String guard,
    required int intervalSecs,
    required int graceSecs,
    required int lockSecs,
    required List<Heir> heirs,
    int depositLamports = 0,
  });

  Future<Uint8List> buildDeposit({required String owner, required int lamports});

  Future<Uint8List> buildWithdrawSol({required String owner, required int lamports});

  Future<Uint8List> buildUpdatePolicy({
    required String owner,
    required int intervalSecs,
    required int graceSecs,
    required int lockSecs,
    required List<Heir> heirs,
    String? guardian,
  });

  Future<Uint8List> buildSetGuard({required String owner, required String newGuard});

  /// Pays [months] of Deadman Plus in SKR.
  Future<Uint8List> buildSubscribe({required String owner, required int months});

  Future<Uint8List> buildPulseByOwner({required String owner});

  Future<Uint8List> buildTrigger({required String caller, required String vaultOwner});

  Future<Uint8List> buildClaimSol({required String heir, required String vaultOwner});

  Future<Uint8List> buildCloseVault({required String owner});

  /// Guard-key actions: signed locally, no wallet prompt.
  Future<String> pulseWithGuard(Ed25519HDKeyPair guard, {required String vaultOwner});

  Future<String> lockdownWithGuard(Ed25519HDKeyPair guard, {required String vaultOwner});

  /// Submits wallet-signed transactions; returns signatures after confirmation.
  Future<List<String>> sendSigned(List<Uint8List> signedTransactions);
}
