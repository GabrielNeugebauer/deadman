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
  static const createVault = [29, 237, 247, 208, 193, 82, 54, 135];
  static const updatePolicy = [212, 245, 246, 7, 163, 151, 18, 57];
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

  static const configAccount = [155, 12, 170, 224, 30, 250, 204, 130];
  static const vaultAccount = [211, 8, 232, 43, 2, 152, 117, 119];
}

/// Mirrors `onchain/programs/deadman/src/constants.rs`.
abstract final class Limits {
  static const maxRules = 8;
  static const maxLabelBytes = 32;
  static const bpsDenominator = 10000;
  static const maxFeeBps = 500;
  static const minIntervalSecs = 60;
  static const maxIntervalSecs = 366 * 86400;
  static const minRuleMarginSecs = 60;
  static const maxRuleDelaySecs = 3 * 366 * 86400;
  static const minSkipGraceSecs = 60;
  static const maxSkipGraceSecs = 366 * 86400;
  static const minLockSecs = 60;
  static const maxLockSecs = 30 * 86400;
  static const privateGasStipend = 3000000;
}

const systemProgramId = SystemProgram.programId;
const tokenProgramId = TokenProgram.programId;
const token2022ProgramId = Token2022Program.programId;
const ataProgramId = AssociatedTokenAccountProgram.programId;

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
  void i64(int v) => _num(8, (d) => d.setInt64(0, v, Endian.little));

  /// Dart ints are signed 64-bit, so only 0..2^63-1 is representable.
  void u64(int v) =>
      _num(8, (d) => d.setUint64(0, _range(v, 0, null, 'u64'), Endian.little));
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

  Uint8List toBytes() => _b.toBytes();

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
  int i64() => _d.getInt64(_take(8), Endian.little);
  int u64() => _d.getUint64(_take(8), Endian.little);

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

Uint8List encodeCreateVault({
  required int planId,
  required String label,
  required String guard,
  required int intervalSecs,
  required int lockSecs,
  required int skipGraceSecs,
  required List<RuleSpec> rules,
}) =>
    (BorshWriter()
          ..bytes(Disc.createVault)
          ..u16(planId)
          ..string(label)
          ..pubkey(guard)
          ..i64(intervalSecs)
          ..i64(lockSecs)
          ..i64(skipGraceSecs)
          ..ruleInputs(rules))
        .toBytes();

