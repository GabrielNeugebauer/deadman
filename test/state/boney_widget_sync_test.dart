import 'package:deadman/solana/deadman_api.dart';
import 'package:deadman/solana/deadman_client.dart';
import 'package:deadman/state/boney.dart';
import 'package:deadman/state/boney_widget_sync.dart';
import 'package:deadman/state/lockdown_retry.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:solana/solana.dart';

import 'boney_test.dart' show day, now, plan, with_;
import 'fakes.dart';

/// Widget storage in memory; records every push and redraw.
class FakeHost implements BoneyWidgetHost {
  final data = <String, Object?>{};
  final pushes = <Map<String, Object?>>[];
  var updates = 0;

  BoneyMood? get mood => BoneyMood.fromWire(data['boney_state'] as String?);
  List<String> get moods => [
    for (final p in pushes) p['boney_state']! as String,
  ];

  @override
  Future<void> save(Map<String, Object?> d) async {
    pushes.add(Map.of(d));
    for (final MapEntry(:key, :value) in d.entries) {
      if (value == null) {
        data.remove(key);
      } else {
        data[key] = value;
      }
    }
  }

  @override
  Future<Object?> read(String key) async => data[key];

  @override
  Future<void> update() async => updates++;
}

class FailingPulseApi extends FakeApi {
  FailingPulseApi(super.plans, this.error);

  final Object error;

  @override
  Future<String> pulseWithGuard(
    Ed25519HDKeyPair guard, {
    required String vaultOwner,
    required List<int> planIds,
  }) async => throw error;
}

