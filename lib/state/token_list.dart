import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../solana/codec.dart' show tokenProgramId;
import 'assets.dart';
import 'providers.dart';

const wrappedSolMint = 'So11111111111111111111111111111111111111112';

/// A token from Jupiter's Tokens API (V2), mainnet mints only.
class ListedToken {
  const ListedToken({
    required this.mint,
    required this.symbol,
    required this.name,
    required this.decimals,
    required this.tokenProgram,
    this.icon,
    this.verified = false,
    this.suspicious = false,
    this.organicScore = '',
  });

  factory ListedToken.fromJson(Map<String, dynamic> j) {
    final icon = j['icon'];
    return ListedToken(
      mint: j['id'] as String,
      symbol: (j['symbol'] as String? ?? '').trim(),
      name: (j['name'] as String? ?? '').trim(),
      decimals: (j['decimals'] as num).toInt(),
      tokenProgram: j['tokenProgram'] as String? ?? '',
      // Only https images; anything else shows the placeholder.
      icon: icon is String && icon.startsWith('https://') ? icon : null,
      verified: j['isVerified'] == true,
      suspicious: (j['audit'] as Map?)?['isSus'] == true,
      organicScore: j['organicScoreLabel'] as String? ?? '',
    );
  }

  final String mint;
  final String symbol;
  final String name;
  final int decimals;
  final String tokenProgram;
  final String? icon;
  final bool verified;

  /// Flagged by Jupiter's audit (`audit.isSus`).
  final bool suspicious;

  /// Jupiter's organic score label: "high", "medium", "low".
  final String organicScore;

  /// Classic SPL token: the only kind plans can hold today.
  bool get supported => tokenProgram == tokenProgramId;

  bool get lookalike => isLookalike(mint, symbol);

  /// Verified by Jupiter and not flagged by its audit.
  bool get trusted => verified && !suspicious;

  /// Why it can't go into a plan; null when it can.
  String? get unsupportedReason =>
      supported ? null : 'Token-2022: not supported yet';

  Map<String, dynamic> toJson() => {
    'id': mint,
    'symbol': symbol,
    'name': name,
    'decimals': decimals,
    'tokenProgram': tokenProgram,
    'icon': icon,
    'isVerified': verified,
    'audit': {'isSus': suspicious},
    'organicScoreLabel': organicScore,
  };
}

/// Jupiter's keyless token list. [base] is overridable with
/// `--dart-define=JUP_TOKENS_URL=...`.
class JupiterTokens {
  JupiterTokens({http.Client? client, Uri? base})
    : _client = client ?? http.Client(),
      _base =
          base ??
          Uri.parse(
            const String.fromEnvironment(
              'JUP_TOKENS_URL',
              defaultValue: 'https://lite-api.jup.ag/tokens/v2',
            ),
          );

  final http.Client _client;
  final Uri _base;

  Future<List<ListedToken>> _get(String path, Map<String, String> query) async {
    final uri = _base.replace(
      path: '${_base.path}/$path',
      queryParameters: query.isEmpty ? null : query,
    );
    final res = await _client
        .get(uri, headers: const {'accept': 'application/json'})
        .timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) {
      throw http.ClientException('Token list: HTTP ${res.statusCode}', uri);
    }
    final body = jsonDecode(res.body);
    if (body is! List) return const [];
    return [
      for (final j in body)
        if (j is Map<String, dynamic> &&
            j['id'] is String &&
            j['decimals'] is num)
          ListedToken.fromJson(j),
    ].where((t) => t.mint != wrappedSolMint).toList();
  }

  /// Most traded tokens by organic score over 24 h.
  Future<List<ListedToken>> top() =>
      _get('toporganicscore/24h', {'limit': '100'});

  /// By symbol, name or mint address.
  Future<List<ListedToken>> search(String query) =>
      _get('search', {'query': query});
}

final jupiterTokensProvider = Provider((ref) => JupiterTokens());

/// The picker's starting list: supported tokens first, then by organic
/// score order (Jupiter's).
final topTokensProvider = FutureProvider<List<ListedToken>>(
  (ref) async => sortForPicker(await ref.watch(jupiterTokensProvider).top()),
);

/// Search results for [query] (2+ characters), sorted like
/// [topTokensProvider].
final tokenSearchProvider = FutureProvider.family<List<ListedToken>, String>(
  (ref, query) async =>
      sortForPicker(await ref.watch(jupiterTokensProvider).search(query)),
);

/// Supported first, then verified, keeping Jupiter's order within each.
List<ListedToken> sortForPicker(List<ListedToken> tokens) {
  int rank(ListedToken t) =>
      (t.supported ? 0 : 2) + (t.verified && !t.suspicious ? 0 : 1);
  final indexed = tokens.indexed.toList()
    ..sort((a, b) {
      final r = rank(a.$2).compareTo(rank(b.$2));
      return r != 0 ? r : a.$1.compareTo(b.$1);
    });
  return [for (final (_, t) in indexed) t];
}

const _prefsKey = 'listed_tokens_v1';

/// Restores the tokens picked so far (see [rememberListedToken]).
void restoreListedTokens(SharedPreferences prefs) {
  final raw = prefs.getString(_prefsKey);
  if (raw == null) return;
  try {
    for (final j in (jsonDecode(raw) as List).cast<Map<String, dynamic>>()) {
      final t = ListedToken.fromJson(j);
      rememberToken(
        t.mint,
        t.symbol,
        t.decimals,
        imageUrl: t.icon,
        tagged: !t.trusted,
      );
    }
  } on Object {
    prefs.remove(_prefsKey);
  }
}

/// Names [token] for the rest of the app, now and after restarts. An
/// unverified or flagged token keeps a piece of its mint in its symbol, so
/// a plan funded with it never reads as a known token.
AssetInfo rememberListedToken(SharedPreferences prefs, ListedToken token) {
  final info = rememberToken(
    token.mint,
    token.symbol,
    token.decimals,
    imageUrl: token.icon,
    tagged: !token.trusted,
  );
  final saved = <String, Map<String, dynamic>>{};
  try {
    final raw = prefs.getString(_prefsKey);
    if (raw != null) {
      for (final j in (jsonDecode(raw) as List).cast<Map<String, dynamic>>()) {
        saved[j['id'] as String] = j;
      }
    }
  } on Object {
    // A corrupt entry is rewritten below.
  }
  saved[token.mint] = token.toJson();
  prefs.setString(_prefsKey, jsonEncode(saved.values.toList()));
  return info;
}

/// The listed token with this exact [mint]; null when Jupiter doesn't list
/// it (or can't be reached). Remembers it, so plan amounts in it read in
/// whole units.
final listedTokenProvider = FutureProvider.family<ListedToken?, String>((
  ref,
  mint,
) async {
  try {
    final found = await ref.watch(jupiterTokensProvider).search(mint);
    for (final t in found) {
      if (t.mint == mint && t.supported) {
        rememberListedToken(ref.read(prefsProvider), t);
        return t;
      }
    }
  } on Object {
    // Unlisted or offline: the mint keeps showing in base units.
  }
  return null;
});
