import 'package:deadman/core/config.dart';
import 'package:deadman/solana/deadman_api.dart';
import 'package:deadman/state/assets.dart';
import 'package:deadman/state/providers.dart';
import 'package:deadman/ui/format.dart';
import 'package:deadman/ui/screens/pulse_tab.dart';
import 'package:deadman/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../state/fakes.dart';
import '../state/installment_fakes.dart';

Future<void> _pump(
  WidgetTester tester,
  List<VaultState> plans, {
  Map<String, Map<String, int>> planTokens = const {},
  SubscriptionTerms? terms,
  AccountSubscription? sub,
  bool duress = false,
  List<int> legacy = const [],
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
        legacyPlansProvider.overrideWith((ref) async => legacy),
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
      child: MaterialApp(
        theme: buildTheme(),
        home: const Scaffold(body: PulseTab()),
      ),
    ),
  );
  if (duress) {
    ProviderScope.containerOf(tester.element(find.byType(PulseTab)))
        .read(sessionProvider.notifier)
        .unlock(duress: true);
  }
  await tester.pump();
  await tester.pump();
}

int _nowSecs() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

Color? _countdownColor(WidgetTester tester) =>
    tester.widget<Text>(find.byKey(const Key('pulse-countdown'))).style?.color;

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

    expect(find.text('Check in'), findsOneWidget);
    expect(find.text('PLAN'), findsOneWidget); // stat tiles: 1 plan
    expect(find.text('Kids'), findsOneWidget);
    expect(find.text('Vesting plans'), findsOneWidget);
    expect(find.text('VESTING'), findsOneWidget);
    expect(find.textContaining('250 USDC'), findsWidgets);
    expect(find.textContaining('Committed: 1000 USDC'), findsOneWidget);
    expect(find.textContaining(RegExp(r'^Release \d')), findsOneWidget);
    expect(find.text('Revoke'), findsOneWidget);
    await _unmount(tester);
  });

  testWidgets('installments: progress, next date, Release only when due', (
    tester,
  ) async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    VaultState plan(int released) => withPeriod(
      vestingVault(
        planId: 1,
        guard: addr(2),
        startAt: now - 150,
        withdrawableLamports: 2000000000,
        schedules: [schedule(duration: 600, released: released)],
      ),
      60,
    );
    await _pump(tester, [plan(200000000)]);
    expect(find.text('2 of 10 installments unlocked'), findsOneWidget);
    expect(find.textContaining('Next installment: 0.100 SOL on '), findsOne);
    expect(find.textContaining(RegExp(r'^Release \d')), findsNothing);
    await _unmount(tester);

    await _pump(tester, [plan(0)]);
    expect(find.text('Release 0.200 SOL'), findsOneWidget);
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

    expect(find.text('NO USDC IN THIS PLAN'), findsOneWidget);
    expect(find.text('NO SOL IN THIS PLAN'), findsNothing);
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
    expect(find.textContaining('IN THIS PLAN'), findsNothing);
    await _unmount(tester);
  });

  group('pulse ring', () {
    VaultState kids(
      int now, {
      required int silentFor,
      List<RuleState>? rules,
    }) => vault(
      planId: 0,
      label: 'Kids',
      guard: addr(2),
      lastPulse: now - silentFor,
      ownerLastSeen: now,
      rules: rules,
    );

    testWidgets('on track: signal ring, Check in, stat tiles, tier chip', (
      tester,
    ) async {
      final now = _nowSecs();
      await _pump(tester, [kids(now, silentFor: 0)]);
      expect(find.text('ON TRACK'), findsOneWidget);
      expect(find.text('until next check-in'), findsOneWidget);
      expect(_countdownColor(tester), DM.signal);
      expect(find.text('Check in'), findsOneWidget);
      expect(find.byIcon(Icons.fingerprint), findsOneWidget);
      for (final label in ['DAY STREAK', 'BEST', 'PLAN']) {
        expect(find.text(label), findsOneWidget);
      }
      expect(find.text('Release plans'), findsOneWidget);
      expect(find.byKey(const Key('new-plan')), findsOneWidget);
      // A calm plan carries no header chip, only its tier countdown.
      expect(find.textContaining(RegExp(r'^IN \d+D')), findsOneWidget);
      expect(find.text('After 10d 0h silent'), findsOneWidget);
      expect(find.text('Solana'), findsOneWidget); // rail tag
      expect(find.text('Deposit'), findsOneWidget);
      expect(find.text('Withdraw'), findsOneWidget);
      expect(find.text('Earn · mainnet'), findsOneWidget);
      await _unmount(tester);
    });

    testWidgets('the last quarter of the window asks for a check-in soon', (
      tester,
    ) async {
      final now = _nowSecs();
      await _pump(tester, [kids(now, silentFor: 6 * 86400 + 43200)]);
      expect(find.text('CHECK IN SOON'), findsOneWidget);
      expect(_countdownColor(tester), DM.attention);
      expect(find.text('Check in'), findsOneWidget);
      await _unmount(tester);
    });

    testWidgets('past the check-in: attention ring counts to the tier', (
      tester,
    ) async {
      final now = _nowSecs();
      await _pump(tester, [kids(now, silentFor: 8 * 86400)]);
      expect(find.text('CHECK-IN OVERDUE'), findsOneWidget);
      expect(find.text('until tier 1 releases'), findsOneWidget);
      expect(_countdownColor(tester), DM.attention);
      expect(find.textContaining('TIER IN '), findsOneWidget);
      await _unmount(tester);
    });

    testWidgets('a due tier: dashed due ring and Check in to stop', (
      tester,
    ) async {
      final now = _nowSecs();
      await _pump(tester, [kids(now, silentFor: 11 * 86400)]);
      expect(find.text('TIER DUE'), findsOneWidget);
      expect(
        find.text('past due, releasing to ${short(addr(10))}'),
        findsOneWidget,
      );
      expect(_countdownColor(tester), DM.due);
      expect(find.text('Check in to stop'), findsOneWidget);
      // Plan header and the tier itself.
      expect(find.text('DUE NOW'), findsNWidgets(2));
      await _unmount(tester);
    });

    testWidgets('released tiers stay as history with a grey chip', (
      tester,
    ) async {
      final now = _nowSecs();
      await _pump(tester, [
        kids(
          now,
          silentFor: 0,
          rules: [
            rule(executedAt: now - 7200),
            rule(seed: 11),
          ],
        ),
      ]);
      expect(find.text('1/2 RELEASED'), findsOneWidget);
      expect(find.text('RELEASED'), findsOneWidget);
      expect(find.textContaining('Released 2h 0m ago'), findsOneWidget);
      await _unmount(tester);
    });

    testWidgets('every plan released: nothing to check in', (tester) async {
      final now = _nowSecs();
      await _pump(tester, [
        kids(now, silentFor: 0, rules: [rule(executedAt: now - 60)]),
      ]);
      expect(find.text('ALL RELEASED'), findsOneWidget);
      expect(find.text('Done'), findsOneWidget);
      expect(find.text('All plans released'), findsOneWidget);
      expect(find.text('Start again'), findsOneWidget);
      await _unmount(tester);
    });
  });

  testWidgets('older-version plans are listed under the page title', (
    tester,
  ) async {
    final now = _nowSecs();
    await _pump(
      tester,
      [vault(guard: addr(2), lastPulse: now, ownerLastSeen: now)],
      legacy: const [7],
    );
    final card = find.text('1 plan from an older version');
    expect(card, findsOneWidget);
    expect(
      tester.getTopLeft(card).dy,
      greaterThan(tester.getBottomLeft(find.text('Pulse').first).dy),
    );
    expect(find.text('Recover SOL'), findsOneWidget);
    await _unmount(tester);

    await _pump(tester, const [], legacy: const [7, 8]);
    expect(
      tester.getTopLeft(find.text('2 plans from an older version')).dy,
      greaterThan(tester.getBottomLeft(find.text('Arm your switch')).dy),
    );
    await _unmount(tester);
  });

  testWidgets('no plans: the arm-switch intro lists rails with their fee', (
    tester,
  ) async {
    await _pump(tester, const []);
    expect(find.text('Arm your switch'), findsOneWidget);
    for (final rail in ['Solana', 'Cloak', 'Zcash']) {
      expect(find.text(rail), findsOneWidget);
    }
    expect(find.text('2%'), findsOneWidget);
    expect(find.text('5%'), findsNWidgets(2));
    expect(find.text('Build release plan'), findsOneWidget);
    expect(
      find.text(
        'No subscription. Deadman only charges when a tier releases funds.',
      ),
      findsOneWidget,
    );
    await _unmount(tester);
  });

  testWidgets('Deposit asks for SOL or USDC and rejects zero', (tester) async {
    final now = _nowSecs();
    await _pump(tester, [
      vault(guard: addr(2), lastPulse: now, ownerLastSeen: now),
    ]);
    await tester.tap(find.text('Deposit'));
    await tester.pumpAndSettle();
    expect(find.byType(SegmentedButton<AssetInfo>), findsOneWidget);
    await tester.enterText(find.byType(TextField), '0');
    await tester.tap(find.text('Confirm'));
    await tester.pump();
    expect(find.text('Enter an amount in SOL'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await _unmount(tester);
  });

  testWidgets('under duress the lock stays hidden', (tester) async {
    final now = _nowSecs();
    final plan = vault(guard: addr(2), lastPulse: now, ownerLastSeen: now);
    final locked = VaultState(
      address: plan.address,
      owner: plan.owner,
      planId: plan.planId,
      label: plan.label,
      guard: plan.guard,
      guardian: plan.guardian,
      intervalSecs: plan.intervalSecs,
      lockSecs: plan.lockSecs,
      skipGraceSecs: plan.skipGraceSecs,
      lastPulse: plan.lastPulse,
      ownerLastSeen: plan.ownerLastSeen,
      lockedUntil: now + 3600,
      guardianReadyAt: 0,
      totalPulses: 1,
      streak: 1,
      bestStreak: 1,
      rules: plan.rules,
      lamports: 0,
      withdrawableLamports: 0,
    );
    await _pump(tester, [locked]);
    expect(find.text('LOCKED'), findsOneWidget);
    expect(find.textContaining('Locked down for'), findsOneWidget);
    await _unmount(tester);

    await _pump(tester, [locked], duress: true);
    expect(find.text('LOCKED'), findsNothing);
    expect(find.textContaining('Locked down for'), findsNothing);
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
