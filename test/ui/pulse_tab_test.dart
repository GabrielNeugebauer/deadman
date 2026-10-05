import 'package:deadman/core/config.dart';
import 'package:deadman/solana/deadman_api.dart';
import 'package:deadman/state/assets.dart';
import 'package:deadman/state/providers.dart';
import 'package:deadman/ui/screens/pulse_tab.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../state/fakes.dart';

Future<void> _pump(
  WidgetTester tester,
  List<VaultState> plans, {
  Map<String, Map<String, int>> planTokens = const {},
  SubscriptionTerms? terms,
  AccountSubscription? sub,
}) async {
  tester.view.physicalSize = const Size(1200, 6000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues({'owner': addr(1)});
  final prefs = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        prefsProvider.overrideWithValue(prefs),
        vaultsProvider.overrideWith((ref) async => plans),
        guardAddressProvider.overrideWith((ref) async => addr(2)),
        planUsdcProvider.overrideWith((ref, address) async => 250000000),
        planTokenBalancesProvider.overrideWith((ref) async => planTokens),
        subscriptionTermsProvider.overrideWith((ref) async => terms),
        accountSubscriptionProvider.overrideWith((ref) async => sub),
        walletTokenProvider.overrideWith((ref, mint) async => 7000000),
        feesProvider.overrideWith(
          (ref) async => FeeSchedule(
            treasury: addr(9),
            feeBpsPublic: 200,
            feeBpsPrivate: 500,
          ),
        ),
      ],
      child: const MaterialApp(home: Scaffold(body: PulseTab())),
    ),
  );
  await tester.pump();
  await tester.pump();
}

/// Disposes the tab so its 1 s ticker stops.
Future<void> _unmount(WidgetTester tester) =>
    tester.pumpWidget(const SizedBox());

