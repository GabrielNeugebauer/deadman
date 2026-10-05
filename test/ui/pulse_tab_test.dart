import 'package:deadman/core/config.dart';
import 'package:deadman/solana/deadman_api.dart';
import 'package:deadman/state/providers.dart';
import 'package:deadman/ui/format.dart';
import 'package:deadman/ui/screens/plans_screen.dart';
import 'package:deadman/ui/screens/pulse_tab.dart';
import 'package:deadman/ui/theme.dart';
import 'package:deadman/ui/widgets/brand/brand.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../state/fakes.dart';

/// A phone's body area under the status bar, above the navigation bar.
const _phone = Size(393, 760);

Future<void> _pump(
  WidgetTester tester,
  List<VaultState> plans, {
  SubscriptionTerms? terms,
  bool duress = false,
  List<int> legacy = const [],
  String guard = '',
  Size size = _phone,
}) async {
  tester.view.physicalSize = size;
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
        guardAddressProvider.overrideWith(
          (ref) async => guard.isEmpty ? addr(2) : guard,
        ),
        planUsdcProvider.overrideWith((ref, address) async => 250000000),
        planTokenBalancesProvider.overrideWith((ref) async => const {}),
        subscriptionTermsProvider.overrideWith((ref) async => terms),
        accountSubscriptionProvider.overrideWith((ref) async => null),
        feesProvider.overrideWith(
          (ref) async => FeeSchedule(
            treasury: addr(9),
            feeBpsPublic: 200,
            feeBpsPrivate: 300,
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

String? _countdown(WidgetTester tester) =>
    tester.widget<Text>(find.byKey(const Key('pulse-countdown'))).data;

double _ringDiameter(WidgetTester tester) =>
    tester.widget<RingScope>(find.byType(RingScope)).diameter;

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

  VaultState kids(int now, {required int silentFor, List<RuleState>? rules}) =>
      vault(
        planId: 0,
        label: 'Kids',
        guard: addr(2),
        lastPulse: now - silentFor,
        ownerLastSeen: now,
        rules: rules,
      );

  group('pulse ring', () {
    testWidgets('alive: pulse ring, Check in, and nothing else', (
      tester,
    ) async {
      final now = _nowSecs();
      await _pump(tester, [kids(now, silentFor: 0), vesting]);
      expect(find.text('ALIVE'), findsOneWidget);
      expect(find.text('until tier 1 releases'), findsOneWidget);
      expect(find.text('Kids'), findsOneWidget); // plan under the countdown
      expect(_countdownColor(tester), DM.pulse);
      expect(find.text('Check in'), findsOneWidget);
      expect(_dmIcon(DMIcons.fingerprint), findsOneWidget);
      // The streak and the plan list are gone from Pulse.
      for (final gone in ['DAY STREAK', 'BEST', 'PLAN', 'Release plans']) {
        expect(find.text(gone), findsNothing);
      }
      expect(find.byKey(const Key('new-plan')), findsNothing);
      expect(find.text('Deposit'), findsNothing);
      expect(find.byType(DMCard), findsNothing);
      await _unmount(tester);
    });

    testWidgets('days of silence stay alive while the tier counts down', (
      tester,
    ) async {
      final now = _nowSecs();
      await _pump(tester, [kids(now, silentFor: 8 * 86400)]);
      expect(find.text('ALIVE'), findsOneWidget);
      expect(find.text('MISSED'), findsNothing);
      expect(find.text('until tier 1 releases'), findsOneWidget);
      expect(_countdown(tester), anyOf('2d 0h', '1d 23h'));
      expect(_countdownColor(tester), DM.pulse);
      expect(find.text('Check in'), findsOneWidget);
      final ring = tester.widget<SegmentedRing>(find.byType(SegmentedRing));
      expect(ring.status, DMStatus.alive);
      expect(ring.progress, closeTo(0.2, 0.01)); // 2 of 10 days left
      await _unmount(tester);
    });

    testWidgets('the ring follows the earliest release across plans', (
      tester,
    ) async {
      final now = _nowSecs();
      final early = vault(
        planId: 1,
        label: 'Savings',
        guard: addr(2),
        lastPulse: now,
        ownerLastSeen: now,
        rules: [rule(afterSecs: 3 * 86400)],
      );
      await _pump(tester, [kids(now, silentFor: 0), early]);
      expect(find.text('Savings'), findsOneWidget);
      expect(find.text('until tier 1 releases'), findsOneWidget);
      expect(_countdown(tester), anyOf('3d 0h', '2d 23h'));
      final ring = tester.widget<SegmentedRing>(find.byType(SegmentedRing));
      expect(ring.progress, closeTo(1, 0.01));
      await _unmount(tester);
    });

    testWidgets('a due tier: flatline ring, releasing-to address, and '
        'Check in to stop', (tester) async {
      final now = _nowSecs();
      await _pump(tester, [kids(now, silentFor: 11 * 86400)]);
      expect(find.text('TIER DUE'), findsOneWidget);
      expect(find.text('past due, releasing to'), findsOneWidget);
      expect(find.text(short(addr(10))), findsOneWidget);
      expect(_countdownColor(tester), DM.flatline);
      expect(find.text('Check in to stop'), findsOneWidget);
      // The ring blinks once a second instead of counting.
      final ring = tester.widget<SegmentedRing>(find.byType(SegmentedRing));
      expect(ring.status, DMStatus.due);
      expect(ring.phase, closeTo(now, 2));
      // The plans button shows the tombstone while a tier is due.
      expect(
        find.descendant(
          of: find.byKey(const Key('open-plans')),
          matching: find.byWidgetPredicate(
            (w) => w is PixelArt && w.sprite == PixelSprites.tombstone,
          ),
        ),
        findsOneWidget,
      );
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
      await _unmount(tester);
    });

    testWidgets('a vesting-only owner has nothing to check in', (tester) async {
      await _pump(tester, [vesting]);
      expect(find.text('NOT ARMED'), findsOneWidget);
      expect(find.text('Off'), findsOneWidget);
      expect(find.text('No plan to check in'), findsOneWidget);
      expect(find.text('Build a release plan'), findsOneWidget);
      await _unmount(tester);
    });
  });

  group('layout', () {
    testWidgets('the ring fills the width of a phone, with Check in under '
        'it and nothing below', (tester) async {
      final now = _nowSecs();
      await _pump(tester, [kids(now, silentFor: 0)]);
      expect(_ringDiameter(tester), _phone.width - 2 * DMSpace.gutter);
      final ring = tester.getRect(find.byType(SegmentedRing));
      final button = tester.getRect(find.byKey(const Key('check-in')));
      expect(button.top, greaterThanOrEqualTo(ring.bottom));
      expect(button.bottom, lessThanOrEqualTo(_phone.height));
      expect(_phone.height - button.bottom, lessThan(40));
      await _unmount(tester);
    });

    testWidgets('on a short, wide window the ring sizes from the height', (
      tester,
    ) async {
      final now = _nowSecs();
      await _pump(tester, [
        kids(now, silentFor: 0),
      ], size: const Size(900, 600));
      final d = _ringDiameter(tester);
      expect(d, lessThan(600 - 56 - 64));
      expect(d, greaterThan(300));
      expect(tester.takeException(), isNull);
      await _unmount(tester);
    });

    testWidgets('too short for the ring: the page scrolls instead of '
        'overflowing', (tester) async {
      final now = _nowSecs();
      await _pump(tester, [
        kids(now, silentFor: 0),
      ], size: const Size(640, 320));
      expect(tester.takeException(), isNull);
      expect(_ringDiameter(tester), greaterThan(200));
      await _unmount(tester);
    });
  });

  group('app bar', () {
    testWidgets('the plans button counts every plan and opens the Plans '
        'screen; Back returns to Pulse', (tester) async {
      final now = _nowSecs();
      await _pump(tester, [kids(now, silentFor: 0), vesting]);
      expect(find.bySemanticsLabel('Release plans, 2'), findsOneWidget);

      await tester.tap(find.byKey(const Key('open-plans')));
      await tester.pumpAndSettle();
      expect(find.byType(PlansScreen), findsOneWidget);
      expect(find.text('Release plans'), findsOneWidget);
      expect(find.text('Vesting plans'), findsOneWidget);
      expect(find.byKey(const Key('new-plan')), findsOneWidget);

      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(PlansScreen), findsNothing);
      expect(find.text('Check in'), findsOneWidget);
      await _unmount(tester);
    });

    testWidgets('the skull button explains the three moods', (tester) async {
      final now = _nowSecs();
      await _pump(tester, [kids(now, silentFor: 0)]);
      await tester.tap(find.byKey(const Key('skull-button')));
      await tester.pumpAndSettle();
      expect(find.text('One skull, three moods'), findsOneWidget);
      for (final mood in [
        'Alive',
        'Silent past a release tier',
        'Plan fully released',
      ]) {
        expect(find.text(mood), findsOneWidget);
      }
      expect(find.text('Missed a check-in'), findsNothing);
      expect(
        find.descendant(
          of: find.byType(BottomSheet),
          matching: find.byType(PixelSkull),
        ),
        findsNWidgets(3),
      );
      expect(find.text('CHECK IN, OR CHECK OUT.'), findsOneWidget);
      await _unmount(tester);
    });

    testWidgets('lockdown shows a LOCKED sticker, hidden under duress', (
      tester,
    ) async {
      final now = _nowSecs();
      final plan = vault(guard: addr(2), lastPulse: now, ownerLastSeen: now);
      final locked = VaultState(
        address: plan.address,
        owner: plan.owner,
        planId: plan.planId,
        label: plan.label,
        guard: plan.guard,
        guardian: plan.guardian,
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
      await _unmount(tester);

      await _pump(tester, [locked], duress: true);
      expect(find.text('LOCKED'), findsNothing);
      await _unmount(tester);
    });
  });

  testWidgets('a plan guarded by another device offers to move the guard', (
    tester,
  ) async {
    final now = _nowSecs();
    await _pump(tester, [kids(now, silentFor: 0)], guard: addr(7));
    expect(
      find.textContaining('1 plan is guarded by another device'),
      findsOne,
    );
    expect(find.text('Move guard to this phone'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _unmount(tester);
  });

  group('no plans', () {
    testWidgets('the arm-switch intro lists rails with their fee', (
      tester,
    ) async {
      await _pump(tester, const [], size: const Size(393, 2000));
      expect(find.text('Arm your switch'), findsOneWidget);
      for (final rail in ['Solana', 'Cloak', 'Zcash']) {
        expect(find.text(rail), findsOneWidget);
      }
      expect(find.text('2%'), findsOneWidget);
      expect(find.text('3%'), findsNWidgets(2));
      expect(find.text('5%'), findsNothing);
      expect(find.text('Build release plan'), findsOneWidget);
      expect(
        find.text(
          'No subscription. Deadman only charges when a tier releases funds.',
        ),
        findsOneWidget,
      );
      expect(find.text('CHECK IN, OR CHECK OUT.'), findsOneWidget);
      await _unmount(tester);
    });

    testWidgets('older-version plans are listed under the title', (
      tester,
    ) async {
      await _pump(
        tester,
        const [],
        legacy: const [7, 8],
        size: const Size(393, 2000),
      );
      expect(
        tester.getTopLeft(find.text('2 plans from an older version')).dy,
        greaterThan(tester.getBottomLeft(find.text('Arm your switch')).dy),
      );
      expect(find.text('Recover SOL'), findsOneWidget);
      await _unmount(tester);
    });

    testWidgets('with plans, older-version plans wait on the Plans screen', (
      tester,
    ) async {
      final now = _nowSecs();
      await _pump(tester, [kids(now, silentFor: 0)], legacy: const [7]);
      expect(find.text('1 plan from an older version'), findsNothing);
      await _unmount(tester);
    });

    testWidgets('the intro mentions the monthly plan when offered', (
      tester,
    ) async {
      await _pump(
        tester,
        const [],
        size: const Size(393, 2000),
        terms: const SubscriptionTerms(
          pricePerPeriod: 10000000,
          periodSecs: 30 * 86400,
          mint: AppConfig.usdcMint,
          minPeriods: 12,
        ),
      );
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

Finder _dmIcon(DMIcons icon) =>
    find.byWidgetPredicate((w) => w is DMIcon && w.icon == icon);
