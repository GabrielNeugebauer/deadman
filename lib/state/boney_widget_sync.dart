/// Keeps the Boney home-screen widget in step with the owner's plans, and
/// runs the widget's one-tap check-in in the background.
///
/// The widget reads the `boney_*` keys (see [Boney.toWidgetData]) plus
/// `boney_updated_at` (unix seconds of the last push). Between pushes it
/// moves on its own from `boney_due_at`: check in soon in the last hour,
/// due once it passes, on track five minutes after a check-in.
library;

import 'package:shared_preferences/shared_preferences.dart';
import 'package:solana/solana.dart';

import '../solana/deadman_api.dart';
import '../solana/deadman_client.dart';
import 'boney.dart';
import 'lockdown_retry.dart';
import 'plan_math.dart';
import 'reminders_stub.dart' if (dart.library.io) 'reminders.dart';

/// The URI the widget's check-in button sends to the background callback.
const boneyCheckInUri = 'deadman://boney/checkin';

bool isBoneyCheckIn(Uri? uri) =>
    uri != null &&
    uri.scheme == 'deadman' &&
    uri.host == 'boney' &&
    uri.path == '/checkin';

/// Where widget data goes: home_widget on Android, a fake in tests.
abstract interface class BoneyWidgetHost {
  Future<void> save(Map<String, Object?> data);
  Future<Object?> read(String key);

  /// Asks the launcher to redraw the widget now.
  Future<void> update();
}

int _nowSecs() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

class BoneyWidgetSync {
  BoneyWidgetSync(this.host, {int Function()? clock})
    : _clock = clock ?? _nowSecs;

  final BoneyWidgetHost host;
  final int Function() _clock;

  /// Prefs key: unix seconds of the last check-in from this phone.
  static const lastCheckInKey = 'boney_checked_in_at';

  static int? lastCheckIn(SharedPreferences prefs) =>
      prefs.getInt(lastCheckInKey);

  static Future<void> markCheckedIn(SharedPreferences prefs, int at) =>
      prefs.setInt(lastCheckInKey, at);

  /// A duress lockdown is pending or in force: the widget never checks in
  /// on its own then (and never says why on the home screen).
  static bool blocked(
    SharedPreferences prefs,
    List<VaultState> plans,
    int now,
  ) =>
      PendingLockdown(prefs).owner != null || plans.any((v) => v.isLocked(now));

  /// Pushes [boney] and redraws the widget. `boney_updated_at` is when the
  /// state began ([since], else now): the widget times "checked in" and
  /// "checking" from it, so a re-push never stretches the celebration.
  Future<void> push(Boney boney, {int? since}) async {
    await host.save({
      ...boney.toWidgetData(),
      'boney_updated_at': since ?? _clock(),
    });
    await host.update();
  }

  /// Boney for [plans] now, pushed. Returns what was pushed.
  Future<Boney> syncPlans(
    List<VaultState> plans, {
    required SharedPreferences prefs,
    String? guard,
  }) async {
    final now = _clock();
    final checkedInAt = lastCheckIn(prefs);
    final boney = boneyFor(
      plans,
      now: now,
      lastCheckInAt: checkedInAt,
      guard: guard,
      blocked: BoneyWidgetSync.blocked(prefs, plans, now),
    );
    await push(
      boney,
      since: boney.mood == BoneyMood.checkedIn ? checkedInAt : null,
    );
    return boney;
  }

  /// The last state pushed, or null.
  Future<Boney?> loadLast() async {
    final data = <String, Object?>{};
    for (final k in const [
      'boney_state',
      'boney_title',
      'boney_caption',
      'boney_sticker',
      'boney_due_at',
      'boney_count',
      'boney_tiers',
      'boney_button',
    ]) {
      data[k] = await host.read(k);
    }
    return Boney.fromWidgetData(data);
  }

  Future<int?> _updatedAt() async {
    final v = await host.read('boney_updated_at');
    return v is num ? v.toInt() : null;
  }
}

/// What a widget check-in did.
enum BoneyCheckInResult {
  /// Every plan the guard key covers was checked in.
  done,

  /// Not attempted: no wallet, no guard key, a lockdown, or the guard can
  /// no longer check in. The widget now says to open the app.
  refused,

  /// Attempted and failed (network, sponsor and guard both out of fees).
  failed,

  /// Nothing to do (a check-in already running, or no plan to check in).
  ignored,
}

