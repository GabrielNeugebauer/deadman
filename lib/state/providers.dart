import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/config.dart';
import '../rails/cloak_route.dart';
import '../rails/cloak_webview_runtime_stub.dart'
    if (dart.library.io) '../rails/cloak_webview_runtime.dart';
import '../rails/earn_jupiter.dart';
import '../rails/rails.dart';
import '../rails/zcash_route.dart';
import '../solana/deadman_api.dart';
import '../solana/deadman_client.dart';
import '../wallet/mwa_wallet_bridge.dart';
import '../wallet/wallet_bridge.dart';
import '../wallet/web_wallet_bridge.dart';
import 'boney_widget_host_stub.dart'
    if (dart.library.io) 'boney_widget_host.dart';
import 'boney_skin.dart';
import 'boney_widget_sync.dart';
import 'decoy_wallet.dart';
import 'fee_settings.dart';
import 'lockdown_retry.dart';
import 'plan_math.dart';
import 'reminders_stub.dart' if (dart.library.io) 'reminders.dart';
import 'secure_store.dart';

final prefsProvider = Provider<SharedPreferences>(
  (ref) => throw UnimplementedError('overridden in main'),
);
final secureStoreProvider = Provider((ref) => SecureStore());

/// Running in a browser. A provider so widget tests can render the web UI.
final isWebProvider = Provider((ref) => kIsWeb);

/// Phantom/Solflare browser extensions (web only).
final webWalletProvider = Provider(
  (ref) => WebWalletBridge(prefs: ref.read(prefsProvider)),
);

/// Mobile Wallet Adapter on Android; Phantom/Solflare extensions on the web.
final walletProvider = Provider<WalletBridge>(
  (ref) => ref.watch(isWebProvider)
      ? ref.watch(webWalletProvider)
      : MwaWalletBridge(),
);

/// The chain. Owner actions and the duress lockdown use it; screens read
/// through [viewApiProvider].
final apiProvider = Provider<DeadmanApi>((ref) => DeadmanClient());
final zcashRouteProvider = Provider((ref) => ZcashRoute());

/// Headless WebView running the Cloak SDK. It needs the UI isolate, so it
/// starts on first use from a screen, never from background work.
final cloakRuntimeProvider = FutureProvider<CloakJsRuntime>((ref) async {
  final runtime = await CloakWebViewRuntime.start();
  ref.onDispose(runtime.dispose);
  return runtime;
});

final cloakRouteProvider = FutureProvider<CloakRoute>(
  (ref) async =>
      CloakRoute(runtime: await ref.watch(cloakRuntimeProvider.future)),
);

/// Signature status only; needs no WebView.
final cloakStatusRouteProvider = Provider<PrivateRoute>((ref) => CloakRoute());

/// Cloak and 1Click run on mainnet only, and in the Android app only: the
/// Cloak prover needs its WebView.
final privateRailsLiveProvider = Provider(
  (ref) => AppConfig.isMainnet && !ref.watch(isWebProvider),
);

/// For the "Private rails check": a mainnet-configured 1Click client that
/// only asks for dry quotes, so it runs on devnet builds too.
final railsCheckZcashProvider = Provider(
  (ref) => ZcashRoute(cluster: 'mainnet-beta'),
);
final earnProvider = Provider<EarnService>((ref) => JupiterEarn());

int nowSecs() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

class Session {
  const Session({String? owner, this.unlocked = false, this.duress = false})
    : realOwner = owner;

  /// Base58 wallet address of the connected owner, even under duress. Only
  /// the silent duress lockdown may use it then.
  final String? realOwner;
  final bool unlocked;

  /// Opened with the duress PIN: the vault is already locked on-chain and
  /// the app shows a decoy wallet ([decoyWalletProvider]) instead.
  final bool duress;

  /// The owner the app shows and reads: the connected wallet, or under
  /// duress the decoy wallet's address.
  String? get owner {
    final real = realOwner;
    return duress && real != null ? decoyOwnerOf(real) : real;
  }

