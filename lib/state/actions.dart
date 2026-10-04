import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:local_auth/local_auth.dart';
import 'package:solana/solana.dart';

import '../core/config.dart';
import '../rails/cloak_route.dart';
import '../rails/rails.dart';
import '../rails/zcash_route.dart';
import '../solana/deadman_api.dart';
import '../wallet/web_wallet_bridge.dart';
import 'assets.dart';
import 'lockdown_retry.dart';
import 'plan_math.dart';
import 'private_rails.dart';
import 'providers.dart';
import 'secure_store.dart';

class ActionError implements Exception {
  const ActionError(this.message);
  final String message;

  @override
  String toString() => message;
}

typedef BiometricCheck = Future<bool> Function(String reason);

final biometricProvider = Provider<BiometricCheck>((ref) {
  final auth = LocalAuthentication();
  final web = ref.watch(isWebProvider);
  return (reason) async {
    // No platform authenticator on the web; the app PIN still gates it.
    if (web) return true;
    try {
      if (!await auth.isDeviceSupported()) return true;
      return await auth.authenticate(localizedReason: reason);
    } on PlatformException {
      return false;
    }
  };
});

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

  /// Web: connects the browser wallet the user picked, which becomes the
  /// owner (and is remembered for the next visit).
  Future<String> connectWeb(WalletKind kind) async {
    final session = await ref.read(webWalletProvider).connect(kind);
    await ref.read(sessionProvider.notifier).setOwner(session.publicKey);
    _refresh();
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
    ref.invalidate(walletTokenProvider);
    ref.invalidate(planTokenBalancesProvider);
    ref.invalidate(watchedTokenBalancesProvider);
  }

  Future<bool> _biometric(String reason) => ref.read(biometricProvider)(reason);

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
    Map<String, int> tokenDeposits = const {},
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
        tokenDeposits: tokenDeposits,
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

  /// Web "I'm alive": the browser holds no background guard, so the owner's
  /// wallet checks in on every active inheritance plan in one approval.
  /// Returns the plans checked in.
  Future<List<VaultState>> pulseWithWallet() async {
    final active = activeSwitchPlans(await _plans());
    if (active.isEmpty) {
      throw const ActionError(
        'Nothing to check in: no inheritance plan has a tier pending',
      );
    }
    await pulseByOwner([for (final v in active) v.planId]);
    _refresh();
    return active;
  }

  /// Web panic: locks every plan with the owner's wallet signature.
  Future<List<VaultState>> lockdownWithWallet() async {
    final plans = await _plans();
    if (plans.isEmpty) {
      throw const ActionError('Nothing was locked: you have no plans');
    }
    await lockdownByOwner([for (final v in plans) v.planId]);
    return plans;
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

  /// Closes plans left in an older layout and returns all their SOL.
  Future<void> recoverLegacyPlans(List<int> planIds) => _decoy(
    () async => _signAndSend([
      for (final id in planIds)
        await _api.buildRecoverLegacyVault(owner: _owner, planId: id),
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

  /// Creates or updates this device's receiving profile for a private rail.
  /// Behind the duress decoy and a biometric check, asked again (with its
  /// own reason) when an existing destination changes.
  Future<SavedClaim> saveClaimProfile(Rail rail, String destination) =>
      _decoy(() async {
        final t = destination.trim();
        final d = rail == Rail.zcash && t == t.toUpperCase()
            ? t.toLowerCase()
            : t;
        _checkDestination(rail, d);
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

  /// Points the Cloak profile at this phone's own shielded address, whose
  /// payouts the shielded inbox finds. Derived from the claim key, so the
  /// recovery phrase restores it.
  Future<SavedClaim> useOwnCloakAddress() => _decoy(() async {
    final route = await _cloakRuntime();
    final store = ref.read(secureStoreProvider);
    final key =
        (await store.loadClaim(Rail.cloak))?.key ??
        (await store.saveClaim(Rail.cloak, '')).key;
    final own = await route.receiveAddressFor(key);
    return saveClaimProfile(Rail.cloak, '$own');
  });

  static void _checkDestination(Rail rail, String d) {
    if (rail == Rail.zcash) {
      final r = ZcashRoute.decodeUnifiedAddress(d);
      if (r == null || !(r.orchard || r.sapling)) {
        throw const ActionError(
          'Use a unified u1… Zcash address so the payout lands shielded',
        );
      }
      if (r.transparent) {
        throw const ActionError(
          'That address also has a transparent receiver. Use a shielded-only '
          'u1… address.',
        );
      }
    }
    if (rail == Rail.cloak) {
      try {
        if (isCloakAddress(d)) {
          CloakAddress.parse(d);
        } else {
          Ed25519HDPublicKey.fromBase58(d);
        }
      } on Object {
        throw const ActionError(
          'Use a Solana address or a cloak:… shielded address',
        );
      }
    }
  }

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

  Future<PrivateRoute> _route(Rail rail) async {
    if (!ref.read(privateRailsLiveProvider)) {
      throw ActionError(
        ref.read(isWebProvider)
            ? '${rail.label} routing runs in the Deadman Android app'
            : '${rail.label} routing is only available on mainnet builds',
      );
    }
    if (rail == Rail.zcash) return ref.read(zcashRouteProvider);
    return _cloakRuntime();
  }

  Future<CloakRoute> _cloakRuntime() async {
    try {
      return await ref.read(cloakRouteProvider.future);
    } catch (e) {
      ref.invalidate(cloakRuntimeProvider);
      throw ActionError('Could not start Cloak: $e');
    }
  }

  /// Quotes moving all of [mint] (SOL or USDC) on [rail]'s claim key to its
  /// private destination, for the user to confirm. On Cloak, an interrupted
  /// route of [mint] is resumed with its original amount once its funds have
  /// left the claim key (the deposit landed; only the send is left).
  Future<RoutePlan> quotePrivateRoute(
    Rail rail,
    String? mint,
  ) => _decoy(() async {
    final profile = await ref.read(secureStoreProvider).loadClaim(rail);
    if (profile == null) {
      throw const ActionError('No receiving profile for this rail');
    }
    if (profile.destination.isEmpty) {
      throw ActionError(
        'Set your ${rail.label} destination first (Security → Receive privately)',
      );
    }
    final route = await _route(rail);
    if (!route.available) {
      throw ActionError(
        '${rail.label} routing is only available on mainnet builds',
      );
    }
    final key = profile.key;
    final (lamports, usdc) = await (
      _api.balance(key.address),
      _api.tokenBalance(key.address, AppConfig.usdcMint),
    ).wait;
    final gas = mint == null && usdc > 0 ? gasKeptForTokens(rail) : 0;
    var amount = route is ZcashRoute
        ? await route.spendable(claimKey: key.address, inputMint: mint) - gas
        : mint == null
        ? lamports - gas
        : usdc;
    PrivateTransfer? resume;
    if (route is CloakRoute) {
      resume = ref
          .read(transferHistoryProvider)
          .where((t) => resumableCloak(t) && t.mint == mint)
          .firstOrNull;
      final resumeAmount = resume == null
          ? 0
          : mint == null
          ? resume.amount + route.solFeeReserveLamports
          : resume.amount;
      if (resume != null && amount < resumeAmount) {
        amount = resumeAmount;
      } else if (mint != null && lamports < route.splFeeReserveLamports) {
        throw ActionError(
          'Cloak needs ${amountText(route.splFeeReserveLamports, null)} on '
          'the claim key to shield USDC; it holds ${amountText(lamports, null)}. '
          'Send the difference to ${key.address}, then route again.',
        );
      }
    }
    if (amount <= 0) throw const ActionError('Nothing to route yet');
    final quote = await route.quote(
      claimKey: key.address,
      inputMint: mint,
      amount: amount,
      destination: profile.destination,
    );
    return RoutePlan(
      profile: profile,
      route: route,
      quote: quote,
      resumes: resume?.id,
    );
  });

  /// Sends a confirmed [plan] and records it under Private transfers.
  Future<PrivateTransfer> executePrivateRoute(
    RoutePlan plan,
  ) => _decoy(() async {
    if (!DateTime.now().isBefore(plan.quote.expiresAt)) {
      throw const ActionError('The quote expired. Route again for a new one.');
    }
    if (!await _biometric('Confirm routing your inheritance')) {
      throw const ActionError('Biometric check failed');
    }
    if (ref
        .read(transferHistoryProvider)
        .any((t) => t.status == sendingStatus)) {
      throw const ActionError('Another private transfer is still sending');
    }
    final q = plan.quote;
    final rail = plan.profile.rail;
    final history = ref.read(transferHistoryProvider.notifier);
    final sending = PrivateTransfer(
      id: plan.resumes ?? '${nowSecs()}-${rail.name}-${q.inputMint ?? 'SOL'}',
      rail: rail,
      mint: q.inputMint,
      amount: q.amountIn,
      trackingId: q.depositAddress ?? '',
      status: sendingStatus,
      createdAt: nowSecs(),
      estimatedOut: q.estimatedOut,
    );
    await history.put(sending);
    final String id;
    try {
      id = await plan.route.execute(claimKey: plan.profile.key, quote: q);
    } catch (e) {
      if (rail == Rail.cloak) {
        await history.put(sending.withStatus(interruptedStatus));
      } else if (e is ZcashRouteException) {
        await history.remove(sending.id);
      } else {
        // Unknown whether the deposit landed: let 1Click's status tell.
        await history.put(sending.withStatus('PENDING_DEPOSIT'));
      }
      rethrow;
    } finally {
      ref.invalidate(claimFundsProvider(plan.profile.key.address));
    }
    final t = sending.withStatus(
      rail == Rail.zcash
          ? 'PENDING_DEPOSIT'
          : id == CloakRoute.alreadySent
          ? 'SUCCESS'
          : 'PENDING',
      trackingId: id,
    );
    await history.put(t);
    ref.invalidate(watchedVaultsProvider);
    return t;
  });

  /// The Cloak profile and route, when its destination is this phone's own
  /// shielded address: notes sent to any other address can't be found here.
  Future<(ClaimProfile, CloakRoute)> _cloakInbox() async {
    final p = await ref.read(secureStoreProvider).loadClaim(Rail.cloak);
    if (p == null || !isCloakAddress(p.destination)) {
      throw const ActionError('No Cloak shielded address on this phone');
    }
    final route = await _route(Rail.cloak) as CloakRoute;
    final own = await route.receiveAddressFor(p.key);
    if (p.destination != '$own') {
      throw const ActionError(
        'Your Cloak destination is another wallet\'s shielded address. Its '
        'payouts show up in that wallet, not here.',
      );
    }
    return (p, route);
  }

  /// Shielded notes paid to this device's Cloak address, spent ones
  /// included. Under duress the inbox looks empty.
  Future<List<CloakNote>> scanShieldedInbox() async {
    if (ref.read(sessionProvider).duress) return const [];
    final (profile, route) = await _cloakInbox();
    return route.scanReceived(claimKey: profile.key);
  }

  /// Unshields [notes] to the connected wallet.
  Future<PrivateTransfer> withdrawShielded(List<CloakNote> notes) =>
      _decoy(() async {
        if (notes.isEmpty) throw const ActionError('Nothing to withdraw');
        final (profile, route) = await _cloakInbox();
        if (!await _biometric('Confirm withdrawing to your wallet')) {
          throw const ActionError('Biometric check failed');
        }
        final sig = await route.withdrawReceived(
          claimKey: profile.key,
          notes: notes,
          destination: _owner,
        );
        final t = PrivateTransfer(
          id: '${nowSecs()}-$sig',
          rail: Rail.cloak,
          mint: notes.first.mint,
          amount: notes.fold(0, (sum, n) => sum + n.amount),
          trackingId: sig,
          status: 'PENDING',
          createdAt: nowSecs(),
          kind: TransferKind.withdraw,
        );
        await ref.read(transferHistoryProvider.notifier).add(t);
        ref.invalidate(walletBalanceProvider);
        ref.invalidate(walletUsdcProvider);
        return t;
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
      throw ActionError(
        '${ref.read(isWebProvider) ? 'Your wallet' : 'Seed Vault'} timed out. '
        'Try again later.',
      );
    }
    return action();
  }
}

final actionsProvider = Provider(VaultActions.new);

/// A quoted private route waiting for the user's confirmation.
class RoutePlan {
  const RoutePlan({
    required this.profile,
    required this.route,
    required this.quote,
    this.resumes,
  });

  final ClaimProfile profile;
  final PrivateRoute route;
  final RouteQuote quote;

  /// Id of the interrupted Cloak transfer this plan finishes.
  final String? resumes;
}

extension on Rail {
  String get label => switch (this) {
    Rail.solana => 'Solana',
    Rail.cloak => 'Cloak',
    Rail.zcash => 'Zcash',
  };
}
