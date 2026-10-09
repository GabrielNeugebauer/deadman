// Renders every main screen to build/brand_review_v2/*.png with the bundled
// brand fonts, at 412x915 and 412x732, for side-by-side review against the
// v2 brand book (docs/brand/v2, app mockups on pages 10-13).
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
import 'package:deadman/state/boney.dart';
import 'package:deadman/state/lockdown_retry.dart';
import 'package:deadman/state/private_rails.dart';
import 'package:deadman/state/providers.dart';
import 'package:deadman/ui/app.dart';
import 'package:deadman/ui/screens/lock_screen.dart';
import 'package:deadman/ui/screens/pin_setup_screen.dart';
import 'package:deadman/ui/screens/plans/plan_card_shell.dart';
import 'package:deadman/ui/screens/recovery_phrase_screen.dart';
import 'package:deadman/ui/screens/rules_editor.dart';
import 'package:deadman/ui/screens/vesting_editor.dart';
import 'package:deadman/ui/screens/welcome_screen.dart';
import 'package:deadman/ui/theme.dart';
import 'package:deadman/ui/widgets/brand/brand.dart';
import 'package:deadman/ui/widgets/editor/plan_steps.dart';
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
const _out = 'build/brand_review_v2';
const _phone = Size(412, 915);
const _short = Size(412, 732);

/// Every phone shot is taken at both sizes; [_suffix] names the short one.
const _sizes = {'': _phone, '_short': _short};
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
  await family('Silkscreen_regular', ['$fonts/Silkscreen-Regular.ttf']);
  await family('Silkscreen_700', ['$fonts/Silkscreen-Bold.ttf']);
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

