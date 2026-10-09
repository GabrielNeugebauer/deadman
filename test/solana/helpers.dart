import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:deadman/solana/codec.dart';
import 'package:deadman/solana/deadman_api.dart';
import 'package:solana/base58.dart';
import 'package:solana/solana.dart';

String key(int seed) =>
    base58encode(List<int>.generate(32, (i) => (seed * 31 + i * 7) & 0xff));

List<int> le(int bytes, int value) {
  final d = ByteData(8)..setInt64(0, value, Endian.little);
  return d.buffer.asUint8List(0, bytes).toList();
}

List<int> keyBytes(String k) => Ed25519HDPublicKey.fromBase58(k).bytes;

/// The built IDL, or the file named by `DEADMAN_IDL` when set.
Map<String, dynamic> loadIdl() => jsonDecode(
  File(Platform.environment['DEADMAN_IDL'] ?? 'onchain/target/idl/deadman.json')
      .readAsStringSync(),
) as Map<String, dynamic>;

List<int> ruleInputBytes(RuleSpec r) => [
  ...keyBytes(r.beneficiary),
  r.rail.index,
  ...le(8, r.afterSecs),
  if (r.mint == null) 0 else ...[1, ...keyBytes(r.mint!)],
  r.mode.index,
  ...le(8, r.amount),
];

List<int> ruleStateBytes(RuleState r) => [
  ...ruleInputBytes(r),
  ...le(8, r.executedAt),
  ...le(8, r.paid),
  ...le(8, r.skippedAt),
  ...le(8, r.reserved),
  ...le(8, r.durationSecs),
  ...le(8, r.released),
];

List<int> vaultBytes({
  required String owner,
  int planId = 0,
  String label = '',
  required String guard,
  String? guardian,
  int legacyInterval = 86400,
  int lockSecs = 3600,
  int skipGraceSecs = 30 * 86400,
  int lastPulse = 1790000000,
  int? ownerLastSeen,
  int lockedUntil = 1790003600,
  int guardianReadyAt = 1790007200,
  int totalPulses = 42,
  int streak = 7,
  int bestStreak = 12,
  PlanKind kind = PlanKind.inheritance,
  int startAt = 0,
  bool revocable = false,
  int revokedAt = 0,
  String? rentPayer,
  int rentPaid = 0,
  List<RuleState> rules = const [],
  int stipendPaid = 0,
  int vestPeriodSecs = 0,
}) => _padVault([
  ...Disc.vaultAccount,
  ...keyBytes(owner),
  ...le(2, planId),
  ...keyBytes(guard),
  if (guardian == null) 0 else ...[1, ...keyBytes(guardian)],
  ...le(8, legacyInterval), // _reserved_interval
  ...le(8, lockSecs),
  ...le(8, skipGraceSecs),
  ...le(8, lastPulse),
  ...le(8, ownerLastSeen ?? lastPulse),
  ...le(8, lockedUntil),
  ...le(8, guardianReadyAt),
  ...le(8, totalPulses),
  ...le(4, streak),
  ...le(4, bestStreak),
  kind.index,
  ...le(8, startAt),
  if (revocable) 1 else 0,
  ...le(8, revokedAt),
  ...keyBytes(rentPayer ?? owner),
  ...le(8, rentPaid),
  ...le(4, rules.length),
  for (final r in rules) ...ruleStateBytes(r),
  ...le(4, utf8.encode(label).length),
  ...utf8.encode(label),
  254,
  stipendPaid,
  ...le(8, vestPeriodSecs),
  ...List<int>.filled(55, 0), // _reserved
]);

/// Unused rule and label space stays zeroed up to the fixed account size.
List<int> _padVault(List<int> bytes) => [
  ...bytes,
  ...List<int>.filled(vaultAccountSize - bytes.length, 0),
];

/// `Config` account: the current 209-byte layout, or with [v1] the first
/// 77-byte one (no SKR rate, not yet migrated by `set_config`).
List<int> configBytes({
  required String admin,
  required String treasury,
  int feeBpsPublic = 200,
  int feeBpsPrivate = 300,
  String? skrMint,
  int feeBpsSkr = 150,
  int skrBurnBps = 1000,
  String? pendingAdmin,
  bool v1 = false,
}) => [
  ...Disc.configAccount,
  ...keyBytes(admin),
  ...keyBytes(treasury),
  ...le(2, feeBpsPublic),
  ...le(2, feeBpsPrivate),
  253,
  if (!v1) ...[
    ...keyBytes(skrMint ?? defaultPubkey),
    ...le(2, feeBpsSkr),
    ...le(2, skrBurnBps),
    ...keyBytes(pendingAdmin ?? defaultPubkey),
    ...List<int>.filled(64, 0), // _reserved
  ],
];

