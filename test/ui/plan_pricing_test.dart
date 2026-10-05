import 'dart:typed_data';

import 'package:deadman/core/config.dart';
import 'package:deadman/solana/deadman_api.dart';
import 'package:deadman/state/providers.dart';
import 'package:deadman/ui/format.dart';
import 'package:deadman/ui/widgets/plan_pricing.dart';
import 'package:deadman/wallet/wallet_bridge.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../state/fakes.dart';

const usdc = AppConfig.usdcMint;
const month = 30 * 86400;
final owner = addr(1);

const terms = SubscriptionTerms(
  pricePerPeriod: 10000000,
  periodSecs: month,
  mint: usdc,
  minPeriods: 12,
);

class _SubApi extends FakeApi {
  _SubApi() : super(const []);

  final sent = <Uint8List>[];

  @override
  Future<List<String>> sendSigned(List<Uint8List> signedTransactions) async {
    sent.addAll(signedTransactions);
    return ['sig'];
  }
}

class _EchoWallet implements WalletBridge {
  @override
  Future<WalletSession> authorize() => throw UnimplementedError();

  @override
  Future<List<Uint8List>> signTransactions(List<Uint8List> txs) async => txs;

  @override
  Future<void> deauthorize(String authToken) async {}
}

int _now() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

AccountSubscription _sub(int paidUntil) =>
    AccountSubscription(owner: owner, paidUntil: paidUntil);

/// Renders [child] for an owner with [plans] and the subscription [sub];
/// the wallet holds [walletUsdc] and each plan 250 USDC.
Future<_SubApi> _pump(
  WidgetTester tester,
  Widget child, {
  List<VaultState> plans = const [],
  AccountSubscription? sub,
  SubscriptionTerms? offered = terms,
  int walletUsdc = 500000000,
  bool duress = false,
}) async {
  tester.view.physicalSize = const Size(900, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues({'owner': owner});
  final prefs = await SharedPreferences.getInstance();
  final api = _SubApi()
    ..plans = plans
    ..subscription = sub
    ..subscriptionTerms = offered
    ..tokens['$owner:$usdc'] = walletUsdc;
  for (final v in plans) {
    api.tokens['${v.address}:$usdc'] = 250000000;
  }
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        prefsProvider.overrideWithValue(prefs),
        apiProvider.overrideWithValue(api),
        walletProvider.overrideWithValue(_EchoWallet()),
        feesProvider.overrideWith(
          (ref) async => FeeSchedule(
            treasury: addr(9),
            feeBpsPublic: 200,
            feeBpsPrivate: 500,
          ),
        ),
      ],
      child: MaterialApp(
        home: Scaffold(body: ListView(children: [child])),
      ),
    ),
  );
  if (duress) {
    ProviderScope.containerOf(tester.element(find.byType(ListView)))
        .read(sessionProvider.notifier)
        .unlock(duress: true);
  }
  await tester.pumpAndSettle();
  return api;
}

Future<void> _open(WidgetTester tester, String button) async {
  await tester.tap(find.text(button));
  await tester.pumpAndSettle();
}

const _rules =
    'Inheritance: covers releases if your last check-in happened while '
    'subscribed. Vesting: fee-free while active.';

