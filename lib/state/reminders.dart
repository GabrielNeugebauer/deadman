import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';

import 'lockdown_retry.dart';

const _taskName = 'deadman.pulse-check';
const _lockdownTask = 'deadman.lockdown-retry';
const _dueKey = 'pulse_due_at';
const _deadlineKey = 'deadline_at';

final _notifications = FlutterLocalNotificationsPlugin();

/// Background reminder: Android may defer this under Doze, which is fine —
/// the on-chain timer is the source of truth and the grace period absorbs it.
@pragma('vm:entry-point')
void reminderDispatcher() {
  Workmanager().executeTask((task, _) async {
    WidgetsFlutterBinding.ensureInitialized();
    if (task == _lockdownTask) return runPendingLockdownInBackground();
    final prefs = await SharedPreferences.getInstance();
    final due = prefs.getInt(_dueKey);
    final deadline = prefs.getInt(_deadlineKey);
    if (due == null || deadline == null) return true;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    if (now >= due) {
      await _init();
      await notifyPulseDue(overdue: now >= deadline - 3600);
    }
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

/// Cached so the background isolate can decide without RPC calls.
Future<void> scheduleFrom({
  required int pulseDue,
  required int deadline,
}) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setInt(_dueKey, pulseDue);
  await prefs.setInt(_deadlineKey, deadline);
}

Future<void> notifyPulseDue({bool overdue = false}) => _notifications.show(
  id: 1,
  title: overdue ? 'Deadman fires soon' : 'Time to pulse',
  body: overdue
      ? 'Your switch is in its grace period. Open Deadman and pulse now.'
      : 'Tap to check in. Keep your streak alive.',
  notificationDetails: const NotificationDetails(
    android: AndroidNotificationDetails(
      'pulse',
      'Pulse reminders',
      importance: Importance.high,
      priority: Priority.high,
    ),
  ),
);
