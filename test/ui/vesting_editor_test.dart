import 'package:deadman/core/config.dart';
import 'package:deadman/solana/deadman_api.dart';
import 'package:deadman/state/actions.dart';
import 'package:deadman/state/providers.dart';
import 'package:deadman/ui/screens/vesting_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../state/fakes.dart';

class _Created {
  _Created(this.schedules, this.revocable, this.lamports, this.tokens);
  final List<VestingSpec> schedules;
  final bool revocable;
  final int lamports;
  final Map<String, int> tokens;
}

class _FakeActions extends VaultActions {
  _FakeActions(super.ref, this.created);

  final List<_Created> created;

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

Future<List<_Created>> _pump(
  WidgetTester tester, {
  FakeApi? api,
  Size size = const Size(1200, 6000),
  double textScale = 1,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues({'owner': addr(1)});
  final prefs = await SharedPreferences.getInstance();
  final created = <_Created>[];
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        prefsProvider.overrideWithValue(prefs),
        actionsProvider.overrideWith((ref) => _FakeActions(ref, created)),
        apiProvider.overrideWithValue(api ?? FakeApi(const [])),
        feesProvider.overrideWith(
          (ref) async => FeeSchedule(
            treasury: addr(9),
            feeBpsPublic: 200,
            feeBpsPrivate: 500,
          ),
        ),
        walletBalanceProvider.overrideWith((ref) async => 5000000000),
        walletTokenProvider.overrideWith((ref, mint) async => 2000000000),
      ],
      child: MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
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
  return created;
}

Finder _field(String label) => find.widgetWithText(TextField, label);

final _list = find
    .byWidgetPredicate(
      (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
    )
    .first;

Future<void> _tap(WidgetTester tester, String text) async {
  for (var i = 0; i < 50 && find.text(text).evaluate().isEmpty; i++) {
    await tester.drag(_list, const Offset(0, -200));
    await tester.pump();
  }
  await tester.ensureVisible(find.text(text).first);
  await tester.pumpAndSettle();
  await tester.tap(find.text(text).first);
  await tester.pumpAndSettle();
}

/// Fills the schedule editor that opens on create.
Future<void> _schedule(
  WidgetTester tester, {
  required String total,
  int who = 30,
  bool sol = false,
}) async {
  await _tap(tester, 'Add a schedule');
  expect(find.text('New schedule'), findsOneWidget);
  await tester.enterText(
    _field('Their wallet address or claim code'),
    addr(who),
  );
  if (sol) await _tap(tester, 'SOL');
  await tester.enterText(find.byKey(const ValueKey('vest-total')), total);
  await tester.pump(const Duration(milliseconds: 500));
  await tester.pumpAndSettle();
}

void main() {
  const usdc = AppConfig.usdcMint;
  final heldUsdc = FakeApi(const [])..tokens['${addr(30)}:$usdc'] = 1;

  testWidgets('USDC totals in USDC; deposit defaults to the total', (
    tester,
  ) async {
    final created = await _pump(tester, api: heldUsdc);
    await _schedule(tester, total: '1500.5');
    expect(
      find.textContaining('1500.5 USDC to ${addr(30).substring(0, 4)}'),
      findsOneWidget,
    );
    await _tap(tester, 'Done');
    await _tap(tester, 'Next: fund the plan');

    expect(
      tester.widget<TextField>(_field('Put in this plan')).controller!.text,
      '1500.5',
    );
    expect(find.text('Your schedules add up to 1500.5 USDC.'), findsOneWidget);

    await _tap(tester, 'Next: review');
    expect(find.textContaining('receives 1500.5 USDC gradually'), findsOne);
    await _tap(tester, 'Create vesting plan');

    final c = created.single;
    expect(c.revocable, isTrue);
    expect(c.schedules.single.total, 1500500000);
    expect(c.schedules.single.mint, usdc);
    expect(c.schedules.single.cliffSecs, 0);
    expect(c.tokens, {usdc: 1500500000});
    expect(c.lamports, 0);
  });

  testWidgets('an invalid beneficiary keeps the schedule editor open', (
    tester,
  ) async {
    await _pump(tester);
    await _tap(tester, 'Add a schedule');
    await tester.enterText(find.byKey(const ValueKey('vest-total')), '10');
    await _tap(tester, 'Done');
    expect(
      find.text("This isn't a valid Solana address or claim code."),
      findsOneWidget,
    );
    expect(find.text('New schedule'), findsOneWidget);
  });

  testWidgets('an underfunded plan warns; a typed deposit is kept', (
    tester,
  ) async {
    final created = await _pump(tester, api: heldUsdc);
    await _schedule(tester, total: '1000');
    await _tap(tester, 'Done');
    await _tap(tester, 'Next: fund the plan');
    await tester.enterText(_field('Put in this plan'), '400');
    await tester.pump();
    expect(find.text('Not fully funded'), findsOneWidget);
    expect(find.textContaining('600 USDC short'), findsOneWidget);

    await _tap(tester, 'Back');
    await tester.tap(find.textContaining('· 1000 USDC'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('vest-total')), '2000');
    await tester.pump();
    await _tap(tester, 'Done');
    await _tap(tester, 'Next: fund the plan');
    expect(
      tester.widget<TextField>(_field('Put in this plan')).controller!.text,
      '400',
    );

    await _tap(tester, 'Put in 2000 USDC');
    await _tap(tester, 'Next: review');
    await _tap(tester, 'Create vesting plan');
    expect(created.single.tokens, {usdc: 2000000000});
  });

  testWidgets('SOL schedule with demo timings, a cliff, and the irrevocable '
      'checkbox', (tester) async {
    final created = await _pump(tester);
    await _tap(tester, 'Advanced');
    await _tap(tester, 'Demo timings');
    await _tap(tester, "No, it's locked in");
    await _tap(tester, 'Add a schedule');
    await tester.enterText(
      _field('Their wallet address or claim code'),
      addr(30),
    );
    await _tap(tester, 'SOL');
    await tester.enterText(find.byKey(const ValueKey('vest-total')), '0.5');
    await _tap(tester, '10 minutes');
    await _tap(tester, '2 minutes');
    expect(find.textContaining('unlocks at once'), findsOneWidget);
    await _tap(tester, 'Done');

    await _tap(tester, 'Next: fund the plan');
    await _tap(tester, 'Next: review');
    await _tap(tester, 'Create vesting plan');
    expect(created, isEmpty);
    expect(
      find.text('Tick the box to create a plan you can never stop.'),
      findsOneWidget,
    );
    await _tap(
      tester,
      'I understand I can never stop these schedules or withdraw what they '
      'owe.',
    );
    await _tap(tester, 'Create vesting plan');

    final c = created.single;
    expect(c.revocable, isFalse);
    expect(c.schedules.single.mint, isNull);
    expect(c.schedules.single.total, 500000000);
    expect(c.schedules.single.durationSecs, 600);
    expect(c.schedules.single.cliffSecs, 120);
    expect(c.lamports, 500000000);
    expect(c.tokens, isEmpty);
  });

  testWidgets('a USDC total to a wallet new to USDC that is too small needs '
      'the checkbox', (tester) async {
    final created = await _pump(tester);
    await _schedule(tester, total: '0.3');
    expect(find.text('Too small to arrive'), findsWidgets);
    await _tap(tester, 'Done');
    await _tap(tester, 'Next: fund the plan');
    await _tap(tester, 'Next: review');
    await _tap(tester, 'Create vesting plan');
    expect(created, isEmpty);
    await _tap(
      tester,
      'Create it anyway. I understand the schedules marked with a red sign '
      'may never arrive.',
    );
    await _tap(tester, 'Create vesting plan');
    expect(created, hasLength(1));
  });

  testWidgets('no overflow at 200% text on a phone', (tester) async {
    await _pump(
      tester,
      api: heldUsdc,
      size: const Size(400, 860),
      textScale: 2,
    );
    expect(tester.takeException(), isNull);
    await _tap(tester, 'Add a schedule');
    await tester.enterText(
      _field('Their wallet address or claim code'),
      addr(30),
    );
    final total = find.byKey(const ValueKey('vest-total'));
    while (total.evaluate().isEmpty) {
      await tester.drag(_list, const Offset(0, -200));
      await tester.pump();
    }
    await tester.ensureVisible(total);
    await tester.enterText(total, '100');
    await tester.pumpAndSettle();
    await _tap(tester, '3 months');
    expect(tester.takeException(), isNull);
    await _tap(tester, 'Done');
    expect(tester.takeException(), isNull);
    await _tap(tester, 'Next: fund the plan');
    expect(tester.takeException(), isNull);
    await _tap(tester, 'Next: review');
    expect(tester.takeException(), isNull);
  });
}
