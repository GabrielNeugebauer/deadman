import 'dart:async';

import 'package:deadman/state/providers.dart';
import 'package:deadman/ui/app.dart';
import 'package:deadman/ui/screens/welcome_screen.dart';
import 'package:deadman/ui/widgets/brand/brand.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../state/fakes.dart';

/// A PIN store that answers [hasPins] only when told to.
class _SlowStore extends FakeSecureStore {
  final pins = Completer<bool>();

  @override
  Future<bool> hasPins() => pins.future;
}

Future<_SlowStore> _pumpApp(
  WidgetTester tester, {
  Map<String, Object> saved = const {},
}) async {
  tester.view.physicalSize = const Size(412, 915);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues(saved);
  final prefs = await SharedPreferences.getInstance();
  final store = _SlowStore();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        prefsProvider.overrideWithValue(prefs),
        isWebProvider.overrideWithValue(false),
        secureStoreProvider.overrideWithValue(store),
      ],
      child: const DeadmanApp(),
    ),
  );
  await tester.pump();
  return store;
}

void main() {
  testWidgets('no wallet yet: the welcome screen', (tester) async {
    await _pumpApp(tester);
    expect(find.byType(WelcomeScreen), findsOneWidget);
    expect(find.byType(SplashScreen), findsNothing);
  });

  testWidgets('while the PIN store opens: the brand splash', (tester) async {
    await _pumpApp(tester, saved: {'owner': addr(1)});
    expect(find.byType(SplashScreen), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    final lockup = tester.widget<DeadmanLockup>(find.byType(DeadmanLockup));
    expect(lockup.stacked, isTrue);
    // Page 6: the splash skull wears the alive face.
    expect(
      tester.widget<SkullMark>(find.byType(SkullMark)).mood,
      SkullMood.alive,
    );
    expect(find.bySemanticsLabel('Deadman'), findsOneWidget);
    expect(find.text('Proof of life, on Solana'), findsOneWidget);
    // The skull sits above the foot line, centred.
    final skull = tester.getRect(find.byType(SkullMark));
    expect(skull.center.dx, closeTo(206, 1));
    expect(
      skull.bottom,
      lessThan(tester.getTopLeft(find.text('Proof of life, on Solana')).dy),
    );
  });

  testWidgets('a store failure shows on the splash, in place of the line', (
    tester,
  ) async {
    final store = await _pumpApp(tester, saved: {'owner': addr(1)});
    store.pins.completeError(StateError('Keystore unavailable'));
    await tester.pump();
    await tester.pump();
    expect(find.byType(SplashScreen), findsOneWidget);
    expect(find.text('Proof of life, on Solana'), findsNothing);
    final error = tester.widget<Text>(
      find.byKey(const ValueKey('splash-error')),
    );
    expect(error.data, contains('Keystore unavailable'));
  });

  testWidgets('no PINs yet: PIN setup with the step sticker', (tester) async {
    final store = await _pumpApp(tester, saved: {'owner': addr(1)});
    store.pins.complete(false);
    await tester.pump();
    await tester.pump();
    expect(find.text('Choose your PIN'), findsOneWidget);
    expect(find.text('STEP 1/3'), findsOneWidget);
  });
}
