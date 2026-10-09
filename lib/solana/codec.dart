import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:solana/base58.dart';
import 'package:solana/encoder.dart';
import 'package:solana/solana.dart';

import '../core/config.dart';
import 'deadman_api.dart';

/// Anchor discriminators, copied from `onchain/target/idl/deadman.json`.
abstract final class Disc {
  static const createPlan = [77, 43, 141, 254, 212, 118, 41, 186];
  static const updatePlan = [119, 112, 58, 60, 76, 205, 1, 100];
  static const setGuard = [250, 44, 173, 235, 219, 76, 36, 198];
  static const pulse = [192, 224, 96, 191, 190, 177, 63, 34];
  static const lockdown = [21, 66, 102, 35, 233, 188, 139, 9];
  static const unlock = [101, 155, 40, 21, 158, 189, 56, 203];
  static const closeVault = [141, 103, 17, 126, 72, 75, 29, 29];
  static const withdrawSol = [145, 131, 74, 136, 65, 137, 42, 38];
  static const withdrawToken = [136, 235, 181, 5, 101, 109, 57, 81];
  static const executeSolRule = [27, 74, 220, 147, 58, 73, 241, 103];
  static const executeTokenRule = [172, 93, 237, 201, 225, 26, 97, 140];
  static const skipRule = [240, 82, 139, 70, 215, 222, 129, 174];
  static const createVesting = [135, 184, 171, 156, 197, 162, 246, 44];
  static const revokeVesting = [12, 252, 252, 168, 39, 101, 98, 9];
  static const releaseVestedSol = [136, 188, 48, 45, 14, 211, 200, 228];
  static const releaseVestedToken = [50, 241, 129, 168, 233, 106, 179, 16];
  static const recoverLegacyVault = [202, 5, 20, 4, 206, 216, 105, 134];
  static const initConfig = [23, 235, 115, 232, 168, 96, 1, 231];
  static const setConfig = [108, 158, 154, 175, 212, 98, 52, 66];
  static const proposeAdmin = [121, 214, 199, 212, 87, 39, 117, 234];
  static const acceptAdmin = [112, 42, 45, 90, 116, 181, 13, 170];

  static const configAccount = [155, 12, 170, 224, 30, 250, 204, 130];
  static const vaultAccount = [211, 8, 232, 43, 2, 152, 117, 119];

  static const feeBurnedEvent = [145, 91, 45, 171, 189, 224, 44, 218];
}

/// `Vault::SPACE` (8 + `Vault::INIT_SPACE`). A Vault account of any other
/// size is in an older layout (see `recover_legacy_vault`).
const vaultAccountSize = 1390;

/// Mirrors `onchain/programs/deadman/src/constants.rs`.
abstract final class Limits {
  static const maxRules = 8;
  static const maxLabelBytes = 32;
  static const bpsDenominator = 10000;
  static const maxFeeBps = 500;
  static const minRuleDelaySecs = 60;
  static const maxRuleDelaySecs = 3 * 366 * 86400;
  static const minSkipGraceSecs = 60;
  static const maxSkipGraceSecs = 366 * 86400;
  static const minLockSecs = 60;
  static const maxLockSecs = 30 * 86400;
  static const cloakGasStipend = 12000000;
  static const zcashGasStipend = 3000000;

  /// SOL a token payout on [rail] tops a claim key holding less up with
  /// (`Rail::gas_stipend`), when the vault has that much spare.
  static int gasStipend(Rail rail) => switch (rail) {
    Rail.solana => 0,
    Rail.cloak => cloakGasStipend,
    Rail.zcash => zcashGasStipend,
  };
  static const maxVestSecs = 20 * 366 * 86400;
  static const maxVestStartSkewSecs = 366 * 86400;
  static const minVestPeriodSecs = 60;
}

const systemProgramId = SystemProgram.programId;
const tokenProgramId = TokenProgram.programId;
const token2022ProgramId = Token2022Program.programId;
const ataProgramId = AssociatedTokenAccountProgram.programId;
const tokenMetadataProgramId = 'metaqbxxUerdq28cj1RbAWkYQm3ybzjb6a8bt518x1s';

/// All-zero key (`Pubkey::default()`).
const defaultPubkey = '11111111111111111111111111111111';

typedef Pda = ({String address, int bump});

final _pdaCache = <String, Pda>{};

/// Synchronous, memoized `findProgramAddress` (the package version is async).
Pda findPda(List<List<int>> seeds, {String programId = AppConfig.programId}) =>
    _pdaCache['$programId:${seeds.map(base58encode).join(':')}'] ??= _findPda(
      seeds,
      programId,
    );

