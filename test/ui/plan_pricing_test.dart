import 'package:deadman/core/config.dart';
import 'package:deadman/solana/deadman_api.dart';
import 'package:deadman/state/providers.dart';
import 'package:deadman/ui/theme.dart';
import 'package:deadman/ui/widgets/plan_pricing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../state/fakes.dart';

const skr = AppConfig.skrMint;
final owner = addr(1);

/// The program's defaults: 2% on every rail, 1.5% for SKR, 10% burned.
final defaults = FeeSchedule(
  treasury: addr(9),
  feeBpsPublic: 200,
  feeBpsPrivate: 200,
  skrMint: skr,
  feeBpsSkr: 150,
  skrBurnBps: 1000,
);

/// Renders [child] with the fee schedule [fees] (null = not read yet).
Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  FeeSchedule? fees,
}) async {
  tester.view.physicalSize = const Size(900, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues({'owner': owner});
  final prefs = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        prefsProvider.overrideWithValue(prefs),
        apiProvider.overrideWithValue(FakeApi(const [])),
        feesProvider.overrideWith(
          (ref) async => fees ?? (throw StateError('rpc down')),
        ),
      ],
      child: MaterialApp(
        theme: buildTheme(),
        home: Scaffold(body: ListView(children: [child])),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('plan fee line', () {
    testWidgets('the rate its pending payouts pay', (tester) async {
      await _pump(tester, PlanFeeLine(vault: vault()), fees: defaults);
      expect(find.text('Release fee: 2%'), findsOneWidget);
      expect(find.byType(TextButton), findsNothing);
      final icon = tester.widget<Icon>(
        find.byIcon(Icons.receipt_long_outlined),
      );
      expect(icon.color, DM.ash);
    });

    testWidgets('an SKR plan shows 1.5% and the burn', (tester) async {
      await _pump(
        tester,
        PlanFeeLine(
          vault: vault(rules: [rule(mint: skr)]),
        ),
        fees: defaults,
      );
      expect(
        find.text('Release fee: 1.5% · SKR fees 10% burned'),
        findsOneWidget,
      );
    });

    testWidgets('before the schedule is read', (tester) async {
      await _pump(tester, PlanFeeLine(vault: vault()));
      expect(find.text('Release fee on payouts'), findsOneWidget);
    });
  });

  group('fee model card', () {
    testWidgets('one line from the on-chain values, details below', (
      tester,
    ) async {
      await _pump(tester, const FeeModelCard(), fees: defaults);
      expect(find.text('Fees'), findsOneWidget);
      expect(
        find.text(
          '2% on release · 1.5% for SKR (10% burned) · withdrawals free',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('Withdrawing, closing'), findsOneWidget);
      expect(
        find.text(
          'Payouts in SKR pay 1.5% on every rail, and 10% of that fee is '
          'burned.',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('Plus'), findsNothing);
      expect(find.textContaining('subscri'), findsNothing);
    });

    testWidgets('follows a changed schedule', (tester) async {
      await _pump(
        tester,
        const FeeModelCard(compact: true),
        fees: FeeSchedule(
          treasury: addr(9),
          feeBpsPublic: 250,
          feeBpsPrivate: 300,
          skrMint: skr,
          feeBpsSkr: 100,
          skrBurnBps: 2000,
        ),
      );
      expect(
        find.text(
          '2.5% (3% private rails) on release · 1% for SKR (20% burned) · '
          'withdrawals free',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('Withdrawing'), findsNothing);
    });

    testWidgets('unreadable schedule: the defaults', (tester) async {
      await _pump(tester, const FeeModelCard());
      expect(
        find.text(
          '2% on release · 1.5% for SKR (10% burned) · withdrawals free',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('Payouts in SKR'), findsNothing);
    });
  });
}
