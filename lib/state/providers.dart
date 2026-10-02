import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

final sessionProvider =
    NotifierProvider<SessionController, Session>(SessionController.new);

final vaultProvider = FutureProvider<VaultState?>((ref) async {
  final owner = ref.watch(sessionProvider.select((s) => s.owner));
  if (owner == null) return null;
  final vault = await ref.watch(apiProvider).fetchVault(owner);
  if (vault != null) {
    await scheduleFrom(pulseDue: vault.pulseDue, deadline: vault.deadline);
  }
  return vault;
});

final walletBalanceProvider = FutureProvider<int>((ref) async {
  final owner = ref.watch(sessionProvider.select((s) => s.owner));
  if (owner == null) return 0;
  return ref.watch(apiProvider).balance(owner);
});

final watchedVaultsProvider = FutureProvider<List<VaultState>>((ref) async {
  final owner = ref.watch(sessionProvider.select((s) => s.owner));
  if (owner == null) return const [];
  return ref.watch(apiProvider).fetchWatchedVaults(owner);
});
