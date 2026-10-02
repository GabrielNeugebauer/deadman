import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:solana/solana.dart';

import '../core/config.dart';
import 'rails.dart';

/// Jupiter Swap API V2 (Meta-Aggregator: `/order` + `/execute`).
const kJupiterSwapBase = 'https://api.jup.ag/swap/v2';

/// Jito stake pool analytics (Kobe). `apy[].data` is a fraction, e.g. 0.048.
const kJitoStatsUrl =
    'https://kobe.mainnet.jito.network/api/v1/stake_pool_stats';

const kWsolMint = 'So11111111111111111111111111111111111111112';
const kJitoSolMint = 'J1toso1uCk3RLmjorhTtrVwY9HJ7X8V9yYac6Y7kGCPn';

/// Optional; keyless access is rate limited to 0.5 RPS. Use a key restricted
/// to the Swap product, since it ships inside the APK.
const kJupiterApiKey = String.fromEnvironment('JUP_API_KEY');

/// Referral account under Jupiter's referral project
/// (DkiqsTrw1u1bYFumumC7sCG2S8K25qc2vemJFHyW2wJc). Empty disables the fee.
// TODO(treasury): create with the treasury as partner, then set it here along
// with a referral token account for the wSOL mint (fee mint for SOL<->LST).
const kJupiterReferralAccount = String.fromEnvironment('JUP_REFERRAL_ACCOUNT');

/// Integrator fee on the swap. Jupiter accepts 50..255 bps and keeps 20%.
// TODO(treasury): confirm the rate.
const kJupiterReferralFeeBps = 50;

class JupiterException implements Exception {
  JupiterException(this.message, {this.code});

  final String message;
  final int? code;

  @override
  String toString() => code == null
      ? 'JupiterException: $message'
      : 'JupiterException($code): $message';
}

/// An `/order` the owner still has to sign and pass to [JupiterEarn.execute].
class JupiterOrder {
  const JupiterOrder({
    required this.requestId,
    required this.inputMint,
    required this.outputMint,
    required this.inAmount,
    required this.outAmount,
    required this.feeBps,
    required this.feeMint,
    required this.router,
    required this.referralApplied,
  });

  final String requestId;
  final String inputMint;
  final String outputMint;
  final int inAmount;

  /// Expected output before slippage, in base units of [outputMint].
  final int outAmount;

  /// Total fee rate charged on the swap (Jupiter + integrator).
  final int feeBps;
  final String feeMint;
  final String router;

  /// False when Jupiter fell back to its default fee, e.g. because the
  /// referral token account for [feeMint] is not initialised.
  final bool referralApplied;
}

class JupiterEarn implements EarnService {
  JupiterEarn({
    http.Client? client,
    this.cluster = AppConfig.cluster,
    this.apiKey = kJupiterApiKey,
    this.referralAccount = kJupiterReferralAccount,
    this.referralFeeBps = kJupiterReferralFeeBps,
    this.slippageBps,
    DateTime Function()? now,
  }) : _http = client ?? http.Client(),
       _now = now ?? DateTime.now {
    if (referralAccount.isNotEmpty &&
        (referralFeeBps < 50 || referralFeeBps > 255)) {
      throw ArgumentError.value(
        referralFeeBps,
        'referralFeeBps',
        'must be 50..255',
      );
    }
  }

  final http.Client _http;
  final DateTime Function() _now;
  final String cluster;
  final String apiKey;
  final String referralAccount;
  final int referralFeeBps;

  /// Null lets Jupiter's RTSE pick slippage per trade.
  final int? slippageBps;

  static const _apyTtl = Duration(minutes: 30);
  (int, DateTime)? _apyCache;

  /// Keyed by base64 of the message bytes, which signing leaves unchanged.
  final _pending = <String, JupiterOrder>{};

  @override
  bool get available => cluster == 'mainnet-beta';

  @override
  String get lstMint => kJitoSolMint;

  bool get feeEnabled => referralAccount.isNotEmpty;

