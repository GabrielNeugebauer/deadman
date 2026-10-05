import 'dart:typed_data';

import 'package:deadman/core/config.dart';
import 'package:deadman/solana/deadman_api.dart';
import 'package:deadman/state/assets.dart';
import 'package:deadman/state/providers.dart';
import 'package:deadman/ui/screens/plans/plan_card_shell.dart';
import 'package:deadman/ui/screens/plans_screen.dart';
import 'package:deadman/ui/theme.dart';
import 'package:deadman/ui/widgets/brand/brand.dart';
import 'package:deadman/wallet/wallet_bridge.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../state/fakes.dart';
import '../state/installment_fakes.dart';

/// Records the plans closed and revoked through the owner's wallet.
class _PlansApi extends FakeApi {
  _PlansApi() : super(const []);

  final closed = <int>[];
  final revoked = <int>[];

  @override
  Future<Uint8List> buildCloseVault({
    required String owner,
    required int planId,
  }) async {
    closed.add(planId);
    return Uint8List(0);
  }

  @override
  Future<Uint8List> buildRevokeVesting({
    required String owner,
    required int planId,
  }) async {
    revoked.add(planId);
    return Uint8List(0);
  }

  @override
  Future<List<String>> sendSigned(List<Uint8List> signed) async => ['sig'];
}

class _EchoWallet implements WalletBridge {
  @override
  Future<WalletSession> authorize() => throw UnimplementedError();

  @override
  Future<List<Uint8List>> signTransactions(List<Uint8List> txs) async => txs;

  @override
  Future<void> deauthorize(String authToken) async {}
}

Future<_PlansApi> _pump(
  WidgetTester tester,
  List<VaultState> plans, {
  Map<String, Map<String, int>> planTokens = const {},
  SubscriptionTerms? terms,
  AccountSubscription? sub,
  bool duress = false,
  List<int> legacy = const [],
  String guard = '',
}) async {
  tester.view.physicalSize = const Size(1200, 6000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues({'owner': addr(1)});
  final prefs = await SharedPreferences.getInstance();
  final api = _PlansApi();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        prefsProvider.overrideWithValue(prefs),
        apiProvider.overrideWithValue(api),
        walletProvider.overrideWithValue(_EchoWallet()),
        vaultsProvider.overrideWith((ref) async => plans),
        legacyPlansProvider.overrideWith((ref) async => legacy),
        guardAddressProvider.overrideWith(
          (ref) async => guard.isEmpty ? addr(2) : guard,
        ),
        planUsdcProvider.overrideWith((ref, address) async => 250000000),
        planTokenBalancesProvider.overrideWith((ref) async => planTokens),
        subscriptionTermsProvider.overrideWith((ref) async => terms),
        accountSubscriptionProvider.overrideWith((ref) async => sub),
        walletTokenProvider.overrideWith((ref, mint) async => 7000000),
        feesProvider.overrideWith(
          (ref) async => FeeSchedule(
            treasury: addr(9),
            feeBpsPublic: 200,
            feeBpsPrivate: 300,
          ),
        ),
      ],
      child: MaterialApp(theme: buildTheme(), home: const PlansScreen()),
    ),
  );
  if (duress) {
    ProviderScope.containerOf(tester.element(find.byType(PlansScreen)))
        .read(sessionProvider.notifier)
        .unlock(duress: true);
  }
  await tester.pump();
  await tester.pump();
  return api;
}

/// Opens every collapsed plan card (not the Released section).
Future<void> _expandAll(WidgetTester tester) async {
  final headers = find.byWidgetPredicate(
    (w) =>
        w is ExpandToggle &&
        !w.open &&
        w.key is ValueKey<String> &&
        (w.key! as ValueKey<String>).value.startsWith('plan-'),
  );
  while (headers.evaluate().isNotEmpty) {
    await tester.tap(headers.first);
    await tester.pumpAndSettle();
  }
}

