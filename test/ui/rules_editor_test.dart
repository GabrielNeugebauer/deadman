import 'package:deadman/solana/deadman_api.dart';
import 'package:deadman/state/actions.dart';
import 'package:deadman/state/providers.dart';
import 'package:deadman/ui/screens/rules_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../state/fakes.dart';

class _Policy {
  _Policy(this.rules, this.skipGraceSecs);
  final List<RuleSpec> rules;
  final int skipGraceSecs;
}

class _FakeActions extends VaultActions {
  _FakeActions(super.ref);

  final updates = <_Policy>[];

  @override
  Future<void> updatePolicy({
    required int planId,
    required String label,
    required int intervalSecs,
    required int lockSecs,
    required int skipGraceSecs,
    required List<RuleSpec> rules,
    String? guardian,
  }) async => updates.add(_Policy(rules, skipGraceSecs));
}

Future<List<_FakeActions>> _pump(WidgetTester tester, VaultState v) async {
  tester.view.physicalSize = const Size(1200, 6000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final made = <_FakeActions>[];
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        actionsProvider.overrideWith((ref) {
          final a = _FakeActions(ref);
          made.add(a);
          return a;
        }),
        feesProvider.overrideWith(
          (ref) async => FeeSchedule(
            treasury: addr(9),
            feeBpsPublic: 200,
            feeBpsPrivate: 500,
          ),
        ),
      ],
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => RulesEditorPage(vault: v),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return made;
}

void main() {
  final released = rule(
    seed: 11,
    afterSecs: 10 * 86400,
    amount: 5000,
    executedAt: 900,
  );
  final pending = rule(seed: 12, afterSecs: 20 * 86400);

  testWidgets('edit sends only the pending tiers; released ones are history', (
    tester,
  ) async {
    final v = vault(
      label: 'Kids',
      rules: [released, pending],
      skipGraceSecs: 7 * 86400,
    );
    final actions = await _pump(tester, v);

    expect(find.text('Tier 1 · Released'), findsOneWidget);
    expect(find.text('Tier 2'), findsOneWidget);
    expect(find.textContaining('of remaining SOL'), findsOneWidget);

    await tester.tap(find.text('30 days').last);
    await tester.pump();
    await tester.tap(find.text('Save with wallet'));
    await tester.pumpAndSettle();

    final sent = actions.single.updates.single;
    expect(sent.rules, hasLength(1));
    expect(sent.rules.single.beneficiary, pending.beneficiary);
    expect(sent.rules.single.afterSecs, pending.afterSecs);
    expect(sent.rules.single.amount, 10000);
    expect(sent.skipGraceSecs, 30 * 86400);
  });

  testWidgets('a skipped tier is history: reserved, still claimable', (
    tester,
  ) async {
    final skipped = rule(
      seed: 13,
      afterSecs: 10 * 86400,
      amount: 5000,
      skippedAt: 950,
      reserved: 42,
    );
    final v = vault(rules: [released, skipped, pending]);
    final actions = await _pump(tester, v);

    expect(find.text('Tier 1 · Released'), findsOneWidget);
    expect(
      find.text('Tier 2 · Skipped (reserved, still claimable)'),
      findsOneWidget,
    );
    expect(find.textContaining('could not pay'), findsNothing);
    expect(find.text('Tier 3'), findsOneWidget);

    await tester.tap(find.text('Save with wallet'));
    await tester.pumpAndSettle();
    final sent = actions.single.updates.single;
    expect(sent.rules.map((r) => r.beneficiary), [pending.beneficiary]);
  });

  testWidgets('a last tier under 100% of remaining asks before saving', (
    tester,
  ) async {
    final v = vault(rules: [rule(seed: 12, amount: 5000)]);
    final actions = await _pump(tester, v);

    expect(find.textContaining('50% left in vault'), findsOneWidget);

    await tester.tap(find.text('Save with wallet'));
    await tester.pumpAndSettle();
    expect(find.text('Funds will be left behind'), findsOneWidget);
    await tester.tap(find.text('Go back'));
    await tester.pumpAndSettle();
    expect(actions, isEmpty);

    await tester.tap(find.text('Save with wallet'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save anyway'));
    await tester.pumpAndSettle();
    expect(actions.single.updates.single.rules.single.amount, 5000);
  });

  testWidgets('a fully released plan starts fresh with no history', (
    tester,
  ) async {
    final v = vault(rules: [rule(seed: 11, executedAt: 900)]);
    await _pump(tester, v);
    expect(find.text('Start a new plan'), findsOneWidget);
    expect(find.textContaining('Released'), findsNothing);
  });
}
