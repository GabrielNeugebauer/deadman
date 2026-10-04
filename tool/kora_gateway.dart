// Public entry to the Kora fee sponsor (audit M-4). Kora listens on :8090
// behind an API key that only this gateway holds. The gateway forwards
// getPayerSigner, getBlockhash and signAndSendTransaction, and only signs
// transactions that are a guard key's Deadman `pulse` / `lockdown` on vaults
// it guards, rate-limited per vault, per guard key and globally.
//
// dart run tool/kora_gateway.dart
//
// Env: SPONSOR_API_KEY (required), RPC_URL, GATEWAY_PORT (8080),
// KORA_UPSTREAM (http://127.0.0.1:8090), GATEWAY_STATE
// (kora/gateway-usage.json), GATEWAY_PER_VAULT (24), GATEWAY_PER_SIGNER (48),
// GATEWAY_GLOBAL (2000), GATEWAY_PER_IP_MINUTE (60).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:deadman/core/config.dart';
import 'package:deadman/solana/codec.dart' show Disc;
import 'package:http/http.dart' as http;
import 'package:solana/base58.dart';
import 'package:solana/dto.dart' show BinaryAccountData, Commitment, Encoding;
import 'package:solana/solana.dart';

const computeBudgetProgramId = ComputeBudgetProgram.programId;
const allowedMethods = {
  'getPayerSigner',
  'getBlockhash',
  'signAndSendTransaction',
};

/// A request the gateway refuses; sent back as a JSON-RPC error.
class GatewayRejection implements Exception {
  const GatewayRejection(this.message);
  final String message;

  @override
  String toString() => 'GatewayRejection: $message';
}

Never _reject(String message) => throw GatewayRejection(message);

class SponsorPolicy {
  const SponsorPolicy({
    required this.koraPayer,
    this.programId = AppConfig.programId,
  });

  static const maxCuLimit = 60000;
  static const maxFeeLamports = 50000;
  static const maxDeadmanIxs = 8;
  static const lamportsPerSignature = 5000;
  static const defaultCuPerIx = 200000;
  static const maxTxCu = 1400000;

  final String koraPayer;
  final String programId;
}

/// A transaction that passed [validateSponsorTx]; the guard signature and the
/// vaults are checked next.
class SponsorRequest {
  const SponsorRequest({
    required this.signer,
    required this.vaults,
    required this.feeLamports,
    required this.message,
    required this.signature,
  });

  /// The one non-Kora signer (must be every vault's guard).
  final String signer;

  /// Distinct vault accounts, in instruction order.
  final List<String> vaults;
  final int feeLamports;
  final Uint8List message;
  final Uint8List signature;
}

class _Ix {
  const _Ix(this.programIndex, this.accounts, this.data);
  final int programIndex;
  final List<int> accounts;
  final Uint8List data;
}

class _Reader {
  _Reader(this._b);
  final List<int> _b;
  int offset = 0;

  bool get done => offset == _b.length;

  int u8() {
    if (offset >= _b.length) _reject('Malformed transaction');
    return _b[offset++];
  }

  Uint8List bytes(int n) {
    if (offset + n > _b.length) _reject('Malformed transaction');
    final out = Uint8List.fromList(_b.sublist(offset, offset + n));
    offset += n;
    return out;
  }

  /// compact-u16
  int shortVec() {
    var value = 0;
    for (var i = 0; i < 3; i++) {
      final b = u8();
      value |= (b & 0x7f) << (7 * i);
      if (b & 0x80 == 0) return value;
    }
    _reject('Malformed transaction');
  }
}

BigInt _uLe(List<int> b) {
  var v = BigInt.zero;
  for (var i = b.length - 1; i >= 0; i--) {
    v = (v << 8) | BigInt.from(b[i]);
  }
  return v;
}