Pda _findPda(List<List<int>> seeds, String programId) {
  final pid = Ed25519HDPublicKey.fromBase58(programId).bytes;
  final prefix = [for (final s in seeds) ...s];
  const marker = 'ProgramDerivedAddress';
  for (var bump = 255; bump >= 0; bump--) {
    final hash = sha256.convert([
      ...prefix,
      bump,
      ...pid,
      ...marker.codeUnits,
    ]).bytes;
    if (!isPointOnEd25519Curve(hash)) {
      return (address: base58encode(hash), bump: bump);
    }
  }
  throw StateError('No viable bump for PDA');
}

/// Plan vault: seeds `["vault", owner, planId as u16 LE]`.
Pda vaultPda(String owner, int planId) => findPda([
  utf8.encode('vault'),
  Ed25519HDPublicKey.fromBase58(owner).bytes,
  (BorshWriter()..u16(planId)).toBytes(),
]);

/// Whether [label] fits the on-chain `MAX_LABEL_LEN` (UTF-8 bytes).
bool labelFits(String label) =>
    utf8.encode(label).length <= Limits.maxLabelBytes;

Pda configPda() => findPda([utf8.encode('config')]);

/// Token Metadata account of [mint]: seeds `["metadata", program, mint]`
/// under the Token Metadata program.
String metadataPda(String mint) => findPda([
  utf8.encode('metadata'),
  Ed25519HDPublicKey.fromBase58(tokenMetadataProgramId).bytes,
  Ed25519HDPublicKey.fromBase58(mint).bytes,
], programId: tokenMetadataProgramId).address;

/// Classic SPL Token associated token account of [owner] for [mint].
String ataAddress(String owner, String mint) => findPda([
  Ed25519HDPublicKey.fromBase58(owner).bytes,
  Ed25519HDPublicKey.fromBase58(tokenProgramId).bytes,
  Ed25519HDPublicKey.fromBase58(mint).bytes,
], programId: ataProgramId).address;

class BorshWriter {
  final _b = BytesBuilder(copy: false);

  void bytes(List<int> v) => _b.add(v);
  void u8(int v) => _b.addByte(_range(v, 0, 0xff, 'u8'));
  void u16(int v) => _num(
    2,
    (d) => d.setUint16(0, _range(v, 0, 0xffff, 'u16'), Endian.little),
  );
  void u32(int v) => _num(
    4,
    (d) => d.setUint32(0, _range(v, 0, 0xffffffff, 'u32'), Endian.little),
  );
  void i64(int v) => _num(8, (d) => _setInt64(d, v));

  /// Dart ints are signed 64-bit, so only 0..2^63-1 is representable
  /// (0..2^53 exactly when compiled to JavaScript).
  void u64(int v) => _num(8, (d) => _setInt64(d, _range(v, 0, null, 'u64')));
  void pubkey(String v) => _b.add(Ed25519HDPublicKey.fromBase58(v).bytes);

  /// Borsh `String`: u32 byte length + UTF-8.
  void string(String v) {
    final bytes = utf8.encode(v);
    u32(bytes.length);
    _b.add(bytes);
  }

  void optionPubkey(String? v) {
    if (v == null) {
      u8(0);
    } else {
      u8(1);
      pubkey(v);
    }
  }

  /// `Vec<RuleInput>`.
  void ruleInputs(List<RuleSpec> rules) {
    u32(rules.length);
    for (final r in rules) {
      pubkey(r.beneficiary);
      u8(r.rail.index);
      i64(r.afterSecs);
      optionPubkey(r.mint);
      u8(r.mode.index);
      u64(r.amount);
    }
  }

  /// `Vec<VestingInput>`.
  void vestingInputs(List<VestingSpec> schedules) {
    u32(schedules.length);
    for (final v in schedules) {
      pubkey(v.beneficiary);
      u8(v.rail.index);
      optionPubkey(v.mint);
      u64(v.total);
      i64(v.cliffSecs);
      i64(v.durationSecs);
    }
  }

  Uint8List toBytes() => _b.toBytes();

  /// As two 32-bit halves: ByteData's 64-bit accessors throw when compiled
  /// to JavaScript.
  static void _setInt64(ByteData d, int v) {
    final lo = v & 0xffffffff;
    d
      ..setUint32(0, lo, Endian.little)
      ..setUint32(4, ((v - lo) ~/ 0x100000000) & 0xffffffff, Endian.little);
  }

  void _num(int len, void Function(ByteData) set) {
    final d = ByteData(len);
    set(d);
    _b.add(d.buffer.asUint8List());
  }

  static int _range(int v, int min, int? max, String type) {
    if (v < min || (max != null && v > max)) {
      throw ArgumentError.value(v, type, 'out of range');
    }
    return v;
  }
}

