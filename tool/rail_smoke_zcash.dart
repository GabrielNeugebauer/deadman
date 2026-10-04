// Live smoke test of the Zcash rail against mainnet 1Click. Sends nothing:
// dry quotes, one real quote (reserves a deposit address that is never
// funded), status reads and read-only Solana RPC.
//
// dart run tool/rail_smoke_zcash.dart
//
// Env: RPC_URL (https://api.mainnet-beta.solana.com), ONECLICK_JWT (optional).
import 'dart:convert';
import 'dart:io';

import 'package:deadman/rails/rails.dart';
import 'package:deadman/rails/zcash_route.dart';
import 'package:http/http.dart' as http;
import 'package:solana/base58.dart';
import 'package:solana/solana.dart';

/// Orchard-only unified address from zcash-test-vectors
/// `test-vectors/json/unified_address.json` (ZIP 316; seed 0x00..1f,
/// account 9, diversifier 0). Its keys are public: never fund it.
const testU1 =
    'u1ddnjsdcpm36r6aq79n3s68shjweksnmwtdltrh046s8m6xcws9ygyawalxx8n6hg6vegk0wh8zjnafxgh6msppjsljvyt0ynece3lvm0';
const usdc = 'EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v';
const usdt = 'Es9vMFrzaCERmJfrF4H2FYD4KCoNkY11McCe8BenwNYB';

class _Counting extends http.BaseClient {
  final _inner = http.Client();
  int calls = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    calls++;
    return _inner.send(request);
  }
}

final _rows = <(String, bool, String)>[];

Future<void> check(String name, Future<String> Function() body) async {
  try {
    _rows.add((name, true, await body()));
  } on Object catch (e) {
    _rows.add((name, false, '$e'));
  }
}

void ensure(bool ok, String what) {
  if (!ok) throw StateError(what);
}

