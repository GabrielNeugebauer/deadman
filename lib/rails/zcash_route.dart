import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

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

/// NEAR Intents account that receives the integrator fee
/// (`--dart-define=ZCASH_FEE_RECIPIENT=...`). Either a named account
/// (`deadman.near`) or a 64-hex implicit account, i.e. the hex of an Ed25519
/// public key. Left empty, no `appFees` are sent.
const zcashAppFeeRecipient = String.fromEnvironment('ZCASH_FEE_RECIPIENT');

class ZcashRouteException implements Exception {
  const ZcashRouteException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => 'ZcashRouteException($statusCode): $message';
}

/// A Solana-side asset 1Click accepts as swap input.
typedef OneClickInput = ({String assetId, int decimals, String symbol});

/// Receiver kinds inside a Zcash unified address.
typedef ZcashReceivers = ({bool orchard, bool sapling, bool transparent});

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
    Future<void> Function(Duration)? sleep,
  }) : _http = client ?? http.Client(),
       _cluster = cluster ?? AppConfig.cluster,
       _rpcUrl = Uri.parse(rpcUrl ?? AppConfig.rpcUrl),
       _now = now ?? DateTime.now,
       _sleep = sleep ?? Future<void>.delayed;

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

  /// Statuses at which [track] stops. `INCOMPLETE_DEPOSIT` can still be
  /// topped up before the deadline, but the claim key never sends twice.
  static const terminalStatuses = {
    'SUCCESS',
    'REFUNDED',
    'FAILED',
    'INCOMPLETE_DEPOSIT',
  };

  /// Base fee of the single-signature payout transaction.
  static const txFeeLamports = 5000;

  /// Rent-exempt minimum of a 0-byte system account: the deposit address
  /// must receive at least this much SOL, and the claim key must keep either
  /// nothing or at least this much.
  static const rentExemptLamports = 890880;

  /// Rent of the deposit address's token account when the claim key creates
  /// it. Covered by the 0.003 SOL Zcash gas stipend of token payouts.
  static const tokenAccountRentLamports = 2039280;

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
  final Future<void> Function(Duration) _sleep;

  static final _nearAccount = RegExp(
    r'^(([a-z\d]+[-_])*[a-z\d]+\.)*([a-z\d]+[-_])*[a-z\d]+$',
  );

  @override
  Rail get rail => Rail.zcash;

  @override
  bool get available => _cluster == 'mainnet-beta';

  /// Named NEAR account (2-64 chars) or 64-hex implicit account.
  static bool isValidFeeRecipient(String account) =>
      account.length >= 2 &&
      account.length <= 64 &&
      _nearAccount.hasMatch(account);

  /// A mainnet unified address (`u1...`) with at least one shielded receiver.
  static bool isUnifiedAddress(String address) {
    final r = decodeUnifiedAddress(address);
    return r != null && (r.orchard || r.sapling);
  }

  /// Decodes a mainnet Zcash unified address per ZIP 316 revision 0: bech32m
  /// with HRP `u` and a verified checksum, F4Jumble, HRP padding and receiver
  /// encodings. Returns null when [address] is not one.
  static ZcashReceivers? decodeUnifiedAddress(String address) =>
      _UnifiedAddress.decode(address);

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
    if (inputMint == null && amount < rentExemptLamports) {
      throw const ZcashRouteException(
        'SOL amount is below the $rentExemptLamports lamport rent minimum',
      );
    }
    if (!_isPubkey(claimKey)) {
      throw const ZcashRouteException('Invalid claim key');
    }
    if (!isUnifiedAddress(destination)) {
      throw const ZcashRouteException(
        'Destination must be a Zcash unified address (u1...)',
      );
    }
    if (appFeeRecipient.isNotEmpty && !isValidFeeRecipient(appFeeRecipient)) {
      throw ZcashRouteException(
        'Invalid ZCASH_FEE_RECIPIENT "$appFeeRecipient"',
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
        echoed['amount'] != '$amount' ||
        q['amountIn'] != '$amount') {
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

  /// Base units of [inputMint] the claim key can route: SOL balance minus
  /// the transaction fee, or the full token balance (its fees come out of
  /// the SOL gas stipend).
  Future<int> spendable({
    required String claimKey,
    required String? inputMint,
  }) async {
    if (!inputs.containsKey(inputMint)) {
      throw ZcashRouteException('Unsupported input mint $inputMint');
    }
    if (!_isPubkey(claimKey)) {
      throw const ZcashRouteException('Invalid claim key');
    }
    final owner = Ed25519HDPublicKey.fromBase58(claimKey);
    if (inputMint == null) {
      final account = (await _accounts([owner])).single;
      return math.max(0, _lamports(account) - txFeeLamports);
    }
    final ata = await findAssociatedTokenAddress(
      owner: owner,
      mint: Ed25519HDPublicKey.fromBase58(inputMint),
    );
    return _tokenAmount((await _accounts([ata])).single);
  }

  /// Sends the quoted amount from the claim key to the deposit address, then
  /// notifies 1Click. Returns the deposit address, which [status] and
  /// [track] follow.
  @override
  Future<String> execute({
    required Ed25519HDKeyPair claimKey,
    required RouteQuote quote,
  }) async {
    if (!available) {
      throw const ZcashRouteException('Zcash payouts are mainnet only');
    }
    final deposit = quote.depositAddress;
    final raw = quote.raw;
    final echoed = raw is Map ? raw['quoteRequest'] : null;
    final quoted = raw is Map ? raw['quote'] : null;
    if (quote.rail != Rail.zcash ||
        deposit == null ||
        echoed is! Map ||
        quoted is! Map ||
        quoted['depositAddress'] != deposit) {
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
    if (echoed['originAsset'] != input.assetId) {
      throw const ZcashRouteException('Quote is for a different asset');
    }

    final owner = claimKey.publicKey;
    final depositKey = Ed25519HDPublicKey.fromBase58(deposit);
    final mint = quote.inputMint;
    final List<Instruction> instructions;
    var lamportsNeeded = txFeeLamports;
    final int lamports;
    if (mint == null) {
      lamports = _lamports((await _accounts([owner])).single);
      lamportsNeeded += quote.amountIn;
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
      final accounts = await _accounts([owner, source, destination]);
      lamports = _lamports(accounts[0]);
      final held = _tokenAmount(accounts[1]);
      if (held < quote.amountIn) {
        throw ZcashRouteException(
          'Claim key holds $held of the ${quote.amountIn} ${input.symbol} '
          'base units quoted',
        );
      }
      if (accounts[2] == null) lamportsNeeded += tokenAccountRentLamports;
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
    final left = lamports - lamportsNeeded;
    if (left < 0) {
      throw ZcashRouteException(
        mint == null
            ? 'Claim key has $lamports lamports, needs $lamportsNeeded '
                  '(amount + $txFeeLamports fee)'
            : 'Claim key lacks SOL for fees: has $lamports lamports, needs '
                  '$lamportsNeeded (network fee + deposit token account rent)',
      );
    }
    if (left > 0 && left < rentExemptLamports) {
      throw ZcashRouteException(
        'Payout would leave $left lamports on the claim key, below the '
        '$rentExemptLamports rent minimum',
      );
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
    } on Exception {
      // Deposit is on-chain; status polling still works.
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

  /// Emits each new [status] of [depositAddress] and closes after a
  /// [terminalStatuses] one. Polls every [every], doubling up to [maxEvery]
  /// while nothing changes or 1Click is unreachable; client errors (4xx
  /// other than 429) end the stream with that error.
  Stream<String> track(
    String depositAddress, {
    Duration every = const Duration(seconds: 5),
    Duration maxEvery = const Duration(minutes: 2),
  }) async* {
    var wait = every;
    String? last;
    while (true) {
      String? s;
      try {
        s = await status(depositAddress);
      } on ZcashRouteException catch (e) {
        final code = e.statusCode;
        if (code != null && code < 500 && code != 429) rethrow;
      } on http.ClientException {
        // Offline or reset; retry.
      }
      if (s != null && s != last) {
        last = s;
        wait = every;
        yield s;
        if (terminalStatuses.contains(s)) return;
      } else {
        final doubled = wait * 2;
        wait = doubled > maxEvery ? maxEvery : doubled;
      }
      await _sleep(wait);
    }
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

  /// `getMultipleAccounts` (jsonParsed); null entries are missing accounts.
  Future<List<Map<dynamic, dynamic>?>> _accounts(
    List<Ed25519HDPublicKey> keys,
  ) async {
    final result = await _rpc('getMultipleAccounts', [
      [for (final k in keys) k.toBase58()],
      {'encoding': 'jsonParsed', 'commitment': 'confirmed'},
    ]);
    final value = result is Map ? result['value'] : null;
    if (value is! List || value.length != keys.length) {
      throw const ZcashRouteException('Malformed getMultipleAccounts response');
    }
    return [for (final a in value) a is Map ? a : null];
  }

  static int _lamports(Map<dynamic, dynamic>? account) {
    if (account == null) return 0;
    final l = account['lamports'];
    if (l is! int) {
      throw const ZcashRouteException('Malformed account lamports');
    }
    return l;
  }

  static int _tokenAmount(Map<dynamic, dynamic>? account) {
    if (account == null) return 0;
    final data = account['data'];
    final parsed = data is Map ? data['parsed'] : null;
    final info = parsed is Map ? parsed['info'] : null;
    final amount = info is Map ? info['tokenAmount'] : null;
    final raw = amount is Map ? amount['amount'] : null;
    final value = raw is String ? int.tryParse(raw) : null;
    if (value == null) {
      throw const ZcashRouteException('Not a token account');
    }
    return value;
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
    final Object? decoded;
    try {
      decoded = jsonDecode(res.body);
    } on FormatException {
      throw ZcashRouteException('Malformed RPC response to $method');
    }
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

/// ZIP 316 revision 0 unified address decoding, mainnet HRP only.
abstract final class _UnifiedAddress {
  static const _hrp = 'u';
  static const _charset = 'qpzry9x8gf2tvdw0s3jn54khce6mua7l';
  static const _bech32mConst = 0x2bc830a3;
  static const _minBytes = 48;
  static const _maxBytes = 4194368;

  static ZcashReceivers? decode(String address) {
    final data = _bech32m(address);
    if (data == null) return null;
    final bytes = _fiveToEight(data);
    if (bytes == null || bytes.length < _minBytes || bytes.length > _maxBytes) {
      return null;
    }
    final raw = _F4Jumble.inverse(bytes);
    final body = raw.length - 16;
    if (raw[body] != _hrp.codeUnitAt(0) ||
        raw.skip(body + 1).any((b) => b != 0)) {
      return null;
    }
    return _items(Uint8List.sublistView(raw, 0, body));
  }

  static List<int>? _bech32m(String s) {
    if (s.length < _hrp.length + 7 || s != s.toLowerCase()) return null;
    final sep = s.lastIndexOf('1');
    if (sep != _hrp.length || !s.startsWith(_hrp)) return null;
    final data = <int>[];
    for (var i = sep + 1; i < s.length; i++) {
      final v = _charset.indexOf(s[i]);
      if (v < 0) return null;
      data.add(v);
    }
    final hrp = _hrp.codeUnits;
    final values = [
      for (final c in hrp) c >> 5,
      0,
      for (final c in hrp) c & 31,
      ...data,
    ];
    if (_polymod(values) != _bech32mConst) return null;
    return data.sublist(0, data.length - 6);
  }

  static int _polymod(List<int> values) {
    const gen = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3];
    var chk = 1;
    for (final v in values) {
      final top = chk >> 25;
      chk = ((chk & 0x1ffffff) << 5) ^ v;
      for (var i = 0; i < 5; i++) {
        if ((top >> i) & 1 == 1) chk ^= gen[i];
      }
    }
    return chk;
  }

  static Uint8List? _fiveToEight(List<int> data) {
    var acc = 0;
    var bits = 0;
    final out = BytesBuilder(copy: false);
    for (final v in data) {
      acc = ((acc << 5) | v) & 0xfff;
      bits += 5;
      if (bits >= 8) {
        bits -= 8;
        out.addByte((acc >> bits) & 0xff);
      }
    }
    if (bits >= 5 || (acc << (8 - bits)) & 0xff != 0) return null;
    return out.takeBytes();
  }

  static ZcashReceivers? _items(Uint8List b) {
    const lengths = {0x00: 20, 0x01: 20, 0x02: 43, 0x03: 43};
    var i = 0;
    var prev = -1;
    var orchard = false;
    var sapling = false;
    var transparent = false;
    var receivers = 0;
    int? compactSize() {
      if (i >= b.length) return null;
      final first = b[i++];
      if (first < 0xfd) return first;
      final n = first == 0xfd ? 2 : (first == 0xfe ? 4 : 8);
      if (i + n > b.length) return null;
      var v = 0;
      for (var k = n - 1; k >= 0; k--) {
        v = (v << 8) | b[i + k];
      }
      i += n;
      final min = first == 0xfd
          ? 0xfd
          : (first == 0xfe ? 0x10000 : 0x100000000);
      return v < min || v > 0xffffffff ? null : v;
    }

    while (i < b.length) {
      final type = compactSize();
      final len = compactSize();
      if (type == null || len == null || i + len > b.length) return null;
      if (type <= prev) return null;
      final expected = lengths[type];
      if (expected != null && len != expected) return null;
      if (type >= 0xe0 && type <= 0xfc) return null;
      switch (type) {
        case 0x00 || 0x01:
          if (transparent) return null;
          transparent = true;
        case 0x02:
          sapling = true;
        case 0x03:
          orchard = true;
      }
      if (type < 0xc0 || type > 0xfc) receivers++;
      prev = type;
      i += len;
    }
    if (receivers == 0) return null;
    return (orchard: orchard, sapling: sapling, transparent: transparent);
  }
}

/// F4Jumble (ZIP 316) over BLAKE2b.
abstract final class _F4Jumble {
  static const _hashLen = 64;

  static Uint8List inverse(Uint8List m) {
    final lL = math.min(_hashLen, m.length ~/ 2);
    final lR = m.length - lL;
    final c = Uint8List.sublistView(m, 0, lL);
    final d = Uint8List.sublistView(m, lL);
    final y = _xor(c, _h(1, d, lL));
    final x = _xor(d, _g(1, y, lR));
    final a = _xor(y, _h(0, x, lL));
    final b = _xor(x, _g(0, a, lR));
    return Uint8List.fromList([...a, ...b]);
  }

  static Uint8List _h(int i, Uint8List u, int len) =>
      _Blake2b.hash(u, len, [...'UA_F4Jumble_H'.codeUnits, i, 0, 0]);

  static Uint8List _g(int i, Uint8List u, int len) {
    final out = BytesBuilder(copy: false);
    for (var j = 0; out.length < len; j++) {
      out.add(
        _Blake2b.hash(u, _hashLen, [
          ...'UA_F4Jumble_G'.codeUnits,
          i,
          j & 0xff,
          j >> 8,
        ]),
      );
    }
    return Uint8List.sublistView(out.takeBytes(), 0, len);
  }

  static Uint8List _xor(Uint8List x, Uint8List y) =>
      Uint8List.fromList([for (var k = 0; k < x.length; k++) x[k] ^ y[k]]);
}

/// Unkeyed BLAKE2b with a 16-byte personalization (RFC 7693). Works on
/// 32-bit halves (lo, hi) so it gives the same result compiled to JavaScript.
abstract final class _Blake2b {
  static const _iv = [
    0xf3bcc908, 0x6a09e667, 0x84caa73b, 0xbb67ae85, //
    0xfe94f82b, 0x3c6ef372, 0x5f1d36f1, 0xa54ff53a,
    0xade682d1, 0x510e527f, 0x2b3e6c1f, 0x9b05688c,
    0xfb41bd6b, 0x1f83d9ab, 0x137e2179, 0x5be0cd19,
  ];

  static const _sigma = [
    [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15],
    [14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3],
    [11, 8, 12, 0, 5, 2, 15, 13, 10, 14, 3, 6, 7, 1, 9, 4],
    [7, 9, 3, 1, 13, 12, 11, 14, 2, 6, 5, 10, 4, 0, 15, 8],
    [9, 0, 5, 7, 2, 4, 10, 15, 14, 1, 11, 12, 6, 8, 3, 13],
    [2, 12, 6, 10, 0, 11, 8, 3, 4, 13, 7, 5, 15, 14, 1, 9],
    [12, 5, 1, 15, 14, 13, 4, 10, 0, 7, 6, 3, 9, 2, 8, 11],
    [13, 11, 7, 14, 12, 1, 3, 9, 5, 0, 15, 4, 8, 6, 2, 10],
    [6, 15, 14, 9, 11, 3, 0, 8, 12, 2, 13, 7, 1, 4, 10, 5],
    [10, 2, 8, 4, 7, 6, 1, 5, 15, 11, 9, 14, 3, 12, 13, 0],
  ];

  static Uint8List hash(Uint8List input, int outLen, List<int> personal) {
    final h = Uint32List.fromList(_iv);
    h[0] ^= 0x01010000 ^ outLen;
    for (var i = 0; i < 4; i++) {
      h[12 + i] ^= _le32(personal, i * 4);
    }
    final block = Uint8List(128);
    var off = 0;
    while (input.length - off > 128) {
      block.setRange(0, 128, input, off);
      off += 128;
      _compress(h, block, off, false);
    }
    block.fillRange(0, 128, 0);
    block.setRange(0, input.length - off, input, off);
    _compress(h, block, input.length, true);
    final out = Uint8List(64);
    for (var i = 0; i < 16; i++) {
      for (var k = 0; k < 4; k++) {
        out[i * 4 + k] = (h[i] >>> (8 * k)) & 0xff;
      }
    }
    return Uint8List.sublistView(out, 0, outLen);
  }

  static void _compress(Uint32List h, Uint8List block, int t, bool last) {
    final m = Uint32List(32);
    for (var i = 0; i < 32; i++) {
      m[i] = _le32(block, i * 4);
    }
    final v = Uint32List(32)
      ..setAll(0, h)
      ..setAll(16, _iv);
    v[24] ^= t;
    v[25] ^= t ~/ 0x100000000;
    if (last) {
      v[28] = ~v[28];
      v[29] = ~v[29];
    }

    // v[a] += v[b] + (xLo, xHi), as 64-bit words at even indices.
    void add(int a, int b, int xLo, int xHi) {
      final lo = v[a] + v[b] + xLo;
      v[a + 1] = v[a + 1] + v[b + 1] + xHi + lo ~/ 0x100000000;
      v[a] = lo;
    }

    // v[d] = rotr64(v[d] ^ v[s], n) for n in 16, 24, 32, 63.
    void xorRotr(int d, int s, int n) {
      final lo = v[d] ^ v[s];
      final hi = v[d + 1] ^ v[s + 1];
      switch (n) {
        case 32:
          v[d] = hi;
          v[d + 1] = lo;
        case 63:
          v[d] = (lo << 1) | (hi >>> 31);
          v[d + 1] = (hi << 1) | (lo >>> 31);
        default:
          v[d] = (lo >>> n) | (hi << (32 - n));
          v[d + 1] = (hi >>> n) | (lo << (32 - n));
      }
    }

    void g(int a, int b, int c, int d, int x, int y) {
      a *= 2;
      b *= 2;
      c *= 2;
      d *= 2;
      add(a, b, m[x * 2], m[x * 2 + 1]);
      xorRotr(d, a, 32);
      add(c, d, 0, 0);
      xorRotr(b, c, 24);
      add(a, b, m[y * 2], m[y * 2 + 1]);
      xorRotr(d, a, 16);
      add(c, d, 0, 0);
      xorRotr(b, c, 63);
    }

    for (var r = 0; r < 12; r++) {
      final s = _sigma[r % 10];
      g(0, 4, 8, 12, s[0], s[1]);
      g(1, 5, 9, 13, s[2], s[3]);
      g(2, 6, 10, 14, s[4], s[5]);
      g(3, 7, 11, 15, s[6], s[7]);
      g(0, 5, 10, 15, s[8], s[9]);
      g(1, 6, 11, 12, s[10], s[11]);
      g(2, 7, 8, 13, s[12], s[13]);
      g(3, 4, 9, 14, s[14], s[15]);
    }
    for (var i = 0; i < 16; i++) {
      h[i] ^= v[i] ^ v[i + 16];
    }
  }

  static int _le32(List<int> b, int off) =>
      b[off] | (b[off + 1] << 8) | (b[off + 2] << 16) | (b[off + 3] << 24);
}