class BorshReader {
  BorshReader(List<int> data)
    : _d = ByteData.sublistView(Uint8List.fromList(data));

  final ByteData _d;
  int offset = 0;

  int u8() => _d.getUint8(_take(1));
  int u16() => _d.getUint16(_take(2), Endian.little);
  int u32() => _d.getUint32(_take(4), Endian.little);
  int i64() => _int64(signed: true);
  int u64() => _int64(signed: false);

  /// Same results as getInt64/getUint64 on native platforms, which
  /// JavaScript lacks.
  int _int64({required bool signed}) {
    final at = _take(8);
    final lo = _d.getUint32(at, Endian.little);
    final hi = signed
        ? _d.getInt32(at + 4, Endian.little)
        : _d.getUint32(at + 4, Endian.little);
    return hi * 0x100000000 + lo;
  }

  bool boolean() => switch (u8()) {
    0 => false,
    1 => true,
    final b => throw FormatException('Bad bool $b'),
  };

  String pubkey() {
    final start = _take(32);
    return base58encode(_d.buffer.asUint8List(_d.offsetInBytes + start, 32));
  }

  String string() {
    final len = u32();
    final start = _take(len);
    return utf8.decode(_d.buffer.asUint8List(_d.offsetInBytes + start, len));
  }

  String? optionPubkey() => switch (u8()) {
    0 => null,
    1 => pubkey(),
    final t => throw FormatException('Bad Option tag $t'),
  };

  T enumOf<T>(List<T> values, String name) {
    final i = u8();
    if (i >= values.length) throw FormatException('Bad $name $i');
    return values[i];
  }

  int _take(int n) {
    if (offset + n > _d.lengthInBytes) {
      throw const FormatException('Account data too short');
    }
    final at = offset;
    offset += n;
    return at;
  }
}

Uint8List encodeCreatePlan({
  required int planId,
  required String label,
  required String guard,
  required int lockSecs,
  required int skipGraceSecs,
  required List<RuleSpec> rules,
}) =>
    (BorshWriter()
          ..bytes(Disc.createPlan)
          ..u16(planId)
          ..string(label)
          ..pubkey(guard)
          ..i64(lockSecs)
          ..i64(skipGraceSecs)
          ..ruleInputs(rules))
        .toBytes();

Uint8List encodeCreateVesting({
  required int planId,
  required String label,
  required String guard,
  required int lockSecs,
  required int startAt,
  required bool revocable,
  required List<VestingSpec> schedules,
  int periodSecs = 0,
}) =>
    (BorshWriter()
          ..bytes(Disc.createVesting)
          ..u16(planId)
          ..string(label)
          ..pubkey(guard)
          ..i64(lockSecs)
          ..i64(startAt)
          ..u8(revocable ? 1 : 0)
          ..vestingInputs(schedules)
          ..i64(periodSecs))
        .toBytes();

Uint8List encodeUpdatePlan({
  required String label,
  required int lockSecs,
  required int skipGraceSecs,
  required List<RuleSpec> rules,
  String? guardian,
}) =>
    (BorshWriter()
          ..bytes(Disc.updatePlan)
          ..string(label)
          ..i64(lockSecs)
          ..i64(skipGraceSecs)
          ..ruleInputs(rules)
          ..optionPubkey(guardian))
        .toBytes();

Uint8List encodeSetGuard(String newGuard) =>
    (BorshWriter()
          ..bytes(Disc.setGuard)
          ..pubkey(newGuard))
        .toBytes();

Uint8List encodeWithdrawSol(int lamports) =>
    (BorshWriter()
          ..bytes(Disc.withdrawSol)
          ..u64(lamports))
        .toBytes();

Uint8List encodeWithdrawToken(int amount) =>
    (BorshWriter()
          ..bytes(Disc.withdrawToken)
          ..u64(amount))
        .toBytes();

Uint8List encodeExecuteRule(int index, {required bool token}) =>
    (BorshWriter()
          ..bytes(token ? Disc.executeTokenRule : Disc.executeSolRule)
          ..u8(index))
        .toBytes();

Uint8List encodeReleaseVested(int index, {required bool token}) =>
    (BorshWriter()
          ..bytes(token ? Disc.releaseVestedToken : Disc.releaseVestedSol)
          ..u8(index))
        .toBytes();

Uint8List encodeSkipRule(int index) =>
    (BorshWriter()
          ..bytes(Disc.skipRule)
          ..u8(index))
        .toBytes();

Uint8List encodeRecoverLegacyVault(int planId) =>
    (BorshWriter()
          ..bytes(Disc.recoverLegacyVault)
          ..u16(planId))
        .toBytes();

