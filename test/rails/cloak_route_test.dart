import 'dart:convert';

import 'package:deadman/rails/cloak_route.dart';
import 'package:deadman/rails/rails.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:solana/solana.dart';

const usdc = 'EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v';
const utxoHex =
    '26cec87910cb7089a1e917b2093669c02418bf79d8e16f9cd17fc43ace644f7b';
const viewHex =
    'de64baa38bbc250b722101d1ac03cca808ae4ec1ff3b73ce7a95dc4e9c0c9366';
const destination = 'cloak:$utxoHex:$viewHex';

class FakeRuntime implements CloakJsRuntime {
  FakeRuntime(this.reply);

  String Function(String op, Map<String, dynamic> payload) reply;
  final calls = <(String, Map<String, dynamic>)>[];

  @override
  Future<String> run(String op, String payloadJson) async {
    final payload = jsonDecode(payloadJson) as Map<String, dynamic>;
    calls.add((op, payload));
    return reply(op, payload);
  }
}

String ok(Map<String, Object?> result) =>
    jsonEncode({'ok': true, 'result': result});

MockClient rpc(Map<String, Object?> Function(String method, List params) on) =>
    MockClient((req) async {
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      return http.Response(
        jsonEncode({
          'jsonrpc': '2.0',
          'id': 1,
          'result': on(body['method'] as String, body['params'] as List),
        }),
        200,
      );
    });

