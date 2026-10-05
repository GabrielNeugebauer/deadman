import 'package:deadman/solana/deadman_api.dart';
import 'package:deadman/state/private_rails.dart';
import 'package:deadman/state/providers.dart';
import 'package:deadman/state/secure_store.dart';
import 'package:deadman/ui/screens/settings_tab.dart';
import 'package:deadman/ui/theme.dart';
import 'package:deadman/ui/widgets/brand/brand.dart';
import 'package:deadman/ui/widgets/pack_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../state/fakes.dart';

/// [vault] from the fakes, in lockdown until [lockedUntil].
VaultState _lockedPlan(int lockedUntil) {
  final v = vault();
  return VaultState(
    address: v.address,
    owner: v.owner,
    planId: v.planId,
    label: v.label,
    guard: v.guard,
    guardian: v.guardian,
    lockSecs: v.lockSecs,
    skipGraceSecs: v.skipGraceSecs,
    lastPulse: v.lastPulse,
    ownerLastSeen: v.ownerLastSeen,
    lockedUntil: lockedUntil,
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
}

class _Harness {
  late ProviderContainer container;
  late FakeApi api;

  Future<void> pump(
    WidgetTester tester, {
    List<VaultState> plans = const [],
    List<ClaimProfile> profiles = const [],
    bool duress = false,
  }) async {
    tester.view.physicalSize = const Size(800, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({'owner': addr(1)});
    final prefs = await SharedPreferences.getInstance();
    api = FakeApi(plans);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          prefsProvider.overrideWithValue(prefs),
          isWebProvider.overrideWithValue(false),
          apiProvider.overrideWithValue(api),
          secureStoreProvider.overrideWithValue(FakeSecureStore(profiles)),
          paymasterAvailableProvider.overrideWithValue(false),
          guardAddressProvider.overrideWith((ref) async => addr(2)),
          claimProfilesProvider.overrideWith((ref) async => profiles),
          feesProvider.overrideWith(
            (ref) async => FeeSchedule(
              treasury: addr(9),
              feeBpsPublic: 200,
              feeBpsPrivate: 300,
            ),
          ),
          subscriptionTermsProvider.overrideWith((ref) async => null),
          walletBalanceProvider.overrideWith((ref) async => 1000000000),
          walletUsdcProvider.overrideWith((ref) async => 0),
          vaultsProvider.overrideWith((ref) async => plans),
        ],
        child: MaterialApp(
          theme: buildTheme(),
          home: const Scaffold(body: SettingsTab()),
        ),
      ),
    );
    container = ProviderScope.containerOf(
      tester.element(find.byType(SettingsTab)),
    );
    container.read(sessionProvider.notifier).unlock(duress: duress);
    await tester.pump();
    await tester.pump();
  }
}

double _top(WidgetTester tester, String text) =>
    tester.getTopLeft(find.text(text)).dy;