List<int> mintBytes(int decimals) => List<int>.filled(82, 0)
  ..[44] = decimals
  ..[45] = 1;

List<int> tokenAccountBytes({
  required String mint,
  required String owner,
  required int amount,
}) => [
  ...keyBytes(mint),
  ...keyBytes(owner),
  ...le(8, amount),
  ...List<int>.filled(165 - 72, 0),
];

class FakeAccount {
  const FakeAccount(this.owner, this.data, {this.lamports = 1000000});

  final String owner;
  final List<int> data;
  final int lamports;

  Map<String, dynamic> toJson() => {
    'lamports': lamports,
    'owner': owner,
    'data': [base64Encode(data), 'base64'],
    'executable': false,
    'rentEpoch': 0,
    'space': data.length,
  };
}

/// A token account as getTokenAccountsByOwner returns it with jsonParsed.
class FakeTokenAccount {
  const FakeTokenAccount(
    this.mint, {
    this.amount = 1,
    this.decimals = 0,
    this.frozen = false,
    this.address,
  });

  final String mint;
  final int amount;
  final int decimals;
  final bool frozen;
  final String? address;

  Map<String, dynamic> toJson(String owner) => {
    'pubkey': address ?? ataAddress(owner, mint),
    'account': {
      'lamports': 2039280,
      'owner': tokenProgramId,
      'data': {
        'program': 'spl-token',
        'parsed': {
          'type': 'account',
          'info': {
            'isNative': false,
            'mint': mint,
            'owner': owner,
            'state': frozen ? 'frozen' : 'initialized',
            'tokenAmount': {
              'amount': '$amount',
              'decimals': decimals,
              'uiAmountString': '$amount',
            },
          },
        },
        'space': 165,
      },
      'executable': false,
      'rentEpoch': 0,
      'space': 165,
    },
  };
}

/// Mint account bytes with [supply].
List<int> mintWithSupply(int decimals, int supply) =>
    mintBytes(decimals)..setRange(36, 44, le(8, supply));

/// Token account bytes in [state] (1 initialized, 2 frozen).
List<int> tokenAccountWithState({
  required String mint,
  required String owner,
  required int amount,
  int state = 1,
}) =>
    tokenAccountBytes(mint: mint, owner: owner, amount: amount)..[108] = state;

/// A Token Metadata `MetadataV1` account, padded like the real ones
/// (fixed-width name, symbol and uri). [tokenStandard] null = None;
/// [legacy] stops after `is_mutable` like accounts from before editions.
List<int> metadataBytes({
  required String mint,
  String name = 'Boney #1',
  String symbol = 'BONE',
  String uri = 'https://example.com/1.json',
  int? tokenStandard = 0,
  bool legacy = false,
  int creators = 1,
}) {
  List<int> padded(String v, int width) {
    final b = utf8.encode(v);
    return [...le(4, width), ...b, ...List<int>.filled(width - b.length, 0)];
  }

  final bytes = [
    4, // Key::MetadataV1
    ...keyBytes(key(77)), // update_authority
    ...keyBytes(mint),
    ...padded(name, 32),
    ...padded(symbol, 10),
    ...padded(uri, 200),
    ...le(2, 500),
    if (creators == 0)
      0
    else ...[
      1,
      ...le(4, creators),
      for (var i = 0; i < creators; i++) ...[
        ...keyBytes(key(78 + i)),
        1,
        100 ~/ creators,
      ],
    ],
    1, // primary_sale_happened
    1, // is_mutable
  ];
  if (legacy) return bytes;
  return [
    ...bytes,
    1, 255, // edition_nonce Some(255)
    if (tokenStandard == null) 0 else ...[1, tokenStandard],
    0, // collection
    0, // uses
    0, // collection_details
    0, // programmable_config
    ...List<int>.filled(679 - bytes.length - 8, 0),
  ];
}

/// Minimal JSON-RPC server for the read paths the client uses.
class FakeRpc {
  FakeRpc._(this._server);

  static Future<FakeRpc> start() async {
    final rpc = FakeRpc._(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    );
    rpc._server.listen(rpc._handle);
    return rpc;
  }

  final HttpServer _server;
  final accounts = <String, FakeAccount>{};
  final calls = <String>[];

  /// Params of each getProgramAccounts call.
  final programScans = <List<dynamic>>[];

  /// Keys of each getMultipleAccounts call.
  final multiReads = <List<String>>[];

  /// Classic SPL Token accounts per wallet, answered by
  /// getTokenAccountsByOwner (jsonParsed).
  final tokenAccountsByOwner = <String, List<FakeTokenAccount>>{};

