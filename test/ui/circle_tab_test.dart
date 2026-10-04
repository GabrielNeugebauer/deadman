import 'package:deadman/core/config.dart';
import 'package:deadman/solana/deadman_api.dart';
import 'package:deadman/state/actions.dart';
import 'package:deadman/state/assets.dart';
import 'package:deadman/state/private_rails.dart';
import 'package:deadman/state/providers.dart';
import 'package:deadman/ui/format.dart';
import 'package:deadman/ui/screens/circle_tab.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../state/fakes.dart';

const usdc = AppConfig.usdcMint;

/// This wallet: the beneficiary of `rule(seed: 10)`.
final me = addr(10);

Future<FakeApi> _pump(
  WidgetTester tester,
  List<VaultState> watched, {
  Map<String, int> tokens = const {},
}) async {
  tester.view.physicalSize = const Size(1200, 4000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues({'owner': me});
  final prefs = await SharedPreferences.getInstance();
  final api = FakeApi(const [])..tokens.addAll(tokens);
  final zcash = FakeZcashRoute(live: false);
  final cloak = FakeCloakRoute(live: false);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        prefsProvider.overrideWithValue(prefs),
        apiProvider.overrideWithValue(api),
        secureStoreProvider.overrideWithValue(FakeSecureStore()),
        watchedVaultsProvider.overrideWith((ref) async => watched),
        zcashRouteProvider.overrideWithValue(zcash),
        cloakRouteProvider.overrideWith((ref) async => cloak),
        cloakStatusRouteProvider.overrideWithValue(cloak),
        privateRailsLiveProvider.overrideWithValue(false),
        biometricProvider.overrideWithValue((_) async => true),
        statusPollIntervalProvider.overrideWithValue(Duration.zero),
      ],
      child: const MaterialApp(home: Scaffold(body: CircleTab())),
    ),
  );
  await tester.pumpAndSettle();
  return api;
}

FilledButton _button(WidgetTester tester, String text) =>
    tester.widget<FilledButton>(find.widgetWithText(FilledButton, text));

void main() {
  // lastPulse 1000: every tier is long due and past its grace period.
  testWidgets('a due USDC tier the plan cannot pay: waiting for funds, no '
      'manual skip', (tester) async {
    final v = vault(rules: [rule(seed: 10, mint: usdc)]);
    final api = await _pump(tester, [v]);

    expect(_button(tester, 'Release this tier').onPressed, isNull);
    expect(
      find.text('Waiting for funds: this plan holds no USDC yet'),
      findsOneWidget,
    );
    expect(
      find.text(
        'Deadman skips it automatically after the grace period; '
        'its share stays reserved for you',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('Skip'), findsNothing);
    expect(find.byType(OutlinedButton), findsNothing);
    expect(api.balanceBatches.single, [(v.address, usdc)]);
  });

  testWidgets('a funded USDC tier can be released; no skip note', (
    tester,
  ) async {
    final v = vault(rules: [rule(seed: 10, mint: usdc)]);
    await _pump(tester, [v], tokens: {'${v.address}:$usdc': 5000000});

    expect(_button(tester, 'Release this tier').onPressed, isNotNull);
    expect(find.textContaining('Waiting for funds'), findsNothing);
    expect(find.textContaining('skips it automatically'), findsNothing);
  });

  testWidgets('an empty SOL plan waits for SOL; one batched lookup for '
      'several plans', (tester) async {
    final empty = vault(planId: 0, rules: [rule(seed: 10)]);
    final circle = vault(
      planId: 1,
      withdrawableLamports: 1000000000,
      rules: [rule(seed: 10, mint: circleDevnetUsdcMint)],
    );
    final api = await _pump(tester, [empty, circle]);

    expect(
      find.text('Waiting for funds: this plan holds no SOL yet'),
      findsOneWidget,
    );
    expect(
      find.text('Waiting for funds: this plan holds no USDC (Circle) yet'),
      findsOneWidget,
    );
    expect(api.balanceBatches.single, [(circle.address, circleDevnetUsdcMint)]);
  });

  testWidgets('a blocking tier of someone else: the keeper skips it, its '
      'share stays theirs', (tester) async {
    final other = addr(11);
    final v = vault(
      rules: [
        rule(seed: 11, mint: usdc),
        rule(seed: 10, mint: usdc, afterSecs: 20 * 86400),
      ],
    );
    await _pump(tester, [v]);

    expect(find.text('Release this tier'), findsNothing);
    expect(
      find.text(
        'Tier 1 could not pay and holds yours back. Deadman skips it '
        'automatically after the grace period; its share stays reserved '
        'for ${short(other)}',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('Skip'), findsNothing);
  });

  testWidgets('vesting: nothing to claim from an empty plan', (tester) async {
    final v = vestingVault(schedules: [schedule(seed: 10, mint: usdc)]);
    await _pump(tester, [v]);

    final claim = find.byWidgetPredicate(
      (w) =>
          w is FilledButton &&
          w.child is Text &&
          (w.child! as Text).data!.startsWith('Claim vested'),
    );
    expect(tester.widget<FilledButton>(claim).onPressed, isNull);
    expect(
      find.text('Waiting for funds: this plan holds no USDC yet'),
      findsOneWidget,
    );
  });
}
