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

Map<String, dynamic> loadIdl() =>
    jsonDecode(File('onchain/target/idl/deadman.json').readAsStringSync())
        as Map<String, dynamic>;

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
];

List<int> vaultBytes({
  required String owner,
  required String guard,
  String? guardian,
  int intervalSecs = 86400,
  int lockSecs = 3600,
  int lastPulse = 1790000000,
  int lockedUntil = 1790003600,
  int guardianReadyAt = 1790007200,
  int totalPulses = 42,
  int streak = 7,
  int bestStreak = 12,
  List<RuleState> rules = const [],
}) => [
  ...Disc.vaultAccount,
  ...keyBytes(owner),
  ...keyBytes(guard),
  if (guardian == null) 0 else ...[1, ...keyBytes(guardian)],
  ...le(8, intervalSecs),
  ...le(8, lockSecs),
  ...le(8, lastPulse),
  ...le(8, lockedUntil),
  ...le(8, guardianReadyAt),
  ...le(8, totalPulses),
  ...le(4, streak),
  ...le(4, bestStreak),
  ...le(4, rules.length),
  for (final r in rules) ...ruleStateBytes(r),
  254,
];

List<int> configBytes({
  required String admin,
  required String treasury,
  int feeBpsPublic = 200,
  int feeBpsPrivate = 500,
}) => [
  ...Disc.configAccount,
  ...keyBytes(admin),
  ...keyBytes(treasury),
  ...le(2, feeBpsPublic),
  ...le(2, feeBpsPrivate),
  253,
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
        'value': [for (final a in params[0] as List) accounts[a]?.toJson()],
      },
      'getProgramAccounts' => [
        for (final e in accounts.entries)
          if (e.value.owner == params[0])
            {'pubkey': e.key, 'account': e.value.toJson()},
      ],
      'getLatestBlockhash' => {
        'context': ctx,
        'value': {'blockhash': blockhash, 'lastValidBlockHeight': 100},
      },
      'getMinimumBalanceForRentExemption' => rentExempt,
      'sendTransaction' => 'sig${calls.length}',
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
}
