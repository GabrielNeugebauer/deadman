import 'dart:convert';
import 'dart:typed_data';

import 'package:deadman/rails/earn_jupiter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:solana/base58.dart';

String key(int seed) =>
    base58encode(List<int>.generate(32, (i) => (seed * 31 + i * 7) & 0xff));

List<int> keyBytes(String k) => base58decode(k);

/// Minimal v0 transaction: [signers] then [others], no instructions or ALTs.
Uint8List v0Tx(List<String> signers, {List<String> others = const []}) {
  final b = <int>[
    signers.length,
    for (var i = 0; i < signers.length * 64; i++) 0,
    0x80,
    signers.length,
    0,
    others.length,
    signers.length + others.length,
    for (final k in [...signers, ...others]) ...keyBytes(k),
    ...List<int>.filled(32, 9),
    0,
    0,
  ];
  return Uint8List.fromList(b);
}

Uint8List signed(Uint8List tx) {
  final out = Uint8List.fromList(tx);
  for (var i = 1; i < 65; i++) {
    out[i] = 0xAB;
  }
  return out;
}

/// `/order` response shape from developers.jup.ag (Swap API V2).
Map<String, Object?> orderBody({
  required Uint8List tx,
  String inputMint = kWsolMint,
  String outputMint = kJitoSolMint,
  String inAmount = '1000000000',
  String? referralAccount,
  int feeBps = 50,
}) => {
  'mode': referralAccount == null ? 'ultra' : 'manual',
  'inputMint': inputMint,
  'outputMint': outputMint,
  'inAmount': inAmount,
  'outAmount': '767327099',
  'otherAmountThreshold': '763490464',
  'swapMode': 'ExactIn',
  'slippageBps': 50,
  'priceImpact': -0.01,
  'routePlan': <Object>[],
  'referralAccount': ?referralAccount,
  'feeMint': kWsolMint,
  'feeBps': feeBps,
  'platformFee': {'amount': '0', 'feeBps': 0, 'feeMint': kWsolMint},
  'signatureFeeLamports': 5000,
  'prioritizationFeeLamports': 10000,
  'rentFeeLamports': 0,
  'router': 'metis',
  'transaction': base64Encode(tx),
  'lastValidBlockHeight': '400000000',
  'gasless': false,
  'requestId': 'req-1',
  'totalTime': 300,
};

/// Kobe `stake_pool_stats` shape: `apy[].data` is a fraction.
const jitoStats = {
  'aggregated_mev_rewards': 1,
  'apy': [
    {'data': 0.0477, 'date': '2026-09-30T23:58:00Z'},
    {'data': 0.04814, 'date': '2026-10-01T23:35:35Z'},
  ],
  'tvl': <Object>[],
};

