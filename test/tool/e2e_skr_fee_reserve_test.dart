import 'dart:convert';

import 'package:deadman/solana/codec.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../tool/e2e_skr_fee_reserve.dart';
import '../../tool/set_config.dart' show devnetRpc, devnetSkrMint;
import '../solana/helpers.dart';

void main() {
  test('parseE2eArgs: devnet test SKR by default, devnet only', () {
    final a = parseE2eArgs(['--dry-run']);
    expect(a.dryRun, isTrue);
    expect(a.skrMint, devnetSkrMint);
    expect(a.rpc, devnetRpc);
    expect(parseE2eArgs(['--skr-mint', key(3)]).skrMint, key(3));
    for (final argv in [
      ['--skr-mint', 'nope'],
      ['--rpc', 'https://api.mainnet-beta.solana.com'],
      ['--keypair', 'k.json'],
      ['extra'],
    ]) {
      expect(() => parseE2eArgs(argv), throwsFormatException, reason: '$argv');
    }
  });

  test('skrFeePaidFromLogs reads the SkrFeePaid event of the vault', () {
    String event(String vault, int index, int fee, int burned) =>
        'Program data: ${base64.encode([...Disc.skrFeePaidEvent, ...keyBytes(vault), index, ...le(8, fee), ...le(8, burned)])}';
    final logs = [
      'Program log: Instruction: ExecuteSolRule',
      'Program data: not base64!',
      event(key(5), 0, 999, 99),
      event(key(4), 2, 75000000, 7500000),
    ];
    expect(skrFeePaidFromLogs(logs, key(4)), (
      vault: key(4),
      index: 2,
      fee: 75000000,
      burned: 7500000,
    ));
    expect(skrFeePaidFromLogs(logs, key(6)), isNull);
  });

  test('nearQuote allows 2% or one unit', () {
    expect(nearQuote(10200, 10000), isTrue);
    expect(nearQuote(9800, 10000), isTrue);
    expect(nearQuote(10201, 10000), isFalse);
    expect(nearQuote(2, 1), isTrue);
    expect(nearQuote(3, 1), isFalse);
  });
}
