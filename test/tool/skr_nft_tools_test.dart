import 'dart:convert';

import 'package:deadman/solana/codec.dart';
import 'package:deadman/solana/deadman_api.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../tool/create_test_nft.dart';
import '../../tool/e2e_skr_nft.dart';
import '../../tool/set_config.dart' show devnetRpc;
import '../solana/helpers.dart';

void main() {
  group('create_test_nft', () {
    test('defaults to the demo skull on devnet', () {
      final a = parseNftArgs(['--keypair', 'k.json']);
      expect(a.name, 'Deadman Test Skull');
      expect(a.symbol, 'DMSK');
      expect(a.uri, '');
      expect(a.to, isNull);
      expect(a.rpc, devnetRpc);
      expect(parseNftArgs(['--keypair', 'k.json', '--to', key(1)]).to, key(1));
    });

    test('rejects a missing keypair, a bad wallet and overlong fields', () {
      for (final argv in [
        <String>[],
        ['--keypair', 'k.json', '--to', 'nope'],
        ['--keypair', 'k.json', '--name', 'x' * 33],
        ['--keypair', 'k.json', '--symbol', 'x' * 11],
        ['--keypair', 'k.json', '--uri', 'x' * 201],
        ['--keypair'],
      ]) {
        expect(
          () => parseNftArgs(argv),
          throwsFormatException,
          reason: '$argv',
        );
      }
    });

    test('CreateMetadataAccountV3 data: borsh strings, no extras', () {
      final d = createMetadataV3Data(name: 'Skull', symbol: 'DMSK', uri: '');
      expect(d.first, 33);
      final r = BorshReader(d)..offset = 1;
      expect(r.string(), 'Skull');
      expect(r.string(), 'DMSK');
      expect(r.string(), '');
      // royalties 0, creators/collection/uses None, mutable, no details.
      expect(d.sublist(r.offset), [0, 0, 0, 0, 0, 1, 0]);
      expect(createMasterEditionV3Data(), [17, 1, 0, 0, 0, 0, 0, 0, 0, 0]);
    });

    test(
      'creates a 0-decimal mint of 1 with metadata and a master edition',
      () {
        final authority = key(2);
        final mint = key(3);
        final ixs = createNftIxs(
          authority: authority,
          mint: mint,
          mintRent: 1461600,
          name: 'Skull',
          symbol: 'DMSK',
          uri: '',
        );
        expect(ixs, hasLength(6));
        // initializeMint: decimals 0, mint and freeze authority = authority.
        final init = ixs[1].data.toList();
        expect(init[1], 0);
        expect(init[34], 1);
        // mintTo amount 1 into the authority's ATA.
        expect(
          ixs[3].accounts[1].pubKey.toBase58(),
          ataAddress(authority, mint),
        );
        final meta = ixs[4];
        expect(meta.programId.toBase58(), tokenMetadataProgramId);
        expect(meta.accounts.first.pubKey.toBase58(), metadataPda(mint));
        final edition = ixs[5];
        expect(edition.accounts.first.pubKey.toBase58(), editionPda(mint));
        expect(edition.accounts[1].isWriteable, isTrue);
        expect(edition.accounts[5].pubKey.toBase58(), metadataPda(mint));
      },
    );
  });

  group('e2e_skr_nft', () {
    test('parses --dry-run and the SKR mint; refuses mainnet', () {
      final a = parseE2eArgs(['--dry-run']);
      expect(a.dryRun, isTrue);
      expect(a.skrMint, '4JX81qZWhPPT38Tn4ZswaS2DyH3PffdrFqbYgsoZCuHc');
      expect(a.rpc, devnetRpc);
      expect(parseE2eArgs(['--skr-mint', key(4)]).dryRun, isFalse);
      expect(
        () => parseE2eArgs(['--rpc', 'https://api.mainnet-beta.solana.com']),
        throwsFormatException,
      );
      expect(() => parseE2eArgs(['--skr-mint', 'x']), throwsFormatException);
    });

    test('reads the burned amount from the FeeBurned event of the vault', () {
      final vault = key(5);
      final mint = key(6);
      String event(String v, String m, int burned) {
        final w = BorshWriter()
          ..bytes(Disc.feeBurnedEvent)
          ..pubkey(v)
          ..pubkey(m)
          ..u64(burned);
        return 'Program data: ${base64.encode(w.toBytes())}';
      }

      final logs = [
        'Program log: Instruction: ExecuteTokenRule',
        'Program data: !!not base64',
        event(key(7), mint, 9),
        event(vault, mint, 27),
      ];
      expect(burnedFromLogs(logs, vault, mint), 27);
      expect(burnedFromLogs(logs, vault, key(8)), isNull);
      expect(burnedFromLogs(const [], vault, mint), isNull);
    });

    test('an SKR payout: 1.5% fee, 10% of it burned, the rest to the '
        'treasury', () {
      final skr = key(9);
      final fees = FeeSchedule(
        treasury: key(10),
        feeBpsPublic: 200,
        feeBpsPrivate: 200,
        skrMint: skr,
        feeBpsSkr: 150,
        skrBurnBps: 1000,
      );
      expect(skrSplit(fees, skr, 10000000), (
        net: 9850000,
        fee: 150000,
        burned: 15000,
        toTreasury: 135000,
      ));
      // Another mint pays the 2% rate and burns nothing.
      expect(skrSplit(fees, key(11), 10000000), (
        net: 9800000,
        fee: 200000,
        burned: 0,
        toTreasury: 200000,
      ));
    });
  });
}