/// Tiers `update_plan` keeps as history in front of the new rules: every
/// paid or skipped one. A fully released plan cannot be updated at all.
int policyHistoryCount(VaultState vault) =>
    vault.rules.where((r) => r.settled).length;

/// Mirrors `Vault::apply_policy` (and the guard checks of `create_plan`).
/// Returns the program error code the chain would raise, or null if valid.
/// Pass [guard] only when known; the chain also checks it on update.
/// [historyCount] is [policyHistoryCount] of the current vault on update
/// (0 on create): history plus [rules] must fit in [Limits.maxRules].
int? policyError({
  required String owner,
  required String vault,
  String? guard,
  required int lockSecs,
  required int skipGraceSecs,
  required List<RuleSpec> rules,
  int historyCount = 0,
  String? guardian,
}) {
  if (lockSecs < Limits.minLockSecs ||
      lockSecs > Limits.maxLockSecs ||
      skipGraceSecs < Limits.minSkipGraceSecs ||
      skipGraceSecs > Limits.maxSkipGraceSecs) {
    return 6002;
  }
  if (rules.isEmpty || historyCount + rules.length > Limits.maxRules) {
    return 6003;
  }
  for (var i = 0; i < rules.length; i++) {
    final r = rules[i];
    final amountOk = switch (r.mode) {
      AmountMode.fixed => r.amount > 0,
      AmountMode.percent => r.amount >= 1 && r.amount <= Limits.bpsDenominator,
    };
    if (!amountOk ||
        r.afterSecs < Limits.minRuleDelaySecs ||
        r.afterSecs > Limits.maxRuleDelaySecs ||
        (i > 0 && rules[i - 1].afterSecs > r.afterSecs) ||
        r.beneficiary == defaultPubkey ||
        r.beneficiary == owner ||
        r.beneficiary == guard ||
        r.beneficiary == vault ||
        r.mint == defaultPubkey) {
      return 6003;
    }
  }
  if (guardian != null &&
      (guardian == defaultPubkey ||
          guardian == owner ||
          guardian == guard ||
          rules.any((r) => r.beneficiary == guardian))) {
    return 6004;
  }
  return null;
}

/// Mirrors the checks of `create_vesting` (`Vault::apply_vesting` plus the
/// guard and lock bounds). Returns the program error code the chain would
/// raise, or null if valid. [now] is unix seconds.
int? vestingError({
  required String owner,
  required String vault,
  required String guard,
  required int lockSecs,
  required int startAt,
  required List<VestingSpec> schedules,
  required int now,
  int periodSecs = 0,
}) {
  if (guard == defaultPubkey || guard == owner) return 6005;
  if (lockSecs < Limits.minLockSecs || lockSecs > Limits.maxLockSecs) {
    return 6002;
  }
  if (schedules.isEmpty ||
      schedules.length > Limits.maxRules ||
      startAt < now - Limits.maxVestStartSkewSecs ||
      startAt > now + Limits.maxVestStartSkewSecs) {
    return 6022;
  }
  for (final v in schedules) {
    if (v.total <= 0 ||
        v.cliffSecs < 0 ||
        v.durationSecs <= 0 ||
        v.cliffSecs > v.durationSecs ||
        v.durationSecs > Limits.maxVestSecs ||
        v.beneficiary == defaultPubkey ||
        v.beneficiary == owner ||
        v.beneficiary == guard ||
        v.beneficiary == vault ||
        v.mint == defaultPubkey) {
      return 6022;
    }
    if (periodSecs != 0 &&
        (periodSecs < Limits.minVestPeriodSecs ||
            periodSecs > v.durationSecs)) {
      return 6022;
    }
  }
  return null;
}

bool hasDiscriminator(List<int> data, List<int> disc) {
  if (data.length < disc.length) return false;
  for (var i = 0; i < disc.length; i++) {
    if (data[i] != disc[i]) return false;
  }
  return true;
}

