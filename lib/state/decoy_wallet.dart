/// The wallet a duress session shows instead of the owner's: a small,
/// plausible set of plans, balances, a Family Circle entry and check-in
/// history, the same every time for the same phone. Actions taken under
/// duress change it as the real ones would, and never reach the network.
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:bip39/bip39.dart' as bip39;
import 'package:crypto/crypto.dart';
import 'package:solana/base58.dart';
import 'package:solana/solana.dart';

import '../core/config.dart';
import '../solana/deadman_api.dart';
import 'boney_skin.dart';
import 'secure_store.dart';

/// Release fee used under duress when the real schedule can't be read (the
/// program's default 2%).
const decoyFallbackFeeBps = 200;

final _decoyOwners = <String, String>{};

/// The address a duress session shows for the wallet [realOwner].
String decoyOwnerOf(String realOwner) => _decoyOwners[realOwner] ??=
    DecoyWallet._address(DecoyWallet._seedOf(realOwner), 'owner');

class DecoyWallet {
  DecoyWallet._(this._seed, int now)
    : owner = _address(_seed, 'owner'),
      guard = _address(_seed, 'guard') {
    final h = _hash(_seed, 'amounts');
    walletLamports = 412000000 + h[0] * 1730000 + h[1] * 6100;
    walletUsdc = 8000000 + h[2] * 97000;
    final family = _vault(
      planId: 0,
      label: 'Family',
      lamports: 650000000 + h[3] * 2410000,
      rules: [
        _rule(_address(_seed, 'heir-1'), afterSecs: 30 * 86400, bps: 6000),
        _rule(_address(_seed, 'heir-2'), afterSecs: 60 * 86400, bps: 10000),
      ],
      lastPulse: now - 86400 - h[4] * 300,
      pulses: 18 + h[5] % 40,
      now: now,
    );
    plans.add(family);
    tokens['${family.address}:${AppConfig.usdcMint}'] = 20000000 + h[6] * 50000;
    if (h[7].isOdd) {
      plans.add(
        _vault(
          planId: 1,
          label: 'Emergency',
          lamports: 120000000 + h[8] * 700000,
          rules: [
            _rule(_address(_seed, 'heir-3'), afterSecs: 7 * 86400, bps: 10000),
          ],
          lastPulse: now - 86400 - h[4] * 300,
          pulses: 4 + h[9] % 9,
          now: now,
        ),
      );
    }
    final parent = _address(_seed, 'circle-owner');
    watched.add(
      _withRules(
        _vault(
          planId: 0,
          label: 'For the kids',
          lamports: 1800000000 + h[10] * 3300000,
          rules: [_rule(owner, afterSecs: 90 * 86400, bps: 10000)],
          lastPulse: now - 3 * 86400 - h[11] * 120,
          pulses: 60 + h[12] % 30,
          now: now,
        ),
        owner: parent,
        address: _address(_seed, 'circle-vault'),
      ),
    );
  }

  /// Decoy for the phone of [realOwner]: derived from it one way only, so
  /// nothing in it leads back to the real wallet.
  factory DecoyWallet.forOwner(String realOwner, {required int now}) =>
      DecoyWallet._(_seedOf(realOwner), now);

  static String _seedOf(String realOwner) => 'deadman-decoy:$realOwner';

  final String _seed;

  /// The wallet address shown instead of the owner's.
  final String owner;

  /// The guard key address shown instead of this phone's.
  final String guard;

  late int walletLamports;
  late int walletUsdc;
  final plans = <VaultState>[];

  /// Plans naming [owner] (the Family Circle).
  final watched = <VaultState>[];

  /// Token balances, keyed `holder:mint`.
  final tokens = <String, int>{};

  /// NFTs in the wallet: Boney skins only (see [ownSkins]).
  final nfts = <WalletNft>[];

