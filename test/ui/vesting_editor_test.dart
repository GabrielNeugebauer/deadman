import 'package:deadman/core/config.dart';
import 'package:deadman/solana/deadman_api.dart';
import 'package:deadman/state/actions.dart';
import 'package:deadman/state/providers.dart';
import 'package:deadman/ui/screens/vesting_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../state/fakes.dart';

class _Created {
  _Created(this.schedules, this.revocable, this.lamports, this.tokens);
  final List<VestingSpec> schedules;
  final bool revocable;
  final int lamports;
  final Map<String, int> tokens;
}

class _FakeActions extends VaultActions {
  _FakeActions(super.ref);

  final created = <_Created>[];

  @override
  Future<List<VaultState>> createVesting({
    required String label,
    required int startAt,
    required bool revocable,
    required List<VestingSpec> schedules,
    required int lockSecs,
    int depositLamports = 0,
    Map<String, int> tokenDeposits = const {},
  }) async {
    created.add(_Created(schedules, revocable, depositLamports, tokenDeposits));
    return const [];
  }
}

/// Sent plans; the actions object is only created when the editor saves.
class _Sent {
  final made = <_FakeActions>[];
  List<_Created> get created => [for (final a in made) ...a.created];
}

Future<_Sent> _pump(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1200, 6000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final sent = _Sent();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        actionsProvider.overrideWith((ref) {
          final a = _FakeActions(ref);
          sent.made.add(a);
          return a;
        }),
        feesProvider.overrideWith(
          (ref) async => FeeSchedule(
            treasury: addr(9),
            feeBpsPublic: 200,
            feeBpsPrivate: 500,
          ),
        ),
        walletBalanceProvider.overrideWith((ref) async => 5000000000),
        walletUsdcProvider.overrideWith((ref) async => 2000000000),
      ],
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => const VestingEditorPage(),
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
  return sent;
}

Finder _field(String label) => find.widgetWithText(TextField, label);

void main() {
  const usdc = AppConfig.usdcMint;

  testWidgets('USDC totals in USDC; deposit defaults to the total', (
    tester,
  ) async {
    final actions = await _pump(tester);
    await tester.enterText(_field('Beneficiary wallet'), addr(30));
    await tester.enterText(_field('Total'), '1500.5');
    await tester.pump();

    expect(
      tester.widget<TextField>(_field('USDC deposit')).controller!.text,
      '1500.5',
    );
    expect(find.textContaining('Schedules need 1500.5 USDC'), findsOneWidget);

    await tester.tap(find.text('Create vesting plan'));
    await tester.pumpAndSettle();

    final c = actions.created.single;
    expect(c.revocable, isTrue);
    expect(c.schedules.single.total, 1500500000);
    expect(c.schedules.single.mint, usdc);
    expect(c.schedules.single.cliffSecs, 0);
    expect(c.tokens, {usdc: 1500500000});
    expect(c.lamports, 0);
  });

  testWidgets('invalid beneficiary is reported and nothing is sent', (
    tester,
  ) async {
    final actions = await _pump(tester);
    await tester.enterText(_field('Total'), '10');
    await tester.tap(find.text('Create vesting plan'));
    await tester.pump();
    expect(find.text('Check each beneficiary address'), findsOneWidget);
    expect(actions.created, isEmpty);
  });

  testWidgets('an underfunded plan warns and asks before creating', (
    tester,
  ) async {
    final actions = await _pump(tester);
    await tester.enterText(_field('Beneficiary wallet'), addr(30));
    await tester.enterText(_field('Total'), '1000');
    await tester.pump();
    await tester.enterText(_field('USDC deposit'), '400');
    await tester.pump();
    expect(find.textContaining('Underfunded by 600 USDC'), findsOneWidget);

    await tester.tap(find.text('Create vesting plan'));
    await tester.pumpAndSettle();
    expect(find.text('Plan is underfunded'), findsOneWidget);
    await tester.tap(find.text('Go back'));
    await tester.pumpAndSettle();
    expect(actions.created, isEmpty);

    // Editing a total no longer overwrites a deposit the user typed.
    await tester.enterText(_field('Total'), '2000');
    await tester.pump();
    expect(
      tester.widget<TextField>(_field('USDC deposit')).controller!.text,
      '400',
    );
  });

  testWidgets('SOL schedule with demo timings and a cliff', (tester) async {
    final actions = await _pump(tester);
    await tester.tap(find.text('Demo timings'));
    await tester.pump();
    await tester.enterText(_field('Beneficiary wallet'), addr(30));
    await tester.tap(find.text('SOL').first);
    await tester.pump();
    await tester.enterText(_field('Total'), '0.5');
    await tester.tap(find.text('10 minutes'));
    await tester.pump();
    await tester.tap(find.text('2 minutes'));
    await tester.pump();
    await tester.tap(find.text('Revocable'));
    await tester.pump();

    await tester.tap(find.text('Create vesting plan'));
    await tester.pumpAndSettle();
    expect(find.text('Irrevocable plan'), findsOneWidget);
    await tester.tap(find.text('Create plan'));
    await tester.pumpAndSettle();

    final c = actions.created.single;
    expect(c.revocable, isFalse);
    expect(c.schedules.single.mint, isNull);
    expect(c.schedules.single.total, 500000000);
    expect(c.schedules.single.durationSecs, 600);
    expect(c.schedules.single.cliffSecs, 120);
    expect(c.lamports, 500000000);
    expect(c.tokens, isEmpty);
  });
}
