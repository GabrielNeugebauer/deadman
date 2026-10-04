import 'package:deadman/solana/deadman_api.dart';
import 'package:solana/base58.dart';
import 'package:solana/solana.dart';

String addr(int seed) =>
    base58encode(List<int>.generate(32, (i) => (seed * 31 + i * 7) & 0xff));

RuleState rule({
  int seed = 10,
  int afterSecs = 10 * 86400,
  String? mint,
  AmountMode mode = AmountMode.percent,
  int amount = 10000,
  int executedAt = 0,
  int skippedAt = 0,
  int reserved = 0,
}) => RuleState(
  beneficiary: addr(seed),
  rail: Rail.solana,
  afterSecs: afterSecs,
  mint: mint,
  mode: mode,
  amount: amount,
  executedAt: executedAt,
  paid: 0,
  skippedAt: skippedAt,
  reserved: reserved,
);

VaultState vault({
  int planId = 0,
  String label = '',
  String? guard,
  List<RuleState>? rules,
  int lastPulse = 1000,
  int ownerLastSeen = 1000,
  int intervalSecs = 7 * 86400,
  int skipGraceSecs = 30 * 86400,
  int withdrawableLamports = 0,
}) => VaultState(
  address: addr(100 + planId),
  owner: addr(1),
  planId: planId,
  label: label,
  guard: guard ?? addr(2),
  guardian: null,
  intervalSecs: intervalSecs,
  lockSecs: 3600,
  skipGraceSecs: skipGraceSecs,
  lastPulse: lastPulse,
  ownerLastSeen: ownerLastSeen,
  lockedUntil: 0,
  guardianReadyAt: 0,
  totalPulses: 1,
  streak: 1,
  bestStreak: 1,
  rules: rules ?? [rule()],
  lamports: withdrawableLamports,
  withdrawableLamports: withdrawableLamports,
);

/// Records guard-key calls; everything else is unimplemented.
class FakeApi implements DeadmanApi {
  FakeApi(this.plans);

  List<VaultState> plans;
  Object? fail;
  final locked = <List<int>>[];
  final pulsed = <List<int>>[];

  @override
  Future<List<VaultState>> fetchVaults(String owner) async {
    if (fail != null) throw fail!;
    return plans;
  }

  @override
  Future<String> lockdownWithGuard(
    Ed25519HDKeyPair guard, {
    required String vaultOwner,
    required List<int> planIds,
  }) async {
    if (fail != null) throw fail!;
    locked.add(planIds);
    return 'sig';
  }

  @override
  Future<String> pulseWithGuard(
    Ed25519HDKeyPair guard, {
    required String vaultOwner,
    required List<int> planIds,
  }) async {
    pulsed.add(planIds);
    return 'sig';
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