Uint8List encodeUpdatePolicy({
  required String label,
  required int intervalSecs,
  required int lockSecs,
  required int skipGraceSecs,
  required List<RuleSpec> rules,
  String? guardian,
}) =>
    (BorshWriter()
          ..bytes(Disc.updatePolicy)
          ..string(label)
          ..i64(intervalSecs)
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

Uint8List encodeSkipRule(int index) =>
    (BorshWriter()
          ..bytes(Disc.skipRule)
          ..u8(index))
        .toBytes();

/// Tiers `update_policy` keeps as history in front of the new rules: every
/// paid or skipped one, or none once every tier has paid.
int policyHistoryCount(VaultState vault) =>
    vault.completed ? 0 : vault.rules.where((r) => r.settled).length;

/// Mirrors `Vault::apply_policy` (and the guard checks of `create_vault`).
/// Returns the program error code the chain would raise, or null if valid.
/// Pass [guard] only when known; the chain also checks it on update.
/// [historyCount] is [policyHistoryCount] of the current vault on update
/// (0 on create): history plus [rules] must fit in [Limits.maxRules].
int? policyError({
  required String owner,
  required String vault,
  String? guard,
  required int intervalSecs,
  required int lockSecs,
  required int skipGraceSecs,
  required List<RuleSpec> rules,
  int historyCount = 0,
  String? guardian,
}) {
  if (intervalSecs < Limits.minIntervalSecs ||
      intervalSecs > Limits.maxIntervalSecs ||
      lockSecs < Limits.minLockSecs ||
      lockSecs > Limits.maxLockSecs ||
      skipGraceSecs < Limits.minSkipGraceSecs ||
      skipGraceSecs > Limits.maxSkipGraceSecs) {
    return 6002;
  }
  if (rules.isEmpty || historyCount + rules.length > Limits.maxRules) {
    return 6003;
  }
  final minDelay = intervalSecs + Limits.minRuleMarginSecs;
  for (var i = 0; i < rules.length; i++) {
    final r = rules[i];
    final amountOk = switch (r.mode) {
      AmountMode.fixed => r.amount > 0,
      AmountMode.percent => r.amount >= 1 && r.amount <= Limits.bpsDenominator,
    };
    if (!amountOk ||
        r.afterSecs < minDelay ||
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
  final intervalSecs = r.i64();
  final lockSecs = r.i64();
  final skipGraceSecs = r.i64();
  final lastPulse = r.i64();
  final ownerLastSeen = r.i64();
  final lockedUntil = r.i64();
  final guardianReadyAt = r.i64();
  final totalPulses = r.u64();
  final streak = r.u32();
  final bestStreak = r.u32();
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
    ),
  );
  final label = r.string();
  r.u8(); // bump
  return VaultState(
    address: address,
    owner: owner,
    planId: planId,
    label: label,
    guard: guard,
    guardian: guardian,
    intervalSecs: intervalSecs,
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
    withdrawableLamports: lamports > rentExemptMinimum
        ? lamports - rentExemptMinimum
        : 0,
  );
}

class DeadmanConfig {
  const DeadmanConfig({required this.admin, required this.fees});

  final String admin;
  final FeeSchedule fees;
}

DeadmanConfig decodeConfig(List<int> data) {
  if (!hasDiscriminator(data, Disc.configAccount)) {
    throw const FormatException('Not a Config account');
  }
  final r = BorshReader(data)..offset = 8;
  return DeadmanConfig(
    admin: r.pubkey(),
    fees: FeeSchedule(
      treasury: r.pubkey(),
      feeBpsPublic: r.u16(),
      feeBpsPrivate: r.u16(),
    ),
  );
}

/// `decimals` of an SPL mint account.
int decodeMintDecimals(List<int> data) {
  if (data.length < 82) throw const FormatException('Not a mint account');
  return data[44];
}

/// `amount` of an SPL token account.
int decodeTokenAmount(List<int> data) {
  if (data.length < 165) {
    throw const FormatException('Not a token account');
  }
  return (BorshReader(data)..offset = 64).u64();
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

/// `create_vault`. [payer] funds the vault rent (the client passes the owner).
Instruction createVaultIx({
  required String owner,
  required String payer,
  required int planId,
  required List<int> data,
}) => deadmanIx([
  _r(owner, signer: true),
  _w(payer, signer: true),
  _w(vaultPda(owner, planId).address),
  _r(systemProgramId),
], data);

/// The owner funds the vault ATA if it does not exist yet.
List<Instruction> depositTokenIxs({
  required String owner,
  required int planId,
  required String mint,
  required int amount,
  required int decimals,
}) {
  final vault = vaultPda(owner, planId).address;
  return [
    createAtaIdempotentIx(payer: owner, owner: vault, mint: mint),
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

/// Recreates the owner's ATA if it was closed, then withdraws.
List<Instruction> withdrawTokenIxs({
  required String owner,
  required int planId,
  required String mint,
  required int amount,
}) {
  final vault = vaultPda(owner, planId).address;
  return [
    createAtaIdempotentIx(payer: owner, owner: owner, mint: mint),
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
/// treasury's and the beneficiary's ATAs (paid by [executor]; the program no
/// longer creates either) followed by `execute_token_rule` paying into the
/// beneficiary's ATA. [treasury] comes from Config.
///
/// Token rules assume classic SPL Token mints. Token-2022 (different token
/// program, ATA derivation and possibly transfer-hook remaining accounts) is
/// not supported by this client yet.
List<Instruction> executeRuleIxs({
  required String executor,
  required String vaultOwner,
  required int planId,
  required RuleSpec rule,
  required int index,
  required String treasury,
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
      ], encodeExecuteRule(index, token: false)),
    ];
  }
  return [
    createAtaIdempotentIx(payer: executor, owner: treasury, mint: mint),
    createAtaIdempotentIx(payer: executor, owner: rule.beneficiary, mint: mint),
    deadmanIx([
      _r(executor, signer: true),
      _w(vault),
      _r(configPda().address),
      _r(mint),
      _w(ataAddress(vault, mint)),
      _w(rule.beneficiary),
      _w(ataAddress(rule.beneficiary, mint)),
      _w(ataAddress(treasury, mint)),
      _r(tokenProgramId),
    ], encodeExecuteRule(index, token: true)),
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
