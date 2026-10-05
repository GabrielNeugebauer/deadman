/// When to remind the owner to check in, counted back from the next
/// release. Pure, so the background isolate and tests share it.
library;

const _day = 86400;

/// Seconds before the release to remind at, latest last; 0 is the release
/// itself. Days-long waits get 3 days, 1 day and 1 hour; a lead is kept
/// only while it is at most half the tier's [delaySecs], and a wait too
/// short for any of them (demo timings) gets one at half the wait.
List<int> reminderLeads(int delaySecs) {
  final leads = [
    for (final lead in const [3 * _day, _day, 3600])
      if (lead * 2 <= delaySecs) lead,
  ];
  if (leads.isEmpty && delaySecs >= 2) leads.add(delaySecs ~/ 2);
  return [...leads, 0];
}

/// The reminder due at [now] for a release at [releaseAt] after a wait of
/// [delaySecs]: the latest lead already reached, or null before the first.
int? reminderLead({
  required int now,
  required int releaseAt,
  required int delaySecs,
}) {
  int? reached;
  for (final lead in reminderLeads(delaySecs)) {
    if (now >= releaseAt - lead) reached = lead;
  }
  return reached;
}

/// "3 days", "1 hour", "5 minutes": how far off a release is.
String leadText(int secs) {
  String plural(int n, String unit) => '$n $unit${n == 1 ? '' : 's'}';
  if (secs >= _day) return plural(secs ~/ _day, 'day');
  if (secs >= 3600) return plural(secs ~/ 3600, 'hour');
  if (secs >= 60) return plural(secs ~/ 60, 'minute');
  return plural(secs, 'second');
}

/// Title and body of a reminder [remaining] seconds before the release
/// (0 or less: it is due).
(String, String) reminderText(int remaining) => remaining <= 0
    ? (
        'A payout is due',
        'A tier of your plan is due. Open Deadman and check in to stop it '
            "if it hasn't been sent yet.",
      )
    : (
        'Time to check in',
        'A payout releases in ${leadText(remaining)}. Check in to restart its '
            'clock.',
      );
