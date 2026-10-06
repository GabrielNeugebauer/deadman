import 'dart:convert';

import 'package:deadman/solana/deadman_api.dart';
import 'package:deadman/state/boney.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

const now = 10000000;
const day = 86400;

/// [v] with a different check-in count or lock.
VaultState with_(VaultState v, {int? totalPulses, int? lockedUntil}) =>
    VaultState(
      address: v.address,
      owner: v.owner,
      planId: v.planId,
      label: v.label,
      guard: v.guard,
      guardian: v.guardian,
      lockSecs: v.lockSecs,
      skipGraceSecs: v.skipGraceSecs,
      lastPulse: v.lastPulse,
      ownerLastSeen: v.ownerLastSeen,
      lockedUntil: lockedUntil ?? v.lockedUntil,
      guardianReadyAt: v.guardianReadyAt,
      totalPulses: totalPulses ?? v.totalPulses,
      streak: v.streak,
      bestStreak: v.bestStreak,
      rules: v.rules,
      lamports: v.lamports,
      withdrawableLamports: v.withdrawableLamports,
      kind: v.kind,
      startAt: v.startAt,
    );

/// An inheritance plan last checked in [silentFor] seconds ago, guarded by
/// this phone (addr(2)).
VaultState plan({
  int silentFor = 3600,
  List<RuleState>? rules,
  int planId = 0,
  int? ownerLastSeen,
}) => vault(
  planId: planId,
  lastPulse: now - silentFor,
  ownerLastSeen: ownerLastSeen ?? now - silentFor,
  rules: rules,
);

Boney at(
  List<VaultState> plans, {
  int t = now,
  int? lastCheckInAt,
  String? guard,
  bool blocked = false,
}) => boneyFor(
  plans,
  now: t,
  lastCheckInAt: lastCheckInAt,
  guard: guard ?? addr(2),
  blocked: blocked,
);

