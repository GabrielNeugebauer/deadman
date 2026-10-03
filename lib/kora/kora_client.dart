import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../core/config.dart';

/// JSON-RPC error from a Kora node, or an HTTP-level rejection.
///
/// [code] is the JSON-RPC error code (Kora reports every method failure as
/// `-32000` with a `"<Kind>: <detail>"` message) or, when the HTTP layer
/// rejected the call, the HTTP status, also in [httpStatus]: 401 bad API key
/// or HMAC, 405 method disabled in `kora.toml`, 429 or 5xx overloaded.
class KoraException implements Exception {
  const KoraException(this.code, this.message, {this.httpStatus});

  final int code;
  final String message;
  final int? httpStatus;

  bool get retryable =>
      httpStatus != null && (httpStatus == 429 || httpStatus! >= 500);

  /// The node's RPC does not know the transaction's blockhash yet (or any
  /// more): Kora surfaces the simulation error text.
  bool get blockhashNotFound =>
      RegExp('blockhash ?not ?found', caseSensitive: false).hasMatch(message);

  @override
  String toString() => 'KoraException($code): $message';
}

typedef KoraPayerSigner = ({String signerAddress, String paymentAddress});

/// [signature] is only set by `signAndSendTransaction`.
typedef KoraSignedTransaction = ({
  String signedTransaction,
  String signerPubkey,
  String? signature,
});

typedef KoraConfig = ({
  List<String> feePayers,
  Map<String, dynamic> validationConfig,
  Map<String, dynamic> enabledMethods,
});

/// Client for a Kora node (kora-cli 2.x JSON-RPC over HTTP POST).
class KoraClient {
  KoraClient(
    this.url, {
    this.apiKey = '',
    this.hmacSecret = '',
    http.Client? httpClient,
    this.timeout = const Duration(seconds: 90),
  }) : _http = httpClient ?? http.Client();

  /// Null when [url] is empty, i.e. Kora is not configured for this build.
  static KoraClient? fromConfig(String url) => url.isEmpty
      ? null
      : KoraClient(Uri.parse(url), apiKey: AppConfig.koraApiKey);

  final Uri url;

  /// Sent as `x-api-key` when non-empty.
  final String apiKey;

  /// When non-empty, signs each request: `x-timestamp` (unix seconds) and
  /// `x-hmac-signature` = hex HMAC-SHA256 of timestamp + raw body.
  final String hmacSecret;

  /// `signAndSendTransaction` waits for confirmation server-side.
  final Duration timeout;
  final http.Client _http;
  var _id = 0;

  Future<KoraPayerSigner> getPayerSigner() async {
    final r = await _call('getPayerSigner');
    return (
      signerAddress: r['signer_address'] as String,
      paymentAddress: r['payment_address'] as String,
    );
  }

  Future<String> getBlockhash() async =>
      (await _call('getBlockhash'))['blockhash'] as String;

  Future<KoraConfig> getConfig() async {
    final r = await _call('getConfig');
    return (
      feePayers: [for (final k in r['fee_payers'] as List) k as String],
      validationConfig: (r['validation_config'] as Map).cast<String, dynamic>(),
      enabledMethods: (r['enabled_methods'] as Map).cast<String, dynamic>(),
    );
  }

  /// Validates, co-signs as fee payer and returns without broadcasting.
  Future<KoraSignedTransaction> signTransaction({
    required String transaction,
    String? signerKey,
    bool? sigVerify,
  }) async => _signed(
    await _call(
      'signTransaction',
      _txParams(transaction, signerKey, sigVerify),
    ),
  );

  /// Validates, co-signs, sends and waits for confirmation.
  Future<KoraSignedTransaction> signAndSendTransaction({
    required String transaction,
    String? signerKey,
    bool? sigVerify,
  }) async => _signed(
    await _call(
      'signAndSendTransaction',
      _txParams(transaction, signerKey, sigVerify),
    ),
  );

  void close() => _http.close();

  static Map<String, Object> _txParams(
    String transaction,
    String? signerKey,
    bool? sigVerify,
  ) => {
    'transaction': transaction,
    'signer_key': ?signerKey,
    'sig_verify': ?sigVerify,
  };

  static KoraSignedTransaction _signed(Map<String, dynamic> r) => (
    signedTransaction: r['signed_transaction'] as String,
    signerPubkey: r['signer_pubkey'] as String,
    signature: r['signature'] as String?,
  );

  Future<Map<String, dynamic>> _call(
    String method, [
    Map<String, Object>? params,
  ]) async {
    final body = jsonEncode({
      'jsonrpc': '2.0',
      'id': ++_id,
      'method': method,
      'params': params ?? const <Object>[],
    });
    final response = await _http
        .post(url, headers: _headers(body), body: body)
        .timeout(timeout);
    if (response.statusCode != 200) {
      final text = response.body.trim();
      throw KoraException(
        response.statusCode,
        text.isEmpty ? 'HTTP ${response.statusCode}' : text,
        httpStatus: response.statusCode,
      );
    }
    final json = jsonDecode(response.body) as Map<String, dynamic>;
    final error = json['error'];
    if (error is Map) {
      throw KoraException(
        error['code'] as int? ?? 0,
        '${error['message'] ?? 'Unknown Kora error'}',
      );
    }
    return (json['result'] as Map).cast<String, dynamic>();
  }

  Map<String, String> _headers(String body) {
    final headers = {'Content-Type': 'application/json'};
    if (apiKey.isNotEmpty) headers['x-api-key'] = apiKey;
    if (hmacSecret.isNotEmpty) {
      final ts = '${DateTime.now().millisecondsSinceEpoch ~/ 1000}';
      headers['x-timestamp'] = ts;
      headers['x-hmac-signature'] = Hmac(
        sha256,
        utf8.encode(hmacSecret),
      ).convert(utf8.encode('$ts$body')).toString();
    }
    return headers;
  }
}
