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
  static const closeVault = [141, 103, 17, 126, 72, 75, 29, 29];
  static const withdrawSol = [145, 131, 74, 136, 65, 137, 42, 38];
  static const trigger = [215, 172, 161, 36, 115, 157, 116, 147];
  static const claimSol = [139, 113, 179, 189, 190, 30, 132, 195];
  static const subscribe = [254, 28, 191, 138, 156, 179, 183, 53];

  static const configAccount = [155, 12, 170, 224, 30, 250, 204, 130];
  static const vaultAccount = [211, 8, 232, 43, 2, 152, 117, 119];
}

typedef Pda = ({String address, int bump});

/// Synchronous `findProgramAddress` (the package version is async).
Pda findPda(List<List<int>> seeds, {String programId = AppConfig.programId}) {
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

Pda vaultPda(String owner) =>
    findPda([utf8.encode('vault'), Ed25519HDPublicKey.fromBase58(owner).bytes]);

Pda configPda() => findPda([utf8.encode('config')]);

class BorshWriter {
  final _b = BytesBuilder(copy: false);

  void bytes(List<int> v) => _b.add(v);
  void u8(int v) => _b.addByte(v);
  void u16(int v) => _num(2, (d) => d.setUint16(0, v, Endian.little));
  void u32(int v) => _num(4, (d) => d.setUint32(0, v, Endian.little));
  void i64(int v) => _num(8, (d) => d.setInt64(0, v, Endian.little));
  void u64(int v) => _num(8, (d) => d.setUint64(0, v, Endian.little));
  void pubkey(String v) => _b.add(Ed25519HDPublicKey.fromBase58(v).bytes);

  void optionPubkey(String? v) {
    if (v == null) {
      u8(0);
    } else {
      u8(1);
      pubkey(v);
    }
  }

  void heirInputs(List<Heir> heirs) {
    u32(heirs.length);
    for (final h in heirs) {
      pubkey(h.wallet);
      u16(h.bps);
    }
  }

  Uint8List toBytes() => _b.toBytes();

  void _num(int len, void Function(ByteData) set) {
    final d = ByteData(len);
    set(d);
    _b.add(d.buffer.asUint8List());
  }
}

class BorshReader {
  BorshReader(List<int> data)
    : _d = ByteData.sublistView(Uint8List.fromList(data));

  final ByteData _d;
  int offset = 0;

  int u8() => _d.getUint8(_take(1));
  bool boolean() => u8() != 0;
  int u16() => _d.getUint16(_take(2), Endian.little);
  int u32() => _d.getUint32(_take(4), Endian.little);
  int i64() => _d.getInt64(_take(8), Endian.little);
  int u64() => _d.getUint64(_take(8), Endian.little);

  String pubkey() {
    final start = _take(32);
    return base58encode(_d.buffer.asUint8List(_d.offsetInBytes + start, 32));
  }

  String? optionPubkey() => switch (u8()) {
    0 => null,
    1 => pubkey(),
    final t => throw FormatException('Bad Option tag $t'),
  };

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
  required String guard,
  required int intervalSecs,
  required int graceSecs,
  required int lockSecs,
  required List<Heir> heirs,
}) {
  final w = BorshWriter()
    ..bytes(Disc.createVault)
    ..pubkey(guard)
    ..i64(intervalSecs)
    ..i64(graceSecs)
    ..i64(lockSecs)
    ..heirInputs(heirs);
  return w.toBytes();
}

Uint8List encodeUpdatePolicy({
  required int intervalSecs,
  required int graceSecs,
  required int lockSecs,
  required List<Heir> heirs,
  String? guardian,
}) {
  final w = BorshWriter()
    ..bytes(Disc.updatePolicy)
    ..i64(intervalSecs)
    ..i64(graceSecs)
    ..i64(lockSecs)
    ..heirInputs(heirs)
    ..optionPubkey(guardian);
  return w.toBytes();
}

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

Uint8List encodeSubscribe(int months) =>
    (BorshWriter()
          ..bytes(Disc.subscribe)
          ..u8(months))
        .toBytes();

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
  final guard = r.pubkey();
  final guardian = r.optionPubkey();
  final intervalSecs = r.i64();
  final graceSecs = r.i64();
  final lockSecs = r.i64();
  final lastPulse = r.i64();
  final lockedUntil = r.i64();
  final plusUntil = r.i64();
  final triggeredAt = r.i64();
  final solAtTrigger = r.u64();
  final totalPulses = r.u64();
  final streak = r.u32();
  final bestStreak = r.u32();
  final status = switch (r.u8()) {
    0 => VaultStatus.active,
    1 => VaultStatus.triggered,
    final s => throw FormatException('Bad VaultStatus $s'),
  };
  final heirs = List.generate(
    r.u32(),
    (_) => Heir(wallet: r.pubkey(), bps: r.u16(), claimedSol: r.boolean()),
  );
  return VaultState(
    address: address,
    owner: owner,
    guard: guard,
    guardian: guardian,
    intervalSecs: intervalSecs,
    graceSecs: graceSecs,
    lockSecs: lockSecs,
    lastPulse: lastPulse,
    lockedUntil: lockedUntil,
    plusUntil: plusUntil,
    triggeredAt: triggeredAt,
    solAtTrigger: solAtTrigger,
    totalPulses: totalPulses,
    streak: streak,
    bestStreak: bestStreak,
    status: status,
    heirs: heirs,
    lamports: lamports,
    withdrawableLamports: lamports > rentExemptMinimum
        ? lamports - rentExemptMinimum
        : 0,
  );
}

class DeadmanConfig {
  const DeadmanConfig({
    required this.admin,
    required this.treasury,
    required this.skrMint,
    required this.plusPrice,
    required this.feeBps,
  });

  final String admin;
  final String treasury;
  final String skrMint;

  /// SKR base units per 30 days.
  final int plusPrice;
  final int feeBps;
}

DeadmanConfig decodeConfig(List<int> data) {
  if (!hasDiscriminator(data, Disc.configAccount)) {
    throw const FormatException('Not a Config account');
  }
  final r = BorshReader(data)..offset = 8;
  return DeadmanConfig(
    admin: r.pubkey(),
    treasury: r.pubkey(),
    skrMint: r.pubkey(),
    plusPrice: r.u64(),
    feeBps: r.u16(),
  );
}

/// Legacy transaction with zeroed signature slots, ready for MWA signing.
Uint8List serializeUnsigned(
  List<Instruction> instructions, {
  required String feePayer,
  required String recentBlockhash,
}) {
  final compiled = Message(instructions: instructions).compile(
    recentBlockhash: recentBlockhash,
    feePayer: Ed25519HDPublicKey.fromBase58(feePayer),
  );
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
