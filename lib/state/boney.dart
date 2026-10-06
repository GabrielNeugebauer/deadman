/// Boney, the Deadman skeleton: what he shows for an owner's plans, on the
/// Pulse screen and on the home-screen widget. Pure, so the app, the
/// background isolate and tests share it.
library;

import 'dart:convert';

import '../solana/deadman_api.dart';
import 'assets.dart';
import 'plan_math.dart';

/// Boney's states. [wire] is the value of `boney_state` the home-screen
/// widget reads. There is no check-in interval, so nothing is ever
/// "missed": the amber pose is kept for real warnings only.
enum BoneyMood {
  /// A widget check-in is in flight.
  checking('checking'),

  /// Within [Boney.checkedInFor] of a check-in from this phone.
  checkedIn('checked_in'),

  /// Counting down, more than [Boney.soonWithin] left.
  onTrack('on_track'),

  /// [Boney.soonWithin] or less before the next release. Still alive.
  checkInSoon('check_in_soon'),

  /// A tier is due (releasing), with more tiers behind it.
  tierDue('tier_due'),

  /// The plan's final pending tier is due.
  lastTier('last_tier'),

  /// Every inheritance plan fully paid out (or nothing left pending).
  released('released'),

  /// No inheritance plan (none at all, or vesting only).
  noPlan('no_plan');

  const BoneyMood(this.wire);

  final String wire;

  static BoneyMood? fromWire(String? s) {
    for (final m in values) {
      if (m.wire == s) return m;
    }
    return null;
  }
}

/// What the widget's button does (`boney_button`).
enum BoneyButton {
  /// "Check in": background guard-key check-in.
  checkIn('check_in', 'Check in'),

  /// "Check in to stop": a tier is due; a check-in still stops it.
  checkInStop('check_in_to_stop', 'Check in to stop'),

  /// "Open Deadman": nothing this phone can check in from the widget.
  openApp('open_app', 'Open Deadman'),

  /// No button (a check-in is in flight).
  none('none', '');

  const BoneyButton(this.wire, this.label);

  final String wire;
  final String label;

  static BoneyButton? fromWire(String? s) {
    for (final b in values) {
      if (b.wire == s) return b;
    }
    return null;
  }
}

typedef BoneyTier = ({String label, String value});

/// Everything Boney says, in one value. Times are unix seconds.
class Boney {
  const Boney({
    required this.mood,
    required this.title,
    required this.caption,
    required this.sticker,
    required this.button,
    this.dueAt,
    this.count = 0,
    this.tiers = const [],
  });

  /// How long after a check-in Boney celebrates.
  static const checkedInFor = 5 * 60;

  /// How close to the next release "check in soon" starts.
  static const soonWithin = 3600;

  /// Shown instead of a check-in when this phone can't do one from the
  /// widget (no guard key, the guard can no longer check in, a lockdown).
  static const openToCheckIn = 'Open Deadman to check in';

  final BoneyMood mood;

  /// Small-widget line: "On track", "Tier 1 releasing", "Last chance".
  final String title;

  /// Line under the countdown: "until tier 1 releases",
  /// "past due, releasing to 4Ywp…KMbF".
  final String caption;

  /// Sticker word: "ALIVE", "TIER DUE", "RELEASED".
  final String sticker;
  final BoneyButton button;

  /// The next release (counting down) or the release that is due (counting
  /// up); null when nothing is pending.
  final int? dueAt;

  /// Check-ins recorded on chain (the heart counter). Not a streak.
  final int count;

  /// Up to three tiers of the plan Boney is about.
  final List<BoneyTier> tiers;

  Boney copyWith({
    BoneyMood? mood,
    String? title,
    String? caption,
    String? sticker,
    BoneyButton? button,
  }) => Boney(
    mood: mood ?? this.mood,
    title: title ?? this.title,
    caption: caption ?? this.caption,
    sticker: sticker ?? this.sticker,
    button: button ?? this.button,
    dueAt: dueAt,
    count: count,
    tiers: tiers,
  );

