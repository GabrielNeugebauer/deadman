import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;
import 'package:http/http.dart' as http;
import 'package:solana/base58.dart';
import 'package:solana/dto.dart' show LatestBlockhash;
import 'package:solana/encoder.dart';
import 'package:solana/solana.dart';

import '../core/config.dart';
import 'rails.dart';

/// Integrator fee charged by 1Click on every Zcash payout, in bps of the
/// input. Observed 2026-10-02: 1Click splits the submitted `fee` 50/50, so
/// Deadman keeps half (100 -> 50 bps to the treasury, 50 bps to 1Click), and
/// the submitted fee may not exceed 500 bps in total.
const zcashAppFeeBps = 100;

/// NEAR Intents account that receives the integrator fee. Either a named
/// account (`deadman.near`) or a 64-hex implicit account, i.e. the hex of an
/// Ed25519 public key. Left empty, no `appFees` are sent.
// TODO(treasury): set the Deadman treasury's NEAR Intents account.
const zcashAppFeeRecipient = '';

class ZcashRouteException implements Exception {
  const ZcashRouteException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => 'ZcashRouteException($statusCode): $message';
}

/// A Solana-side asset 1Click accepts as swap input.
typedef OneClickInput = ({String assetId, int decimals, String symbol});

/// SOL / SPL -> shielded ZEC through the NEAR Intents 1Click API.
///
/// The claim key deposits to a one-time 1Click deposit address on Solana;
/// solvers deliver ZEC to the beneficiary's unified address. Refunds go back
/// to the claim key on Solana.
class ZcashRoute implements PrivateRoute {
  ZcashRoute({
    http.Client? client,
    String? cluster,
    String? rpcUrl,
    this._apiKey = const String.fromEnvironment('ONECLICK_JWT'),
    this.appFeeRecipient = zcashAppFeeRecipient,
    this.appFeeBps = zcashAppFeeBps,
    this.slippageBps = 100,
    this.depositWindow = const Duration(minutes: 30),
    DateTime Function()? now,
  }) : _http = client ?? http.Client(),
       _cluster = cluster ?? AppConfig.cluster,
       _rpcUrl = Uri.parse(rpcUrl ?? AppConfig.rpcUrl),
       _now = now ?? DateTime.now;

  static final baseUrl = Uri.parse('https://1click.chaindefuser.com');

  /// Signs every quote payload (from `@defuse-protocol/one-click-sdk-typescript`
  /// 0.1.26, `ONE_CLICK_MANAGER_PUB_KEY`).
  static const quoteSignerKey = 'reYaWhvwu8Jzo3WUM3zhn6VrhuMEF4eADL17qtRVifc';

  static const zecAssetId = 'nep141:zec.omft.near';
  static const zecDecimals = 8;

  /// Keys are SPL mints; `null` is native SOL. Ids from `GET /v0/tokens`.
  static const inputs = <String?, OneClickInput>{
    null: (assetId: 'nep141:sol.omft.near', decimals: 9, symbol: 'SOL'),
    'EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v': (
      assetId: 'nep141:sol-5ce3bf3a31af18be40ba30f721101b4341690186.omft.near',
      decimals: 6,
      symbol: 'USDC',
    ),
    'Es9vMFrzaCERmJfrF4H2FYD4KCoNkY11McCe8BenwNYB': (
      assetId: 'nep141:sol-c800a4bd850783ccb82c2b2c7e84175443606352.omft.near',
      decimals: 6,
      symbol: 'USDT',
    ),
  };

  /// Statuses after which [status] will not change.
  static const terminalStatuses = {'SUCCESS', 'REFUNDED', 'FAILED'};

  final String appFeeRecipient;
  final int appFeeBps;
  final int slippageBps;

  /// How long the claim key has to deposit before 1Click starts a refund.
  final Duration depositWindow;

  final http.Client _http;
  final String _cluster;
  final Uri _rpcUrl;
  final String _apiKey;
  final DateTime Function() _now;

