import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:deadman/core/config.dart';
import 'package:deadman/solana/codec.dart';
import 'package:deadman/solana/deadman_api.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../tool/set_config.dart';
import '../solana/helpers.dart';

void main() {
  final admin = key(1);
  final treasury = key(2);

  test('defaults: 2% Solana rail, 3% private rails, devnet', () {
    final a = parseArgs(['--keypair', 'admin.json']);
    expect(a.keypair, 'admin.json');
    expect(a.treasury, isNull);
    expect(a.feePublic, 200);
    expect(a.feePrivate, 300);
    expect(a.rpc, devnetRpc);
    expect(a.mainnet, isFalse);
  });

  test('explicit treasury, fees, --rpc and --mainnet', () {
    final a = parseArgs([
      '--keypair',
      'k',
      '--treasury',
      treasury,
      '--fee-public',
      '0',
      '--fee-private',
      '${Limits.maxFeeBps}',
      '--rpc',
      'http://localhost:8899',
      '--mainnet',
    ]);
    expect(a.treasury, treasury);
    expect(a.feePublic, 0);
    expect(a.feePrivate, Limits.maxFeeBps);
    expect(a.rpc, 'http://localhost:8899');
    expect(a.mainnet, isTrue);
  });

  test('rejects what the program would, and missing arguments', () {
    for (final argv in [
      <String>[],
      ['--treasury', treasury],
      ['--keypair', 'k', '--fee-private', '501'],
      ['--keypair', 'k', '--fee-public', '-1'],
      ['--keypair', 'k', '--fee-public', 'two'],
      ['--keypair', 'k', '--treasury', 'nope'],
      ['--keypair', 'k', '--treasury', defaultPubkey],
      ['--keypair', 'k', 'stray'],
    ]) {
      expect(() => parseArgs(argv), throwsFormatException, reason: '$argv');
    }
  });

  test('discriminator matches Anchor and the built IDL', () {
    expect(
      setConfigDisc,
      sha256.convert(utf8.encode('global:set_config')).bytes.sublist(0, 8),
    );
    final ix = (loadIdl()['instructions'] as List).cast<Map>().firstWhere(
      (i) => i['name'] == 'set_config',
    );
    expect(setConfigDisc, (ix['discriminator'] as List).cast<int>());
    expect((ix['accounts'] as List).map((a) => (a as Map)['name']), [
      'admin',
      'config',
    ]);
  });

  test('encodes treasury and both fees as little-endian u16', () {
    final data = encodeSetConfig(
      treasury: treasury,
      feePublic: 200,
      feePrivate: 300,
    );
    expect(data, [
      ...setConfigDisc,
      ...keyBytes(treasury),
      ...le(2, 200),
      ...le(2, 300),
    ]);
    expect(data.length, 8 + 32 + 2 + 2);
  });

  test('instruction: admin signer, Config PDA writable, Deadman program', () {
    final ix = setConfigIx(
      admin: admin,
      treasury: treasury,
      feePublic: 200,
      feePrivate: 300,
    );
    expect(ix.programId.toBase58(), AppConfig.programId);
    expect(ix.accounts, hasLength(2));
    expect(ix.accounts[0].pubKey.toBase58(), admin);
    expect(ix.accounts[0].isSigner, isTrue);
    expect(ix.accounts[0].isWriteable, isFalse);
    expect(ix.accounts[1].pubKey.toBase58(), configPda().address);
    expect(ix.accounts[1].isSigner, isFalse);
    expect(ix.accounts[1].isWriteable, isTrue);
    expect(
      ix.data.toList(),
      encodeSetConfig(treasury: treasury, feePublic: 200, feePrivate: 300),
    );
  });

  test('describeConfig prints both rates in bps and percent', () {
    final out = describeConfig(
      DeadmanConfig(
        admin: admin,
        fees: FeeSchedule(
          treasury: treasury,
          feeBpsPublic: 200,
          feeBpsPrivate: 300,
        ),
      ),
    );
    expect(out, contains(configPda().address));
    expect(out, contains('treasury:    $treasury'));
    expect(out, contains('fee public:  200 bps (2%'));
    expect(out, contains('fee private: 300 bps (3%'));
  });
}
