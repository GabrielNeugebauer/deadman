import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:deadman/core/config.dart';
import 'package:deadman/solana/codec.dart';
import 'package:deadman/solana/deadman_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:solana/solana.dart' show SystemProgram;

import '../../tool/init_config.dart';
import '../../tool/set_config.dart';
import '../solana/helpers.dart';

Map<String, dynamic> idlIx(String name) => (loadIdl()['instructions'] as List)
    .cast<Map<String, dynamic>>()
    .firstWhere((i) => i['name'] == name);

List<String> idlAccounts(String name) => [
  for (final a in idlIx(name)['accounts'] as List) (a as Map)['name'] as String,
];

void main() {
  final admin = key(1);
  final treasury = key(2);
  final skr = key(3);

  group('parseArgs', () {
    test('defaults: 2% per release, 1.5% in SKR with 10% burned, devnet '
        'test SKR', () {
      final a = parseArgs(['--keypair', 'admin.json']);
      expect(a.command, ConfigCommand.fees);
      expect(a.keypair, 'admin.json');
      expect(a.treasury, isNull);
      expect(a.feePublic, 200);
      expect(a.feePrivate, 200);
      expect(a.feeSkr, 150);
      expect(a.skrBurnBps, 1000);
      expect(a.skrMint, devnetSkrMint);
      expect(a.skrMint, '4JX81qZWhPPT38Tn4ZswaS2DyH3PffdrFqbYgsoZCuHc');
      expect(a.newAdmin, isNull);
      expect(a.rpc, devnetRpc);
      expect(a.mainnet, isFalse);
      expect(parseArgs(['fees', '--keypair', 'k']).feeSkr, 150);
    });

    test('--mainnet defaults to mainnet SKR', () {
      final a = parseArgs(['--keypair', 'k', '--mainnet']);
      expect(a.skrMint, mainnetSkrMint);
      expect(a.skrMint, 'SKRbvo6Gf7GondiT3BbTfuRDPqLWei4j2Qy2NPGZhW3');
      expect(a.mainnet, isTrue);
    });

    test('explicit treasury, rates, SKR mint and --rpc', () {
      final a = parseArgs([
        '--keypair',
        'k',
        '--treasury',
        treasury,
        '--fee-public',
        '0',
        '--fee-private',
        '${Limits.maxFeeBps}',
        '--fee-skr',
        '100',
        '--skr-burn-bps',
        '${Limits.bpsDenominator}',
        '--skr-mint',
        skr,
        '--rpc',
        'http://localhost:8899',
      ]);
      expect(a.treasury, treasury);
      expect(a.feePublic, 0);
      expect(a.feePrivate, Limits.maxFeeBps);
      expect(a.feeSkr, 100);
      expect(a.skrBurnBps, Limits.bpsDenominator);
      expect(a.skrMint, skr);
      expect(a.rpc, 'http://localhost:8899');
    });

    test('--skr-mint none turns the SKR rate off', () {
      expect(
        parseArgs(['--keypair', 'k', '--skr-mint', 'none']).skrMint,
        defaultPubkey,
      );
    });

    test('admin rotation commands', () {
      final p = parseArgs([
        'propose-admin',
        '--keypair',
        'k',
        '--new-admin',
        admin,
      ]);
      expect(p.command, ConfigCommand.proposeAdmin);
      expect(p.newAdmin, admin);
      expect(
        parseArgs(['propose-admin', '--keypair', 'k', '--new-admin', 'none'])
            .newAdmin,
        defaultPubkey,
      );
      final acc = parseArgs(['accept-admin', '--keypair', 'new.json']);
      expect(acc.command, ConfigCommand.acceptAdmin);
      expect(acc.keypair, 'new.json');
    });

    test('rejects what the program would, and bad arguments', () {
      for (final argv in [
        <String>[],
        ['--treasury', treasury],
        ['--keypair', 'k', '--fee-private', '501'],
        ['--keypair', 'k', '--fee-skr', '501'],
        ['--keypair', 'k', '--skr-burn-bps', '10001'],
        ['--keypair', 'k', '--fee-public', '-1'],
        ['--keypair', 'k', '--fee-public', 'two'],
        ['--keypair', 'k', '--treasury', 'nope'],
        ['--keypair', 'k', '--treasury', defaultPubkey],
        ['--keypair', 'k', '--skr-mint', 'nope'],
        ['--keypair', 'k', 'stray'],
        ['subscribe', '--keypair', 'k'],
        ['propose-admin', '--keypair', 'k'],
        ['propose-admin', '--keypair', 'k', '--new-admin', 'nope'],
        [
          'propose-admin',
          '--keypair',
          'k',
          '--new-admin',
          admin,
          '--fee-skr',
          '1',
        ],
        ['accept-admin', '--keypair', 'k', '--new-admin', admin],
        ['accept-admin', '--keypair', 'k', '--treasury', treasury],
        ['--keypair', 'k', '--new-admin', admin],
      ]) {
        expect(() => parseArgs(argv), throwsFormatException, reason: '$argv');
      }
    });
  });

  test('discriminators and account lists match Anchor and the built IDL', () {
    for (final (name, disc) in [
      ('set_config', setConfigDisc),
      ('propose_admin', proposeAdminDisc),
      ('accept_admin', acceptAdminDisc),
      ('init_config', initConfigDisc),
    ]) {
      expect(
        disc,
        sha256.convert(utf8.encode('global:$name')).bytes.sublist(0, 8),
        reason: name,
      );
      expect(disc, (idlIx(name)['discriminator'] as List).cast<int>());
    }
    expect(idlAccounts('set_config'), [
      'admin',
      'config',
      'treasury',
      'system_program',
    ]);
    expect(
      [for (final a in idlIx('set_config')['args'] as List) (a as Map)['name']],
      [
        'fee_bps_public',
        'fee_bps_private',
        'skr_mint',
        'fee_bps_skr',
        'skr_burn_bps',
      ],
    );
    expect(idlAccounts('propose_admin'), ['admin', 'config']);
    expect(idlAccounts('accept_admin'), ['new_admin', 'config']);
    expect(idlAccounts('init_config'), [
      'admin',
      'config',
      'treasury',
      'program',
      'program_data',
      'system_program',
    ]);
  });

  test('encodes the rates as little-endian u16 around the SKR mint', () {
    final data = encodeSetConfig(
      feePublic: 200,
      feePrivate: 300,
      skrMint: skr,
      feeSkr: 150,
      skrBurnBps: 1000,
    );
    expect(data, [
      ...setConfigDisc,
      ...le(2, 200),
      ...le(2, 300),
      ...keyBytes(skr),
      ...le(2, 150),
      ...le(2, 1000),
    ]);
    expect(data.length, 8 + 2 + 2 + 32 + 2 + 2);
  });

  test('set_config: admin writable signer, Config PDA writable, treasury '
      'and System program read-only', () {
    final ix = setConfigIx(
      admin: admin,
      treasury: treasury,
      feePublic: 200,
      feePrivate: 200,
      skrMint: skr,
      feeSkr: 150,
      skrBurnBps: 1000,
    );
    expect(ix.programId.toBase58(), AppConfig.programId);
    expect(
      [for (final m in ix.accounts) m.pubKey.toBase58()],
      [admin, configPda().address, treasury, SystemProgram.programId],
    );
    expect(
      [for (final m in ix.accounts) m.isSigner],
      [true, false, false, false],
    );
    expect(
      [for (final m in ix.accounts) m.isWriteable],
      [true, true, false, false],
    );
  });

  test('propose_admin and accept_admin', () {
    final p = proposeAdminIx(admin: admin, newAdmin: key(4));
    expect(
      [for (final m in p.accounts) m.pubKey.toBase58()],
      [admin, configPda().address],
    );
    expect(p.accounts[0].isSigner, isTrue);
    expect(p.accounts[0].isWriteable, isFalse);
    expect(p.accounts[1].isWriteable, isTrue);
    expect(p.data.toList(), [...proposeAdminDisc, ...keyBytes(key(4))]);

    final a = acceptAdminIx(key(4));
    expect(
      [for (final m in a.accounts) m.pubKey.toBase58()],
      [key(4), configPda().address],
    );
    expect(a.accounts[0].isSigner, isTrue);
    expect(a.accounts[1].isWriteable, isTrue);
    expect(a.data.toList(), acceptAdminDisc);
  });

  test('init_config: upgrade authority signs, treasury and program data '
      'are passed, SKR mint is the only argument', () {
    final ix = initConfigIx(admin: admin, treasury: treasury, skrMint: skr);
    final programData = findPda([
      keyBytes(AppConfig.programId),
    ], programId: loaderUpgradeable).address;
    expect(
      [for (final m in ix.accounts) m.pubKey.toBase58()],
      [
        admin,
        configPda().address,
        treasury,
        AppConfig.programId,
        programData,
        SystemProgram.programId,
      ],
    );
    expect(ix.accounts[0].isSigner && ix.accounts[0].isWriteable, isTrue);
    expect(ix.accounts[1].isWriteable, isTrue);
    expect(ix.data.toList(), [...initConfigDisc, ...keyBytes(skr)]);
  });

  group('describeConfig', () {
    test('prints every rate in bps and percent', () {
      final out = describeConfig(
        DeadmanConfig(
          admin: admin,
          pendingAdmin: key(4),
          fees: FeeSchedule(
            treasury: treasury,
            feeBpsPublic: 200,
            feeBpsPrivate: 200,
            skrMint: skr,
            feeBpsSkr: 150,
            skrBurnBps: 1000,
          ),
        ),
      );
      expect(out, contains(configPda().address));
      expect(out, isNot(contains('old 77-byte layout')));
      expect(out, contains('pending admin: ${key(4)}'));
      expect(out, contains('treasury:      $treasury'));
      expect(out, contains('fee public:    200 bps (2%'));
      expect(out, contains('fee private:   200 bps (2%'));
      expect(out, contains('SKR mint:      $skr'));
      expect(out, contains('fee SKR:       150 bps (1.5%'));
      expect(out, contains('SKR burned:    1000 bps (10%'));
    });

    test('an old-layout config without an SKR rate', () {
      final out = describeConfig(
        DeadmanConfig(
          admin: admin,
          migrated: false,
          fees: FeeSchedule(
            treasury: treasury,
            feeBpsPublic: 50,
            feeBpsPrivate: 50,
          ),
        ),
      );
      expect(out, contains('old 77-byte layout'));
      expect(out, contains('pending admin: none'));
      expect(out, contains('SKR rate:      off'));
      expect(out, contains('fee public:    50 bps (0.5%'));
    });
  });
}
