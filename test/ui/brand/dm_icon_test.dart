import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:deadman/ui/theme.dart';
import 'package:deadman/ui/widgets/brand/brand.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

/// The pack's SVG as drawn: filled cells in viewBox units plus the viewBox
/// origin. Parsed here independently of tool/gen_icons.dart.
({Set<(int, int)> cells, double minX, double minY}) _svg(String name) {
  final svg = File('assets/icons/$name.svg').readAsStringSync();
  final vb = RegExp(r'viewBox="([^"]+)"')
      .firstMatch(svg)!
      .group(1)!
      .split(' ')
      .map(double.parse)
      .toList();
  expect(vb.sublist(2), [12, 12], reason: '$name viewBox');
  final d = RegExp(r'\bd="([^"]+)"').firstMatch(svg)!.group(1)!;
  final rect = RegExp(r'M(\d+) (\d+)h(\d+)v1h-\3z');
  expect(d.replaceAll(rect, ''), isEmpty, reason: '$name: only 1-row rects');
  final cells = <(int, int)>{};
  for (final m in rect.allMatches(d)) {
    final [x, y, w] = [1, 2, 3].map((g) => int.parse(m.group(g)!)).toList();
    for (var i = 0; i < w; i++) {
      cells.add((x + i, y));
    }
  }
  return (cells: cells, minX: vb[0], minY: vb[1]);
}

/// Filled cells of [icon]'s sprite, in its SVG's viewBox units.
Set<(int, int)> _spriteCells(DMIcons icon) => {
  for (var y = 0; y < icon.sprite.height; y++)
    for (var x = 0; x < icon.sprite.width; x++)
      if (icon.sprite.rows[y][x] == '#') (x, y),
};

Widget _at1x(Widget child, {double dpr = 1}) => MediaQuery(
  data: MediaQueryData(devicePixelRatio: dpr),
  child: Directionality(
    textDirection: TextDirection.ltr,
    child: Align(alignment: Alignment.topLeft, child: child),
  ),
);

