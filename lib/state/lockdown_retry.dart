import 'dart:async';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:solana/solana.dart';

import '../solana/deadman_api.dart';
import '../solana/deadman_client.dart';
import 'plan_math.dart';
import 'secure_store.dart';

/// Lockdown cannot work from this device (no guard key, no plans, or no
/// plan it guards). Retrying will not help.
class LockdownUnavailable implements Exception {
  const LockdownUnavailable(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Locks every plan of [owner] that [guard] guards. Throws
/// [LockdownUnavailable] when there is nothing it can lock; the report
/// names plans guarded by another key.
Future<LockReport> lockGuardedPlans(
  DeadmanApi api,
  Ed25519HDKeyPair? guard,
  String owner,
) async {
  if (guard == null) {
    throw const LockdownUnavailable(
      'Nothing was locked: this phone has no guard key. Use Move guard to this phone first.',
    );
  }
  final plans = await api.fetchVaults(owner);
  if (plans.isEmpty) {
    throw const LockdownUnavailable('Nothing was locked: you have no plans');
  }
  final mine = [
    for (final v in plans)
      if (v.guard == guard.address) v,
  ];
  final other = [
    for (final v in plans)
      if (v.guard != guard.address) v,
  ];
  if (mine.isEmpty) {
    throw LockdownUnavailable(
      'Nothing was locked: ${other.map(planName).join(', ')} '
      '${other.length == 1 ? 'is' : 'are'} guarded by another device. Use Move guard to this phone first.',
    );
  }
  await api.lockdownWithGuard(
    guard,
    vaultOwner: owner,
    planIds: [for (final v in mine) v.planId],
  );
  return LockReport(locked: mine, uncovered: other);
}

/// A duress lockdown that has not gone through yet, persisted so a retry
/// survives the app being killed.
class PendingLockdown {
  PendingLockdown(this._prefs);

  final SharedPreferences _prefs;
  static const _ownerKey = 'pending_lockdown_owner';

  String? get owner => _prefs.getString(_ownerKey);
  Future<void> mark(String owner) => _prefs.setString(_ownerKey, owner);
  Future<void> clear() => _prefs.remove(_ownerKey);
}

/// 5 s, 15 s, 30 s, 1 min, 2 min, then every 5 min.
Duration lockdownBackoff(int attempt) =>
    Duration(seconds: const [5, 15, 30, 60, 120, 300][min(attempt, 5)]);

typedef Scheduler = void Function(Duration delay, void Function() run);

/// Duress lockdown that never gives up silently: it retries with backoff
/// until the lock goes through, while the UI keeps looking normal. A
/// Workmanager task (see reminders.dart) covers the app being killed.
class LockdownRetrier {
  LockdownRetrier({
    required this.pending,
    required this.attempt,
    this.onPending,
    this.onDone,
    Scheduler? schedule,
  }) : _schedule = schedule ?? ((d, run) => Timer(d, run));

  final PendingLockdown pending;

  /// Locks [owner]'s plans; throws on failure.
  final Future<void> Function(String owner) attempt;

  /// Called when a lockdown becomes pending (schedule the background task).
  final Future<void> Function()? onPending;

  /// Called once nothing is pending any more (cancel the background task).
  final Future<void> Function()? onDone;
  final Scheduler _schedule;

  int _tries = 0;
  bool _running = false;
  bool _scheduled = false;

  Future<void> start(String owner) async {
    await pending.mark(owner);
    _tries = 0;
    await onPending?.call().catchError((Object _) {});
    await _run();
  }

  /// Picks up a lockdown left pending by an earlier run of the app.
  Future<void> resume() async {
    if (pending.owner == null) return;
    await onPending?.call().catchError((Object _) {});
    await _run();
  }

  /// Returns true once nothing is pending.
  Future<bool> _run() async {
    final owner = pending.owner;
    if (owner == null) return true;
    if (_running) return false;
    _running = true;
    try {
      await attempt(owner);
      await _finish();
      return true;
    } on LockdownUnavailable {
      await _finish();
      return true;
    } catch (_) {
      if (!_scheduled) {
        _scheduled = true;
        _schedule(lockdownBackoff(_tries++), () {
          _scheduled = false;
          unawaited(_run());
        });
      }
      return false;
    } finally {
      _running = false;
    }
  }

  Future<void> _finish() async {
    await pending.clear();
    await onDone?.call().catchError((Object _) {});
  }
}

/// Background (Workmanager) attempt. Returns false to ask for a retry.
Future<bool> runPendingLockdownInBackground() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.reload();
  final pending = PendingLockdown(prefs);
  final owner = pending.owner;
  if (owner == null) return true;
  try {
    final store = SecureStore();
    await lockGuardedPlans(DeadmanClient(), await store.loadGuard(), owner);
  } on LockdownUnavailable {
    // Nothing this device can lock.
  } catch (_) {
    return false;
  }
  await pending.clear();
  return true;
}
