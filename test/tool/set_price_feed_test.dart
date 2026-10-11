import 'package:deadman/core/config.dart';
import 'package:deadman/solana/codec.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:solana/solana.dart' show SystemProgram;

import '../../tool/set_config.dart' show devnetRpc;
import '../../tool/set_price_feed.dart';
import '../solana/helpers.dart';

Map<String, dynamic> idlIx(String name) => (loadIdl()['instructions'] as List)
    .cast<Map<String, dynamic>>()
    .firstWhere((i) => i['name'] == name);

void main() {
  group('parseArgs', () {
    test('--asset picks the devnet test mints and their feeds', () {
      for (final (asset, mint, feed) in [
        ('sol', nativeMint, PythFeedIds.solUsd),
        (
          'usdc',
          'Ew8Z6hhRp7MFK8KJAxRqaBQvBEjtRj4Y4K4YhWsPMFGk',
          PythFeedIds.usdcUsd,
        ),
        (
          'skr',
          '4JX81qZWhPPT38Tn4ZswaS2DyH3PffdrFqbYgsoZCuHc',
          PythFeedIds.skrUsd,
        ),
        (
          'ORE',
          '6KdRjrWYouFLmEcNeDpJkc9AUgzvmE7cn3DbAx2KfSyt',
          PythFeedIds.oreUsd,
        ),
      ]) {
        final a = parseArgs(['--keypair', 'admin.json', '--asset', asset]);
        expect(a.show, isFalse);
        expect(a.mint, mint, reason: asset);
        expect(a.feedId, feed, reason: asset);
        expect(a.shard, 0);
        expect(a.maxAgeSecs, defaultMaxAgeSecs);
        expect(a.rpc, devnetRpc);
        expect(a.mainnet, isFalse);
      }
    });

    test('the devnet presets are the app test mints', () {
      expect(devnetPresets['usdc']!.mint, AppConfig.usdcMint);
      expect(devnetPresets['skr']!.mint, AppConfig.skrMint);
      expect(devnetPresets['ore']!.mint, AppConfig.oreMint);
      expect(devnetPresets.containsKey('jitosol'), isFalse);
    });

    test('--mainnet picks the real mints; JitoSOL only there', () {
      final a = parseArgs([
        '--keypair',
        'admin.json',
        '--asset',
        'jitosol',
        '--mainnet',
      ]);
      expect(a.mint, 'J1toso1uCk3RLmjorhTtrVwY9HJ7X8V9yYac6Y7kGCPn');
      expect(a.feedId, PythFeedIds.jitoSolUsd);
      expect(a.mainnet, isTrue);
      expect(
        parseArgs(['--keypair', 'admin.json', '--asset', 'skr', '--mainnet'])
            .mint,
        'SKRbvo6Gf7GondiT3BbTfuRDPqLWei4j2Qy2NPGZhW3',
      );
      expect(
        () => parseArgs(['--keypair', 'admin.json', '--asset', 'jitosol']),
        throwsFormatException,
      );
    });

    test('--mint and --feed-id register any feed', () {
      final a = parseArgs([
        '--keypair',
        'admin.json',
        '--mint',
        key(7),
        '--feed-id',
        '0x${'AB' * 32}',
        '--shard',
        '3',
        '--max-age',
        '0',
      ]);
      expect(a.mint, key(7));
      expect(a.feedId, 'ab' * 32);
      expect(a.shard, 3);
      expect(a.maxAgeSecs, 0);
      expect(a.symbol, isNull);
    });

    test('show takes only --rpc and --mainnet', () {
      final a = parseArgs(['show', '--rpc', 'http://x']);
      expect(a.show, isTrue);
      expect(a.keypair, isNull);
      expect(a.rpc, 'http://x');
      expect(
        () => parseArgs(['show', '--asset', 'sol']),
        throwsFormatException,
      );
    });

    test('rejects bad input', () {
      for (final argv in [
        <String>[],
        ['--asset', 'sol'],
        ['--keypair', 'k.json'],
        ['--keypair', 'k.json', '--asset', 'btc'],
        ['--keypair', 'k.json', '--asset', 'sol', '--mint', key(7)],
        ['--keypair', 'k.json', '--mint', key(7)],
        ['--keypair', 'k.json', '--mint', 'nope', '--feed-id', 'ab' * 32],
        [
          '--keypair',
          'k.json',
          '--mint',
          defaultPubkey,
          '--feed-id',
          'ab' * 32,
        ],
        ['--keypair', 'k.json', '--mint', key(7), '--feed-id', 'ab' * 31],
        ['--keypair', 'k.json', '--mint', key(7), '--feed-id', 'zz' * 32],
        ['--keypair', 'k.json', '--asset', 'sol', '--max-age', '3601'],
        ['--keypair', 'k.json', '--asset', 'sol', '--max-age', '-1'],
        ['--keypair', 'k.json', '--asset', 'sol', '--shard', '65536'],
        ['register', '--keypair', 'k.json'],
        ['--keypair'],
      ]) {
        expect(() => parseArgs(argv), throwsFormatException, reason: '$argv');
      }
    });
  });

  test('the registered price accounts are the live shard-0 accounts', () {
    expect(
      pythPriceAccount(devnetPresets['sol']!.feedId),
      '7UVimffxr9ow1uXYxsr4LHAcV58mLzhmwaeKvJ1pjLiE',
    );
    expect(
      pythPriceAccount(devnetPresets['usdc']!.feedId),
      'Dpw1EAVrSB1ibxiDQyTAW6Zip3J4Btk2x4SgApQCeFbX',
    );
    expect(
      pythPriceAccount(devnetPresets['skr']!.feedId),
      'AFrJWhfWt3vDtGPdcwTyLyHz8ZQ4M9L2z1YHThY5Vbj5',
    );
    expect(
      pythPriceAccount(devnetPresets['ore']!.feedId),
      'GYYQ8gbX4Tndc4WMJ9jSjZTePTvbmgRRxByt54ZQYqvZ',
    );
  });

  test('set_price_feed matches the IDL accounts and args', () {
    final ix = setPriceFeedIx(
      admin: key(1),
      mint: nativeMint,
      feedId: PythFeedIds.solUsd,
      maxAgeSecs: defaultMaxAgeSecs,
    );
    final idl = idlIx('set_price_feed');
    expect(ix.accounts.map((a) => a.pubKey.toBase58()).toList(), [
      key(1),
      configPda().address,
      priceFeedPda(nativeMint).address,
      SystemProgram.programId,
    ]);
    expect(ix.accounts.length, (idl['accounts'] as List).length);
    expect(ix.accounts[0].isSigner && ix.accounts[0].isWriteable, isTrue);
    expect(ix.accounts[2].isWriteable, isTrue);
    final data = ix.data.toList();
    expect(data.sublist(0, 8), (idl['discriminator'] as List).cast<int>());
    // mint (32) + feed id (32) + shard u16 + max age u32.
    expect(data.length, 8 + 32 + 32 + 2 + 4);
    expect(data.sublist(72, 74), [0, 0]);
    expect(data.sublist(74), le(4, defaultMaxAgeSecs));
  });

  group('priceProblem', () {
    const now = 1790000000;
    final feed = (
      mint: nativeMint,
      feedId: PythFeedIds.solUsd,
      priceAccount: pythPriceAccount(PythFeedIds.solUsd),
      maxAgeSecs: 600,
    );
    List<int> update({
      String feedId = PythFeedIds.solUsd,
      int price = 15000000000,
      int conf = 10000000,
      int age = 30,
      bool full = true,
    }) => priceUpdateBytes(
      feedId: feedId,
      price: price,
      expo: -8,
      publishTime: now - age,
      conf: conf,
      full: full,
    );

    test('a fresh, full, tight price is usable', () {
      expect(priceProblem(feed, pythReceiverId, update(), now), isNull);
      expect(priceProblem(feed, pythReceiverId, update(age: 600), now), isNull);
      // conf exactly 2% of the price.
      expect(
        priceProblem(feed, pythReceiverId, update(conf: 300000000), now),
        isNull,
      );
    });

    test('mirrors every reason the program skips a price', () {
      for (final (owner, data, f, why) in [
        (key(9), update(), feed, 'not owned by the Pyth receiver'),
        (pythReceiverId, update(age: 601), feed, 'stale'),
        (pythReceiverId, update(full: false), feed, 'partially verified'),
        (
          pythReceiverId,
          update(feedId: PythFeedIds.skrUsd),
          feed,
          'holds feed',
        ),
        (pythReceiverId, update(price: 0), feed, 'not positive'),
        (pythReceiverId, update(price: -5), feed, 'not positive'),
        (pythReceiverId, update(conf: 300000001), feed, 'confidence'),
        (
          pythReceiverId,
          update(),
          (
            mint: feed.mint,
            feedId: feed.feedId,
            priceAccount: feed.priceAccount,
            maxAgeSecs: 0,
          ),
          'disabled',
        ),
        (pythReceiverId, [1, 2, 3], feed, 'Not a'),
      ]) {
        expect(priceProblem(f, owner, data, now), contains(why));
      }
    });

    test('formats the price with its exponent', () {
      String fmt(int price, int expo) => formatPrice((
        feedId: '',
        price: price,
        conf: 0,
        expo: expo,
        publishTime: 0,
        full: true,
      ));
      expect(fmt(11049439383, -8), '110.49439383');
      expect(fmt(99985944, -8), '0.99985944');
      expect(fmt(-5, -2), '-0.05');
      expect(fmt(42, 2), '4200');
    });
  });
}