  /// Shows [skins] as owned, so Boney keeps the skin he wears.
  void ownSkins(Iterable<BoneySkin> skins) {
    for (final s in skins) {
      final mint = _address(_seed, 'skin-${s.id}');
      if (nfts.any((n) => n.mint == mint)) continue;
      nfts.add(
        WalletNft(
          mint: mint,
          name: 'Boney ${s.label}',
          symbol: boneySkinSymbol,
        ),
      );
    }
  }

  /// Receiving profiles "saved" under duress.
  final claims = <Rail, ClaimProfile>{};
  bool phraseConfirmed = false;

  /// Ids of every fake confirmation, newest last.
  final signatures = <String>[];
  var _signed = 0;

  static Uint8List _hash(String seed, String what) =>
      Uint8List.fromList(sha256.convert(utf8.encode('$seed/$what')).bytes);

  static String _address(String seed, String what) =>
      base58encode(_hash(seed, what));

  /// A transaction-signature-like id (64 bytes, base58) for a fake
  /// confirmation.
  String nextSignature() {
    final n = _signed++;
    final sig = base58encode([
      ..._hash(_seed, 'sig-$n-a'),
      ..._hash(_seed, 'sig-$n-b'),
    ]);
    signatures.add(sig);
    return sig;
  }

  /// The phrase shown under duress once a receiving profile exists.
  String get phrase =>
      bip39.entropyToMnemonic(_hex(_hash(_seed, 'phrase').sublist(0, 16)));

  /// This phone's "own" Cloak address under duress.
  String get cloakAddress =>
      'cloak:${_hex(_hash(_seed, 'cloak-a'))}:${_hex(_hash(_seed, 'cloak-b'))}';

  static String _hex(List<int> b) =>
      b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

  String vaultAddress(int planId) => _address(_seed, 'vault-$planId');

  static const _rent = 2450000;

  VaultState _vault({
    required int planId,
    required String label,
    required int lamports,
    required List<RuleState> rules,
    required int lastPulse,
    required int pulses,
    required int now,
    PlanKind kind = PlanKind.inheritance,
    int lockSecs = 7 * 86400,
    int startAt = 0,
    bool revocable = false,
    int periodSecs = 0,
  }) => VaultState(
    address: vaultAddress(planId),
    owner: owner,
    planId: planId,
    label: label,
    guard: guard,
    guardian: null,
    lockSecs: lockSecs,
    skipGraceSecs: 30 * 86400,
    lastPulse: lastPulse,
    ownerLastSeen: lastPulse - 9 * 86400,
    lockedUntil: 0,
    guardianReadyAt: 0,
    totalPulses: pulses,
    streak: math.min(pulses, 6 + pulses % 7),
    bestStreak: math.min(pulses, 11 + pulses % 5),
    rules: rules,
    lamports: lamports + _rent,
    withdrawableLamports: lamports,
    kind: kind,
    startAt: startAt,
    revocable: revocable,
    rentPayer: owner,
    rentPaid: _rent,
    vestPeriodSecs: periodSecs,
  );

  static RuleState _rule(
    String beneficiary, {
    required int afterSecs,
    required int bps,
  }) => RuleState(
    beneficiary: beneficiary,
    rail: Rail.solana,
    afterSecs: afterSecs,
    mode: AmountMode.percent,
    amount: bps,
    executedAt: 0,
    paid: 0,
  );

  static RuleState _ruleFrom(RuleSpec r) => RuleState(
    beneficiary: r.beneficiary,
    rail: r.rail,
    afterSecs: r.afterSecs,
    mode: r.mode,
    amount: r.amount,
    mint: r.mint,
    executedAt: 0,
    paid: 0,
  );

