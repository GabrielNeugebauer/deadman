import 'package:deadman/core/config.dart';
import 'package:deadman/solana/deadman_api.dart';
import 'package:deadman/state/protocol_fees.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

const usdc = AppConfig.usdcMint;
const skr = AppConfig.skrMint;

final fees = FeeSchedule(
  treasury: addr(9),
  feeBpsPublic: 200,
  feeBpsPrivate: 300,
  skrMint: skr,
  feeBpsSkr: 150,
  skrBurnBps: 1000,
);

/// The program's defaults: 2% on every rail, 1.5% for SKR, 10% burned.
final defaults = FeeSchedule(
  treasury: addr(9),
  feeBpsPublic: 200,
  feeBpsPrivate: 200,
  skrMint: skr,
  feeBpsSkr: 150,
  skrBurnBps: 1000,
);

void main() {
  group('FeeSchedule', () {
    test('SKR pays its own rate on every rail; other mints the rail rate', () {
      for (final rail in Rail.values) {
        expect(fees.bpsFor(rail, skr), 150);
      }
      expect(fees.bpsFor(Rail.solana), 200);
      expect(fees.bpsFor(Rail.solana, usdc), 200);
      expect(fees.bpsFor(Rail.cloak, usdc), 300);
      expect(fees.bpsFor(Rail.zcash), 300);
    });

    test('no SKR mint configured: SKR pays the rail rate', () {
      final plain = FeeSchedule(
        treasury: addr(9),
        feeBpsPublic: 200,
        feeBpsPrivate: 300,
        feeBpsSkr: 150,
        skrBurnBps: 1000,
      );
      expect(plain.isSkr(skr), isFalse);
      expect(plain.bpsFor(Rail.solana, skr), 200);
      expect(plain.burnedOf(1000, skr), 0);
    });

    test('fee and burn split round down as on chain', () {
      // 1.5% of 1,000,000 = 15,000; 10% burned, 90% to the treasury.
      final fee = fees.feeOf(1000000, Rail.cloak, skr);
      expect(fee, 15000);
      expect(fees.burnedOf(fee, skr), 1500);
      expect(fees.toTreasuryOf(fee, skr), 13500);
      // Nothing is burned from other mints.
      expect(fees.burnedOf(20000, usdc), 0);
      expect(fees.toTreasuryOf(20000, usdc), 20000);
      // A single NFT pays no fee at all.
      expect(fees.feeOf(1, Rail.solana, addr(50)), 0);
      expect(fees.feeOf(66, Rail.solana, skr), 0);
      expect(fees.feeOf(67, Rail.solana, skr), 1);
      expect(fees.burnedOf(9, skr), 0);
    });
  });

  group('fee summary', () {
    test('from the on-chain schedule', () {
      expect(
        feeSummaryText(defaults),
        '2% on release · 1.5% for SKR (10% burned) · withdrawals free',
      );
      expect(
        feeSummaryText(fees),
        '2% (3% private rails) on release · 1.5% for SKR (10% burned) · '
        'withdrawals free',
      );
    });

    test('before the schedule is read: the defaults', () {
      expect(feeSummaryText(null), feeSummaryStaticText);
      expect(feeSummaryStaticText, feeSummaryText(defaults));
    });

    test('no burn, or no SKR rate at all', () {
      final noBurn = FeeSchedule(
        treasury: addr(9),
        feeBpsPublic: 200,
        feeBpsPrivate: 200,
        skrMint: skr,
        feeBpsSkr: 150,
      );
      expect(
        feeSummaryText(noBurn),
        '2% on release · 1.5% for SKR · withdrawals free',
      );
      final noSkr = FeeSchedule(
        treasury: addr(9),
        feeBpsPublic: 200,
        feeBpsPrivate: 200,
      );
      expect(feeSummaryText(noSkr), '2% on release · withdrawals free');
      expect(skrFeeText(noSkr), isNull);
    });

    test('review terms', () {
      expect(
        releaseFeeTerms(defaults, 'payout'),
        '2% of each payout, 1.5% for SKR (10% of it burned), taken when it '
        'runs.',
      );
      expect(
        releaseFeeTerms(fees, 'release'),
        '2% of each normal release, 3% of each private one, 1.5% for SKR '
        '(10% of it burned), taken when it runs.',
      );
    });
  });

  group('releaseFeeEstimate', () {
    test('one 100% tier pays 2% of the balance', () {
      final v = vault(rules: [rule(mint: usdc)]);
      expect(releaseFeeEstimate(v, fees, usdc, 250000000), 5000000);
    });

    test('compounding percent tiers on mixed rails', () {
      // 50% via Solana (2%), then 100% of the rest via Cloak (3%).
      final v = vault(
        rules: [
          rule(seed: 11, mint: usdc, amount: 5000, afterSecs: 10),
          rule(seed: 12, mint: usdc, afterSecs: 20, rail: Rail.cloak),
        ],
      );
      expect(releaseFeeEstimate(v, fees, usdc, 1000), 10 + 15);
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

    test('SKR tiers pay the SKR rate on any rail', () {
      final v = vault(
        rules: [
          rule(seed: 11, mint: skr, amount: 5000, afterSecs: 10),
          rule(seed: 12, mint: skr, afterSecs: 20, rail: Rail.zcash),
        ],
      );
      // 1.5% of 500 and of the remaining 500.
      expect(releaseFeeEstimate(v, fees, skr, 1000), 7 + 7);
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
      expect(plansReleaseFeeEstimate([a, b, c], fees, usdc, held), 20 + 30);
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
        '2% / 3%',
      );
    });
  });

  group('planFeeText', () {
    test("the rates of the plan's pending payouts", () {
      expect(planFeeText(vault(), fees), 'Release fee: 2%');
      expect(
        planFeeText(
          vault(
            rules: [
              rule(seed: 11),
              rule(seed: 12, rail: Rail.cloak),
            ],
          ),
          fees,
        ),
        'Release fee: 2% / 3%',
      );
      expect(planFeeText(vault(), null), 'Release fee on payouts');
    });

    test('SKR payouts show the burn', () {
      expect(
        planFeeText(vault(rules: [rule(mint: skr)]), fees),
        'Release fee: 1.5% · SKR fees 10% burned',
      );
      final vested = vestingVault(schedules: [schedule(mint: skr)]);
      expect(
        planFeeText(vested, fees),
        'Release fee: 1.5% · SKR fees 10% burned',
      );
    });
  });

  group('labels', () {
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
        '2% / 3%',
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
        '3%',
      );
    });
  });
}