  @override
  Future<int> apyBps() async {
    final cached = _apyCache;
    if (cached != null && _now().difference(cached.$2) < _apyTtl) {
      return cached.$1;
    }
    final body = await _getJson(Uri.parse(kJitoStatsUrl), auth: false);
    final series = body['apy'];
    if (series is! List || series.isEmpty) {
      throw JupiterException('Jito stats: no apy series');
    }
    final latest = series.last;
    final value = latest is Map ? latest['data'] : null;
    if (value is! num || value.isNaN || value < 0 || value > 1) {
      throw JupiterException('Jito stats: bad apy value $value');
    }
    final bps = (value * 10000).round();
    _apyCache = (bps, _now());
    return bps;
  }

  /// SOL -> JitoSOL. [receiver] (e.g. the vault PDA) gets the LST in its ATA
  /// instead of [owner]; Jupiter adds the create-ATA instruction if needed.
  @override
  Future<Uint8List> buildStake({
    required String owner,
    required int lamports,
    String? receiver,
  }) => _order(
    inputMint: kWsolMint,
    outputMint: kJitoSolMint,
    amount: lamports,
    taker: owner,
    receiver: receiver,
  );

  /// JitoSOL -> SOL, from the owner's JitoSOL ATA.
  @override
  Future<Uint8List> buildUnstake({
    required String owner,
    required int lstAmount,
  }) => _order(
    inputMint: kJitoSolMint,
    outputMint: kWsolMint,
    amount: lstAmount,
    taker: owner,
  );

  /// Order details for an unsigned or signed transaction from this service.
  JupiterOrder? orderFor(Uint8List tx) => _pending[_messageKey(tx)];

  /// Submits the MWA-signed bytes through Jupiter's `/execute` (required for
  /// `/order` transactions: RFQ fills get the market maker's signature there).
  /// Returns the transaction signature.
  @override
  Future<String> execute(Uint8List signedTx) async {
    final key = _messageKey(signedTx);
    final order = _pending[key];
    if (order == null) {
      throw JupiterException('No pending order for this transaction');
    }
    final res = await _http.post(
      Uri.parse('$kJupiterSwapBase/execute'),
      headers: {..._headers(), 'Content-Type': 'application/json'},
      body: jsonEncode({
        'signedTransaction': base64Encode(signedTx),
        'requestId': order.requestId,
      }),
    );
    final body = _decode(res);
    _pending.remove(key);
    final code = (body['code'] as num?)?.toInt();
    if (body['status'] != 'Success' || (code != null && code != 0)) {
      throw JupiterException(
        '${body['error'] ?? 'execute failed'}'
        '${body['signature'] != null ? ' (${body['signature']})' : ''}',
        code: code,
      );
    }
    final sig = body['signature'];
    if (sig is! String || sig.isEmpty) {
      throw JupiterException('execute: missing signature');
    }
    return sig;
  }

  void close() => _http.close();

