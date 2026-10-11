import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../core/config.dart';
import '../solana/codec.dart' show PythFeedIds, nativeMint;
import 'assets.dart' show jitoSolMint;

/// USD prices of plan assets, for sizing an SKR fee reserve: Pyth's Hermes
/// first (the feeds the program reads on chain), Jupiter's price API for
/// assets Hermes does not answer for. Estimates only: the program prices
/// each payout itself, from the on-chain feeds, when it runs.
class UsdPrices {
  UsdPrices({http.Client? client, Uri? hermes, Uri? jupiter, this.clock})
    : _client = client ?? http.Client(),
      _hermes =
          hermes ??
          Uri.parse(
            const String.fromEnvironment(
              'HERMES_URL',
              defaultValue: 'https://hermes.pyth.network',
            ),
          ),
      _jupiter =
          jupiter ??
          Uri.parse(
            const String.fromEnvironment(
              'JUP_PRICE_URL',
              defaultValue: 'https://lite-api.jup.ag/price/v3',
            ),
          );

  final http.Client _client;
  final Uri _hermes;
  final Uri _jupiter;

  /// Unix seconds; null = the system clock.
  final int Function()? clock;

  static const timeout = Duration(seconds: 8);

  /// A Hermes price older than this is ignored (Jupiter answers instead).
  static const maxAgeSecs = 600;

  /// The Pyth feed of each asset that has one (null = SOL), whatever the
  /// cluster: devnet test mints stand for the real tokens.
  static const feedIds = <String?, String>{
    null: PythFeedIds.solUsd,
    AppConfig.usdcMint: PythFeedIds.usdcUsd,
    AppConfig.skrMint: PythFeedIds.skrUsd,
    AppConfig.oreMint: PythFeedIds.oreUsd,
    jitoSolMint: PythFeedIds.jitoSolUsd,
  };

  /// The mainnet mint Jupiter knows each asset by.
  static const _mainnetMints = <String?, String>{
    null: nativeMint,
    AppConfig.usdcMint: 'EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v',
    AppConfig.skrMint: 'SKRbvo6Gf7GondiT3BbTfuRDPqLWei4j2Qy2NPGZhW3',
    AppConfig.oreMint: 'oreoU2P8bN6jkk3jbaiVxYnG1dCXcYxwhwyK9jSybcp',
  };

  int _now() => clock?.call() ?? DateTime.now().millisecondsSinceEpoch ~/ 1000;

  /// USD per whole unit of each of [mints] (null = SOL) that could be
  /// priced; the others are left out.
  Future<Map<String?, double>> fetch(Iterable<String?> mints) async {
    final wanted = mints.toSet();
    final out = <String?, double>{};
    final byFeed = {for (final m in wanted) ?feedIds[m]: m};
    if (byFeed.isNotEmpty) {
      try {
        final got = await _fromHermes(byFeed.keys);
        for (final MapEntry(key: id, value: usd) in got.entries) {
          if (byFeed.containsKey(id)) out[byFeed[id]] = usd;
        }
      } on Object {
        // Jupiter below.
      }
    }
    final rest = wanted.where((m) => !out.containsKey(m)).toList();
    if (rest.isNotEmpty) {
      try {
        out.addAll(await _fromJupiter(rest));
      } on Object {
        // Unpriced: left out.
      }
    }
    return out;
  }

  /// Feed id -> USD from Hermes' latest parsed prices.
  Future<Map<String, double>> _fromHermes(Iterable<String> ids) async {
    final uri = _hermes.replace(
      path: '${_hermes.path}/v2/updates/price/latest',
      queryParameters: {
        'ids[]': ids.toList(),
        'parsed': 'true',
        'encoding': 'hex',
      },
    );
    final res = await _client.get(uri).timeout(timeout);
    if (res.statusCode != 200) {
      throw http.ClientException('Hermes: HTTP ${res.statusCode}', uri);
    }
    final parsed = (jsonDecode(res.body) as Map)['parsed'];
    final now = _now();
    final out = <String, double>{};
    for (final p in parsed is List ? parsed : const []) {
      if (p is! Map || p['price'] is! Map) continue;
      final price = p['price'] as Map;
      final raw = int.tryParse('${price['price']}');
      final expo = price['expo'];
      final at = price['publish_time'];
      if (raw == null || raw <= 0 || expo is! int || at is! int) continue;
      if (now - at > maxAgeSecs) continue;
      final id = '${p['id']}'.replaceFirst('0x', '');
      out[id] = raw * _pow10(expo);
    }
    return out;
  }

  /// Asset -> USD from Jupiter's price API.
  Future<Map<String?, double>> _fromJupiter(List<String?> mints) async {
    final ids = {for (final m in mints) m: _mainnetMints[m] ?? m!};
    final uri = _jupiter.replace(
      queryParameters: {'ids': ids.values.toSet().join(',')},
    );
    final res = await _client.get(uri).timeout(timeout);
    if (res.statusCode != 200) {
      throw http.ClientException('Jupiter: HTTP ${res.statusCode}', uri);
    }
    final body = jsonDecode(res.body);
    if (body is! Map) return const {};
    return {
      for (final MapEntry(key: m, value: id) in ids.entries)
        if (body[id] case {'usdPrice': final num usd} when usd > 0)
          m: usd.toDouble(),
    };
  }

  static double _pow10(int e) {
    var v = 1.0;
    for (var i = 0; i < e.abs(); i++) {
      v *= 10;
    }
    return e < 0 ? 1 / v : v;
  }
}

final usdPricesServiceProvider = Provider((ref) => UsdPrices());

/// USD prices of the assets named by [key], a comma-separated, sorted list
/// of mints ('' = SOL; see [priceKey]). Errors resolve to no prices.
final usdPricesProvider = FutureProvider.autoDispose
    .family<Map<String?, double>, String>(
      (ref, key) => ref.watch(usdPricesServiceProvider).fetch([
        for (final m in key.split(',')) m.isEmpty ? null : m,
      ]),
    );

/// The [usdPricesProvider] key for [mints] (null = SOL).
String priceKey(Iterable<String?> mints) =>
    ({for (final m in mints) m ?? ''}.toList()..sort()).join(',');
