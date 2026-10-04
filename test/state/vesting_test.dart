import 'package:deadman/core/config.dart';
import 'package:deadman/solana/deadman_api.dart';
import 'package:deadman/state/plan_math.dart';
import 'package:deadman/state/vesting.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

void main() {
  const usdc = AppConfig.usdcMint;

  group('vesting progress', () {
    // 1000 USDC over 1000 s from t=1000 with a 100 s cliff.
    final v = vestingVault(
      startAt: 1000,
      schedules: [
        schedule(mint: usdc, total: 1000000000, cliff: 100, duration: 1000),
      ],
    );

    test('nothing before the cliff, linear after, capped at the total', () {
      expect(v.vested(0, 1050), 0);
      expect(v.vested(0, 1100), 100000000);
      expect(v.vested(0, 1500), 500000000);
      expect(v.vested(0, 5000), 1000000000);
    });

    test('progress reports claimable, timing and fractions', () {
      final p = scheduleProgress(v, 0, 1500);
      expect(p.vested, 500000000);
      expect(p.claimable, 500000000);
      expect(p.cliffAt, 1100);
      expect(p.endAt, 2000);
      expect(p.vestedFraction, 0.5);
      expect(p.fullyVested, isFalse);
    });

    test('released amounts reduce claimable and what is committed', () {
      final w = vestingVault(
        startAt: 1000,
        schedules: [
          schedule(
            mint: usdc,
            total: 1000000000,
            duration: 1000,
            released: 300000000,
          ),
          schedule(seed: 21, total: 2000000000, duration: 1000),
        ],
      );
      expect(scheduleProgress(w, 0, 1500).claimable, 200000000);
      expect(scheduleProgress(w, 0, 1500).releasedFraction, 0.3);
      expect(w.committed(usdc), 700000000);
      expect(w.committed(null), 2000000000);
      expect(uncommitted(w, null, 2500000000), 500000000);
      expect(uncommitted(w, usdc, 100), 0);
      expect(shortfall(w, usdc, 500000000), 200000000);
      expect(vestingSettled(w), isFalse);
    });

    test('revocation freezes vesting at the revoke time', () {
      final r = vestingVault(
        startAt: 1000,
        revokedAt: 1250,
        schedules: [schedule(mint: usdc, total: 1000000000, duration: 1000)],
      );
      final p = scheduleProgress(r, 0, 9999);
      expect(p.cap, 250000000);
      expect(p.vested, 250000000);
      expect(p.fullyVested, isTrue);
      expect(p.revoked, isTrue);
      expect(r.committed(usdc), 250000000);
    });
  });

  group('parseSchedule', () {
    VestingSpec parse({
      String? who,
      String? mint = usdc,
      String amount = '1000',
      int cliff = 0,
      int duration = 12 * monthSecs,
    }) => parseSchedule(
      beneficiary: who ?? addr(30),
      rail: Rail.solana,
      mint: mint,
      amount: amount,
      cliffSecs: cliff,
      durationSecs: duration,
    );

    test('USDC totals are typed in USDC and sent in base units', () {
      final s = parse(amount: '1500.25');
      expect(s.total, 1500250000);
      expect(s.mint, usdc);
      expect(parse(mint: null, amount: '0.5').total, 500000000);
    });

    test('a claim code picks the rail', () {
      final s = parse(who: 'zcash:${addr(31)}');
      expect(s.rail, Rail.zcash);
      expect(s.beneficiary, addr(31));
    });

    test('rejects bad input with a message', () {
      expect(() => parse(who: 'nope'), throwsA(isA<VestingInputError>()));
      expect(() => parse(amount: ''), throwsA(isA<VestingInputError>()));
      expect(() => parse(amount: '0'), throwsA(isA<VestingInputError>()));
      expect(
        () => parse(amount: '0.0000001'),
        throwsA(isA<VestingInputError>()),
      );
      expect(
        () => parse(mint: null, amount: '0.0001'),
        throwsA(isA<VestingInputError>()),
      );
      expect(
        () => parse(cliff: 13 * monthSecs),
        throwsA(predicate((e) => '$e'.contains('cliff cannot be longer'))),
      );
    });

    test('plan checks: 1-8 schedules, short name, start within a year', () {
      void check({String label = '', int start = 0, int n = 1}) =>
          checkVestingPlan(label: label, startAt: start, now: 0, schedules: n);
      check();
      check(n: 8, start: 300 * 86400);
      expect(() => check(n: 0), throwsA(isA<VestingInputError>()));
      expect(() => check(n: 9), throwsA(isA<VestingInputError>()));
      expect(() => check(label: 'x' * 33), throwsA(isA<VestingInputError>()));
      expect(
        () => check(start: 400 * 86400),
        throwsA(isA<VestingInputError>()),
      );
    });

    test('totals per asset fund the plan', () {
      final t = totalsByAsset([
        parse(amount: '100'),
        parse(amount: '50.5'),
        parse(mint: null, amount: '1'),
      ]);
      expect(t, {usdc: 150500000, null: 1000000000});
    });
  });

  group('pulse ignores vesting plans', () {
    final inheritance = vault(planId: 0, guard: addr(2));
    final vesting = vestingVault(planId: 1, guard: addr(2));

    test('coverage, active plans and wallet check-ins skip them', () {
      final cover = PlanCoverage.of([inheritance, vesting], addr(2), 2000);
      expect(cover.guarded, [inheritance]);
      expect(cover.needsWallet, isEmpty);
      expect(cover.otherGuard, isEmpty);
      expect(activeSwitchPlans([inheritance, vesting]), [inheritance]);
      expect(switchPlans([inheritance, vesting]), [inheritance]);
      expect(needsWalletCheckIn(vesting, 1000 + 400 * 86400), isFalse);
    });

    test('a vesting-only owner has nothing to check in', () {
      final cover = PlanCoverage.of([vesting], addr(2), 2000);
      expect(cover.isEmpty, isTrue);
      expect(activeSwitchPlans([vesting]), isEmpty);
    });
  });
}
