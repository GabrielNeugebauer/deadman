// Renders every main screen to build/brand_review/*.png with the bundled
// brand fonts, for side-by-side review against docs/brand/ui-reference.
//
//   flutter test test/brand_review --dart-define=BRAND_RENDER=true
//
// Skipped in the normal suite.
@Tags(['render'])
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:deadman/core/config.dart';
import 'package:deadman/solana/deadman_api.dart';
import 'package:deadman/state/actions.dart';
import 'package:deadman/state/lockdown_retry.dart';
import 'package:deadman/state/private_rails.dart';
import 'package:deadman/state/providers.dart';
import 'package:deadman/ui/app.dart';
import 'package:deadman/ui/screens/lock_screen.dart';
import 'package:deadman/ui/screens/pin_setup_screen.dart';
import 'package:deadman/ui/screens/recovery_phrase_screen.dart';
import 'package:deadman/ui/screens/rules_editor.dart';
import 'package:deadman/ui/screens/vesting_editor.dart';
import 'package:deadman/ui/screens/welcome_screen.dart';
import 'package:deadman/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:solana/solana.dart' show Ed25519HDKeyPair;

import '../state/fakes.dart';
import '../state/installment_fakes.dart';

const _enabled = bool.fromEnvironment('BRAND_RENDER');
const _out = 'build/brand_review';
const _phone = Size(412, 915);
const _root = Key('render-root');
const usdc = AppConfig.usdcMint;

Future<void> _loadFonts() async {
  Future<void> family(String name, List<String> files) async {
    final loader = FontLoader(name);
    for (final f in files) {
      final bytes = File(f).readAsBytesSync();
      loader.addFont(Future.value(ByteData.sublistView(bytes)));
    }
    await loader.load();
  }

  const fonts = 'assets/brand/fonts';
  const outfit = {
    'regular': 'Regular',
    '500': 'Medium',
    '600': 'SemiBold',
    '700': 'Bold',
    '800': 'ExtraBold',
  };
  const mono = {
    'regular': 'Regular',
    '500': 'Medium',
    '600': 'SemiBold',
    '700': 'Bold',
  };
  for (final e in outfit.entries) {
    await family('Outfit_${e.key}', ['$fonts/Outfit-${e.value}.ttf']);
  }
  for (final e in mono.entries) {
    await family('JetBrainsMono_${e.key}', [
      '$fonts/JetBrainsMono-${e.value}.ttf',
    ]);
  }
  final sdk = Platform.environment['FLUTTER_ROOT'] ?? '/home/gabriel/flutter';
  final material = '$sdk/bin/cache/artifacts/material_fonts';
  await family('MaterialIcons', ['$material/MaterialIcons-Regular.otf']);
  await family('Roboto', [
    '$material/Roboto-Regular.ttf',
    '$material/Roboto-Medium.ttf',
    '$material/Roboto-Bold.ttf',
  ]);
}

