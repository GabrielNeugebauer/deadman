import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:local_auth/local_auth.dart';

import '../rails/cloak_route.dart';
import '../rails/cloak_webview_runtime.dart';
import '../solana/deadman_api.dart';
import 'lockdown_retry.dart';
import 'plan_math.dart';
import 'providers.dart';
import 'secure_store.dart';

class ActionError implements Exception {
  const ActionError(this.message);
  final String message;

  @override
  String toString() => message;
}

/// SOL left on a claim key after routing, to cover the routing tx fees.
const _routeFeeReserve = 1000000;

class SavedClaim {
  const SavedClaim(this.profile, this.unconfirmedPhrase);

  final ClaimProfile profile;

  /// The recovery phrase, when the user has not yet confirmed writing it
  /// down (show it now).
  final String? unconfirmedPhrase;
}

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
    ref.invalidate(vaultsProvider);
    ref.invalidate(walletBalanceProvider);
    ref.invalidate(watchedVaultsProvider);
    ref.invalidate(walletUsdcProvider);
    ref.invalidate(planUsdcProvider);
  }

  Future<bool> _biometric(String reason) async {
    try {
      if (!await _auth.isDeviceSupported()) return true;
      return await _auth.authenticate(localizedReason: reason);
    } on PlatformException {
      return false;
    }
  }

  Future<List<VaultState>> _plans() => _api.fetchVaults(_owner);

  /// Creates a new plan with the next free id. Every plan uses this
  /// device's guard key so one check-in covers all of them. Returns the
  /// active plans still guarded by another device (e.g. after "Forget this
  /// device"): they need "Move guard to this phone".
  Future<List<VaultState>> createVault({
    required String label,
    required List<RuleSpec> rules,
    required int intervalSecs,
    required int lockSecs,
    required int skipGraceSecs,
    required int depositLamports,
  }) async {
    final store = ref.read(secureStoreProvider);
    final guard = await store.loadGuard() ?? await store.createGuard();
    final plans = await _plans();
    final planId = await _api.nextFreePlanId(_owner);
    await _signAndSend([
      await _api.buildCreateVault(
        owner: _owner,
        planId: planId,
        label: label,
        guard: guard.address,
        intervalSecs: intervalSecs,
        lockSecs: lockSecs,
        skipGraceSecs: clampGrace(skipGraceSecs),
        rules: rules,
        depositLamports: depositLamports,
      ),
    ]);
    ref.invalidate(guardAddressProvider);
    return PlanCoverage.of(plans, guard.address, nowSecs()).otherGuard;
  }

  /// Creates a vesting plan with the next free id, funded in the same
  /// transaction. Uses this device's guard key so panic lockdown covers it.
  /// Returns the active inheritance plans guarded by another device.
  Future<List<VaultState>> createVesting({
    required String label,
    required int startAt,
    required bool revocable,
    required List<VestingSpec> schedules,
    required int lockSecs,
    int depositLamports = 0,
    Map<String, int> tokenDeposits = const {},
  }) => _decoy(() async {
    final store = ref.read(secureStoreProvider);
    final guard = await store.loadGuard() ?? await store.createGuard();
    final plans = await _plans();
    final planId = await _api.nextFreePlanId(_owner);
    await _signAndSend([
      await _api.buildCreateVesting(
        owner: _owner,
        planId: planId,
        label: label,
        guard: guard.address,
        lockSecs: lockSecs,
        startAt: startAt,
        revocable: revocable,
        schedules: schedules,
        depositLamports: depositLamports,
        tokenDeposits: tokenDeposits,
      ),
    ]);
    ref.invalidate(guardAddressProvider);
    return PlanCoverage.of(plans, guard.address, nowSecs()).otherGuard;
  });

  /// Stops future vesting; what already vested stays the beneficiaries'.
  Future<void> revokeVesting(int planId) => _decoy(
    () async => _signAndSend([
      await _api.buildRevokeVesting(owner: _owner, planId: planId),
    ]),
  );

  /// Releases what has vested on schedule [index], signed by the connected
  /// wallet (anyone may; the destination is fixed on-chain).
  Future<void> releaseVested(VaultState vault, int index) async =>
      _signAndSend([
        await _api.buildReleaseVested(
          executor: _owner,
          vaultOwner: vault.owner,
          planId: vault.planId,
          index: index,
        ),
      ]);

  /// Checks in, with the guard key, on exactly the active plans it can
  /// pulse. The report names plans that need a wallet check-in or are
  /// guarded by another device; throws when nothing could be pulsed.
  Future<PlanCoverage> pulse() async {
    final guard = await ref.read(secureStoreProvider).loadGuard();
    final cover = PlanCoverage.of(await _plans(), guard?.address, nowSecs());
    if (cover.isEmpty) {
      throw const ActionError(
        'Nothing to check in: no inheritance plan has a tier pending',
      );
    }
    if (cover.guarded.isEmpty) {
      throw ActionError(cover.reportText(pulsed: false));
    }
    if (!await _biometric('Confirm you are alive')) {
      throw const ActionError('Biometric check failed');
    }
    await _api.pulseWithGuard(
      guard!,
      vaultOwner: _owner,
      planIds: [for (final v in cover.guarded) v.planId],
    );
    HapticFeedback.heavyImpact();
    _refresh();
    return cover;
  }

  /// Wallet-signed check-in, for plans the guard key can no longer pulse.
  Future<void> pulseByOwner(List<int> planIds) async {
    if (!await _biometric('Confirm you are alive')) {
      throw const ActionError('Biometric check failed');
    }
    await _signAndSend([
      await _api.buildPulseByOwner(owner: _owner, planIds: planIds),
    ]);
    HapticFeedback.heavyImpact();
  }

  /// Panic: locks every plan this device guards. Throws when nothing was
  /// locked; the report names plans left unlocked.
  Future<LockReport> lockdown() async {
    try {
      final report = await lockGuardedPlans(
        _api,
        await ref.read(secureStoreProvider).loadGuard(),
        _owner,
      );
      _refresh();
      return report;
    } on LockdownUnavailable catch (e) {
      throw ActionError(e.message);
    }
  }

  /// Panic fallback: locks [planIds] with the owner's wallet signature.
  Future<void> lockdownByOwner(List<int> planIds) async => _signAndSend([
    await _api.buildLockdownByOwner(owner: _owner, planIds: planIds),
  ]);

  /// Duress PIN: silent, retried with backoff until it goes through.
  Future<void> duressLockdown() async {
    final owner = ref.read(sessionProvider).owner;
    if (owner == null) return;
    await ref.read(lockdownRetrierProvider).start(owner);
  }

  Future<void> deposit(int planId, int lamports) => _decoy(
    () async => _signAndSend([
      await _api.buildDeposit(
        owner: _owner,
        planId: planId,
        lamports: lamports,
      ),
    ]),
  );

  Future<void> withdraw(int planId, int lamports) => _decoy(
    () async => _signAndSend([
      await _api.buildWithdrawSol(
        owner: _owner,
        planId: planId,
        lamports: lamports,
      ),
    ]),
  );

  /// Moves [amount] base units of [mint] from the wallet into a plan.
  Future<void> depositToken(int planId, String mint, int amount) => _decoy(
    () async => _signAndSend([
      await _api.buildDepositToken(
        owner: _owner,
        planId: planId,
        mint: mint,
        amount: amount,
      ),
    ]),
  );

  Future<void> withdrawToken(int planId, String mint, int amount) => _decoy(
    () async => _signAndSend([
      await _api.buildWithdrawToken(
        owner: _owner,
        planId: planId,
        mint: mint,
        amount: amount,
      ),
    ]),
  );

  /// [rules] are the new pending tiers only (see
  /// [DeadmanApi.buildUpdatePolicy]).
  Future<void> updatePolicy({
    required int planId,
    required String label,
    required int intervalSecs,
    required int lockSecs,
    required int skipGraceSecs,
    required List<RuleSpec> rules,
    String? guardian,
  }) => _decoy(
    () async => _signAndSend([
      await _api.buildUpdatePolicy(
        owner: _owner,
        planId: planId,
        label: label,
        intervalSecs: intervalSecs,
        lockSecs: lockSecs,
        skipGraceSecs: clampGrace(skipGraceSecs),
        rules: rules,
        guardian: guardian,
      ),
    ]),
  );

  /// Moves every plan guarded by another key (a lost phone, or before
  /// "Forget this device") to this device's guard key, in one wallet
  /// approval. The old key stops working.
  Future<void> rotateGuard() async {
    final plans = await _plans();
    if (plans.isEmpty) throw const ActionError('You have no plans yet');
    final store = ref.read(secureStoreProvider);
    final guard = await store.loadGuard() ?? await store.createGuard();
    final ids = [
      for (final v in plans)
        if (v.guard != guard.address) v.planId,
    ];
    if (ids.isEmpty) {
      throw const ActionError('Every plan is already guarded by this phone');
    }
    await _signAndSend([
      await _api.buildSetGuard(
        owner: _owner,
        planIds: ids,
        newGuard: guard.address,
      ),
    ]);
    ref.invalidate(guardAddressProvider);
  }

  /// Executes a due rule from the connected wallet. Anyone may execute;
  /// the payout destination is fixed on-chain.
  Future<void> executeRule(VaultState vault, int index) async => _signAndSend([
    await _api.buildExecuteRule(
      executor: _owner,
      vaultOwner: vault.owner,
      planId: vault.planId,
      index: index,
    ),
  ]);

  /// Skips a due tier that could not pay within the plan's grace period,
  /// so later tiers for that asset can run. Anyone may skip; the tier's
  /// share stays reserved and its beneficiary can still claim it.
  Future<void> skipRule(VaultState vault, int index) async => _signAndSend([
    await _api.buildSkipRule(
      caller: _owner,
      vaultOwner: vault.owner,
      planId: vault.planId,
      index: index,
    ),
  ]);

  /// Creates or updates this device's receiving profile for a private rail.
  /// Behind the duress decoy and a biometric check, asked again (with its
  /// own reason) when an existing destination changes.
  Future<SavedClaim> saveClaimProfile(Rail rail, String destination) =>
      _decoy(() async {
        final d = destination.trim();
        if (rail == Rail.zcash && !d.startsWith('u1')) {
          throw const ActionError(
            'Use a unified u1… Zcash address so the payout lands shielded',
          );
        }
        final store = ref.read(secureStoreProvider);
        final existing = await store.loadClaim(rail);
        final changing =
            existing != null &&
            existing.destination.isNotEmpty &&
            existing.destination != d;
        if (!await _biometric(
          changing
              ? 'Confirm changing where your ${rail.name} inheritance goes'
              : 'Confirm your ${rail.name} receiving profile',
        )) {
          throw const ActionError('Biometric check failed');
        }
        final p = await store.saveClaim(rail, d);
        ref.invalidate(claimProfilesProvider);
        final unconfirmed = p.recoverable && !await store.phraseConfirmed()
            ? await store.loadPhrase()
            : null;
        return SavedClaim(p, unconfirmed);
      });

  /// The recovery phrase for this device's receiving profiles.
  Future<String> revealRecoveryPhrase() => _decoy(() async {
    final store = ref.read(secureStoreProvider);
    final phrase = await store.loadPhrase();
    if (phrase == null) {
      throw const ActionError(
        'No recovery phrase yet. It is created with your first receiving profile.',
      );
    }
    if (!await _biometric('Show your recovery phrase')) {
      throw const ActionError('Biometric check failed');
    }
    return phrase;
  });

  Future<void> confirmPhraseSaved() =>
      ref.read(secureStoreProvider).markPhraseConfirmed();

  Future<RestoreResult> restoreFromPhrase(String phrase) => _decoy(() async {
    if (!SecureStore.isValidPhrase(phrase)) {
      throw const ActionError('That is not a valid 12-word recovery phrase');
    }
    if (!await _biometric('Restore your receiving profiles')) {
      throw const ActionError('Biometric check failed');
    }
    try {
      final r = await ref.read(secureStoreProvider).restoreFromPhrase(phrase);
      ref.invalidate(claimProfilesProvider);
      return r;
    } on StateError catch (e) {
      throw ActionError(e.message);
    }
  });

  /// Forwards SOL that landed on a claim key to its private destination.
  Future<String> routePrivately(Rail rail) => _decoy(() async {
    final profile = await ref.read(secureStoreProvider).loadClaim(rail);
    if (profile == null) {
      throw const ActionError('No receiving profile for this rail');
    }
    if (profile.destination.isEmpty) {
      throw ActionError(
        'Set your ${rail.name} destination first (Security → Receive privately)',
      );
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
    if (!await _biometric('Confirm routing your inheritance')) {
      throw const ActionError('Biometric check failed');
    }
    final quote = await route.quote(
      claimKey: profile.key.address,
      inputMint: null,
      amount: amount,
      destination: profile.destination,
    );
    final id = await route.execute(claimKey: profile.key, quote: quote);
    ref.invalidate(watchedVaultsProvider);
    return id;
  });

  /// Swaps wallet SOL into the yield token, then deposits it into a plan.
  /// The swap goes through Jupiter's /execute: some routes need Jupiter's
  /// co-signature, so it can't be sent through our own RPC.
  Future<void> earn(int planId, int lamports) => _decoy(() async {
    final earn = ref.read(earnProvider);
    if (!earn.available) {
      throw const ActionError('Earn is only available on mainnet builds');
    }
    final unsigned = await earn.buildStake(owner: _owner, lamports: lamports);
    final signed = await ref.read(walletProvider).signTransactions([unsigned]);
    await earn.execute(signed.single);
    final lst = await _api.tokenBalance(_owner, earn.lstMint);
    if (lst > 0) {
      await _signAndSend([
        await _api.buildDepositToken(
          owner: _owner,
          planId: planId,
          mint: earn.lstMint,
          amount: lst,
        ),
      ]);
    }
    _refresh();
  });

  /// Under duress, fund-moving actions look like a flaky wallet instead of
  /// revealing the on-chain lock to the person holding the phone.
  Future<T> _decoy<T>(Future<T> Function() action) async {
    if (ref.read(sessionProvider).duress) {
      await Future<void>.delayed(const Duration(seconds: 4));
      throw const ActionError('Seed Vault timed out. Try again later.');
    }
    return action();
  }
}

final actionsProvider = Provider(VaultActions.new);
