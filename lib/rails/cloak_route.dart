import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:solana/base58.dart';
import 'package:solana/solana.dart';

import '../core/config.dart';
import 'rails.dart';

class CloakRouteException implements Exception {
  const CloakRouteException(this.message, {this.retryable});

  final String message;

  /// As reported by the SDK's `CloakError`, when known.
  final bool? retryable;

  @override
  String toString() => 'CloakRouteException: $message';
}

/// Runs the bundled `@cloak.dev/sdk` (assets/cloak/cloak.js).
///
/// [run] calls `window.deadmanCloak.run(op, payloadJson)` and returns its
/// JSON string reply. The app backs it with a headless WebView; tests fake it.
abstract class CloakJsRuntime {
  Future<String> run(String op, String payloadJson);
}

/// Signature of `InAppWebViewController.callAsyncJavaScript`, reduced to the
/// returned value, so this file needs no WebView dependency.
typedef CallAsyncJavaScript = Future<Object?> Function(
  String functionBody,
  Map<String, Object?> arguments,
);

/// [CloakJsRuntime] over a `callAsyncJavaScript`-style entry point.
class CallAsyncCloakRuntime implements CloakJsRuntime {
  const CallAsyncCloakRuntime(this._call);

  static const functionBody =
      'return await window.deadmanCloak.run(op, payload);';

  final CallAsyncJavaScript _call;

  @override
  Future<String> run(String op, String payloadJson) async {
    final reply = await _call(functionBody, {'op': op, 'payload': payloadJson});
    if (reply is! String) {
      throw const CloakRouteException('Cloak runtime returned no reply');
    }
    return reply;
  }
}

/// A Cloak receive address: the owner's UTXO public key (a BN254 field
/// element) and X25519 viewing public key, which together let a sender lock
/// a shielded note to the owner and seal its secrets to them on chain.
///
/// Cloak defines no string format for this pair, so Deadman uses
/// `cloak:<64 hex utxo pubkey>:<64 hex viewing pubkey>`.
class CloakAddress {
  CloakAddress({required this.utxoPubkey, required this.viewingPubkey}) {
    if (!_hex64.hasMatch(utxoPubkey) || !_hex64.hasMatch(viewingPubkey)) {
      throw const FormatException('Cloak keys must be 32 bytes of hex');
    }
    final field = BigInt.parse(utxoPubkey, radix: 16);
    if (field == BigInt.zero || field >= bn254FieldModulus) {
      throw const FormatException('Cloak pubkey is not a field element');
    }
  }

  factory CloakAddress.parse(String s) {
    final parts = s.trim().split(':');
    if (parts.length != 3 || parts[0] != 'cloak') {
      throw const FormatException(
        'Cloak address must be cloak:<utxo pubkey hex>:<viewing key hex>',
      );
    }
    return CloakAddress(
      utxoPubkey: parts[1].toLowerCase(),
      viewingPubkey: parts[2].toLowerCase(),
    );
  }

  static final bn254FieldModulus = BigInt.parse(
    '21888242871839275222246405745257275088548364400416034343698204186575808495617',
  );
  static final _hex64 = RegExp(r'^[0-9a-f]{64}$');

  final String utxoPubkey;
  final String viewingPubkey;

  @override
  String toString() => 'cloak:$utxoPubkey:$viewingPubkey';

  @override
  bool operator ==(Object other) =>
      other is CloakAddress &&
      other.utxoPubkey == utxoPubkey &&
      other.viewingPubkey == viewingPubkey;

  @override
  int get hashCode => Object.hash(utxoPubkey, viewingPubkey);
}

/// What [CloakRoute.execute] needs beyond [RouteQuote]'s fields. Exactly one
/// of [shielded] and [publicRecipient] is set.
class CloakQuoteData {
  const CloakQuoteData({
    required this.claimKey,
    this.shielded,
    this.publicRecipient,
  }) : assert((shielded == null) != (publicRecipient == null));

  final String claimKey;