void main() {
  group('boneyFor', () {
    test('no plan: make one, from the app', () {
      final b = at(const []);
      expect(b.mood, BoneyMood.noPlan);
      expect(b.title, 'Make a plan');
      expect(b.sticker, 'NO PLAN');
      expect(b.button, BoneyButton.openApp);
      expect(b.dueAt, isNull);
      expect(b.count, 0);
      expect(b.tiers, isEmpty);
    });

    test('vesting only: no plan to check in, and Boney says why', () {
      final b = at([vestingVault()]);
      expect(b.mood, BoneyMood.noPlan);
      expect(b.title, 'Vesting only');
      expect(b.caption, contains('No check-ins needed'));
      expect(b.sticker, 'VESTING');
      expect(b.button, BoneyButton.openApp);
      expect(b.count, 0);
    });

    test('on track: counting down to tier 1, Check in', () {
      final b = at([plan()]);
      expect(b.mood, BoneyMood.onTrack);
      expect(b.title, 'On track');
      expect(b.caption, 'until tier 1 releases');
      expect(b.sticker, 'ALIVE');
      expect(b.button, BoneyButton.checkIn);
      expect(b.button.label, 'Check in');
      expect(b.dueAt, now - 3600 + 10 * day);
      expect(b.tiers, [
        (label: 'Tier 1', value: '100% SOL → ${short(addr(10))}'),
      ]);
    });

    test('check in soon: one hour or less left, still alive', () {
      final p = plan(silentFor: 10 * day - 3600);
      expect(at([p]).mood, BoneyMood.checkInSoon);
      expect(at([p]).title, 'Check in soon?');
      expect(at([p]).sticker, 'ALIVE');
      expect(at([p]).button, BoneyButton.checkIn);
      expect(at([p], t: now - 1).mood, BoneyMood.onTrack);
      // The release second itself is still alive.
      expect(at([p], t: now + 3600).mood, BoneyMood.checkInSoon);
    });

    test('checked in: five minutes of celebration, then on track', () {
      final p = plan(silentFor: 60);
      final b = at([p], lastCheckInAt: now - 60);
      expect(b.mood, BoneyMood.checkedIn);
      expect(b.title, 'Pulse recorded!');
      expect(b.caption, 'until tier 1 releases');
      expect(at([p], lastCheckInAt: now - 300).mood, BoneyMood.onTrack);
      // A clock that went backwards is not a check-in.
      expect(at([p], lastCheckInAt: now + 60).mood, BoneyMood.onTrack);
    });

    test('nothing is ever "missed": late stays alive until a tier is due', () {
      for (final silent in [day, 5 * day, 10 * day - 1]) {
        final mood = at([plan(silentFor: silent)]).mood;
        expect(mood, isNot(BoneyMood.tierDue));
        expect(BoneyMood.values.map((m) => m.wire), isNot(contains('missed')));
      }
    });

    test('tier due: releasing to the beneficiary, Check in to stop', () {
      final p = plan(
        silentFor: 2 * day,
        rules: [
          rule(seed: 10, afterSecs: day, amount: 2500),
          rule(seed: 11, afterSecs: 3 * day, amount: 5000),
          rule(seed: 12, afterSecs: 5 * day),
        ],
      );
      final b = at([p]);
      expect(b.mood, BoneyMood.tierDue);
      expect(b.title, 'Tier 1 releasing');
      expect(b.caption, 'past due, releasing to ${short(addr(10))}');
      expect(b.sticker, 'TIER DUE');
      expect(b.button, BoneyButton.checkInStop);
      expect(b.button.label, 'Check in to stop');
      expect(b.dueAt, now - day);
      expect(b.tiers, [
        (label: 'Tier 1', value: 'due'),
        (label: 'Tier 2', value: '50% SOL → ${short(addr(11))}'),
        (label: 'Tier 3', value: '100% SOL → ${short(addr(12))}'),
      ]);
    });

    test('last tier: the final pending tier is due', () {
      final p = plan(
        silentFor: 2 * day,
        ownerLastSeen: now,
        rules: [
          rule(seed: 10, afterSecs: day ~/ 2, executedAt: now - day),
          rule(seed: 11, afterSecs: day),
        ],
      );
      final b = at([p]);
      expect(b.mood, BoneyMood.lastTier);
      expect(b.title, 'Last chance');
      expect(b.caption, 'past due, releasing to ${short(addr(11))}');
      expect(b.sticker, 'LAST TIER');
      expect(b.button, BoneyButton.checkInStop);
      expect(b.tiers, [
        (label: 'Tier 1', value: 'released'),
        (label: 'Tier 2', value: 'due'),
      ]);
    });

    test('released: n of n tiers paid out, Open Deadman', () {
      final p = plan(
        rules: [
          rule(seed: 10, afterSecs: day, executedAt: now - 2 * day),
          rule(seed: 11, afterSecs: 2 * day, executedAt: now - day),
        ],
      );
      final b = at([with_(p, totalPulses: 7)]);
      expect(b.mood, BoneyMood.released);
      expect(b.title, 'Plan released');
      expect(b.caption, '2 of 2 tiers paid out. Rest easy.');
      expect(b.sticker, 'RELEASED');
      expect(b.button, BoneyButton.openApp);
      expect(b.button.label, 'Open Deadman');
      expect(b.dueAt, isNull);
      expect(b.count, 7);
      expect(b.tiers.map((t) => t.value), ['released', 'released']);

      final two = at([p, plan(planId: 1, rules: p.rules)]);
      expect(two.title, 'Plans released');
      expect(two.caption, '4 of 4 tiers paid out. Rest easy.');
    });

    test('a skipped tier awaiting its claim is not a released plan', () {
      final p = plan(
        rules: [rule(afterSecs: day, skippedAt: now - day)],
      );
      final b = at([p]);
      expect(b.mood, BoneyMood.released);
      expect(b.title, 'Nothing pending');
      expect(b.tiers.single.value, 'skipped');
    });

    test('follows the earliest release across plans', () {
      final slow = plan(planId: 0, rules: [rule(seed: 10, afterSecs: 9 * day)]);
      final fast = plan(planId: 1, rules: [rule(seed: 11, afterSecs: 2 * day)]);
      final b = at([slow, fast]);
      expect(b.dueAt, fast.nextReleaseAt);
      expect(b.tiers.single.value, contains(short(addr(11))));
    });

    test('the heart counts check-ins on the longest-running plan', () {
      final b = at([
        with_(plan(planId: 0), totalPulses: 12),
        with_(plan(planId: 1), totalPulses: 3),
        vestingVault(),
      ]);
      // One check-in pulses every plan: a sum would count it twice.
      expect(b.count, 12);
    });

    test('three tier rows around the next tier', () {
      final p = plan(
        ownerLastSeen: now,
        rules: [
          for (var i = 0; i < 5; i++)
            rule(
              seed: 10 + i,
              afterSecs: (i + 1) * day,
              executedAt: i < 3 ? now - day : 0,
            ),
        ],
      );
      expect(at([p]).tiers.map((t) => t.label), ['Tier 3', 'Tier 4', 'Tier 5']);
    });

    test('no guard key here: the widget opens the app instead', () {
      final b = boneyFor([plan()], now: now);
      expect(b.mood, BoneyMood.onTrack);
      expect(b.button, BoneyButton.openApp);
      expect(b.caption, Boney.openToCheckIn);
    });

    test('guarded by another device: open the app', () {
      final b = at([plan()], guard: addr(77));
      expect(b.button, BoneyButton.openApp);
      expect(b.caption, Boney.openToCheckIn);
    });

    test('guard window over: open the app, the due caption stays', () {
      final p = plan(
        silentFor: 2 * day,
        ownerLastSeen: now - 400 * day,
        rules: [
          rule(afterSecs: day),
          rule(seed: 11, afterSecs: 3 * day),
        ],
      );
      final b = at([p]);
      expect(b.mood, BoneyMood.tierDue);
      expect(b.button, BoneyButton.openApp);
      expect(b.caption, startsWith('past due, releasing to'));
    });

    test(
      'a lockdown never shows on the home screen, it only opens the app',
      () {
        final b = at([plan()], blocked: true);
        expect(b.mood, BoneyMood.onTrack);
        expect(b.sticker, 'ALIVE');
        expect(b.button, BoneyButton.openApp);
        expect(b.caption, Boney.openToCheckIn);
        expect('$b', isNot(contains('LOCK')));
      },
    );

    test('checking keeps the countdown and hides the button', () {
      final b = at([plan()]).checking;
      expect(b.mood, BoneyMood.checking);
      expect(b.title, 'Checking in…');
      expect(b.button, BoneyButton.none);
      expect(b.dueAt, at([plan()]).dueAt);
    });
  });

  group('widget data contract', () {
    test('keys and types the Android widget reads', () {
      final data = at([with_(plan(), totalPulses: 12)]).toWidgetData();
      expect(data.keys.toSet(), {
        'boney_state',
        'boney_title',
        'boney_caption',
        'boney_sticker',
        'boney_due_at',
        'boney_count',
        'boney_tiers',
        'boney_button',
      });
      expect(data['boney_state'], 'on_track');
      expect(data['boney_button'], 'check_in');
      expect(data['boney_count'], 12);
      // Unix seconds.
      expect(data['boney_due_at'], now - 3600 + 10 * day);
      expect(jsonDecode(data['boney_tiers']! as String), [
        {'label': 'Tier 1', 'value': '100% SOL → ${short(addr(10))}'},
      ]);
      expect(at(const []).toWidgetData()['boney_due_at'], isNull);
    });

    test('every state and button has its wire name', () {
      expect(BoneyMood.values.map((m) => m.wire), [
        'checking',
        'checked_in',
        'on_track',
        'check_in_soon',
        'tier_due',
        'last_tier',
        'released',
        'no_plan',
      ]);
      expect(BoneyButton.values.map((b) => b.wire), [
        'check_in',
        'check_in_to_stop',
        'open_app',
        'none',
      ]);
    });

    test('round-trips through widget storage', () {
      final b = at([
        plan(
          silentFor: 2 * day,
          rules: [
            rule(afterSecs: day),
            rule(),
          ],
        ),
      ]);
      final back = Boney.fromWidgetData(b.toWidgetData())!;
      expect(back.mood, b.mood);
      expect(back.title, b.title);
      expect(back.caption, b.caption);
      expect(back.sticker, b.sticker);
      expect(back.button, b.button);
      expect(back.dueAt, b.dueAt);
      expect(back.count, b.count);
      expect(back.tiers, b.tiers);
      expect(Boney.fromWidgetData(const {}), isNull);
    });
  });
}

String short(String a) => '${a.substring(0, 4)}…${a.substring(a.length - 4)}';
