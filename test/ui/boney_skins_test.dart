import 'dart:io';
import 'dart:ui' as ui;

import 'package:deadman/state/boney.dart';
import 'package:deadman/state/boney_skin.dart';
import 'package:deadman/state/boney_skins.dart';
import 'package:deadman/state/providers.dart';
import 'package:deadman/ui/widgets/boney_skins.dart';
import 'package:deadman/ui/widgets/brand/boney_skin_art.dart';
import 'package:deadman/ui/widgets/brand/brand.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Widget _host(Widget child) => MediaQuery(
  data: const MediaQueryData(),
  child: Directionality(
    textDirection: TextDirection.ltr,
    child: Center(child: child),
  ),
);

List<PixelArt> _layers(WidgetTester tester) =>
    tester.widgetList<PixelArt>(find.byType(PixelArt)).toList();

void main() {
  test('every skin fits Boney\'s grid', () {
    for (final s in BoneySkin.values) {
      final art = s.art;
      expect(art.ink.width, 26, reason: s.id);
      expect(art.ink.height, 24, reason: s.id);
      final shade = art.shade;
      if (shade != null) {
        expect(shade.width, 26);
        expect(shade.height, 24);
      }
    }
  });

  test('the skin follows his head: every widget pose keeps it in place, the '
      'idle loop moves it', () {
    for (final m in BoneyMood.values) {
      if (m == BoneyMood.released) continue;
      // The Android widget draws skins unshifted: keep these at (0, 0).
      expect(skullShift(m.pose.layers.first.sprite), (0, 0), reason: m.wire);
    }
    expect(skullShift(BoneyPose.releasedGhost.layers.first.sprite), (-1, -3));
    expect(
      [for (final f in boneyIdle) skullShift(f.sprite)],
      [(0, 0), (0, -1), (1, -1), (0, -1), (-1, -1)],
    );
  });

  testWidgets('worn in his status colour, with a dark shade', (tester) async {
    await tester.pumpWidget(
      _host(
        const BoneyFigure(
          mood: BoneyMood.tierDue,
          animate: false,
          skin: BoneySkin.cap,
        ),
      ),
    );
    final layers = _layers(tester);
    expect(layers.map((l) => l.sprite), [
      BoneyPose.tierDue.layers.first.sprite,
      BoneySkin.cap.art.shade,
      BoneySkin.cap.art.ink,
    ]);
    expect(layers[1].color, DM.void_);
    expect(layers[2].color, DM.flatline);
    expect(find.byKey(const ValueKey('boney-tier_due-cap')), findsOneWidget);
  });

  testWidgets('a crown has no shade', (tester) async {
    await tester.pumpWidget(
      _host(
        const BoneyFigure(
          mood: BoneyMood.onTrack,
          animate: false,
          skin: BoneySkin.crown,
        ),
      ),
    );
    expect(_layers(tester).map((l) => l.color), [DM.pulse, DM.pulse]);
  });

  testWidgets('the released ghost wears none', (tester) async {
    await tester.pumpWidget(
      _host(
        const BoneyFigure(
          mood: BoneyMood.released,
          animate: false,
          skin: BoneySkin.glasses,
        ),
      ),
    );
    expect(_layers(tester), hasLength(2));
    expect(
      _layers(tester).any((l) => l.sprite == BoneySkin.glasses.art.ink),
      isFalse,
    );
  });

  test('the Android widget draws the same art', () async {
    for (final s in BoneySkin.values) {
      final art = s.art;
      await _expectPng(
        'android/app/src/main/res/drawable-nodpi/boney_skin_${s.id}.png',
        art.ink,
        const Color(0xFFFFFFFF),
      );
      expect(
        File('android/app/src/main/res/drawable/boney_px_skin_${s.id}.xml')
            .existsSync(),
        isTrue,
      );
      final shade = art.shade;
      if (shade != null) {
        await _expectPng(
          'android/app/src/main/res/drawable-nodpi/boney_skin_${s.id}_shade.png',
          shade,
          DM.void_,
        );
      }
    }
    final kotlin = File(
      'android/app/src/main/kotlin/app/deadman/seeker/BoneyWidget.kt',
    ).readAsStringSync();
    expect(kotlin, contains('"$boneySkinKey"'));
    for (final s in BoneySkin.values) {
      expect(kotlin, contains('"${s.id}"'));
    }
  });

  group('picker', () {
    Future<SharedPreferences> pump(
      WidgetTester tester,
      Set<BoneySkin> owned,
    ) async {
      tester.view.physicalSize = const Size(600, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            prefsProvider.overrideWithValue(prefs),
            boneyHostProvider.overrideWithValue(null),
            ownedSkinsProvider.overrideWith((ref) async => owned),
          ],
          child: const MaterialApp(
            home: Scaffold(
              body: Column(
                children: [
                  SkinnedBoney(mood: BoneyMood.onTrack, size: 72),
                  BoneySkinPicker(mood: BoneyMood.onTrack),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return prefs;
    }

    BoneySkin? worn(WidgetTester tester) => tester
        .widget<BoneyFigure>(
          find.descendant(
            of: find.byType(SkinnedBoney),
            matching: find.byType(BoneyFigure),
          ),
        )
        .skin;

    testWidgets('an owned skin goes on; a locked one says which NFT', (
      tester,
    ) async {
      final prefs = await pump(tester, {BoneySkin.crown});
      expect(worn(tester), isNull);
      expect(
        find.text(
          'Hold a Boney Cap, Glasses NFT to unlock them. Boney wears your '
          'skin on the home-screen widget too.',
        ),
        findsOneWidget,
      );
      expect(find.bySemanticsLabel('Cap, locked'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('skin-crown')));
      await tester.pumpAndSettle();
      expect(worn(tester), BoneySkin.crown);
      expect(prefs.getString(boneySkinKey), 'crown');

      await tester.tap(find.byKey(const ValueKey('skin-cap')));
      await tester.pumpAndSettle();
      expect(worn(tester), BoneySkin.crown);

      await tester.tap(find.text('None'));
      await tester.pumpAndSettle();
      expect(worn(tester), isNull);
      expect(prefs.getString(boneySkinKey), isNull);
    });

    testWidgets('all unlocked', (tester) async {
      await pump(tester, BoneySkin.values.toSet());
      expect(find.textContaining('Every skin unlocked'), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp(r', locked$')), findsNothing);
    });
  });
}

/// [path] is [sprite] at 4 px a cell: [color] where it is filled, clear
/// elsewhere.
Future<void> _expectPng(String path, PixelSprite sprite, Color color) async {
  final codec = await ui.instantiateImageCodec(File(path).readAsBytesSync());
  final image = (await codec.getNextFrame()).image;
  expect(image.width, sprite.width * 4, reason: path);
  expect(image.height, sprite.height * 4, reason: path);
  final bytes = (await image.toByteData())!;
  for (var y = 0; y < sprite.height; y++) {
    for (var x = 0; x < sprite.width; x++) {
      final i = ((y * 4 + 2) * image.width + x * 4 + 2) * 4;
      final filled = sprite.rows[y][x] == '#';
      expect(bytes.getUint8(i + 3), filled ? 255 : 0, reason: '$path $x,$y');
      if (filled) {
        expect(
          Color.fromARGB(
            255,
            bytes.getUint8(i),
            bytes.getUint8(i + 1),
            bytes.getUint8(i + 2),
          ),
          color,
          reason: '$path $x,$y',
        );
      }
    }
  }
}
