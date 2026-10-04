import 'package:deadman/state/lockdown_retry.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:solana/solana.dart';

import 'fakes.dart';

void main() {
  late SharedPreferences prefs;
  late PendingLockdown pending;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    pending = PendingLockdown(prefs);
  });

  group('LockdownRetrier', () {
    test('keeps the flag and backs off until the lockdown succeeds', () async {
      final delays = <Duration>[];
      final runs = <void Function()>[];
      var failuresLeft = 2;
      var scheduledBackground = 0;
      var done = 0;
      final r = LockdownRetrier(
        pending: pending,
        attempt: (owner) async {
          expect(owner, 'owner1');
          if (failuresLeft-- > 0) throw Exception('429');
        },
        onPending: () async => scheduledBackground++,
        onDone: () async => done++,
        schedule: (d, run) {
          delays.add(d);
          runs.add(run);
        },
      );

      await r.start('owner1');
      expect(scheduledBackground, 1);
      expect(PendingLockdown(prefs).owner, 'owner1');
      expect(delays, [const Duration(seconds: 5)]);

      runs.removeLast()();
      await pumpEventQueue();
      expect(pending.owner, 'owner1');
      expect(delays.last, const Duration(seconds: 15));

      runs.removeLast()();
      await pumpEventQueue();
      expect(pending.owner, isNull);
      expect(done, 1);
      expect(delays, hasLength(2));
    });

    test('stops when this device can never lock', () async {
      final r = LockdownRetrier(
        pending: pending,
        attempt: (_) async => throw const LockdownUnavailable('no guard'),
        schedule: (_, _) => fail('should not retry'),
      );
      await r.start('owner1');
      expect(pending.owner, isNull);
    });

    test('resume picks up a lockdown left pending by an earlier run', () async {
      await pending.mark('owner2');
      final seen = <String>[];
      final r = LockdownRetrier(
        pending: pending,
        attempt: (owner) async => seen.add(owner),
      );
      await r.resume();
      expect(seen, ['owner2']);
      expect(pending.owner, isNull);

      await r.resume();
      expect(seen, ['owner2']);
    });
  });

  test('backoff grows to a 5 minute ceiling', () {
    expect(
      [for (var i = 0; i < 8; i++) lockdownBackoff(i).inSeconds],
      [5, 15, 30, 60, 120, 300, 300, 300],
    );
  });

  group('lockGuardedPlans', () {
    late Ed25519HDKeyPair guard;
    setUpAll(() async => guard = await Ed25519HDKeyPair.random());

    test('no guard key is an error, not a silent success', () async {
      expect(
        () => lockGuardedPlans(FakeApi([vault()]), null, addr(1)),
        throwsA(isA<LockdownUnavailable>()),
      );
    });

    test('no plan guarded by this phone names the plans', () async {
      final api = FakeApi([vault(label: 'Kids')]);
      await expectLater(
        lockGuardedPlans(api, guard, addr(1)),
        throwsA(
          isA<LockdownUnavailable>().having(
            (e) => e.message,
            'message',
            contains('Kids is guarded by another device'),
          ),
        ),
      );
      expect(api.locked, isEmpty);
    });

    test('locks the plans it guards and reports the others', () async {
      final api = FakeApi([
        vault(planId: 0, guard: guard.address),
        vault(planId: 1, label: 'Old'),
        vault(planId: 2, guard: guard.address),
      ]);
      final r = await lockGuardedPlans(api, guard, addr(1));
      expect(api.locked, [
        [0, 2],
      ]);
      expect(r.complete, isFalse);
      expect(r.uncovered.single.label, 'Old');
    });
  });
}
