import 'package:deadman/core/config.dart';
import 'package:deadman/solana/deadman_api.dart';
import 'package:deadman/state/providers.dart';
import 'package:deadman/state/subscription.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

const usdc = AppConfig.usdcMint;
const month = 30 * 86400;

final fees = FeeSchedule(
  treasury: addr(9),
  feeBpsPublic: 200,
  feeBpsPrivate: 500,
);

const terms = SubscriptionTerms(
  pricePerPeriod: 10000000,
  periodSecs: month,
  mint: usdc,
  minPeriods: 12,
);

/// Records each owner whose subscription is read.
class _CountingApi extends FakeApi {
  _CountingApi() : super(const []);

  final reads = <String>[];

  @override
  Future<AccountSubscription?> fetchSubscription(String owner) async {
    reads.add(owner);
    return owner == addr(1)
        ? AccountSubscription(owner: owner, paidUntil: 5)
        : null;
  }
}

void main() {
  const now = 1000000;

  group('fetchSubscriptionsOf', () {
    test('reads each owner once', () async {
      final api = _CountingApi();
      final got = await fetchSubscriptionsOf(api, [addr(1), addr(7), addr(1)]);
      expect(api.reads, [addr(1), addr(7)]);
      expect(got.keys, [addr(1), addr(7)]);
      expect(got[addr(1)]!.paidUntil, 5);
      expect(got[addr(7)], isNull);
    });

    test('no owners, no reads', () async {
      final api = _CountingApi();
      expect(await fetchSubscriptionsOf(api, const []), isEmpty);
      expect(api.reads, isEmpty);
    });
  });

  AccountSubscription sub(int paidUntil) =>
      AccountSubscription(owner: addr(1), paidUntil: paidUntil);

  group('subscriptionStatus', () {
    test('never subscribed', () {
      expect(subscriptionStatus(null, now), SubscriptionStatus.none);
      expect(subscriptionStatus(sub(0), now), SubscriptionStatus.none);
    });

    test('paid through now is active', () {
      expect(subscriptionStatus(sub(now), now), SubscriptionStatus.active);
    });

    test('ended is lapsed', () {
      expect(subscriptionStatus(sub(now - 1), now), SubscriptionStatus.lapsed);
    });
  });

  group('subscriptionChoices', () {
    test('new: the 12-period minimum and its multiples', () {
      expect(subscriptionChoices(terms, null, now), [12, 24, 36]);
    });

    test('lapsed: the minimum again', () {
      expect(subscriptionChoices(terms, sub(now - 1), now), [12, 24, 36]);
    });

    test('active: short extensions', () {
      expect(subscriptionChoices(terms, sub(now), now), [1, 3, 6, 12]);
    });

    test('a minimum above 12 drops multiples past 36', () {
      const long = SubscriptionTerms(
        pricePerPeriod: 1,
        periodSecs: month,
        mint: usdc,
        minPeriods: 20,
      );
      expect(subscriptionChoices(long, null, now), [20]);
    });

    test('a minimum of 1 offers short terms from the start', () {
      const short = SubscriptionTerms(
        pricePerPeriod: 1,
        periodSecs: month,
        mint: usdc,
        minPeriods: 1,
      );
      expect(subscriptionChoices(short, null, now), [1, 3, 6, 12]);
    });
  });

  group('releaseFeeEstimate', () {
    test('one 100% tier pays 2% of the balance', () {
      final v = vault(rules: [rule(mint: usdc)]);
      expect(releaseFeeEstimate(v, fees, usdc, 250000000), 5000000);
    });

    test('compounding percent tiers on mixed rails', () {
      // 50% via Solana (2%), then 100% of the rest via Cloak (5%).
      final v = vault(
        rules: [
          rule(seed: 11, mint: usdc, amount: 5000, afterSecs: 10),
          rule(seed: 12, mint: usdc, afterSecs: 20, rail: Rail.cloak),
        ],
      );
      expect(releaseFeeEstimate(v, fees, usdc, 1000), 10 + 25);
    });

    test('fixed tiers are capped by the balance; paid tiers are skipped', () {
      final v = vault(
        rules: [
          rule(seed: 11, mode: AmountMode.fixed, amount: 700, executedAt: 5),
          rule(seed: 12, mode: AmountMode.fixed, amount: 700, afterSecs: 20),
          rule(seed: 13, mode: AmountMode.fixed, amount: 700, afterSecs: 30),
        ],
      );
      // 700 then the remaining 300, at 2%.
      expect(releaseFeeEstimate(v, fees, null, 1000), 14 + 6);
    });

    test('other assets do not count', () {
      final v = vault(rules: [rule(mint: usdc)]);
      expect(releaseFeeEstimate(v, fees, null, 5000000000), 0);
    });

    test('vesting: what is still owed, capped by the balance', () {
      final v = vestingVault(
        schedules: [
          schedule(mint: usdc, total: 1000, released: 400),
          schedule(seed: 21, mint: usdc, total: 1000),
        ],
      );
      expect(releaseFeeEstimate(v, fees, usdc, 5000), 12 + 20);
      expect(releaseFeeEstimate(v, fees, usdc, 600), 12);
    });
  });

  group('plansReleaseFeeEstimate', () {
    test('sums every plan holding the token; SOL from the plans', () {
      final a = vault(rules: [rule(mint: usdc)], withdrawableLamports: 1000);
      final b = vault(
        planId: 1,
        rules: [rule(mint: usdc, rail: Rail.cloak)],
      );
      final c = vestingVault(
        planId: 2,
        schedules: [schedule(total: 500)],
        withdrawableLamports: 5000,
      );
      final held = {a.address: 1000, b.address: 1000};
      expect(plansReleaseFeeEstimate([a, b, c], fees, usdc, held), 20 + 50);
      // a's SOL has no SOL tier; c owes 500 of its 5000 lamports.
      expect(plansReleaseFeeEstimate([a, b, c], fees, null), 10);
      expect(plansReleaseFeeEstimate(const [], fees, usdc), 0);
    });

    test('rates across plans', () {
      expect(
        plansPendingFeeRates([
          vault(),
          vault(planId: 1, rules: [rule(rail: Rail.zcash)]),
        ], fees),
        '2% / 5%',
      );
    });
  });

  group('planFeeText', () {
    test('the fee, or 0% while the account subscription covers the plan', () {
      final v = vault(lastPulse: now - 100);
      expect(
        planFeeText(v, null, fees, now),
        'Release fee: 2% (5% private rails)',
      );
      expect(
        planFeeText(v, sub(now + 1), fees, now),
        '0% release fee · monthly plan',
      );
      // Ended after the last check-in: still covered.
      expect(
        planFeeText(v, sub(now - 50), fees, now),
        '0% release fee · monthly plan',
      );
      // Ended before it.
      expect(
        planFeeText(v, sub(now - 150), fees, now),
        'Release fee: 2% (5% private rails)',
      );
      expect(planFeeText(v, null, null, now), 'Release fee on payouts');
    });

    test('vesting: covered only while paid', () {
      final v = vestingVault();
      expect(
        planFeeText(v, sub(now), fees, now),
        '0% release fee · monthly plan',
      );
      expect(
        planFeeText(v, sub(now - 1), fees, now),
        'Release fee: 2% (5% private rails)',
      );
    });

    test("another owner's subscription does not count", () {
      final other = AccountSubscription(owner: addr(7), paidUntil: now + 1);
      expect(
        planFeeText(vault(), other, fees, now),
        'Release fee: 2% (5% private rails)',
      );
    });
  });

  group('labels', () {
    test('release fee row', () {
      expect(releaseFeeText(fees), 'Release fee: 2% (5% private rails)');
    });

    test('pending rates', () {
      expect(pendingFeeRates(vault(), fees), '2%');
      expect(
        pendingFeeRates(
          vault(
            rules: [
              rule(seed: 11),
              rule(seed: 12, rail: Rail.zcash),
            ],
          ),
          fees,
        ),
        '2% / 5%',
      );
      expect(
        pendingFeeRates(
          vault(
            rules: [
              rule(seed: 11, rail: Rail.cloak),
              rule(seed: 12, executedAt: 5),
            ],
          ),
          fees,
        ),
        '5%',
      );
    });

    test('period words', () {
      expect(periodWord(terms, 1), 'month');
      expect(periodWord(terms, 12), 'months');
      const weekly = SubscriptionTerms(
        pricePerPeriod: 1,
        periodSecs: 7 * 86400,
        mint: usdc,
        minPeriods: 4,
      );
      expect(periodWord(weekly, 4), 'periods');
    });
  });
}
