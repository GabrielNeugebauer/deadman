import 'package:deadman/core/config.dart';
import 'package:deadman/state/fee_settings.dart';
import 'package:deadman/state/providers.dart';
import 'package:deadman/ui/screens/settings_tab.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../state/fakes.dart';

Future<(FakeApi, SharedPreferences)> _pump(
  WidgetTester tester, {
  required bool paymaster,
  Map<String, Object> saved = const {},
}) async {
  SharedPreferences.setMockInitialValues(saved);
  final prefs = await SharedPreferences.getInstance();
  final api = FakeApi(const []);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        prefsProvider.overrideWithValue(prefs),
        apiProvider.overrideWithValue(api),
        paymasterAvailableProvider.overrideWithValue(paymaster),
        walletBalanceProvider.overrideWith((ref) async => 1500000000),
        walletUsdcProvider.overrideWith((ref) async => 42000000),
      ],
      child: const MaterialApp(
        home: Scaffold(body: SingleChildScrollView(child: NetworkFeesCard())),
      ),
    ),
  );
  await tester.pump();
  return (api, prefs);
}

void main() {
  testWidgets('choosing USDC saves it and sets the fee token', (tester) async {
    final (api, prefs) = await _pump(tester, paymaster: true);
    expect(find.textContaining('42 USDC'), findsOneWidget);
    expect(api.feeToken, isNull);

    await tester.tap(find.text('USDC'));
    await tester.pumpAndSettle();
    expect(api.feeToken, AppConfig.usdcMint);
    expect(prefs.getString(FeeSettings.key), 'usdc');

    await tester.tap(find.text('SOL'));
    await tester.pumpAndSettle();
    expect(api.feeToken, isNull);
  });

  testWidgets('the saved choice is applied when first read', (tester) async {
    final (api, _) = await _pump(
      tester,
      paymaster: true,
      saved: {FeeSettings.key: 'usdc'},
    );
    expect(api.feeToken, AppConfig.usdcMint);
  });

  testWidgets('USDC is unavailable without a paymaster', (tester) async {
    final (api, prefs) = await _pump(
      tester,
      paymaster: false,
      saved: {FeeSettings.key: 'usdc'},
    );
    expect(api.feeToken, isNull);
    expect(find.textContaining('needs a Kora'), findsOneWidget);
    await tester.tap(find.text('USDC'));
    await tester.pumpAndSettle();
    expect(api.feeToken, isNull);
  });
}
