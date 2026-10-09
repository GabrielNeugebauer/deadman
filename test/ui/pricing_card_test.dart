import 'dart:async';

import 'package:deadman/core/config.dart';
import 'package:deadman/solana/deadman_api.dart';
import 'package:deadman/state/providers.dart';
import 'package:deadman/ui/screens/settings_tab.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../state/fakes.dart';

Future<void> _pump(WidgetTester tester, FeeSchedule fees) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [feesProvider.overrideWith((ref) async => fees)],
      child: const MaterialApp(home: Scaffold(body: PricingCard())),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a fee only on release, per rail and for SKR, part burned', (
    tester,
  ) async {
    await _pump(
      tester,
      FeeSchedule(
        treasury: addr(9),
        feeBpsPublic: 200,
        feeBpsPrivate: 300,
        skrMint: AppConfig.skrMint,
        feeBpsSkr: 150,
        skrBurnBps: 1000,
      ),
    );
    expect(find.text('Pricing'), findsOneWidget);
    expect(
      find.text(
        'A fee is taken only when a tier or vesting installment releases '
        'funds. Withdrawing, closing, cancelling and revoking are free.',
      ),
      findsOneWidget,
    );
    expect(find.bySemanticsLabel('Via Solana: 2%'), findsOneWidget);
    expect(find.bySemanticsLabel('Via Cloak or Zcash: 3%'), findsOneWidget);
    expect(find.bySemanticsLabel('Payouts in SKR: 1.5%'), findsOneWidget);
    expect(
      find.text(
        '10% of every SKR fee is burned in the same transaction; the rest '
        'goes to Deadman.',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('Plus'), findsNothing);
  });

  testWidgets('no SKR rate configured: no SKR row', (tester) async {
    await _pump(
      tester,
      FeeSchedule(treasury: addr(9), feeBpsPublic: 200, feeBpsPrivate: 200),
    );
    expect(find.bySemanticsLabel('Via Solana: 2%'), findsOneWidget);
    expect(find.textContaining('SKR'), findsNothing);
  });

  testWidgets('no burn: the SKR rate without the burn line', (tester) async {
    await _pump(
      tester,
      FeeSchedule(
        treasury: addr(9),
        feeBpsPublic: 200,
        feeBpsPrivate: 200,
        skrMint: AppConfig.skrMint,
        feeBpsSkr: 150,
      ),
    );
    expect(find.bySemanticsLabel('Payouts in SKR: 1.5%'), findsOneWidget);
    expect(find.textContaining('burned'), findsNothing);
  });

  testWidgets('fees not read yet: the defaults in one line', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          feesProvider.overrideWith((ref) => Completer<FeeSchedule>().future),
        ],
        child: const MaterialApp(home: Scaffold(body: PricingCard())),
      ),
    );
    await tester.pump();
    expect(
      find.text(
        '2% on release · 1.5% for SKR (10% burned) · withdrawals free.',
      ),
      findsOneWidget,
    );
  });
}