  Future<Uint8List> _order({
    required String inputMint,
    required String outputMint,
    required int amount,
    required String taker,
    String? receiver,
  }) async {
    if (!available) {
      throw StateError('Earn is mainnet-only (cluster: $cluster)');
    }
    if (amount <= 0) {
      throw ArgumentError.value(amount, 'amount', 'must be positive');
    }
    final ownerKey = Ed25519HDPublicKey.fromBase58(taker);
    if (receiver != null) {
      Ed25519HDPublicKey.fromBase58(receiver);
      if (receiver == taker) receiver = null;
    }

    final uri = Uri.parse('$kJupiterSwapBase/order').replace(
      queryParameters: {
        'inputMint': inputMint,
        'outputMint': outputMint,
        'amount': '$amount',
        'taker': taker,
        'receiver': ?receiver,
        if (slippageBps != null) 'slippageBps': '$slippageBps',
        if (feeEnabled) ...{
          'referralAccount': referralAccount,
          'referralFee': '$referralFeeBps',
        },
      },
    );
    final body = await _getJson(uri);

    final txB64 = body['transaction'];
    if (txB64 is! String || txB64.isEmpty) {
      throw JupiterException(
        '[${body['router']}] ${body['errorMessage'] ?? body['error'] ?? 'no transaction'}',
        code: (body['errorCode'] as num?)?.toInt(),
      );
    }
    final requestId = body['requestId'];
    if (requestId is! String || requestId.isEmpty) {
      throw JupiterException('order: missing requestId');
    }
    if (body['inputMint'] != inputMint || body['outputMint'] != outputMint) {
      throw JupiterException('order: mint mismatch');
    }
    final inAmount = int.tryParse('${body['inAmount']}');
    final outAmount = int.tryParse('${body['outAmount']}');
    if (inAmount != amount || outAmount == null || outAmount <= 0) {
      throw JupiterException('order: amount mismatch');
    }

    final tx = Uint8List.fromList(base64Decode(txB64));
    _checkTransaction(tx, ownerKey.bytes);

    _pending[_messageKey(tx)] = JupiterOrder(
      requestId: requestId,
      inputMint: inputMint,
      outputMint: outputMint,
      inAmount: amount,
      outAmount: outAmount,
      feeBps: (body['feeBps'] as num?)?.toInt() ?? 0,
      feeMint: '${body['feeMint'] ?? ''}',
      router: '${body['router'] ?? ''}',
      referralApplied: feeEnabled && body['referralAccount'] == referralAccount,
    );
    return tx;
  }

  Map<String, String> _headers() => {
    'Accept': 'application/json',
    if (apiKey.isNotEmpty) 'x-api-key': apiKey,
  };

  Future<Map<String, dynamic>> _getJson(Uri uri, {bool auth = true}) async {
    final res = await _http.get(
      uri,
      headers: auth ? _headers() : const {'Accept': 'application/json'},
    );
    return _decode(res);
  }

  Map<String, dynamic> _decode(http.Response res) {
    Object? body;
    try {
      body = jsonDecode(res.body);
    } on FormatException {
      body = null;
    }
    if (res.statusCode != 200) {
      final msg = body is Map ? (body['error'] ?? body['message']) : null;
      throw JupiterException(
        'HTTP ${res.statusCode}: ${msg ?? res.reasonPhrase}',
        code: res.statusCode,
      );
    }
    if (body is! Map<String, dynamic>) {
      throw JupiterException('Unexpected response body');
    }
    return body;
  }
}

/// Checks the bytes are a v0 transaction that [owner] must sign.
void _checkTransaction(Uint8List tx, List<int> owner) {
  final r = _Reader(tx);
  final sigs = r.shortVec();
  r.skip(sigs * 64);
  if (r.byte() != 0x80) {
    throw JupiterException('Expected a v0 transaction');
  }
  final required = r.byte();
  r.skip(2);
  final keys = r.shortVec();
  if (sigs != required || required > keys) {
    throw JupiterException('Malformed transaction header');
  }
  for (var i = 0; i < required; i++) {
    final k = r.take(32);
    var same = true;
    for (var j = 0; j < 32; j++) {
      if (k[j] != owner[j]) {
        same = false;
        break;
      }
    }
    if (same) return;
  }
  throw JupiterException('Owner is not a signer of the order transaction');
}

String _messageKey(Uint8List tx) {
  final r = _Reader(tx);
  final sigs = r.shortVec();
  r.skip(sigs * 64);
  return base64Encode(Uint8List.sublistView(tx, r.offset));
}

class _Reader {
  _Reader(this._b);

  final Uint8List _b;
  int offset = 0;

  int byte() {
    if (offset >= _b.length) throw JupiterException('Truncated transaction');
    return _b[offset++];
  }

  void skip(int n) {
    if (offset + n > _b.length) throw JupiterException('Truncated transaction');
    offset += n;
  }

  Uint8List take(int n) {
    skip(n);
    return Uint8List.sublistView(_b, offset - n, offset);
  }

  int shortVec() {
    var value = 0;
    for (var shift = 0; shift < 21; shift += 7) {
      final b = byte();
      value |= (b & 0x7f) << shift;
      if (b & 0x80 == 0) return value;
    }
    throw JupiterException('Bad shortvec');
  }
}
