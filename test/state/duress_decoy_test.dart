import 'dart:typed_data';

import 'package:bip39/bip39.dart' as bip39;
import 'package:deadman/core/config.dart';
import 'package:deadman/solana/deadman_api.dart';
import 'package:deadman/state/actions.dart';
import 'package:deadman/state/boney_skin.dart';
import 'package:deadman/state/decoy_wallet.dart';
import 'package:deadman/state/lockdown_retry.dart';
import 'package:deadman/state/nfts.dart';
import 'package:deadman/state/plan_math.dart';
import 'package:deadman/state/private_rails.dart';
import 'package:deadman/state/providers.dart';
import 'package:deadman/state/secure_store.dart';
import 'package:deadman/wallet/wallet_bridge.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes.dart';

const _usdc = AppConfig.usdcMint;
const _skr = AppConfig.skrMint;

/// The fee schedule as configured: 2%, 1.5% for SKR, 10% of it burned.
final _fees = FeeSchedule(
  treasury: addr(9),
  feeBpsPublic: 200,
  feeBpsPrivate: 200,
  skrMint: _skr,
  feeBpsSkr: 150,
  skrBurnBps: 1000,
);

/// The chain. Only the public, owner-independent reads a duress session
/// may make are answered; any other call (every build, send, guard- or
/// key-signed send, and every read of an owner's accounts) is recorded and
/// fails.
class _Chain implements DeadmanApi {
  final calls = <String>[];

  @override
  String? feeToken;

  @override
  Future<FeeSchedule> fetchFees() async => _fees;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    final name = invocation.memberName.toString();
    calls.add(name.substring(8, name.length - 2));
    throw StateError('chain call under duress: $name');
  }
}

/// The wallet app: never asked to sign or connect under duress.
class _Wallet implements WalletBridge {
  final calls = <String>[];

  @override
  Future<WalletSession> authorize() async {
    calls.add('authorize');
    throw StateError('authorize under duress');
  }

  @override
  Future<List<Uint8List>> signTransactions(List<Uint8List> txs) async {
    calls.add('sign');
    throw StateError('sign under duress');
  }

  @override
  Future<void> deauthorize(String authToken) async {}
}

/// The phone's secure storage: never read under duress (no real guard,
/// receiving profile or recovery phrase).
class _Store implements SecureStore {
  final calls = <String>[];

  @override
  dynamic noSuchMethod(Invocation invocation) {
    final name = invocation.memberName.toString();
    calls.add(name.substring(8, name.length - 2));
    throw StateError('secure store read under duress: $name');
  }
}

typedef _Rig = ({
  ProviderContainer c,
  _Chain chain,
  _Wallet wallet,
  _Store store,
  List<String> lockdowns,
});