  /// Shielded transfer: the payout stays in the pool as the owner's note.
  final CloakAddress? shielded;

  /// Cloak "private send": the payout leaves the pool to this Solana wallet.
  final String? publicRecipient;
}

/// A Cloak pool Deadman can pay into. Exit fee: [exitFixedFee] + 0.3%.
typedef CloakPool = ({
  String symbol,
  int decimals,
  int minDeposit,
  int exitFixedFee,
});

/// Claim key -> Cloak shielded pool -> the beneficiary.
///
/// Runs the official TypeScript SDK in a headless WebView, because every
/// Cloak transaction, deposits included, carries a Groth16 proof generated
/// on the client. Two transactions:
///
/// 1. Deposit from the claim key into a note owned by a Cloak identity
///    derived from the claim key. Signed by the claim key, sent straight to
///    chain. No protocol fee.
/// 2. Either a shielded transfer of the whole note to a `cloak:` address,
///    with the note secrets sealed to its viewing key on chain (no protocol
///    fee; the owner pays the exit fee when they unshield), or, for a plain
///    Solana address, a withdrawal of the whole note to it (exit fee 0.3% +
///    0.005 SOL or 0.45 USDC/USDT). Submitted through Cloak's relay,
///    authenticated by the claim key.
///
/// The claim key's secret is handed to the on-device WebView only.
class CloakRoute implements PrivateRoute {
  CloakRoute({
    this._runtime,
    http.Client? client,
    String? cluster,
    String? rpcUrl,
    this.solFeeReserveLamports = 5000000,
    this.splFeeReserveLamports = 10000000,
    this.quoteTtl = const Duration(minutes: 10),
    DateTime Function()? now,
  }) : _http = client ?? http.Client(),
       _cluster = cluster ?? AppConfig.cluster,
       _rpcUrl = Uri.parse(rpcUrl ?? AppConfig.rpcUrl),
       _now = now ?? DateTime.now;

  /// Mainnet only; Cloak has no devnet deployment (verified 2026-10-02).
  static const programId = 'zh1eLd6rSphLejbFfJEneUwzHRfMKxgzrgkfwA6qRkW';
  static const relayUrl = 'https://api.cloak.ag';
  static const sdkVersion = '0.2.5';
  static const deployedClusters = {'mainnet-beta'};

  /// Keys are SPL mints; `null` is native SOL. Minimums from the program's
  /// `PoolConfig` (SDK 0.2.5 README, "Fees and limits").
  static const pools = <String?, CloakPool>{
    null: (
      symbol: 'SOL',
      decimals: 9,
      minDeposit: 10000000,
      exitFixedFee: 5000000,
    ),
    'EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v': (
      symbol: 'USDC',
      decimals: 6,
      minDeposit: 1000000,
      exitFixedFee: 450000,
    ),
    'Es9vMFrzaCERmJfrF4H2FYD4KCoNkY11McCe8BenwNYB': (
      symbol: 'USDT',
      decimals: 6,
      minDeposit: 1000000,
      exitFixedFee: 450000,
    ),
  };

  /// Lamports left on the claim key to pay for a SOL deposit (signature,
  /// account rent). The rest of the payout is shielded.
  final int solFeeReserveLamports;

  /// SOL the claim key must already hold for a USDC/USDT deposit, which may
  /// also create a lookup table (about 0.0056 SOL) if the relay cannot
  /// extend its shared one.
  final int splFeeReserveLamports;
  final Duration quoteTtl;

  final CloakJsRuntime? _runtime;
  final http.Client _http;
  final String _cluster;
  final Uri _rpcUrl;
  final DateTime Function() _now;

  @override
  Rail get rail => Rail.cloak;

  @override
  bool get available => unavailableReason == null;

  /// Why [available] is false, for display; `null` when available.
  String? get unavailableReason {
    if (!deployedClusters.contains(_cluster)) {
      return 'Cloak is deployed on Solana mainnet only (cluster: $_cluster)';
    }
    if (_runtime == null) {
      return 'Cloak runtime (headless WebView with assets/cloak) not started';
    }
    return null;
  }

