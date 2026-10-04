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

/// A shielded note paid to this device's Cloak receive address (see
/// [CloakRoute.receiveAddressFor]), found by [CloakRoute.scanReceived].
class CloakNote {
  const CloakNote({
    required this.commitment,
    required this.amount,
    required this.mint,
    required this.blinding,
    required this.spent,
    this.leafIndex,
    this.receivedAt,
  });

  factory CloakNote.fromJson(Map<String, dynamic> json) {
    final blockTime = json['blockTime'] as int?;
    return CloakNote(
      commitment: json['commitment'] as String,
      amount: int.parse(json['amount'] as String),
      mint: json['mint'] as String?,
      blinding: json['blinding'] as String,
      spent: json['spent'] as bool,
      leafIndex: json['index'] as int?,
      receivedAt: blockTime == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(blockTime * 1000, isUtc: true),
    );
  }

  /// 64 hex chars; identifies the note in the pool.
  final String commitment;

  /// Base units of [mint].
  final int amount;

  /// `null` for native SOL.
  final String? mint;

  /// The note's secret blinding (64 hex chars), needed to spend it. Not a
  /// key: spending also needs the claim key.
  final String blinding;
  final bool spent;

  /// Position in the pool's Merkle tree, once the relay has indexed it.
  final int? leafIndex;
  final DateTime? receivedAt;

  CloakPool? get pool => CloakRoute.pools[mint];

  Map<String, Object?> toJson() => {
    'commitment': commitment,
    'amount': '$amount',
    'mint': mint,
    'blinding': blinding,
  };

  @override
  String toString() => 'CloakNote($commitment, $amount ${pool?.symbol})';
}

/// [CloakRoute.selfTest] result: the deposit pipeline ran up to signing.
class CloakSelfTest {
  const CloakSelfTest({
    required this.download,
    required this.prove,
    required this.total,
    required this.steps,
  });

  /// Fetching and hash-checking the proving files (near zero once cached).
  final Duration download;

  /// Groth16 proof generation, when the SDK reported its progress.
  final Duration? prove;
  final Duration total;

  /// SDK progress messages, prefixed with ms since the deposit started.
  final List<String> steps;
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
/// Receiving side: [receiveAddressFor] gives the claim key's own `cloak:`
/// address, [scanReceived] finds notes paid to it, [withdrawReceived]
/// unshields them to any Solana address.
///
/// The claim key's secret is handed to the on-device WebView only.
class CloakRoute implements PrivateRoute {
  CloakRoute({
    this._runtime,
    http.Client? client,
    String? cluster,
    String? rpcUrl,
    this.solFeeReserveLamports = 5000000,
    this.splFeeReserveLamports = defaultSplFeeReserveLamports,
    this.quoteTtl = const Duration(minutes: 10),
    DateTime Function()? now,
  }) : _http = client ?? http.Client(),
       _cluster = cluster ?? AppConfig.cluster,
       _rpcUrl = Uri.parse(
         rpcUrl ?? (rpcOverride.isNotEmpty ? rpcOverride : AppConfig.rpcUrl),
       ),
       _selfTestRpcUrl =
           rpcUrl ?? (rpcOverride.isNotEmpty ? rpcOverride : selfTestRpcUrl),
       _now = now ?? DateTime.now;

  /// Mainnet only; Cloak has no devnet deployment (verified 2026-10-02).
  static const programId = 'zh1eLd6rSphLejbFfJEneUwzHRfMKxgzrgkfwA6qRkW';
  static const relayUrl = 'https://api.cloak.ag';
  static const sdkVersion = '0.2.5';
  static const deployedClusters = {'mainnet-beta'};

  /// RPC for the WebView, which needs one that allows browser requests
  /// (api.mainnet-beta.solana.com answers 403) and, for [scanReceived],
  /// serves `getSignaturesForAddress` history (publicnode returns none).
  /// `--dart-define=CLOAK_RPC_URL=...`; empty = `AppConfig.rpcUrl`.
  static const rpcOverride = String.fromEnvironment('CLOAK_RPC_URL');

  /// Mainnet RPC [selfTest] reads from when no Cloak RPC is configured, so
  /// it also runs on devnet builds. Allows browser requests.
  static const selfTestRpcUrl = 'https://solana-rpc.publicnode.com';

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
  static const defaultSplFeeReserveLamports = 10000000;
  final Duration quoteTtl;

  final CloakJsRuntime? _runtime;
  final http.Client _http;
  final String _cluster;
  final Uri _rpcUrl;
  final String _selfTestRpcUrl;
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
    final runtime = _requireRuntime();
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

    final result = await _runWithClaim(runtime, 'shieldAndSend', claimKey, {
      'rpcUrl': _rpcUrl.toString(),
      'mint': quote.inputMint,
      'amount': '${quote.amountIn}',
      'recipientUtxoPubkey': data.shielded?.utxoPubkey,
      'recipientViewingPubkey': data.shielded?.viewingPubkey,
      'recipientSolana': data.publicRecipient,
      'resumeOnlyReason': shortfall,
    });
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

