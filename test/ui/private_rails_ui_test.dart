import 'package:deadman/core/config.dart';
import 'package:deadman/rails/cloak_route.dart';
import 'package:deadman/rails/rails.dart';
import 'package:deadman/state/actions.dart';
import 'package:deadman/state/private_rails.dart';
import 'package:deadman/state/providers.dart';
import 'package:deadman/state/secure_store.dart';
import 'package:deadman/ui/screens/circle_tab.dart';
import 'package:deadman/ui/screens/rails_check_screen.dart';
import 'package:deadman/ui/screens/shielded_inbox_screen.dart';
import 'package:deadman/ui/widgets/brand/brand.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../state/fakes.dart';

const usdc = AppConfig.usdcMint;
final cloakAddress = 'cloak:${'1' * 64}:${'2' * 64}';

class Rig {
  Rig(this.api, this.zcash, this.cloak, this.container);

  final FakeApi api;
  final FakeZcashRoute zcash;
  final FakeCloakRoute cloak;
  final ProviderContainer container;
}

Future<Rig> _pump(
  WidgetTester tester,
  Widget home, {
  List<ClaimProfile> profiles = const [],
  bool live = true,
  bool duress = false,
  void Function(FakeApi, FakeZcashRoute, FakeCloakRoute)? setup,
}) async {
  tester.view.physicalSize = const Size(1200, 4000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues({'owner': addr(1)});
  final prefs = await SharedPreferences.getInstance();
  final api = FakeApi(const []);
  final zcash = FakeZcashRoute(live: live);
  final cloak = FakeCloakRoute(live: live);
  setup?.call(api, zcash, cloak);
  final container = ProviderContainer(
    overrides: [
      prefsProvider.overrideWithValue(prefs),
      apiProvider.overrideWithValue(api),
      secureStoreProvider.overrideWithValue(FakeSecureStore(profiles)),
      watchedVaultsProvider.overrideWith((ref) async => const []),
      zcashRouteProvider.overrideWithValue(zcash),
      cloakRouteProvider.overrideWith((ref) async => cloak),
      cloakStatusRouteProvider.overrideWithValue(cloak),
      privateRailsLiveProvider.overrideWithValue(live),
      biometricProvider.overrideWithValue((_) async => true),
      statusPollIntervalProvider.overrideWithValue(Duration.zero),
      railsCheckZcashProvider.overrideWithValue(zcash),
    ],
  );
  addTearDown(container.dispose);
  if (duress) container.read(sessionProvider.notifier).unlock(duress: true);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(home: Scaffold(body: home)),
    ),
  );
  await tester.pumpAndSettle();
  return Rig(api, zcash, cloak, container);
}

/// The route button spins behind the dialog, so the tree never settles.
Future<void> _openDialog(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
}

/// The sticker reading [word].
Sticker _sticker(WidgetTester tester, String word) => tester.widget<Sticker>(
  find.ancestor(of: find.text(word), matching: find.byType(Sticker)),
);

Future<ClaimProfile> _profile(Rail rail, String destination) async =>
    ClaimProfile(rail: rail, key: await keyPair(5), destination: destination);