  static VaultState _withRules(
    VaultState v, {
    List<RuleState>? rules,
    String? owner,
    String? address,
    String? label,
    int? lamports,
    int? lastPulse,
    int? totalPulses,
    int? streak,
    int? lockSecs,
    int? skipGraceSecs,
    int? revokedAt,
  }) {
    final withdrawable = lamports ?? v.withdrawableLamports;
    final pulses = totalPulses ?? v.totalPulses;
    final s = streak ?? v.streak;
    return VaultState(
      address: address ?? v.address,
      owner: owner ?? v.owner,
      planId: v.planId,
      label: label ?? v.label,
      guard: v.guard,
      guardian: v.guardian,
      lockSecs: lockSecs ?? v.lockSecs,
      skipGraceSecs: skipGraceSecs ?? v.skipGraceSecs,
      lastPulse: lastPulse ?? v.lastPulse,
      ownerLastSeen: v.ownerLastSeen,
      lockedUntil: 0,
      guardianReadyAt: 0,
      totalPulses: pulses,
      streak: s,
      bestStreak: math.max(v.bestStreak, s),
      rules: rules ?? v.rules,
      lamports: withdrawable + v.rentPaid,
      withdrawableLamports: withdrawable,
      kind: v.kind,
      startAt: v.startAt,
      revocable: v.revocable,
      revokedAt: revokedAt ?? v.revokedAt,
      rentPayer: v.rentPayer,
      rentPaid: v.rentPaid,
      vestPeriodSecs: v.vestPeriodSecs,
    );
  }

  int _index(int planId) {
    final i = plans.indexWhere((v) => v.planId == planId);
    if (i < 0) throw StateError('No plan $planId');
    return i;
  }

  VaultState plan(int planId) => plans[_index(planId)];

  /// Base units of [mint] (null = SOL) held by [holder]; null when [holder]
  /// is not part of this wallet.
  int? balanceOf(String holder, String? mint) {
    if (mint == null) {
      if (holder == owner) return walletLamports;
      if (holder == guard) return 21000000;
      for (final v in [...plans, ...watched]) {
        if (v.address == holder) return v.lamports;
      }
      if (claims.values.any((c) => c.key.address == holder)) return 0;
      return null;
    }
    if (holder == owner && mint == AppConfig.usdcMint) return walletUsdc;
    if (holder == owner ||
        holder == guard ||
        [...plans, ...watched].any((v) => v.address == holder) ||
        claims.values.any((c) => c.key.address == holder)) {
      return tokens['$holder:$mint'] ?? 0;
    }
    return null;
  }

  void _addWallet(String? mint, int amount) {
    if (mint == null) {
      walletLamports = math.max(0, walletLamports + amount);
    } else if (mint == AppConfig.usdcMint) {
      walletUsdc = math.max(0, walletUsdc + amount);
    } else {
      final k = '$owner:$mint';
      tokens[k] = math.max(0, (tokens[k] ?? 0) + amount);
    }
  }

  void _addPlan(int planId, String? mint, int amount) {
    final i = _index(planId);
    final v = plans[i];
    if (mint == null) {
      plans[i] = _withRules(
        v,
        lamports: math.max(0, v.withdrawableLamports + amount),
      );
    } else {
      final k = '${v.address}:$mint';
      tokens[k] = math.max(0, (tokens[k] ?? 0) + amount);
    }
  }

  int nextPlanId() =>
      plans.isEmpty ? 0 : plans.map((v) => v.planId).reduce(math.max) + 1;

  void createPlan({
    required String label,
    required List<RuleSpec> rules,
    required int lockSecs,
    required int skipGraceSecs,
    required int depositLamports,
    required Map<String, int> tokenDeposits,
    required int now,
  }) {
    final id = nextPlanId();
    plans.add(
      _withRules(
        _vault(
          planId: id,
          label: label,
          lamports: 0,
          rules: [for (final r in rules) _ruleFrom(r)],
          lastPulse: now,
          pulses: 1,
          now: now,
          lockSecs: lockSecs,
        ),
        skipGraceSecs: skipGraceSecs,
      ),
    );
    _fund(id, depositLamports, tokenDeposits);
  }

