
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:local_auth/local_auth.dart';

import '../solana/deadman_api.dart';
import 'providers.dart';

class ActionError implements Exception {
  const ActionError(this.message);
  final String message;

  @override
  String toString() => message;
}

/// User intents. Owner actions go through the Seed Vault wallet; pulse and
/// panic use the on-device guard key behind a biometric check.
class VaultActions {
  VaultActions(this.ref);

  final Ref ref;
  final _auth = LocalAuthentication();

  DeadmanApi get _api => ref.read(apiProvider);

  String get _owner {
    final owner = ref.read(sessionProvider).owner;
    if (owner == null) throw const ActionError('Connect your wallet first');
    return owner;
  }

  Future<String> connect() async {
    final session = await ref.read(walletProvider).authorize();
    await ref.read(sessionProvider.notifier).setOwner(session.publicKey);
    return session.publicKey;
  }

  Future<void> _signAndSend(Uint8List tx) async {
    final signed = await ref.read(walletProvider).signTransactions([tx]);
    await _api.sendSigned(signed);
    _refresh();
  }

  void _refresh() {
    ref.invalidate(vaultProvider);
    ref.invalidate(walletBalanceProvider);
    ref.invalidate(watchedVaultsProvider);
  }

  Future<bool> _biometric(String reason) async {
    try {
      if (!await _auth.isDeviceSupported()) return true;
      return await _auth.authenticate(localizedReason: reason);
    } on PlatformException {
      return false;
    }
  }

  Future<void> createVault({
    required List<Heir> heirs,
    required int intervalSecs,
    required int graceSecs,
    required int lockSecs,
    required int depositLamports,
  }) async {
    final store = ref.read(secureStoreProvider);
    final guard = await store.loadGuard() ?? await store.createGuard();
    final tx = await _api.buildCreateVault(
      owner: _owner,
      guard: guard.address,
      intervalSecs: intervalSecs,
      graceSecs: graceSecs,
      lockSecs: lockSecs,
      heirs: heirs,
      depositLamports: depositLamports,
    );
    await _signAndSend(tx);
  }

  Future<void> pulse() async {
    if (!await _biometric('Confirm you are alive')) {
      throw const ActionError('Biometric check failed');
    }
    final guard = await ref.read(secureStoreProvider).loadGuard();
    if (guard == null) throw const ActionError('Guard key missing on this device');
    await _api.pulseWithGuard(guard, vaultOwner: _owner);
    HapticFeedback.heavyImpact();
    _refresh();
  }

  /// Silent: no prompt, no haptics. Used by the duress PIN and Panic.
  Future<void> lockdown() async {
    final guard = await ref.read(secureStoreProvider).loadGuard();
    if (guard == null) return;
    await _api.lockdownWithGuard(guard, vaultOwner: _owner);
    _refresh();
  }

  Future<void> deposit(int lamports) =>
      _decoy(() async => _signAndSend(await _api.buildDeposit(owner: _owner, lamports: lamports)));

  Future<void> withdraw(int lamports) => _decoy(
        () async => _signAndSend(await _api.buildWithdrawSol(owner: _owner, lamports: lamports)),
      );

  Future<void> updatePolicy({
    required int intervalSecs,
    required int graceSecs,
    required int lockSecs,
    required List<Heir> heirs,
    String? guardian,
  }) =>
      _decoy(
        () async => _signAndSend(await _api.buildUpdatePolicy(
          owner: _owner,
          intervalSecs: intervalSecs,
          graceSecs: graceSecs,
          lockSecs: lockSecs,
          heirs: heirs,
          guardian: guardian,
        )),
      );

  Future<void> subscribe(int months) async =>
      _signAndSend(await _api.buildSubscribe(owner: _owner, months: months));

  /// Moves the guard to a fresh device key (e.g. after losing a phone).
  Future<void> rotateGuard() async {
    final store = ref.read(secureStoreProvider);
    final fresh = await store.createGuard();
    await _signAndSend(await _api.buildSetGuard(owner: _owner, newGuard: fresh.address));
  }

  Future<void> trigger(String vaultOwner) async =>
      _signAndSend(await _api.buildTrigger(caller: _owner, vaultOwner: vaultOwner));

  Future<void> claim(String vaultOwner) async =>
      _signAndSend(await _api.buildClaimSol(heir: _owner, vaultOwner: vaultOwner));

  /// Under duress, fund-moving actions look like a flaky wallet instead of
  /// revealing the on-chain lock to the person holding the phone.
  Future<void> _decoy(Future<void> Function() action) async {
    if (ref.read(sessionProvider).duress) {
      await Future<void>.delayed(const Duration(seconds: 4));
      throw const ActionError('Seed Vault timed out. Try again later.');
    }
    await action();
  }
}

final actionsProvider = Provider(VaultActions.new);