bool _eq(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Checks a wire transaction (base64-decoded, legacy or v0) against the
/// sponsor policy. Pure: the guard signature ([verifyGuardSignature]) and the
/// vault accounts ([checkVaultAccounts]) are checked separately.
SponsorRequest validateSponsorTx(List<int> wire, SponsorPolicy policy) {
  final r = _Reader(wire);
  final signatures = [for (var i = r.shortVec(); i > 0; i--) r.bytes(64)];
  final messageStart = r.offset;
  int? version;
  if (messageStart < wire.length && wire[messageStart] & 0x80 != 0) {
    version = r.u8() & 0x7f;
    if (version != 0) _reject('Unsupported transaction version $version');
  }
  final requiredSigs = r.u8();
  final readonlySigned = r.u8();
  final readonlyUnsigned = r.u8();
  final keys = [
    for (var i = r.shortVec(); i > 0; i--) base58encode(r.bytes(32)),
  ];
  r.bytes(32); // recent blockhash
  final ixs = <_Ix>[];
  for (var n = r.shortVec(); n > 0; n--) {
    final program = r.u8();
    final accounts = [for (var i = r.shortVec(); i > 0; i--) r.u8()];
    ixs.add(_Ix(program, accounts, r.bytes(r.shortVec())));
  }
  if (version == 0) {
    final lookups = r.shortVec();
    if (lookups != 0) _reject('Address lookup tables are not allowed');
  }
  if (!r.done) _reject('Malformed transaction');

  if (requiredSigs != 2 || signatures.length != 2) {
    _reject(
      'Sponsored transactions need exactly 2 signatures: the sponsor and '
      'the guard key',
    );
  }
  if (keys.length < 3 ||
      keys.toSet().length != keys.length ||
      readonlySigned > 1 ||
      requiredSigs + readonlyUnsigned > keys.length) {
    _reject('Malformed transaction');
  }
  if (keys[0] != policy.koraPayer) {
    _reject('The sponsor ${policy.koraPayer} must be the fee payer');
  }
  final signer = keys[1];

  int? cuLimit;
  BigInt? cuPrice;
  var deadmanIxs = 0;
  final vaults = <String>{};
  for (final ix in ixs) {
    if (ix.programIndex >= keys.length ||
        ix.accounts.any((a) => a >= keys.length)) {
      _reject('Malformed transaction');
    }
    if (ix.accounts.contains(0)) {
      _reject('Instructions may not reference the sponsor account');
    }
    final program = keys[ix.programIndex];
    final d = ix.data;
    if (program == computeBudgetProgramId) {
      if (ix.accounts.isNotEmpty) {
        _reject('Malformed ComputeBudget instruction');
      }
      if (d.length == 5 && d[0] == 2 && cuLimit == null) {
        cuLimit = _uLe(d.sublist(1)).toInt();
      } else if (d.length == 9 && d[0] == 3 && cuPrice == null) {
        cuPrice = _uLe(d.sublist(1));
      } else {
        _reject(
          'Only one SetComputeUnitLimit and one SetComputeUnitPrice '
          'ComputeBudget instruction are allowed',
        );
      }
    } else if (program == policy.programId) {
      if (++deadmanIxs > SponsorPolicy.maxDeadmanIxs) {
        _reject(
          'At most ${SponsorPolicy.maxDeadmanIxs} Deadman instructions per '
          'transaction',
        );
      }
      if (d.length != 8 || !(_eq(d, Disc.pulse) || _eq(d, Disc.lockdown))) {
        _reject('Only Deadman pulse and lockdown are sponsored');
      }
      if (ix.accounts.length != 2 || ix.accounts[1] < requiredSigs) {
        _reject('Malformed Deadman instruction');
      }
      if (keys[ix.accounts[0]] != signer) {
        _reject(
          "Each pulse/lockdown must be signed by the transaction's guard key",
        );
      }
      vaults.add(keys[ix.accounts[1]]);
    } else {
      _reject('Program $program is not sponsored');
    }
  }
  if (deadmanIxs == 0) _reject('No Deadman pulse or lockdown to sponsor');
  if (cuLimit != null && cuLimit > SponsorPolicy.maxCuLimit) {
    _reject('Compute unit limit $cuLimit exceeds ${SponsorPolicy.maxCuLimit}');
  }
  final limit =
      cuLimit ??
      (SponsorPolicy.defaultCuPerIx * ixs.length).clamp(
        0,
        SponsorPolicy.maxTxCu,
      );
  final micro = BigInt.from(1000000);
  final priority =
      (BigInt.from(limit) * (cuPrice ?? BigInt.zero) + micro - BigInt.one) ~/
      micro;
  final fee =
      BigInt.from(requiredSigs * SponsorPolicy.lamportsPerSignature) + priority;
  if (fee > BigInt.from(SponsorPolicy.maxFeeLamports)) {
    _reject(
      'Fee $fee lamports exceeds the sponsored maximum of '
      '${SponsorPolicy.maxFeeLamports}',
    );
  }
  return SponsorRequest(
    signer: signer,
    vaults: vaults.toList(),
    feeLamports: fee.toInt(),
    message: Uint8List.fromList(wire.sublist(messageStart)),
    signature: signatures[1],
  );
}

/// Whether the guard's signature is valid, so a stranger cannot burn a
/// vault's quota with unsigned copies of its pulse.
Future<bool> verifyGuardSignature(SponsorRequest request) => verifySignature(
  message: request.message,
  signature: request.signature,
  publicKey: Ed25519HDPublicKey.fromBase58(request.signer),
);

typedef VaultAccount = ({String owner, Uint8List data});

/// Requires every vault to be a Deadman vault whose guard is the signer, and
/// the signer to be neither its owner nor its guardian (owner wallets pay
/// their own fees; the guardian's lockdown is not sponsored).
void checkVaultAccounts(
  SponsorRequest request,
  List<VaultAccount?> accounts,
  SponsorPolicy policy,
) {
  if (accounts.length != request.vaults.length) {
    _reject('Could not load the vault accounts');
  }
  for (var i = 0; i < accounts.length; i++) {
    final vault = request.vaults[i];
    final a = accounts[i];
    if (a == null) _reject('Vault $vault not found');
    final d = a.data;
    if (a.owner != policy.programId ||
        d.length < 75 ||
        !_eq(d.sublist(0, 8), Disc.vaultAccount)) {
      _reject('$vault is not a Deadman vault');
    }
    final owner = base58encode(d.sublist(8, 40));
    final guard = base58encode(d.sublist(42, 74));
    final guardian = d[74] == 1 && d.length >= 107
        ? base58encode(d.sublist(75, 107))
        : null;
    if (request.signer == owner) {
      _reject('Owner-signed transactions are not sponsored; the wallet pays');
    }
    if (request.signer == guardian) {
      _reject('Guardian-signed transactions are not sponsored');
    }
    if (request.signer != guard) {
      _reject('${request.signer} is not the guard key of vault $vault');
    }
  }
}

/// Rolling-window counters per vault, per signer and global, persisted to
/// [file] after every sponsored transaction.
class UsageLimiter {
  UsageLimiter({
    this.perVault = 24,
    this.perSigner = 48,
    this.global = 2000,
    this.windowSecs = 86400,
    this.file,
    int Function()? clock,
  }) : _now = clock ?? _systemNow {
    _load();
  }

  final int perVault;
  final int perSigner;
  final int global;
  final int windowSecs;
  final File? file;
  final int Function() _now;

  final _vaults = <String, List<int>>{};
  final _signers = <String, List<int>>{};
  final _global = <int>[];

  static int _systemNow() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  /// Throws if this transaction would exceed a limit; records nothing.
  void check(String signer, List<String> vaults) {
    final now = _now();
    _prune(now);
    String retry(List<int> hits) => DateTime.fromMillisecondsSinceEpoch(
      (hits.first + windowSecs) * 1000,
      isUtc: true,
    ).toIso8601String();
    if (_global.length >= global) {
      _reject(
        'Rate limit: the sponsor reached its cap of $global transactions per '
        '24h; retry after ${retry(_global)}',
      );
    }
    final s = _signers[signer] ?? const [];
    if (s.length >= perSigner) {
      _reject(
        'Rate limit: guard key $signer reached $perSigner sponsored '
        'transactions per 24h; retry after ${retry(s)}',
      );
    }
    for (final v in vaults) {
      final hits = _vaults[v] ?? const [];
      if (hits.length >= perVault) {
        _reject(
          'Rate limit: vault $v reached $perVault sponsored transactions per '
          '24h; retry after ${retry(hits)}',
        );
      }
    }
  }

  /// [check], then records the transaction. Synchronous, so concurrent
  /// requests cannot both pass the last free slot.
  void acquire(String signer, List<String> vaults) {
    check(signer, vaults);
    final now = _now();
    _global.add(now);
    (_signers[signer] ??= []).add(now);
    for (final v in vaults.toSet()) {
      (_vaults[v] ??= []).add(now);
    }
    _save();
  }

  void _prune(int now) {
    final cutoff = now - windowSecs;
    _global.removeWhere((t) => t <= cutoff);
    for (final m in [_vaults, _signers]) {
      m.removeWhere(
        (_, hits) => (hits..removeWhere((t) => t <= cutoff)).isEmpty,
      );
    }
  }

  Map<String, Object> toJson() => {
    'global': _global,
    'signers': _signers,
    'vaults': _vaults,
  };

  void _load() {
    final f = file;
    if (f == null || !f.existsSync()) return;
    try {
      final j = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      List<int> ints(Object? l) => [for (final t in l as List) t as int];
      _global.addAll(ints(j['global']));
      for (final (key, into) in [('signers', _signers), ('vaults', _vaults)]) {
        (j[key] as Map<String, dynamic>).forEach((k, v) => into[k] = ints(v));
      }
    } on Object catch (e) {
      stderr.writeln('Ignoring unreadable usage file ${f.path}: $e');
    }
  }

  void _save() {
    final f = file;
    if (f == null) return;
    final tmp = File('${f.path}.tmp')..writeAsStringSync(jsonEncode(toJson()));
    tmp.renameSync(f.path);
  }
}

/// Fixed one-minute window per client IP, to keep junk off the upstream.
class _IpLimiter {
  _IpLimiter(this.perMinute);
  final int perMinute;
  final _hits = <String, (int, int)>{};

  bool allow(String ip, int nowSecs) {
    final window = nowSecs ~/ 60;
    if (_hits.length > 10000) _hits.removeWhere((_, e) => e.$1 != window);
    final e = _hits[ip];
    final count = e == null || e.$1 != window ? 1 : e.$2 + 1;
    _hits[ip] = (window, count);
    return count <= perMinute;
  }
}

class KoraGateway {
  KoraGateway({
    required this.upstream,
    required this.apiKey,
    required this.policy,
    required this.payerSigner,
    required this.limiter,
    required this.fetchAccounts,
    this.maxBodyBytes = 8192,
    int perIpPerMinute = 60,
    http.Client? httpClient,
    void Function(String)? log,
  }) : _http = httpClient ?? http.Client(),
       _ips = _IpLimiter(perIpPerMinute),
       log = log ?? stdout.writeln;

  final Uri upstream;
  final String apiKey;
  final SponsorPolicy policy;

  /// Kora's cached `getPayerSigner` result.
  final Map<String, dynamic> payerSigner;
  final UsageLimiter limiter;
  final Future<List<VaultAccount?>> Function(List<String>) fetchAccounts;
  final int maxBodyBytes;
  final void Function(String) log;
  final http.Client _http;
  final _IpLimiter _ips;

  (int, Object)? _blockhash;

  Future<HttpServer> serve(InternetAddress address, int port) async {
    final server = await HttpServer.bind(address, port);
    server.listen((r) => unawaited(handle(r)));
    return server;
  }

  Future<void> handle(HttpRequest req) async {
    final res = req.response;
    final ip = req.connectionInfo?.remoteAddress.address ?? '?';
    try {
      if (req.method == 'GET' && req.uri.path == '/liveness') {
        final r = await _http.get(upstream.resolve('/liveness'));
        res.statusCode = r.statusCode == 200 ? 200 : 502;
        return;
      }
      if (req.method != 'POST') {
        res.statusCode = HttpStatus.methodNotAllowed;
        return;
      }
      if (!_ips.allow(ip, DateTime.now().millisecondsSinceEpoch ~/ 1000)) {
        _send(res, null, error: 'Too many requests', status: 429);
        return;
      }
      final body = await _readBody(req);
      if (body == null) {
        _send(res, null, error: 'Request body too large', status: 413);
        return;
      }
      Object? json;
      try {
        json = jsonDecode(utf8.decode(body));
      } on FormatException {
        _send(res, null, error: 'Parse error', code: -32700);
        return;
      }
      if (json is! Map<String, dynamic> || json['method'] is! String) {
        _send(res, null, error: 'Invalid request', code: -32600);
        return;
      }
      final id = json['id'];
      final method = json['method'] as String;
      if (!allowedMethods.contains(method)) {
        _send(
          res,
          id,
          error: 'Method $method is not available on the Deadman sponsor',
          code: -32601,
        );
        return;
      }
      switch (method) {
        case 'getPayerSigner':
          _send(res, id, result: payerSigner);
        case 'getBlockhash':
          await _getBlockhash(res, id);
        default:
          await _signAndSend(res, id, json['params'], ip);
      }
    } on GatewayRejection catch (e) {
      _send(res, null, error: e.message);
    } on Object catch (e) {
      log('${_ts()} error $ip: $e');
      try {
        _send(res, null, error: 'Sponsor temporarily unavailable', status: 502);
      } on StateError {
        // Headers already sent.
      }
    } finally {
      await res.close();
    }
  }

  Future<List<int>?> _readBody(HttpRequest req) async {
    if (req.contentLength > maxBodyBytes) return null;
    final out = BytesBuilder(copy: false);
    await for (final chunk in req) {
      out.add(chunk);
      if (out.length > maxBodyBytes) return null;
    }
    return out.takeBytes();
  }

  Future<void> _getBlockhash(HttpResponse res, Object? id) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final cached = _blockhash;
    if (cached != null && now - cached.$1 < 1000) {
      _send(res, id, result: cached.$2);
      return;
    }
    final r = await _forward('getBlockhash', null);
    final result = r['result'];
    if (result != null) _blockhash = (now, result);
    _relay(res, id, r);
  }

  Future<void> _signAndSend(
    HttpResponse res,
    Object? id,
    Object? params,
    String ip,
  ) async {
    final tx = params is Map ? params['transaction'] : null;
    if (tx is! String || tx.length > 2048) {
      _send(res, id, error: 'params.transaction must be a base64 transaction');
      return;
    }
    final SponsorRequest request;
    try {
      request = validateSponsorTx(base64Decode(tx), policy);
      if (!await verifyGuardSignature(request)) {
        _reject('Invalid guard signature');
      }
      limiter.check(request.signer, request.vaults);
      checkVaultAccounts(request, await fetchAccounts(request.vaults), policy);
      limiter.acquire(request.signer, request.vaults);
    } on FormatException {
      _send(res, id, error: 'params.transaction is not valid base64');
      return;
    } on GatewayRejection catch (e) {
      log('${_ts()} reject $ip: ${e.message}');
      _send(res, id, error: e.message);
      return;
    }
    final r = await _forward('signAndSendTransaction', {'transaction': tx});
    final outcome = r['error'] is Map
        ? 'kora error: ${(r['error'] as Map)['message']}'
        : 'sent ${(r['result'] as Map?)?['signature']}';
    log(
      '${_ts()} sponsor $ip signer=${request.signer} '
      'vaults=${request.vaults.join(',')} fee<=${request.feeLamports} $outcome',
    );
    _relay(res, id, r);
  }

  Future<Map<String, dynamic>> _forward(
    String method,
    Map<String, Object>? params,
  ) async {
    final r = await _http
        .post(
          upstream,
          headers: {'Content-Type': 'application/json', 'x-api-key': apiKey},
          body: jsonEncode({
            'jsonrpc': '2.0',
            'id': 1,
            'method': method,
            'params': params ?? const <Object>[],
          }),
        )
        .timeout(const Duration(seconds: 90));
    if (r.statusCode != 200) {
      throw StateError('upstream $method returned HTTP ${r.statusCode}');
    }
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  void _relay(HttpResponse res, Object? id, Map<String, dynamic> upstream) {
    final error = upstream['error'];
    if (error is Map) {
      _send(
        res,
        id,
        error: '${error['message']}',
        code: error['code'] as int? ?? -32000,
      );
    } else {
      _send(res, id, result: upstream['result']);
    }
  }

  static void _send(
    HttpResponse res,
    Object? id, {
    Object? result,
    String? error,
    int code = -32000,
    int status = 200,
  }) {
    res
      ..statusCode = status
      ..headers.contentType = ContentType.json
      ..write(
        jsonEncode({
          'jsonrpc': '2.0',
          if (error == null)
            'result': result
          else
            'error': {'code': code, 'message': error},
          'id': id,
        }),
      );
  }

  static String _ts() => DateTime.now().toUtc().toIso8601String();
}

/// Loads [addresses] with getMultipleAccounts (base64).
Future<List<VaultAccount?>> Function(List<String>) rpcAccountFetcher(
  RpcClient rpc,
) => (addresses) async {
  final r = await rpc.getMultipleAccounts(
    addresses,
    commitment: Commitment.confirmed,
    encoding: Encoding.base64,
  );
  return [
    for (final a in r.value)
      if (a != null && a.data is BinaryAccountData)
        (
          owner: a.owner,
          data: Uint8List.fromList((a.data! as BinaryAccountData).data),
        )
      else
        null,
  ];
};

Future<void> main() async {
  final env = Platform.environment;
  final apiKey = env['SPONSOR_API_KEY'] ?? '';
  if (apiKey.isEmpty) {
    stderr.writeln('SPONSOR_API_KEY is not set (see docs/KORA.md)');
    exit(64);
  }
  int envInt(String name, int fallback) =>
      int.tryParse(env[name] ?? '') ?? fallback;
  final upstream = Uri.parse(env['KORA_UPSTREAM'] ?? 'http://127.0.0.1:8090');
  final rpcUrl = env['RPC_URL'] ?? AppConfig.rpcUrl;
  final port = envInt('GATEWAY_PORT', 8080);

  final client = http.Client();
  Map<String, dynamic>? payer;
  for (var attempt = 0; payer == null; attempt++) {
    try {
      final r = await client.post(
        upstream,
        headers: {'Content-Type': 'application/json', 'x-api-key': apiKey},
        body: '{"jsonrpc":"2.0","id":1,"method":"getPayerSigner","params":[]}',
      );
      if (r.statusCode != 200) throw StateError('HTTP ${r.statusCode}');
      payer = (jsonDecode(r.body) as Map)['result'] as Map<String, dynamic>;
    } on Object catch (e) {
      if (attempt >= 60) {
        stderr.writeln('Kora at $upstream unreachable: $e');
        exit(1);
      }
      await Future<void>.delayed(const Duration(seconds: 1));
    }
  }

  final gateway = KoraGateway(
    upstream: upstream,
    apiKey: apiKey,
    policy: SponsorPolicy(koraPayer: payer['signer_address'] as String),
    payerSigner: payer,
    limiter: UsageLimiter(
      perVault: envInt('GATEWAY_PER_VAULT', 24),
      perSigner: envInt('GATEWAY_PER_SIGNER', 48),
      global: envInt('GATEWAY_GLOBAL', 2000),
      file: File(env['GATEWAY_STATE'] ?? 'kora/gateway-usage.json'),
    ),
    fetchAccounts: rpcAccountFetcher(RpcClient(rpcUrl)),
    perIpPerMinute: envInt('GATEWAY_PER_IP_MINUTE', 60),
    httpClient: client,
  );
  final server = await gateway.serve(InternetAddress.anyIPv4, port);
  stdout.writeln(
    '${KoraGateway._ts()} gateway on :$port -> $upstream, '
    'payer ${gateway.policy.koraPayer}, rpc $rpcUrl',
  );
  for (final signal in [ProcessSignal.sigint, ProcessSignal.sigterm]) {
    signal.watch().listen((_) async {
      await server.close(force: true);
      exit(0);
    });
  }
}