  /// This state while a widget check-in runs: no button, same countdown.
  Boney get checking => copyWith(
    mood: BoneyMood.checking,
    title: 'Checking in…',
    caption: 'Recording your pulse',
    sticker: 'ALIVE',
    button: BoneyButton.none,
  );

  /// This state when the widget can't check in: the button opens the app.
  /// Due states keep their caption (who the release goes to).
  Boney get mustOpenApp => copyWith(
    button: BoneyButton.openApp,
    caption: switch (mood) {
      BoneyMood.tierDue || BoneyMood.lastTier => caption,
      BoneyMood.released || BoneyMood.noPlan => caption,
      _ => openToCheckIn,
    },
  );

  /// The widget data contract (`boney_*` keys). `boney_due_at` is unix
  /// seconds and is left out (null) when there is no countdown.
  Map<String, Object?> toWidgetData() => {
    'boney_state': mood.wire,
    'boney_title': title,
    'boney_caption': caption,
    'boney_sticker': sticker,
    'boney_due_at': dueAt,
    'boney_count': count,
    'boney_tiers': jsonEncode([
      for (final t in tiers) {'label': t.label, 'value': t.value},
    ]),
    'boney_button': button.wire,
  };

  /// Reads [toWidgetData] back (the background isolate starts from the
  /// last state it pushed); null when nothing usable was saved.
  static Boney? fromWidgetData(Map<String, Object?> data) {
    final mood = BoneyMood.fromWire(data['boney_state'] as String?);
    final button = BoneyButton.fromWire(data['boney_button'] as String?);
    if (mood == null || button == null) return null;
    final due = data['boney_due_at'];
    final count = data['boney_count'];
    var tiers = const <BoneyTier>[];
    try {
      tiers = [
        for (final t in jsonDecode('${data['boney_tiers'] ?? '[]'}') as List)
          (label: '${t['label']}', value: '${t['value']}'),
      ];
    } on Object {
      // Keep the rest.
    }
    return Boney(
      mood: mood,
      title: '${data['boney_title'] ?? ''}',
      caption: '${data['boney_caption'] ?? ''}',
      sticker: '${data['boney_sticker'] ?? ''}',
      button: button,
      dueAt: due is num && due > 0 ? due.toInt() : null,
      count: count is num ? count.toInt() : 0,
      tiers: tiers,
    );
  }

  @override
  String toString() => 'Boney(${mood.wire}, $title, $caption, ${button.wire})';
}