  void createVesting({
    required String label,
    required int startAt,
    required bool revocable,
    required List<VestingSpec> schedules,
    required int lockSecs,
    required int periodSecs,
    required int depositLamports,
    required Map<String, int> tokenDeposits,
    required int now,
  }) {
    final id = nextPlanId();
    plans.add(
      _vault(
        planId: id,
        label: label,
        lamports: 0,
        rules: [
          for (final s in schedules)
            RuleState(
              beneficiary: s.beneficiary,
              rail: s.rail,
              afterSecs: s.cliffSecs,
              mode: AmountMode.fixed,
              amount: s.total,
              mint: s.mint,
              executedAt: 0,
              paid: 0,
              durationSecs: s.durationSecs,
            ),
        ],
        lastPulse: now,
        pulses: 0,
        now: now,
        kind: PlanKind.vesting,
        lockSecs: lockSecs,
        startAt: startAt,
        revocable: revocable,
        periodSecs: periodSecs,
      ),
    );
    _fund(id, depositLamports, tokenDeposits);
  }

  void _fund(int planId, int lamports, Map<String, int> tokenDeposits) {
    if (lamports > 0) deposit(planId, null, lamports);
    for (final e in tokenDeposits.entries) {
      deposit(planId, e.key, e.value);
    }
  }

  void deposit(int planId, String? mint, int amount) {
    _addWallet(mint, -amount);
    _addPlan(planId, mint, amount);
  }

  /// Moves [amount] of [mint] out of a plan back to the wallet (free).
  void withdraw(int planId, String? mint, int amount) {
    _addPlan(planId, mint, -amount);
    _addWallet(mint, amount);
  }

  /// Everything in the plan goes back to the wallet, plus its rent.
  void close(int planId) {
    final v = plan(planId);
    for (final k in tokens.keys.toList()) {
      if (!k.startsWith('${v.address}:')) continue;
      final mint = k.substring(v.address.length + 1);
      withdraw(planId, mint, tokens[k]!);
      tokens.remove(k);
    }
    withdraw(planId, null, v.withdrawableLamports);
    walletLamports += v.rentPaid;
    plans.removeAt(_index(planId));
  }

  void updatePolicy(
    int planId, {
    required String label,
    required int lockSecs,
    required int skipGraceSecs,
    required List<RuleSpec> rules,
    required int now,
  }) {
    final i = _index(planId);
    final v = plans[i];
    plans[i] = _withRules(
      v,
      label: label,
      lockSecs: lockSecs,
      skipGraceSecs: skipGraceSecs,
      rules: [
        for (final r in v.rules)
          if (r.settled) r,
        for (final r in rules) _ruleFrom(r),
      ],
      lastPulse: now,
    );
  }

  /// A check-in on [planIds] at [now].
  void pulse(Iterable<int> planIds, int now) {
    for (final id in planIds) {
      final i = _index(id);
      final v = plans[i];
      plans[i] = _withRules(
        v,
        lastPulse: now,
        totalPulses: v.totalPulses + 1,
        streak: v.streak + 1,
      );
    }
  }

  void revoke(int planId, int now) {
    final i = _index(planId);
    plans[i] = _withRules(plans[i], revokedAt: now);
  }

  /// Claims tier or schedule [index] of [vault] (a Family Circle plan) into
  /// the wallet.
  void claim(VaultState vault, int index, int now) {
    final i = watched.indexWhere((v) => v.address == vault.address);
    if (i < 0) return;
    final v = watched[i];
    final r = v.rules[index];
    final balance = r.mint == null
        ? v.withdrawableLamports
        : tokens['${v.address}:${r.mint}'] ?? 0;
    final gross = v.payoutGross(index, balance);
    final rules = [...v.rules];
    rules[index] = RuleState(
      beneficiary: r.beneficiary,
      rail: r.rail,
      afterSecs: r.afterSecs,
      mode: r.mode,
      amount: r.amount,
      mint: r.mint,
      executedAt: now,
      paid: gross,
    );
    watched[i] = _withRules(
      v,
      rules: rules,
      lamports: r.mint == null ? v.withdrawableLamports - gross : null,
    );
    if (r.mint != null) tokens['${v.address}:${r.mint}'] = balance - gross;
    _addWallet(r.mint, gross);
  }