VaultState decodeVault(
  List<int> data, {
  required String address,
  required int lamports,
  required int rentExemptMinimum,
}) {
  if (!hasDiscriminator(data, Disc.vaultAccount)) {
    throw const FormatException('Not a Vault account');
  }
  final r = BorshReader(data)..offset = 8;
  final owner = r.pubkey();
  final planId = r.u16();
  final guard = r.pubkey();
  final guardian = r.optionPubkey();
  r.i64(); // _reserved_interval: legacy bytes, never read.
  final lockSecs = r.i64();
  final skipGraceSecs = r.i64();
  final lastPulse = r.i64();
  final ownerLastSeen = r.i64();
  final lockedUntil = r.i64();
  final guardianReadyAt = r.i64();
  final totalPulses = r.u64();
  final streak = r.u32();
  final bestStreak = r.u32();
  final kind = r.enumOf(PlanKind.values, 'PlanKind');
  final startAt = r.i64();
  final revocable = r.boolean();
  final revokedAt = r.i64();
  final rentPayer = r.pubkey();
  final rentPaid = r.u64();
  final count = r.u32();
  if (count > Limits.maxRules) throw FormatException('Bad rule count $count');
  final rules = List.generate(
    count,
    (_) => RuleState(
      beneficiary: r.pubkey(),
      rail: r.enumOf(Rail.values, 'Rail'),
      afterSecs: r.i64(),
      mint: r.optionPubkey(),
      mode: r.enumOf(AmountMode.values, 'AmountMode'),
      amount: r.u64(),
      executedAt: r.i64(),
      paid: r.u64(),
      skippedAt: r.i64(),
      reserved: r.u64(),
      durationSecs: r.i64(),
      released: r.u64(),
    ),
  );
  final label = r.string();
  r.u8(); // bump
  r.u8(); // stipend_paid
  final vestPeriodSecs = r.i64(); // 55 reserved (zero) bytes follow.
  final rentReserve = rentPaid > rentExemptMinimum
      ? rentPaid
      : rentExemptMinimum;
  return VaultState(
    address: address,
    owner: owner,
    planId: planId,
    label: label,
    guard: guard,
    guardian: guardian,
    lockSecs: lockSecs,
    skipGraceSecs: skipGraceSecs,
    lastPulse: lastPulse,
    ownerLastSeen: ownerLastSeen,
    lockedUntil: lockedUntil,
    guardianReadyAt: guardianReadyAt,
    totalPulses: totalPulses,
    streak: streak,
    bestStreak: bestStreak,
    rules: rules,
    lamports: lamports,
    withdrawableLamports: lamports > rentReserve ? lamports - rentReserve : 0,
    kind: kind,
    startAt: startAt,
    revocable: revocable,
    revokedAt: revokedAt,
    rentPayer: rentPayer,
    rentPaid: rentPaid,
    vestPeriodSecs: vestPeriodSecs,
  );
}

class DeadmanConfig {
  const DeadmanConfig({
    required this.admin,
    required this.fees,
    this.pendingAdmin,
    this.migrated = true,
  });

  final String admin;
  final FeeSchedule fees;

  /// Proposed next admin until it calls `accept_admin`; null = none.
  final String? pendingAdmin;

  /// False for the first, 77-byte layout: payouts fail on chain until the
  /// admin runs `set_config` once, which reallocates it.
  final bool migrated;
}

/// `Config::SPACE` (8 + `Config::INIT_SPACE`).
const configAccountSize = 209;

/// The first `Config` layout (admin, treasury, two fee rates, bump).
const configV1AccountSize = 77;

/// Decodes `Config`, current or first layout (the latter has no SKR rate).
DeadmanConfig decodeConfig(List<int> data) {
  if (!hasDiscriminator(data, Disc.configAccount)) {
    throw const FormatException('Not a Config account');
  }
  final r = BorshReader(data)..offset = 8;
  final admin = r.pubkey();
  final treasury = r.pubkey();
  final feeBpsPublic = r.u16();
  final feeBpsPrivate = r.u16();
  r.u8(); // bump
  if (data.length < configAccountSize) {
    return DeadmanConfig(
      admin: admin,
      fees: FeeSchedule(
        treasury: treasury,
        feeBpsPublic: feeBpsPublic,
        feeBpsPrivate: feeBpsPrivate,
      ),
      migrated: false,
    );
  }
  final skrMint = r.pubkey();
  final feeBpsSkr = r.u16();
  final skrBurnBps = r.u16();
  if (skrBurnBps > Limits.bpsDenominator) {
    throw FormatException('Bad skr_burn_bps $skrBurnBps');
  }
  final pending = r.pubkey();
  return DeadmanConfig(
    admin: admin,
    fees: FeeSchedule(
      treasury: treasury,
      feeBpsPublic: feeBpsPublic,
      feeBpsPrivate: feeBpsPrivate,
      skrMint: skrMint == defaultPubkey ? null : skrMint,
      feeBpsSkr: feeBpsSkr,
      skrBurnBps: skrBurnBps,
    ),
    pendingAdmin: pending == defaultPubkey ? null : pending,
  );
}

/// `decimals` of an SPL mint account.
int decodeMintDecimals(List<int> data) {
  if (data.length < 82) throw const FormatException('Not a mint account');
  return data[44];
}