/// Renders [icon] in white on black at 1x and returns (rgba, width).
Future<(ByteData, int)> _render(
  WidgetTester tester,
  DMIcons icon,
  double size,
) async {
  final key = GlobalKey();
  await tester.pumpWidget(
    _at1x(
      RepaintBoundary(
        key: key,
        child: ColoredBox(
          color: const Color(0xFF000000),
          child: DMIcon(icon, size: size, color: const Color(0xFFFFFFFF)),
        ),
      ),
    ),
  );
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

void main() {
  test('the enum covers every SVG in the pack, in the README order', () {
    final files = Directory('assets/icons')
        .listSync()
        .map((f) => f.uri.pathSegments.last)
        .where((f) => f.endsWith('.svg'))
        .map((f) => f.replaceAll('.svg', ''))
        .toSet();
    expect(DMIcons.values.map((i) => i.sprite.name).toSet(), files);
    expect(DMIcons.values, hasLength(19));
  });

  test('every generated sprite matches its SVG cell for cell', () {
    for (final icon in DMIcons.values) {
      final svg = _svg(icon.sprite.name);
      expect(_spriteCells(icon), svg.cells, reason: icon.name);
      expect((icon.dx, icon.dy), (-svg.minX, -svg.minY), reason: icon.name);
      expect(icon.dx + icon.sprite.width, lessThanOrEqualTo(DMIcons.grid));
      expect(icon.dy + icon.sprite.height, lessThanOrEqualTo(DMIcons.grid));
    }
  });

  test('the pulse icon is the heart from the pixel cast', () {
    expect(DMIcons.pulse.sprite.rows.take(10), PixelSprites.heart.rows);
  });

  testWidgets('every icon renders some pixels', (tester) async {
    for (final icon in DMIcons.values) {
      final (bytes, width) = await _render(tester, icon, 24);
      expect(width, 24);
      var lit = 0;
      for (var i = 0; i < bytes.lengthInBytes; i += 4) {
        if (bytes.getUint8(i) == 255) lit++;
      }
      // Each cell is 2x2 device pixels at 24px and 1x.
      expect(lit, _spriteCells(icon).length * 4, reason: icon.name);
    }
    expect(tester.takeException(), isNull);
  });

  for (final (name, size) in [
    ('wallet', 24.0),
    ('pulse', 24.0),
    ('wallet', 48.0),
    ('pulse', 48.0),
  ]) {
    testWidgets('$name at ${size.toInt()}px is pixel-exact against the SVG', (
      tester,
    ) async {
      final icon = DMIcons.values.firstWhere((i) => i.sprite.name == name);
      final svg = _svg(name);
      final scale = size / 12;
      final (bytes, width) = await _render(tester, icon, size);
      expect(width, size.toInt());
      for (var py = 0; py < width; py++) {
        for (var px = 0; px < width; px++) {
          // Sample the SVG at the pixel center, as crispEdges rasterizes.
          final ux = ((px + 0.5) / scale + svg.minX).floor();
          final uy = ((py + 0.5) / scale + svg.minY).floor();
          final want = svg.cells.contains((ux, uy));
          final i = (py * width + px) * 4;
          final r = bytes.getUint8(i);
          expect(
            r,
            want ? 255 : 0,
            reason: '$name pixel ($px, $py) should be ${want ? 'on' : 'off'}',
          );
        }
      }
    });
  }

  group('sizing', () {
    test('cells snap down to whole device pixels', () {
      expect(DMIcon.extentFor(24, 1), 24);
      expect(DMIcon.extentFor(48, 1), 48);
      expect(DMIcon.extentFor(20, 1), 12);
      expect(DMIcon.extentFor(20, 3), 20); // 5 device px per cell
      expect(DMIcon.extentFor(30, 2), 30); // 2.5 logical px per cell
      expect(DMIcon.extentFor(4, 1), 12); // never below one device pixel
      for (final dpr in [1.0, 1.5, 2.0, 2.625, 3.0]) {
        for (final size in [12.0, 18.0, 22.0, 24.0, 36.0]) {
          final devicePx = DMIcon.cellFor(size, dpr) * dpr;
          expect(devicePx, closeTo(devicePx.roundToDouble(), 1e-9));
          expect(
            DMIcon.extentFor(size, dpr),
            lessThanOrEqualTo(size + 1e-9),
            reason: '$size at $dpr',
          );
        }
      }
    });

    for (final (size, dpr, extent) in [
      (24.0, 1.0, 24.0),
      (20.0, 1.0, 12.0),
      (20.0, 3.0, 20.0),
    ]) {
      testWidgets('lays out $size square and draws $extent at ${dpr}x', (
        tester,
      ) async {
        await tester.pumpWidget(
          _at1x(DMIcon(DMIcons.shield, size: size), dpr: dpr),
        );
        expect(tester.getSize(find.byType(DMIcon)), Size.square(size));
        expect(tester.getSize(find.byType(PixelArt)), Size.square(extent));
        final art = tester.getTopLeft(find.byType(PixelArt));
        final inset = (size - extent) / 2;
        expect(art, Offset(inset, inset));
      });
    }
  });

  group('color', () {
    Color drawn(WidgetTester tester) =>
        tester.widget<PixelArt>(find.byType(PixelArt)).color;

    testWidgets('inherits the ambient IconTheme color', (tester) async {
      await tester.pumpWidget(
        _at1x(
          const IconTheme(
            data: IconThemeData(color: DM.pulse),
            child: DMIcon(DMIcons.plus),
          ),
        ),
      );
      expect(drawn(tester), DM.pulse);
    });

    testWidgets('an explicit color wins over the IconTheme', (tester) async {
      await tester.pumpWidget(
        _at1x(
          const IconTheme(
            data: IconThemeData(color: DM.pulse),
            child: DMIcon(DMIcons.warning, color: DM.flatline),
          ),
        ),
      );
      expect(drawn(tester), DM.flatline);
    });

    testWidgets('applies IconTheme opacity like Icon does', (tester) async {
      await tester.pumpWidget(
        _at1x(
          const IconTheme(
            data: IconThemeData(color: DM.bone, opacity: 0.5),
            child: DMIcon(DMIcons.lock),
          ),
        ),
      );
      expect(drawn(tester).a, closeTo(0.5, 1e-6));
    });

    testWidgets('defaults to Bone under the app theme', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(),
          home: const Scaffold(body: DMIcon(DMIcons.wallet)),
        ),
      );
      expect(drawn(tester), DM.bone);
    });

    testWidgets('takes the button foreground inside an IconButton', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(),
          home: Scaffold(
            body: IconButton(
              color: DM.missed,
              onPressed: () {},
              icon: const DMIcon(DMIcons.key),
            ),
          ),
        ),
      );
      expect(drawn(tester), DM.missed);
    });
  });

  group('semantics', () {
    testWidgets('decorative by default, labelled when asked', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        _at1x(
          const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              DMIcon(DMIcons.lock),
              DMIcon(DMIcons.key, semanticLabel: 'Guard key'),
            ],
          ),
        ),
      );
      expect(find.bySemanticsLabel('Guard key'), findsOneWidget);
      handle.dispose();
    });
  });

  testWidgets('DMNavigationDestination colors by selection', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: Scaffold(
          bottomNavigationBar: NavigationBar(
            selectedIndex: 0,
            destinations: const [
              DMNavigationDestination(icon: DMIcons.pulse, label: 'Pulse'),
              DMNavigationDestination(icon: DMIcons.users, label: 'Circle'),
              DMNavigationDestination(icon: DMIcons.shield, label: 'Security'),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    Color colorOf(DMIcons icon) => tester
        .widget<PixelArt>(
          find.descendant(
            of: find.byWidgetPredicate((w) => w is DMIcon && w.icon == icon),
            matching: find.byType(PixelArt),
          ),
        )
        .color;
    expect(colorOf(DMIcons.pulse), DM.pulse);
    expect(colorOf(DMIcons.users), DM.ash);
    expect(colorOf(DMIcons.shield), DM.ash);
    expect(find.text('Circle'), findsOneWidget);
    for (final size in find.byType(DMIcon).evaluate().map((e) => e.size)) {
      expect(size, const Size.square(24));
    }
  });
}