  @override
  Future<RouteQuote> quote({
    required String claimKey,
    required String? inputMint,
    required int amount,
    required String destination,
  }) async {
    final reason = unavailableReason;
    if (reason != null) throw CloakRouteException(reason);
    final pool = pools[inputMint];
    if (pool == null) {
      throw CloakRouteException('Unsupported input mint $inputMint');
    }
    if (!_isPubkey(claimKey)) {
      throw const CloakRouteException('Invalid claim key');
    }
    CloakAddress? shielded;
    String? publicRecipient;
    if (_isPubkey(destination)) {
      publicRecipient = destination;
    } else {
      try {
        shielded = CloakAddress.parse(destination);
      } on FormatException catch (e) {
        throw CloakRouteException(e.message);
      }
    }

    final amountIn = inputMint == null
        ? amount - solFeeReserveLamports
        : amount;
    if (amountIn < pool.minDeposit) {
      throw CloakRouteException(
        'Below Cloak minimum deposit of ${_format(pool.minDeposit, pool)}'
        '${inputMint == null ? ' plus ${_format(solFeeReserveLamports, pool)} for fees' : ''}',
      );
    }

    final String estimatedOut;
    if (shielded != null) {
      estimatedOut = '${_format(amountIn, pool)} shielded';
    } else {
      final out = amountIn - exitFee(amountIn, pool);
      if (out <= 0) {
        throw CloakRouteException(
          'Amount does not cover Cloak exit fee of '
          '${_format(exitFee(amountIn, pool), pool)}',
        );
      }
      estimatedOut = _format(out, pool);
    }

    return RouteQuote(
      rail: Rail.cloak,
      amountIn: amountIn,
      inputMint: inputMint,
      estimatedOut: estimatedOut,
      expiresAt: _now().add(quoteTtl),
      raw: CloakQuoteData(
        claimKey: claimKey,
        shielded: shielded,
        publicRecipient: publicRecipient,
      ),
    );
  }

  /// Cloak's on-chain exit fee for [amount] leaving [pool]: fixed + 0.3%.
  static int exitFee(int amount, CloakPool pool) =>
      pool.exitFixedFee + amount * 3 ~/ 1000;

  /// Returns the signature of the shielded transfer or withdrawal, or
  /// `already-sent` when a previous run delivered this exact payout.
  @override
  Future<String> execute({
    required Ed25519HDKeyPair claimKey,
    required RouteQuote quote,
  }) async {
    final runtime = _runtime;
    final reason = unavailableReason;
    if (runtime == null || reason != null) throw CloakRouteException(reason!);
    final data = quote.raw;
    final pool = pools[quote.inputMint];
    if (quote.rail != Rail.cloak || data is! CloakQuoteData || pool == null) {
      throw const CloakRouteException('Not an executable Cloak quote');
    }
    if (data.claimKey != claimKey.address) {
      throw const CloakRouteException('Quote is for a different claim key');
    }
    if (!_now().isBefore(quote.expiresAt)) {
      throw const CloakRouteException('Quote expired');
    }

    final needed = quote.inputMint == null
        ? quote.amountIn + solFeeReserveLamports
        : splFeeReserveLamports;
    // Short of funds is fine only if an earlier run already deposited; the
    // runtime then skips the deposit, and the relay pays for the second leg.
    final lamports = await _balance(claimKey.address);
    final shortfall = lamports < needed
        ? 'Claim key holds $lamports lamports, needs $needed to shield'
        : null;

    final secret = await claimKey.extract();
    final String reply;
    try {
      reply = await runtime.run(
        'shieldAndSend',
        jsonEncode({
          'rpcUrl': _rpcUrl.toString(),
          'secret': base64Encode(secret.bytes),
          'mint': quote.inputMint,
          'amount': '${quote.amountIn}',
          'recipientUtxoPubkey': data.shielded?.utxoPubkey,
          'recipientViewingPubkey': data.shielded?.viewingPubkey,
          'recipientSolana': data.publicRecipient,
          'resumeOnlyReason': shortfall,
        }),
      );
    } finally {
      secret.destroy();
    }

    final result = _unwrap(reply);
    if (result['state'] == 'already_sent') return alreadySent;
    final sig = result['sendSignature'];
    if (sig is! String || sig.isEmpty) {
      throw const CloakRouteException('Cloak runtime returned no signature');
    }
    return sig;
  }