/// `supply` of an SPL mint account.
int decodeMintSupply(List<int> data) {
  if (data.length < 82) throw const FormatException('Not a mint account');
  return (BorshReader(data)..offset = 36).u64();
}

/// `amount` of an SPL token account.
int decodeTokenAmount(List<int> data) {
  if (data.length < 165) {
    throw const FormatException('Not a token account');
  }
  return (BorshReader(data)..offset = 64).u64();
}

/// Whether an SPL token account is frozen (`state` == 2).
bool decodeTokenFrozen(List<int> data) {
  if (data.length < 165) {
    throw const FormatException('Not a token account');
  }
  return data[108] == 2;
}

/// Token Metadata `TokenStandard`.
enum TokenStandard {
  nonFungible,
  fungibleAsset,
  fungible,
  nonFungibleEdition,
  programmableNonFungible,
  programmableNonFungibleEdition,
}

/// What the app reads from a Token Metadata `Metadata` account.
typedef NftMetadata = ({
  String mint,
  String name,
  String symbol,
  String uri,

  /// Null on accounts written before token standards existed (legacy NFTs).
  TokenStandard? tokenStandard,
});

/// Programmable NFTs need Token Metadata transfers with rule sets; the
/// program only moves plain SPL tokens.
bool isProgrammable(TokenStandard? s) =>
    s == TokenStandard.programmableNonFungible ||
    s == TokenStandard.programmableNonFungibleEdition;

/// Decodes a Token Metadata `MetadataV1` account (key 4) up to
/// `token_standard`. Older or shorter accounts end early; their token
/// standard is null.
NftMetadata decodeMetadata(List<int> data) {
  if (data.isEmpty || data[0] != 4) {
    throw const FormatException('Not a Token Metadata account');
  }
  final r = BorshReader(data)..offset = 1;
  r.pubkey(); // update_authority
  final mint = r.pubkey();
  String text() => r.string().replaceAll('\u0000', '').trim();
  final name = text();
  final symbol = text();
  final uri = text();
  TokenStandard? standard;
  try {
    r.u16(); // seller_fee_basis_points
    if (r.boolean()) {
      final creators = r.u32();
      if (creators > 5) throw FormatException('Bad creator count $creators');
      r.offset += creators * 34; // address, verified, share
    }
    r
      ..boolean() // primary_sale_happened
      ..boolean(); // is_mutable
    if (r.boolean()) r.u8(); // edition_nonce
    if (r.boolean()) {
      standard = r.enumOf(TokenStandard.values, 'TokenStandard');
    }
  } on FormatException {
    standard = null;
  } on RangeError {
    standard = null;
  }
  return (
    mint: mint,
    name: name,
    symbol: symbol,
    uri: uri,
    tokenStandard: standard,
  );
}

Ed25519HDPublicKey _pk(String address) =>
    Ed25519HDPublicKey.fromBase58(address);

AccountMeta _w(String address, {bool signer = false}) =>
    AccountMeta.writeable(pubKey: _pk(address), isSigner: signer);

AccountMeta _r(String address, {bool signer = false}) =>
    AccountMeta.readonly(pubKey: _pk(address), isSigner: signer);

Instruction deadmanIx(List<AccountMeta> accounts, List<int> data) =>
    Instruction(
      programId: _pk(AppConfig.programId),
      accounts: accounts,
      data: ByteArray(data),
    );

/// Associated Token `CreateIdempotent` (instruction 1), classic SPL Token.
Instruction createAtaIdempotentIx({
  required String payer,
  required String owner,
  required String mint,
}) => Instruction(
  programId: _pk(ataProgramId),
  accounts: [
    _w(payer, signer: true),
    _w(ataAddress(owner, mint)),
    _r(owner),
    _r(mint),
    _r(systemProgramId),
    _r(tokenProgramId),
  ],
  data: ByteArray(const [1]),
);

/// SPL Token `TransferChecked` (instruction 12).
Instruction transferCheckedIx({
  required String source,
  required String mint,
  required String destination,
  required String authority,
  required int amount,
  required int decimals,
}) => Instruction(
  programId: _pk(tokenProgramId),
  accounts: [
    _w(source),
    _r(mint),
    _w(destination),
    _r(authority, signer: true),
  ],
  data: ByteArray(
    (BorshWriter()
          ..u8(12)
          ..u64(amount)
          ..u8(decimals))
        .toBytes(),
  ),
);

Instruction ownerActionIx(String owner, int planId, List<int> data) =>
    deadmanIx([
      _w(owner, signer: true),
      _w(vaultPda(owner, planId).address),
    ], data);

