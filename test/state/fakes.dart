import 'dart:typed_data';

import 'package:deadman/rails/cloak_route.dart';
import 'package:deadman/rails/rails.dart';
import 'package:deadman/rails/zcash_route.dart';
import 'package:deadman/solana/deadman_api.dart';
import 'package:deadman/state/secure_store.dart';
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
  int durationSecs = 0,
  int released = 0,
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
  durationSecs: durationSecs,
  released: released,
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
  PlanKind kind = PlanKind.inheritance,
  int startAt = 0,
  bool revocable = false,
  int revokedAt = 0,
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
  kind: kind,
  startAt: startAt,
  revocable: revocable,
  revokedAt: revokedAt,
);

/// A vesting schedule: [total] of [mint] vesting over [duration] seconds
/// after a [cliff].
RuleState schedule({
  int seed = 20,
  String? mint,
  int total = 1000000000,
  int cliff = 0,
  int duration = 1000,
  int released = 0,
  int executedAt = 0,
}) => rule(
  seed: seed,
  afterSecs: cliff,
  mint: mint,
  mode: AmountMode.fixed,
  amount: total,
  durationSecs: duration,
  released: released,
  executedAt: executedAt,
);

VaultState vestingVault({
  int planId = 5,
  List<RuleState>? schedules,
  int startAt = 1000,
  bool revocable = true,
  int revokedAt = 0,
  int withdrawableLamports = 0,
  String? guard,
}) => vault(
  planId: planId,
  kind: PlanKind.vesting,
  rules: schedules ?? [schedule()],
  startAt: startAt,
  revocable: revocable,
  revokedAt: revokedAt,
  withdrawableLamports: withdrawableLamports,
  guard: guard,
);

/// Records guard-key calls; everything else is unimplemented.
class FakeApi implements DeadmanApi {
  FakeApi(this.plans);

  List<VaultState> plans;
  Object? fail;
  final balances = <String, int>{};

  /// Keyed by `owner:mint`.
  final tokens = <String, int>{};
  final locked = <List<int>>[];
  final pulsed = <List<int>>[];

  @override
  String? feeToken;

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
  Future<int> balance(String address) async => balances[address] ?? 0;

  @override
  Future<int> tokenBalance(String owner, String mint) async =>
      tokens['$owner:$mint'] ?? 0;

  /// Every batched balance lookup, in call order.
  final balanceBatches = <List<(String, String)>>[];

  @override
  Future<List<int>> tokenBalances(List<(String, String)> accounts) async {
    balanceBatches.add(accounts);
    return [for (final (o, m) in accounts) tokens['$o:$m'] ?? 0];
  }

  /// Token deposits of each [buildCreateVault] call.
  final createdDeposits = <Map<String, int>>[];

