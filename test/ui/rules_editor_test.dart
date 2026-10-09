import 'package:deadman/core/config.dart';
import 'package:deadman/solana/deadman_api.dart';
import 'package:deadman/state/actions.dart';
import 'package:deadman/state/providers.dart';
import 'package:deadman/state/plan_draft.dart';
import 'package:deadman/ui/screens/rules_editor.dart';
import 'package:deadman/ui/theme.dart';
import 'package:deadman/ui/widgets/brand/brand.dart';
import 'package:deadman/ui/widgets/editor/plan_steps.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../state/fakes.dart';

const usdc = AppConfig.usdcMint;

class _Sent {
  _Sent(this.rules, this.lamports, this.tokens, this.skipGraceSecs);
  final List<RuleSpec> rules;
  final int lamports;
  final Map<String, int> tokens;
  final int skipGraceSecs;
}

class _FakeActions extends VaultActions {
  _FakeActions(super.ref, this.sent);

  final List<_Sent> sent;

  @override
  Future<List<VaultState>> createVault({
    required String label,
    required List<RuleSpec> rules,
    required int lockSecs,
    required int skipGraceSecs,
    required int depositLamports,
    Map<String, int> tokenDeposits = const {},
  }) async {
    sent.add(_Sent(rules, depositLamports, tokenDeposits, skipGraceSecs));
    return const [];
  }

  @override
  Future<void> updatePolicy({
    required int planId,
    required String label,
    required int lockSecs,
    required int skipGraceSecs,
    required List<RuleSpec> rules,
    String? guardian,
  }) async => sent.add(_Sent(rules, 0, const {}, skipGraceSecs));
}

Future<List<_Sent>> _pump(
  WidgetTester tester,
  VaultState? v, {
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
  final sent = <_Sent>[];
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        prefsProvider.overrideWithValue(prefs),
        actionsProvider.overrideWith((ref) => _FakeActions(ref, sent)),
        apiProvider.overrideWithValue(api ?? FakeApi(const [])),
        walletTokenProvider.overrideWith((ref, mint) async => 12000000),
        walletBalanceProvider.overrideWith((ref) async => 2000000000),
        feesProvider.overrideWith(
          (ref) async => FeeSchedule(
            treasury: addr(9),
            feeBpsPublic: 200,
            feeBpsPrivate: 300,
          ),
        ),
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
  return sent;
}

/// The input under the label [label] (labels sit above their fields).
Finder _field(String label) => find.descendant(
  of: find.widgetWithText(LabeledField, label),
  matching: find.byType(TextField),
);

/// Lets the debounced beneficiary lookup run.
Future<void> _settle(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 500));
  await tester.pumpAndSettle();
}

