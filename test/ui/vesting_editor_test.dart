import 'package:deadman/core/config.dart';
import 'package:deadman/solana/deadman_api.dart';
import 'package:deadman/state/actions.dart';
import 'package:deadman/state/providers.dart';
import 'package:deadman/state/vesting.dart';
import 'package:deadman/ui/screens/vesting_editor.dart';
import 'package:deadman/ui/theme.dart';
import 'package:deadman/ui/widgets/vesting_progress.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../state/fakes.dart';

class _Created {
  _Created(
    this.schedules,
    this.revocable,
    this.lamports,
    this.tokens,
    this.periodSecs,
  );
  final List<VestingSpec> schedules;
  final bool revocable;
  final int lamports;
  final Map<String, int> tokens;
  final int periodSecs;
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
    int periodSecs = 0,
    int depositLamports = 0,
    Map<String, int> tokenDeposits = const {},
  }) async {
    created.add(
      _Created(
        schedules,
        revocable,
        depositLamports,
        tokenDeposits,
        periodSecs,
      ),
    );
    return const [];
  }
}

Future<List<_Created>> _pump(
  WidgetTester tester, {
  FakeApi? api,
  Size size = const Size(1200, 6000),
  double textScale = 1,
  ThemeData? theme,
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
        theme: theme,
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
    expect(
      find.textContaining(
        'receives 1500.5 USDC over 12 months in 12 installments of about '
        '125.04 USDC every month, first on',
      ),
      findsOne,
    );
    await _tap(tester, 'Create vesting plan');

    final c = created.single;
    expect(c.periodSecs, monthSecs);
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
    expect(
      find.textContaining('the first 2 installments unlock together'),
      findsOneWidget,
    );
    expect(find.textContaining('Then 0.05 SOL every minute'), findsOneWidget);
    await _tap(tester, 'Done');
    expect(
      find.textContaining(
        '10 installments of 0.05 SOL every minute, the '
        'first 2 together (0.1 SOL) on',
      ),
      findsOneWidget,
    );

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
    expect(c.periodSecs, 60);
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

  testWidgets('"Continuously" keeps the legacy per-second vesting', (
    tester,
  ) async {
    final created = await _pump(tester, api: heldUsdc);
    expect(find.text('Release every'), findsOneWidget);
    await _tap(tester, 'Continuously');
    expect(find.textContaining('a little every second'), findsOneWidget);
    await _schedule(tester, total: '1200');
    expect(find.textContaining('Each month after: about'), findsOneWidget);
    await _tap(tester, 'Done');
    await _tap(tester, 'Next: fund the plan');
    await _tap(tester, 'Next: review');
    expect(find.textContaining('receives 1200 USDC gradually'), findsOne);
    await _tap(tester, 'Create vesting plan');
    expect(created.single.periodSecs, 0);
  });

  testWidgets('installments: editor preview and summary card', (tester) async {
    final created = await _pump(tester, api: heldUsdc);
    await _tap(tester, 'Quarter');
    await _schedule(tester, total: '1200');
    await _tap(tester, '3 months');
    expect(find.textContaining('first installment, 300 USDC'), findsOne);
    expect(find.textContaining('Then 300 USDC every quarter'), findsOne);
    expect(find.textContaining('in 4 installments'), findsOne);
    expect(find.textContaining('Nothing can be claimed between'), findsOne);
    await _tap(tester, 'Done');
    expect(
      find.textContaining(
        '4 installments of 300 USDC every quarter, first '
        'on',
      ),
      findsOneWidget,
    );
    await _tap(tester, 'Next: fund the plan');
    await _tap(tester, 'Next: review');
    await _tap(tester, 'Create vesting plan');
    expect(created.single.periodSecs, quarterSecs);
  });

  testWidgets('a period longer than a schedule is explained and blocks Next', (
    tester,
  ) async {
    final created = await _pump(tester, api: heldUsdc);
    await _tap(tester, 'Advanced');
    await _tap(tester, 'Demo timings');
    expect(find.text('Minute'), findsOneWidget);
    await _schedule(tester, total: '10');
    await _tap(tester, '10 minutes');
    await _tap(tester, 'Done');
    await tester.enterText(_field('Plan name'), 'Demo');
    await _tap(tester, 'Day');
    const why =
        'Schedule 1 is fully unlocked after 10 minutes, before its first '
        'installment (one every day). Release more often, or give it a '
        'longer duration.';
    expect(find.text(why), findsOneWidget);
    await _tap(tester, 'Next: fund the plan');
    expect(find.text('Put in this plan'), findsNothing);

    // The schedule editor offers no duration shorter than one installment.
    await tester.tap(find.textContaining('· 10 USDC'));
    await tester.pumpAndSettle();
    final chip = tester.widget<ChoiceChip>(
      find.widgetWithText(ChoiceChip, '10 minutes'),
    );
    expect(chip.onSelected, isNull);
    expect(find.textContaining('must last at least that long'), findsOne);
    await tester.tap(find.byTooltip('Cancel'));
    await tester.pumpAndSettle();

    await _tap(tester, 'Minute');
    expect(find.text(why), findsNothing);
    await _tap(tester, 'Next: fund the plan');
    await _tap(tester, 'Next: review');
    await _tap(tester, 'Create vesting plan');
    expect(created.single.periodSecs, 60);
  });

  testWidgets('no overflow at 200% text on a phone', (tester) async {
    await _pump(
      tester,
      api: heldUsdc,
      size: const Size(400, 860),
      textScale: 2,
      theme: buildTheme(),
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

  testWidgets('brand: schedule editor and card use the signal accent', (
    tester,
  ) async {
    await _pump(tester, api: heldUsdc, theme: buildTheme());
    await _schedule(tester, total: '1200');
    // Milestones: the date in mono, what unlocks in Outfit.
    final milestone = tester.widget<Text>(
      find.textContaining('first installment, 100 USDC'),
    );
    final spans = (milestone.textSpan! as TextSpan).children!.cast<TextSpan>();
    expect(spans.first.style?.fontFamily, contains('JetBrains'));
    expect(spans.first.text, endsWith(':'));
    for (final bar in tester.widgetList<VestingBar>(find.byType(VestingBar))) {
      expect(bar.color, DM.signal);
    }
    await _tap(tester, 'Done');
    final card = tester.widget<VestingBar>(find.byType(VestingBar));
    expect(card.color, DM.signal);
    expect(find.text('START'), findsOneWidget);
    expect(find.text('END'), findsOneWidget);
    // Selected chips (Today, Yes, Month) read in signal, never purple.
    final today = tester.widget<ChoiceChip>(
      find.widgetWithText(ChoiceChip, 'Today'),
    );
    expect(today.labelStyle?.color, DM.signal);
    for (final w in tester.allWidgets) {
      if (w is Text) expect(w.style?.color, isNot(DM.locked));
      if (w is Icon) expect(w.color, isNot(DM.locked));
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('brand: review numbers each schedule and sets deposits in mono', (
    tester,
  ) async {
    await _pump(tester, api: heldUsdc, theme: buildTheme());
    await _schedule(tester, total: '1200');
    await _tap(tester, 'Done');
    await _tap(tester, 'Next: fund the plan');
    await _tap(tester, 'Next: review');
    expect(find.text('Schedule 1'), findsOneWidget);
    expect(find.text('1'), findsOneWidget);
    final deposit = tester.widget<Text>(find.text('1200 USDC'));
    expect(deposit.style?.fontFamily, contains('JetBrains'));
  });
}