  Session copyWith({String? owner, bool? unlocked, bool? duress}) => Session(
    owner: owner ?? realOwner,
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

  void lock() => state = Session(owner: state.realOwner);

  /// "Forget this device": PINs and the guard key go; receiving keys stay
  /// unless [deleteReceivingKeys] (funds sent to them are then lost unless
  /// the recovery phrase was saved). Under duress nothing is deleted (the
  /// pending lockdown needs the guard key) and nothing is read: the app
  /// forgets the owner for this session only, so it lands on Welcome as a
  /// real reset does, and stays a duress session until a PIN is entered.
  Future<void> reset({bool deleteReceivingKeys = false}) async {
    if (state.duress) {
      state = const Session(duress: true);
      return;
    }
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

/// The decoy wallet a duress session shows, made once per session from the
/// real owner; null outside duress (or with no wallet connected).
final decoyWalletProvider = Provider<DecoyWallet?>((ref) {
  final real = ref.watch(
    sessionProvider.select((s) => s.duress ? s.realOwner : null),
  );
  if (real == null) return null;
  // It holds the skin Boney wears, so he looks the same under duress.
  final skin = BoneySkin.byId(ref.read(prefsProvider).getString(boneySkinKey));
  return DecoyWallet.forOwner(real, now: nowSecs())..ownSkins([?skin]);
});

/// What screens read: the chain, or under duress the decoy wallet (whose
/// public, owner-independent reads still come from the chain).
final viewApiProvider = Provider<DeadmanApi>((ref) {
  final chain = ref.watch(apiProvider);
  final decoy = ref.watch(decoyWalletProvider);
  return decoy == null ? chain : DecoyApi(decoy, chain, clock: nowSecs);
});

/// Every release plan of the connected owner, sorted by plan id.
final vaultsProvider = FutureProvider<List<VaultState>>((ref) async {
  final owner = ref.watch(sessionProvider.select((s) => s.owner));
  final duress = ref.watch(sessionProvider.select((s) => s.duress));
  if (owner == null) {
    if (!duress) _syncBoney(ref, const []);
    return const [];
  }
  final vaults = await ref.watch(viewApiProvider).fetchVaults(owner);
  // The decoy's plans never reach the home screen or the reminders.
  if (duress) return vaults;
  _syncBoney(ref, vaults);
  // Vesting plans need no check-ins, so they never drive reminders.
  final active = activeSwitchPlans(vaults);
  if (active.isNotEmpty) {
    // Remind ahead of the next release across every plan.
    final urgent = active.reduce(
      (a, b) => a.nextReleaseAt! <= b.nextReleaseAt! ? a : b,
    );
    final releaseAt = urgent.nextReleaseAt!;
    await scheduleFrom(
      releaseAt: releaseAt,
      delaySecs: releaseAt - urgent.lastPulse,
    );
  }
  return vaults;
});

/// The Boney home-screen widget; null where there is none (web).
final boneyHostProvider = Provider<BoneyWidgetHost?>(
  (ref) => ref.watch(isWebProvider) ? null : platformBoneyHost(),
);

/// Pushes Boney for [plans] to the home-screen widget, in the background.
void _syncBoney(Ref ref, List<VaultState> plans) {
  final host = ref.read(boneyHostProvider);
  if (host == null) return;
  final prefs = ref.read(prefsProvider);
  final guard = ref.read(guardAddressProvider.future);
  unawaited(
    () async {
      await BoneyWidgetSync(host)
          .syncPlans(plans, prefs: prefs, guard: await guard);
    }().catchError((Object _) {}),
  );
}

/// Plans of the connected owner left in an older account layout by a
/// program upgrade: unreadable as plans, but their SOL can be recovered.
final legacyPlansProvider = FutureProvider<List<int>>((ref) async {
  final owner = ref.watch(sessionProvider.select((s) => s.owner));
  if (owner == null) return const [];
  return ref.watch(viewApiProvider).fetchLegacyPlanIds(owner);
});

/// This device's guard key address, or null when it has none (the decoy's
/// under duress).
final guardAddressProvider = FutureProvider<String?>((ref) async {
  final decoy = ref.watch(decoyWalletProvider);
  if (decoy != null) return decoy.guard;
  return (await ref.watch(secureStoreProvider).loadGuard())?.address;
});

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
  (ref) => ref.watch(viewApiProvider).fetchFees(),
);

/// This device's receiving profiles (the decoy's under duress).
final claimProfilesProvider = FutureProvider<List<ClaimProfile>>((ref) async {
  final decoy = ref.watch(decoyWalletProvider);
  if (decoy != null) return decoy.claims.values.toList();
  return ref.watch(secureStoreProvider).loadClaims();
});

final walletBalanceProvider = FutureProvider<int>((ref) async {
  final owner = ref.watch(sessionProvider.select((s) => s.owner));
  if (owner == null) return 0;
  return ref.watch(viewApiProvider).balance(owner);
});

/// USDC (base units) in the connected wallet.
final walletUsdcProvider = FutureProvider<int>((ref) async {
  final owner = ref.watch(sessionProvider.select((s) => s.owner));
  if (owner == null) return 0;
  return ref.watch(viewApiProvider).tokenBalance(owner, AppConfig.usdcMint);
});

/// [mint] (base units) in the connected wallet.
final walletTokenProvider = FutureProvider.family<int, String>((
  ref,
  mint,
) async {
  final owner = ref.watch(sessionProvider.select((s) => s.owner));
  if (owner == null) return 0;
  return ref.watch(viewApiProvider).tokenBalance(owner, mint);
});

/// Token balances of [plans]' vaults for every token an unpaid tier uses
/// (SOL is each plan's [VaultState.withdrawableLamports]): vault address
/// -> mint -> base units, in one batched lookup.
Future<Map<String, Map<String, int>>> planTokenBalances(
  DeadmanApi api,
  Iterable<VaultState> plans,
) async {
  final pairs = [
    for (final v in plans)
      for (final mint in {
        for (final r in v.rules)
          if (!r.executed) ?r.mint,
      })
        (v.address, mint),
  ];
  if (pairs.isEmpty) return const {};
  final got = await api.tokenBalances(pairs);
  final out = <String, Map<String, int>>{};
  for (final (i, (address, mint)) in pairs.indexed) {
    (out[address] ??= {})[mint] = got[i];
  }
  return out;
}

/// [planTokenBalances] of the connected owner's inheritance plans.
final planTokenBalancesProvider = FutureProvider<Map<String, Map<String, int>>>(
  (ref) async => planTokenBalances(
    ref.watch(viewApiProvider),
    switchPlans(await ref.watch(vaultsProvider.future)),
  ),
);

/// [planTokenBalances] of the plans naming this wallet or its claim keys.
final watchedTokenBalancesProvider =
    FutureProvider<Map<String, Map<String, int>>>(
      (ref) async => planTokenBalances(
        ref.watch(viewApiProvider),
        await ref.watch(watchedVaultsProvider.future),
      ),
    );

/// USDC (base units) held by the plan vault at [vaultAddress] (its ATA is
/// owned by the vault PDA).
final planUsdcProvider = FutureProvider.family<int, String>(
  (ref, vaultAddress) =>
      ref.watch(viewApiProvider).tokenBalance(vaultAddress, AppConfig.usdcMint),
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
  final api = ref.watch(viewApiProvider);
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

/// A rule or schedule of a plan, as claimed from the Family Circle.
typedef ClaimTarget = ({String vaultOwner, int planId, int index});

/// What claiming [ClaimTarget] costs the connected wallet; null while no
/// wallet is connected or when it cannot be priced (the claim itself then
/// reports why).
final claimQuoteProvider = FutureProvider.autoDispose
    .family<ClaimQuote?, ClaimTarget>((ref, target) async {
      final owner = ref.watch(sessionProvider.select((s) => s.owner));
      if (owner == null) return null;
      try {
        return await ref
            .watch(viewApiProvider)
            .quoteClaim(
              claimer: owner,
              vaultOwner: target.vaultOwner,
              planId: target.planId,
              index: target.index,
            );
      } on Object {
        return null;
      }
    });

/// [mint] (base units) held by the plan vault at `vault`.
final planTokenProvider =
    FutureProvider.family<int, ({String vault, String mint})>(
      (ref, k) => ref.watch(viewApiProvider).tokenBalance(k.vault, k.mint),
    );