void main() {
  final owner = key(1);
  final vault = key(2);
  final program = key(3);
  final referral = key(4);

  group('JupiterEarn', () {
    test('available only on mainnet-beta', () {
      expect(JupiterEarn(cluster: 'devnet').available, isFalse);
      expect(JupiterEarn(cluster: 'mainnet-beta').available, isTrue);
      expect(JupiterEarn().lstMint, kJitoSolMint);
    });

    test('build refuses off mainnet', () {
      final earn = JupiterEarn(
        cluster: 'devnet',
        client: MockClient((_) async => fail('no request expected')),
      );
      expect(
        () => earn.buildStake(owner: owner, lamports: 1),
        throwsStateError,
      );
    });

    test('rejects referral fee outside 50..255 bps', () {
      expect(
        () => JupiterEarn(referralAccount: referral, referralFeeBps: 30),
        throwsArgumentError,
      );
      expect(
        () => JupiterEarn(referralAccount: referral, referralFeeBps: 300),
        throwsArgumentError,
      );
    });

    test(
      'buildStake requests a fee-bearing order and returns unsigned v0',
      () async {
        final tx = v0Tx([owner], others: [program]);
        late Uri seen;
        late Map<String, String> headers;
        final earn = JupiterEarn(
          cluster: 'mainnet-beta',
          apiKey: 'k',
          referralAccount: referral,
          referralFeeBps: 100,
          client: MockClient((req) async {
            seen = req.url;
            headers = req.headers;
            return http.Response(
              jsonEncode(
                orderBody(tx: tx, referralAccount: referral, feeBps: 100),
              ),
              200,
            );
          }),
        );

        final out = await earn.buildStake(
          owner: owner,
          lamports: 1000000000,
          receiver: vault,
        );

        expect(out, tx);
        expect(seen.path, '/swap/v2/order');
        expect(seen.queryParameters, {
          'inputMint': kWsolMint,
          'outputMint': kJitoSolMint,
          'amount': '1000000000',
          'taker': owner,
          'receiver': vault,
          'referralAccount': referral,
          'referralFee': '100',
        });
        expect(headers['x-api-key'], 'k');
        final order = earn.orderFor(out)!;
        expect(order.requestId, 'req-1');
        expect(order.outAmount, 767327099);
        expect(order.feeBps, 100);
        expect(order.referralApplied, isTrue);
      },
    );

    test(
      'no fee params or key header when unset; referral fallback flagged',
      () async {
        final tx = v0Tx([owner]);
        late Uri seen;
        late Map<String, String> headers;
        final earn = JupiterEarn(
          cluster: 'mainnet-beta',
          apiKey: '',
          referralAccount: '',
          client: MockClient((req) async {
            seen = req.url;
            headers = req.headers;
            return http.Response(jsonEncode(orderBody(tx: tx, feeBps: 0)), 200);
          }),
        );
        final out = await earn.buildStake(owner: owner, lamports: 1000000000);
        expect(seen.queryParameters.containsKey('referralAccount'), isFalse);
        expect(seen.queryParameters.containsKey('receiver'), isFalse);
        expect(headers.containsKey('x-api-key'), isFalse);
        expect(earn.orderFor(out)!.referralApplied, isFalse);
      },
    );

    test('buildUnstake swaps LST to SOL', () async {
      final tx = v0Tx([owner]);
      late Uri seen;
      final earn = JupiterEarn(
        cluster: 'mainnet-beta',
        referralAccount: '',
        client: MockClient((req) async {
          seen = req.url;
          return http.Response(
            jsonEncode(
              orderBody(
                tx: tx,
                inputMint: kJitoSolMint,
                outputMint: kWsolMint,
                inAmount: '500',
              ),
            ),
            200,
          );
        }),
      );
      await earn.buildUnstake(owner: owner, lstAmount: 500);
      expect(seen.queryParameters['inputMint'], kJitoSolMint);
      expect(seen.queryParameters['outputMint'], kWsolMint);
      expect(seen.queryParameters['amount'], '500');
    });

    test('rejects a transaction the owner does not sign', () async {
      final earn = JupiterEarn(
        cluster: 'mainnet-beta',
        referralAccount: '',
        client: MockClient(
          (_) async => http.Response(
            jsonEncode(orderBody(tx: v0Tx([key(9)], others: [owner]))),
            200,
          ),
        ),
      );
      expect(
        earn.buildStake(owner: owner, lamports: 1000000000),
        throwsA(isA<JupiterException>()),
      );
    });

    test('rejects legacy transactions and mismatched amounts', () async {
      final v0 = v0Tx([owner]);
      final legacy = Uint8List.fromList([
        ...v0.sublist(0, 65),
        ...v0.sublist(66),
      ]);
      JupiterEarn mk(Map<String, Object?> body) => JupiterEarn(
        cluster: 'mainnet-beta',
        referralAccount: '',
        client: MockClient((_) async => http.Response(jsonEncode(body), 200)),
      );
      await expectLater(
        mk(orderBody(tx: legacy))
            .buildStake(owner: owner, lamports: 1000000000),
        throwsA(isA<JupiterException>()),
      );
      await expectLater(
        mk(orderBody(tx: v0Tx([owner]), inAmount: '1'))
            .buildStake(owner: owner, lamports: 1000000000),
        throwsA(isA<JupiterException>()),
      );
    });

    test('surfaces order errorCode when no transaction is built', () async {
      final body = orderBody(tx: Uint8List(0))
        ..['transaction'] = ''
        ..['errorCode'] = 1
        ..['errorMessage'] = 'Insufficient funds';
      final earn = JupiterEarn(
        cluster: 'mainnet-beta',
        referralAccount: '',
        client: MockClient((_) async => http.Response(jsonEncode(body), 200)),
      );
      await expectLater(
        earn.buildStake(owner: owner, lamports: 1000000000),
        throwsA(
          isA<JupiterException>()
              .having((e) => e.code, 'code', 1)
              .having(
                (e) => e.message,
                'message',
                contains('Insufficient funds'),
              ),
        ),
      );
    });

    test('HTTP errors become JupiterException', () async {
      final earn = JupiterEarn(
        cluster: 'mainnet-beta',
        referralAccount: '',
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({'code': 429, 'message': 'Rate limit exceeded'}),
            429,
          ),
        ),
      );
      await expectLater(
        earn.buildStake(owner: owner, lamports: 1000000000),
        throwsA(isA<JupiterException>().having((e) => e.code, 'code', 429)),
      );
    });

    test('execute posts MWA-signed bytes with the order requestId', () async {
      final tx = v0Tx([owner]);
      Map<String, dynamic>? posted;
      final earn = JupiterEarn(
        cluster: 'mainnet-beta',
        referralAccount: '',
        client: MockClient((req) async {
          if (req.method == 'GET') {
            return http.Response(jsonEncode(orderBody(tx: tx)), 200);
          }
          expect(req.url.path, '/swap/v2/execute');
          posted = jsonDecode(req.body) as Map<String, dynamic>;
          return http.Response(
            jsonEncode({
              'status': 'Success',
              'signature': '5sig',
              'code': 0,
              'totalInputAmount': '1000000000',
              'totalOutputAmount': '767327099',
              'inputAmountResult': '995000000',
              'outputAmountResult': '767327099',
            }),
            200,
          );
        }),
      );
      final unsigned = await earn.buildStake(
        owner: owner,
        lamports: 1000000000,
      );
      final s = signed(unsigned);
      expect(earn.orderFor(s), isNotNull);

      expect(await earn.execute(s), '5sig');
      expect(posted, {
        'signedTransaction': base64Encode(s),
        'requestId': 'req-1',
      });
      expect(earn.orderFor(s), isNull);
    });

    test('execute failure carries the Jupiter code', () async {
      final tx = v0Tx([owner]);
      final earn = JupiterEarn(
        cluster: 'mainnet-beta',
        referralAccount: '',
        client: MockClient(
          (req) async => req.method == 'GET'
              ? http.Response(jsonEncode(orderBody(tx: tx)), 200)
              : http.Response(
                  jsonEncode({
                    'status': 'Failed',
                    'signature': '5sig',
                    'code': -1000,
                    'error': 'Failed to land',
                  }),
                  200,
                ),
        ),
      );
      final unsigned = await earn.buildStake(
        owner: owner,
        lamports: 1000000000,
      );
      await expectLater(
        earn.execute(signed(unsigned)),
        throwsA(isA<JupiterException>().having((e) => e.code, 'code', -1000)),
      );
    });

    test('execute rejects unknown transactions', () async {
      final earn = JupiterEarn(
        cluster: 'mainnet-beta',
        client: MockClient((_) async => fail('no request expected')),
      );
      await expectLater(
        earn.execute(v0Tx([owner])),
        throwsA(isA<JupiterException>()),
      );
    });

    test('apyBps reads the latest Jito APY and caches it', () async {
      var calls = 0;
      var now = DateTime.utc(2026, 10, 2);
      final earn = JupiterEarn(
        now: () => now,
        client: MockClient((req) async {
          calls++;
          expect(req.url.toString(), kJitoStatsUrl);
          return http.Response(jsonEncode(jitoStats), 200);
        }),
      );
      expect(await earn.apyBps(), 481);
      expect(await earn.apyBps(), 481);
      expect(calls, 1);
      now = now.add(const Duration(hours: 1));
      await earn.apyBps();
      expect(calls, 2);
    });

    test('apyBps rejects an empty series', () async {
      final earn = JupiterEarn(
        client: MockClient(
          (_) async => http.Response(jsonEncode({'apy': []}), 200),
        ),
      );
      await expectLater(earn.apyBps(), throwsA(isA<JupiterException>()));
    });
  });
}