/// Scrolls the page's list until [f] is built, then to the top of the view
/// (clear of the sticky bottom bar).
Future<void> _scrollTo(WidgetTester tester, Finder f) async {
  await tester.scrollUntilVisible(
    f,
    200,
    scrollable: find
        .byWidgetPredicate(
          (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
        )
        .first,
  );
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, String text) async {
  await _scrollTo(tester, find.text(text).first);
  await tester.tap(find.text(text).first);
  await tester.pumpAndSettle();
}

/// Fills the payout editor that opens on create: [who], USDC, [share]%.
Future<void> _usdcPayout(
  WidgetTester tester, {
  String share = '100',
  int who = 12,
}) async {
  expect(find.text('New payout'), findsOneWidget);
  await tester.enterText(_field('Wallet address or claim code'), addr(who));
  // Close the keyboard: a focused field scrolls itself back into view.
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pump();
  final chip = find.widgetWithText(ChoiceChip, 'USDC');
  await _scrollTo(tester, chip);
  await tester.tap(chip);
  await tester.pump();
  final field = find.byKey(const ValueKey('share-field'));
  await _scrollTo(tester, field);
  await tester.enterText(field, share);
  await _settle(tester);
}

void main() {
  final released = rule(
    seed: 11,
    afterSecs: 10 * 86400,
    amount: 5000,
    executedAt: 900,
  );
  final pending = rule(seed: 12, afterSecs: 20 * 86400);

  testWidgets('regression: 1% of 1 USDC is flagged before it is created', (
    tester,
  ) async {
    final sent = await _pump(tester, null);
    await _usdcPayout(tester, share: '1');

    expect(find.text('1 out of every 100 USDC left'), findsOneWidget);
    expect(find.text('Did you mean 100%?'), findsWidgets);

    await _tap(tester, 'Done');
    expect(find.text('Sent 30 days after your last check-in'), findsOneWidget);
    await _tap(tester, 'Next: fund the plan');

    await tester.enterText(_field('Put in this plan'), '1');
    await tester.pumpAndSettle();
    expect(find.textContaining('≈ 0.0098 USDC'), findsWidgets);
    expect(find.text('Too small to arrive'), findsWidgets);

    await _tap(tester, 'Next: review');
    await _tap(tester, 'Create plan');
    expect(sent, isEmpty);
    expect(
      find.text('Tick the box, or fix the payouts marked with a red sign.'),
      findsOneWidget,
    );

    await _tap(tester, 'Use 100%');
    expect(find.text('Too small to arrive'), findsNothing);
    expect(find.text('Did you mean 100%?'), findsNothing);
    expect(find.textContaining('will need to claim it'), findsWidgets);
    expect(find.textContaining('(≈\u00a00.98 USDC)'), findsOneWidget);

    await _tap(tester, 'Create plan');
    final s = sent.single;
    expect(s.rules.single.amount, 10000);
    expect(s.rules.single.mode, AmountMode.percent);
    expect(s.rules.single.mint, usdc);
    expect(s.tokens, {usdc: 1000000});
    expect(s.lamports, 0);
  });

  testWidgets('share and fixed keep their own values', (tester) async {
    await _pump(tester, null);
    await _usdcPayout(tester);
    expect(find.text("Everything that's left"), findsOneWidget);

    await tester.tap(find.text('Fixed amount'));
    await tester.pump();
    final fixed = find.byKey(const ValueKey('fixed-field'));
    expect(tester.widget<TextField>(fixed).controller!.text, isEmpty);
    await tester.enterText(fixed, '5');
    await tester.pump();

    await tester.tap(find.text("Share of what's left"));
    await tester.pump();
    final share = find.byKey(const ValueKey('share-field'));
    expect(tester.widget<TextField>(share).controller!.text, '100');

    await tester.tap(find.text('Fixed amount'));
    await tester.pump();
    expect(tester.widget<TextField>(fixed).controller!.text, '5');
  });

  testWidgets('the payout editor follows the "New payout" mockup', (
    tester,
  ) async {
    await _pump(tester, null, theme: buildTheme());
    expect(find.text('New payout'), findsOneWidget);
    expect(find.text('STEP 1/3'), findsOneWidget);
    for (final title in ['Who gets it', 'What they get', 'When']) {
      expect(find.text(title), findsOneWidget);
    }
    // The pixel heart leads "Who gets it"; coin and tombstone the others.
    PixelSprite? figureOf(String title) => tester
        .widget<PixelArt>(
          find.descendant(
            of: find.ancestor(of: find.text(title), matching: find.byType(Row)),
            matching: find.byType(PixelArt),
          ),
        )
        .sprite;
    expect(figureOf('Who gets it'), PixelSprites.heart);
    expect(figureOf('What they get'), EditorSprites.coin);
    expect(figureOf('When'), PixelSprites.tombstone);

    // Rails are radio cards with the fee schedule's rates.
    expect(find.byType(SelectCard), findsNWidgets(3));
    expect(find.text('2% fee'), findsOneWidget);
    expect(find.text('3% fee'), findsNWidgets(2));
    expect(find.textContaining('5% fee'), findsNothing);

    await _usdcPayout(tester);
    final preview = tester.widget<Text>(
      find
          .descendant(of: find.byType(LivePreview), matching: find.byType(Text))
          .first,
    );
    final amount = (preview.textSpan! as TextSpan).children!
        .cast<TextSpan>()
        .firstWhere((t) => t.style?.fontFamily?.contains('JetBrains') ?? false);
    expect(amount.text, '11.76 USDC');
    expect(amount.style?.fontWeight, FontWeight.w700);
    expect(
      find.textContaining(
        '30 days after your last check-in (after the 2% fee)',
      ),
      findsOneWidget,
    );

    await _tap(tester, 'Done');
    expect(find.text('STEP 1/3'), findsOneWidget);
    await _tap(tester, 'Next: fund the plan');
    expect(find.text('STEP 2/3'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a share-only plan starts with an empty deposit; a fixed one '
      'defaults to its sum', (tester) async {
    final sent = await _pump(tester, null);
    await _usdcPayout(tester);
    await tester.tap(find.text('Fixed amount'));
    await tester.pump();
    await tester.enterText(find.byKey(const ValueKey('fixed-field')), '2.5');
    await _settle(tester);
    await _tap(tester, 'Done');
    await _tap(tester, 'Next: fund the plan');

    expect(
      tester.widget<TextField>(_field('Put in this plan')).controller!.text,
      '2.5',
    );
    expect(find.text('In your wallet: 12 USDC'), findsOneWidget);
    expect(find.text('Your payouts add up to 2.5 USDC.'), findsOneWidget);

    await _tap(tester, 'Next: review');
    expect(find.text('Some money stays behind'), findsOneWidget);
    await _tap(tester, 'Create plan');
    expect(sent.single.tokens, {usdc: 2500000});
    expect(sent.single.rules.single.amount, 2500000);
    expect(sent.single.rules.single.mode, AmountMode.fixed);
  });

  testWidgets('a USDC payout with no deposit needs the checkbox', (
    tester,
  ) async {
    final sent = await _pump(tester, null);
    await _usdcPayout(tester);
    await _tap(tester, 'Done');
    await _tap(tester, 'Next: fund the plan');
    expect(
      tester.widget<TextField>(_field('Put in this plan')).controller!.text,
      isEmpty,
    );
    expect(find.text('Nothing to pay out'), findsOneWidget);

    await _tap(tester, 'Next: review');
    expect(find.text('Nothing to pay out'), findsOneWidget);
    await _tap(tester, 'Create plan');
    expect(sent, isEmpty);

    await _tap(
      tester,
      'Create it anyway. I understand the payouts marked '
      'with a red sign may never arrive.',
    );
    await _tap(tester, 'Create plan');
    expect(sent.single.tokens, isEmpty);
  });

  testWidgets('a deposit over the wallet or unparseable blocks Next', (
    tester,
  ) async {
    await _pump(tester, null);
    await _usdcPayout(tester);
    await _tap(tester, 'Done');
    await _tap(tester, 'Next: fund the plan');

    await tester.enterText(_field('Put in this plan'), '1.0000001');
    await tester.pump();
    expect(find.text('Check this amount'), findsOneWidget);
    await _tap(tester, 'Next: review');
    expect(find.text('Put in now'), findsNothing);

    await tester.enterText(_field('Put in this plan'), '50');
    await tester.pump();
    expect(find.text('Your wallet has only 12 USDC.'), findsOneWidget);
    await _tap(tester, 'Next: review');
    expect(find.text('Put in now'), findsNothing);

    await _tap(tester, 'Use all');
    await _tap(tester, 'Next: review');
    expect(find.text('Put in now'), findsOneWidget);
    expect(find.text('12 USDC'), findsOneWidget);
  });

  testWidgets('cancelling the first payout leaves the empty state; Next asks '
      'for a payout', (tester) async {
    await _pump(tester, null);
    await tester.tap(find.byTooltip('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Add your first payout'), findsOneWidget);
    // The empty state leads with the pack's heartbeat line.
    expect(
      find.descendant(
        of: find.byType(EmptyStateCard),
        matching: find.byWidgetPredicate(
          (w) => w is DMIcon && w.icon == DMIcons.heartbeat,
        ),
      ),
      findsOne,
    );
    await _tap(tester, 'Next: fund the plan');
    expect(find.text('Add at least one payout.'), findsOneWidget);
  });

  testWidgets('each payout only asks how long after the last check-in; '
      'Demo timings swap in minutes', (tester) async {
    final sent = await _pump(tester, null);
    expect(find.textContaining('check in every'), findsNothing);
    expect(
      find.text('Send after this long since your last check-in'),
      findsOneWidget,
    );
    for (final chip in ['7 days', '30 days', 'Custom']) {
      expect(find.widgetWithText(ChoiceChip, chip), findsOneWidget);
    }
    for (final chip in ['1 day', '14 days', '90 days', '1 year']) {
      expect(find.widgetWithText(ChoiceChip, chip), findsNothing);
    }
    expect(find.widgetWithText(ChoiceChip, '2 minutes'), findsNothing);
    expect(find.textContaining('sent in order of their wait'), findsOneWidget);
    await _usdcPayout(tester, share: '50');
    await _tap(tester, '7 days');
    await _tap(tester, 'Done');
    expect(find.text('Sent 7 days after your last check-in'), findsOneWidget);
    expect(find.textContaining('You check in every'), findsNothing);

    await _tap(tester, 'Advanced');
    await _tap(tester, 'Demo timings');
    await _tap(tester, "50% of what's left of your USDC");
    for (final chip in ['1 minute', '2 minutes', '5 minutes', '10 minutes']) {
      expect(find.widgetWithText(ChoiceChip, chip), findsOneWidget);
    }
    expect(find.widgetWithText(ChoiceChip, '30 days'), findsNothing);
    await _tap(tester, '2 minutes');
    await _tap(tester, 'Done');
    expect(
      find.text('Sent 2 minutes after your last check-in'),
      findsOneWidget,
    );

    await _tap(tester, 'Add a payout');
    await _usdcPayout(tester, who: 13);
    await _tap(tester, 'Done');
    expect(
      find.text('Sent 5 minutes after your last check-in'),
      findsOneWidget,
    );

    await _tap(tester, 'Next: fund the plan');
    await tester.enterText(_field('Put in this plan'), '10');
    await tester.pumpAndSettle();
    await _tap(tester, 'Next: review');
    expect(
      find.text(
        'Each payout is sent its own time after your last check-in. Any '
        'check-in restarts every clock.',
      ),
      findsOneWidget,
    );
    await _tap(tester, 'Create plan');
    expect(sent.single.rules.map((r) => r.afterSecs), [120, 300]);
  });

  testWidgets('Custom: any wait in days, hours or minutes, without demo '
      'timings', (tester) async {
    final sent = await _pump(tester, null);
    await _usdcPayout(tester);
    await _tap(tester, 'Custom');
    await tester.enterText(_field('Number'), '90');
    await tester.pumpAndSettle();
    await _tap(tester, 'days');
    await tester.tap(find.text('minutes').last);
    await tester.pumpAndSettle();
    expect(find.textContaining('Must be at least 1 minute'), findsNothing);
    await _tap(tester, 'Done');
    expect(
      find.text('Sent 90 minutes after your last check-in'),
      findsOneWidget,
    );
    await _tap(tester, 'Next: fund the plan');
    await tester.enterText(_field('Put in this plan'), '10');
    await tester.pumpAndSettle();
    await _tap(tester, 'Next: review');
    await _tap(tester, 'Create plan');
    expect(sent.single.rules.single.afterSecs, 90 * 60);
  });

  testWidgets('edit sends only the pending payouts; released ones are '
      'history', (tester) async {
    final v = vault(
      label: 'Kids',
      rules: [released, pending],
      skipGraceSecs: 7 * 86400,
      withdrawableLamports: 1000000000,
    );
    final sent = await _pump(tester, v);

    expect(find.text('Edit plan'), findsOneWidget);
    expect(find.text('STEP 1/2'), findsOneWidget);
    expect(find.text('Payout 1 · Released'), findsOneWidget);
    expect(find.text("Already paid. It won't pay again."), findsOneWidget);
    expect(find.text('Payout 2'), findsOneWidget);
    expect(find.text('Everything left of your SOL'), findsOneWidget);

    await _tap(tester, 'Advanced');
    await tester.ensureVisible(find.text('30 days').last);
    await tester.tap(find.text('30 days').last);
    await tester.pump();
    await _tap(tester, 'Next: review');
    expect(
      find.text(
        "Saving also counts as a check-in: every payout's clock restarts.",
      ),
      findsOneWidget,
    );
    await _tap(tester, 'Save changes');

    final s = sent.single;
    expect(s.rules, hasLength(1));
    expect(s.rules.single.beneficiary, pending.beneficiary);
    expect(s.rules.single.afterSecs, pending.afterSecs);
    expect(s.rules.single.amount, 10000);
    expect(s.skipGraceSecs, 30 * 86400);
  });

  testWidgets('a skipped payout is history: reserved, still claimable', (
    tester,
  ) async {
    final skipped = rule(
      seed: 13,
      afterSecs: 10 * 86400,
      amount: 5000,
      skippedAt: 950,
      reserved: 42,
    );
    final v = vault(
      rules: [released, skipped, pending],
      withdrawableLamports: 1000000000,
    );
    final sent = await _pump(tester, v);

    expect(find.text('Payout 1 · Released'), findsOneWidget);
    expect(
      find.text('Payout 2 · Skipped (reserved, still claimable)'),
      findsOneWidget,
    );
    expect(find.textContaining('set aside until'), findsOneWidget);
    expect(find.text('Payout 3'), findsOneWidget);

    await _tap(tester, 'Next: review');
    await _tap(tester, 'Save changes');
    expect(sent.single.rules.map((r) => r.beneficiary), [pending.beneficiary]);
  });

  testWidgets('a last payout under 100% shows L1 in Review; its action sets '
      '100%', (tester) async {
    final v = vault(
      rules: [rule(seed: 12, amount: 5000)],
      withdrawableLamports: 1000000000,
    );
    final sent = await _pump(tester, v);
    await _tap(tester, 'Next: review');
    expect(find.text('Some money stays behind'), findsOneWidget);
    expect(
      find.textContaining('0.5 SOL (50% of what the plan holds)'),
      findsOneWidget,
    );
    expect(find.text('Funds will be left behind'), findsNothing);

    await _tap(tester, 'Make the last payout "Everything left"');
    expect(find.text('Nothing of your SOL is left behind.'), findsOneWidget);
    await _tap(tester, 'Save changes');
    expect(sent.single.rules.single.amount, 10000);
  });

  testWidgets('editing a plan that holds none of a payout token needs the '
      'checkbox', (tester) async {
    final v = vault(rules: [rule(seed: 12, mint: usdc)]);
    final sent = await _pump(tester, v);
    expect(find.textContaining('This plan holds no USDC yet'), findsOneWidget);

    await _tap(tester, 'Next: review');
    expect(find.text('Nothing to pay out'), findsOneWidget);
    await _tap(tester, 'Save changes');
    expect(sent, isEmpty);
    await _tap(
      tester,
      'Save it anyway. I understand the payouts marked '
      'with a red sign may never arrive.',
    );
    await _tap(tester, 'Save changes');
    expect(sent, hasLength(1));
  });

  testWidgets('editing a plan that holds the token saves without asking', (
    tester,
  ) async {
    final v = vault(rules: [rule(seed: 12, mint: usdc)]);
    final api = FakeApi(const [])
      ..tokens['${v.address}:$usdc'] = 50000000
      ..tokens['${addr(12)}:$usdc'] = 1;
    final sent = await _pump(tester, v, api: api);
    await _tap(tester, 'Next: review');
    expect(find.text('Nothing to pay out'), findsNothing);
    expect(find.textContaining('≈\u00a049 USDC'), findsOneWidget);
    await _tap(tester, 'Save changes');
    expect(sent, hasLength(1));
  });

  testWidgets('the rail tiles show the fee of each rail', (tester) async {
    await _pump(
      tester,
      vault(rules: [pending], withdrawableLamports: 1000000000),
    );
    await _tap(tester, 'Everything left of your SOL');
    expect(find.text('2% fee'), findsOneWidget);
    expect(find.text('3% fee'), findsNWidgets(2));
    expect(find.text('5% fee'), findsNothing);
    expect(find.textContaining('Plus'), findsNothing);
  });

  testWidgets('a claim code picks its private rail', (tester) async {
    await _pump(tester, null);
    await tester.enterText(
      _field('Wallet address or claim code'),
      'zcash:${addr(12)}',
    );
    await tester.pump();
    expect(
      find.text(
        "Claim code recognised: they'll receive it privately via Zcash.",
      ),
      findsOneWidget,
    );
    expect(_field('Their claim code'), findsOneWidget);
  });

  testWidgets('the owner cannot be a beneficiary', (tester) async {
    await _pump(tester, null);
    await _usdcPayout(tester, who: 1);
    expect(find.text("That's your own wallet"), findsWidgets);
    await _tap(tester, 'Done');
    expect(find.text('New payout'), findsOneWidget);
  });

  testWidgets('back on the first step asks before discarding a new plan', (
    tester,
  ) async {
    await _pump(tester, null);
    await _usdcPayout(tester);
    await _tap(tester, 'Done');
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Discard this plan?'), findsOneWidget);
    await _tap(tester, 'Keep editing');
    expect(find.text('New inheritance plan'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await _tap(tester, 'Discard');
    expect(find.text('open'), findsOneWidget);
  });

  testWidgets('no overflow at 200% text on a phone', (tester) async {
    await _pump(
      tester,
      null,
      size: const Size(400, 860),
      textScale: 2,
      theme: buildTheme(),
    );
    await _usdcPayout(tester, share: '1');
    expect(tester.takeException(), isNull);
    await _tap(tester, 'Done');
    expect(tester.takeException(), isNull);
    await _tap(tester, 'Next: fund the plan');
    await tester.enterText(_field('Put in this plan'), '1');
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await _tap(tester, 'Next: review');
    expect(tester.takeException(), isNull);
  });

  testWidgets('brand: the whole create flow renders without purple', (
    tester,
  ) async {
    await _pump(tester, null, theme: buildTheme());
    await _usdcPayout(tester, share: '1');
    _expectNoPurple(tester);
    await _tap(tester, 'Done');
    _expectNoPurple(tester);
    await _tap(tester, 'Next: fund the plan');
    await tester.enterText(_field('Put in this plan'), '1');
    await tester.pumpAndSettle();
    _expectNoPurple(tester);
    await _tap(tester, 'Next: review');
    _expectNoPurple(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('brand: amounts and time labels read in mono', (tester) async {
    await _pump(tester, null, theme: buildTheme());
    await _usdcPayout(tester, share: '1');
    final share = tester.widget<TextField>(
      find.byKey(const ValueKey('share-field')),
    );
    expect(share.style?.fontFamily, contains('JetBrains'));
    await _tap(tester, 'Done');
    final when = tester.widget<Text>(
      find.text('Sent 30 days after your last check-in'),
    );
    expect(when.style?.fontFamily, contains('JetBrains'));
    await _tap(tester, 'Next: fund the plan');
    final deposit = tester.widget<TextField>(_field('Put in this plan'));
    expect(deposit.style?.fontFamily, contains('JetBrains'));
  });

  group('editor widgets', () {
    Future<void> host(WidgetTester tester, Widget child) => tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: Scaffold(body: SingleChildScrollView(child: child)),
      ),
    );

    testWidgets('step header announces steps and only goes back', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final taps = <int>[];
      await host(
        tester,
        StepHeader(
          labels: const ['Payouts', 'Fund', 'Review'],
          current: 1,
          onTap: taps.add,
        ),
      );
      expect(find.bySemanticsLabel('Step 2 of 3, Fund'), findsOneWidget);
      await tester.tap(find.bySemanticsLabel('Step 1 of 3, Payouts'));
      await tester.tap(find.bySemanticsLabel('Step 3 of 3, Review'));
      expect(taps, [0]);
      // The done step carries a check; the current one reads in bone.
      expect(find.byIcon(Icons.check), findsOneWidget);
      final now = tester.widget<Text>(find.text('Fund'));
      expect(now.style?.color, DM.bone);
      expect(now.style?.fontWeight, FontWeight.w600);
      expect(tester.widget<Text>(find.text('Review')).style?.color, DM.ash);
      handle.dispose();
    });

    testWidgets('selected chips sit on deep with a pulse label', (
      tester,
    ) async {
      await host(
        tester,
        Wrap(
          children: [
            pickChip(label: 'On', selected: true, onSelected: (_) {}),
            pickChip(label: 'Off', selected: false, onSelected: (_) {}),
          ],
        ),
      );
      final on = tester.widget<ChoiceChip>(
        find.widgetWithText(ChoiceChip, 'On'),
      );
      final off = tester.widget<ChoiceChip>(
        find.widgetWithText(ChoiceChip, 'Off'),
      );
      expect(on.labelStyle?.color, DM.pulse);
      expect(on.side?.color, DM.pulse);
      expect(off.labelStyle?.color, DM.bone);
      expect(on.showCheckmark, isFalse);
      expect(
        Theme.of(tester.element(find.text('On'))).chipTheme.selectedColor,
        DM.deep,
      );
    });

    testWidgets('rail tiles are radio cards: deep + pulse when selected', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await host(
        tester,
        Column(
          children: [
            RailOptionTile(
              rail: Rail.cloak,
              selected: true,
              onTap: () {},
              feeLine: '3% fee',
            ),
            RailOptionTile(
              rail: Rail.zcash,
              selected: false,
              onTap: () {},
              feeLine: '3% fee',
              badge: 'mainnet only',
            ),
          ],
        ),
      );
      final cards = tester
          .widgetList<SelectCard>(find.byType(SelectCard))
          .toList();
      expect(cards.map((c) => c.selected), [true, false]);
      expect(cards.map((c) => c.title), [
        'Private (Cloak)',
        'Private as Zcash',
      ]);
      final materials = tester
          .widgetList<Material>(
            find.descendant(
              of: find.byType(SelectCard),
              matching: find.byType(Material),
            ),
          )
          .map((m) => m.color)
          .toList();
      expect(materials, containsAllInOrder([DM.deep, DM.grave]));
      // The selected card's fee line is pulse, in mono.
      final fee = tester.widget<Text>(find.text('3% fee').first);
      expect(fee.style?.color, DM.pulse);
      expect(fee.style?.fontFamily, contains('JetBrains'));
      final tag = tester.widget<Text>(find.text('mainnet only'));
      expect(tag.style?.fontFamily, contains('JetBrains'));
      expect(
        tester.getSemantics(find.byType(SelectCard).first),
        isSemantics(
          isInMutuallyExclusiveGroup: true,
          hasCheckedState: true,
          isChecked: true,
          hasTapAction: true,
        ),
      );
      _expectNoPurple(tester);
      handle.dispose();
    });

    testWidgets('rail fee lines come from the fee schedule', (tester) async {
      final fees = FeeSchedule(
        treasury: addr(9),
        feeBpsPublic: 200,
        feeBpsPrivate: 300,
      );
      expect(railFeeLine(FeeInfo(fees: fees), Rail.solana), '2% fee');
      expect(railFeeLine(FeeInfo(fees: fees), Rail.cloak), '3% fee');
      expect(railFeeLine(FeeInfo(fees: fees), Rail.zcash), '3% fee');
      final skr = FeeInfo(
        fees: FeeSchedule(
          treasury: addr(9),
          feeBpsPublic: 200,
          feeBpsPrivate: 300,
          skrMint: AppConfig.skrMint,
          feeBpsSkr: 150,
          skrBurnBps: 1000,
        ),
      );
      expect(
        railFeeLine(skr, Rail.cloak, AppConfig.skrMint),
        '1.5% fee · 10% burned',
      );
      expect(railFeeLine(skr, Rail.cloak, AppConfig.usdcMint), '3% fee');
    });

    testWidgets('step sticker is a pixel word that reads "Step n of m"', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await host(tester, const StepSticker(step: 1, of: 3));
      final word = tester.widget<Text>(find.text('STEP 1/3'));
      expect(word.style?.fontFamily, contains('Silkscreen'));
      expect(find.bySemanticsLabel('Step 1 of 3'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('labeled fields read label and input as one node', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await host(
        tester,
        const LabeledField(label: 'Plan name', child: TextField()),
      );
      final node = tester.getSemantics(find.byType(TextField));
      expect(node.label, contains('Plan name'));
      expect(node, isSemantics(isTextField: true));
      handle.dispose();
    });

    testWidgets('rail chip is an outlined tag with the short name', (
      tester,
    ) async {
      await host(tester, const RailChip(Rail.cloak));
      expect(find.byType(DMTag), findsOneWidget);
      expect(find.text('Cloak'), findsOneWidget);
    });

    testWidgets('warnings: status on the icon and title only; fix is pulse', (
      tester,
    ) async {
      var fixed = 0;
      await host(
        tester,
        WarningTile.of(
          const PlanIssue(
            IssueCode.a1,
            Severity.danger,
            title: 'Too small to arrive',
            body: 'It would never arrive.',
            action: 'Use 100%',
          ),
          onAction: () => fixed++,
        ),
      );
      final box = tester.widget<Container>(
        find
            .descendant(
              of: find.byType(WarningTile),
              matching: find.byType(Container),
            )
            .first,
      );
      expect((box.decoration! as BoxDecoration).color, DM.raise);
      expect(
        tester.widget<Icon>(find.byIcon(Icons.error_outline)).color,
        DM.flatline,
      );
      expect(
        tester.widget<Text>(find.text('Too small to arrive')).style?.color,
        DM.flatline,
      );
      await tester.tap(find.text('Use 100%'));
      expect(fixed, 1);
      expect(severityColor(Severity.warn), DM.missed);
      expect(severityColor(Severity.info), DM.dust);
    });

    testWidgets('cost rows can set amounts in mono', (tester) async {
      await host(
        tester,
        const Column(
          children: [
            CostRow('Put in now', '1 USDC', mono: true),
            CostRow('Release fee', '2% of each normal payout'),
          ],
        ),
      );
      expect(
        tester.widget<Text>(find.text('1 USDC')).style?.fontFamily,
        contains('JetBrains'),
      );
      expect(
        tester
            .widget<Text>(find.text('2% of each normal payout'))
            .style
            ?.fontFamily,
        contains('Outfit'),
      );
    });
  });
}

/// Lockdown purple is reserved for duress; the editors never show it.
void _expectNoPurple(WidgetTester tester) {
  const banned = [Color(0xFFA493FF), Color(0xFF8B5CF6), Color(0xFFA78BFA)];
  final colors = <Color?>[
    for (final w in tester.allWidgets)
      ...switch (w) {
        Icon(:final color) => [color],
        Text(:final style) => [style?.color],
        Material(:final color) => [color],
        DecoratedBox(:final decoration) when decoration is BoxDecoration => [
          decoration.color,
        ],
        Container(:final decoration) when decoration is BoxDecoration => [
          decoration.color,
        ],
        _ => const <Color?>[],
      },
  ];
  for (final c in colors.nonNulls) {
    expect(banned.contains(c), isFalse, reason: 'purple $c in the editor');
  }
}