  static const alreadySent = 'already-sent';

  /// `SUCCESS`, `FAILED` or `PENDING` for the shielded-transfer signature.
  @override
  Future<String> status(String trackingId) async {
    if (trackingId == alreadySent) return 'SUCCESS';
    final result = await _rpc('getSignatureStatuses', [
      [trackingId],
      {'searchTransactionHistory': true},
    ]);
    final value = result is Map ? result['value'] : null;
    final entry = value is List && value.isNotEmpty ? value.first : null;
    if (entry is! Map) return 'PENDING';
    if (entry['err'] != null) return 'FAILED';
    final level = entry['confirmationStatus'];
    return level == 'confirmed' || level == 'finalized' ? 'SUCCESS' : 'PENDING';
  }

  /// The Cloak address for a 32-byte Cloak spend key held by the
  /// beneficiary's app, to hand to whoever sets up the payout.
  Future<CloakAddress> receiveAddress(List<int> spendKey) async {
    final runtime = _runtime;
    if (runtime == null) throw CloakRouteException(unavailableReason!);
    if (spendKey.length != 32) {
      throw const CloakRouteException('Cloak spend key must be 32 bytes');
    }
    final result = _unwrap(
      await runtime.run(
        'receiveAddress',
        jsonEncode({'spendKey': base64Encode(spendKey)}),
      ),
    );
    try {
      return CloakAddress(
        utxoPubkey: result['utxoPubkey'] as String,
        viewingPubkey: result['viewingPubkey'] as String,
      );
    } on Object {
      throw const CloakRouteException('Malformed Cloak address reply');
    }
  }

  static Map<String, dynamic> _unwrap(String reply) {
    final Object? decoded;
    try {
      decoded = jsonDecode(reply);
    } on FormatException {
      throw const CloakRouteException('Malformed Cloak runtime reply');
    }
    if (decoded is! Map<String, dynamic>) {
      throw const CloakRouteException('Malformed Cloak runtime reply');
    }
    if (decoded['ok'] != true) {
      throw CloakRouteException(
        '${decoded['error'] ?? 'Cloak runtime error'}',
        retryable: decoded['retryable'] as bool?,
      );
    }
    final result = decoded['result'];
    if (result is! Map<String, dynamic>) {
      throw const CloakRouteException('Malformed Cloak runtime reply');
    }
    return result;
  }

  Future<int> _balance(String address) async {
    final result = await _rpc('getBalance', [
      address,
      {'commitment': 'confirmed'},
    ]);
    final value = result is Map ? result['value'] : null;
    if (value is! int) {
      throw const CloakRouteException('Malformed getBalance response');
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
      throw CloakRouteException('Malformed RPC response to $method');
    }
    if (decoded is! Map) {
      throw CloakRouteException('Malformed RPC response to $method');
    }
    final error = decoded['error'];
    if (error != null) {
      final msg = error is Map ? error['message'] : error;
      throw CloakRouteException('$method failed: $msg');
    }
    return decoded['result'];
  }

  static String _format(int baseUnits, CloakPool pool) {
    final s = baseUnits.toString().padLeft(pool.decimals + 1, '0');
    final whole = s.substring(0, s.length - pool.decimals);
    final frac = s
        .substring(s.length - pool.decimals)
        .replaceFirst(RegExp(r'0+$'), '');
    return '${frac.isEmpty ? whole : '$whole.$frac'} ${pool.symbol}';
  }

  static bool _isPubkey(String s) {
    try {
      return base58decode(s).length == 32;
    } on FormatException {
      return false;
    }
  }
}
