import 'package:deadman/solana/codec.dart';
import 'package:deadman/solana/deadman_api.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../tool/set_subscription.dart';
import '../solana/helpers.dart';

void main() {
  final mint = key(6);

  test('defaults: 30-day periods, 12 minimum, devnet', () {
    final a = parseArgs([
      '--keypair',
      'admin.json',
      '--price',
      '4990000',
      '--mint',
      mint,
      '--enable',
    ]);
    expect(a.keypair, 'admin.json');
    expect(a.price, 4990000);
    expect(a.periodSecs, 30 * 86400);
    expect(a.minPeriods, 12);
    expect(a.mint, mint);
    expect(a.enabled, isTrue);
    expect(a.rpc, devnetRpc);
    expect(a.mainnet, isFalse);
  });

  test('explicit terms, --disable, --rpc and --mainnet', () {
    final a = parseArgs([
      '--keypair',
      'k',
      '--price',
      '1',
      '--period-days',
      '7',
      '--min-periods',
      '4',
      '--mint',
      mint,
      '--disable',
      '--rpc',
      'http://localhost:8899',
      '--mainnet',
    ]);
    expect(a.periodSecs, 7 * 86400);
    expect(a.minPeriods, 4);
    expect(a.enabled, isFalse);
    expect(a.rpc, 'http://localhost:8899');
    expect(a.mainnet, isTrue);
  });

  test('rejects what the program would, and missing arguments', () {
    List<String> base(List<String> extra) => [
      '--keypair',
      'k',
      '--mint',
      mint,
      '--enable',
      ...extra,
    ];
    for (final argv in [
      base(['--price', '0']),
      base(['--price', '1', '--period-days', '0']),
      base(['--price', '1', '--period-days', '367']),
      base(['--price', '1', '--min-periods', '0']),
      base(['--price', '1', '--min-periods', '37']),
      base([]),
      ['--keypair', 'k', '--price', '1', '--mint', mint],
      [
        ...base(['--price', '1']),
        '--disable',
      ],
      ['--keypair', 'k', '--price', '1', '--mint', 'nope', '--enable'],
      ['--keypair', 'k', '--price', '1', '--mint', defaultPubkey, '--enable'],
    ]) {
      expect(() => parseArgs(argv), throwsFormatException, reason: '$argv');
    }
  });

  test('describeTerms prints the price in whole tokens', () {
    final out = describeTerms(
      SubscriptionTerms(
        pricePerPeriod: 4990000,
        periodSecs: 30 * 86400,
        mint: mint,
        minPeriods: 12,
      ),
      6,
    );
    expect(out, contains(subConfigPda().address));
    expect(out, contains('4990000 base units (4.99)'));
    expect(out, contains('30 days'));
    expect(out, contains('min periods:      12'));
    expect(out, contains('enabled:          true'));
  });
}