/// Captures the screen to `build/brand_review/[name].png`.
Future<void> _shot(WidgetTester tester, String name) async {
  for (var i = 0; i < 3; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  final ro = tester.renderObject<RenderRepaintBoundary>(find.byKey(_root));
  await tester.runAsync(() async {
    final image = await ro.toImage(pixelRatio: 2);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    Directory(_out).createSync(recursive: true);
    File('$_out/$name.png').writeAsBytesSync(png!.buffer.asUint8List());
  });
}

void _size(WidgetTester tester, Size logical) {
  tester.view.physicalSize = logical * 2;
  tester.view.devicePixelRatio = 2;
  tester.view.padding = const FakeViewPadding(top: 64, bottom: 32);
  tester.view.viewPadding = const FakeViewPadding(top: 64, bottom: 32);
  addTearDown(tester.view.reset);
}

class _Store extends FakeSecureStore {
  @override
  Future<Ed25519HDKeyPair?> loadGuard() async => null;

  @override
  Future<bool> hasPins() async => true;
}

int _now() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

VaultState _copy(
  VaultState v, {
  int? lockedUntil,
  String? guardian,
  int? streak,
}) => VaultState(
  address: v.address,
  owner: v.owner,
  planId: v.planId,
  label: v.label,
  guard: v.guard,
  guardian: guardian ?? v.guardian,
  intervalSecs: v.intervalSecs,
  lockSecs: v.lockSecs,
  skipGraceSecs: v.skipGraceSecs,
  lastPulse: v.lastPulse,
  ownerLastSeen: v.ownerLastSeen,
  lockedUntil: lockedUntil ?? v.lockedUntil,
  guardianReadyAt: v.guardianReadyAt,
  totalPulses: v.totalPulses,
  streak: streak ?? v.streak,
  bestStreak: streak ?? v.bestStreak,
  rules: v.rules,
  lamports: v.lamports,
  withdrawableLamports: v.withdrawableLamports,
  kind: v.kind,
  startAt: v.startAt,
  revocable: v.revocable,
  revokedAt: v.revokedAt,
);

class _QuoteApi extends FakeApi {
  _QuoteApi(super.plans, this.quote);
  final ClaimQuote quote;

  @override
  Future<ClaimQuote> quoteClaim({
    required String claimer,
    required String vaultOwner,
    required int planId,
    required int index,
  }) async => quote;
}

/// The real app shell, unlocked, on [tab].
Future<void> _app(
  WidgetTester tester, {
  List<VaultState> plans = const [],
  List<VaultState> watched = const [],
  String owner = '',
  int tab = 0,
  SubscriptionTerms? terms,
  List<int> legacy = const [],
  FakeApi? api,
  Map<String, int> tokens = const {},
  Size size = _phone,
}) async {
  _size(tester, size);
  final who = owner.isEmpty ? addr(1) : owner;
  SharedPreferences.setMockInitialValues({'owner': who});
  final prefs = await SharedPreferences.getInstance();
  final fake = (api ?? FakeApi(plans))..tokens.addAll(tokens);
  final cloak = FakeCloakRoute(live: false);
  await tester.pumpWidget(
    RepaintBoundary(
      key: _root,
      child: ProviderScope(
        overrides: [
          prefsProvider.overrideWithValue(prefs),
          isWebProvider.overrideWithValue(false),
          apiProvider.overrideWithValue(fake),
          secureStoreProvider.overrideWithValue(_Store()),
          vaultsProvider.overrideWith((ref) async => plans),
          watchedVaultsProvider.overrideWith((ref) async => watched),
          legacyPlansProvider.overrideWith((ref) async => legacy),
          guardAddressProvider.overrideWith((ref) async => addr(2)),
          planUsdcProvider.overrideWith((ref, address) async => 250000000),
          planTokenBalancesProvider.overrideWith((ref) async => const {}),
          subscriptionTermsProvider.overrideWith((ref) async => terms),
          accountSubscriptionProvider.overrideWith((ref) async => null),
          walletTokenProvider.overrideWith((ref, mint) async => 7000000),
          walletBalanceProvider.overrideWith((ref) async => 1000000000),
          walletUsdcProvider.overrideWith((ref) async => 0),
          paymasterAvailableProvider.overrideWithValue(false),
          claimProfilesProvider.overrideWith((ref) async => const []),
          zcashRouteProvider.overrideWithValue(FakeZcashRoute(live: false)),
          cloakRouteProvider.overrideWith((ref) async => cloak),
          cloakStatusRouteProvider.overrideWithValue(cloak),
          privateRailsLiveProvider.overrideWithValue(false),
          biometricProvider.overrideWithValue((_) async => true),
          statusPollIntervalProvider.overrideWithValue(Duration.zero),
          feesProvider.overrideWith(
            (ref) async => FeeSchedule(
              treasury: addr(9),
              feeBpsPublic: 200,
              feeBpsPrivate: 500,
            ),
          ),
        ],
        child: const DeadmanApp(),
      ),
    ),
  );
  await tester.pump();
  ProviderScope.containerOf(tester.element(find.byType(MaterialApp)))
      .read(sessionProvider.notifier)
      .unlock(duress: false);
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  if (tab > 0) {
    await tester.tap(find.text(['Pulse', 'Circle', 'Security'][tab]).last);
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }
}

/// A bare screen (no shell) with the brand theme.
Future<ProviderContainer> _screen(
  WidgetTester tester,
  Widget child, {
  Size size = _phone,
}) async {
  _size(tester, size);
  SharedPreferences.setMockInitialValues({'owner': addr(1)});
  final prefs = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    RepaintBoundary(
      key: _root,
      child: ProviderScope(
        overrides: [
          prefsProvider.overrideWithValue(prefs),
          isWebProvider.overrideWithValue(false),
          secureStoreProvider.overrideWithValue(_Store()),
          apiProvider.overrideWithValue(FakeApi(const [])),
          lockdownRetrierProvider.overrideWithValue(
            LockdownRetrier(
              pending: PendingLockdown(prefs),
              attempt: (owner) async {},
            ),
          ),
          walletTokenProvider.overrideWith((ref, mint) async => 2000000000),
          walletBalanceProvider.overrideWith((ref) async => 2000000000),
          feesProvider.overrideWith(
            (ref) async => FeeSchedule(
              treasury: addr(9),
              feeBpsPublic: 200,
              feeBpsPrivate: 500,
            ),
          ),
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildTheme(),
          home: child,
        ),
      ),
    ),
  );
  await tester.pump();
  return ProviderScope.containerOf(tester.element(find.byWidget(child)));
}