  static final _unifiedAddress = RegExp(r'^u1[02-9ac-hj-np-z]{100,}$');

  @override
  Rail get rail => Rail.zcash;

  @override
  bool get available => _cluster == 'mainnet-beta';

  @override
  Future<RouteQuote> quote({
    required String claimKey,
    required String? inputMint,
    required int amount,
    required String destination,
  }) => _quote(
    claimKey: claimKey,
    inputMint: inputMint,
    amount: amount,
    destination: destination,
    dry: false,
  );

  /// Price preview without reserving a deposit address.
  Future<RouteQuote> estimate({
    required String claimKey,
    required String? inputMint,
    required int amount,
    required String destination,
  }) => _quote(
    claimKey: claimKey,
    inputMint: inputMint,
    amount: amount,
    destination: destination,
    dry: true,
  );

  Future<RouteQuote> _quote({
    required String claimKey,
    required String? inputMint,
    required int amount,
    required String destination,
    required bool dry,
  }) async {
    if (!available) {
      throw const ZcashRouteException('Zcash payouts are mainnet only');
    }
    final input = inputs[inputMint];
    if (input == null) {
      throw ZcashRouteException('Unsupported input mint $inputMint');
    }
    if (amount <= 0) {
      throw const ZcashRouteException('Amount must be positive');
    }
    if (!_isPubkey(claimKey)) {
      throw const ZcashRouteException('Invalid claim key');
    }
    if (!_unifiedAddress.hasMatch(destination)) {
      throw const ZcashRouteException(
        'Destination must be a Zcash unified address (u1...)',
      );
    }

    final request = <String, Object>{
      'dry': dry,
      'swapType': 'EXACT_INPUT',
      'slippageTolerance': slippageBps,
      'originAsset': input.assetId,
      'depositType': 'ORIGIN_CHAIN',
      'destinationAsset': zecAssetId,
      'amount': '$amount',
      'refundTo': claimKey,
      'refundType': 'ORIGIN_CHAIN',
      'recipient': destination,
      'recipientType': 'DESTINATION_CHAIN',
      'deadline': _now().toUtc().add(depositWindow).toIso8601String(),
      'referral': 'deadman',
      if (appFeeRecipient.isNotEmpty && appFeeBps > 0)
        'appFees': [
          {'recipient': appFeeRecipient, 'fee': appFeeBps},
        ],
    };

    final res = await _send('POST', '/v0/quote', body: request);
    final echoed = res['quoteRequest'];
    final q = res['quote'];
    if (echoed is! Map || q is! Map) {
      throw const ZcashRouteException('Malformed quote response');
    }
    if (!await verifyQuoteSignature(res)) {
      throw const ZcashRouteException('Quote signature does not verify');
    }
    if (echoed['refundTo'] != claimKey ||
        echoed['recipient'] != destination ||
        echoed['originAsset'] != input.assetId ||
        echoed['destinationAsset'] != zecAssetId ||
        echoed['amount'] != '$amount') {
      throw const ZcashRouteException('Quote does not match the request');
    }
    final depositAddress = q['depositAddress'] as String?;
    if (!dry && (depositAddress == null || !_isPubkey(depositAddress))) {
      throw const ZcashRouteException('Quote has no Solana deposit address');
    }

    return RouteQuote(
      rail: Rail.zcash,
      amountIn: int.parse(q['amountIn'] as String),
      inputMint: inputMint,
      estimatedOut: '${q['amountOutFormatted']} ZEC',
      expiresAt: DateTime.parse(echoed['deadline'] as String),
      depositAddress: depositAddress,
      raw: res,
    );
  }

