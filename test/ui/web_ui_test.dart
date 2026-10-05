import 'dart:typed_data';

import 'package:deadman/core/config.dart';
import 'package:deadman/solana/deadman_api.dart';
import 'package:deadman/state/providers.dart';
import 'package:deadman/state/secure_store.dart';
import 'package:deadman/ui/screens/pulse_tab.dart';
import 'package:deadman/ui/screens/settings_tab.dart';
import 'package:deadman/ui/screens/welcome_screen.dart';
import 'package:deadman/ui/web/web_ui.dart';
import 'package:deadman/ui/widgets/brand/brand.dart';
import 'package:deadman/wallet/wallet_bridge.dart';
import 'package:deadman/wallet/web_wallet_bridge.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../state/fakes.dart';
import '../wallet/web_wallet_bridge_test.dart' show FakeBackend;

const _phantom = WebWallet(
  kind: WalletKind.phantom,
  name: 'Phantom',
  path: SigningPath.walletStandard,
);
const _solflare = WebWallet(
  kind: WalletKind.solflare,
  name: 'Solflare',
  path: SigningPath.injected,
);

/// Owner-signed builds return a marker byte; sends are recorded.
class _OwnerApi extends FakeApi {
  _OwnerApi(super.plans);

  final ownerPulses = <List<int>>[];
  final ownerLocks = <List<int>>[];
  final sent = <Uint8List>[];

  @override
  Future<Uint8List> buildPulseByOwner({
    required String owner,
    required List<int> planIds,
  }) async {
    ownerPulses.add(planIds);
    return Uint8List.fromList([1]);
  }

  @override
  Future<Uint8List> buildLockdownByOwner({
    required String owner,
    required List<int> planIds,
  }) async {
    ownerLocks.add(planIds);
    return Uint8List.fromList([2]);
  }

  @override
  Future<List<String>> sendSigned(List<Uint8List> signedTransactions) async {
    sent.addAll(signedTransactions);
    return ['sig'];
  }
}

/// Signs by echoing; counts approvals.
class _EchoWallet implements WalletBridge {
  int approvals = 0;

  @override
  Future<WalletSession> authorize() async =>
      WalletSession(publicKey: addr(1), authToken: 'web');

  @override
  Future<List<Uint8List>> signTransactions(List<Uint8List> txs) async {
    approvals++;
    return txs;
  }

  @override
  Future<void> deauthorize(String authToken) async {}
}

class _Harness {
  late SharedPreferences prefs;
  late FakeBackend backend;
  final opened = <String>[];
  final api = _OwnerApi(const []);
  final wallet = _EchoWallet();

  Future<void> pump(
    WidgetTester tester,
    Widget child, {
    required bool web,
    List<WebWallet> installed = const [_phantom],
    Map<String, Object> saved = const {},
    bool paymaster = false,
    List<VaultState>? plans,
  }) async {
    tester.view.physicalSize = const Size(800, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues(saved);
    prefs = await SharedPreferences.getInstance();
    backend = FakeBackend(installed, address: addr(1));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          prefsProvider.overrideWithValue(prefs),
          isWebProvider.overrideWithValue(web),
          webWalletProvider.overrideWithValue(
            WebWalletBridge(backend: backend, prefs: prefs),
          ),
          walletProvider.overrideWithValue(wallet),
          apiProvider.overrideWithValue(api),
          secureStoreProvider.overrideWithValue(FakeSecureStore()),
          openUrlProvider.overrideWithValue(opened.add),
          paymasterAvailableProvider.overrideWithValue(paymaster),
          guardAddressProvider.overrideWith((ref) async => addr(2)),
          claimProfilesProvider.overrideWith(
            (ref) async => const <ClaimProfile>[],
          ),
          feesProvider.overrideWith(
            (ref) async => FeeSchedule(
              treasury: addr(9),
              feeBpsPublic: 200,
              feeBpsPrivate: 300,
            ),
          ),
          walletBalanceProvider.overrideWith((ref) async => 1000000000),
          walletUsdcProvider.overrideWith((ref) async => 0),
          planUsdcProvider.overrideWith((ref, address) async => 0),
          if (plans != null) vaultsProvider.overrideWith((ref) async => plans),
        ],
        child: MaterialApp(home: Scaffold(body: child)),
      ),
    );
    await tester.pump();
    await tester.pump();
  }
}

