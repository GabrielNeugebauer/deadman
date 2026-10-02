import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:deadman/core/config.dart';
import 'package:deadman/solana/codec.dart';
import 'package:deadman/solana/deadman_api.dart';
import 'package:deadman/solana/deadman_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:solana/base58.dart';
import 'package:solana/encoder.dart';
import 'package:solana/solana.dart';

String key(int seed) =>
    base58encode(List<int>.generate(32, (i) => (seed * 31 + i * 7) & 0xff));

List<int> le(int bytes, int value) {
  final d = ByteData(8)..setInt64(0, value, Endian.little);
  return d.buffer.asUint8List(0, bytes).toList();
}

List<int> keyBytes(String k) => Ed25519HDPublicKey.fromBase58(k).bytes;

void main() {
  final owner = key(1);
  final guard = key(2);
  final heirA = key(3);
  final heirB = key(4);
  final guardian = key(5);
  final heirs = [
    Heir(wallet: heirA, bps: 6000),
    Heir(wallet: heirB, bps: 4000),
  ];

  group('PDA', () {
    test('vault PDA matches the async package derivation', () async {
      final expected = await Ed25519HDPublicKey.findProgramAddress(
        seeds: [utf8.encode('vault'), keyBytes(owner)],
        programId: Ed25519HDPublicKey.fromBase58(AppConfig.programId),
      );
      final pda = vaultPda(owner);
      expect(pda.address, expected.toBase58());
      expect(DeadmanClient().vaultAddressFor(owner), expected.toBase58());

      final check = await Ed25519HDPublicKey.createProgramAddress(
        seeds: [...utf8.encode('vault'), ...keyBytes(owner), pda.bump],
        programId: Ed25519HDPublicKey.fromBase58(AppConfig.programId),
      );
      expect(check.toBase58(), pda.address);
    });

    test('config PDA matches the async package derivation', () async {
      final expected = await Ed25519HDPublicKey.findProgramAddress(
        seeds: [utf8.encode('config')],
        programId: Ed25519HDPublicKey.fromBase58(AppConfig.programId),
      );
      expect(configPda().address, expected.toBase58());
    });
  });

  group('instruction data', () {
    test('discriminators match the IDL', () {
      final idl = jsonDecode(
        File('onchain/target/idl/deadman.json').readAsStringSync(),
      ) as Map;
      List<int> ix(String name) => List<int>.from(
        (idl['instructions'] as List).firstWhere(
              (i) => i['name'] == name,
            )['discriminator']
            as List,
      );
      List<int> acc(String name) => List<int>.from(
        (idl['accounts'] as List).firstWhere(
              (a) => a['name'] == name,
            )['discriminator']
            as List,
      );
      expect(Disc.createVault, ix('create_vault'));
      expect(Disc.updatePolicy, ix('update_policy'));
      expect(Disc.setGuard, ix('set_guard'));
      expect(Disc.pulse, ix('pulse'));
      expect(Disc.lockdown, ix('lockdown'));
      expect(Disc.closeVault, ix('close_vault'));
      expect(Disc.withdrawSol, ix('withdraw_sol'));
      expect(Disc.trigger, ix('trigger'));
      expect(Disc.claimSol, ix('claim_sol'));
      expect(Disc.subscribe, ix('subscribe'));
      expect(Disc.vaultAccount, acc('Vault'));
      expect(Disc.configAccount, acc('Config'));
    });

    final heirBytes = [
      ...le(4, 2),
      ...keyBytes(heirA),
      ...le(2, 6000),
      ...keyBytes(heirB),
      ...le(2, 4000),
    ];

    test('create_vault with 2 heirs', () {
      final data = encodeCreateVault(
        guard: guard,
        intervalSecs: 86400,
        graceSecs: 3600,
        lockSecs: -1,
        heirs: heirs,
      );
      expect(data, [
        29,
        237,
        247,
        208,
        193,
        82,
        54,
        135,
        ...keyBytes(guard),
        ...le(8, 86400),
        ...le(8, 3600),
        ...List.filled(8, 0xff),
        ...heirBytes,
      ]);
      expect(data.length, 8 + 32 + 24 + 4 + 2 * 34);
    });

    test('update_policy with guardian Some', () {
      final data = encodeUpdatePolicy(
        intervalSecs: 60,
        graceSecs: 120,
        lockSecs: 180,
        heirs: heirs,
        guardian: guardian,
      );
      expect(data, [
        212,
        245,
        246,
        7,
        163,
        151,
        18,
        57,
        ...le(8, 60),
        ...le(8, 120),
        ...le(8, 180),
        ...heirBytes,
        1,
        ...keyBytes(guardian),
      ]);
    });

    test('update_policy with guardian None', () {
      final data = encodeUpdatePolicy(
        intervalSecs: 60,
        graceSecs: 120,
        lockSecs: 180,
        heirs: heirs,
      );
      expect(data, [
        212,
        245,
        246,
        7,
        163,
        151,
        18,
        57,
        ...le(8, 60),
        ...le(8, 120),
        ...le(8, 180),
        ...heirBytes,
        0,
      ]);
    });

    test('scalar args', () {
      expect(encodeWithdrawSol(1500000000), [
        ...Disc.withdrawSol,
        ...le(8, 1500000000),
      ]);
      expect(encodeSubscribe(3), [...Disc.subscribe, 3]);
      expect(encodeSetGuard(guardian), [
        ...Disc.setGuard,
        ...keyBytes(guardian),
      ]);
    });
  });

  group('Vault decoding', () {
    List<int> vaultBytes({String? guardian}) => [
      ...Disc.vaultAccount,
      ...keyBytes(owner),
      ...keyBytes(guard),
      if (guardian == null) 0 else ...[1, ...keyBytes(guardian)],
      ...le(8, 86400),
      ...le(8, 7200),
      ...le(8, 3600),
      ...le(8, 1790000000),
      ...le(8, 1790003600),
      ...le(8, 1800000000),
      ...le(8, 1795000000),
      ...le(8, 2500000000),
      ...le(8, 42),
      ...le(4, 7),
      ...le(4, 12),
      1,
      ...le(4, 2),
      ...keyBytes(heirA),
      ...le(2, 6000),
      1,
      ...keyBytes(heirB),
      ...le(2, 4000),
      0,
      254,
    ];

    test('decodes a hand-built buffer with guardian', () {
      final v = decodeVault(
        vaultBytes(guardian: guardian),
        address: 'vault',
        lamports: 3000000000,
        rentExemptMinimum: 3194880,
      );
      expect(v.owner, owner);
      expect(v.guard, guard);
      expect(v.guardian, guardian);
      expect(v.intervalSecs, 86400);
      expect(v.graceSecs, 7200);
      expect(v.lockSecs, 3600);
      expect(v.lastPulse, 1790000000);
      expect(v.lockedUntil, 1790003600);
      expect(v.plusUntil, 1800000000);
      expect(v.triggeredAt, 1795000000);
      expect(v.solAtTrigger, 2500000000);
      expect(v.totalPulses, 42);
      expect(v.streak, 7);
      expect(v.bestStreak, 12);
      expect(v.status, VaultStatus.triggered);
      expect(v.heirs.length, 2);
      expect(v.heirs[0].wallet, heirA);
      expect(v.heirs[0].bps, 6000);
      expect(v.heirs[0].claimedSol, isTrue);
      expect(v.heirs[1].wallet, heirB);
      expect(v.heirs[1].bps, 4000);
      expect(v.heirs[1].claimedSol, isFalse);
      expect(v.lamports, 3000000000);
      expect(v.withdrawableLamports, 3000000000 - 3194880);
    });

    test('decodes guardian None (fields shift by 32 bytes)', () {
      final v = decodeVault(
        vaultBytes(),
        address: 'vault',
        lamports: 100,
        rentExemptMinimum: 200,
      );
      expect(v.guardian, isNull);
      expect(v.intervalSecs, 86400);
      expect(v.heirs.map((h) => h.wallet), [heirA, heirB]);
      expect(v.withdrawableLamports, 0);
    });

    test('rejects wrong discriminator and truncated data', () {
      final bad = vaultBytes()..[0] ^= 1;
      expect(
        () => decodeVault(bad, address: 'x', lamports: 0, rentExemptMinimum: 0),
        throwsFormatException,
      );
      final short = vaultBytes().sublist(0, 60);
      expect(
        () =>
            decodeVault(short, address: 'x', lamports: 0, rentExemptMinimum: 0),
        throwsFormatException,
      );
    });
  });

  group('transaction serialization', () {
    test('zeroed signature slot and fee payer first', () {
      final blockhash = key(9);
      final ix = Instruction(
        programId: Ed25519HDPublicKey.fromBase58(AppConfig.programId),
        accounts: [
          AccountMeta.readonly(
            pubKey: Ed25519HDPublicKey.fromBase58(owner),
            isSigner: true,
          ),
          AccountMeta.writeable(
            pubKey: Ed25519HDPublicKey.fromBase58(vaultPda(owner).address),
            isSigner: false,
          ),
        ],
        data: ByteArray(Disc.pulse),
      );
      final bytes = serializeUnsigned(
        [ix],
        feePayer: owner,
        recentBlockhash: blockhash,
      );
      expect(bytes[0], 1);
      expect(bytes.sublist(1, 65), List.filled(64, 0));

      final tx = SignedTx.fromBytes(bytes);
      final msg = tx.compiledMessage;
      expect(msg.requiredSignatureCount, 1);
      expect(msg.accountKeys.first.toBase58(), owner);
      expect(msg.recentBlockhash, blockhash);
      expect(msg.instructions.single.data.toList(), Disc.pulse);
    });
  });

  test('maps Anchor custom errors', () {
    final e = DeadmanException.fromTxError({
      'InstructionError': [
        0,
        {'Custom': 6010},
      ],
    });
    expect(e.name, 'StillAlive');
    expect(e.code, 6010);
  });
}
