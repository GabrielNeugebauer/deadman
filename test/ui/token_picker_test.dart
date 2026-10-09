import 'dart:convert';

import 'package:deadman/state/assets.dart';
import 'package:deadman/state/providers.dart';
import 'package:deadman/state/token_list.dart';
import 'package:deadman/ui/theme.dart';
import 'package:deadman/ui/widgets/editor/asset_chips.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const classic = 'TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA';
const t22 = 'TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb';
final jup = '${'J' * 40}upZZ';
final fakeUsdc = '${'F' * 40}akeU';
final pump = '${'P' * 40}umpZ';
const unlisted = '7xKXtg2CW87d97TXJSDpbD5jBkheTqA83TZRuJosgAsU';

Map<String, dynamic> token(
  String id,
  String symbol, {
  String program = classic,
  bool verified = true,
}) => {
  'id': id,
  'symbol': symbol,
  'name': '$symbol name',
  'decimals': 6,
  'tokenProgram': program,
  'icon': null,
  'isVerified': verified,
  'organicScoreLabel': 'high',
};

void main() {
  late List<String> queries;
  late String? picked;

  tearDown(forgetTokens);

  Future<void> open(WidgetTester tester) async {
    queries = [];
    picked = null;
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final api = JupiterTokens(
      base: Uri.parse('https://jup.test/tokens/v2'),
      client: MockClient((req) async {
        queries.add(req.url.path.split('/').last);
        final q = req.url.queryParameters['query'];
        final all = [
          token(jup, 'JUP'),
          token(fakeUsdc, 'USDC', verified: false),
          token(pump, 'PUMP', program: t22),
        ];
        final hits = q == null
            ? all
            : all.where((t) => '$t'.toLowerCase().contains(q.toLowerCase()));
        return http.Response(jsonEncode(hits.toList()), 200);
      }),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          prefsProvider.overrideWithValue(prefs),
          jupiterTokensProvider.overrideWithValue(api),
        ],
        child: MaterialApp(
          theme: buildTheme(),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async => picked = await askMint(context),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('lists top tokens and picks a verified one', (tester) async {
    await open(tester);
    expect(queries, ['24h']);
    expect(find.text('JUP'), findsOneWidget);
    expect(find.text('Token-2022: not supported yet'), findsOneWidget);

    // Token-2022 rows do nothing.
    await tester.tap(find.text('PUMP'));
    await tester.pumpAndSettle();
    expect(picked, isNull);
    expect(find.text('Other token'), findsOneWidget);

    await tester.tap(find.text('JUP'));
    await tester.pumpAndSettle();
    expect(picked, jup);
    expect(assetSymbol(jup), 'JUP');
    expect(parseAmount('2', jup), 2000000);
  });

  testWidgets('a lookalike needs confirming and keeps a mint tag', (
    tester,
  ) async {
    await open(tester);
    expect(find.text('LOOKALIKE'), findsOneWidget);
    await tester.tap(find.text('USDC'));
    await tester.pumpAndSettle();
    expect(find.textContaining('This is not the USDC Deadman uses'), findsOne);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(picked, isNull);

    await tester.tap(find.text('USDC'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Use it'));
    await tester.pumpAndSettle();
    expect(picked, fakeUsdc);
    expect(assetSymbol(fakeUsdc), 'USDC·FFFF');
  });

  testWidgets('searches, and takes a pasted unlisted mint', (tester) async {
    await open(tester);
    await tester.enterText(find.byKey(const ValueKey('token-search')), 'jup');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(queries.last, 'search');
    expect(find.text('JUP'), findsOneWidget);
    expect(find.text('PUMP'), findsNothing);

    await tester.enterText(
      find.byKey(const ValueKey('token-search')),
      unlisted,
    );
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('token-pasted')));
    await tester.pumpAndSettle();
    expect(picked, unlisted);
    expect(knownAsset(unlisted), isNull, reason: 'stays in base units');
  });
}
