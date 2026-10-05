import 'package:deadman/state/lockdown_retry.dart';
import 'package:deadman/state/providers.dart';
import 'package:deadman/state/secure_store.dart';
import 'package:deadman/ui/screens/lock_screen.dart';
import 'package:deadman/ui/screens/pin_setup_screen.dart';
import 'package:deadman/ui/screens/recovery_phrase_screen.dart';
import 'package:deadman/ui/theme.dart';
import 'package:deadman/ui/widgets/brand/brand.dart';
import 'package:deadman/ui/widgets/feedback.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../state/fakes.dart';

/// PINs in memory: [savedPin] opens normally, [savedDuress] under duress.
class _PinStore extends FakeSecureStore {
  String? savedPin;
  String? savedDuress;
  bool confirmedPhrase = false;

  @override
  Future<bool> hasPins() async => savedPin != null;

  @override
  Future<void> setPins({required String pin, required String duressPin}) async {
    savedPin = pin;
    savedDuress = duressPin;
  }

  @override
  Future<PinCheck> checkPin(String value) async => value == savedPin
      ? PinCheck.normal
      : value == savedDuress
      ? PinCheck.duress
      : PinCheck.wrong;

  @override
  Future<void> markPhraseConfirmed() async => confirmedPhrase = true;
}

class _Harness {
  final store = _PinStore();
  final lockdowns = <String>[];
  late ProviderContainer container;

  Future<void> pump(WidgetTester tester, Widget child) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({'owner': addr(1)});
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          prefsProvider.overrideWithValue(prefs),
          isWebProvider.overrideWithValue(false),
          secureStoreProvider.overrideWithValue(store),
          lockdownRetrierProvider.overrideWithValue(
            LockdownRetrier(
              pending: PendingLockdown(prefs),
              attempt: (owner) async => lockdowns.add(owner),
            ),
          ),
        ],
        child: MaterialApp(theme: buildTheme(), home: child),
      ),
    );
    container = ProviderScope.containerOf(tester.element(find.byWidget(child)));
    await tester.pump();
  }
}

Future<void> _enter(WidgetTester tester, String pin) async {
  for (final d in pin.split('')) {
    await tester.tap(find.widgetWithText(TextButton, d));
    await tester.pump();
  }
  await tester.pumpAndSettle();
}