  /// Sends the quoted amount from the claim key to the deposit address.
  /// Returns the deposit address, which is what [status] tracks.
  @override
  Future<String> execute({
    required Ed25519HDKeyPair claimKey,
    required RouteQuote quote,
  }) async {
    final deposit = quote.depositAddress;
    final raw = quote.raw;
    final echoed = raw is Map ? raw['quoteRequest'] : null;
    if (quote.rail != Rail.zcash || deposit == null || echoed is! Map) {
      throw const ZcashRouteException('Not an executable Zcash quote');
    }
    if (echoed['refundTo'] != claimKey.address) {
      throw const ZcashRouteException('Quote refunds to a different key');
    }
    if (!_now().isBefore(quote.expiresAt)) {
      throw const ZcashRouteException('Quote expired');
    }
    final input = inputs[quote.inputMint];
    if (input == null) {
      throw ZcashRouteException('Unsupported input mint ${quote.inputMint}');
    }

    final owner = claimKey.publicKey;
    final depositKey = Ed25519HDPublicKey.fromBase58(deposit);
    final mint = quote.inputMint;
    final List<Instruction> instructions;
    if (mint == null) {
      instructions = [
        SystemInstruction.transfer(
          fundingAccount: owner,
          recipientAccount: depositKey,
          lamports: quote.amountIn,
        ),
      ];
    } else {
      final mintKey = Ed25519HDPublicKey.fromBase58(mint);
      final source = await findAssociatedTokenAddress(
        owner: owner,
        mint: mintKey,
      );
      final destination = await findAssociatedTokenAddress(
        owner: depositKey,
        mint: mintKey,
      );
      instructions = [
        AssociatedTokenAccountInstruction.createAccountIdempotent(
          funder: owner,
          address: destination,
          owner: depositKey,
          mint: mintKey,
        ),
        TokenInstruction.transferChecked(
          amount: quote.amountIn,
          decimals: input.decimals,
          source: source,
          mint: mintKey,
          destination: destination,
          owner: owner,
        ),
      ];
    }

    final blockhash = await _rpc('getLatestBlockhash', [
      {'commitment': 'confirmed'},
    ]);
    final value = (blockhash as Map)['value'] as Map;
    final tx = await signTransaction(
      LatestBlockhash(
        blockhash: value['blockhash'] as String,
        lastValidBlockHeight: value['lastValidBlockHeight'] as int,
      ),
      Message(instructions: instructions),
      [claimKey],
    );
    final signature = await _rpc('sendTransaction', [
      tx.encode(),
      {'encoding': 'base64', 'preflightCommitment': 'confirmed'},
    ]) as String;

    // Optional per the API; 1Click also detects the deposit on its own.
    try {
      await _send(
        'POST',
        '/v0/deposit/submit',
        body: {'txHash': signature, 'depositAddress': deposit},
      );
    } on ZcashRouteException {
      // Deposit is on-chain; status polling still works.
    } on http.ClientException {
      // Same.
    }
    return deposit;
  }

  /// One of `PENDING_DEPOSIT`, `KNOWN_DEPOSIT_TX`, `PROCESSING`, `SUCCESS`,
  /// `INCOMPLETE_DEPOSIT`, `REFUNDED`, `FAILED`.
  @override
  Future<String> status(String trackingId) async {
    final res = await _send(
      'GET',
      '/v0/status',
      query: {'depositAddress': trackingId},
    );
    final s = res['status'];
    if (s is! String) {
      throw const ZcashRouteException('Malformed status response');
    }
    return s;
  }

