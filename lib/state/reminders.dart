import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';

import 'lockdown_retry.dart';
import 'reminder_schedule.dart';

const _taskName = 'deadman.pulse-check';
const _lockdownTask = 'deadman.lockdown-retry';
const _releaseKey = 'release_at';
const _delayKey = 'release_delay';

/// "releaseAt:lead" of the last reminder shown, so each fires once.
const _shownKey = 'reminder_shown';

final _notifications = FlutterLocalNotificationsPlugin();

/// Background reminder ahead of the next release (see [reminderLeads]).
/// Android may defer it under Doze; the on-chain timer is the source of
/// truth.
@pragma('vm:entry-point')
void reminderDispatcher() {
  Workmanager().executeTask((task, _) async {
    WidgetsFlutterBinding.ensureInitialized();
    if (task == _lockdownTask) return runPendingLockdownInBackground();
    final prefs = await SharedPreferences.getInstance();
    final releaseAt = prefs.getInt(_releaseKey);
    final delay = prefs.getInt(_delayKey);
    if (releaseAt == null || delay == null) return true;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final lead = reminderLead(now: now, releaseAt: releaseAt, delaySecs: delay);
    if (lead == null || prefs.getString(_shownKey) == '$releaseAt:$lead') {
      return true;
    }
    await _init();
    await notifyRelease(releaseAt - now);
    await prefs.setString(_shownKey, '$releaseAt:$lead');
    return true;
  });
}

Future<void> _init() => _notifications.initialize(
  settings: const InitializationSettings(
    android: AndroidInitializationSettings('@mipmap/ic_launcher'),
  ),
);

Future<void> initReminders() async {
  await _init();
  await _notifications
      .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin
      >()
      ?.requestNotificationsPermission();
  await Workmanager().initialize(reminderDispatcher);
  await Workmanager().registerPeriodicTask(
    _taskName,
    _taskName,
    frequency: const Duration(hours: 1),
    existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
  );
}

/// Retries a pending duress lockdown in the background, with exponential
/// backoff, until it succeeds (the task returns false on failure).
Future<void> scheduleLockdownRetry() => Workmanager().registerOneOffTask(
  _lockdownTask,
  _lockdownTask,
  initialDelay: const Duration(seconds: 30),
  constraints: Constraints(networkType: NetworkType.connected),
  existingWorkPolicy: ExistingWorkPolicy.keep,
  backoffPolicy: BackoffPolicy.exponential,
  backoffPolicyDelay: const Duration(seconds: 30),
);

Future<void> cancelLockdownRetry() =>
    Workmanager().cancelByUniqueName(_lockdownTask);

/// The next release across the owner's plans ([releaseAt], unix seconds)
/// and its tier's wait after a check-in ([delaySecs]). Cached so the
/// background isolate can decide without RPC calls.
Future<void> scheduleFrom({
  required int releaseAt,
  required int delaySecs,
}) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setInt(_releaseKey, releaseAt);
  await prefs.setInt(_delayKey, delaySecs);
}

/// The reminder [remaining] seconds before the next release (0 or less:
/// it is due).
Future<void> notifyRelease(int remaining) {
  final (title, body) = reminderText(remaining);
  return _notifications.show(
    id: 1,
    title: title,
    body: body,
    notificationDetails: _details,
  );
}

const _details = NotificationDetails(
  android: AndroidNotificationDetails(
    'pulse',
    'Pulse reminders',
    importance: Importance.high,
    priority: Priority.high,
  ),
);
