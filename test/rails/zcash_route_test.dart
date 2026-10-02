import 'dart:convert';

import 'package:deadman/rails/rails.dart';
import 'package:deadman/rails/zcash_route.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:solana/encoder.dart';
import 'package:solana/solana.dart';

// Captured from https://1click.chaindefuser.com on 2026-10-02 (no funds sent).
const dryQuoteSol =
    r'''{"quote":{"amountIn":"1000000000","amountInFormatted":"1.0","amountInUsd":"118.980000000000","minAmountIn":"1000000000","amountOut":"8848584","amountOutFormatted":"0.08848584","amountOutUsd":"118.980000000000","minAmountOut":"8760098","timeEstimate":135,"refundFee":"86690","withdrawFee":"32000"},"quoteRequest":{"dry":true,"depositMode":"SIMPLE","swapType":"EXACT_INPUT","slippageTolerance":100,"originAsset":"nep141:sol.omft.near","depositType":"ORIGIN_CHAIN","destinationAsset":"nep141:zec.omft.near","amount":"1000000000","refundTo":"13QkxhNMrTPxoCkRdYdJ65tFuwXPhL5gLS2Z5Nr6gjRK","refundType":"ORIGIN_CHAIN","recipient":"u1cv7rewjqmj395gla0zzfz669ntf6cr5hx9n983ct5t4dv0gphgyg5qjqe5re6ue5menlw94876wp0q90uf2cskh75rfvfejr564x8heq9zrs5p40n0fhqvehy8sjgxy0eu58l87w2mk48y3j07ggvgw5z5lncusl6y2a03rqau44ha2g","recipientType":"DESTINATION_CHAIN","deadline":"2026-10-02T18:57:30.000Z","confidentiality":"public","quoteWaitingTimeMs":0,"insured":false,"appFees":[{"recipient":"5880ad2b362620fadf759cbceb1cd5737ce8c6ed7fb8e9942881e6731f9247dd","fee":20}]},"signature":"ed25519:2ropA8ZmwCtjhAWYvXM6AgK2YuxqWz8sVn8uoUxTtavHCZ9t9mddVurBzYXGtTcSbrjMgGFCP67UpnSKoqx2omrT","timestamp":"2026-10-02T18:27:31.021Z","correlationId":"f26391dd-2073-4a43-8903-ec31619e0ce2"}''';
const quoteUsdc =
    r'''{"quote":{"amountIn":"5000000","amountInFormatted":"5.0","amountInUsd":"4.999690000000","minAmountIn":"5000000","amountOut":"340565","amountOutFormatted":"0.00340565","amountOutUsd":"4.575899453000","minAmountOut":"337159","timeEstimate":137,"refundFee":"318834","withdrawFee":"32000","deadline":"2026-10-05T18:59:39.000Z","timeWhenInactive":"2026-10-05T18:59:39.000Z","depositAddress":"E5RdW4ip1B4wx1Loy83zr2dVadYywJazHvB22JBKq1Dg"},"quoteRequest":{"dry":false,"depositMode":"SIMPLE","swapType":"EXACT_INPUT","slippageTolerance":100,"originAsset":"nep141:sol-5ce3bf3a31af18be40ba30f721101b4341690186.omft.near","depositType":"ORIGIN_CHAIN","destinationAsset":"nep141:zec.omft.near","amount":"5000000","refundTo":"13QkxhNMrTPxoCkRdYdJ65tFuwXPhL5gLS2Z5Nr6gjRK","refundType":"ORIGIN_CHAIN","recipient":"u1cv7rewjqmj395gla0zzfz669ntf6cr5hx9n983ct5t4dv0gphgyg5qjqe5re6ue5menlw94876wp0q90uf2cskh75rfvfejr564x8heq9zrs5p40n0fhqvehy8sjgxy0eu58l87w2mk48y3j07ggvgw5z5lncusl6y2a03rqau44ha2g","recipientType":"DESTINATION_CHAIN","deadline":"2026-10-02T18:59:39.000Z","confidentiality":"public","referral":"deadman","quoteWaitingTimeMs":0,"insured":false,"appFees":[{"recipient":"5880ad2b362620fadf759cbceb1cd5737ce8c6ed7fb8e9942881e6731f9247dd","fee":20,"limitOrderId":null}]},"signature":"ed25519:4hT7wJUSrkvuhbHAUdFC7HmtrPoCPzgUzqvZT5iwgLZWnKDWEucjKi1pvamzHVLA4q3ZFEGav6WYpiGeHEjGZ4Pt","timestamp":"2026-10-02T18:29:39.675Z","correlationId":"48837116-8c91-41b3-89b3-3cb2469865eb"}''';