  /// Port of `verifyQuoteSignature` from the 1Click TypeScript SDK: Ed25519
  /// over base58(sha256(stable JSON of the signed request/quote fields)).
  static Future<bool> verifyQuoteSignature(Map<dynamic, dynamic> res) async {
    try {
      final req = res['quoteRequest'] as Map;
      final q = res['quote'] as Map;
      final sig = res['signature'] as String;
      Object? truthy(Object? v) =>
          v == null || v == false || v == 0 || v == '' ? null : v;

      final fields = <String, Object?>{
        'dry': req['dry'],
        'swapType': req['swapType'],
        'slippageTolerance': req['slippageTolerance'],
        'originAsset': req['originAsset'],
        'depositType': req['depositType'],
        'destinationAsset': req['destinationAsset'],
        'amount': req['amount'],
        'refundTo': req['refundTo'],
        'refundType': req['refundType'],
        'recipient': req['recipient'],
        'recipientType': req['recipientType'],
        'deadline': req['deadline'],
        'quoteWaitingTimeMs': truthy(req['quoteWaitingTimeMs']),
        'referral': truthy(req['referral']),
        'virtualChainRecipient': truthy(req['virtualChainRecipient']),
        'virtualChainRefundRecipient': truthy(
          req['virtualChainRefundRecipient'],
        ),
        'customRecipientMsg': truthy(req['customRecipientMsg']),
        'amountIn': q['amountIn'],
        'amountInFormatted': q['amountInFormatted'],
        'amountInUsd': q['amountInUsd'],
        'minAmountIn': q['minAmountIn'],
        'amountOut': q['amountOut'],
        'amountOutFormatted': q['amountOutFormatted'],
        'amountOutUsd': q['amountOutUsd'],
        'minAmountOut': q['minAmountOut'],
        if (req['dry'] != true) ...{
          'depositAddress': truthy(q['depositAddress']),
          'depositMemo': truthy(q['depositMemo']),
          'deadline': truthy(q['deadline']),
          'timeWhenInactive': truthy(q['timeWhenInactive']),
          'timeEstimate': truthy(q['timeEstimate']),
          'refundFee': truthy(q['refundFee']),
          'withdrawFee': truthy(q['withdrawFee']),
        },
        'timestamp': res['timestamp'],
      };
      // json-stable-stringify: sorted keys, undefined dropped.
      final keys = fields.keys.where((k) => fields[k] != null).toList()..sort();
      final json =
          '{${keys.map((k) => '${jsonEncode(k)}:${jsonEncode(fields[k])}').join(',')}}';
      final digest = base58encode(
        crypto.sha256.convert(utf8.encode(json)).bytes,
      );
      return await verifySignature(
        message: utf8.encode(digest),
        signature: base58decode(sig.replaceFirst('ed25519:', '')),
        publicKey: Ed25519HDPublicKey.fromBase58(quoteSignerKey),
      );
    } on Object {
      return false;
    }
  }

  Map<String, String> get _headers => {
    'Content-Type': 'application/json',
    if (_apiKey.isNotEmpty) 'Authorization': 'Bearer $_apiKey',
  };

  Future<Map<String, dynamic>> _send(
    String method,
    String path, {
    Map<String, Object>? body,
    Map<String, String>? query,
  }) async {
    final uri = baseUrl.replace(path: path, queryParameters: query);
    final res = method == 'GET'
        ? await _http.get(uri, headers: _headers)
        : await _http.post(uri, headers: _headers, body: jsonEncode(body));
    Object? decoded;
    try {
      decoded = jsonDecode(res.body);
    } on FormatException {
      decoded = null;
    }
    if (res.statusCode < 200 || res.statusCode >= 300) {
      final msg = decoded is Map ? decoded['message'] : null;
      throw ZcashRouteException(
        '${msg ?? 'HTTP ${res.statusCode}'}',
        statusCode: res.statusCode,
      );
    }
    if (decoded is! Map<String, dynamic>) {
      throw const ZcashRouteException('Malformed 1Click response');
    }
    return decoded;
  }

  Future<Object?> _rpc(String method, List<Object> params) async {
    final res = await _http.post(
      _rpcUrl,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'jsonrpc': '2.0',
        'id': 1,
        'method': method,
        'params': params,
      }),
    );
    final decoded = jsonDecode(res.body);
    if (decoded is! Map) {
      throw ZcashRouteException('Malformed RPC response to $method');
    }
    final error = decoded['error'];
    if (error != null) {
      final msg = error is Map ? error['message'] : error;
      throw ZcashRouteException('$method failed: $msg');
    }
    return decoded['result'];
  }

  static bool _isPubkey(String s) {
    try {
      return base58decode(s).length == 32;
    } on FormatException {
      return false;
    }
  }
}