Future<_Rig> _rig({Map<String, Object> saved = const {}}) async {
  SharedPreferences.setMockInitialValues({'owner': addr(1), ...saved});
  final prefs = await SharedPreferences.getInstance();
  final chain = _Chain();
  final wallet = _Wallet();
  final store = _Store();
  final lockdowns = <String>[];
  final c = ProviderContainer(
    overrides: [
      prefsProvider.overrideWithValue(prefs),
      apiProvider.overrideWithValue(chain),
      walletProvider.overrideWithValue(wallet),
      secureStoreProvider.overrideWithValue(store),
      biometricProvider.overrideWithValue((_) async => true),
      decoyLatencyProvider.overrideWithValue(Duration.zero),
      boneyHostProvider.overrideWithValue(null),
      privateRailsLiveProvider.overrideWithValue(false),
      // The silent lockdown of the real plans: recorded, not sent.
      lockdownRetrierProvider.overrideWithValue(
        LockdownRetrier(
          pending: PendingLockdown(prefs),
          attempt: (owner) async => lockdowns.add(owner),
        ),
      ),
    ],
  );
  addTearDown(c.dispose);
  c.read(sessionProvider.notifier).unlock(duress: true);
  return (
    c: c,
    chain: chain,
    wallet: wallet,
    store: store,
    lockdowns: lockdowns,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('duress session', () {
    test('shows the decoy wallet, never the real owner', () async {
      final r = await _rig();
      final s = r.c.read(sessionProvider);
      expect(s.realOwner, addr(1));
      expect(s.owner, isNot(addr(1)));
      expect(s.owner, decoyOwnerOf(addr(1)));
      final plans = await r.c.read(vaultsProvider.future);
      expect(plans, isNotEmpty);
      expect(plans.every((v) => v.owner == s.owner), isTrue);
      expect(plans.any((v) => v.isLocked(nowSecs())), isFalse);
      expect(await r.c.read(walletBalanceProvider.future), greaterThan(0));
      expect(await r.c.read(walletUsdcProvider.future), greaterThan(0));
      expect(await r.c.read(watchedVaultsProvider.future), hasLength(1));
      expect(await r.c.read(guardAddressProvider.future), isNot(addr(2)));
      expect(await r.c.read(claimProfilesProvider.future), isEmpty);
      expect(r.c.read(transferHistoryProvider), isEmpty);
      // The public fee schedule still comes from the chain.
      expect(await r.c.read(feesProvider.future), same(_fees));
      expect(r.chain.calls, isEmpty);
      expect(r.store.calls, isEmpty);
    });

    test('the same decoy every time for the same wallet, another for '
        'another', () {
      final a = DecoyWallet.forOwner(addr(1), now: 1000000);
      final b = DecoyWallet.forOwner(addr(1), now: 1000000);
      expect(a.owner, b.owner);
      expect(a.walletLamports, b.walletLamports);
      expect(
        [for (final v in a.plans) v.address],
        [for (final v in b.plans) v.address],
      );
      expect(DecoyWallet.forOwner(addr(3), now: 1000000).owner, isNot(a.owner));
    });

    test('every owner action looks like it went through, and nothing is '
        'built, signed or sent', () async {
      final r = await _rig();
      final a = r.c.read(actionsProvider);
      final owner = r.c.read(sessionProvider).owner!;
      final decoy = r.c.read(decoyWalletProvider)!;
      final before = (await r.c.read(vaultsProvider.future)).length;
      final family = (await r.c.read(vaultsProvider.future)).first;

      expect(await a.connect(), owner);
      expect(
        await a.createVault(
          label: 'New',
          rules: [
            RuleSpec(
              beneficiary: addr(40),
              rail: Rail.solana,
              afterSecs: 7 * 86400,
              mode: AmountMode.percent,
              amount: 10000,
            ),
          ],
          lockSecs: 86400,
          skipGraceSecs: 86400,
          depositLamports: 100000000,
          tokenDeposits: {_usdc: 1000000},
        ),
        isEmpty,
      );
      final plans = await r.c.read(vaultsProvider.future);
      expect(plans, hasLength(before + 1));
      final created = plans.last;
      expect(created.label, 'New');
      expect(created.withdrawableLamports, 100000000);

      final wallet = decoy.walletLamports;
      await a.deposit(created.planId, 50000000);
      await a.withdraw(created.planId, 20000000);
      // Withdrawals are free: all of it comes back.
      expect(decoy.walletLamports, wallet - 30000000);
      await a.depositToken(created.planId, _usdc, 500000);
      await a.withdrawToken(created.planId, _usdc, 500000);
      await a.updatePolicy(
        planId: created.planId,
        label: 'Renamed',
        lockSecs: 86400,
        skipGraceSecs: 86400,
        rules: [
          RuleSpec(
            beneficiary: addr(41),
            rail: Rail.solana,
            afterSecs: 30 * 86400,
            mode: AmountMode.percent,
            amount: 10000,
          ),
        ],
      );
      expect(decoy.plan(created.planId).label, 'Renamed');

      final pulses = family.totalPulses;
      final cover = await a.pulse();
      expect(cover.guarded, isNotEmpty);
      expect(decoy.plan(family.planId).totalPulses, pulses + 1);
      await a.pulseByOwner([family.planId]);
      await a.pulseWithWallet();

      final report = await a.lockdown();
      expect(report.complete, isTrue);
      await a.lockdownByOwner([family.planId]);
      await a.lockdownWithWallet();
      // The real plans are what gets locked, silently.
      expect(r.lockdowns, everyElement(addr(1)));
      expect(r.lockdowns, isNotEmpty);

      await a.createVesting(
        label: 'Vest',
        startAt: nowSecs(),
        revocable: true,
        schedules: [
          VestingSpec(
            beneficiary: addr(42),
            rail: Rail.solana,
            mint: _usdc,
            total: 1000000,
            cliffSecs: 0,
            durationSecs: 365 * 86400,
          ),
        ],
        lockSecs: 86400,
      );
      final vest = (await r.c.read(vaultsProvider.future)).last;
      await a.revokeVesting(vest.planId);
      expect(decoy.plan(vest.planId).revokedAt, isNot(0));
      await a.closePlan(created.planId);
      expect(decoy.plans.any((v) => v.planId == created.planId), isFalse);

      final watched = (await r.c.read(watchedVaultsProvider.future)).single;
      expect(await a.claim(watched, 0), isNull);
      await a.recoverLegacyPlans(const [9]);

      final saved = await a.saveClaimProfile(Rail.cloak, addr(43));
      expect(saved.profile.destination, addr(43));
      expect(saved.unconfirmedPhrase, decoy.phrase);
      expect(await r.c.read(claimProfilesProvider.future), hasLength(1));
      expect(await a.revealRecoveryPhrase(), decoy.phrase);
      await a.confirmPhraseSaved();
      final restored = await a.restoreFromPhrase(bip39.generateMnemonic());
      expect(restored.restored, isEmpty);

      await expectLater(a.rotateGuard(), throwsA(isA<ActionError>()));
      await expectLater(
        a.quotePrivateRoute(Rail.cloak, null),
        throwsA(isA<ActionError>()),
      );
      await expectLater(
        a.withdrawShielded(const []),
        throwsA(isA<ActionError>()),
      );
      expect(await a.scanShieldedInbox(), isEmpty);

      // Nothing reached the chain, the wallet app or the secure store.
      expect(r.chain.calls, isEmpty);
      expect(r.wallet.calls, isEmpty);
      expect(r.store.calls, isEmpty);
    });

    test('Boney keeps the skin he wears', () async {
      final r = await _rig(saved: {boneySkinKey: 'crown'});
      final nfts = await r.c.read(walletNftsProvider.future);
      expect(ownedSkins(nfts), {BoneySkin.crown});
    });

    test('Forget this device deletes and reads nothing: the app lands on '
        'Welcome, still under duress', () async {
      final r = await _rig();
      await r.c.read(sessionProvider.notifier).reset(deleteReceivingKeys: true);
      final s = r.c.read(sessionProvider);
      expect(s.unlocked, isFalse);
      expect(s.duress, isTrue);
      expect(s.owner, isNull);
      expect(r.c.read(prefsProvider).getString('owner'), addr(1));
      expect(r.store.calls, isEmpty);
    });

    test('locking ends the act; the next normal unlock shows the real '
        'wallet', () async {
      final r = await _rig();
      r.c.read(sessionProvider.notifier).lock();
      r.c.read(sessionProvider.notifier).unlock(duress: false);
      expect(r.c.read(sessionProvider).owner, addr(1));
      expect(r.c.read(decoyWalletProvider), isNull);
      expect(r.c.read(viewApiProvider), same(r.chain));
    });
  });

  test('plan coverage of the decoy uses its own guard', () {
    final w = DecoyWallet.forOwner(addr(1), now: 2000000);
    final cover = PlanCoverage.of(w.plans, w.guard, 2000000);
    expect(cover.guarded, hasLength(w.plans.length));
  });
}