void main() {
  group('PIN setup', () {
    testWidgets('PIN, confirm, then a different duress PIN', (tester) async {
      final h = _Harness();
      var done = false;
      await h.pump(tester, PinSetupScreen(onDone: () => done = true));
      expect(find.text('Choose your PIN'), findsOneWidget);
      expect(find.bySemanticsLabel('Step 1 of 3'), findsOneWidget);
      expect(find.text('STEP 1/3'), findsOneWidget);

      await _enter(tester, '123456');
      expect(find.text('Confirm your PIN'), findsOneWidget);
      expect(find.bySemanticsLabel('Step 2 of 3'), findsOneWidget);
      expect(find.text('STEP 2/3'), findsOneWidget);

      await _enter(tester, '123456');
      expect(find.text('Choose a duress PIN'), findsOneWidget);
      expect(find.bySemanticsLabel('Step 3 of 3'), findsOneWidget);
      expect(find.textContaining('silently locked down'), findsOneWidget);

      await _enter(tester, '123456');
      expect(find.text('Duress PIN must differ from your PIN'), findsOneWidget);
      expect(find.byKey(const ValueKey('toast-error')), findsOneWidget);
      expect(h.store.savedPin, isNull);

      await _enter(tester, '654321');
      expect(h.store.savedPin, '123456');
      expect(h.store.savedDuress, '654321');
      expect(done, isTrue);
      expect(h.container.read(sessionProvider).unlocked, isTrue);
      expect(h.container.read(sessionProvider).duress, isFalse);
    });

    testWidgets('a mismatch starts over', (tester) async {
      final h = _Harness();
      await h.pump(tester, PinSetupScreen(onDone: () {}));
      await _enter(tester, '123456');
      await _enter(tester, '111111');
      expect(find.text('PINs do not match'), findsOneWidget);
      expect(find.text('Choose your PIN'), findsOneWidget);
    });

    testWidgets('the duress step uses no status color', (tester) async {
      final h = _Harness();
      await h.pump(tester, PinSetupScreen(onDone: () {}));
      await _enter(tester, '123456');
      await _enter(tester, '123456');
      for (final icon in tester.widgetList<Icon>(find.byType(Icon))) {
        expect(icon.color, isNot(DM.missed));
        expect(icon.color, isNot(DM.flatline));
      }
      for (final s in tester.widgetList<Sticker>(find.byType(Sticker))) {
        expect(s.color, DM.pulse);
      }
    });
  });

  group('lock screen', () {
    testWidgets('a wrong PIN stays locked', (tester) async {
      final h = _Harness()..store.savedPin = '123456';
      h.store.savedDuress = '999999';
      await h.pump(tester, const LockScreen());
      expect(find.text('Enter PIN'), findsOneWidget);
      await _enter(tester, '000000');
      expect(h.container.read(sessionProvider).unlocked, isFalse);
      expect(find.bySemanticsLabel('0 of 6 digits entered'), findsOneWidget);
    });

    testWidgets('the PIN unlocks a normal session', (tester) async {
      final h = _Harness()..store.savedPin = '123456';
      h.store.savedDuress = '999999';
      await h.pump(tester, const LockScreen());
      await _enter(tester, '123456');
      final s = h.container.read(sessionProvider);
      expect(s.unlocked, isTrue);
      expect(s.duress, isFalse);
      expect(h.lockdowns, isEmpty);
    });

    testWidgets('the duress PIN unlocks and silently starts the lockdown', (
      tester,
    ) async {
      final h = _Harness()..store.savedPin = '123456';
      h.store.savedDuress = '999999';
      await h.pump(tester, const LockScreen());
      await _enter(tester, '999999');
      final s = h.container.read(sessionProvider);
      expect(s.unlocked, isTrue);
      expect(s.duress, isTrue);
      expect(h.lockdowns, [addr(1)]);
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('the skull lockup heads the screen, with no step sticker', (
      tester,
    ) async {
      await _Harness().pump(tester, const LockScreen());
      expect(find.byType(DeadmanLockup), findsOneWidget);
      expect(find.bySemanticsLabel('Deadman'), findsOneWidget);
      expect(find.byType(Sticker), findsNothing);
    });

    testWidgets('digits are mono keys; delete has a label', (tester) async {
      await _Harness().pump(tester, const LockScreen());
      final key = tester.widget<Text>(
        find.descendant(
          of: find.widgetWithText(TextButton, '5'),
          matching: find.text('5'),
        ),
      );
      expect(key.style?.fontFamily, contains('JetBrains'));
      expect(find.byTooltip('Delete digit'), findsOneWidget);
    });
  });

  group('recovery phrase', () {
    const phrase =
        'one two three four five six seven eight nine ten eleven twelve';

    testWidgets('reads down the left column, then the right', (tester) async {
      await _Harness().pump(tester, const RecoveryPhrasePage(phrase: phrase));
      Offset at(int i) =>
          tester.getTopLeft(find.byKey(ValueKey('phrase-word-$i')));
      expect(at(2).dy, greaterThan(at(1).dy));
      expect(at(7).dy, at(1).dy);
      expect(at(7).dx, greaterThan(at(1).dx));
      expect(find.text('07'), findsOneWidget);
      expect(find.text('Done'), findsOneWidget);
      // The app bar names the page once; no second heading repeats it.
      expect(find.text('Recovery phrase'), findsOneWidget);
      expect(find.textContaining('Your recovery phrase'), findsNothing);
    });

    testWidgets('first time: no way back until confirmed', (tester) async {
      final h = _Harness();
      await h.pump(
        tester,
        Builder(
          builder: (context) => TextButton(
            onPressed: () =>
                RecoveryPhrasePage.show(context, phrase, firstTime: true),
            child: const Text('open'),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.byType(BackButton), findsNothing);
      expect(find.byType(CloseButton), findsNothing);
      await tester.tap(find.text('I wrote it down'));
      await tester.pumpAndSettle();
      expect(h.store.confirmedPhrase, isTrue);
      expect(find.text('open'), findsOneWidget);
    });
  });

  group('toast', () {
    testWidgets('a sprite leads a success message in pulse', (tester) async {
      await _Harness().pump(
        tester,
        Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => toast(
                context,
                'Pulse recorded on 2 plans.',
                sprite: PixelSprites.heart,
              ),
              child: const Text('ok'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('ok'));
      await tester.pump();
      final art = tester.widget<PixelArt>(
        find.descendant(
          of: find.byType(SnackBar),
          matching: find.byType(PixelArt),
        ),
      );
      expect(art.sprite, PixelSprites.heart);
      expect(art.color, DM.pulse);
      expect(art.semanticLabel, isNull);
      expect(find.text('Pulse recorded on 2 plans.'), findsOneWidget);
    });

    testWidgets('errors keep the raise bar and mark it with a flatline icon', (
      tester,
    ) async {
      await _Harness().pump(
        tester,
        Scaffold(
          body: Builder(
            builder: (context) => Column(
              children: [
                TextButton(
                  onPressed: () => toast(context, 'Saved'),
                  child: const Text('ok'),
                ),
                TextButton(
                  onPressed: () => toast(context, 'It failed', error: true),
                  child: const Text('fail'),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.tap(find.text('ok'));
      await tester.pump();
      expect(find.text('Saved'), findsOneWidget);
      expect(find.byIcon(Icons.error_outline), findsNothing);

      await tester.tap(find.text('fail'));
      await tester.pumpAndSettle();
      final bar = tester.widget<SnackBar>(find.byType(SnackBar));
      expect(bar.backgroundColor, isNull);
      expect(find.text('It failed'), findsOneWidget);
      final icon = tester.widget<Icon>(find.byIcon(Icons.error_outline));
      expect(icon.color, DM.flatline);
      expect(find.byType(PixelArt), findsNothing);
    });
  });
}
