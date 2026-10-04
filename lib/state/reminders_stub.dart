// Web: no Workmanager or local notifications. The on-chain timer stays the
// source of truth; a pending duress lockdown is retried while the app is
// open (LockdownRetrier) and on the next start.

Future<void> initReminders() async {}

Future<void> scheduleLockdownRetry() async {}

Future<void> cancelLockdownRetry() async {}

Future<void> scheduleFrom({
  required int pulseDue,
  required int deadline,
}) async {}

Future<void> notifyPulseDue({bool overdue = false}) async {}