/// Boney for an owner's [plans] at [now].
///
/// [lastCheckInAt] is the last check-in made from this phone (in the app
/// or the widget); [guard] is this phone's guard address (null: none);
/// [blocked] is a duress lockdown pending or in force, during which the
/// widget never checks in on its own.
Boney boneyFor(
  List<VaultState> plans, {
  required int now,
  int? lastCheckInAt,
  String? guard,
  bool blocked = false,
}) {
  final switches = switchPlans(plans);
  final active = activeSwitchPlans(plans);
  // One check-in pulses every plan, so a sum would count it once per plan;
  // the longest-running plan has seen every check-in.
  final count = switches.fold(
    0,
    (n, v) => v.totalPulses > n ? v.totalPulses : n,
  );

  if (switches.isEmpty) {
    final vesting = plans.isNotEmpty;
    return Boney(
      mood: BoneyMood.noPlan,
      title: vesting ? 'Vesting only' : 'Make a plan',
      caption: vesting
          ? 'Vesting pays out on its own schedule. No check-ins needed.'
          : 'Build a release plan in Deadman.',
      sticker: vesting ? 'VESTING' : 'NO PLAN',
      button: BoneyButton.openApp,
      count: count,
    );
  }

  if (active.isEmpty) {
    final rules = [for (final v in switches) ...v.rules];
    final paid = rules.where((r) => r.executed).length;
    final done = switches.every((v) => v.completed);
    final plan = switches.last;
    return Boney(
      mood: BoneyMood.released,
      title: !done
          ? 'Nothing pending'
          : switches.length == 1
          ? 'Plan released'
          : 'Plans released',
      caption: done
          ? '$paid of ${rules.length} tiers paid out. Rest easy.'
          : 'No tier pending. Reserved shares await their claim.',
      sticker: 'RELEASED',
      button: BoneyButton.openApp,
      count: count,
      tiers: _tierRows(plan, now, null),
    );
  }

  final urgent = active.reduce(
    (a, b) => a.nextReleaseAt! <= b.nextReleaseAt! ? a : b,
  );
  final next = urgent.nextReleaseAt!;
  final tier = _nextTier(urgent);
  final rows = _tierRows(urgent, now, tier);
  final cover = PlanCoverage.of(plans, guard, now);
  final canCheckIn = !blocked && cover.guarded.isNotEmpty;

  final Boney boney;
  if (now > next) {
    final last = urgent.rules.where((r) => !r.settled).length == 1;
    final to = tier == null ? null : _short(urgent.rules[tier].beneficiary);
    boney = Boney(
      mood: last ? BoneyMood.lastTier : BoneyMood.tierDue,
      title: last
          ? 'Last chance'
          : tier == null
          ? 'Tier releasing'
          : 'Tier ${tier + 1} releasing',
      caption: to == null
          ? 'tier due, releasing'
          : 'past due, releasing to $to',
      sticker: last ? 'LAST TIER' : 'TIER DUE',
      button: BoneyButton.checkInStop,
      dueAt: next,
      count: count,
      tiers: rows,
    );
  } else {
    final checkedIn =
        lastCheckInAt != null &&
        now >= lastCheckInAt &&
        now - lastCheckInAt < Boney.checkedInFor;
    final soon = next - now <= Boney.soonWithin;
    final mood = checkedIn
        ? BoneyMood.checkedIn
        : soon
        ? BoneyMood.checkInSoon
        : BoneyMood.onTrack;
    boney = Boney(
      mood: mood,
      title: switch (mood) {
        BoneyMood.checkedIn => 'Pulse recorded!',
        BoneyMood.checkInSoon => 'Check in soon?',
        _ => 'On track',
      },
      caption: tier == null
          ? 'until the next release'
          : 'until tier ${tier + 1} releases',
      sticker: 'ALIVE',
      button: BoneyButton.checkIn,
      dueAt: next,
      count: count,
      tiers: rows,
    );
  }
  return canCheckIn ? boney : boney.mustOpenApp;
}

/// Index of [v]'s pending tier that comes due first, or null.
int? _nextTier(VaultState v) {
  int? next;
  for (var i = 0; i < v.rules.length; i++) {
    if (v.rules[i].settled) continue;
    if (next == null || v.ruleDueAt(i) < v.ruleDueAt(next)) next = i;
  }
  return next;
}

/// Three tiers of [v] around [next] (the first three when null).
List<BoneyTier> _tierRows(VaultState v, int now, int? next) {
  final n = v.rules.length;
  final maxStart = n > 3 ? n - 3 : 0;
  final start = next == null ? 0 : (next - 1).clamp(0, maxStart);
  return [
    for (var i = start; i < n && i < start + 3; i++)
      (label: 'Tier ${i + 1}', value: _tierValue(v, i, now)),
  ];
}

String _tierValue(VaultState v, int i, int now) {
  final r = v.rules[i];
  if (r.executed) return 'released';
  if (r.skipped) return 'skipped';
  if (now > v.ruleDueAt(i)) return 'due';
  final amount = switch (r.mode) {
    AmountMode.percent =>
      '${percentText(r.amount / 10000)} ${assetSymbol(r.mint)}',
    AmountMode.fixed => amountText(r.amount, r.mint),
  };
  return '$amount → ${_short(r.beneficiary)}';
}

String _short(String a) =>
    a.length <= 10 ? a : '${a.substring(0, 4)}…${a.substring(a.length - 4)}';
