import 'dart:convert';

import 'package:deadman/kora/kora_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:solana/base58.dart';

String _key(int seed) =>
    base58encode(List<int>.generate(32, (i) => (seed * 31 + i * 7) & 0xff));

/// In-memory Kora node: records every JSON-RPC call and answers with the
/// response shapes of kora-cli 2.0.5.
class FakeKora {
  FakeKora({String? signer, String? paymentAddress})
    : signer = signer ?? _key(50),
      paymentAddress = paymentAddress ?? _key(51);

  final String signer;
  final String paymentAddress;
  String blockhash = _key(52);

  /// `estimateTransactionFee` answers (fee_in_token only when asked for a
  /// fee token, like Kora).
  int feeInLamports = 10000;
  int? feeInToken = 2500;

  /// `payment_address` in estimates, when it should differ from
  /// [paymentAddress] (a tampered response).
  String? estimatePaymentAddress;

  /// Next estimateTransactionFee answered with this Kora error message.
  String? failNextEstimate;

  /// signAndSendTransaction calls answered with a blockhash simulation error.
  int blockhashMisses = 0;

  /// Next signAndSendTransaction answered with this Kora error message.
  String? failNextSend;

  final calls =
      <({String method, Object? params, Map<String, String> headers})>[];

  Iterable<Map<String, dynamic>> paramsOf(String method) => [
    for (final c in calls)
      if (c.method == method) (c.params as Map).cast<String, dynamic>(),
  ];

  http.Client get httpClient => MockClient(_handle);

  KoraClient client({String apiKey = 'k'}) => KoraClient(
    Uri.parse('https://kora.test'),
    apiKey: apiKey,
    httpClient: httpClient,
  );

  Future<http.Response> _handle(http.Request req) async {
    final body = jsonDecode(req.body) as Map<String, dynamic>;
    final method = body['method'] as String;
    final params = body['params'];
    calls.add((method: method, params: params, headers: req.headers));
    http.Response ok(Object result) => http.Response(
      jsonEncode({'jsonrpc': '2.0', 'id': body['id'], 'result': result}),
      200,
    );
    http.Response fail(String message) => http.Response(
      jsonEncode({
        'jsonrpc': '2.0',
        'id': body['id'],
        'error': {'code': -32000, 'message': message},
      }),
      200,
    );
    switch (method) {
      case 'getPayerSigner':
        return ok({
          'signer_address': signer,
          'payment_address': paymentAddress,
        });
      case 'getBlockhash':
        return ok({'blockhash': blockhash});
      case 'estimateTransactionFee':
        final error = failNextEstimate;
        if (error != null) {
          failNextEstimate = null;
          return fail(error);
        }
        return ok({
          'fee_in_lamports': feeInLamports,
          'fee_in_token': (params as Map)['fee_token'] == null
              ? null
              : feeInToken,
          'signer_pubkey': signer,
          'payment_address': estimatePaymentAddress ?? paymentAddress,
        });
      case 'getConfig':
        return ok({
          'fee_payers': [signer],
          'validation_config': {'max_signatures': 10},
          'enabled_methods': {'sign_and_send_transaction': true},
        });
      case 'signTransaction' || 'signAndSendTransaction':
        final tx = (params as Map)['transaction'] as String;
        if (method == 'signAndSendTransaction') {
          if (blockhashMisses > 0) {
            blockhashMisses--;
            return fail(
              'Invalid transaction: Transaction simulation failed: '
              'Blockhash not found',
            );
          }
          final error = failNextSend;
          if (error != null) {
            failNextSend = null;
            return fail(error);
          }
        }
        return ok({
          if (method == 'signAndSendTransaction')
            'signature': 'kora${calls.length}',
          'signed_transaction': tx,
          'signer_pubkey': signer,
        });
    }
    return http.Response('', 405);
  }
}