void main() {
  final start = DateTime.now().millisecondsSinceEpoch ~/ 1000 - 500;
  final vesting = vestingVault(
    planId: 1,
    guard: addr(2),
    startAt: start,
    withdrawableLamports: 2000000000,
    schedules: [
      schedule(mint: AppConfig.usdcMint, total: 1000000000, duration: 1000),
    ],
  );

  testWidgets('vesting plans are listed but not counted by the pulse', (
    tester,
  ) async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final inheritance = vault(
      planId: 0,
      label: 'Kids',
      guard: addr(2),
      lastPulse: now,
      ownerLastSeen: now,
    );
    await _pump(tester, [inheritance, vesting]);

    expect(find.text("I'm alive"), findsOneWidget);
    expect(find.text('plan'), findsOneWidget); // streak card: 1 plan
    expect(find.text('Kids'), findsOneWidget);
    expect(find.text('Vesting plans'), findsOneWidget);
    expect(find.text('VESTING'), findsOneWidget);
    expect(find.textContaining('250 USDC'), findsWidgets);
    expect(find.textContaining('Committed: 1000 USDC'), findsOneWidget);
    expect(find.textContaining(RegExp(r'^Release \d')), findsOneWidget);
    expect(find.text('Revoke'), findsOneWidget);
    await _unmount(tester);
  });

  testWidgets('a vesting-only owner has nothing to check in', (tester) async {
    await _pump(tester, [vesting]);
    expect(find.text('No plan to check in'), findsOneWidget);
    expect(find.text('Off'), findsOneWidget);
    expect(find.textContaining('Underfunded by 750 USDC'), findsOneWidget);
    await _unmount(tester);
  });

  testWidgets('New plan offers inheritance or vesting', (tester) async {
    await _pump(tester, [vesting]);
    await tester.tap(find.text('New plan'));
    await tester.pumpAndSettle();
    expect(find.text('Inheritance'), findsOneWidget);
    expect(find.text('Vesting'), findsOneWidget);
    await tester.tap(find.text('Vesting'));
    await tester.pumpAndSettle();
    expect(find.text('New vesting plan'), findsOneWidget);
    await _unmount(tester);
  });

  testWidgets('a plan without the asset of a pending tier warns and offers '
      'a deposit of that asset', (tester) async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final usdc = AppConfig.usdcMint;
    final kids = vault(
      planId: 0,
      label: 'Kids',
      guard: addr(2),
      lastPulse: now,
      ownerLastSeen: now,
      withdrawableLamports: 1000000000,
      rules: [
        rule(seed: 11),
        rule(seed: 12, mint: usdc),
      ],
    );
    await _pump(
      tester,
      [kids],
      planTokens: {
        kids.address: {usdc: 0},
      },
    );

    expect(find.text('No USDC in this plan'), findsOneWidget);
    expect(find.text('No SOL in this plan'), findsNothing);
    await tester.tap(find.text('Deposit USDC'));
    await tester.pumpAndSettle();
    expect(find.text('Deposit USDC'), findsWidgets);
    expect(find.text('7 USDC in your wallet'), findsOneWidget);
    expect(find.byType(SegmentedButton<AssetInfo>), findsNothing);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await _unmount(tester);
  });

  testWidgets('a funded plan shows no funding warning', (tester) async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final usdc = AppConfig.usdcMint;
    final kids = vault(
      planId: 0,
      guard: addr(2),
      lastPulse: now,
      ownerLastSeen: now,
      withdrawableLamports: 1000000000,
      rules: [
        rule(seed: 11),
        rule(seed: 12, mint: usdc),
      ],
    );
    await _pump(
      tester,
      [kids],
      planTokens: {
        kids.address: {usdc: 1},
      },
    );
    expect(find.textContaining('in this plan'), findsNothing);
    await _unmount(tester);
  });

  group('monthly plan', () {
    const terms = SubscriptionTerms(
      pricePerPeriod: 10000000,
      periodSecs: 30 * 86400,
      mint: AppConfig.usdcMint,
      minPeriods: 12,
    );

    testWidgets('each plan card shows the release fee; one account card '
        'offers the subscription', (tester) async {
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final kids = vault(guard: addr(2), lastPulse: now, ownerLastSeen: now);
      await _pump(tester, [kids, vesting], terms: terms);
      await tester.pump();
      expect(find.text('Release fee: 2% (5% private rails)'), findsNWidgets(2));
      expect(find.text('Switch to monthly'), findsNothing);
      expect(find.text('Not subscribed'), findsOneWidget);
      expect(find.text('Subscribe'), findsOneWidget);
      expect(find.text('Extend'), findsNothing);
      await _unmount(tester);
    });

    testWidgets('the account subscription covers every plan', (tester) async {
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final kids = vault(guard: addr(2), lastPulse: now, ownerLastSeen: now);
      final until = now + 86400 * 400;
      await _pump(
        tester,
        [kids, vesting],
        terms: terms,
        sub: AccountSubscription(owner: addr(1), paidUntil: until),
      );
      await tester.pump();
      expect(find.text('0% release fee · monthly plan'), findsNWidgets(2));
      expect(
        find.textContaining('Monthly plan · covers all your plans'),
        findsOneWidget,
      );
      expect(find.text('Extend'), findsOneWidget);
      await _unmount(tester);
    });

    testWidgets('not offered: no fee row on the cards', (tester) async {
      await _pump(tester, [vesting]);
      expect(find.textContaining('Release fee'), findsNothing);
      expect(find.text('Subscribe'), findsNothing);
      expect(find.textContaining('Monthly plan'), findsNothing);
      await _unmount(tester);
    });

    testWidgets('the intro mentions the monthly plan when offered', (
      tester,
    ) async {
      await _pump(tester, const [], terms: terms);
      expect(
        find.textContaining(
          'Or pay a flat 10 USDC a month for all your plans instead (12 months '
          'minimum).',
        ),
        findsOneWidget,
      );
      await _unmount(tester);
    });
  });
}