const statusPending =
    r'''{"status":"PENDING_DEPOSIT","updatedAt":"2026-10-02T18:29:40.097Z","correlationId":"92820c1f-f3cb-4c4c-91d9-d8428a3fc124","swapDetails":{"depositedAmount":null,"depositedAmountUsd":null,"depositedAmountFormatted":null,"intentHashes":[],"nearTxHashes":[],"amountIn":null,"amountInFormatted":null,"amountInUsd":null,"amountOut":null,"amountOutFormatted":null,"amountOutUsd":null,"slippage":null,"refundedAmount":"0","refundedAmountFormatted":"0","refundedAmountUsd":"0","refundReason":null,"refundFee":"318834","withdrawFee":"32000","originChainTxHashes":[],"destinationChainTxHashes":[]},"quoteResponse":{"timestamp":"2026-10-02T18:29:39.675Z","signature":"ed25519:4hT7wJUSrkvuhbHAUdFC7HmtrPoCPzgUzqvZT5iwgLZWnKDWEucjKi1pvamzHVLA4q3ZFEGav6WYpiGeHEjGZ4Pt","quoteRequest":{"dry":false,"swapType":"EXACT_INPUT","depositMode":"SIMPLE","slippageTolerance":100,"originAsset":"nep141:sol-5ce3bf3a31af18be40ba30f721101b4341690186.omft.near","depositType":"ORIGIN_CHAIN","destinationAsset":"nep141:zec.omft.near","amount":"5000000","refundTo":"13QkxhNMrTPxoCkRdYdJ65tFuwXPhL5gLS2Z5Nr6gjRK","refundType":"ORIGIN_CHAIN","recipient":"u1cv7rewjqmj395gla0zzfz669ntf6cr5hx9n983ct5t4dv0gphgyg5qjqe5re6ue5menlw94876wp0q90uf2cskh75rfvfejr564x8heq9zrs5p40n0fhqvehy8sjgxy0eu58l87w2mk48y3j07ggvgw5z5lncusl6y2a03rqau44ha2g","recipientType":"DESTINATION_CHAIN","deadline":"2026-10-02T18:59:39.000Z","appFees":[{"limitOrderId":null,"recipient":"5880ad2b362620fadf759cbceb1cd5737ce8c6ed7fb8e9942881e6731f9247dd","fee":20}],"virtualChainRecipient":null,"virtualChainRefundRecipient":null,"referral":"deadman","confidentiality":"public"},"quote":{"amountIn":"5000000","amountInFormatted":"5.0","amountInUsd":"4.999690000000","minAmountIn":"5000000","amountOut":"340565","amountOutFormatted":"0.00340565","amountOutUsd":"4.575899453000","minAmountOut":"337159","timeWhenInactive":"2026-10-05T18:59:39.000Z","depositAddress":"E5RdW4ip1B4wx1Loy83zr2dVadYywJazHvB22JBKq1Dg","deadline":"2026-10-05T18:59:39.000Z","timeEstimate":137,"refundFee":"318834","withdrawFee":"32000"}}}''';

const u1 =
    'u1cv7rewjqmj395gla0zzfz669ntf6cr5hx9n983ct5t4dv0gphgyg5qjqe5re6ue5menlw94876wp0q90uf2cskh75rfvfejr564x8heq9zrs5p40n0fhqvehy8sjgxy0eu58l87w2mk48y3j07ggvgw5z5lncusl6y2a03rqau44ha2g';
const fixtureRefund = '13QkxhNMrTPxoCkRdYdJ65tFuwXPhL5gLS2Z5Nr6gjRK';
const usdc = 'EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v';
const rpc = 'https://rpc.test';
final quotedAt = DateTime.utc(2026, 10, 2, 18, 29, 39);

class Recorder {
  final requests = <http.Request>[];
  late final client = MockClient((req) async {
    requests.add(req);
    return handler(req);
  });
  Future<http.Response> Function(http.Request) handler = (_) async =>
      http.Response('{}', 500);

  Iterable<http.Request> to(String path) =>
      requests.where((r) => r.url.path == path);
}

ZcashRoute route(
  Recorder r, {
  String cluster = 'mainnet-beta',
  String fee = '',
}) => ZcashRoute(
  client: r.client,
  cluster: cluster,
  rpcUrl: rpc,
  appFeeRecipient: fee,
  now: () => quotedAt,
);

http.Response json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status);

