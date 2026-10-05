import 'package:deadman/core/config.dart';
import 'package:deadman/solana/deadman_api.dart';
import 'package:deadman/state/providers.dart';
import 'package:deadman/ui/screens/settings_tab.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../state/fakes.dart';

Future<void> _pump(WidgetTester tester, SubscriptionTerms? terms) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        feesProvider.overrideWith(
          (ref) async => FeeSchedule(
            treasury: addr(9),
            feeBpsPublic: 200,
            feeBpsPrivate: 500,
          ),
        ),
        subscriptionTermsProvider.overrideWith((ref) async => terms),
      ],
      child: const MaterialApp(home: Scaffold(body: PricingCard())),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the release fee, and the monthly plan when offered', (
    tester,
  ) async {
    await _pump(
      tester,
      const SubscriptionTerms(
        pricePerPeriod: 10000000,
        periodSecs: 30 * 86400,
        mint: AppConfig.usdcMint,
        minPeriods: 12,
      ),
    );
    expect(find.text('Pricing'), findsOneWidget);
    expect(
      find.text(
        'Free to use. A fee is taken from each release: 2% via Solana, '
        '5% via Cloak or Zcash.',
      ),
      findsOneWidget,
    );
    expect(
      find.textContaining(
        'Or pay 10 USDC a month and releases carry no fee: one subscription '
        'covers all your plans',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('per plan'), findsNothing);
    expect(
      find.textContaining('starts with 12 months paid at once (up to 36'),
      findsOneWidget,
    );
  });

  testWidgets('not offered: only the release fee', (tester) async {
    await _pump(tester, null);
    expect(find.textContaining('2% via Solana'), findsOneWidget);
    expect(find.textContaining('a month'), findsNothing);
  });
}