  /// Params of each getTokenAccountsByOwner call.
  final tokenAccountQueries = <List<dynamic>>[];

  /// Transactions passed to sendTransaction (wire bytes).
  final sent = <Uint8List>[];
  String blockhash = key(99);
  int rentExempt = 2000000;

  /// Requests to kill mid-flight, simulating Android dropping the socket
  /// while the wallet app is in front.
  int dropNext = 0;

  /// Requests answered with HTTP 429, like a rate-limited public RPC.
  int throttleNext = 0;

  /// sendTransaction calls answered with a BlockhashNotFound preflight error.
  int blockhashMisses = 0;

  Uri get url => Uri.parse('http://127.0.0.1:${_server.port}');

  SolanaClient client() => SolanaClient(
    rpcUrl: url,
    websocketUrl: Uri.parse('ws://127.0.0.1:${_server.port}'),
  );

  Future<void> close() => _server.close(force: true);

  Future<void> _handle(HttpRequest req) async {
    if (dropNext > 0) {
      dropNext--;
      (await req.response.detachSocket(writeHeaders: false)).destroy();
      return;
    }
    if (throttleNext > 0) {
      throttleNext--;
      await utf8.decoder.bind(req).join();
      req.response
        ..statusCode = 429
        ..write('Too many requests for a specific RPC call');
      await req.response.close();
      return;
    }
    final body = jsonDecode(await utf8.decoder.bind(req).join());
    final response = body is List
        ? [for (final r in body) _respond(r as Map)]
        : _respond(body as Map);
    req.response
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(response));
    await req.response.close();
  }

  Map<String, dynamic> _respond(Map req) {
    final method = req['method'] as String;
    final params = (req['params'] as List?) ?? const [];
    calls.add(method);
    const ctx = {'slot': 1};
    if (method == 'sendTransaction' && blockhashMisses > 0) {
      blockhashMisses--;
      return {
        'jsonrpc': '2.0',
        'id': req['id'],
        'error': {
          'code': -32002,
          'message': 'Transaction simulation failed: Blockhash not found',
          'data': {'err': 'BlockhashNotFound', 'logs': <String>[]},
        },
      };
    }
    final Object result = switch (method) {
      'getAccountInfo' => {
        'context': ctx,
        'value': accounts[params[0]]?.toJson(),
      },
      'getMultipleAccounts' => {
        'context': ctx,
        'value': [
          for (final a
              in (multiReads
                    ..add([for (final k in params[0] as List) k as String]))
                  .last)
            accounts[a]?.toJson(),
        ],
      },
      'getProgramAccounts' => _programAccounts(params),
      'getTokenAccountsByOwner' => {
        'context': ctx,
        'value': [
          for (final t
              in tokenAccountsByOwner[(tokenAccountQueries..add(params))
                      .last[0]] ??
                  const <FakeTokenAccount>[])
            t.toJson(params[0] as String),
        ],
      },
      'getBalance' => {
        'context': ctx,
        'value': accounts[params[0]]?.lamports ?? 0,
      },
      'getLatestBlockhash' => {
        'context': ctx,
        'value': {'blockhash': blockhash, 'lastValidBlockHeight': 100},
      },
      'getMinimumBalanceForRentExemption' => rentExempt,
      'sendTransaction' => _record(params[0] as String),
      'getSignatureStatuses' => {
        'context': ctx,
        'value': [
          for (final _ in params[0] as List)
            {
              'slot': 1,
              'confirmations': null,
              'err': null,
              'confirmationStatus': 'confirmed',
            },
        ],
      },
      _ => throw UnsupportedError(method),
    };
    return {'jsonrpc': '2.0', 'id': req['id'], 'result': result};
  }

  String _record(String base64Tx) {
    sent.add(base64Decode(base64Tx));
    return 'sig${calls.length}';
  }

  List<Map<String, dynamic>> _programAccounts(List<dynamic> params) {
    programScans.add(params);
    final config = params.length > 1 ? params[1] as Map : const {};
    final memcmps = [
      for (final f in (config['filters'] as List?) ?? const [])
        (f as Map)['memcmp'] as Map,
    ];
    bool matches(List<int> data) => memcmps.every((m) {
      final offset = m['offset'] as int;
      final bytes = base58decode(m['bytes'] as String);
      if (data.length < offset + bytes.length) return false;
      for (var i = 0; i < bytes.length; i++) {
        if (data[offset + i] != bytes[i]) return false;
      }
      return true;
    });
    return [
      for (final e in accounts.entries)
        if (e.value.owner == params[0] && matches(e.value.data))
          {'pubkey': e.key, 'account': e.value.toJson()},
    ];
  }
}