Map<String, dynamic> body(http.Request r) =>
    jsonDecode(r.body) as Map<String, dynamic>;

void main() {
  group('availability', () {
    test('mainnet only', () {
      final r = Recorder();
      expect(route(r).available, isTrue);
      expect(route(r, cluster: 'devnet').available, isFalse);
      expect(ZcashRoute(client: r.client).available, isFalse);
    });

    test('quote refuses off mainnet without calling out', () async {
      final r = Recorder();
      await expectLater(
        route(r, cluster: 'devnet').quote(
          claimKey: fixtureRefund,
          inputMint: null,
          amount: 1,
          destination: u1,
        ),
        throwsA(isA<ZcashRouteException>()),
      );
      expect(r.requests, isEmpty);
    });
  });

  group('signature', () {
    test('verifies real dry and non-dry quotes', () async {
      expect(
        await ZcashRoute.verifyQuoteSignature(jsonDecode(dryQuoteSol) as Map),
        isTrue,
      );
      expect(
        await ZcashRoute.verifyQuoteSignature(jsonDecode(quoteUsdc) as Map),
        isTrue,
      );
    });

    test('rejects a swapped deposit address', () async {
      final res = jsonDecode(quoteUsdc) as Map;
      (res['quote'] as Map)['depositAddress'] = fixtureRefund;
      expect(await ZcashRoute.verifyQuoteSignature(res), isFalse);
    });
  });

  group('quote', () {
    test('USDC: request fields and parsed quote', () async {
      final r = Recorder()
        ..handler = (_) async => http.Response(quoteUsdc, 201);
      final q = await route(r).quote(
        claimKey: fixtureRefund,
        inputMint: usdc,
        amount: 5000000,
        destination: u1,
      );

      final sent = body(r.to('/v0/quote').single);
      expect(sent['dry'], false);
      expect(sent['swapType'], 'EXACT_INPUT');
      expect(
        sent['originAsset'],
        'nep141:sol-5ce3bf3a31af18be40ba30f721101b4341690186.omft.near',
      );
      expect(sent['destinationAsset'], 'nep141:zec.omft.near');
      expect(sent['amount'], '5000000');
      expect(sent['refundTo'], fixtureRefund);
      expect(sent['refundType'], 'ORIGIN_CHAIN');
      expect(sent['recipient'], u1);
      expect(sent['recipientType'], 'DESTINATION_CHAIN');
      expect(sent['slippageTolerance'], 100);
      expect(sent.containsKey('appFees'), isFalse);
      expect(
        DateTime.parse(sent['deadline'] as String),
        quotedAt.add(const Duration(minutes: 30)),
      );

      expect(q.rail, Rail.zcash);
      expect(q.amountIn, 5000000);
      expect(q.inputMint, usdc);
      expect(q.depositAddress, 'E5RdW4ip1B4wx1Loy83zr2dVadYywJazHvB22JBKq1Dg');
      expect(q.estimatedOut, '0.00340565 ZEC');
      expect(q.expiresAt, DateTime.utc(2026, 10, 2, 18, 59, 39));
    });

    test('sends appFees once a treasury is set', () async {
      final r = Recorder()
        ..handler = (_) async => http.Response(quoteUsdc, 201);
      await route(r, fee: 'deadman.near').quote(
        claimKey: fixtureRefund,
        inputMint: usdc,
        amount: 5000000,
        destination: u1,
      );
      expect(body(r.requests.single)['appFees'], [
        {'recipient': 'deadman.near', 'fee': zcashAppFeeBps},
      ]);
    });

    test('dry estimate has no deposit address', () async {
      final r = Recorder()
        ..handler = (_) async => http.Response(dryQuoteSol, 201);
      final q = await route(r).estimate(
        claimKey: fixtureRefund,
        inputMint: null,
        amount: 1000000000,
        destination: u1,
      );
      expect(body(r.requests.single)['dry'], true);
      expect(body(r.requests.single)['originAsset'], 'nep141:sol.omft.near');
      expect(q.depositAddress, isNull);
      expect(q.estimatedOut, '0.08848584 ZEC');
    });

    test('rejects a tampered quote', () async {
      final res = jsonDecode(quoteUsdc) as Map;
      (res['quote'] as Map)['depositAddress'] = fixtureRefund;
      final r = Recorder()..handler = (_) async => json(res, 201);
      await expectLater(
        route(r).quote(
          claimKey: fixtureRefund,
          inputMint: usdc,
          amount: 5000000,
          destination: u1,
        ),
        throwsA(isA<ZcashRouteException>()),
      );
    });

    test('rejects a quote for another refund key', () async {
      final other = (await Ed25519HDKeyPair.random()).address;
      final r = Recorder()
        ..handler = (_) async => http.Response(quoteUsdc, 201);
      await expectLater(
        route(r).quote(
          claimKey: other,
          inputMint: usdc,
          amount: 5000000,
          destination: u1,
        ),
        throwsA(isA<ZcashRouteException>()),
      );
    });

    test('only unified addresses, no network call otherwise', () async {
      final r = Recorder();
      for (final dest in [
        't1Rv4exT7bqhZqi2j7xz8bUHDMxwosrjADU',
        'zs1notshieldedenough',
        fixtureRefund,
      ]) {
        await expectLater(
          route(r).quote(
            claimKey: fixtureRefund,
            inputMint: null,
            amount: 1,
            destination: dest,
          ),
          throwsA(isA<ZcashRouteException>()),
        );
      }
      expect(r.requests, isEmpty);
    });

    test('unsupported mint', () async {
      final r = Recorder();
      await expectLater(
        route(r).quote(
          claimKey: fixtureRefund,
          inputMint: 'So11111111111111111111111111111111111111112',
          amount: 1,
          destination: u1,
        ),
        throwsA(isA<ZcashRouteException>()),
      );
    });

    test('surfaces the API error message', () async {
      final r = Recorder()
        ..handler = (_) async => json({
          'message': 'recipient is not valid',
          'correlationId': '21fcdb0a-34a1-4426-bf14-2e8d577cf670',
          'timestamp': '2026-10-02T18:27:52.211Z',
          'path': '/v0/quote',
        }, 400);
      await expectLater(
        route(r).quote(
          claimKey: fixtureRefund,
          inputMint: null,
          amount: 1,
          destination: u1,
        ),
        throwsA(
          isA<ZcashRouteException>()
              .having((e) => e.message, 'message', 'recipient is not valid')
              .having((e) => e.statusCode, 'statusCode', 400),
        ),
      );
    });
  });

  group('execute', () {
    late Ed25519HDKeyPair claim;
    const deposit = 'E5RdW4ip1B4wx1Loy83zr2dVadYywJazHvB22JBKq1Dg';
    const sig =
        '5ijsgRrhViNTtFMmnsfJDSo3HhRmt3Ri7WB513oBoQLxfGNswDxvHnakwW1yyqXznTTCSxnUkooAHDKowz9AjLkx';

    setUpAll(() async => claim = await Ed25519HDKeyPair.random());

    RouteQuote quoteFor(String? mint, int amount, {String? refundTo}) =>
        RouteQuote(
          rail: Rail.zcash,
          amountIn: amount,
          inputMint: mint,
          estimatedOut: '0.1 ZEC',
          expiresAt: quotedAt.add(const Duration(minutes: 30)),
          depositAddress: deposit,
          raw: {
            'quoteRequest': {'refundTo': refundTo ?? claim.address},
            'quote': {'depositAddress': deposit},
          },
        );

    Recorder chain() => Recorder()
      ..handler = (req) async {
        if (req.url.toString() == rpc) {
          final m = body(req)['method'];
          if (m == 'getLatestBlockhash') {
            return json({
              'jsonrpc': '2.0',
              'id': 1,
              'result': {
                'context': {'slot': 1},
                'value': {
                  'blockhash': 'EkSnNWid2cvwEVnVx9aBqawnmiCNiDgp3gUdkDPTKN1N',
                  'lastValidBlockHeight': 300,
                },
              },
            });
          }
          return json({'jsonrpc': '2.0', 'id': 1, 'result': sig});
        }
        return json(jsonDecode(statusPending));
      };

    Message sentMessage(Recorder r) {
      final send = r.requests
          .where((q) => q.url.toString() == rpc)
          .map(body)
          .singleWhere((b) => b['method'] == 'sendTransaction');
      final tx = SignedTx.decode((send['params'] as List).first as String);
      expect(tx.signatures.single.publicKey, claim.publicKey);
      return Message.decompile(tx.compiledMessage);
    }

    test('SOL: system transfer of amountIn, then deposit/submit', () async {
      final r = chain();
      final id = await route(r)
          .execute(claimKey: claim, quote: quoteFor(null, 123456789));
      expect(id, deposit);

      final ix = sentMessage(r).instructions.single;
      expect(ix.programId.toBase58(), SystemProgram.programId);
      expect(ix.accounts[0].pubKey, claim.publicKey);
      expect(ix.accounts[1].pubKey.toBase58(), deposit);
      expect(
        ix.data.toList(),
        SystemInstruction.transfer(
          fundingAccount: claim.publicKey,
          recipientAccount: Ed25519HDPublicKey.fromBase58(deposit),
          lamports: 123456789,
        ).data.toList(),
      );

      expect(body(r.to('/v0/deposit/submit').single), {
        'txHash': sig,
        'depositAddress': deposit,
      });
    });

    test(
      'USDC: idempotent ATA for the deposit address + transferChecked',
      () async {
        final r = chain();
        await route(r).execute(claimKey: claim, quote: quoteFor(usdc, 5000000));

        final ixs = sentMessage(r).instructions;
        expect(ixs, hasLength(2));
        final mint = Ed25519HDPublicKey.fromBase58(usdc);
        final depositAta = await findAssociatedTokenAddress(
          owner: Ed25519HDPublicKey.fromBase58(deposit),
          mint: mint,
        );
        final claimAta = await findAssociatedTokenAddress(
          owner: claim.publicKey,
          mint: mint,
        );

        expect(
          ixs[0].programId.toBase58(),
          AssociatedTokenAccountProgram.programId,
        );
        expect(ixs[0].data.toList(), [1]);
        expect(ixs[0].accounts[1].pubKey, depositAta);

        expect(ixs[1].programId.toBase58(), TokenProgram.programId);
        expect(ixs[1].accounts[0].pubKey, claimAta);
        expect(ixs[1].accounts[2].pubKey, depositAta);
        expect(ixs[1].accounts[3].pubKey, claim.publicKey);
        // transferChecked = 12, u64 LE amount, u8 decimals.
        expect(ixs[1].data.toList(), [12, 0x40, 0x4b, 0x4c, 0, 0, 0, 0, 0, 6]);
      },
    );

    test('deposit/submit failure does not fail the payout', () async {
      final r = chain();
      final base = r.handler;
      r.handler = (req) async => req.url.path == '/v0/deposit/submit'
          ? json({'message': 'boom'}, 500)
          : base(req);
      expect(
        await route(r).execute(claimKey: claim, quote: quoteFor(null, 1)),
        deposit,
      );
    });

    test('refuses a quote that refunds elsewhere', () async {
      final r = chain();
      await expectLater(
        route(r).execute(
          claimKey: claim,
          quote: quoteFor(null, 1, refundTo: fixtureRefund),
        ),
        throwsA(isA<ZcashRouteException>()),
      );
      expect(r.requests, isEmpty);
    });

    test('refuses an expired quote', () async {
      final r = chain();
      final late = ZcashRoute(
        client: r.client,
        cluster: 'mainnet-beta',
        rpcUrl: rpc,
        now: () => quotedAt.add(const Duration(hours: 1)),
      );
      await expectLater(
        late.execute(claimKey: claim, quote: quoteFor(null, 1)),
        throwsA(isA<ZcashRouteException>()),
      );
      expect(r.requests, isEmpty);
    });

    test('RPC error propagates', () async {
      final r = Recorder()
        ..handler = (_) async => json({
          'jsonrpc': '2.0',
          'id': 1,
          'error': {'code': -32002, 'message': 'insufficient funds'},
        });
      await expectLater(
        route(r).execute(claimKey: claim, quote: quoteFor(null, 1)),
        throwsA(isA<ZcashRouteException>()),
      );
      expect(r.to('/v0/deposit/submit'), isEmpty);
    });
  });

  group('status', () {
    test('polls by deposit address', () async {
      final r = Recorder()
        ..handler = (_) async => http.Response(statusPending, 200);
      expect(
        await route(r).status('E5RdW4ip1B4wx1Loy83zr2dVadYywJazHvB22JBKq1Dg'),
        'PENDING_DEPOSIT',
      );
      final req = r.requests.single;
      expect(req.method, 'GET');
      expect(
        req.url.toString(),
        'https://1click.chaindefuser.com/v0/status?depositAddress=E5RdW4ip1B4wx1Loy83zr2dVadYywJazHvB22JBKq1Dg',
      );
    });

    test('unknown deposit address throws 404', () async {
      final r = Recorder()
        ..handler = (_) async => json({
          'message': 'Deposit address x not found',
          'error': 'Not Found',
          'statusCode': 404,
        }, 404);
      await expectLater(
        route(r).status('x'),
        throwsA(
          isA<ZcashRouteException>().having(
            (e) => e.statusCode,
            'statusCode',
            404,
          ),
        ),
      );
    });
  });
}