void main() {
  testWidgets('USDC on a Zcash claim key: quote, confirm, track', (
    tester,
  ) async {
    final p = await _profile(Rail.zcash, sampleZcashAddress);
    final r = await _pump(
      tester,
      const CircleTab(),
      profiles: [p],
      setup: (api, zcash, _) {
        api.balances[p.key.address] = tokenGasStipend;
        api.tokens['${p.key.address}:$usdc'] = 12500000;
        zcash.spendableBy[usdc] = 12500000;
      },
    );

    expect(find.text('Ready to route'), findsOneWidget);
    expect(find.widgetWithText(DMTag, 'Zcash'), findsOneWidget);
    expect(find.text('12.5 USDC'), findsOneWidget);
    expect(find.text('0.003 SOL'), findsNothing);

    await tester.tap(find.text('Route privately via Zcash'));
    await _openDialog(tester);
    expect(find.text('ESTIMATED TO ARRIVE'), findsOneWidget);
    expect(find.text('YOU SEND'), findsOneWidget);
    expect(find.text('0.0034 ZEC'), findsOneWidget);
    expect(
      find.textContaining('0.00032 ZEC Zcash network fee'),
      findsOneWidget,
    );
    expect(find.textContaining('Quote valid for'), findsOneWidget);
    expect(r.zcash.executed, isEmpty);

    await tester.tap(find.text('Send'));
    await tester.pumpAndSettle();
    expect(r.zcash.executed.single.inputMint, usdc);
    expect(find.text('Private transfers'), findsOneWidget);
    expect(find.text('12.5 USDC → 0.0034 ZEC'), findsOneWidget);
    expect(find.textContaining('Delivered as shielded ZEC'), findsOneWidget);
    expect(find.widgetWithText(StatusSticker, 'DONE'), findsOneWidget);
    // An outcome, not a plan state: pulse word, no figure.
    expect(_sticker(tester, 'DONE').color, DM.pulse);
    expect(_sticker(tester, 'DONE').sprite, isNull);
    expect(r.container.read(transferHistoryProvider).single.status, 'SUCCESS');
  });

  testWidgets('an interrupted Cloak route resumes from its history row', (
    tester,
  ) async {
    final p = await _profile(Rail.cloak, cloakAddress);
    final r = await _pump(
      tester,
      const CircleTab(),
      profiles: [p],
      setup: (api, _, _) => api.balances[p.key.address] = 4000,
    );
    await r.container
        .read(transferHistoryProvider.notifier)
        .add(
          const PrivateTransfer(
            id: 'stuck',
            rail: Rail.cloak,
            mint: null,
            amount: 20000000,
            trackingId: '',
            status: interruptedStatus,
            createdAt: 1,
          ),
        );
    await tester.pumpAndSettle();
    expect(find.textContaining('Interrupted before delivery'), findsOneWidget);
    // Resumable, so attention rather than failure.
    expect(find.widgetWithText(StatusSticker, 'INTERRUPTED'), findsOneWidget);
    expect(_sticker(tester, 'INTERRUPTED').color, DM.missed);
    expect(_sticker(tester, 'INTERRUPTED').sprite, isNull);
    expect(find.widgetWithText(StatusSticker, 'FAILED'), findsNothing);

    await tester.tap(find.text('Resume'));
    await _openDialog(tester);
    expect(find.text('ESTIMATED TO ARRIVE'), findsOneWidget);
    await tester.tap(find.text('Send'));
    await tester.pumpAndSettle();
    expect(r.cloak.executed.single.amountIn, 20000000);
    expect(find.widgetWithText(StatusSticker, 'INTERRUPTED'), findsNothing);
    final t = r.container.read(transferHistoryProvider).single;
    expect(t.id, 'stuck');
    expect(t.trackingId, 'cloakSig');
    expect(find.text('Resume'), findsNothing);
  });

  testWidgets('cancelling the preview sends nothing', (tester) async {
    final p = await _profile(Rail.zcash, sampleZcashAddress);
    final r = await _pump(
      tester,
      const CircleTab(),
      profiles: [p],
      setup: (api, zcash, _) {
        api.balances[p.key.address] = 500000000;
        zcash.spendableBy[null] = 499995000;
      },
    );
    await tester.tap(find.text('Route privately via Zcash'));
    await _openDialog(tester);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(r.zcash.quotes, hasLength(1));
    expect(r.zcash.executed, isEmpty);
    expect(find.text('Private transfers'), findsNothing);
  });

  testWidgets('devnet builds say mainnet only', (tester) async {
    final p = await _profile(Rail.cloak, addr(6));
    await _pump(
      tester,
      const CircleTab(),
      profiles: [p],
      live: false,
      setup: (api, _, _) => api.balances[p.key.address] = 500000000,
    );
    final button = find.widgetWithText(
      OutlinedButton,
      'Route via Cloak: mainnet only',
    );
    expect(button, findsOneWidget);
    expect(tester.widget<OutlinedButton>(button).onPressed, isNull);
    final why = find.textContaining('run on Solana mainnet only');
    expect(why, findsOneWidget);
    expect(tester.widget<Text>(why).style?.color, DM.ash);
  });

  testWidgets('no destination yet: say where to set one, in bone', (
    tester,
  ) async {
    final p = await _profile(Rail.zcash, '');
    await _pump(
      tester,
      const CircleTab(),
      profiles: [p],
      setup: (api, zcash, _) {
        api.balances[p.key.address] = 500000000;
        zcash.spendableBy[null] = 499995000;
      },
    );
    const text = 'Set a destination first: Security → Receive privately.';
    expect(find.text(text), findsOneWidget);
    expect(tester.widget<Text>(find.text(text)).style?.color, DM.bone);
    expect(find.byIcon(Icons.info_outline), findsOneWidget);
  });

  testWidgets('under duress routing looks like a wallet timeout', (
    tester,
  ) async {
    final p = await _profile(Rail.zcash, sampleZcashAddress);
    final r = await _pump(
      tester,
      const CircleTab(),
      profiles: [p],
      duress: true,
      setup: (api, zcash, _) {
        api.balances[p.key.address] = 500000000;
        zcash.spendableBy[null] = 499995000;
      },
    );
    await tester.tap(find.text('Route privately via Zcash'));
    await tester.pump(const Duration(seconds: 5));
    await tester.pump();
    expect(find.text('Seed Vault timed out. Try again later.'), findsOneWidget);
    expect(r.zcash.quotes, isEmpty);
    await tester.pumpAndSettle(const Duration(seconds: 5));
  });

  testWidgets('a cloak: profile gets a shielded inbox entry', (tester) async {
    final p = await _profile(Rail.cloak, cloakAddress);
    await _pump(tester, const CircleTab(), profiles: [p]);
    expect(find.text('Shielded inbox'), findsOneWidget);
    await tester.tap(find.text('Shielded inbox'));
    await tester.pumpAndSettle();
    expect(find.byType(ShieldedInboxScreen), findsOneWidget);
  });

  testWidgets('shielded inbox scans on open and withdraws to the wallet', (
    tester,
  ) async {
    final p = await _profile(Rail.cloak, cloakAddress);
    final r = await _pump(
      tester,
      const ShieldedInboxScreen(),
      profiles: [p],
      setup: (_, _, cloak) => cloak.notes = [
        note(400000000),
        note(100000000),
        note(700000000, spent: true),
      ],
    );
    expect(r.cloak.scans, 1);
    expect(find.text('0.500 SOL'), findsOneWidget);
    expect(find.text('2 shielded notes'), findsOneWidget);

    await tester.tap(find.text('Withdraw to my wallet'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Cloak keeps about'), findsOneWidget);
    await tester.tap(find.text('Withdraw'));
    await tester.pumpAndSettle();
    expect(r.cloak.withdrawals.single.destination, addr(1));
    expect(r.cloak.withdrawals.single.notes, hasLength(2));
    expect(r.cloak.scans, 2);
    expect(
      r.container.read(transferHistoryProvider).single.kind,
      TransferKind.withdraw,
    );
  });

  testWidgets('shielded inbox does not scan on devnet', (tester) async {
    final p = await _profile(Rail.cloak, cloakAddress);
    final r = await _pump(
      tester,
      const ShieldedInboxScreen(),
      profiles: [p],
      live: false,
    );
    expect(r.cloak.scans, 0);
    expect(find.textContaining('mainnet only'), findsOneWidget);
  });

  testWidgets('private rails check passes on a devnet build', (tester) async {
    final r = await _pump(tester, const RailsCheckScreen(), live: false);
    expect(
      find.text('Proving files 1200 ms · proof 5600 ms · total 6900 ms'),
      findsOneWidget,
    );
    expect(find.textContaining('0.100 SOL ≈ 0.0034 ZEC'), findsOneWidget);
    expect(find.text('PASS'), findsNWidgets(2));
    expect(find.text('FAIL'), findsNothing);
    expect(r.zcash.estimates.single.to, sampleZcashAddress);
  });

  testWidgets('private rails check shows a failure', (tester) async {
    await _pump(
      tester,
      const RailsCheckScreen(),
      setup: (_, zcash, cloak) {
        cloak.fail = const CloakRouteException('proving key hash mismatch');
        zcash.fail = Exception('HTTP 503');
      },
    );
    expect(find.text('proving key hash mismatch'), findsOneWidget);
    expect(find.text('FAIL'), findsNWidgets(2));
    expect(find.text('PASS'), findsNothing);
  });
}