void main() {
  group('plan fee line', () {
    Future<void> line(
      WidgetTester tester,
      VaultState v, {
      AccountSubscription? sub,
      SubscriptionTerms? offered = terms,
    }) => _pump(
      tester,
      PlanFeeLine(vault: v, now: _now()),
      sub: sub,
      offered: offered,
    );

    testWidgets('hidden while the monthly plan is not offered', (tester) async {
      await line(tester, vault(), offered: null);
      expect(find.textContaining('release fee'), findsNothing);
      expect(find.textContaining('Release fee'), findsNothing);
    });

    testWidgets('not subscribed: the release fee, and no button', (
      tester,
    ) async {
      await line(tester, vault());
      expect(find.text('Release fee: 2% (5% private rails)'), findsOneWidget);
      expect(find.byType(TextButton), findsNothing);
    });

    testWidgets('covered by the account subscription: 0%', (tester) async {
      await line(tester, vault(), sub: _sub(_now() + 86400));
      expect(find.text('0% release fee · monthly plan'), findsOneWidget);
      expect(find.byType(TextButton), findsNothing);
    });

    testWidgets('inheritance: a check-in after the end brings the fee back', (
      tester,
    ) async {
      final now = _now();
      await line(tester, vault(lastPulse: now - 10), sub: _sub(now - 100));
      expect(find.text('Release fee: 2% (5% private rails)'), findsOneWidget);
    });

    testWidgets('no longer offered: a covered plan still shows 0%', (
      tester,
    ) async {
      await line(tester, vault(), sub: _sub(_now() + 86400), offered: null);
      expect(find.text('0% release fee · monthly plan'), findsOneWidget);
    });
  });

  group('monthly plan card', () {
    testWidgets('hidden while not offered', (tester) async {
      await _pump(tester, const MonthlyPlanCard(), offered: null);
      expect(find.textContaining('Monthly plan'), findsNothing);
      expect(find.text('Subscribe'), findsNothing);
    });

    testWidgets('new: Subscribe buys 12 months or more; the sheet compares '
        'the fee on all plans and pays the chosen term', (tester) async {
      final now = _now();
      final plans = [
        vault(
          rules: [
            rule(mint: usdc),
            rule(seed: 11),
          ],
          lastPulse: now,
          withdrawableLamports: 2000000000,
        ),
        vestingVault(
          planId: 3,
          startAt: now,
          schedules: [schedule(mint: usdc, total: 100000000)],
        ),
      ];
      final api = await _pump(tester, const MonthlyPlanCard(), plans: plans);
      expect(find.text('Monthly plan'), findsOneWidget);
      expect(find.text('Not subscribed'), findsOneWidget);
      expect(find.text(_rules), findsOneWidget);
      expect(find.text('Extend'), findsNothing);
      await _open(tester, 'Subscribe');

      expect(find.text('Subscribe monthly'), findsOneWidget);
      expect(find.text('10 USDC / month'), findsOneWidget);
      expect(
        find.text(
          'One subscription covers all your plans, present and future.',
        ),
        findsNWidgets(2),
      );
      expect(find.textContaining('A new subscription starts'), findsOne);
      expect(find.textContaining('at least 12 months paid at once'), findsOne);
      expect(find.text('12 months'), findsOneWidget);
      expect(find.text('24 months'), findsOneWidget);
      expect(find.text('36 months'), findsOneWidget);
      expect(find.text('1 month'), findsNothing);
      expect(find.text('Your wallet: 500 USDC'), findsOneWidget);
      // 2% of 250 USDC on the inheritance plan, 2% of the 100 USDC the
      // vesting plan still owes.
      expect(
        find.text(
          'At 2%, releasing all your plans would cost ~7 USDC; 12 months '
          'cost 120 USDC.',
        ),
        findsOneWidget,
      );
      expect(
        find.textContaining(
          'The SOL in all your plans would add ~0.040 SOL in fees.',
        ),
        findsOneWidget,
      );

      await tester.tap(find.text('24 months'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Total 240 USDC'), findsOneWidget);
      await tester.tap(find.text('Pay 240 USDC'));
      await tester.pumpAndSettle();

      expect(api.subscribed, [(owner, 24)]);
      expect(api.sent, hasLength(1));
      expect(find.textContaining('Monthly plan paid until'), findsOneWidget);
    });

    testWidgets('no plans yet: no comparison', (tester) async {
      await _pump(tester, const MonthlyPlanCard());
      await _open(tester, 'Subscribe');
      expect(find.textContaining('releasing'), findsNothing);
      expect(find.text('Pay 120 USDC'), findsOneWidget);
    });

    testWidgets('active: paid until, and Extend offers short terms', (
      tester,
    ) async {
      final until = _now() + 90 * 86400;
      final api = await _pump(
        tester,
        const MonthlyPlanCard(),
        plans: [vault()],
        sub: _sub(until),
      );
      expect(
        find.text(
          'Monthly plan · covers all your plans · paid until '
          '${dateText(until)}',
        ),
        findsOneWidget,
      );
      expect(find.text('Subscribe'), findsNothing);
      await _open(tester, 'Extend');

      expect(find.text('Extend monthly plan'), findsOneWidget);
      expect(find.textContaining('Extend by any number of months'), findsOne);
      for (final p in ['1 month', '3 months', '6 months', '12 months']) {
        expect(find.text(p), findsOneWidget);
      }
      expect(find.text('24 months'), findsNothing);
      expect(
        find.textContaining('paid until ${dateText(until + month)}'),
        findsOneWidget,
      );
      await tester.tap(find.text('Pay 10 USDC'));
      await tester.pumpAndSettle();
      expect(api.subscribed, [(owner, 1)]);
    });

    testWidgets('lapsed: Subscribe needs the minimum again', (tester) async {
      final ended = _now() - 86400;
      await _pump(tester, const MonthlyPlanCard(), sub: _sub(ended));
      expect(
        find.text('Not subscribed · ended ${dateText(ended)}'),
        findsOneWidget,
      );
      await _open(tester, 'Subscribe');
      expect(find.textContaining('A lapsed subscription starts'), findsOne);
      expect(find.text('12 months'), findsOneWidget);
      expect(find.text('1 month'), findsNothing);
    });

    testWidgets('compact: status and button, no rules', (tester) async {
      await _pump(tester, const MonthlyPlanCard(compact: true));
      expect(find.text('Not subscribed'), findsOneWidget);
      expect(find.text('Subscribe'), findsOneWidget);
      expect(find.text(_rules), findsNothing);
    });

    testWidgets('not enough in the wallet: Pay is disabled', (tester) async {
      final api = await _pump(
        tester,
        const MonthlyPlanCard(),
        walletUsdc: 7000000,
      );
      await _open(tester, 'Subscribe');
      expect(find.text('Not enough USDC for 12 months.'), findsOneWidget);
      final pay = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Pay 120 USDC'),
      );
      expect(pay.onPressed, isNull);
      expect(api.subscribed, isEmpty);
    });

    testWidgets('under duress the payment looks like a wallet timeout', (
      tester,
    ) async {
      final api = await _pump(tester, const MonthlyPlanCard(), duress: true);
      await _open(tester, 'Subscribe');
      await tester.tap(find.text('Pay 120 USDC'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(api.subscribed, isEmpty);
      expect(find.textContaining('timed out'), findsOneWidget);
    });
  });
}