VaultState _copy(VaultState v, {int? lockedUntil, String? guardian}) =>
    VaultState(
      address: v.address,
      owner: v.owner,
      planId: v.planId,
      label: v.label,
      guard: v.guard,
      guardian: guardian ?? v.guardian,
      lockSecs: v.lockSecs,
      skipGraceSecs: v.skipGraceSecs,
      lastPulse: v.lastPulse,
      ownerLastSeen: v.ownerLastSeen,
      lockedUntil: lockedUntil ?? v.lockedUntil,
      guardianReadyAt: v.guardianReadyAt,
      totalPulses: v.totalPulses,
      streak: v.streak,
      bestStreak: v.bestStreak,
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
              feeBpsPrivate: 300,
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
              feeBpsPrivate: 300,
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
Future<void> _editor(
  WidgetTester tester,
  Widget page, {
  Size size = _phone,
}) async {
  await _screen(
    tester,
    size: size,
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

    VaultState vestingOnly() => withPeriod(
      vestingVault(
        planId: 1,
        guard: addr(2),
        startAt: _now() - 500,
        withdrawableLamports: 2000000000,
        schedules: [schedule(mint: usdc, total: 1000000000, duration: 6000)],
      ),
      600,
    );

    /// The Plans screen with an active release plan, a vesting plan and
    /// two fully released plans (one of each kind), all collapsed.
    Future<void> plansWith(WidgetTester tester, {required Size size}) async {
      final now = _now();
      await _app(
        tester,
        size: size,
        plans: [
          kids(
            silentFor: 3600,
            rules: [
              rule(seed: 11, executedAt: now - 7200, amount: 1000),
              rule(seed: 10, afterSecs: 20 * 86400, amount: 100),
              rule(seed: 12, mint: usdc, afterSecs: 30 * 86400),
            ],
          ),
          vestingOnly(),
          vault(
            planId: 3,
            label: 'Brother',
            guard: addr(2),
            lastPulse: now - 40 * 86400,
            ownerLastSeen: now - 40 * 86400,
            withdrawableLamports: 5000000,
            rules: [rule(seed: 13, executedAt: now - 3 * 86400)],
          ),
          vestingVault(
            planId: 4,
            guard: addr(2),
            startAt: now - 90 * 86400,
            schedules: [
              schedule(
                mint: usdc,
                released: 1000000000,
                duration: 60 * 86400,
                executedAt: now - 30 * 86400,
              ),
            ],
          ),
        ],
        legacy: const [7],
      );
      await tester.tap(find.byKey(const Key('open-plans')));
      await tester.pumpAndSettle();
    }

    // Boney in every mood and every idle frame, on the tiles of the
    // "Meet Boney" board (09-reference-boards/mascot-concept.png).
    testWidgets('boney board', (tester) async {
      Widget tile(String label, Widget art, Color background, Color ink) =>
          SizedBox(
            width: 128,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  height: 150,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: background,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: DM.line),
                  ),
                  child: art,
                ),
                const SizedBox(height: 8),
                Text(label, style: DMType.outfit(size: 13, color: ink)),
              ],
            ),
          );
      await _screen(
        tester,
        size: const Size(1200, 520),
        Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 16,
                  children: [
                    for (final m in BoneyMood.values)
                      tile(
                        m.wire,
                        BoneyFigure(mood: m, size: 96, animate: false),
                        m.background,
                        m.status.color,
                      ),
                  ],
                ),
                const SizedBox(height: 24),
                Wrap(
                  spacing: 16,
                  children: [
                    for (final (i, f) in boneyIdle.indexed)
                      tile(
                        'idle $i · ${f.ms} ms',
                        PixelArt(
                          f.sprite,
                          size: 96,
                          color: DMStatus.alive.color,
                        ),
                        DM.deep,
                        DM.pulse,
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
      await _shot(tester, 'boney_board');
      await _unmount(tester);
    });

    for (final MapEntry(key: suffix, value: size) in _sizes.entries) {
      testWidgets('pulse states$suffix', (tester) async {
        final states = <String, List<VaultState>>{
          'pulse_alive': [kids(silentFor: 3600)],
          'pulse_counting_down': [kids(silentFor: 8 * 86400)],
          'pulse_due': [kids(silentFor: 10 * 86400 + 2892)],
          'pulse_locked': [
            _copy(kids(silentFor: 3600), lockedUntil: _now() + 29 * 86400),
          ],
          'pulse_released': [
            kids(
              silentFor: 3600,
              rules: [rule(seed: 10, executedAt: _now() - 60, amount: 100)],
            ),
          ],
          'pulse_vesting_only': [vestingOnly()],
          'pulse_arm_switch': const [],
        };
        for (final MapEntry(key: name, value: plans) in states.entries) {
          await _app(tester, plans: plans, size: size);
          await _shot(tester, '$name$suffix');
          await _unmount(tester);
        }

        // The due ring on its other phase, and the skull's legend.
        await _app(tester, plans: states['pulse_alive']!, size: size);
        await tester.tap(find.byKey(const Key('skull-button')));
        await tester.pumpAndSettle();
        await _shot(tester, 'pulse_moods$suffix');
        await _unmount(tester);
      });

      testWidgets('plans screen$suffix', (tester) async {
        await plansWith(tester, size: size);
        await _shot(tester, 'plans$suffix');

        // One card open: tiers, fee, actions and Cancel plan.
        await tester.ensureVisible(find.byKey(ValueKey('plan-${addr(100)}')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(ValueKey('plan-${addr(100)}')));
        await tester.pumpAndSettle();
        await _shot(tester, 'plans_expanded$suffix');

        await _tap(tester, 'Cancel plan');
        await _shot(tester, 'plans_cancel_inheritance$suffix');
        await tester.tap(find.text('Keep plan'));
        await tester.pumpAndSettle();
        await _top(tester);
        await tester.ensureVisible(find.byKey(ValueKey('plan-${addr(100)}')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(ValueKey('plan-${addr(100)}')));
        await tester.pumpAndSettle();

        await tester.ensureVisible(find.byKey(ValueKey('plan-${addr(101)}')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(ValueKey('plan-${addr(101)}')));
        await tester.pumpAndSettle();
        await _tap(tester, 'Cancel plan');
        await _shot(tester, 'plans_cancel_vesting$suffix');
        await tester.tap(find.text('Keep plan'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.byKey(ValueKey('plan-${addr(101)}')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(ValueKey('plan-${addr(101)}')));
        await tester.pumpAndSettle();

        // The Released group at the bottom, closed, then open with one card.
        await tester.drag(_down, const Offset(0, -20000));
        await tester.pumpAndSettle();
        await _shot(tester, 'plans_released_closed$suffix');
        await tester.tap(find.byKey(const Key('released-section')));
        await tester.pumpAndSettle();
        await tester.drag(_down, const Offset(0, -20000));
        await tester.pumpAndSettle();
        await _shot(tester, 'plans_released_open$suffix');
        await tester.ensureVisible(find.byKey(ValueKey('plan-${addr(103)}')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(ValueKey('plan-${addr(103)}')));
        await tester.pumpAndSettle();
        await tester.drag(_down, const Offset(0, -20000));
        await tester.pumpAndSettle();
        await _shot(tester, 'plans_released_card$suffix');
        await _unmount(tester);

        await _app(
          tester,
          size: size,
          plans: [kids(silentFor: 8 * 86400)],
        );
        await tester.tap(find.byKey(const Key('open-plans')));
        await tester.pumpAndSettle();
        await _shot(tester, 'plans_counting_down$suffix');
        await _unmount(tester);

        await _app(
          tester,
          size: size,
          plans: [kids(silentFor: 10 * 86400 + 2892)],
        );
        await tester.tap(find.byKey(const Key('open-plans')));
        await tester.pumpAndSettle();
        await _shot(tester, 'plans_due$suffix');
        await _unmount(tester);

        // Every plan closed while the screen was open.
        final live = [kids(silentFor: 3600)];
        await _app(tester, size: size, plans: live);
        await tester.tap(find.byKey(const Key('open-plans')));
        await tester.pumpAndSettle();
        live.clear();
        ProviderScope.containerOf(tester.element(find.byType(MaterialApp)))
            .invalidate(vaultsProvider);
        await tester.pumpAndSettle();
        await _shot(tester, 'plans_empty$suffix');
        await _unmount(tester);
      });
    }

    testWidgets('plans screen, tall', (tester) async {
      await plansWith(tester, size: const Size(412, 3600));
      await _shot(tester, 'plans_tall');
      await tester.tap(find.byKey(const Key('released-section')));
      await tester.pumpAndSettle();
      final headers = find.byWidgetPredicate(
        (w) =>
            w is ExpandToggle &&
            !w.open &&
            w.key is ValueKey<String> &&
            (w.key! as ValueKey<String>).value.startsWith('plan-'),
      );
      while (headers.evaluate().isNotEmpty) {
        await tester.ensureVisible(headers.first);
        await tester.tap(headers.first);
        await tester.pumpAndSettle();
      }
      await _top(tester);
      await _shot(tester, 'plans_tall_open');
      await _unmount(tester);
    });

    for (final MapEntry(key: suffix, value: size) in _sizes.entries) {
      testWidgets('circle states$suffix', (tester) async {
        final now = _now();
        final me = addr(10);
        await _app(
          tester,
          size: size,
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
            ),
          ],
          tokens: {'${vault().address}:$usdc': 5000000},
        );
        await _shot(tester, 'circle_due$suffix');
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
            ),
            _copy(
              vault(planId: 2, label: 'Dad', lastPulse: now - 60),
              lockedUntil: now + 29 * 86400 + 30,
              guardian: me,
            ),
          ],
        );
        await _shot(tester, 'circle_states$suffix');
        await _unmount(tester);

        // Claim quote under a funded USDC tier.
        final usdcTier = vault(rules: [rule(mint: usdc)]);
        await _app(
          tester,
          size: size,
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
        await _shot(tester, 'circle_claim_quote$suffix');
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
        await _shot(tester, 'circle_vesting_waiting$suffix');
        await _unmount(tester);

        await _app(tester, size: size, owner: me, tab: 1);
        await _shot(tester, 'circle_empty$suffix');
        await _unmount(tester);
      });

      testWidgets('security$suffix', (tester) async {
        await _app(tester, size: size, tab: 2, plans: [kids(silentFor: 3600)]);
        await _shot(tester, 'security$suffix');
        await _unmount(tester);
        await _app(
          tester,
          tab: 2,
          size: const Size(412, 2400),
          plans: [kids(silentFor: 3600)],
        );
        await _shot(tester, 'security_tall$suffix');
        await _unmount(tester);
      });

      testWidgets('welcome, PIN, lock, recovery$suffix', (tester) async {
        await _screen(tester, size: size, const SplashScreen());
        await _shot(tester, 'splash$suffix');
        await _unmount(tester);

        await _screen(tester, size: size, const WelcomeScreen());
        await _shot(tester, 'welcome$suffix');
        await _unmount(tester);

        await _screen(tester, size: size, PinSetupScreen(onDone: () {}));
        await _shot(tester, 'pin_setup$suffix');
        for (final d in '123'.split('')) {
          await tester.tap(find.widgetWithText(TextButton, d));
          await tester.pump();
        }
        await _shot(tester, 'pin_setup_typing$suffix');
        await _unmount(tester);

        await _screen(tester, size: size, const LockScreen());
        await _shot(tester, 'lock$suffix');
        await _unmount(tester);

        await _screen(
          tester,
          const RecoveryPhrasePage(
            phrase:
                'abandon ability able about above absent absorb abstract '
                'absurd abuse access accident',
          ),
        );
        await _shot(tester, 'recovery_phrase$suffix');
        await _unmount(tester);
      });

      testWidgets('release plan editor$suffix', (tester) async {
        await _editor(tester, size: size, const RulesEditorPage(vault: null));
        await _shot(tester, 'editor_payout_empty$suffix');
        await tester.enterText(
          find.byKey(const ValueKey('recipient-address')),
          addr(12),
        );
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pumpAndSettle();
        Future<void> reveal(Finder f) async {
          // The focused address field keeps scrolling itself back into view.
          FocusManager.instance.primaryFocus?.unfocus();
          await tester.pumpAndSettle();
          await tester.ensureVisible(f);
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
        await _shot(tester, 'editor_payout_warning$suffix');
        await _tap(tester, 'Done');
        await _top(tester);
        await _shot(tester, 'editor_payouts_step$suffix');
        await _tap(tester, 'Next: fund the plan');
        await tester.enterText(
          find.descendant(
            of: find.widgetWithText(LabeledField, 'Put in this plan'),
            matching: find.byType(TextField),
          ),
          '1',
        );
        await tester.pumpAndSettle();
        await _top(tester);
        await _shot(tester, 'editor_fund_step$suffix');
        await _tap(tester, 'Next: review');
        await _top(tester);
        await _shot(tester, 'editor_review_step$suffix');
        await _tap(tester, 'Create plan');
        await _shot(tester, 'editor_review_blocked$suffix');
        await _unmount(tester);
      });

      testWidgets('vesting editor$suffix', (tester) async {
        await _editor(tester, size: size, const VestingEditorPage());
        await _shot(tester, 'vesting_start$suffix');
        await _tap(tester, 'Add a schedule');
        await tester.enterText(
          find.byKey(const ValueKey('recipient-address')),
          addr(30),
        );
        await tester.enterText(find.byKey(const ValueKey('vest-total')), '500');
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pumpAndSettle();
        await _top(tester);
        await _shot(tester, 'vesting_schedule_editor$suffix');
        await _tap(tester, 'Done');
        await _top(tester);
        await _shot(tester, 'vesting_schedules_step$suffix');
        await _tap(tester, 'Next: fund the plan');
        await _top(tester);
        await _shot(tester, 'vesting_fund_step$suffix');
        await _tap(tester, 'Next: review');
        await _top(tester);
        await _shot(tester, 'vesting_review_step$suffix');
        await _unmount(tester);
      });
    }
  });
}