/// Opens [page] from a launcher so its back button and route are real.
Future<void> _editor(WidgetTester tester, Widget page) async {
  await _screen(
    tester,
    Builder(
      builder: (context) => Scaffold(
        body: TextButton(
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute<void>(builder: (_) => page),
          ),
          child: const Text('open'),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

final _down = find
    .byWidgetPredicate(
      (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
    )
    .last;

Future<void> _tap(WidgetTester tester, String text) async {
  for (var i = 0; i < 60 && find.text(text).evaluate().isEmpty; i++) {
    await tester.drag(_down, const Offset(0, -200));
    await tester.pump();
  }
  await tester.ensureVisible(find.text(text).first);
  await tester.pumpAndSettle();
  await tester.tap(find.text(text).first);
  await tester.pumpAndSettle();
}

Future<void> _top(WidgetTester tester) async {
  await tester.drag(_down, const Offset(0, 20000));
  await tester.pumpAndSettle();
}

Future<void> _unmount(WidgetTester tester) =>
    tester.pumpWidget(const SizedBox());

void main() {
  setUpAll(() async {
    if (_enabled) await _loadFonts();
  });

  group('brand review renders', skip: !_enabled, () {
    VaultState kids({required int silentFor, List<RuleState>? rules}) {
      final now = _now();
      return vault(
        planId: 0,
        label: 'Kids',
        guard: addr(2),
        lastPulse: now - silentFor,
        ownerLastSeen: now,
        withdrawableLamports: 2500000000,
        rules:
            rules ??
            [
              rule(seed: 10, amount: 100),
              rule(seed: 11, afterSecs: 20 * 86400, amount: 1000),
            ],
      );
    }

    testWidgets('pulse states', (tester) async {
      await _app(tester, plans: [kids(silentFor: 3600)]);
      await _shot(tester, 'pulse_on_track');
      await _unmount(tester);

      await _app(tester, plans: [kids(silentFor: 6 * 86400 + 43200)]);
      await _shot(tester, 'pulse_attention_soon');
      await _unmount(tester);

      await _app(tester, plans: [kids(silentFor: 8 * 86400)]);
      await _shot(tester, 'pulse_overdue');
      await _unmount(tester);

      await _app(tester, plans: [kids(silentFor: 10 * 86400 + 20)]);
      await _shot(tester, 'pulse_due');
      await _unmount(tester);

      await _app(
        tester,
        plans: [_copy(kids(silentFor: 3600), lockedUntil: _now() + 29 * 86400)],
      );
      await _shot(tester, 'pulse_locked');
      await _unmount(tester);

      await _app(tester, plans: const []);
      await _shot(tester, 'pulse_arm_switch');
      await _unmount(tester);
    });

    testWidgets('pulse plan cards, tall', (tester) async {
      final now = _now();
      final start = now - 500;
      final vesting = withPeriod(
        vestingVault(
          planId: 1,
          guard: addr(2),
          startAt: start,
          withdrawableLamports: 2000000000,
          schedules: [schedule(mint: usdc, total: 1000000000, duration: 6000)],
        ),
        600,
      );
      await _app(
        tester,
        size: const Size(412, 3000),
        plans: [
          kids(
            silentFor: 3600,
            rules: [
              rule(seed: 11, executedAt: now - 7200, amount: 1000),
              rule(seed: 10, afterSecs: 20 * 86400, amount: 100),
              rule(seed: 12, mint: usdc, afterSecs: 30 * 86400),
            ],
          ),
          vesting,
        ],
        legacy: const [7],
        terms: const SubscriptionTerms(
          pricePerPeriod: 4990000,
          periodSecs: 30 * 86400,
          mint: usdc,
          minPeriods: 12,
        ),
      );
      await _shot(tester, 'pulse_plan_cards_tall');
      await _unmount(tester);
    });

    testWidgets('circle states', (tester) async {
      final now = _now();
      final me = addr(10);
      await _app(
        tester,
        owner: me,
        tab: 1,
        watched: [
          vault(
            label: 'Test',
            withdrawableLamports: 1000000000,
            rules: [rule(mint: usdc)],
          ),
          _copy(
            vault(
              planId: 1,
              label: 'TEST USDC',
              lastPulse: now - 8 * 86400 - 7200,
              rules: [rule(mint: usdc)],
            ),
            streak: 4,
          ),
        ],
        tokens: {'${vault().address}:$usdc': 5000000},
      );
      await _shot(tester, 'circle_due');
      await _unmount(tester);

      await _app(
        tester,
        owner: me,
        tab: 1,
        size: const Size(412, 1800),
        watched: [
          vault(rules: [rule(executedAt: now - 3)]),
          _copy(
            vault(
              planId: 1,
              label: 'Mom',
              lastPulse: now - 8000,
              rules: [rule(afterSecs: 30 * 86400, amount: 2000, mint: usdc)],
            ),
            streak: 31,
          ),
          _copy(
            vault(planId: 2, label: 'Dad', lastPulse: now - 60),
            lockedUntil: now + 29 * 86400 + 30,
            guardian: me,
          ),
        ],
      );
      await _shot(tester, 'circle_states');
      await _unmount(tester);

      // Claim quote under a funded USDC tier.
      final usdcTier = vault(rules: [rule(mint: usdc)]);
      await _app(
        tester,
        owner: me,
        tab: 1,
        watched: [usdcTier],
        tokens: {'${usdcTier.address}:$usdc': 5000000},
        api: _QuoteApi(
          const [],
          const ClaimQuote(
            payer: ClaimPayer.payout,
            mint: usdc,
            net: 4900000,
            feeToken: usdc,
            feeAmount: 20000,
          ),
        ),
      );
      await _shot(tester, 'circle_claim_quote');
      await _unmount(tester);

      // Vesting installments + waiting for funds.
      await _app(
        tester,
        owner: me,
        tab: 1,
        size: const Size(412, 1800),
        watched: [
          withPeriod(
            vestingVault(
              startAt: now - 150,
              withdrawableLamports: 1000000000,
              schedules: [
                schedule(seed: 10, duration: 600, released: 100000000),
              ],
            ),
            60,
          ),
          vault(
            planId: 3,
            label: 'Empty',
            rules: [rule(mint: usdc)],
          ),
        ],
        api: _QuoteApi(
          const [],
          const ClaimQuote(payer: ClaimPayer.sponsor, mint: null, net: 1),
        ),
      );
      await _shot(tester, 'circle_vesting_waiting');
      await _unmount(tester);

      await _app(tester, owner: me, tab: 1);
      await _shot(tester, 'circle_empty');
      await _unmount(tester);
    });

    testWidgets('security', (tester) async {
      await _app(tester, tab: 2, plans: [kids(silentFor: 3600)]);
      await _shot(tester, 'security');
      await _unmount(tester);
      await _app(
        tester,
        tab: 2,
        size: const Size(412, 2400),
        plans: [kids(silentFor: 3600)],
      );
      await _shot(tester, 'security_tall');
      await _unmount(tester);
    });

    testWidgets('welcome, PIN, lock, recovery', (tester) async {
      await _screen(tester, const WelcomeScreen());
      await _shot(tester, 'welcome');
      await _unmount(tester);

      await _screen(tester, PinSetupScreen(onDone: () {}));
      await _shot(tester, 'pin_setup');
      for (final d in '123'.split('')) {
        await tester.tap(find.widgetWithText(TextButton, d));
        await tester.pump();
      }
      await _shot(tester, 'pin_setup_typing');
      await _unmount(tester);

      await _screen(tester, const LockScreen());
      await _shot(tester, 'lock');
      await _unmount(tester);

      await _screen(
        tester,
        const RecoveryPhrasePage(
          phrase:
              'abandon ability able about above absent absorb abstract '
              'absurd abuse access accident',
        ),
      );
      await _shot(tester, 'recovery_phrase');
      await _unmount(tester);
    });

    testWidgets('release plan editor', (tester) async {
      await _editor(tester, const RulesEditorPage(vault: null));
      await _shot(tester, 'editor_payout_empty');
      await tester.enterText(
        find.widgetWithText(TextField, 'Their wallet address or claim code'),
        addr(12),
      );
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      Future<void> reveal(Finder f) async {
        await tester.scrollUntilVisible(f, 200, scrollable: _down);
        await tester.drag(_down, const Offset(0, -250));
        await tester.pumpAndSettle();
      }

      final chip = find.widgetWithText(ChoiceChip, 'USDC');
      await reveal(chip);
      await tester.tap(chip);
      await tester.pump();
      final field = find.byKey(const ValueKey('share-field'));
      await reveal(field);
      await tester.enterText(field, '1');
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      await tester.drag(_down, const Offset(0, 250));
      await tester.pumpAndSettle();
      await _shot(tester, 'editor_payout_warning');
      await _tap(tester, 'Done');
      await _top(tester);
      await _shot(tester, 'editor_payouts_step');
      await _tap(tester, 'Next: fund the plan');
      await tester.enterText(
        find.widgetWithText(TextField, 'Put in this plan'),
        '1',
      );
      await tester.pumpAndSettle();
      await _top(tester);
      await _shot(tester, 'editor_fund_step');
      await _tap(tester, 'Next: review');
      await _top(tester);
      await _shot(tester, 'editor_review_step');
      await _tap(tester, 'Create plan');
      await _shot(tester, 'editor_review_blocked');
      await _unmount(tester);
    });

    testWidgets('vesting editor', (tester) async {
      await _editor(tester, const VestingEditorPage());
      await _shot(tester, 'vesting_start');
      await _tap(tester, 'Add a schedule');
      await tester.enterText(
        find.widgetWithText(TextField, 'Their wallet address or claim code'),
        addr(30),
      );
      await tester.enterText(find.byKey(const ValueKey('vest-total')), '500');
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      await _top(tester);
      await _shot(tester, 'vesting_schedule_editor');
      await _tap(tester, 'Done');
      await _top(tester);
      await _shot(tester, 'vesting_schedules_step');
      await _tap(tester, 'Next: fund the plan');
      await _top(tester);
      await _shot(tester, 'vesting_fund_step');
      await _tap(tester, 'Next: review');
      await _top(tester);
      await _shot(tester, 'vesting_review_step');
      await _unmount(tester);
    });
  });
}