void main() {
  late SharedPreferences prefs;
  late FakeHost host;
  late Ed25519HDKeyPair guard;
  var clock = now;

  setUpAll(() async => guard = await keyPair(2));

  setUp(() async {
    SharedPreferences.setMockInitialValues({'owner': addr(1)});
    prefs = await SharedPreferences.getInstance();
    host = FakeHost();
    clock = now;
  });

  // Plans guarded by [guard] (the fakes' default guard is addr(2), which
  // is not this key's address).
  VaultState mine(VaultState v) => VaultState(
    address: v.address,
    owner: v.owner,
    planId: v.planId,
    label: v.label,
    guard: guard.address,
    guardian: v.guardian,
    lockSecs: v.lockSecs,
    skipGraceSecs: v.skipGraceSecs,
    lastPulse: v.lastPulse,
    ownerLastSeen: v.ownerLastSeen,
    lockedUntil: v.lockedUntil,
    guardianReadyAt: v.guardianReadyAt,
    totalPulses: v.totalPulses,
    streak: v.streak,
    bestStreak: v.bestStreak,
    rules: v.rules,
    lamports: v.lamports,
    withdrawableLamports: v.withdrawableLamports,
    kind: v.kind,
    startAt: v.startAt,
  );

  BoneyWidgetSync sync() => BoneyWidgetSync(host, clock: () => clock);

  BoneyCheckIn checkIn(FakeApi api, {bool hasGuard = true}) => BoneyCheckIn(
    prefs: prefs,
    api: api,
    loadGuard: () async => hasGuard ? guard : null,
    sync: sync(),
    clock: () => clock,
  );

  test('the check-in URI', () {
    expect(isBoneyCheckIn(Uri.parse(boneyCheckInUri)), isTrue);
    expect(isBoneyCheckIn(Uri.parse('deadman://boney/open')), isFalse);
    expect(isBoneyCheckIn(Uri.parse('https://boney/checkin')), isFalse);
    expect(isBoneyCheckIn(null), isFalse);
  });

  group('syncPlans', () {
    test('pushes Boney and redraws', () async {
      final p = mine(plan());
      final b = await sync().syncPlans([p], prefs: prefs, guard: guard.address);
      expect(b.mood, BoneyMood.onTrack);
      expect(host.mood, BoneyMood.onTrack);
      expect(host.data['boney_button'], 'check_in');
      expect(host.data['boney_due_at'], p.nextReleaseAt);
      expect(host.data['boney_updated_at'], now);
      expect(host.updates, 1);
    });

    test('checked in: the widget times the hold from the check-in', () async {
      await BoneyWidgetSync.markCheckedIn(prefs, now - 120);
      final b = await sync().syncPlans(
        [mine(plan())],
        prefs: prefs,
        guard: guard.address,
      );
      expect(b.mood, BoneyMood.checkedIn);
      // A re-push two minutes later must not restart the five minutes.
      expect(host.data['boney_updated_at'], now - 120);
    });

    test('no plans: no countdown key left behind', () async {
      await sync().syncPlans([mine(plan())], prefs: prefs);
      expect(host.data, contains('boney_due_at'));
      await sync().syncPlans(const [], prefs: prefs);
      expect(host.mood, BoneyMood.noPlan);
      expect(host.data, isNot(contains('boney_due_at')));
    });

    test('a pending lockdown only makes the button open the app', () async {
      await PendingLockdown(prefs).mark(addr(1));
      await sync().syncPlans(
        [mine(plan())],
        prefs: prefs,
        guard: guard.address,
      );
      expect(host.mood, BoneyMood.onTrack);
      expect(host.data['boney_button'], 'open_app');
      expect(host.data['boney_caption'], Boney.openToCheckIn);
    });

    test('loadLast reads back what was pushed', () async {
      final pushed = await sync().syncPlans([mine(plan())], prefs: prefs);
      final last = (await sync().loadLast())!;
      expect(last.mood, pushed.mood);
      expect(last.dueAt, pushed.dueAt);
      expect(last.tiers, pushed.tiers);
    });
  });

  group('widget check-in', () {
    test('checks in every active guarded plan, then celebrates', () async {
      final api = FakeApi([
        mine(plan(planId: 0)),
        mine(plan(planId: 1)),
        vestingVault(guard: guard.address),
      ]);
      final result = await checkIn(api).run();
      expect(result, BoneyCheckInResult.done);
      expect(api.pulsed, [
        [0, 1],
      ]);
      expect(host.moods, ['checking', 'checked_in']);
      expect(host.pushes.first['boney_button'], 'none');
      expect(host.data['boney_title'], 'Pulse recorded!');
      expect(BoneyWidgetSync.lastCheckIn(prefs), now);
      // The reminder follows the new release time.
      expect(prefs.getInt('release_at'), plan(planId: 0).nextReleaseAt);
    });

    test('a tier is due: the check-in stops it', () async {
      final api = FakeApi([
        mine(
          plan(
            silentFor: 2 * day,
            rules: [
              rule(afterSecs: day),
              rule(seed: 11, afterSecs: 3 * day),
            ],
          ),
        ),
      ]);
      expect(await checkIn(api).run(), BoneyCheckInResult.done);
      expect(api.pulsed, [
        [0],
      ]);
    });

    test('no guard key: never attempted, opens the app', () async {
      final api = FakeApi([mine(plan())]);
      expect(
        await checkIn(api, hasGuard: false).run(),
        BoneyCheckInResult.refused,
      );
      expect(api.pulsed, isEmpty);
      expect(host.moods, isNot(contains('checking')));
      expect(host.data['boney_button'], 'open_app');
    });

    test('a pending duress lockdown: never attempted', () async {
      await PendingLockdown(prefs).mark(addr(1));
      final api = FakeApi([mine(plan())]);
      expect(await checkIn(api).run(), BoneyCheckInResult.refused);
      expect(api.pulsed, isEmpty);
      expect(host.data['boney_button'], 'open_app');
    });

    test('a plan under lockdown: never attempted, never said', () async {
      final api = FakeApi([with_(mine(plan()), lockedUntil: now + 29 * day)]);
      expect(await checkIn(api).run(), BoneyCheckInResult.refused);
      expect(api.pulsed, isEmpty);
      expect(host.data['boney_button'], 'open_app');
      expect(host.data['boney_caption'], Boney.openToCheckIn);
      expect(host.data['boney_sticker'], 'ALIVE');
    });

    test('the guard can no longer check in: opens the app', () async {
      final api = FakeApi([mine(plan(ownerLastSeen: now - 400 * day))]);
      expect(await checkIn(api).run(), BoneyCheckInResult.refused);
      expect(api.pulsed, isEmpty);
      expect(host.data['boney_button'], 'open_app');
    });

    test('the program asks for the wallet: refused, opens the app', () async {
      final api = FailingPulseApi(
        [mine(plan())],
        const DeadmanException(
          'Open your wallet',
          code: DeadmanException.ownerConfirmationRequired,
          name: 'OwnerConfirmationRequired',
        ),
      );
      expect(await checkIn(api).run(), BoneyCheckInResult.refused);
      expect(host.data['boney_caption'], Boney.openToCheckIn);
      expect(BoneyWidgetSync.lastCheckIn(prefs), isNull);
    });

    test('a network failure: says to open the app', () async {
      final api = FailingPulseApi([mine(plan())], Exception('429'));
      expect(await checkIn(api).run(), BoneyCheckInResult.failed);
      expect(host.moods.last, 'on_track');
      expect(host.data['boney_button'], 'open_app');
      expect(host.data['boney_caption'], Boney.openToCheckIn);
      expect(BoneyWidgetSync.lastCheckIn(prefs), isNull);
    });

    test('plans unreadable: back to the last state, open the app', () async {
      await sync().syncPlans(
        [mine(plan())],
        prefs: prefs,
        guard: guard.address,
      );
      final api = FakeApi([mine(plan())])..fail = Exception('offline');
      clock += 120;
      expect(await checkIn(api).run(), BoneyCheckInResult.failed);
      expect(host.moods, ['on_track', 'checking', 'on_track']);
      expect(host.data['boney_button'], 'open_app');
    });

    test('a second tap while checking in is ignored', () async {
      await sync().push(
        (await sync().syncPlans([mine(plan())], prefs: prefs)).checking,
      );
      final api = FakeApi([mine(plan())]);
      clock += 10;
      expect(await checkIn(api).run(), BoneyCheckInResult.ignored);
      expect(api.pulsed, isEmpty);
      // A check-in that died long ago does not block the next one.
      clock += BoneyCheckIn.busyFor;
      expect(await checkIn(api).run(), BoneyCheckInResult.done);
    });

    test('every plan released: nothing to check in', () async {
      final api = FakeApi([
        mine(
          plan(
            rules: [rule(afterSecs: day, executedAt: now - day)],
          ),
        ),
      ]);
      expect(await checkIn(api).run(), BoneyCheckInResult.ignored);
      expect(api.pulsed, isEmpty);
      expect(host.mood, BoneyMood.released);
    });

    test('no wallet on this phone: refused', () async {
      await prefs.remove('owner');
      final api = FakeApi([mine(plan())]);
      expect(await checkIn(api).run(), BoneyCheckInResult.refused);
      expect(host.mood, BoneyMood.noPlan);
    });
  });
}