Future<void> _tapText(WidgetTester tester, String text) async {
  await tester.ensureVisible(find.text(text).last);
  await tester.tap(find.text(text).last);
  await tester.pumpAndSettle();
}

int _nowSecs() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

/// Disposes the screen so its 1 s ticker stops.
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

  testWidgets('release plans first, then vesting plans', (tester) async {
    final now = _nowSecs();
    await _pump(tester, [kids(now, silentFor: 0), vesting]);
    await _expandAll(tester);

    expect(find.text('Release plans'), findsOneWidget); // app bar
    expect(find.byKey(const Key('new-plan')), findsOneWidget);
    expect(find.text('Kids'), findsOneWidget);
    expect(find.text('Vesting plans'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('Vesting plans')).dy,
      greaterThan(tester.getTopLeft(find.text('Kids')).dy),
    );
    expect(find.text('VESTING'), findsOneWidget);
    expect(find.textContaining('250 USDC'), findsWidgets);
    expect(find.textContaining('Committed: 1000 USDC'), findsOneWidget);
    expect(find.textContaining(RegExp(r'^Release \d')), findsOneWidget);
    expect(find.text('Cancel plan'), findsNWidgets(2));
    // No streak anywhere.
    expect(
      find.textContaining(RegExp('streak', caseSensitive: false)),
      findsNothing,
    );
    await _unmount(tester);
  });

  testWidgets('installments: progress, next date, Release only when due', (
    tester,
  ) async {
    final now = _nowSecs();
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
    expect(
      find.textContaining(RegExp(r'^Next installment 0.100 SOL in \d')),
      findsOneWidget,
      reason: 'the collapsed header names the next installment',
    );
    await _expandAll(tester);
    expect(find.text('2 of 10 installments unlocked'), findsOneWidget);
    expect(find.textContaining('Next installment: 0.100 SOL on '), findsOne);
    expect(find.textContaining(RegExp(r'^Release \d')), findsNothing);
    await _unmount(tester);

    await _pump(tester, [plan(0)]);
    expect(find.text('Ready to release'), findsOneWidget);
    await _expandAll(tester);
    expect(find.text('Release 0.200 SOL'), findsOneWidget);
    await _unmount(tester);
  });

  testWidgets('an underfunded vesting plan says by how much', (tester) async {
    await _pump(tester, [vesting]);
    await _expandAll(tester);
    expect(find.textContaining('Underfunded by 750 USDC'), findsOneWidget);
    await _unmount(tester);
  });

  testWidgets('New plan is a full-width button at the top of the list, '
      'not in the app bar', (tester) async {
    final now = _nowSecs();
    await _pump(tester, [kids(now, silentFor: 0)]);
    final button = find.byKey(const Key('new-plan'));
    expect(
      find.descendant(of: find.byType(AppBar), matching: button),
      findsNothing,
    );
    expect(tester.widget(button), isA<FilledButton>());
    expect(
      find.descendant(
        of: button,
        matching: find.byWidgetPredicate(
          (w) => w is DMIcon && w.icon == DMIcons.plus,
        ),
      ),
      findsOneWidget,
    );
    expect(
      tester.getSize(button).width,
      tester.getSize(find.byType(ListView)).width - 2 * DMSpace.gutter,
    );
    expect(
      tester.getTopLeft(button).dy,
      lessThan(tester.getTopLeft(find.text('Kids')).dy),
    );
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

  testWidgets('no plans left: an empty state with a way to start one', (
    tester,
  ) async {
    await _pump(tester, const []);
    expect(find.text('No plans yet'), findsOneWidget);
    expect(
      find.byWidgetPredicate((w) => w is DMIcon && w.icon == DMIcons.heartbeat),
      findsOneWidget,
    );
    expect(find.text('New plan'), findsOneWidget);
    expect(find.text('Released · 0'), findsNothing);
    await _unmount(tester);
  });

  testWidgets('a plan without the asset of a pending tier warns and offers '
      'a deposit of that asset', (tester) async {
    final now = _nowSecs();
    final usdc = AppConfig.usdcMint;
    final plan = vault(
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
      [plan],
      planTokens: {
        plan.address: {usdc: 0},
      },
    );
    await _expandAll(tester);

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
    final now = _nowSecs();
    final usdc = AppConfig.usdcMint;
    final plan = vault(
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
      [plan],
      planTokens: {
        plan.address: {usdc: 1},
      },
    );
    await _expandAll(tester);
    expect(find.textContaining('in this plan'), findsNothing);
    await _unmount(tester);
  });

  group('plan card', () {
    testWidgets('alive: no header sticker, the tier counts down in mono', (
      tester,
    ) async {
      final now = _nowSecs();
      await _pump(tester, [kids(now, silentFor: 0)]);
      expect(find.byType(StatusSticker), findsNothing);
      final next = find.textContaining(RegExp(r'^Tier 1 in \d+d'));
      expect(tester.widget<Text>(next).style?.color, DM.pulse);
      await _expandAll(tester);
      final countdown = find.textContaining(RegExp(r'^in \d+d'));
      expect(countdown, findsOneWidget);
      expect(tester.widget<Text>(countdown).style?.color, DM.pulse);
      expect(find.text('10d 0h after last check-in'), findsOneWidget);
      expect(find.textContaining('check in every'), findsNothing);
      expect(find.text('Solana'), findsOneWidget); // rail tag
      expect(find.text('Deposit'), findsOneWidget);
      expect(find.text('Withdraw'), findsOneWidget);
      expect(find.text('Edit'), findsOneWidget);
      expect(find.text('Cancel plan'), findsOneWidget);
      expect(find.text('Earn · mainnet'), findsOneWidget);
      await _unmount(tester);
    });

    testWidgets('days of silence: still no sticker, the countdown stays '
        'pulse', (tester) async {
      final now = _nowSecs();
      await _pump(tester, [kids(now, silentFor: 8 * 86400)]);
      expect(find.text('MISSED'), findsNothing);
      expect(find.byType(StatusSticker), findsNothing);
      final next = find.textContaining(RegExp(r'^Tier 1 in [12]d'));
      expect(tester.widget<Text>(next).style?.color, DM.pulse);
      await _expandAll(tester);
      final countdown = find.textContaining(RegExp(r'^in [12]d'));
      expect(tester.widget<Text>(countdown).style?.color, DM.pulse);
      await _unmount(tester);
    });

    testWidgets('a due tier: TIER DUE on the plan, DUE NOW and the '
        'tombstone on the tier', (tester) async {
      final now = _nowSecs();
      await _pump(tester, [kids(now, silentFor: 11 * 86400)]);
      expect(find.text('TIER DUE'), findsOneWidget);
      expect(find.text('Tier 1 due now'), findsOneWidget);
      await _expandAll(tester);
      expect(find.text('DUE NOW'), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (w) => w is PixelArt && w.sprite == PixelSprites.tombstone,
        ),
        findsOneWidget,
      );
      await _unmount(tester);
    });

    testWidgets('released tiers stay as history', (tester) async {
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
      expect(find.text('Released · 1'), findsNothing, reason: 'still active');
      await _expandAll(tester);
      expect(find.text('1/2 RELEASED'), findsOneWidget);
      expect(find.text('RELEASED'), findsOneWidget);
      expect(find.textContaining('Released 2h 0m ago'), findsOneWidget);
      expect(find.text('Edit'), findsOneWidget, reason: 'pending tiers edit');
      await _unmount(tester);
    });

    testWidgets('fully released: the ghost, read-only, no Start again', (
      tester,
    ) async {
      final now = _nowSecs();
      await _pump(tester, [
        kids(now, silentFor: 0, rules: [rule(executedAt: now - 60)]),
      ]);
      await tester.tap(find.byKey(const Key('released-section')));
      await tester.pumpAndSettle();
      await _expandAll(tester);
      expect(
        find.byWidgetPredicate(
          (w) => w is PixelArt && w.sprite == PixelSprites.ghost,
        ),
        findsOneWidget,
      );
      expect(
        find.textContaining(RegExp(r'^All tiers released 1m \ds ago')),
        findsOneWidget,
      );
      expect(find.textContaining('check in every'), findsNothing);
      for (final gone in [
        'Start again',
        'Edit',
        'Deposit',
        'Cancel plan',
        'Earn · mainnet',
      ]) {
        expect(find.text(gone), findsNothing, reason: gone);
      }
      expect(find.text('Withdraw leftovers'), findsOneWidget);
      expect(find.text('Close plan'), findsOneWidget);
      await _unmount(tester);
    });

    testWidgets('guarded by another device is noted on the card', (
      tester,
    ) async {
      final now = _nowSecs();
      await _pump(tester, [kids(now, silentFor: 0)], guard: addr(7));
      await _expandAll(tester);
      expect(find.text('Guarded by another device'), findsOneWidget);
      await _unmount(tester);
    });
  });

  testWidgets('older-version plans are listed first', (tester) async {
    final now = _nowSecs();
    await _pump(tester, [kids(now, silentFor: 0)], legacy: const [7]);
    final card = find.text('1 plan from an older version');
    expect(card, findsOneWidget);
    expect(
      tester.getTopLeft(card).dy,
      lessThan(tester.getTopLeft(find.text('Kids')).dy),
    );
    expect(find.text('Recover SOL'), findsOneWidget);
    await _unmount(tester);
  });

  testWidgets('Deposit asks for SOL or USDC and rejects zero', (tester) async {
    final now = _nowSecs();
    await _pump(tester, [
      vault(guard: addr(2), lastPulse: now, ownerLastSeen: now),
    ]);
    await _expandAll(tester);
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
    expect(find.text('LOCKED'), findsOneWidget, reason: 'header sticker');
    await _expandAll(tester);
    expect(find.textContaining('Locked down for'), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (w) => w is PixelArt && w.sprite == PixelSprites.lock,
      ),
      findsNWidgets(2),
    );
    await _unmount(tester);

    await _pump(tester, [locked], duress: true);
    await _expandAll(tester);
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
      final now = _nowSecs();
      final plan = vault(guard: addr(2), lastPulse: now, ownerLastSeen: now);
      await _pump(tester, [plan, vesting], terms: terms);
      await tester.pump();
      await _expandAll(tester);
      expect(find.text('Release fee: 2% (3% private rails)'), findsNWidgets(2));
      expect(find.textContaining('5%'), findsNothing);
      expect(find.text('Switch to monthly'), findsNothing);
      expect(find.text('Not subscribed'), findsOneWidget);
      expect(find.text('Subscribe'), findsOneWidget);
      expect(find.text('Extend'), findsNothing);
      await _unmount(tester);
    });

    testWidgets('the account subscription covers every plan', (tester) async {
      final now = _nowSecs();
      final plan = vault(guard: addr(2), lastPulse: now, ownerLastSeen: now);
      final until = now + 86400 * 400;
      await _pump(
        tester,
        [plan, vesting],
        terms: terms,
        sub: AccountSubscription(owner: addr(1), paidUntil: until),
      );
      await tester.pump();
      await _expandAll(tester);
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
      await _expandAll(tester);
      expect(find.textContaining('Release fee'), findsNothing);
      expect(find.text('Subscribe'), findsNothing);
      expect(find.textContaining('Monthly plan'), findsNothing);
      await _unmount(tester);
    });
  });

  group('collapsed cards', () {
    testWidgets('start collapsed; the header opens and closes one card', (
      tester,
    ) async {
      final now = _nowSecs();
      await _pump(tester, [
        kids(now, silentFor: 0),
        vault(
          planId: 3,
          label: 'Spouse',
          guard: addr(2),
          lastPulse: now,
          ownerLastSeen: now,
        ),
      ]);
      final semantics = tester.ensureSemantics();
      final header = find.byKey(ValueKey('plan-${addr(100)}'));
      expect(find.text('Deposit'), findsNothing);
      expect(find.text('0.000 SOL · 250 USDC protected'), findsNWidgets(2));
      expect(find.textContaining(RegExp(r'^Tier 1 in ')), findsNWidgets(2));
      expect(tester.getSize(header).height, greaterThanOrEqualTo(48));
      expect(
        tester.getSemantics(header),
        isSemantics(isButton: true, hasExpandedState: true, isExpanded: false),
      );

      await tester.tap(header);
      await tester.pumpAndSettle();
      expect(find.text('Deposit'), findsOneWidget, reason: 'only Kids');
      expect(
        tester.getSemantics(header),
        isSemantics(hasExpandedState: true, isExpanded: true),
      );

      await tester.tap(header);
      await tester.pumpAndSettle();
      expect(find.text('Deposit'), findsNothing);
      semantics.dispose();
      await _unmount(tester);
    });
  });

  group('released plans', () {
    testWidgets('group under a collapsed Released section at the bottom; '
        'their cards are read-only', (tester) async {
      final now = _nowSecs();
      final done = vault(
        planId: 3,
        label: 'Done',
        guard: addr(2),
        lastPulse: now,
        ownerLastSeen: now,
        withdrawableLamports: 5000000,
        rules: [rule(executedAt: now - 3600)],
      );
      final paid = vestingVault(
        planId: 4,
        guard: addr(2),
        startAt: now - 5000,
        schedules: [schedule(released: 1000000000, executedAt: now - 60)],
      );
      final api = await _pump(tester, [
        done,
        kids(now, silentFor: 0),
        paid,
        vesting,
      ]);
      final section = find.byKey(const Key('released-section'));
      expect(find.text('Released · 2'), findsOneWidget);
      expect(find.text('Done'), findsNothing);
      expect(find.text('PAID OUT'), findsNothing);
      expect(
        tester.getTopLeft(section).dy,
        greaterThan(tester.getTopLeft(find.text('Vesting plans')).dy),
      );
      final semantics = tester.ensureSemantics();
      expect(
        tester.getSemantics(section),
        isSemantics(hasExpandedState: true, isExpanded: false),
      );
      semantics.dispose();

      await tester.tap(section);
      await tester.pumpAndSettle();
      expect(find.text('Done'), findsOneWidget);
      expect(find.text('PAID OUT'), findsOneWidget);
      expect(find.text('0.005 SOL · 250 USDC left'), findsOneWidget);
      expect(find.text('All tiers released 1h 0m ago'), findsOneWidget);
      expect(find.text('Close plan'), findsNothing, reason: 'cards collapsed');

      await _expandAll(tester);
      expect(find.text('Close plan'), findsNWidgets(2));
      expect(find.text('Withdraw leftovers'), findsNWidgets(2));
      // Only the two active plans can be edited, funded or cancelled.
      expect(find.text('Cancel plan'), findsNWidgets(2));
      expect(find.text('Deposit'), findsNWidgets(2));
      expect(find.text('Edit'), findsOneWidget);
      expect(find.textContaining(RegExp(r'^Release \d')), findsOneWidget);

      await _tapText(tester, 'Close plan');
      expect(find.text('Close Plan 5?'), findsOneWidget);
      expect(
        find.textContaining('The plan and its history leave the app'),
        findsOneWidget,
      );
      await _tapText(tester, 'Close plan');
      expect(api.closed, [4]);
      expect(api.revoked, isEmpty);
      await _unmount(tester);
    });
  });

  group('cancel plan', () {
    testWidgets('inheritance: confirm in plain words, then close the plan', (
      tester,
    ) async {
      final now = _nowSecs();
      final api = await _pump(tester, [kids(now, silentFor: 0)]);
      await _expandAll(tester);
      final cancel = find.text('Cancel plan');
      expect(
        find.descendant(
          of: find.ancestor(of: cancel, matching: find.byType(TextButton)),
          matching: find.byWidgetPredicate(
            (w) => w is DMIcon && w.icon == DMIcons.warning,
          ),
        ),
        findsOneWidget,
      );

      await _tapText(tester, 'Cancel plan');
      expect(find.text('Cancel Kids?'), findsOneWidget);
      expect(
        find.textContaining(
          'Everything in it comes back to your wallet: 250 USDC',
        ),
        findsOneWidget,
      );
      await _tapText(tester, 'Keep plan');
      expect(api.closed, isEmpty);

      await _tapText(tester, 'Cancel plan');
      await _tapText(tester, 'Cancel plan');
      expect(api.closed, [0]);
      expect(
        find.text('Plan cancelled; its funds are back in your wallet'),
        findsOneWidget,
      );
      await _unmount(tester);
    });

    testWidgets('a locked plan explains why it cannot be cancelled yet', (
      tester,
    ) async {
      final now = _nowSecs();
      final api = await _pump(tester, [
        _locked(kids(now, silentFor: 0), now + 7200),
      ]);
      await _expandAll(tester);
      await _tapText(tester, 'Cancel plan');
      expect(find.text('Plan is locked down'), findsOneWidget);
      expect(find.textContaining("can't be cancelled or closed"), findsOne);
      await _tapText(tester, 'OK');
      expect(api.closed, isEmpty);
      await _unmount(tester);
    });

    testWidgets('revocable vesting: what vested stays with the beneficiaries; '
        'cancelling revokes', (tester) async {
      final api = await _pump(tester, [vesting]);
      await _expandAll(tester);
      await _tapText(tester, 'Cancel plan');
      expect(find.text('Cancel Plan 2?'), findsOneWidget);
      expect(
        find.textContaining(
          RegExp(r'What has already vested \(\d+ USDC\) stays with the '),
        ),
        findsOneWidget,
      );
      await _tapText(tester, 'Cancel plan');
      expect(api.revoked, [1]);
      expect(api.closed, isEmpty);
      await _unmount(tester);
    });

    testWidgets('irrevocable vesting says it cannot be cancelled', (
      tester,
    ) async {
      final start = _nowSecs() - 500;
      await _pump(tester, [
        vestingVault(
          planId: 1,
          guard: addr(2),
          startAt: start,
          revocable: false,
          schedules: [schedule()],
        ),
      ]);
      await _expandAll(tester);
      expect(find.text('Cancel plan'), findsNothing);
      expect(
        find.textContaining("Irrevocable: this plan can't be cancelled"),
        findsOneWidget,
      );
      await _unmount(tester);
    });

    testWidgets('revoked vesting: Close once nothing is owed', (tester) async {
      final now = _nowSecs();
      VaultState revoked(int planId, int at) => vestingVault(
        planId: planId,
        guard: addr(2),
        startAt: now - 500,
        revokedAt: at,
        schedules: [schedule()],
      );
      // Revoked mid-way: what vested is still owed.
      await _pump(tester, [revoked(1, now - 100)]);
      await _expandAll(tester);
      expect(find.text('Cancel plan'), findsNothing);
      expect(find.text('Close plan'), findsNothing);
      expect(
        find.textContaining('You can close this plan once the beneficiaries'),
        findsOneWidget,
      );
      await _unmount(tester);

      // Revoked at the start: nothing vested, nothing owed.
      final api = await _pump(tester, [revoked(2, now - 500)]);
      await _expandAll(tester);
      await _tapText(tester, 'Close plan');
      await _tapText(tester, 'Close plan');
      expect(api.closed, [2]);
      await _unmount(tester);
    });
  });
}

/// [plan] under panic lockdown until [until].
VaultState _locked(VaultState plan, int until) => VaultState(
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
  lockedUntil: until,
  guardianReadyAt: 0,
  totalPulses: 1,
  streak: 1,
  bestStreak: 1,
  rules: plan.rules,
  lamports: 0,
  withdrawableLamports: 0,
);
