import 'package:deadman/ui/theme.dart';
import 'package:deadman/ui/widgets/brand/brand.dart';
import 'package:flutter/material.dart';
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

void main() {
  group('theme', () {
    test('maps the brand tokens onto the color scheme', () {
      final theme = buildTheme();
      expect(theme.scaffoldBackgroundColor, DM.void_);
      expect(theme.colorScheme.primary, DM.signal);
      expect(theme.colorScheme.onPrimary, DM.void_);
      expect(theme.colorScheme.surface, DM.graphite);
      expect(theme.colorScheme.outline, DM.line);
      expect(theme.colorScheme.error, DM.due);
      // Selected states are deep + signal, never purple.
      expect(theme.colorScheme.secondaryContainer, DM.deep);
      expect(theme.navigationBarTheme.indicatorColor, DM.deep);
      expect(theme.textTheme.headlineMedium?.fontFamily, contains('Outfit'));
    });

    test('fonts come from the bundle, never fetched at runtime', () {
      buildTheme();
      expect(GoogleFonts.config.allowRuntimeFetching, isFalse);
    });

    test('legacy DmColors resolve to brand tokens', () {
      // ignore: deprecated_member_use_from_same_package
      expect(DmColors.alive, DM.signal);
      // ignore: deprecated_member_use_from_same_package
      expect(DmColors.bg, DM.void_);
      // ignore: deprecated_member_use_from_same_package
      expect(DmColors.plus, isNot(DM.locked));
    });

    testWidgets('bundled Outfit and JetBrains Mono load', (tester) async {
      await tester.pumpWidget(
        _host(
          Column(
            children: [
              const Text('Pulse'),
              Text('1m 49s', style: DMType.countdown(DM.signal)),
            ],
          ),
        ),
      );
      await expectLater(GoogleFonts.pendingFonts(), completes);
    });
  });

  group('status', () {
    test('statusForWindow picks the countdown state', () {
      expect(statusForWindow(0.8), DMStatus.onTrack);
      expect(statusForWindow(0.25), DMStatus.attention);
      expect(statusForWindow(0), DMStatus.due);
      expect(statusForWindow(0.9, releasing: true), DMStatus.due);
      expect(statusForWindow(0.9, locked: true), DMStatus.locked);
    });

    test('each status has its color and word', () {
      expect(DMStatus.onTrack.color, DM.signal);
      expect(DMStatus.attention.color, DM.attention);
      expect(DMStatus.due.color, DM.due);
      expect(DMStatus.locked.color, DM.locked);
      expect(DMStatus.released.color, DM.sub);
      expect(DMStatus.released.label, 'RELEASED');
      expect(DMStatus.due.tint.a, closeTo(0.12, 0.01));
    });

    testWidgets('StatusChip shows the status word in caps and its color', (
      tester,
    ) async {
      await tester.pumpWidget(_host(const StatusChip(DMStatus.onTrack)));
      final text = tester.widget<Text>(find.text('ON TRACK'));
      expect(text.style?.color, DM.signal);
      expect(text.style?.fontFamily, contains('JetBrains'));
    });

    testWidgets('StatusChip label override is uppercased', (tester) async {
      await tester.pumpWidget(
        _host(const StatusChip(DMStatus.attention, label: 'tier in 56s')),
      );
      expect(find.text('TIER IN 56S'), findsOneWidget);
    });
  });

  group('mark', () {
    testWidgets('DeadmanMark is decorative unless labelled', (tester) async {
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(_host(const DeadmanMark(size: 40)));
      expect(find.bySemanticsLabel('Deadman'), findsNothing);
      expect(tester.getSize(find.byType(DeadmanMark)), const Size(40, 40));

      await tester.pumpWidget(
        _host(const DeadmanMark(size: 40, semanticLabel: 'Deadman')),
      );
      expect(find.bySemanticsLabel('Deadman'), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('lockup pairs the mark with the wordmark', (tester) async {
      await tester.pumpWidget(_host(const DeadmanLockup(height: 32)));
      expect(find.byType(DeadmanMark), findsOneWidget);
      expect(find.text('Deadman'), findsOneWidget);
    });

    testWidgets('mono mark paints both halves one color', (tester) async {
      await tester.pumpWidget(
        _host(const DeadmanMark.mono(color: DM.bone, size: 24)),
      );
      final mark = tester.widget<DeadmanMark>(find.byType(DeadmanMark));
      expect(mark.top, DM.bone);
      expect(mark.bottom, DM.bone);
    });
  });

  group('layout pieces', () {
    testWidgets('StatTiles lays out three cells with caps labels', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          const StatTiles(
            children: [
              StatTile(value: '1', label: 'Day streak'),
              StatTile(value: '12', label: 'Best'),
              StatTile(value: '2', label: 'Plan'),
            ],
          ),
        ),
      );
      expect(find.text('DAY STREAK'), findsOneWidget);
      expect(find.text('BEST'), findsOneWidget);
      expect(find.text('12'), findsOneWidget);
      expect(find.byType(VerticalDivider), findsNWidgets(2));
      expect(tester.takeException(), isNull);
    });

    testWidgets('SectionHeader action fires', (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        _host(
          SectionHeader(
            title: 'Release plans',
            actionLabel: 'New plan',
            actionKey: const Key('new-plan'),
            onAction: () => taps++,
          ),
        ),
      );
      expect(find.text('Release plans'), findsOneWidget);
      await tester.tap(find.byKey(const Key('new-plan')));
      expect(taps, 1);
    });

    testWidgets('PageHeader shows title, trailing and lead', (tester) async {
      await tester.pumpWidget(
        _host(
          const PageHeader(
            title: 'Family Circle',
            subtitle: 'People who named you in their release plan.',
            trailing: DeadmanMark(),
          ),
        ),
      );
      expect(find.text('Family Circle'), findsOneWidget);
      expect(
        find.text('People who named you in their release plan.'),
        findsOneWidget,
      );
      expect(find.byType(DeadmanMark), findsOneWidget);
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

    testWidgets('IconTile tone tints the tile', (tester) async {
      await tester.pumpWidget(
        _host(const IconTile(icon: Icons.warning_amber, tone: DM.due)),
      );
      final icon = tester.widget<Icon>(find.byIcon(Icons.warning_amber));
      expect(icon.color, DM.due);
    });

    testWidgets('DMCard and DMTag render on graphite', (tester) async {
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
      expect(material.color, DM.graphite);
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

  group('PulseRing', () {
    testWidgets('renders a readout and fits long countdowns', (tester) async {
      await tester.pumpWidget(
        _host(
          const PulseRing(
            progress: 0.7,
            status: DMStatus.attention,
            child: PulseReadout(
              status: DMStatus.attention,
              statusLabel: 'Check-in overdue',
              countdown: '12d 23h 59m 59s',
              caption: 'until tier 1 releases',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('CHECK-IN OVERDUE'), findsOneWidget);
      expect(find.text('12d 23h 59m 59s'), findsOneWidget);
      expect(find.text('until tier 1 releases'), findsOneWidget);
      expect(tester.takeException(), isNull);
      final countdown = tester.widget<Text>(find.text('12d 23h 59m 59s'));
      expect(countdown.style?.color, DM.attention);
    });

    testWidgets('legacy color argument still drives the arc', (tester) async {
      await tester.pumpWidget(
        _host(
          const PulseRing(
            progress: 0.5,
            color: DM.signal,
            child: Text('2d 4h'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('2d 4h'), findsOneWidget);
    });

    testWidgets('due status draws without errors', (tester) async {
      await tester.pumpWidget(
        _host(
          const PulseRing(
            progress: 0,
            status: DMStatus.due,
            child: PulseReadout(
              status: DMStatus.due,
              statusLabel: 'Tier due',
              countdown: '0m 10s',
              caption: 'releasing to AppA…9PbA',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('TIER DUE'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