void main() {
  final chip = find.byKey(const ValueKey('security-lock-chip'));
  int now() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  group('lock chip', () {
    testWidgets('hidden with no plans to lock', (tester) async {
      await _Harness().pump(tester);
      expect(find.text('Security'), findsOneWidget);
      expect(chip, findsNothing);
    });

    testWidgets('UNLOCKED while no plan is in lockdown', (tester) async {
      await _Harness().pump(tester, plans: [vault()]);
      expect(
        find.descendant(of: chip, matching: find.text('UNLOCKED')),
        findsOne,
      );
      final sticker = tester.widget<StatusSticker>(chip);
      expect(sticker.status, DMStatus.alive);
      // The alive skull belongs to check-ins, not to the lock state.
      expect(sticker.showSprite, isFalse);
      expect(
        find.descendant(of: chip, matching: find.byType(PixelArt)),
        findsNothing,
      );
    });

    testWidgets('LOCKED, in the locked color, during a lockdown', (
      tester,
    ) async {
      await _Harness().pump(tester, plans: [_lockedPlan(now() + 3600)]);
      expect(
        find.descendant(of: chip, matching: find.text('LOCKED')),
        findsOne,
      );
      expect(tester.widget<StatusSticker>(chip).status, DMStatus.locked);
      final lock = tester.widget<PixelArt>(
        find.descendant(of: chip, matching: find.byType(PixelArt)),
      );
      expect(lock.sprite, PixelSprites.lock);
      expect(lock.color, DM.bone);
    });

    testWidgets('a duress session never shows the lock it sent', (
      tester,
    ) async {
      await _Harness().pump(
        tester,
        plans: [_lockedPlan(now() + 3600)],
        duress: true,
      );
      expect(find.text('LOCKED'), findsNothing);
      expect(
        find.byWidgetPredicate(
          (w) => w is PixelArt && w.sprite == PixelSprites.lock,
        ),
        findsNothing,
      );
      expect(
        find.descendant(of: chip, matching: find.text('UNLOCKED')),
        findsOne,
      );
    });
  });

  testWidgets('follows the mockup order, then fees and this phone', (
    tester,
  ) async {
    await _Harness().pump(tester);
    expect(find.textContaining('· Seed Vault'), findsOneWidget);
    expect(find.textContaining('· this phone'), findsOneWidget);
    final order = [
      'Owner wallet',
      'Guard key',
      'Panic lockdown',
      'Move guard to this phone',
      'Receive privately',
      'Show recovery phrase',
      'Fees',
      'Pricing',
      'Network fees',
      'This phone',
      'Private rails check',
      'Lock app',
      'Forget this device',
    ];
    for (var i = 1; i < order.length; i++) {
      expect(
        _top(tester, order[i - 1]) < _top(tester, order[i]),
        isTrue,
        reason: '${order[i - 1]} above ${order[i]}',
      );
    }
  });

  testWidgets('rows lead with the pixel pack icons', (tester) async {
    await _Harness().pump(tester);
    Finder rowOf(String title) =>
        find.ancestor(of: find.text(title), matching: find.byType(DMListRow));
    DMIcons leadOf(String title) => tester
        .widget<DMIconTile>(
          find.descendant(of: rowOf(title), matching: find.byType(DMIconTile)),
        )
        .icon;
    expect(leadOf('Owner wallet'), DMIcons.wallet);
    expect(leadOf('Guard key'), DMIcons.key);
    expect(leadOf('Panic lockdown'), DMIcons.warning);
    expect(leadOf('Move guard to this phone'), DMIcons.swap);
    expect(leadOf('Show recovery phrase'), DMIcons.key);
    expect(leadOf('Restore receiving profiles from phrase'), DMIcons.history);
    expect(leadOf('Private rails check'), DMIcons.shieldPlus);
    expect(leadOf('Lock app'), DMIcons.lock);
    expect(leadOf('Forget this device'), DMIcons.logout);
    DMIcons? railOf(String rail) => tester
        .widget<DMIcon>(
          find
              .descendant(
                of: find.byKey(ValueKey('receive-$rail')),
                matching: find.byType(DMIcon),
              )
              .first,
        )
        .icon;
    expect(railOf('cloak'), DMIcons.cloak);
    expect(railOf('zcash'), DMIcons.shieldZ);
    final panic = tester.widget<DMIcon>(
      find.descendant(
        of: find.byKey(const ValueKey('panic-card')),
        matching: find.byType(DMIcon),
      ),
    );
    expect(panic.color, DM.flatline);
    final chevron = tester.widget<DMIcon>(
      find.descendant(
        of: rowOf('Private rails check'),
        matching: find.byWidgetPredicate(
          (w) => w is DMIcon && w.icon == DMIcons.chevronRight,
        ),
      ),
    );
    expect(chevron.color, DM.ash);
  });

  testWidgets('only the panic card carries a status border', (tester) async {
    await _Harness().pump(tester);
    final panic = tester.widget<DMCard>(
      find.byKey(const ValueKey('panic-card')),
    );
    expect(panic.borderColor, DM.flatline.withValues(alpha: 0.35));
    final others = tester
        .widgetList<DMCard>(find.byType(DMCard))
        .where((c) => c.key != const ValueKey('panic-card'));
    expect(others, isNotEmpty);
    for (final c in others) {
      expect(c.borderColor, DM.line);
    }
    final tile = tester.widget<IconTile>(
      find.descendant(
        of: find.byKey(const ValueKey('panic-card')),
        matching: find.byType(IconTile),
      ),
    );
    expect(tile.tone, DM.flatline);
  });

  testWidgets('panic asks first; Cancel locks nothing', (tester) async {
    final h = _Harness();
    await h.pump(tester, plans: [vault()]);
    await tester.tap(find.text('Panic lockdown'));
    await tester.pumpAndSettle();
    expect(find.text('Lock down vault?'), findsOneWidget);
    expect(find.textContaining('Inheritance keeps working.'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Lock down vault?'), findsNothing);
    expect(h.api.locked, isEmpty);
  });

  testWidgets('receive privately: + to set up, copy once set up', (
    tester,
  ) async {
    final profile = ClaimProfile(
      rail: Rail.zcash,
      key: await keyPair(5),
      destination: sampleZcashAddress,
    );
    await _Harness().pump(tester, profiles: [profile]);
    final cloak = find.byKey(const ValueKey('receive-cloak'));
    final zcash = find.byKey(const ValueKey('receive-zcash'));
    expect(
      find.descendant(of: cloak, matching: find.text('Not set up')),
      findsOne,
    );
    expect(
      find.descendant(
        of: cloak,
        matching: find.byWidgetPredicate(
          (w) => w is DMIcon && w.icon == DMIcons.plus,
        ),
      ),
      findsOne,
    );
    expect(
      find.descendant(of: zcash, matching: find.byTooltip('Copy claim code')),
      findsOne,
    );
    expect(
      find.descendant(of: zcash, matching: find.textContaining('Code ')),
      findsOne,
    );
  });

  testWidgets('Lock app returns to the PIN', (tester) async {
    final h = _Harness();
    await h.pump(tester);
    expect(h.container.read(sessionProvider).unlocked, isTrue);
    await tester.tap(find.text('Lock app'));
    await tester.pump();
    expect(h.container.read(sessionProvider).unlocked, isFalse);
  });

  testWidgets('pricing lists each rail rate in mono', (tester) async {
    await _Harness().pump(tester);
    for (final r in ['2%', '3%']) {
      final rate = tester.widget<Text>(find.text(r));
      expect(rate.style?.fontFamily, contains('JetBrains'));
    }
    expect(find.text('5%'), findsNothing);
  });
}