  /// This device's Cloak address for [claimKey]: the shielded destination
  /// whose payouts [scanReceived] finds and [withdrawReceived] unshields.
  /// Derived from the claim key, so the phrase restores it.
  Future<CloakAddress> receiveAddressFor(Ed25519HDKeyPair claimKey) async {
    final runtime = _runtime;
    if (runtime == null) throw CloakRouteException(unavailableReason!);
    final result = await _runWithClaim(
      runtime,
      'receiveAddress',
      claimKey,
      const {},
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

  /// Notes paid to [receiveAddressFor] `claimKey`, spent ones included.
  /// Reads the whole on-chain delivery registry (one RPC call per delivery
  /// ever made) and fails rather than return a partial list.
  Future<List<CloakNote>> scanReceived({
    required Ed25519HDKeyPair claimKey,
  }) async {
    final runtime = _requireRuntime();
    final result = await _runWithClaim(runtime, 'scanReceived', claimKey, {
      'rpcUrl': _rpcUrl.toString(),
    });
    final notes = result['notes'];
    try {
      return [
        for (final n in notes as List)
          CloakNote.fromJson(n as Map<String, dynamic>),
      ];
    } on Object {
      throw const CloakRouteException('Malformed Cloak scan reply');
    }
  }

  /// Unshields [notes] (one mint, all unspent) in full to the Solana
  /// address [destination]. Cloak's relay submits it; the claim key needs no
  /// SOL. Exit fee [exitFee] is deducted. Returns the last signature.
  Future<String> withdrawReceived({
    required Ed25519HDKeyPair claimKey,
    required List<CloakNote> notes,
    required String destination,
  }) async {
    final runtime = _requireRuntime();
    if (notes.isEmpty) throw const CloakRouteException('No notes to withdraw');
    final mint = notes.first.mint;
    final pool = pools[mint];
    if (pool == null) throw CloakRouteException('Unsupported mint $mint');
    if (notes.any((n) => n.mint != mint)) {
      throw const CloakRouteException('Withdraw one mint at a time');
    }
    if (notes.any((n) => n.spent)) {
      throw const CloakRouteException('A selected note was already withdrawn');
    }
    if (!_isPubkey(destination)) {
      throw const CloakRouteException('Invalid destination address');
    }
    final total = notes.fold(0, (sum, n) => sum + n.amount);
    if (total <= exitFee(total, pool)) {
      throw CloakRouteException(
        'Notes do not cover the Cloak exit fee of '
        '${_format(exitFee(total, pool), pool)}',
      );
    }
    final result = await _runWithClaim(runtime, 'withdrawReceived', claimKey, {
      'rpcUrl': _rpcUrl.toString(),
      'destination': destination,
      'notes': [for (final n in notes) n.toJson()],
    });
    final sig = result['signature'];
    if (sig is! String || sig.isEmpty) {
      throw const CloakRouteException('Cloak runtime returned no signature');
    }
    return sig;
  }

  /// Runs the deposit pipeline from a random unfunded key against mainnet up
  /// to signing: proving-file download and hash check, Groth16 proof, risk
  /// quote, transaction build. Nothing is signed or sent, so it needs only
  /// the runtime and works on devnet builds. [mint] `null` is SOL; the
  /// amount is the pool minimum.
  Future<CloakSelfTest> selfTest({String? mint}) async {
    final runtime = _runtime;
    if (runtime == null) {
      throw const CloakRouteException('Cloak runtime not started');
    }
    if (!pools.containsKey(mint)) {
      throw CloakRouteException('Unsupported input mint $mint');
    }
    final result = _unwrap(
      await runtime.run(
        'selfTest',
        jsonEncode({'rpcUrl': _selfTestRpcUrl, 'mint': mint}),
      ),
    );
    final download = result['downloadMs'];
    final prove = result['proveMs'];
    final total = result['totalMs'];
    final steps = result['steps'];
    if (result['reachedSigning'] != true ||
        download is! int ||
        (prove != null && prove is! int) ||
        total is! int ||
        steps is! List) {
      throw const CloakRouteException('Malformed Cloak self-test reply');
    }
    return CloakSelfTest(
      download: Duration(milliseconds: download),
      prove: prove == null ? null : Duration(milliseconds: prove as int),
      total: Duration(milliseconds: total),
      steps: steps.map((s) => '$s').toList(),
    );
  }

  CloakJsRuntime _requireRuntime() {
    final runtime = _runtime;
    final reason = unavailableReason;
    if (runtime == null || reason != null) throw CloakRouteException(reason!);
    return runtime;
  }

  /// Hands [claimKey]'s secret to the runtime with [payload] and wipes the
  /// extracted bytes afterwards.
  static Future<Map<String, dynamic>> _runWithClaim(
    CloakJsRuntime runtime,
    String op,
    Ed25519HDKeyPair claimKey,
    Map<String, Object?> payload,
  ) async {
    final secret = await claimKey.extract();
    final String reply;
    try {
      reply = await runtime.run(
        op,
        jsonEncode({...payload, 'secret': base64Encode(secret.bytes)}),
      );
    } finally {
      secret.destroy();
    }
    return _unwrap(reply);
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