  @override
  Future<Uint8List> buildCreateVault({
    required String owner,
    required int planId,
    required String label,
    required String guard,
    required int intervalSecs,
    required int lockSecs,
    required int skipGraceSecs,
    required List<RuleSpec> rules,
    int depositLamports = 0,
    Map<String, int> tokenDeposits = const {},
  }) async {
    createdDeposits.add(tokenDeposits);
    return Uint8List(0);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

var _notes = 0;

CloakNote note(int amount, {String? mint, bool spent = false}) => CloakNote(
  commitment: (++_notes).toRadixString(16).padLeft(64, '0'),
  amount: amount,
  mint: mint,
  blinding: 'ab' * 32,
  spent: spent,
);

Future<Ed25519HDKeyPair> keyPair(int seed) =>
    Ed25519HDKeyPair.fromPrivateKeyBytes(privateKey: List.filled(32, seed));

/// Claim profiles held in memory.
class FakeSecureStore implements SecureStore {
  FakeSecureStore([List<ClaimProfile> profiles = const []])
    : claims = {for (final p in profiles) p.rail: p};

  final Map<Rail, ClaimProfile> claims;

  @override
  Future<ClaimProfile?> loadClaim(Rail rail) async => claims[rail];

  @override
  Future<List<ClaimProfile>> loadClaims() async => [
    for (final r in [Rail.cloak, Rail.zcash]) ?claims[r],
  ];

  @override
  Future<ClaimProfile> saveClaim(Rail rail, String destination) async =>
      claims[rail] = ClaimProfile(
        rail: rail,
        key: claims[rail]?.key ?? await keyPair(40 + rail.index),
        destination: destination,
      );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

typedef QuoteCall = ({String claimKey, String? mint, int amount, String to});

/// 1Click without the network: quotes echo the request, [track] replays
/// [statuses].
class FakeZcashRoute implements ZcashRoute {
  FakeZcashRoute({this.live = true});

  bool live;
  Object? fail;
  final spendableBy = <String?, int>{};
  final quotes = <QuoteCall>[];
  final estimates = <QuoteCall>[];
  final executed = <RouteQuote>[];
  Object? executeFail;
  List<String> statuses = const ['PROCESSING', 'SUCCESS'];
  final tracked = <String>[];
  static final depositAddress = addr(77);

  @override
  Rail get rail => Rail.zcash;

  @override
  bool get available => live;

  @override
  Future<int> spendable({
    required String claimKey,
    required String? inputMint,
  }) async => spendableBy[inputMint] ?? 0;

  RouteQuote _quote(QuoteCall c, {required bool dry}) => RouteQuote(
    rail: Rail.zcash,
    amountIn: c.amount,
    inputMint: c.mint,
    estimatedOut: '0.0034 ZEC',
    expiresAt: DateTime.now().add(const Duration(minutes: 30)),
    depositAddress: dry ? null : depositAddress,
    raw: {
      'quote': {
        'amountInUsd': '5.00',
        'amountOutUsd': '4.50',
        'withdrawFee': '32000',
      },
    },
  );

  @override
  Future<RouteQuote> quote({
    required String claimKey,
    required String? inputMint,
    required int amount,
    required String destination,
  }) async {
    if (fail != null) throw fail!;
    final c = (
      claimKey: claimKey,
      mint: inputMint,
      amount: amount,
      to: destination,
    );
    quotes.add(c);
    return _quote(c, dry: false);
  }

  @override
  Future<RouteQuote> estimate({
    required String claimKey,
    required String? inputMint,
    required int amount,
    required String destination,
  }) async {
    if (fail != null) throw fail!;
    final c = (
      claimKey: claimKey,
      mint: inputMint,
      amount: amount,
      to: destination,
    );
    estimates.add(c);
    return _quote(c, dry: true);
  }

  @override
  Future<String> execute({
    required Ed25519HDKeyPair claimKey,
    required RouteQuote quote,
  }) async {
    executed.add(quote);
    if (executeFail != null) throw executeFail!;
    return quote.depositAddress!;
  }

  @override
  Future<String> status(String trackingId) async => statuses.last;

  @override
  Stream<String> track(
    String depositAddress, {
    Duration every = const Duration(seconds: 5),
    Duration maxEvery = const Duration(minutes: 2),
  }) {
    tracked.add(depositAddress);
    return Stream.fromIterable(statuses);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Cloak without a WebView or the network.
class FakeCloakRoute implements CloakRoute {
  FakeCloakRoute({this.live = true});

  static final ownAddress = 'cloak:${'1' * 64}:${'2' * 64}';

  bool live;
  Object? fail;
  Object? executeFail;
  final quoted = <int>[];

  @override
  final int solFeeReserveLamports = 0;

  @override
  final int splFeeReserveLamports = CloakRoute.defaultSplFeeReserveLamports;
  List<CloakNote> notes = const [];
  final executed = <RouteQuote>[];
  final withdrawals = <({List<CloakNote> notes, String destination})>[];
  final statusCalls = <String>[];
  List<String> statuses = const ['PENDING', 'SUCCESS'];
  var _status = 0;
  int scans = 0;

  @override
  Rail get rail => Rail.cloak;

  @override
  bool get available => live;

  @override
  String? get unavailableReason => live ? null : 'mainnet only';

  @override
  Future<RouteQuote> quote({
    required String claimKey,
    required String? inputMint,
    required int amount,
    required String destination,
  }) async {
    if (fail != null) throw fail!;
    quoted.add(amount);
    final shielded = destination.startsWith('cloak:');
    return RouteQuote(
      rail: Rail.cloak,
      amountIn: amount,
      inputMint: inputMint,
      estimatedOut: shielded ? 'shielded' : 'after exit fee',
      expiresAt: DateTime.now().add(const Duration(minutes: 10)),
      raw: CloakQuoteData(
        claimKey: claimKey,
        shielded: shielded ? CloakAddress.parse(destination) : null,
        publicRecipient: shielded ? null : destination,
      ),
    );
  }

  @override
  Future<String> execute({
    required Ed25519HDKeyPair claimKey,
    required RouteQuote quote,
  }) async {
    executed.add(quote);
    if (executeFail != null) throw executeFail!;
    return 'cloakSig';
  }

  @override
  Future<CloakAddress> receiveAddressFor(Ed25519HDKeyPair claimKey) async =>
      CloakAddress.parse(ownAddress);

  @override
  Future<String> status(String trackingId) async {
    statusCalls.add(trackingId);
    return statuses[_status < statuses.length
        ? _status++
        : statuses.length - 1];
  }

  @override
  Future<List<CloakNote>> scanReceived({
    required Ed25519HDKeyPair claimKey,
  }) async {
    scans++;
    if (fail != null) throw fail!;
    return notes;
  }

  @override
  Future<String> withdrawReceived({
    required Ed25519HDKeyPair claimKey,
    required List<CloakNote> notes,
    required String destination,
  }) async {
    withdrawals.add((notes: notes, destination: destination));
    return 'withdrawSig';
  }

  @override
  Future<CloakSelfTest> selfTest({String? mint}) async {
    if (fail != null) throw fail!;
    return const CloakSelfTest(
      download: Duration(milliseconds: 1200),
      prove: Duration(milliseconds: 5600),
      total: Duration(milliseconds: 6900),
      steps: [],
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