Future<void> main() async {
  final env = Platform.environment;
  final client = _Counting();
  final claim = (await Ed25519HDKeyPair.random()).address;
  final route = ZcashRoute(
    client: client,
    cluster: 'mainnet-beta',
    rpcUrl: env['RPC_URL'] ?? 'https://api.mainnet-beta.solana.com',
    apiKey: env['ONECLICK_JWT'] ?? '',
  );
  stdout.writeln('refundTo (fresh, unfunded claim key): $claim');
  stdout.writeln('recipient (ZIP 316 test vector): $testU1\n');

  await check('GET /v0/tokens: asset ids + decimals', () async {
    final res = await client.get(ZcashRoute.baseUrl.resolve('/v0/tokens'));
    ensure(res.statusCode == 200, 'HTTP ${res.statusCode}');
    final byId = {
      for (final t in jsonDecode(res.body) as List) (t as Map)['assetId']: t,
    };
    final expected = {
      for (final MapEntry(key: mint, value: i) in ZcashRoute.inputs.entries)
        i.assetId: (decimals: i.decimals, chain: 'sol', mint: mint),
      ZcashRoute.zecAssetId: (
        decimals: ZcashRoute.zecDecimals,
        chain: 'zec',
        mint: null,
      ),
    };
    final prices = <String>[];
    expected.forEach((id, want) {
      final t = byId[id];
      if (t == null) throw StateError('$id missing');
      ensure(t['decimals'] == want.decimals, '$id decimals ${t['decimals']}');
      ensure(t['blockchain'] == want.chain, '$id chain ${t['blockchain']}');
      ensure(
        want.mint == null || t['contractAddress'] == want.mint,
        '$id contract ${t['contractAddress']}',
      );
      prices.add('${t['symbol']} \$${t['price']}');
    });
    return '${byId.length} tokens; ${prices.join(', ')}';
  });

  await check('u1 validation (local, no network)', () async {
    final before = client.calls;
    final r = ZcashRoute.decodeUnifiedAddress(testU1);
    ensure(r == (orchard: true, sapling: false, transparent: false), '$r');
    for (final bad in [
      't1Rv4exT7bqhZqi2j7xz8bUHDMxwosrjADU',
      'zs1mrhc9y7jdh5r9ece8u5khgvj9kg0zgkxzdduyv0whkg7lkcrkx5xqem3e48avjq9wn2rukydkwn',
      '${testU1.substring(0, testU1.length - 1)}q',
    ]) {
      try {
        await route.estimate(
          claimKey: claim,
          inputMint: null,
          amount: 100000000,
          destination: bad,
        );
        throw StateError('accepted $bad');
      } on ZcashRouteException {
        // Expected.
      }
    }
    ensure(client.calls == before, 'made a network call');
    return 'Orchard-only u1 decodes; t1/zs/bad checksum rejected offline';
  });

  Future<RouteQuote> dry(String? mint, int amount, {ZcashRoute? via}) async {
    final q = await (via ?? route).estimate(
      claimKey: claim,
      inputMint: mint,
      amount: amount,
      destination: testU1,
    );
    ensure(q.depositAddress == null, 'dry quote has a deposit address');
    ensure(q.amountIn == amount, 'amountIn ${q.amountIn}');
    return q;
  }

  String describe(RouteQuote q) {
    final quote = (q.raw! as Map)['quote'] as Map;
    return '${quote['amountInFormatted']} -> ${q.estimatedOut} '
        '(min ${quote['minAmountOut']}, ~${quote['timeEstimate']}s), '
        'signature ok';
  }

  await check(
    'dry quote 0.1 SOL -> ZEC',
    () async => describe(await dry(null, 100000000)),
  );
  await check(
    'dry quote 5 USDC -> ZEC',
    () async => describe(await dry(usdc, 5000000)),
  );
  await check(
    'dry quote 5 USDT -> ZEC',
    () async => describe(await dry(usdt, 5000000)),
  );
  await check('dry quote with appFees (64-hex recipient)', () async {
    final hex = base58decode(claim)
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    final withFee = ZcashRoute(
      client: client,
      cluster: 'mainnet-beta',
      appFeeRecipient: hex,
    );
    final q = await dry(usdc, 5000000, via: withFee);
    final fees = ((q.raw! as Map)['quoteRequest'] as Map)['appFees'] as List;
    ensure(
      fees.any((f) => (f as Map)['recipient'] == hex),
      'appFees not echoed: $fees',
    );
    return '${describe(q)}; appFees echoed: '
        '${fees.map((f) => '${(f as Map)['fee']}bps').join(', ')}';
  });

  RouteQuote? real;
  await check('real quote 5 USDC -> ZEC (nothing deposited)', () async {
    final started = DateTime.now().toUtc();
    final q = await route.quote(
      claimKey: claim,
      inputMint: usdc,
      amount: 5000000,
      destination: testU1,
    );
    final res = q.raw! as Map;
    final req = res['quoteRequest'] as Map;
    final quote = res['quote'] as Map;
    ensure(await ZcashRoute.verifyQuoteSignature(res), 'signature');
    ensure(req['dry'] == false, 'dry echoed');
    ensure(req['refundTo'] == claim, 'refundTo');
    ensure(req['recipient'] == testU1, 'recipient');
    ensure(req['originAsset'] == ZcashRoute.inputs[usdc]!.assetId, 'origin');
    ensure(req['destinationAsset'] == ZcashRoute.zecAssetId, 'destination');
    ensure(req['amount'] == '5000000' && q.amountIn == 5000000, 'amount');
    final deposit = q.depositAddress!;
    ensure(base58decode(deposit).length == 32, 'deposit address');
    ensure(quote['depositAddress'] == deposit, 'deposit echoed');
    final window = q.expiresAt.difference(started);
    ensure(
      window > const Duration(minutes: 29) &&
          window <= const Duration(minutes: 31),
      'deadline $window',
    );
    final tampered = jsonDecode(jsonEncode(res)) as Map;
    (tampered['quote'] as Map)['depositAddress'] = claim;
    ensure(
      !await ZcashRoute.verifyQuoteSignature(tampered),
      'tampered quote verified',
    );
    real = q;
    return 'deposit $deposit, ${q.estimatedOut}, deadline '
        '${q.expiresAt.toIso8601String()}, inactive '
        '${quote['timeWhenInactive']}; signature ok, tamper rejected';
  });

  await check('GET /v0/status on the real quote', () async {
    final q = real;
    ensure(q != null, 'no real quote');
    final s = await route.status(q!.depositAddress!);
    ensure(s == 'PENDING_DEPOSIT', s);
    return s;
  });

  await check('track() first emission', () async {
    final q = real;
    ensure(q != null, 'no real quote');
    final s = await route.track(q!.depositAddress!).first;
    ensure(s == 'PENDING_DEPOSIT', s);
    return s;
  });

  await check(
    'spendable() on the unfunded claim key (read-only RPC)',
    () async {
      final sol = await route.spendable(claimKey: claim, inputMint: null);
      final usd = await route.spendable(claimKey: claim, inputMint: usdc);
      ensure(sol == 0 && usd == 0, 'sol $sol usdc $usd');
      return 'SOL 0, USDC 0';
    },
  );

  final width = _rows.map((r) => r.$1.length).reduce((a, b) => a > b ? a : b);
  for (final (name, ok, detail) in _rows) {
    stdout.writeln('${ok ? 'PASS' : 'FAIL'}  ${name.padRight(width)}  $detail');
  }
  final failed = _rows.where((r) => !r.$2).length;
  stdout.writeln('\n${_rows.length - failed}/${_rows.length} passed');
  exit(failed == 0 ? 0 : 1);
}
