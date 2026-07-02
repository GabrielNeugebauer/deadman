import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../rails/cloak_route.dart';
import '../rails/earn_jupiter.dart';
import '../rails/rails.dart';
import '../rails/zcash_route.dart';
import '../solana/deadman_api.dart';
import '../solana/deadman_client.dart';
import '../wallet/mwa_wallet_bridge.dart';
import '../wallet/wallet_bridge.dart';
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

  Future<void> reset() async {
    await ref.read(prefsProvider).remove(_ownerKey);
    await ref.read(secureStoreProvider).wipe();
    state = const Session();
  }
}

final sessionProvider = NotifierProvider<SessionController, Session>(
  SessionController.new,
);

final vaultProvider = FutureProvider<VaultState?>((ref) async {
  final owner = ref.watch(sessionProvider.select((s) => s.owner));
  if (owner == null) return null;
  final vault = await ref.watch(apiProvider).fetchVault(owner);
  final next = vault?.nextRuleDue;
  if (vault != null && next != null) {
    await scheduleFrom(pulseDue: vault.pulseDue, deadline: next);
  }
  return vault;
});

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