void main() {
  group('wallet picker', () {
    testWidgets('lists both wallets, links the missing one, connects', (
      tester,
    ) async {
      final h = _Harness();
      await h.pump(tester, const WelcomeScreen(), web: true);
      expect(find.text('Web'), findsOneWidget);

      await tester.tap(find.text('Connect Phantom or Solflare'));
      await tester.pumpAndSettle();
      expect(find.text('Connect a wallet'), findsOneWidget);
      expect(find.text('Detected'), findsOneWidget);
      expect(find.text('Not installed in this browser'), findsOneWidget);

      await tester.tap(find.text('Install'));
      expect(h.opened, ['https://solflare.com/download']);

      await tester.tap(find.text('Phantom'));
      await tester.pumpAndSettle();
      expect(h.backend.connected, [WalletKind.phantom]);
      expect(h.prefs.getString('owner'), addr(1));
      expect(h.prefs.getString('web_wallet'), 'phantom');
    });

    testWidgets('marks the wallet used last', (tester) async {
      final h = _Harness();
      await h.pump(
        tester,
        const WelcomeScreen(),
        web: true,
        installed: const [_phantom, _solflare],
        saved: {'web_wallet': 'solflare'},
      );
      await tester.tap(find.text('Connect Phantom or Solflare'));
      await tester.pumpAndSettle();
      expect(find.text('Last used'), findsOneWidget);
      expect(find.text('Detected'), findsOneWidget);
      expect(find.text('Install'), findsNothing);

      // Dismissing connects nothing.
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      expect(h.backend.connected, isEmpty);
      expect(h.prefs.getString('owner'), isNull);
    });

    testWidgets('Android keeps the Seed Vault button', (tester) async {
      final h = _Harness();
      await h.pump(tester, const WelcomeScreen(), web: false);
      expect(find.text('Connect Seed Vault wallet'), findsOneWidget);
      expect(find.text('Web'), findsNothing);
    });

    testWidgets('welcome is the brand splash: skull, wordmark, tagline', (
      tester,
    ) async {
      final h = _Harness();
      await h.pump(tester, const WelcomeScreen(), web: false);
      expect(find.byType(DeadmanLockup), findsOneWidget);
      expect(find.byType(SkullMark), findsOneWidget);
      final tagline = tester.widget<Text>(
        find.byKey(const ValueKey('welcome-tagline')),
      );
      expect(tagline.data, 'CHECK IN, OR CHECK OUT.');
      expect(tagline.style?.fontFamily, contains('Silkscreen'));
      expect(find.bySemanticsLabel('Check in, or check out.'), findsOneWidget);
      expect(
        find.text('A dead man\'s switch for your Solana wallet.'),
        findsOneWidget,
      );
    });
  });

  group('settings gating', () {
    testWidgets('web hides phone-only features and links the app', (
      tester,
    ) async {
      final h = _Harness();
      await h.pump(
        tester,
        const SettingsTab(),
        web: true,
        saved: {'owner': addr(1), 'web_wallet': 'phantom'},
      );
      expect(find.text('Web'), findsOneWidget);
      expect(find.textContaining('· Phantom'), findsOneWidget);
      expect(find.text('Guard key'), findsOneWidget);
      expect(find.textContaining('· this browser'), findsOneWidget);
      expect(find.text('Move guard to this phone'), findsNothing);
      expect(find.text('Private rails check'), findsNothing);
      expect(find.text('Forget this browser'), findsOneWidget);
      // No paymaster: no SOL/USDC choice at all.
      expect(find.text('Pay network fees with'), findsNothing);

      await tester.tap(find.text('Get the Android app'));
      expect(h.opened, [AppConfig.androidAppUrl]);
    });

    testWidgets('web keeps USDC fees when a paymaster is configured', (
      tester,
    ) async {
      final h = _Harness();
      await h.pump(
        tester,
        const SettingsTab(),
        web: true,
        paymaster: true,
        saved: {'owner': addr(1)},
      );
      expect(find.text('Pay network fees with'), findsOneWidget);
    });

    testWidgets('Android is unchanged', (tester) async {
      final h = _Harness();
      await h.pump(
        tester,
        const SettingsTab(),
        web: false,
        saved: {'owner': addr(1)},
      );
      expect(find.text('Web'), findsNothing);
      expect(find.text('Get the Android app'), findsNothing);
      expect(find.text('Guard key'), findsOneWidget);
      expect(find.textContaining('· this phone'), findsOneWidget);
      expect(find.textContaining('· Seed Vault'), findsOneWidget);
      expect(find.text('Move guard to this phone'), findsOneWidget);
      expect(find.text('Private rails check'), findsOneWidget);
      expect(find.text('Forget this device'), findsOneWidget);
      expect(find.text('Pay network fees with'), findsOneWidget);
    });

    testWidgets('web panic locks every plan with one wallet approval', (
      tester,
    ) async {
      final h = _Harness();
      h.api.plans = [vault(planId: 0), vault(planId: 3, guard: addr(7))];
      await h.pump(
        tester,
        const SettingsTab(),
        web: true,
        saved: {'owner': addr(1)},
      );
      await tester.tap(find.text('Panic lockdown'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Approve in your wallet.'), findsOneWidget);
      await tester.tap(find.text('Lock down'));
      await tester.pumpAndSettle();
      expect(h.api.ownerLocks, [
        [0, 3],
      ]);
      expect(h.api.locked, isEmpty); // no guard-key path
      expect(h.wallet.approvals, 1);
      expect(find.text('Locked 2 plans.'), findsOneWidget);
    });
  });

  group('pulse', () {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final plans = [
      vault(planId: 0, label: 'Kids', lastPulse: now, ownerLastSeen: now),
      // Guarded elsewhere: the wallet still checks it in.
      vault(planId: 1, guard: addr(7), lastPulse: now, ownerLastSeen: now),
    ];

    testWidgets('web Check in checks in every plan with the wallet', (
      tester,
    ) async {
      final h = _Harness();
      h.api.plans = plans;
      await h.pump(
        tester,
        const PulseTab(),
        plans: plans,
        web: true,
        saved: {'owner': addr(1)},
      );
      expect(find.text('Move guard to this phone'), findsNothing);
      expect(find.text('Guarded by another device'), findsNothing);
      expect(_dmIcon(DMIcons.wallet), findsWidgets);
      // No pull-to-refresh with a mouse: the header carries a button.
      expect(find.byTooltip('Refresh'), findsOneWidget);
      expect(_dmIcon(DMIcons.fingerprint), findsNothing);

      await tester.tap(find.text('Check in'));
      // The tab ticks every second, so it never settles.
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(h.api.ownerPulses, [
        [0, 1],
      ]);
      expect(h.api.pulsed, isEmpty);
      expect(h.wallet.approvals, 1);
      expect(find.text('Pulse recorded on 2 plans.'), findsOneWidget);
      // The check-in toast leads with the pixel heart, as in the mockup.
      final heart = find.descendant(
        of: find.byType(SnackBar),
        matching: find.byType(PixelArt),
      );
      expect(tester.widget<PixelArt>(heart).sprite, PixelSprites.heart);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('Android still offers to move the guard', (tester) async {
      final h = _Harness();
      await h.pump(
        tester,
        const PulseTab(),
        plans: plans,
        web: false,
        saved: {'owner': addr(1)},
      );
      expect(find.text('Move guard to this phone'), findsOneWidget);
      expect(_dmIcon(DMIcons.fingerprint), findsOneWidget);
      expect(find.byTooltip('Refresh'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('WebFrame', () {
    Future<Size> sizeAt(WidgetTester tester, double width) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      const key = Key('app');
      await tester.pumpWidget(
        const MaterialApp(
          home: WebFrame(child: SizedBox.expand(key: key)),
        ),
      );
      return tester.getSize(find.byKey(key));
    }

    testWidgets('centers a phone-width column on wide windows', (tester) async {
      expect(await sizeAt(tester, 1400), const Size(WebFrame.maxWidth, 900));
    });

    testWidgets('fills narrow windows', (tester) async {
      expect(await sizeAt(tester, 420), const Size(420, 900));
    });
  });

  test('private routes point to the Android app on the web', () {
    expect(routeOffLabel('Cloak', web: true), 'Route via Cloak: Android app');
    expect(routeOffLabel('Zcash', web: false), 'Route via Zcash: mainnet only');
  });
}

Finder _dmIcon(DMIcons icon) =>
    find.byWidgetPredicate((w) => w is DMIcon && w.icon == icon);