/// Signer may be the owner or the guard (guardian too, for lockdown).
Instruction pulseOrLockdownIx({
  required String signer,
  required String vaultOwner,
  required int planId,
  required bool lockdown,
}) => deadmanIx([
  _r(signer, signer: true),
  _w(vaultPda(vaultOwner, planId).address),
], lockdown ? Disc.lockdown : Disc.pulse);

/// `skip_rule`: any signer may skip a tier past its grace period. For a
/// token tier ([mint] set) `vault_token` is the vault's ATA, so the program
/// can reserve the tier's share; for a SOL tier the optional account is
/// omitted, which Anchor encodes as the program id in its slot.
Instruction skipRuleIx({
  required String caller,
  required String vaultOwner,
  required int planId,
  required int index,
  String? mint,
}) {
  final vault = vaultPda(vaultOwner, planId).address;
  return deadmanIx([
    _r(caller, signer: true),
    _w(vault),
    _r(mint == null ? AppConfig.programId : ataAddress(vault, mint)),
  ], encodeSkipRule(index));
}

/// `create_plan` or `create_vesting` (same accounts). [payer] funds the
/// vault rent and becomes its `rent_payer`: the owner, or a Kora paymaster.
/// [mints] are the token mints the rules or schedules name: the program
/// reads each one (as a remaining account) to check it is a classic SPL
/// Token mint.
Instruction createVaultIx({
  required String owner,
  required String payer,
  required int planId,
  required List<int> data,
  Iterable<String> mints = const [],
}) => deadmanIx([
  _r(owner, signer: true),
  _w(payer, signer: true),
  _w(vaultPda(owner, planId).address),
  _r(systemProgramId),
  ..._mintAccounts(mints),
], data);

/// `update_plan`, with every token mint the new [rules] name as a
/// read-only remaining account (see [createVaultIx]).
Instruction updatePlanIx({
  required String owner,
  required int planId,
  required List<int> data,
  required List<RuleSpec> rules,
}) => deadmanIx([
  _w(owner, signer: true),
  _w(vaultPda(owner, planId).address),
  ..._mintAccounts(rules.map((r) => r.mint)),
], data);

/// Distinct mints, read-only, in first-seen order.
List<AccountMeta> _mintAccounts(Iterable<String?> mints) => [
  for (final m in {...mints.nonNulls}) _r(m),
];

/// `close_vault`: the rent goes back to [rentPayer] (`Vault.rent_payer`),
/// everything above it to the owner.
Instruction closeVaultIx({
  required String owner,
  required int planId,
  required String rentPayer,
}) => deadmanIx([
  _w(owner, signer: true),
  _w(vaultPda(owner, planId).address),
  _w(rentPayer),
], Disc.closeVault);

/// `recover_legacy_vault`: closes [owner]'s plan [planId] left in an older
/// account layout and sends all its lamports to the owner.
Instruction recoverLegacyVaultIx({
  required String owner,
  required int planId,
}) => deadmanIx([
  _w(owner, signer: true),
  _w(vaultPda(owner, planId).address),
], encodeRecoverLegacyVault(planId));

/// [payer] (default: the owner) funds the vault ATA if it does not exist.
List<Instruction> depositTokenIxs({
  required String owner,
  required int planId,
  required String mint,
  required int amount,
  required int decimals,
  String? payer,
}) {
  final vault = vaultPda(owner, planId).address;
  return [
    createAtaIdempotentIx(payer: payer ?? owner, owner: vault, mint: mint),
    transferCheckedIx(
      source: ataAddress(owner, mint),
      mint: mint,
      destination: ataAddress(vault, mint),
      authority: owner,
      amount: amount,
      decimals: decimals,
    ),
  ];
}

/// Recreates the owner's ATA if it was closed ([payer], default the owner,
/// funds it), then withdraws.
List<Instruction> withdrawTokenIxs({
  required String owner,
  required int planId,
  required String mint,
  required int amount,
  String? payer,
}) {
  final vault = vaultPda(owner, planId).address;
  return [
    createAtaIdempotentIx(payer: payer ?? owner, owner: owner, mint: mint),
    deadmanIx([
      _w(owner, signer: true),
      _w(vault),
      _r(mint),
      _w(ataAddress(vault, mint)),
      _w(ataAddress(owner, mint)),
      _r(tokenProgramId),
    ], encodeWithdrawToken(amount)),
  ];
}