void main() {
  final now = DateTime.utc(2026, 10, 2, 12);
  late Ed25519HDKeyPair claim;

  setUpAll(() async {
    claim = await Ed25519HDKeyPair.fromPrivateKeyBytes(
      privateKey: List.filled(32, 9),
    );
  });

  CloakRoute route({
    CloakJsRuntime? runtime,
    http.Client? client,
    String cluster = 'mainnet-beta',
  }) => CloakRoute(
    runtime: runtime,
    client: client ?? rpc((_, _) => {'value': 0}),
    cluster: cluster,
    rpcUrl: 'https://rpc.test',
    now: () => now,
  );

  group('availability', () {
    test('unavailable without a Cloak deployment', () {
      final r = route(runtime: FakeRuntime((_, _) => ''), cluster: 'devnet');
      expect(r.rail, Rail.cloak);
      expect(r.available, isFalse);
      expect(r.unavailableReason, contains('mainnet only'));
    });

    test('unavailable without the JS runtime', () {
      final r = route();
      expect(r.available, isFalse);
      expect(r.unavailableReason, contains('runtime'));
    });

    test('available on mainnet with a runtime', () {
      final r = route(runtime: FakeRuntime((_, _) => ''));
      expect(r.available, isTrue);
      expect(r.unavailableReason, isNull);
    });

    test('quote refuses when unavailable', () {
      expect(
        route(cluster: 'devnet').quote(
          claimKey: claim.address,
          inputMint: null,
          amount: 100000000,
          destination: destination,
        ),
        throwsA(isA<CloakRouteException>()),
      );
    });
  });

  group('CloakAddress', () {
    test('round-trips', () {
      final a = CloakAddress.parse(
        destination.toUpperCase().replaceFirst('CLOAK', 'cloak'),
      );
      expect(a.utxoPubkey, utxoHex);
      expect(a.viewingPubkey, viewHex);
      expect(a.toString(), destination);
      expect(CloakAddress.parse(a.toString()), a);
    });

    test('rejects malformed input', () {
      for (final bad in [
        'cloak:$utxoHex',
        'zcash:$utxoHex:$viewHex',
        'cloak:${utxoHex.substring(2)}:$viewHex',
        'cloak:$utxoHex:${'z' * 64}',
        'cloak:${'0' * 64}:$viewHex',
        'cloak:${'f' * 64}:$viewHex',
      ]) {
        expect(
          () => CloakAddress.parse(bad),
          throwsFormatException,
          reason: bad,
        );
      }
    });
  });

  group('quote', () {
    late CloakRoute r;
    setUp(() => r = route(runtime: FakeRuntime((_, _) => '')));

    test('SOL keeps the fee reserve on the claim key', () async {
      final q = await r.quote(
        claimKey: claim.address,
        inputMint: null,
        amount: 105000000,
        destination: destination,
      );
      expect(q.rail, Rail.cloak);
      expect(q.amountIn, 100000000);
      expect(q.inputMint, isNull);
      expect(q.estimatedOut, '0.1 SOL shielded');
      expect(q.expiresAt, now.add(const Duration(minutes: 10)));
      expect(q.depositAddress, isNull);
      final data = q.raw! as CloakQuoteData;
      expect(data.claimKey, claim.address);
      expect(data.shielded!.utxoPubkey, utxoHex);
      expect(data.publicRecipient, isNull);
    });

    test('USDC shields the whole amount', () async {
      final q = await r.quote(
        claimKey: claim.address,
        inputMint: usdc,
        amount: 2500000,
        destination: destination,
      );
      expect(q.amountIn, 2500000);
      expect(q.estimatedOut, '2.5 USDC shielded');
    });

    test('enforces pool minimums', () {
      expect(
        r.quote(
          claimKey: claim.address,
          inputMint: null,
          amount: 14000000,
          destination: destination,
        ),
        throwsA(isA<CloakRouteException>()),
      );
      expect(
        r.quote(
          claimKey: claim.address,
          inputMint: usdc,
          amount: 999999,
          destination: destination,
        ),
        throwsA(isA<CloakRouteException>()),
      );
    });

    test('rejects unknown mints, bad keys and bad destinations', () {
      expect(
        r.quote(
          claimKey: claim.address,
          inputMint: 'So11111111111111111111111111111111111111112',
          amount: 100000000,
          destination: destination,
        ),
        throwsA(isA<CloakRouteException>()),
      );
      expect(
        r.quote(
          claimKey: 'nope',
          inputMint: null,
          amount: 100000000,
          destination: destination,
        ),
        throwsA(isA<CloakRouteException>()),
      );
      expect(
        r.quote(
          claimKey: claim.address,
          inputMint: null,
          amount: 100000000,
          destination: 'u1notcloak',
        ),
        throwsA(isA<CloakRouteException>()),
      );
    });

    test('a Solana address is a private send net of the exit fee', () async {
      final wallet = (await Ed25519HDKeyPair.fromPrivateKeyBytes(
        privateKey: List.filled(32, 5),
      )).address;
      final q = await r.quote(
        claimKey: claim.address,
        inputMint: usdc,
        amount: 10000000,
        destination: wallet,
      );
      // 10 USDC - (0.45 + 0.3% of 10)
      expect(q.estimatedOut, '9.52 USDC');
      final data = q.raw! as CloakQuoteData;
      expect(data.publicRecipient, wallet);
      expect(data.shielded, isNull);
      expect(CloakRoute.exitFee(1000000000, CloakRoute.pools[null]!), 8000000);
    });
  });

  group('execute', () {
    test('hands the claim secret and recipient to the runtime', () async {
      final runtime = FakeRuntime(
        (_, _) => ok({
          'state': 'sent',
          'depositSignature': 'dep',
          'sendSignature': 'send-sig',
        }),
      );
      final r = route(
        runtime: runtime,
        client: rpc((m, p) {
          expect(m, 'getBalance');
          expect(p.first, claim.address);
          return {'value': 105000000};
        }),
      );
      final q = await r.quote(
        claimKey: claim.address,
        inputMint: null,
        amount: 105000000,
        destination: destination,
      );

      expect(await r.execute(claimKey: claim, quote: q), 'send-sig');
      expect(runtime.calls, hasLength(1));
      final (op, payload) = runtime.calls.single;
      expect(op, 'shieldAndSend');
      expect(base64Decode(payload['secret'] as String), List.filled(32, 9));
      expect(payload['amount'], '100000000');
      expect(payload['mint'], isNull);
      expect(payload['rpcUrl'], 'https://rpc.test');
      expect(payload['recipientUtxoPubkey'], utxoHex);
      expect(payload['recipientViewingPubkey'], viewHex);
      expect(payload['recipientSolana'], isNull);
      expect(payload['resumeOnlyReason'], isNull);
    });

    test('reports a payout a previous run already delivered', () async {
      final r = route(
        runtime: FakeRuntime((_, _) => ok({'state': 'already_sent'})),
        client: rpc((_, _) => {'value': 2000000000}),
      );
      final q = await r.quote(
        claimKey: claim.address,
        inputMint: usdc,
        amount: 5000000,
        destination: destination,
      );
      final id = await r.execute(claimKey: claim, quote: q);
      expect(id, CloakRoute.alreadySent);
      expect(await r.status(id), 'SUCCESS');
    });

    test('needs SOL on the claim key for an SPL deposit', () async {
      final runtime = FakeRuntime(
        (_, p) => jsonEncode({'ok': false, 'error': p['resumeOnlyReason']}),
      );
      final r = route(
        runtime: runtime,
        client: rpc((_, _) => {'value': 9999999}),
      );
      final q = await r.quote(
        claimKey: claim.address,
        inputMint: usdc,
        amount: 5000000,
        destination: destination,
      );
      await expectLater(
        r.execute(claimKey: claim, quote: q),
        throwsA(
          isA<CloakRouteException>().having(
            (e) => e.message,
            'message',
            'Claim key holds 9999999 lamports, needs 10000000 to shield',
          ),
        ),
      );
      expect(runtime.calls.single.$2['resumeOnlyReason'], isNotNull);
    });

    test('surfaces SDK errors', () async {
      final r = route(
        runtime: FakeRuntime(
          (_, _) => jsonEncode({
            'ok': false,
            'error': 'Risk quote request failed (403)',
            'retryable': false,
          }),
        ),
        client: rpc((_, _) => {'value': 2000000000}),
      );
      final q = await r.quote(
        claimKey: claim.address,
        inputMint: null,
        amount: 105000000,
        destination: destination,
      );
      await expectLater(
        r.execute(claimKey: claim, quote: q),
        throwsA(
          isA<CloakRouteException>()
              .having((e) => e.message, 'message', contains('Risk quote'))
              .having((e) => e.retryable, 'retryable', isFalse),
        ),
      );
    });

    test('refuses foreign, expired and non-Cloak quotes', () async {
      final runtime = FakeRuntime((_, _) => ok({}));
      final r = route(runtime: runtime);
      final other = await Ed25519HDKeyPair.fromPrivateKeyBytes(
        privateKey: List.filled(32, 3),
      );
      final q = await r.quote(
        claimKey: other.address,
        inputMint: null,
        amount: 105000000,
        destination: destination,
      );
      await expectLater(
        r.execute(claimKey: claim, quote: q),
        throwsA(isA<CloakRouteException>()),
      );

      final expired = RouteQuote(
        rail: Rail.cloak,
        amountIn: 100000000,
        inputMint: null,
        estimatedOut: '',
        expiresAt: now,
        raw: CloakQuoteData(
          claimKey: claim.address,
          shielded: CloakAddress.parse(destination),
        ),
      );
      await expectLater(
        r.execute(claimKey: claim, quote: expired),
        throwsA(isA<CloakRouteException>()),
      );

      final zcash = RouteQuote(
        rail: Rail.zcash,
        amountIn: 1,
        inputMint: null,
        estimatedOut: '',
        expiresAt: now.add(const Duration(hours: 1)),
      );
      await expectLater(
        r.execute(claimKey: claim, quote: zcash),
        throwsA(isA<CloakRouteException>()),
      );
      expect(runtime.calls, isEmpty);
    });
  });

  group('status', () {
    Future<String> statusFor(Object? entry) => route(
      client: rpc((m, p) {
        expect(m, 'getSignatureStatuses');
        return {
          'value': [entry],
        };
      }),
    ).status('sig');

    test('maps signature statuses', () async {
      expect(await statusFor(null), 'PENDING');
      expect(
        await statusFor({'err': null, 'confirmationStatus': 'processed'}),
        'PENDING',
      );
      expect(
        await statusFor({'err': null, 'confirmationStatus': 'finalized'}),
        'SUCCESS',
      );
      expect(
        await statusFor({
          'err': {'InstructionError': []},
          'confirmationStatus': 'confirmed',
        }),
        'FAILED',
      );
    });
  });

  group('runtime glue', () {
    test('receiveAddress parses the runtime reply', () async {
      final runtime = FakeRuntime(
        (_, _) => ok({'utxoPubkey': utxoHex, 'viewingPubkey': viewHex}),
      );
      final a = await route(runtime: runtime)
          .receiveAddress(List.filled(32, 7));
      expect(a.toString(), destination);
      expect(runtime.calls.single.$1, 'receiveAddress');
      expect(
        base64Decode(runtime.calls.single.$2['spendKey'] as String),
        List.filled(32, 7),
      );
    });

    test('CallAsyncCloakRuntime passes op and payload as arguments', () async {
      late String body;
      late Map<String, Object?> args;
      final runtime = CallAsyncCloakRuntime((b, a) async {
        body = b;
        args = a;
        return ok({'version': 'x'});
      });
      expect(await runtime.run('ping', '{}'), ok({'version': 'x'}));
      expect(body, CallAsyncCloakRuntime.functionBody);
      expect(args, {'op': 'ping', 'payload': '{}'});

      final silent = CallAsyncCloakRuntime((_, _) async => null);
      expect(silent.run('ping', '{}'), throwsA(isA<CloakRouteException>()));
    });
  });
}
