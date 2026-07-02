import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:local_auth/local_auth.dart';

import '../rails/cloak_route.dart';
import '../rails/cloak_webview_runtime.dart';
import '../solana/deadman_api.dart';
import 'providers.dart';

class ActionError implements Exception {
  const ActionError(this.message);
  final String message;

  @override
  String toString() => message;
}

/// SOL left on a claim key after routing, to cover the routing tx fees.
const _routeFeeReserve = 1000000;

/// User intents. Owner actions go through the Seed Vault wallet; pulse and
/// panic use the on-device guard key behind a biometric check; private
/// routing uses the beneficiary's claim keys.
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

  Future<void> _signAndSend(List<Uint8List> txs) async {
    final signed = await ref.read(walletProvider).signTransactions(txs);
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
    required List<RuleSpec> rules,
    required int intervalSecs,
    required int lockSecs,
    required int depositLamports,
  }) async {
    final store = ref.read(secureStoreProvider);
    final guard = await store.loadGuard() ?? await store.createGuard();
    await _signAndSend([
      await _api.buildCreateVault(
        owner: _owner,
        guard: guard.address,
        intervalSecs: intervalSecs,
        lockSecs: lockSecs,
        rules: rules,
        depositLamports: depositLamports,
      ),
    ]);
  }

  Future<void> pulse() async {
    if (!await _biometric('Confirm you are alive')) {
      throw const ActionError('Biometric check failed');
    }
    final guard = await ref.read(secureStoreProvider).loadGuard();
    if (guard == null) {
      throw const ActionError('Guard key missing on this device');
    }
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

  Future<void> deposit(int lamports) => _decoy(
    () async => _signAndSend([
      await _api.buildDeposit(owner: _owner, lamports: lamports),
    ]),
  );

  Future<void> withdraw(int lamports) => _decoy(
    () async => _signAndSend([
      await _api.buildWithdrawSol(owner: _owner, lamports: lamports),
    ]),
  );

  Future<void> updatePolicy({
    required int intervalSecs,
    required int lockSecs,
    required List<RuleSpec> rules,
    String? guardian,
  }) => _decoy(
    () async => _signAndSend([
      await _api.buildUpdatePolicy(
        owner: _owner,
        intervalSecs: intervalSecs,
        lockSecs: lockSecs,
        rules: rules,
        guardian: guardian,
      ),
    ]),
  );

  /// Moves the guard to a fresh device key (e.g. after losing a phone).
  Future<void> rotateGuard() async {
    final fresh = await ref.read(secureStoreProvider).createGuard();
    await _signAndSend([
      await _api.buildSetGuard(owner: _owner, newGuard: fresh.address),
    ]);
  }

  /// Executes a due rule from the connected wallet. Anyone may execute;
  /// the payout destination is fixed on-chain.
  Future<void> executeRule(String vaultOwner, int index) async => _signAndSend([
    await _api.buildExecuteRule(
      executor: _owner,
      vaultOwner: vaultOwner,
      index: index,
    ),
  ]);

  /// Creates or updates this device's receiving profile for a private rail.
  Future<String> saveClaimProfile(Rail rail, String destination) async {
    final d = destination.trim();
    if (rail == Rail.zcash && !d.startsWith('u1')) {
      throw const ActionError(
        'Use a unified u1… Zcash address so the payout lands shielded',
      );
    }
    final p = await ref
        .read(secureStoreProvider)
        .saveClaim(rail, destination.trim());
    ref.invalidate(claimProfilesProvider);
    return p.claimCode;
  }

  /// Forwards SOL that landed on a claim key to its private destination.
  Future<String> routePrivately(Rail rail) async {
    final profile = await ref.read(secureStoreProvider).loadClaim(rail);
    if (profile == null) {
      throw const ActionError('No receiving profile for this rail');
    }
    final route = rail == Rail.cloak
        ? CloakRoute(runtime: await CloakWebViewRuntime.start())
        : ref.read(routesProvider)[rail]!;
    if (!route.available) {
      throw ActionError(
        '${rail.name} routing is only available on mainnet builds',
      );
    }
    final balance = await _api.balance(profile.key.address);
    final amount = balance - _routeFeeReserve;
    if (amount <= 0) throw const ActionError('Nothing to route yet');
    final quote = await route.quote(
      claimKey: profile.key.address,
      inputMint: null,
      amount: amount,
      destination: profile.destination,
    );
    final id = await route.execute(claimKey: profile.key, quote: quote);
    ref.invalidate(watchedVaultsProvider);
    return id;
  }

  /// Swaps idle SOL into the yield token, then deposits it into the vault.
  Future<void> earn(int lamports) => _decoy(() async {
    final earn = ref.read(earnProvider);
    if (!earn.available) {
      throw const ActionError('Earn is only available on mainnet builds');
    }
    await _signAndSend([
      await earn.buildStake(owner: _owner, lamports: lamports),
    ]);
    final lst = await _api.tokenBalance(_owner, earn.lstMint);
    if (lst > 0) {
      await _signAndSend([
        await _api.buildDepositToken(
          owner: _owner,
          mint: earn.lstMint,
          amount: lst,
        ),
      ]);
    }
  });

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
