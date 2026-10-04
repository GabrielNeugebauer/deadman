import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/config.dart';
import '../rails/cloak_route.dart';
import '../rails/earn_jupiter.dart';
import '../rails/rails.dart';
import '../rails/zcash_route.dart';
import '../solana/deadman_api.dart';
import '../solana/deadman_client.dart';
import '../wallet/mwa_wallet_bridge.dart';
import '../wallet/wallet_bridge.dart';
import 'fee_settings.dart';
import 'lockdown_retry.dart';
import 'plan_math.dart';
import 'reminders.dart';
import 'secure_store.dart';

final prefsProvider = Provider<SharedPreferences>(
  (ref) => throw UnimplementedError('overridden in main'),
);
final secureStoreProvider = Provider((ref) => SecureStore());
final walletProvider = Provider<WalletBridge>((ref) => MwaWalletBridge());
final apiProvider = Provider<DeadmanApi>((ref) => DeadmanClient());
final routesProvider = Provider<Map<Rail, PrivateRoute>>(
  (ref) => {Rail.zcash: ZcashRoute(), Rail.cloak: CloakRoute()},
);
final earnProvider = Provider<EarnService>((ref) => JupiterEarn());

int nowSecs() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

class Session {
  const Session({this.owner, this.unlocked = false, this.duress = false});

  /// Base58 wallet address of the connected owner.
  final String? owner;
  final bool unlocked;

  /// Opened with the duress PIN: the vault is already locked on-chain and
  /// the UI keeps up appearances.
  final bool duress;

  Session copyWith({String? owner, bool? unlocked, bool? duress}) => Session(
    owner: owner ?? this.owner,
    unlocked: unlocked ?? this.unlocked,
    duress: duress ?? this.duress,
  );
}

class SessionController extends Notifier<Session> {
  static const _ownerKey = 'owner';

  @override
  Session build() =>
      Session(owner: ref.read(prefsProvider).getString(_ownerKey));

  Future<void> setOwner(String owner) async {
    await ref.read(prefsProvider).setString(_ownerKey, owner);
    state = state.copyWith(owner: owner);
  }

  void unlock({required bool duress}) =>
      state = state.copyWith(unlocked: true, duress: duress);

  void lock() => state = Session(owner: state.owner);

  /// "Forget this device": PINs and the guard key go; receiving keys stay
  /// unless [deleteReceivingKeys] (funds sent to them are then lost unless
  /// the recovery phrase was saved).
  Future<void> reset({bool deleteReceivingKeys = false}) async {
    final store = ref.read(secureStoreProvider);
    await ref.read(prefsProvider).remove(_ownerKey);
    if (deleteReceivingKeys) {
      await store.wipeAll();
    } else {
      await store.wipeDevice();
    }
    ref.invalidate(guardAddressProvider);
    ref.invalidate(claimProfilesProvider);
    state = const Session();
  }
}

final sessionProvider = NotifierProvider<SessionController, Session>(
  SessionController.new,
);

/// Every release plan of the connected owner, sorted by plan id.
final vaultsProvider = FutureProvider<List<VaultState>>((ref) async {
  final owner = ref.watch(sessionProvider.select((s) => s.owner));
  if (owner == null) return const [];
  final vaults = await ref.watch(apiProvider).fetchVaults(owner);
  // Vesting plans need no check-ins, so they never drive reminders.
  final active = activeSwitchPlans(vaults);
  if (active.isNotEmpty) {
    // Remind on the most urgent plan.
    final pulseDue = active.map((v) => v.pulseDue).reduce(min);
    final deadline = active.map((v) => v.nextRuleDue!).reduce(min);
    await scheduleFrom(pulseDue: pulseDue, deadline: deadline);
  }
  return vaults;
});

/// This device's guard key address, or null when it has none.
final guardAddressProvider = FutureProvider<String?>(
  (ref) async => (await ref.watch(secureStoreProvider).loadGuard())?.address,
);

/// Duress lockdown with persisted retry; one per app.
final lockdownRetrierProvider = Provider(
  (ref) => LockdownRetrier(
    pending: PendingLockdown(ref.read(prefsProvider)),
    attempt: (owner) async {
      await lockGuardedPlans(
        ref.read(apiProvider),
        await ref.read(secureStoreProvider).loadGuard(),
        owner,
      );
      ref.invalidate(vaultsProvider);
    },
    onPending: scheduleLockdownRetry,
    onDone: cancelLockdownRetry,
  ),
);

final feesProvider = FutureProvider(
  (ref) => ref.watch(apiProvider).fetchFees(),
);

final claimProfilesProvider = FutureProvider(
  (ref) => ref.watch(secureStoreProvider).loadClaims(),
);

final walletBalanceProvider = FutureProvider<int>((ref) async {
  final owner = ref.watch(sessionProvider.select((s) => s.owner));
  if (owner == null) return 0;
  return ref.watch(apiProvider).balance(owner);
});

/// USDC (base units) in the connected wallet.
final walletUsdcProvider = FutureProvider<int>((ref) async {
  final owner = ref.watch(sessionProvider.select((s) => s.owner));
  if (owner == null) return 0;
  return ref.watch(apiProvider).tokenBalance(owner, AppConfig.usdcMint);
});

/// USDC (base units) held by the plan vault at [vaultAddress] (its ATA is
/// owned by the vault PDA).
final planUsdcProvider = FutureProvider.family<int, String>(
  (ref, vaultAddress) =>
      ref.watch(apiProvider).tokenBalance(vaultAddress, AppConfig.usdcMint),
);

/// A Kora paymaster is configured, so owners may pay fees in USDC.
final paymasterAvailableProvider = Provider(
  (ref) => AppConfig.koraPaymasterUrl.isNotEmpty,
);

/// Network-fee payment for wallet-signed owner transactions. Reading it
/// applies the persisted choice to the API (done at startup in main).
class FeeModeController extends Notifier<FeeMode> {
  FeeSettings get _settings => FeeSettings(
    ref.read(prefsProvider),
    paymasterAvailable: ref.read(paymasterAvailableProvider),
  );

  @override
  FeeMode build() {
    final mode = _settings.mode;
    _settings.apply(ref.read(apiProvider), mode);
    return mode;
  }

  Future<void> set(FeeMode mode) async {
    final settings = _settings;
    if (mode == FeeMode.usdc && !settings.paymasterAvailable) return;
    await settings.save(mode);
    settings.apply(ref.read(apiProvider), mode);
    state = mode;
  }
}

final feeModeProvider = NotifierProvider<FeeModeController, FeeMode>(
  FeeModeController.new,
);

/// Vaults naming this wallet, or one of this device's claim keys.
final watchedVaultsProvider = FutureProvider<List<VaultState>>((ref) async {
  final owner = ref.watch(sessionProvider.select((s) => s.owner));
  if (owner == null) return const [];
  final api = ref.watch(apiProvider);
  final claims = await ref.watch(claimProfilesProvider.future);
  final seen = <String, VaultState>{};
  for (final who in [owner, ...claims.map((c) => c.key.address)]) {
    for (final v in await api.fetchWatchedVaults(who)) {
      seen[v.address] = v;
    }
  }
  return seen.values.toList();
});

/// Addresses this device answers for as a beneficiary.
final myBeneficiaryKeysProvider = FutureProvider<Set<String>>((ref) async {
  final owner = ref.watch(sessionProvider.select((s) => s.owner));
  final claims = await ref.watch(claimProfilesProvider.future);
  return {?owner, ...claims.map((c) => c.key.address)};
});
