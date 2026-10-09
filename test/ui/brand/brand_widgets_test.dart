// The deprecated v1 names are exercised on purpose: screens still use them.
// ignore_for_file: deprecated_member_use_from_same_package

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:deadman/ui/theme.dart';
import 'package:deadman/ui/widgets/brand/brand.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';

Widget _host(Widget child) => MaterialApp(
  theme: buildTheme(),
  home: Scaffold(
    body: Center(
      child: Padding(padding: const EdgeInsets.all(20), child: child),
    ),
  ),
);

/// Renders [child] at 1x and returns its pixels (RGBA).
Future<(ByteData, int)> _pixels(WidgetTester tester, Widget child) async {
  final key = GlobalKey();
  await tester.pumpWidget(
    MediaQuery(
      data: const MediaQueryData(devicePixelRatio: 1),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Align(
          alignment: Alignment.topLeft,
          child: RepaintBoundary(
            key: key,
            child: ColoredBox(color: DM.void_, child: child),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  return (await tester.runAsync(() async {
    final image = await boundary.toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    final width = image.width;
    image.dispose();
    return (bytes!, width);
  }))!;
}

Color _at((ByteData, int) img, int x, int y) {
  final (bytes, width) = img;
  final i = (y * width + x) * 4;
  return Color.fromARGB(
    bytes.getUint8(i + 3),
    bytes.getUint8(i),
    bytes.getUint8(i + 1),
    bytes.getUint8(i + 2),
  );
}

void main() {
  group('theme', () {
    test('maps the v2 palette onto the color scheme', () {
      final theme = buildTheme();
      expect(theme.scaffoldBackgroundColor, const Color(0xFF0A0B0D));
      expect(theme.colorScheme.primary, const Color(0xFF3EF5A8));
      expect(theme.colorScheme.onPrimary, DM.void_);
      expect(theme.colorScheme.surface, const Color(0xFF16181C));
      expect(theme.colorScheme.onSurface, const Color(0xFFF1F0EA));
      expect(theme.colorScheme.error, const Color(0xFFFF4D5E));
      expect(theme.colorScheme.secondaryContainer, DM.deep);
      expect(theme.navigationBarTheme.indicatorColor, DM.deep);
      expect(theme.inputDecorationTheme.fillColor, DM.pit);
      // The app keeps its own type; Silkscreen stays out of the text theme.
      expect(theme.textTheme.headlineMedium?.fontFamily, contains('Outfit'));
      expect(theme.textTheme.bodyMedium?.fontFamily, contains('Outfit'));
    });

    test('brand book colors are exact', () {
      expect(DM.void_, const Color(0xFF0A0B0D));
      expect(DM.grave, const Color(0xFF16181C));
      expect(DM.bone, const Color(0xFFF1F0EA));
      expect(DM.pulse, const Color(0xFF3EF5A8));
      expect(DM.missed, const Color(0xFFFFB547));
      expect(DM.flatline, const Color(0xFFFF4D5E));
      expect(DM.ash, const Color(0xFF8B8F98));
    });

    test('v1 token names resolve to v2 colors', () {
      expect(DM.signal, DM.pulse);
      expect(DM.graphite, DM.grave);
      expect(DM.attention, DM.missed);
      expect(DM.due, DM.flatline);
      expect(DM.mist, DM.ash);
      expect(DmColors.alive, DM.pulse);
      expect(DmColors.bg, DM.void_);
    });

    test('nothing in the palette is purple', () {
      for (final c in [DM.locked, DM.tide, DM.deep]) {
        final hsl = HSLColor.fromColor(c);
        final purple = hsl.saturation > 0.2 && hsl.hue > 250 && hsl.hue < 320;
        expect(purple, isFalse, reason: '$c');
      }
    });

    test('fonts come from the bundle, never fetched at runtime', () {
      buildTheme();
      expect(GoogleFonts.config.allowRuntimeFetching, isFalse);
    });

    testWidgets('bundled Outfit, JetBrains Mono and Silkscreen load', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          Column(
            children: [
              const Text('Pulse'),
              Text('1m 55s', style: DMType.countdown(DM.pulse)),
              Text('CHECK IN, OR CHECK OUT.', style: DMType.tagline()),
            ],
          ),
        ),
      );
      await expectLater(GoogleFonts.pendingFonts(), completes);
      final tagline = tester.widget<Text>(find.text('CHECK IN, OR CHECK OUT.'));
      expect(tagline.style?.fontFamily, contains('Silkscreen'));
    });
  });

  group('status', () {
    test('statusForWindow: alive until the release, then due', () {
      expect(statusForWindow(0.8), DMStatus.alive);
      expect(statusForWindow(0.1), DMStatus.alive);
      expect(statusForWindow(0), DMStatus.due);
      expect(statusForWindow(0.9, releasing: true), DMStatus.due);
      expect(
        statusForWindow(0, releasing: true, locked: true),
        DMStatus.locked,
      );
    });

    test('each status has its brand color, word and figure', () {
      expect(DMStatus.alive.color, DM.pulse);
      expect(DMStatus.missed.color, DM.missed);
      expect(DMStatus.due.color, DM.flatline);
      expect(DMStatus.released.color, DM.ash);
      expect(DMStatus.locked.color, DM.bone);
      expect(DMStatus.alive.label, 'ALIVE');
      expect(DMStatus.missed.label, 'MISSED');
      expect(DMStatus.due.label, 'TIER DUE');
      expect(DMStatus.released.label, 'RELEASED');
      expect(DMStatus.locked.label, 'LOCKED');
      expect(DMStatus.alive.sprite, PixelSprites.skull);
      expect(DMStatus.missed.sprite, PixelSprites.skullMissed);
      expect(DMStatus.due.sprite, PixelSprites.skullDue);
      expect(DMStatus.released.sprite, PixelSprites.ghost);
      expect(DMStatus.locked.sprite, PixelSprites.lock);
      expect(DMStatus.missed.mood, SkullMood.missed);
      expect(DMStatus.due.tint.a, closeTo(0.13, 0.01));
      expect(DMStatus.due.dimTick.a, closeTo(0.33, 0.01));
      expect(DMStatus.alive.dimTick, DM.line);
    });

    test('v1 status names alias the v2 values', () {
      expect(DMStatus.onTrack, DMStatus.alive);
      expect(DMStatus.attention, DMStatus.missed);
    });
  });

  group('pixel sprites', () {
    const all = [
      PixelSprites.skull,
      PixelSprites.skullAlive,
      PixelSprites.skullMissed,
      PixelSprites.skullDue,
      PixelSprites.skullReleased,
      PixelSprites.heart,
      PixelSprites.tombstone,
      PixelSprites.ghost,
      PixelSprites.lock,
      PixelSprites.wordmark,
    ];

    test('every grid is rectangular', () {
      for (final s in all) {
        for (final row in s.rows) {
          expect(row.length, s.width, reason: s.name);
          expect(RegExp(r'^[#.]+$').hasMatch(row), isTrue, reason: s.name);
        }
      }
      expect(PixelSprites.skull.width, 11);
      expect(PixelSprites.skull.height, 11);
      expect(PixelSprites.heart.height, 10);
      expect(PixelSprites.tombstone.height, 12);
      expect(PixelSprites.wordmark.width, 41);
      expect(PixelSprites.wordmark.height, 7);
    });

    test('the four moods share one skull outline', () {
      String outline(String row) {
        final a = row.indexOf('#'), b = row.lastIndexOf('#');
        return '$a-$b';
      }

      for (final mood in SkullMood.values) {
        final s = PixelSprites.forMood(mood);
        for (var y = 0; y < 11; y++) {
          expect(
            outline(s.rows[y]),
            outline(PixelSprites.skull.rows[y]),
            reason: '${s.name} row $y',
          );
        }
        // Teeth and jaw never change.
        expect(s.rows.sublist(8), PixelSprites.skull.rows.sublist(8));
      }
    });

    test('runs merge adjacent cells', () {
      // Row 0 of the skull is one run of five cells.
      expect(PixelSprites.skull.runs.first, (0, 3, 5));
      // Teeth row: four single cells.
      expect(PixelSprites.skull.runs.where((r) => r.$1 == 10).length, 4);
    });

    test('cells snap to whole device pixels', () {
      // 24 tall at 1x: 2px cells, 22px skull.
      expect(PixelArt.cellFor(PixelSprites.skull, 24, 1), 2);
      // 24 tall at 2.75x: 66 device px / 11 = 6 px cells.
      expect(PixelArt.cellFor(PixelSprites.skull, 24, 2.75), 6 / 2.75);
      // Never below one device pixel.
      expect(PixelArt.cellFor(PixelSprites.skull, 4, 1), 1);
    });

    testWidgets('PixelArt sizes itself from the snapped cell', (tester) async {
      await tester.pumpWidget(
        _host(const PixelArt(PixelSprites.skull, size: 24)),
      );
      // Test view is 3x: floor(72 / 11) = 6 px cells = 2 logical.
      expect(tester.getSize(find.byType(PixelArt)), const Size(22, 22));
    });

    testWidgets('paints exactly the transcribed grid, crisp', (tester) async {
      final img = await _pixels(
        tester,
        const PixelArt(PixelSprites.skullDue, size: 44, color: DM.flatline),
      );
      // 44 / 11 = 4px cells. Sample every cell centre and every cell
      // corner pixel: no blending at the edges.
      final rows = PixelSprites.skullDue.rows;
      for (var y = 0; y < 11; y++) {
        for (var x = 0; x < 11; x++) {
          final want = rows[y][x] == '#' ? DM.flatline : DM.void_;
          expect(_at(img, x * 4 + 2, y * 4 + 2), want, reason: 'cell $x,$y');
          expect(_at(img, x * 4, y * 4), want, reason: 'corner $x,$y');
          expect(_at(img, x * 4 + 3, y * 4 + 3), want, reason: 'edge $x,$y');
        }
      }
    });

    testWidgets('PixelSkull.status picks the face and color', (tester) async {
      await tester.pumpWidget(_host(PixelSkull.status(DMStatus.missed)));
      final art = tester.widget<PixelArt>(find.byType(PixelArt));
      expect(art.sprite, PixelSprites.skullMissed);
      expect(art.color, DM.missed);
    });

    testWidgets('decorative unless labelled', (tester) async {
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(_host(const PixelArt(PixelSprites.heart)));
      expect(find.bySemanticsLabel('Check-ins'), findsNothing);
      await tester.pumpWidget(
        _host(const PixelArt(PixelSprites.heart, semanticLabel: 'Check-ins')),
      );
      expect(find.bySemanticsLabel('Check-ins'), findsOneWidget);
      semantics.dispose();
    });
  });

  group('mark', () {
    testWidgets('SkullMark is the pulse skull, decorative unless labelled', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(_host(const SkullMark(size: 22)));
      final art = tester.widget<PixelArt>(find.byType(PixelArt));
      expect(art.sprite, PixelSprites.skull);
      expect(art.color, DM.pulse);
      expect(find.bySemanticsLabel('Deadman'), findsNothing);

      await tester.pumpWidget(
        _host(const SkullMark(size: 22, semanticLabel: 'Deadman')),
      );
      expect(find.bySemanticsLabel('Deadman'), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('lockup pairs the skull with the pixel wordmark', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(_host(const DeadmanLockup(height: 33)));
      expect(find.byType(SkullMark), findsOneWidget);
      expect(find.byType(DeadmanWordmark), findsOneWidget);
      expect(find.bySemanticsLabel('Deadman'), findsOneWidget);
      // Wordmark is 7/11 of the skull: both on the same 3px cell.
      final skull = tester.getSize(find.byType(SkullMark));
      final word = tester.getSize(find.byType(DeadmanWordmark));
      expect(skull.height, 33);
      expect(word.height, 21);
      expect(word.width, 41 * 3);
      semantics.dispose();
    });

    testWidgets('stacked lockup centres the wordmark under the skull', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(const DeadmanLockup(height: 66, stacked: true)),
      );
      final skull = tester.getRect(find.byType(SkullMark));
      final word = tester.getRect(find.byType(DeadmanWordmark));
      expect(word.top, greaterThan(skull.bottom));
      expect(word.center.dx, closeTo(skull.center.dx, 1));
    });

    testWidgets('deprecated DeadmanMark draws the skull', (tester) async {
      await tester.pumpWidget(
        _host(const DeadmanMark.mono(color: DM.bone, size: 22)),
      );
      final art = tester.widget<PixelArt>(find.byType(PixelArt));
      expect(art.sprite, PixelSprites.skull);
      expect(art.color, DM.bone);
    });
  });

  group('stickers', () {
    testWidgets('Sticker sets its word in Silkscreen caps on a tint', (
      tester,
    ) async {
      await tester.pumpWidget(_host(const Sticker('Step 1/3')));
      final text = tester.widget<Text>(find.text('STEP 1/3'));
      expect(text.style?.fontFamily, contains('Silkscreen'));
      expect(text.style?.color, DM.pulse);
      expect(find.byType(PixelArt), findsNothing);
      final box = tester.widget<DecoratedBox>(
        find.descendant(
          of: find.byType(Sticker),
          matching: find.byType(DecoratedBox),
        ),
      );
      final fill = (box.decoration as BoxDecoration).color!;
      expect(fill.a, closeTo(0.13, 0.01));
    });

    testWidgets('StatusSticker carries the status word and figure', (
      tester,
    ) async {
      await tester.pumpWidget(_host(const StatusSticker(DMStatus.due)));
      expect(find.text('TIER DUE'), findsOneWidget);
      final art = tester.widget<PixelArt>(find.byType(PixelArt));
      expect(art.sprite, PixelSprites.skullDue);
      expect(art.color, DM.flatline);
    });

    testWidgets('label override is uppercased; figure can be dropped', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          const StatusSticker(
            DMStatus.alive,
            label: 'pass',
            dense: true,
            showSprite: false,
          ),
        ),
      );
      expect(find.text('PASS'), findsOneWidget);
      expect(find.byType(PixelArt), findsNothing);
    });

    testWidgets('released wears the ghost, locked the lock', (tester) async {
      await tester.pumpWidget(
        _host(
          const Column(
            children: [
              StatusSticker(DMStatus.released),
              StatusSticker(DMStatus.locked),
            ],
          ),
        ),
      );
      final sprites = tester
          .widgetList<PixelArt>(find.byType(PixelArt))
          .map((a) => a.sprite)
          .toList();
      expect(sprites, [PixelSprites.ghost, PixelSprites.lock]);
    });

    testWidgets('StatusChip still compiles as a sticker', (tester) async {
      await tester.pumpWidget(
        _host(const StatusChip(DMStatus.missed, label: 'tier in 56s')),
      );
      expect(find.text('TIER IN 56S'), findsOneWidget);
      expect(find.byType(StatusSticker), findsOneWidget);
    });

    testWidgets('long words ellipsize inside a narrow slot', (tester) async {
      await tester.pumpWidget(
        _host(
          const SizedBox(
            width: 90,
            child: Sticker(
              'Releasing to beneficiary',
              sprite: PixelSprites.ghost,
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('SegmentedRing', () {
    testWidgets('fills the space it is given and shares the diameter', (
      tester,
    ) async {
      double? seen;
      await tester.pumpWidget(
        _host(
          SizedBox(
            width: 300,
            height: 520,
            child: SegmentedRing(
              progress: 0.9,
              child: Builder(
                builder: (context) {
                  seen = RingScope.of(context);
                  return const SizedBox();
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(seen, 300);
      final ring = find.descendant(
        of: find.byType(SegmentedRing),
        matching: find.byType(CustomPaint),
      );
      expect(tester.getSize(ring.first), const Size(300, 300));
    });

    testWidgets('height limits the ring on a wide screen', (tester) async {
      await tester.pumpWidget(
        _host(
          const SizedBox(
            width: 700,
            height: 360,
            child: SegmentedRing(progress: 0.5),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final ring = find.descendant(
        of: find.byType(SegmentedRing),
        matching: find.byType(CustomPaint),
      );
      expect(tester.getSize(ring.first), const Size(360, 360));
    });

    testWidgets('unbounded constraints fall back to a fixed size', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          const SingleChildScrollView(
            child: UnconstrainedBox(child: SegmentedRing(progress: 0.5)),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('lit ticks are the time left, from 12 o\'clock clockwise', (
      tester,
    ) async {
      final img = await _pixels(
        tester,
        const SegmentedRing(progress: 0.5, size: 200),
      );
      // 56 ticks, half lit: the right half (ticks 0..27) is pulse, the left
      // half is dim. Sample mid-tick at 3 o'clock (tick 14) and 9 (tick 42).
      const mid = 100 - 5; // radius minus half the 10px tick
      expect(_at(img, 100 + mid, 100), DM.pulse);
      expect(_at(img, 100 - mid, 100), DM.line);
      // Top tick is lit, its neighbour to the left (tick 55) is dim.
      expect(_at(img, 100, 100 - mid), DM.pulse);
    });

    testWidgets('a due tier alternates lit and dim ticks', (tester) async {
      Future<(Color, Color)> sample(int phase) async {
        final img = await _pixels(
          tester,
          SegmentedRing(
            progress: 1,
            size: 200,
            status: DMStatus.due,
            phase: phase,
          ),
        );
        return (_at(img, 100, 5), _at(img, 195, 100));
      }

      final dim = Color.alphaBlend(DMStatus.due.dimTick, DM.void_);
      // Tick 0 (top) and tick 14 (3 o'clock) are both even.
      final (top0, right0) = await sample(0);
      expect(top0, DM.flatline);
      expect(right0, DM.flatline);
      final (top1, _) = await sample(1);
      expect((top1.r - dim.r).abs(), lessThan(0.02));
    });

    testWidgets('readout scales with the ring and fits long countdowns', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          const SegmentedRing(
            progress: 0.7,
            size: 320,
            status: DMStatus.missed,
            child: PulseReadout(
              status: DMStatus.missed,
              countdown: '12d 23h 59m 59s',
              caption: 'until tier 1 releases',
              detail: 'Kids',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('MISSED'), findsOneWidget);
      expect(find.text('until tier 1 releases'), findsOneWidget);
      expect(find.text('Kids'), findsOneWidget);
      expect(tester.takeException(), isNull);
      final countdown = tester.widget<Text>(find.text('12d 23h 59m 59s'));
      expect(countdown.style?.color, DM.missed);
      expect(countdown.style?.fontSize, closeTo(320 * 0.165, 0.01));
      expect(countdown.style?.fontFamily, contains('JetBrains'));
    });

    testWidgets('due readout shows the address line in mono', (tester) async {
      await tester.pumpWidget(
        _host(
          const SegmentedRing(
            progress: 0,
            size: 300,
            status: DMStatus.due,
            child: PulseReadout(
              status: DMStatus.due,
              countdown: '48m 12s',
              caption: 'past due, releasing to',
              address: '4Ywp…KMbF',
              detail: 'test03 USDC 1',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('TIER DUE'), findsOneWidget);
      final address = tester.widget<Text>(find.text('4Ywp…KMbF'));
      expect(address.style?.fontFamily, contains('JetBrains'));
      expect(tester.takeException(), isNull);
    });

    testWidgets('small rings keep the readout inside', (tester) async {
      await tester.pumpWidget(
        _host(
          const SegmentedRing(
            progress: 0.4,
            size: 160,
            child: PulseReadout(
              status: DMStatus.alive,
              countdown: '6d 23h 59m',
              caption: 'until next check-in',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('deprecated PulseRing draws a SegmentedRing', (tester) async {
      await tester.pumpWidget(
        _host(
          const PulseRing(progress: 0.5, color: DM.pulse, child: Text('2d 4h')),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(SegmentedRing), findsOneWidget);
      expect(find.text('2d 4h'), findsOneWidget);
    });
  });

  group('controls', () {
    testWidgets('DMSquareButton taps, names itself and shows a count', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      var taps = 0;
      await tester.pumpWidget(
        _host(
          DMSquareButton(
            tooltip: 'Release plans',
            badge: 3,
            onPressed: () => taps++,
            child: const PixelArt(PixelSprites.tombstone, size: 20),
          ),
        ),
      );
      expect(find.text('3'), findsOneWidget);
      expect(find.bySemanticsLabel('Release plans, 3'), findsOneWidget);
      expect(tester.getSize(find.byType(DMSquareButton)), const Size(48, 48));
      await tester.tap(find.byType(DMSquareButton));
      expect(taps, 1);
      semantics.dispose();
    });

    testWidgets('DMSquareButton hides a zero badge', (tester) async {
      await tester.pumpWidget(
        _host(
          DMSquareButton(
            tooltip: 'Release plans',
            badge: 0,
            onPressed: () {},
            child: const SkullMark(size: 22),
          ),
        ),
      );
      expect(find.byType(Badge), findsNothing);
    });

    testWidgets('SelectCard reports its choice and selects on tap', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      var picked = '';
      await tester.pumpWidget(
        _host(
          Column(
            children: [
              SelectCard(
                selected: true,
                icon: Icons.bolt,
                title: 'Normal transfer',
                body: 'Straight to their Solana wallet.',
                footnote: '2% fee',
                onTap: () => picked = 'solana',
              ),
              const SizedBox(height: 12),
              SelectCard(
                selected: false,
                icon: Icons.visibility_off_outlined,
                title: 'Private (Cloak)',
                tag: const DMTag(label: 'mainnet only', mono: true),
                footnote: '3% fee',
                onTap: () => picked = 'cloak',
              ),
            ],
          ),
        ),
      );
      final footnote = tester.widget<Text>(find.text('2% fee'));
      expect(footnote.style?.color, DM.pulse);
      expect(tester.widget<Text>(find.text('3% fee')).style?.color, DM.haze);
      expect(
        tester.getSemantics(find.text('Normal transfer')),
        matchesSemantics(
          isInMutuallyExclusiveGroup: true,
          hasCheckedState: true,
          isChecked: true,
          hasEnabledState: true,
          isEnabled: true,
          hasTapAction: true,
          hasFocusAction: true,
          isFocusable: true,
          label: 'Normal transfer\nStraight to their Solana wallet.\n2% fee',
        ),
      );
      await tester.tap(find.text('Private (Cloak)'));
      expect(picked, 'cloak');
      expect(tester.takeException(), isNull);
      semantics.dispose();
    });
  });

  group('layout pieces', () {
    testWidgets('SectionHeader takes a pixel figure and an action', (
      tester,
    ) async {
      var taps = 0;
      await tester.pumpWidget(
        _host(
          SectionHeader(
            title: 'Who gets it',
            leading: const PixelArt(
              PixelSprites.heart,
              size: 20,
              color: DM.pulse,
            ),
            actionLabel: 'Add',
            actionKey: const Key('add'),
            onAction: () => taps++,
          ),
        ),
      );
      expect(find.text('Who gets it'), findsOneWidget);
      expect(find.byType(PixelArt), findsOneWidget);
      await tester.tap(find.byKey(const Key('add')));
      expect(taps, 1);
    });

    testWidgets('PageHeader shows title, trailing and lead', (tester) async {
      await tester.pumpWidget(
        _host(
          const PageHeader(
            title: 'Family Circle',
            subtitle: 'People who named you in their release plan.',
            trailing: SkullMark(),
          ),
        ),
      );
      expect(find.text('Family Circle'), findsOneWidget);
      expect(
        find.text('People who named you in their release plan.'),
        findsOneWidget,
      );
      expect(find.byType(SkullMark), findsOneWidget);
    });

    testWidgets('DMListGroup splits rows with lines and rows tap', (
      tester,
    ) async {
      var tapped = '';
      await tester.pumpWidget(
        _host(
          DMListGroup(
            children: [
              DMListRow(
                leading: const IconTile(icon: Icons.account_balance_wallet),
                title: 'Owner wallet',
                subtitle: 'DrX6…7VsQ · Seed Vault',
                onTap: () => tapped = 'owner',
              ),
              const DMListRow(
                leading: IconTile(icon: Icons.key),
                title: 'Guard key',
                subtitle: '9e7P…EUJH · this phone',
              ),
            ],
          ),
        ),
      );
      expect(find.byType(Divider), findsOneWidget);
      final sub = tester.widget<Text>(find.text('DrX6…7VsQ · Seed Vault'));
      expect(sub.style?.fontFamily, contains('JetBrains'));
      await tester.tap(find.text('Owner wallet'));
      expect(tapped, 'owner');
    });

    testWidgets('IconTile sinks into void unless toned', (tester) async {
      await tester.pumpWidget(
        _host(
          const Row(
            children: [
              IconTile(icon: Icons.bolt),
              IconTile(icon: Icons.warning_amber, tone: DM.flatline),
              IconTile(child: PixelArt(PixelSprites.ghost, size: 16)),
            ],
          ),
        ),
      );
      final boxes = tester
          .widgetList<DecoratedBox>(
            find.descendant(
              of: find.byType(IconTile),
              matching: find.byType(DecoratedBox),
            ),
          )
          .map((b) => (b.decoration as BoxDecoration).color)
          .toList();
      expect(boxes.first, DM.void_);
      expect(
        tester.widget<Icon>(find.byIcon(Icons.warning_amber)).color,
        DM.flatline,
      );
      expect(find.byType(PixelArt), findsOneWidget);
    });

    testWidgets('DMCard and DMTag render on grave', (tester) async {
      await tester.pumpWidget(
        _host(
          const DMCard(
            child: DMTag(label: 'Solana', icon: Icons.bolt),
          ),
        ),
      );
      expect(find.text('Solana'), findsOneWidget);
      final material = tester.widget<Material>(
        find.descendant(
          of: find.byType(DMCard),
          matching: find.byType(Material),
        ),
      );
      expect(material.color, DM.grave);
    });

    testWidgets('MonoLabel uppercases unless asked not to', (tester) async {
      await tester.pumpWidget(
        _host(
          const Column(
            children: [MonoLabel('plan'), MonoLabel('AppA…9PbA', upper: false)],
          ),
        ),
      );
      expect(find.text('PLAN'), findsOneWidget);
      expect(find.text('AppA…9PbA'), findsOneWidget);
    });
  });
}
