import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:deadman/kora/kora_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fake_kora.dart';

void main() {
  late FakeKora node;
  late KoraClient kora;

  setUp(() {
    node = FakeKora();
    kora = node.client(apiKey: 'secret');
  });

  test('JSON-RPC 2.0 envelope, x-api-key header, [] for no params', () async {
    final payer = await kora.getPayerSigner();
    expect(payer.signerAddress, node.signer);
    expect(payer.paymentAddress, node.paymentAddress);
    expect(await kora.getBlockhash(), node.blockhash);

    final c = node.calls.first;
    expect(c.method, 'getPayerSigner');
    expect(c.params, isEmpty);
    expect(c.params, isList);
    expect(c.headers['x-api-key'], 'secret');
    expect(c.headers['content-type'], startsWith('application/json'));
    expect(c.headers.containsKey('x-hmac-signature'), isFalse);
  });

  test('no API key header when the key is empty', () async {
    await node.client(apiKey: '').getBlockhash();
    expect(node.calls.single.headers.containsKey('x-api-key'), isFalse);
  });

  test('getConfig', () async {
    final config = await kora.getConfig();
    expect(config.feePayers, [node.signer]);
    expect(config.validationConfig['max_signatures'], 10);
    expect(config.enabledMethods['sign_and_send_transaction'], isTrue);
  });

  test('signTransaction and signAndSendTransaction', () async {
    final signed = await kora.signTransaction(
      transaction: 'dHg=',
      sigVerify: false,
    );
    expect(signed.signedTransaction, 'dHg=');
    expect(signed.signerPubkey, node.signer);
    expect(signed.signature, isNull);
    expect(node.paramsOf('signTransaction').single, {
      'transaction': 'dHg=',
      'sig_verify': false,
    });

    final sent = await kora.signAndSendTransaction(
      transaction: 'dHg=',
      signerKey: node.signer,
    );
    expect(sent.signature, isNotEmpty);
    expect(node.paramsOf('signAndSendTransaction').single, {
      'transaction': 'dHg=',
      'signer_key': node.signer,
    });
  });

  test('estimateTransactionFee: params and response', () async {
    final est = await kora.estimateTransactionFee(
      transaction: 'dHg=',
      feeToken: 'mint',
      signerKey: node.signer,
    );
    expect(node.paramsOf('estimateTransactionFee').single, {
      'transaction': 'dHg=',
      'signer_key': node.signer,
      'fee_token': 'mint',
    });
    expect(est.feeInLamports, 10000);
    expect(est.feeInToken, 2500);
    expect(est.signerPubkey, node.signer);
    expect(est.paymentAddress, node.paymentAddress);

    final sol = await kora.estimateTransactionFee(transaction: 'dHg=');
    expect(node.paramsOf('estimateTransactionFee').last, {
      'transaction': 'dHg=',
    });
    expect(sol.feeInToken, isNull);
  });

  test('JSON-RPC errors become KoraException with code and message', () async {
    node.failNextSend = 'Invalid transaction: Insufficient token payment';
    await expectLater(
      kora.signAndSendTransaction(transaction: 'dHg='),
      throwsA(
        isA<KoraException>()
            .having((e) => e.code, 'code', -32000)
            .having((e) => e.message, 'message', contains('Insufficient'))
            .having((e) => e.httpStatus, 'httpStatus', isNull)
            .having((e) => e.retryable, 'retryable', isFalse),
      ),
    );
    node.blockhashMisses = 1;
    await expectLater(
      kora.signAndSendTransaction(transaction: 'dHg='),
      throwsA(
        isA<KoraException>().having(
          (e) => e.blockhashNotFound,
          'blockhashNotFound',
          isTrue,
        ),
      ),
    );
  });

  test('HTTP rejections (auth, disabled method, throttling)', () async {
    for (final (status, retryable) in [
      (401, false),
      (405, false),
      (429, true),
    ]) {
      final c = KoraClient(
        Uri.parse('https://kora.test'),
        httpClient: MockClient((_) async => http.Response('', status)),
      );
      await expectLater(
        c.getBlockhash(),
        throwsA(
          isA<KoraException>()
              .having((e) => e.code, 'code', status)
              .having((e) => e.httpStatus, 'httpStatus', status)
              .having((e) => e.retryable, 'retryable', retryable),
        ),
      );
    }
  });

  test('HMAC: hex HMAC-SHA256 of timestamp + raw body', () async {
    late http.Request seen;
    final c = KoraClient(
      Uri.parse('https://kora.test'),
      hmacSecret: 'shh',
      httpClient: MockClient((req) async {
        seen = req;
        return http.Response(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': 1,
            'result': {'blockhash': 'h'},
          }),
          200,
        );
      }),
    );
    await c.getBlockhash();
    final ts = seen.headers['x-timestamp']!;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    expect((int.parse(ts) - now).abs(), lessThan(5));
    expect(
      seen.headers['x-hmac-signature'],
      Hmac(
        sha256,
        utf8.encode('shh'),
      ).convert(utf8.encode('$ts${seen.body}')).toString(),
    );
  });

  test('Kora URLs: https everywhere, plain http only on devnet (M-3)', () {
    for (final ok in ['https://k.test', 'https://k.test:8081/']) {
      KoraClient.checkUrl(ok, mainnet: true);
      KoraClient.checkUrl(ok, mainnet: false);
    }
    KoraClient.checkUrl('http://192.168.0.2:8081', mainnet: false);
    for (final bad in ['http://192.168.0.2:8081', 'k.test', 'ftp://k.test']) {
      expect(
        () => KoraClient.checkUrl(bad, mainnet: true),
        throwsArgumentError,
        reason: bad,
      );
    }
    expect(
      () => KoraClient.checkUrl('k.test:8081', mainnet: false),
      throwsArgumentError,
    );
    expect(
      () => KoraClient.fromConfig('http://k.test', mainnet: true),
      throwsArgumentError,
    );
    expect(KoraClient.fromConfig('', mainnet: true), isNull);
    expect(
      KoraClient.fromConfig('http://k.test', mainnet: false)?.url.host,
      'k.test',
    );
  });

  test('fromConfig is null for an empty URL', () {
    expect(KoraClient.fromConfig(''), isNull);
    expect(KoraClient.fromConfig('https://k.test')?.url.host, 'k.test');
  });
}