/// The widget's "Check in": the guard-key check-in of the app's Pulse
/// button (Kora sponsor, guard-paid fallback), on every active inheritance
/// plan this phone guards. Never runs during a duress lockdown or without
/// a guard key that can still check in.
class BoneyCheckIn {
  BoneyCheckIn({
    required this.prefs,
    required this.api,
    required this.loadGuard,
    required this.sync,
    int Function()? clock,
  }) : _clock = clock ?? _nowSecs;

  final SharedPreferences prefs;
  final DeadmanApi api;
  final Future<Ed25519HDKeyPair?> Function() loadGuard;
  final BoneyWidgetSync sync;
  final int Function() _clock;

  /// A tap while a check-in runs for less than this is ignored.
  static const busyFor = 90;

  Future<BoneyCheckInResult> run() async {
    await prefs.reload();
    final last = await sync.loadLast();
    final updated = await sync._updatedAt();
    if (last?.mood == BoneyMood.checking &&
        updated != null &&
        _clock() - updated < busyFor) {
      return BoneyCheckInResult.ignored;
    }

    final owner = prefs.getString('owner');
    final fallback = last ?? boneyFor(const [], now: _clock());
    Future<BoneyCheckInResult> stop(
      BoneyCheckInResult result, [
      List<VaultState>? plans,
      String? guard,
    ]) async {
      final base = plans == null
          ? fallback
          : boneyFor(
              plans,
              now: _clock(),
              lastCheckInAt: BoneyWidgetSync.lastCheckIn(prefs),
              guard: guard,
            );
      await sync.push(_openApp(base));
      return result;
    }

    if (owner == null || PendingLockdown(prefs).owner != null) {
      return stop(BoneyCheckInResult.refused);
    }
    final guard = await loadGuard();
    if (guard == null) return stop(BoneyCheckInResult.refused);

    await sync.push(fallback.checking);
    List<VaultState> plans;
    try {
      plans = await api.fetchVaults(owner);
    } on Object {
      return stop(BoneyCheckInResult.failed);
    }
    final now = _clock();
    if (BoneyWidgetSync.blocked(prefs, plans, now)) {
      return stop(BoneyCheckInResult.refused, plans, guard.address);
    }
    final cover = PlanCoverage.of(plans, guard.address, now);
    final ids = [
      for (final v in cover.guarded)
        if (v.nextReleaseAt != null) v.planId,
    ];
    if (ids.isEmpty) {
      if (activeSwitchPlans(plans).isEmpty) {
        await sync.syncPlans(plans, prefs: prefs, guard: guard.address);
        return BoneyCheckInResult.ignored;
      }
      return stop(BoneyCheckInResult.refused, plans, guard.address);
    }

    try {
      await api.pulseWithGuard(guard, vaultOwner: owner, planIds: ids);
    } on DeadmanException catch (e) {
      final refused =
          e.code == DeadmanException.ownerConfirmationRequired ||
          e.code == DeadmanException.vaultLocked;
      return stop(
        refused ? BoneyCheckInResult.refused : BoneyCheckInResult.failed,
        plans,
        guard.address,
      );
    } on Object {
      return stop(BoneyCheckInResult.failed, plans, guard.address);
    }

    await BoneyWidgetSync.markCheckedIn(prefs, _clock());
    try {
      plans = await api.fetchVaults(owner);
    } on Object {
      // The countdown catches up at the next sync.
    }
    await cacheNextRelease(plans);
    await sync.syncPlans(plans, prefs: prefs, guard: guard.address);
    return BoneyCheckInResult.done;
  }

  /// [b] with the button opening the app and the reason on screen.
  static Boney _openApp(Boney b) => switch (b.mood) {
    BoneyMood.released || BoneyMood.noPlan => b,
    BoneyMood.checking => b.copyWith(
      mood: BoneyMood.onTrack,
      title: 'On track',
      caption: Boney.openToCheckIn,
      button: BoneyButton.openApp,
    ),
    _ => b.copyWith(caption: Boney.openToCheckIn, button: BoneyButton.openApp),
  };
}

/// Caches the next release for the background reminder (as the app does
/// when it reads the plans), so a widget check-in moves it too.
Future<void> cacheNextRelease(List<VaultState> plans) async {
  final active = activeSwitchPlans(plans);
  if (active.isEmpty) return;
  final urgent = active.reduce(
    (a, b) => a.nextReleaseAt! <= b.nextReleaseAt! ? a : b,
  );
  final releaseAt = urgent.nextReleaseAt!;
  await scheduleFrom(
    releaseAt: releaseAt,
    delaySecs: releaseAt - urgent.lastPulse,
  );
}
