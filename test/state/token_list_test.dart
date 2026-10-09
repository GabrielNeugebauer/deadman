import 'dart:convert';

import 'package:deadman/core/config.dart';
import 'package:deadman/state/assets.dart';
import 'package:deadman/state/token_list.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const classic = 'TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA';
const t22 = 'TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb';

Map<String, dynamic> token(
  String id,
  String symbol, {
  String program = classic,
  bool verified = true,
  bool sus = false,
  String? icon = 'https://img.example/x.png',
  int decimals = 6,
}) => {
  'id': id,
  'symbol': symbol,
  'name': '$symbol token',
  'decimals': decimals,
  'tokenProgram': program,
  'icon': icon,
  'isVerified': verified,
  'audit': {'isSus': sus},
  'organicScoreLabel': 'high',
};

String mint(int i) => '${'M' * 39}${String.fromCharCode(65 + i)}${'k' * 4}';

void main() {
  tearDown(forgetTokens);

  test('parses Jupiter tokens and drops wrapped SOL', () async {
    Uri? asked;
    final api = JupiterTokens(
      base: Uri.parse('https://jup.test/tokens/v2'),
      client: MockClient((req) async {
        asked = req.url;
        return http.Response(
          jsonEncode([
            token(wrappedSolMint, 'SOL'),
            token(mint(1), 'JUP'),
            token(mint(2), 'PUMP', program: t22, icon: 'http://insecure/x.png'),
            {'id': mint(3)}, // no decimals: skipped
          ]),
          200,
        );
      }),
    );
    final list = await api.search('ju p');
    expect(asked.toString(), 'https://jup.test/tokens/v2/search?query=ju+p');
    expect(list.map((t) => t.symbol), ['JUP', 'PUMP']);
    expect(list[0].supported, isTrue);
    expect(list[1].supported, isFalse);
    expect(list[1].unsupportedReason, contains('Token-2022'));
    expect(list[1].icon, isNull, reason: 'only https icons');

    await api.top();
    expect(
      asked.toString(),
      'https://jup.test/tokens/v2/toporganicscore/24h?limit=100',
    );
  });

  test('HTTP errors throw', () {
    final api = JupiterTokens(
      client: MockClient((_) async => http.Response('nope', 429)),
    );
    expect(api.top(), throwsA(isA<http.ClientException>()));
  });

  test('picker order: supported and verified first', () {
    final sorted = sortForPicker([
      ListedToken.fromJson(token(mint(1), 'A', program: t22)),
      ListedToken.fromJson(token(mint(2), 'B', verified: false)),
      ListedToken.fromJson(token(mint(3), 'C')),
      ListedToken.fromJson(token(mint(4), 'D', sus: true)),
      ListedToken.fromJson(token(mint(5), 'E')),
    ]);
    expect(sorted.map((t) => t.symbol), ['C', 'E', 'B', 'D', 'A']);
  });

  test('a lookalike symbol never reads as the real token', () {
    expect(isLookalike(mint(1), 'usdc'), isTrue);
    expect(isLookalike(AppConfig.usdcMint, 'USDC'), isFalse);
    expect(isLookalike(mint(1), 'JUP'), isFalse);

    final fake = rememberToken(mint(1), 'USDC', 6);
    expect(fake.symbol, 'USDC·${mint(1).substring(0, 4)}');
    expect(assetSymbol(mint(1)), isNot('USDC'));
    expect(knownAsset(AppConfig.usdcMint)!.symbol, 'USDC');
  });

  test('picked tokens read in whole units and survive a restart', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    expect(knownAsset(mint(1)), isNull);
    expect(parseAmount('1.5', mint(1)), isNull, reason: 'base units only');

    rememberListedToken(
      prefs,
      ListedToken.fromJson(token(mint(1), 'JUP', decimals: 6)),
    );
    rememberListedToken(
      prefs,
      ListedToken.fromJson(token(mint(2), 'BONK', decimals: 5)),
    );
    expect(parseAmount('1.5', mint(1)), 1500000);
    expect(amountText(1500000, mint(1)), '1.5 JUP');

    forgetTokens();
    expect(knownAsset(mint(1)), isNull);
    restoreListedTokens(prefs);
    expect(assetSymbol(mint(1)), 'JUP');
    expect(assetInfo(mint(2)).decimals, 5);
  });

  test('a corrupt saved list is dropped', () async {
    SharedPreferences.setMockInitialValues({'listed_tokens_v1': '{oops'});
    final prefs = await SharedPreferences.getInstance();
    restoreListedTokens(prefs);
    expect(prefs.getString('listed_tokens_v1'), isNull);
  });
}