/// `execute_sol_rule` or, for a token rule, idempotent creates of the
/// treasury's (when [treasuryFee]) and the beneficiary's ATAs (paid by
/// [payer], default [executor]; the program no longer creates either)
/// followed by `execute_token_rule` paying into the beneficiary's ATA.
/// [treasury] comes from Config.
///
/// [treasuryFee] false leaves the treasury's token account out (the
/// program id fills its optional slot), for a payout that leaves the
/// treasury nothing, such as a single NFT; the program refuses it with
/// `TreasuryAccountRequired` if a fee is due after all.
///
/// Token rules use classic SPL Token mints only; the program rejects any
/// other mint when the plan is created or updated.
List<Instruction> executeRuleIxs({
  required String executor,
  required String vaultOwner,
  required int planId,
  required RuleSpec rule,
  required int index,
  required String treasury,
  String? payer,
  bool treasuryFee = true,
}) => _payoutIxs(
  executor: executor,
  vaultOwner: vaultOwner,
  planId: planId,
  rule: rule,
  treasury: treasury,
  payer: payer,
  treasuryFee: treasuryFee,
  data: encodeExecuteRule(index, token: rule.mint != null),
);

/// `release_vested_sol`, or for a token schedule the same idempotent ATA
/// creates as [executeRuleIxs] followed by `release_vested_token` (same
/// accounts as the execute variants).
List<Instruction> releaseVestedIxs({
  required String executor,
  required String vaultOwner,
  required int planId,
  required RuleSpec rule,
  required int index,
  required String treasury,
  String? payer,
  bool treasuryFee = true,
}) => _payoutIxs(
  executor: executor,
  vaultOwner: vaultOwner,
  planId: planId,
  rule: rule,
  treasury: treasury,
  payer: payer,
  treasuryFee: treasuryFee,
  data: encodeReleaseVested(index, token: rule.mint != null),
);

/// [payer] (default: [executor]) funds any missing ATA. The mint is
/// writable so the burned share of an SKR fee can leave its supply.
List<Instruction> _payoutIxs({
  required String executor,
  required String vaultOwner,
  required int planId,
  required RuleSpec rule,
  required String treasury,
  required String? payer,
  required bool treasuryFee,
  required List<int> data,
}) {
  final vault = vaultPda(vaultOwner, planId).address;
  final mint = rule.mint;
  if (mint == null) {
    return [
      deadmanIx([
        _r(executor, signer: true),
        _w(vault),
        _r(configPda().address),
        _w(rule.beneficiary),
        _w(treasury),
      ], data),
    ];
  }
  final rentPayer = payer ?? executor;
  return [
    if (treasuryFee)
      createAtaIdempotentIx(payer: rentPayer, owner: treasury, mint: mint),
    createAtaIdempotentIx(
      payer: rentPayer,
      owner: rule.beneficiary,
      mint: mint,
    ),
    deadmanIx([
      _r(executor, signer: true),
      _w(vault),
      _r(configPda().address),
      _w(mint),
      _w(ataAddress(vault, mint)),
      _w(rule.beneficiary),
      _w(ataAddress(rule.beneficiary, mint)),
      treasuryFee ? _w(ataAddress(treasury, mint)) : _r(AppConfig.programId),
      _r(tokenProgramId),
    ], data),
  ];
}

/// Legacy transaction with zeroed signature slots, ready for MWA signing.
/// With a Kora fee payer there are two or more slots, the fee payer's first;
/// the signer fills only its own and Kora co-signs later.
Uint8List serializeUnsigned(
  List<Instruction> instructions, {
  required String feePayer,
  required String recentBlockhash,
}) {
  final compiled = Message(instructions: instructions).compile(
    recentBlockhash: recentBlockhash,
    feePayer: Ed25519HDPublicKey.fromBase58(feePayer),
  );
  if (compiled.accountKeys.first.toBase58() != feePayer) {
    throw StateError('Fee payer $feePayer is not the first account');
  }
  final tx = SignedTx(
    compiledMessage: compiled,
    signatures: [
      for (final k in compiled.accountKeys.take(
        compiled.requiredSignatureCount,
      ))
        Signature(List<int>.filled(64, 0), publicKey: k),
    ],
  );
  return Uint8List.fromList(tx.toByteArray().toList());
}

/// Fills [signer]'s signature slot of wire transaction [tx], leaving the
/// other slots (e.g. a Kora fee payer's) as they are.
Future<Uint8List> partiallySign(List<int> tx, Ed25519HDKeyPair signer) async {
  final signed = SignedTx.fromBytes(tx);
  final message = signed.compiledMessage;
  final slot = message.accountKeys
      .take(message.requiredSignatureCount)
      .toList()
      .indexOf(signer.publicKey);
  if (slot < 0) {
    throw ArgumentError.value(signer.address, 'signer', 'not a signer of tx');
  }
  final signature = await signer.sign(message.toByteArray());
  final signatures = [...signed.signatures]..[slot] = signature;
  return Uint8List.fromList(
    signed.copyWith(signatures: signatures).toByteArray().toList(),
  );
}