  /// A decoy receiving profile for [rail], always the same key.
  Future<ClaimProfile> saveClaim(Rail rail, String destination) async {
    final key = await Ed25519HDKeyPair.fromPrivateKeyBytes(
      privateKey: _hash(_seed, 'claim-${rail.name}'),
    );
    return claims[rail] = ClaimProfile(
      rail: rail,
      key: key,
      destination: destination,
      recoverable: true,
    );
  }
}

/// The chain as a duress session sees it: [wallet]'s plans and balances;
/// public, owner-independent reads (the fee schedule) come from
/// [chain]. Never builds, signs or sends anything.
class DecoyApi implements DeadmanApi {
  DecoyApi(this.wallet, this.chain, {required this.clock});

  final DecoyWallet wallet;
  final DeadmanApi chain;
  final int Function() clock;

  @override
  String? feeToken;

  @override
  String vaultAddressFor(String owner, int planId) =>
      owner == wallet.owner ? wallet.vaultAddress(planId) : '';

  @override
  Future<VaultState?> fetchVault(String owner, int planId) async {
    for (final v in [...wallet.plans, ...wallet.watched]) {
      if (v.owner == owner && v.planId == planId) return v;
    }
    return null;
  }

  @override
  Future<int> nextFreePlanId(String owner) async => wallet.nextPlanId();

  @override
  Future<List<VaultState>> fetchVaults(String owner) async =>
      owner == wallet.owner ? [...wallet.plans] : const [];

  @override
  Future<List<int>> fetchLegacyPlanIds(String owner) async => const [];

  @override
  Future<List<VaultState>> fetchAllVaults() async => [
    ...wallet.plans,
    ...wallet.watched,
  ];

  @override
  Future<List<VaultState>> fetchWatchedVaults(String who) async =>
      who == wallet.owner ? [...wallet.watched] : const [];

  @override
  Future<FeeSchedule> fetchFees() => chain.fetchFees();

  Future<FeeSchedule> _fees() async {
    try {
      return await chain.fetchFees();
    } on Object {
      return const FeeSchedule(
        treasury: '',
        feeBpsPublic: decoyFallbackFeeBps,
        feeBpsPrivate: decoyFallbackFeeBps,
      );
    }
  }

  @override
  Future<int> balance(String address) async =>
      wallet.balanceOf(address, null) ?? (throw StateError('Unknown account'));

  @override
  Future<int> tokenBalance(String owner, String mint) async =>
      wallet.balanceOf(owner, mint) ?? (throw StateError('Unknown account'));

  @override
  Future<List<int>> tokenBalances(List<(String, String)> accounts) async => [
    for (final (o, m) in accounts) wallet.balanceOf(o, m) ?? 0,
  ];

  @override
  Future<List<WalletNft>> fetchWalletNfts(String owner) async =>
      owner == wallet.owner ? [...wallet.nfts] : const [];

  @override
  Future<WalletNft?> fetchNftMetadata(String mint) async => null;

  @override
  Future<ClaimQuote> quoteClaim({
    required String claimer,
    required String vaultOwner,
    required int planId,
    required int index,
  }) async {
    final v = await fetchVault(vaultOwner, planId);
    if (v == null) throw StateError('No plan');
    final r = v.rules[index];
    final balance = r.mint == null
        ? v.withdrawableLamports
        : wallet.tokens['${v.address}:${r.mint}'] ?? 0;
    final gross = v.payoutGross(index, balance);
    final fees = await _fees();
    return ClaimQuote(
      payer: ClaimPayer.sponsor,
      mint: r.mint,
      net: gross - fees.feeOf(gross, r.rail, r.mint),
    );
  }

  /// Anything that would build, sign or send.
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Not available');
}
