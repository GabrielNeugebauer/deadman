import 'package:deadman/solana/deadman_api.dart';
import 'package:deadman/state/plan_math.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

TierAmount pct(double p, {int after = 1, String? mint}) => TierAmount(
  mint: mint,
  mode: AmountMode.percent,
  amount: (p * 100).round(),
  afterSecs: after,
);

TierAmount fixed(int amount, {int after = 1, String? mint}) => TierAmount(
  mint: mint,
  mode: AmountMode.fixed,
  amount: amount,
  afterSecs: after,
);

List<String?> shares(AssetPreview a) => [
  for (final s in a.tiers) s.share == null ? null : percentText(s.share!),
];

void main() {
  group('previewShares', () {
    test('percentages compound on what is left', () {
      final [sol] = previewShares([pct(50, after: 1), pct(50, after: 2)]);
      expect(shares(sol), ['50%', '25%']);
      expect(percentText(sol.leftover!), '25%');
      expect(sol.lastTakesAll, isFalse);
    });

    test('a final 100% of remaining leaves nothing', () {
      final [sol] = previewShares([pct(10, after: 1), pct(100, after: 2)]);
      expect(shares(sol), ['10%', '90%']);
      expect(sol.leftover, 0);
      expect(sol.lastTakesAll, isTrue);
    });

    test('follows delay order, not list order', () {
      final [sol] = previewShares([pct(100, after: 9), pct(20, after: 1)]);
      expect([for (final s in sol.tiers) s.index], [1, 0]);
      expect(shares(sol), ['20%', '80%']);
      expect(sol.lastTakesAll, isTrue);
    });

    test('assets are independent; incomplete drafts are ignored', () {
      final mint = addr(5);
      final previews = previewShares([
        pct(50, after: 1),
        null,
        pct(30, after: 2, mint: mint),
        pct(100, after: 3, mint: mint),
      ]);
      expect(previews.map((a) => a.mint), [null, mint]);
      expect(shares(previews[0]), ['50%']);
      expect(shares(previews[1]), ['30%', '70%']);
      expect(previews[1].lastTakesAll, isTrue);
    });

    test('fixed tiers use the known balance, capped at what is left', () {
      final [sol] = previewShares([
        fixed(250, after: 1),
        pct(50, after: 2),
        fixed(900, after: 3),
      ], balanceOf: (_) => 1000);
      expect(shares(sol), ['25%', '37.5%', '37.5%']);
      expect(sol.leftover, 0);
      expect(sol.lastTakesAll, isFalse);
    });

    test('fixed tiers with an unknown balance make later shares unknown', () {
      final [sol] = previewShares([fixed(250, after: 1), pct(100, after: 2)]);
      expect(shares(sol), [null, null]);
      expect(sol.leftover, isNull);
      expect(sol.lastTakesAll, isTrue);
    });
  });

  test('percentText trims trailing zeros', () {
    expect(percentText(0.5), '50%');
    expect(percentText(0.125), '12.5%');
    expect(percentText(1 / 3), '33.33%');
  });

  group('splitRules', () {
    test('paid and skipped tiers are history; only pending ones are '
        'editable', () {
      final v = vault(
        rules: [
          rule(seed: 11, executedAt: 500),
          rule(seed: 12, skippedAt: 600, reserved: 7),
          rule(seed: 13),
        ],
      );
      final s = splitRules(v);
      expect(s.history.map((r) => r.beneficiary), [addr(11), addr(12)]);
      expect(s.pending.map((r) => r.beneficiary), [addr(13)]);
    });

    test('a skipped but unclaimed tier keeps the history (plan not done)', () {
      final v = vault(
        rules: [
          rule(seed: 11, executedAt: 500),
          rule(seed: 12, skippedAt: 600, reserved: 7),
        ],
      );
      expect(v.completed, isFalse);
      final s = splitRules(v);
      expect(s.history.map((r) => r.beneficiary), [addr(11), addr(12)]);
      expect(s.pending, isEmpty);
    });

    test('a fully released plan keeps its history (it is final)', () {
      final s = splitRules(vault(rules: [rule(executedAt: 5)]));
      expect(s.history, hasLength(1));
      expect(s.pending, isEmpty);
    });
  });

  group('PlanCoverage', () {
    final me = addr(2);
    final now = 2000;
    final ok = vault(planId: 0, label: 'Kids');
    final other = vault(planId: 1, label: 'Old', guard: addr(3));
    final stale = vault(
      planId: 2,
      label: 'Savings',
      rules: [rule(executedAt: 1500), rule(seed: 11)],
    );
    final done = vault(planId: 3, rules: [rule(executedAt: 1500)]);

    test('pulses only plans this guard can check in', () {
      final c = PlanCoverage.of([ok, other, stale, done], me, now);
      expect(c.guarded, [ok]);
      expect(c.otherGuard, [other]);
      expect(c.needsWallet, [stale]);
      expect(c.complete, isFalse);
    });

    test('no guard on this phone: every active plan is uncovered', () {
      final c = PlanCoverage.of([ok, other], null, now);
      expect(c.guarded, isEmpty);
      expect(c.otherGuard, [ok, other]);
    });

    test('a year without a wallet check-in stops guard pulses', () {
      final old = vault(ownerLastSeen: 0);
      final late = VaultState.guardWindowSecs + 1;
      expect(PlanCoverage.of([old], me, late).needsWallet, [old]);
      expect(needsWalletCheckIn(old, late - 86400), isTrue);
      expect(needsWalletCheckIn(old, 1000), isFalse);
    });

    test('report counts exactly the plans pulsed and names the rest', () {
      final c = PlanCoverage.of([ok, other, stale, done], me, now);
      expect(
        c.reportText(pulsed: true),
        'Pulse recorded on Kids. '
        '1 plan needs a wallet check-in (Savings): tap Confirm with wallet. '
        '1 plan is guarded by another device (Old): Move guard to this phone.',
      );
      final two = PlanCoverage.of([ok, vault(planId: 4)], me, now);
      expect(two.reportText(pulsed: true), 'Pulse recorded on 2 plans.');
      expect(two.complete, isTrue);
      expect(
        PlanCoverage.of([other], me, now).reportText(pulsed: false),
        startsWith(
          'Nothing was checked in. 1 plan is guarded by another device',
        ),
      );
    });
  });

  test('LockReport names plans left unlocked', () {
    final r = LockReport(
      locked: [vault(label: 'Kids')],
      uncovered: [
        vault(planId: 1),
        vault(planId: 2, label: 'Old'),
      ],
    );
    expect(r.complete, isFalse);
    expect(r.text, contains('Locked Kids.'));
    expect(
      r.text,
      contains('NOT locked, guarded by another device: Plan 2, Old'),
    );
  });

  test('grace choices: 30 days default, 2 minutes only for Demo', () {
    expect(graceChoices(demo: false).map((c) => c.$1), [
      86400,
      7 * 86400,
      30 * 86400,
      90 * 86400,
    ]);
    expect(graceChoices(demo: true).first, (120, '2 minutes'));
    expect(clampGrace(1), 60);
    expect(clampGrace(400 * 86400), 366 * 86400);
  });

  group('funds a tier can pay from', () {
    final usdc = addr(60);

    test('payoutGross mirrors the program: reserved shares come first', () {
      final v = vault(
        rules: [
          rule(seed: 11, skippedAt: 900, reserved: 300),
          rule(seed: 12, mode: AmountMode.fixed, amount: 500),
          rule(seed: 13, amount: 5000),
        ],
      );
      expect(v.reservedFor(null), 300);
      expect(v.reservedFor(null, except: 0), 0);
      expect(v.payoutGross(0, 1000), 300);
      expect(v.payoutGross(0, 100), 100);
      expect(v.payoutGross(1, 1000), 500);
      expect(v.payoutGross(1, 600), 300);
      expect(v.payoutGross(2, 1000), 350);
      expect(v.payoutGross(2, 300), 0);
    });

    test('SOL tiers: withdrawable minus what is reserved for others', () {
      final reservedOnly = vault(
        withdrawableLamports: 300,
        rules: [rule(seed: 11, skippedAt: 900, reserved: 300), rule(seed: 12)],
      );
      expect(tierFunded(reservedOnly, 0, null), isTrue);
      expect(tierFunded(reservedOnly, 1, null), isFalse);
      expect(unfundedAssets(reservedOnly, null), [null]);
      expect(tierFunded(vault(withdrawableLamports: 1), 0, null), isTrue);
    });

    test('token tiers: the vault balance of the tier mint; unknown = null', () {
      final v = vault(
        withdrawableLamports: 1000,
        rules: [
          rule(seed: 11),
          rule(seed: 12, mint: usdc),
        ],
      );
      expect(tierFunded(v, 1, null), isNull);
      expect(tierFunded(v, 1, const {}), isNull);
      expect(tierFunded(v, 1, {usdc: 0}), isFalse);
      expect(tierFunded(v, 1, {usdc: 5}), isTrue);
      expect(unfundedAssets(v, {usdc: 0}), [usdc]);
      expect(unfundedAssets(v, {usdc: 5}), isEmpty);
      expect(unfundedAssets(v, null), isEmpty);
    });

    test('paid tiers never count as unfunded', () {
      final v = vault(rules: [rule(seed: 11, mint: usdc, executedAt: 900)]);
      expect(unfundedAssets(v, {usdc: 0}), isEmpty);
    });

    test('vesting: any balance of the schedule asset', () {
      final v = vestingVault(schedules: [schedule(mint: usdc)]);
      expect(tierFunded(v, 0, {usdc: 0}), isFalse);
      expect(tierFunded(v, 0, {usdc: 1}), isTrue);
    });
  });
}
