import 'dart:typed_data';

import 'package:solana/solana.dart';

import '../rails/rails.dart';

export '../rails/rails.dart' show Rail;

enum AmountMode { fixed, percent }

/// One release instruction: after [afterSecs] of owner silence, send
/// [amount] of [mint] (null = SOL) to [beneficiary] over [rail].
class RuleSpec {
  const RuleSpec({
    required this.beneficiary,
    required this.rail,
    required this.afterSecs,
    required this.mode,
    required this.amount,
    this.mint,
  });

  /// Solana key paid on-chain. For private rails this is the beneficiary's
  /// claim key from their Deadman app.
  final String beneficiary;
  final Rail rail;
  final int afterSecs;
  final String? mint;
  final AmountMode mode;

  /// Base units for [AmountMode.fixed], basis points for [AmountMode.percent].
  final int amount;
}

class RuleState extends RuleSpec {
  const RuleState({
    required super.beneficiary,
    required super.rail,
    required super.afterSecs,
    required super.mode,
    required super.amount,
    super.mint,
    required this.executedAt,
    required this.paid,
  });

  /// Unix seconds; 0 while pending.
  final int executedAt;

  /// Net amount the beneficiary received.
  final int paid;

  bool get executed => executedAt != 0;
}

/// Mirror of the on-chain `Vault` account plus its lamport balance.
class VaultState {
  const VaultState({
    required this.address,
    required this.owner,
    required this.planId,
    required this.label,
    required this.guard,
    required this.guardian,
    required this.intervalSecs,
    required this.lockSecs,
    required this.lastPulse,
    required this.lockedUntil,
    required this.guardianReadyAt,
    required this.totalPulses,
    required this.streak,
    required this.bestStreak,
    required this.rules,
    required this.lamports,
    required this.withdrawableLamports,
  });

  final String address;
  final String owner;

  /// Owner-chosen id; an owner can hold many independent plans.
  final int planId;
  final String label;
  final String guard;
  final String? guardian;
  final int intervalSecs;
  final int lockSecs;

  /// Unix seconds.
  final int lastPulse;
  final int lockedUntil;
  final int guardianReadyAt;
  final int totalPulses;
  final int streak;
  final int bestStreak;
  final List<RuleState> rules;
  final int lamports;

  /// Lamports above the rent-exempt minimum.
  final int withdrawableLamports;

  int get pulseDue => lastPulse + intervalSecs;

  /// Every tier has released; the program rejects further check-ins.
  bool get completed => rules.every((r) => r.executed);
  int ruleDueAt(int index) => lastPulse + rules[index].afterSecs;
  bool isLocked(int now) => now < lockedUntil;

  /// Earliest pending rule deadline, or null when every rule has executed.
  int? get nextRuleDue {
    int? next;
    for (var i = 0; i < rules.length; i++) {
      if (rules[i].executed) continue;
      final due = ruleDueAt(i);
      if (next == null || due < next) next = due;
    }
    return next;
  }

  /// Due, pending, and every earlier rule for the same asset has executed.
  bool canExecute(int index, int now) {
    final r = rules[index];
    if (r.executed || now <= ruleDueAt(index)) return false;
    for (var j = 0; j < index; j++) {
      if (rules[j].mint == r.mint && !rules[j].executed) return false;
    }
    return true;
  }
}

class FeeSchedule {
  const FeeSchedule({
    required this.treasury,
    required this.feeBpsPublic,
    required this.feeBpsPrivate,
  });

  final String treasury;
  final int feeBpsPublic;
  final int feeBpsPrivate;

  int bpsFor(Rail rail) => rail == Rail.solana ? feeBpsPublic : feeBpsPrivate;
}

/// Client for the Deadman program. `build*` methods return serialized,
/// unsigned transactions (fee payer = the signer named first) to hand to
/// [WalletBridge.signTransactions]. Key-signed methods sign and send directly.
abstract class DeadmanApi {
  /// Plan vault PDA: seeds `["vault", owner, planId as u16 LE]`.
  String vaultAddressFor(String owner, int planId);

  Future<VaultState?> fetchVault(String owner, int planId);

  /// Every plan of [owner], sorted by plan id.
  Future<List<VaultState>> fetchVaults(String owner);

  /// Every Deadman vault (keepers use this to find due rules).
  Future<List<VaultState>> fetchAllVaults();

  /// Vaults where [wallet] is a rule beneficiary or the guardian.
  Future<List<VaultState>> fetchWatchedVaults(String wallet);

  Future<FeeSchedule> fetchFees();

  Future<int> balance(String address);

  /// Token balance (base units) of [owner]'s ATA for [mint]; 0 if missing.
  Future<int> tokenBalance(String owner, String mint);

  /// Creates plan [planId], funds the guard key with fee money if it holds
  /// less than that, and optionally deposits [depositLamports], in one tx.
  Future<Uint8List> buildCreateVault({
    required String owner,
    required int planId,
    required String label,
    required String guard,
    required int intervalSecs,
    required int lockSecs,
    required List<RuleSpec> rules,
    int depositLamports = 0,
  });

  Future<Uint8List> buildDeposit({
    required String owner,
    required int planId,
    required int lamports,
  });

  /// Moves [amount] of [mint] from the owner's ATA into the plan vault's ATA
  /// (created idempotently).
  Future<Uint8List> buildDepositToken({
    required String owner,
    required int planId,
    required String mint,
    required int amount,
  });

  Future<Uint8List> buildWithdrawSol({
    required String owner,
    required int planId,
    required int lamports,
  });

  Future<Uint8List> buildWithdrawToken({
    required String owner,
    required int planId,
    required String mint,
    required int amount,
  });

  Future<Uint8List> buildUpdatePolicy({
    required String owner,
    required int planId,
    required String label,
    required int intervalSecs,
    required int lockSecs,
    required List<RuleSpec> rules,
    String? guardian,
  });

  /// Rotates the guard on every listed plan in one transaction.
  Future<Uint8List> buildSetGuard({
    required String owner,
    required List<int> planIds,
    required String newGuard,
  });

  Future<Uint8List> buildPulseByOwner({
    required String owner,
    required List<int> planIds,
  });

  /// Executes rule [index] of a plan (SOL or token variant, chosen from the
  /// rule). Also creates the treasury ATA for token rules.
  Future<Uint8List> buildExecuteRule({
    required String executor,
    required String vaultOwner,
    required int planId,
    required int index,
  });

  Future<Uint8List> buildCloseVault({
    required String owner,
    required int planId,
  });

  /// Guard-key actions over several plans, one transaction, no wallet prompt.
  Future<String> pulseWithGuard(
    Ed25519HDKeyPair guard, {
    required String vaultOwner,
    required List<int> planIds,
  });

  Future<String> lockdownWithGuard(
    Ed25519HDKeyPair guard, {
    required String vaultOwner,
    required List<int> planIds,
  });

  /// Executes a rule signed by a local key (claim key or keeper).
  Future<String> executeRuleWithKey(
    Ed25519HDKeyPair executor, {
    required String vaultOwner,
    required int planId,
    required int index,
  });

  /// Submits wallet-signed transactions; returns signatures after confirmation.
  Future<List<String>> sendSigned(List<Uint8List> signedTransactions);
}
