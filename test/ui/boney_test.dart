import 'package:deadman/state/boney.dart';
import 'package:deadman/ui/widgets/brand/brand.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host(Widget child, {bool reduceMotion = false, double dpr = 1}) =>
    MediaQuery(
      data: MediaQueryData(
        devicePixelRatio: dpr,
        disableAnimations: reduceMotion,
      ),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Center(child: child),
      ),
    );

List<PixelArt> _layers(WidgetTester tester) =>
    tester.widgetList<PixelArt>(find.byType(PixelArt)).toList();

String _key(WidgetTester tester) =>
    (tester.widget<KeyedSubtree>(find.byType(KeyedSubtree)).key!
            as ValueKey<String>)
        .value;

void main() {
  test('every mood has a pose, in its status colour', () {
    expect({for (final m in BoneyMood.values) m.pose}, hasLength(8));
    for (final m in BoneyMood.values) {
      final layers = m.pose.layers;
      expect(layers.first.argb, m.status.color.toARGB32(), reason: m.wire);
      for (final l in layers) {
        expect(l.sprite.width, 26);
        expect(l.sprite.height, 24);
      }
    }
    // Only the ghost's tombstone and the amber sweat add a second colour.
    expect(BoneyPose.releasedGhost.layers, hasLength(2));
    expect(BoneyPose.missed.layers, hasLength(2));
    expect(BoneyPose.onTrack.layers, hasLength(1));
  });

  test('the idle loop: five frames, 400/400/400/800/400 ms', () {
    expect(boneyIdle.map((f) => f.ms), [400, 400, 400, 800, 400]);
    expect(
      boneyIdle.first.sprite.rows,
      BoneyPose.front.layers.single.sprite.rows,
    );
  });

  testWidgets('draws whole cells: 48 tall at 1x is 2 px a cell', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(const BoneyFigure(mood: BoneyMood.onTrack, animate: false)),
    );
    expect(tester.getSize(find.byType(BoneyFigure)), const Size(52, 48));
    expect(_layers(tester).single.color, DM.pulse);
  });

  testWidgets('cells snap to the device grid at 2.75x', (tester) async {
    await tester.pumpWidget(
      _host(
        const BoneyFigure(mood: BoneyMood.tierDue, animate: false),
        dpr: 2.75,
      ),
    );
    // floor(48 * 2.75 / 24) = 5 device px a cell.
    final size = tester.getSize(find.byType(BoneyFigure));
    expect(size.height * 2.75, closeTo(24 * 5, 1e-9));
    expect(_layers(tester).single.color, DM.flatline);
  });

  testWidgets('released: the ash ghost over his own tombstone', (tester) async {
    await tester.pumpWidget(
      _host(const BoneyFigure(mood: BoneyMood.released, animate: false)),
    );
    final layers = _layers(tester);
    expect(layers.map((l) => l.color), [DM.ash, const Color(0xFF5B606A)]);
  });

  testWidgets('decorative unless labelled', (tester) async {
    await tester.pumpWidget(
      _host(
        const BoneyFigure(
          mood: BoneyMood.onTrack,
          animate: false,
          semanticLabel: 'Boney: On track',
        ),
      ),
    );
    expect(find.bySemanticsLabel('Boney: On track'), findsOneWidget);
  });

  testWidgets('alive, he rests then plays the idle loop once', (tester) async {
    await tester.pumpWidget(_host(const BoneyFigure(mood: BoneyMood.onTrack)));
    expect(_key(tester), 'boney-on_track');
    await tester.pump(const Duration(seconds: 4));
    expect(_key(tester), 'boney-on_track-idle-0');
    await tester.pump(const Duration(milliseconds: 400));
    expect(_key(tester), 'boney-on_track-idle-1');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    expect(_key(tester), 'boney-on_track-idle-3');
    // The happy frame holds twice as long.
    await tester.pump(const Duration(milliseconds: 400));
    expect(_key(tester), 'boney-on_track-idle-3');
    await tester.pump(const Duration(milliseconds: 400));
    expect(_key(tester), 'boney-on_track-idle-4');
    await tester.pump(const Duration(milliseconds: 400));
    expect(_key(tester), 'boney-on_track');
    expect(_layers(tester).single.color, DM.pulse);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('due or released, he stays still', (tester) async {
    for (final mood in [
      BoneyMood.tierDue,
      BoneyMood.lastTier,
      BoneyMood.released,
      BoneyMood.noPlan,
    ]) {
      await tester.pumpWidget(_host(BoneyFigure(mood: mood)));
      await tester.pump(const Duration(seconds: 10));
      expect(_key(tester), 'boney-${mood.wire}');
    }
  });

  testWidgets('reduced motion and muted tickers keep him still', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(const BoneyFigure(mood: BoneyMood.onTrack), reduceMotion: true),
    );
    await tester.pump(const Duration(seconds: 10));
    expect(_key(tester), 'boney-on_track');

    await tester.pumpWidget(
      _host(
        const TickerMode(
          enabled: false,
          child: BoneyFigure(mood: BoneyMood.checkInSoon),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 10));
    expect(_key(tester), 'boney-check_in_soon');
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('pumpAndSettle settles while he idles', (tester) async {
    await tester.pumpWidget(_host(const BoneyFigure(mood: BoneyMood.onTrack)));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
  });
}
