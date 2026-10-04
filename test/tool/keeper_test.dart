import 'package:deadman/solana/deadman_api.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../tool/keeper.dart';
import '../solana/helpers.dart';
import '../state/fakes.dart' as f;

final heir = key(4);
final treasury = key(5);
const mint = 'Mint111111111111111111111111111111111111111';

RuleSpec rule({
  AmountMode mode = AmountMode.fixed,
  int amount = 1000000,
  String? mint,
}) => RuleSpec(
  beneficiary: heir,
  rail: Rail.solana,
  afterSecs: 90000,
  mode: mode,
  amount: amount,
  mint: mint,
);

RuleState skippedRule({int reserved = 2000000, String? mint}) => RuleState(
  beneficiary: heir,
  rail: Rail.solana,
  afterSecs: 90000,
  mode: AmountMode.percent,
  amount: 10000,
  mint: mint,
  executedAt: 0,
  paid: 0,
  skippedAt: 1000,
  reserved: reserved,
);

SolFacts sol({
  int available = 5000000,
  int beneficiaryLamports = 0,
  int treasuryLamports = 1000000000,
  int otherReserved = 0,
}) => SolFacts(
  otherReserved: otherReserved,
  available: available,
  feeBps: 200,
  beneficiaryLamports: beneficiaryLamports,
  beneficiaryRentMin: 890880,
  treasuryLamports: treasuryLamports,
  treasuryRentMin: 890880,
);

TokenFacts token({
  int vaultBalance = 1000000,
  AtaStatus beneficiaryAta = AtaStatus.usable,
  AtaStatus treasuryAta = AtaStatus.usable,
  double? lamportsPerUnit,
  bool classicMint = true,
  int otherReserved = 0,
}) => TokenFacts(
  otherReserved: otherReserved,
  classicMint: classicMint,
  vaultBalance: vaultBalance,
  feeBps: 200,
  beneficiaryAta: beneficiaryAta,
  treasuryAta: treasuryAta,
  ataRent: 2039280,
  lamportsPerUnit: lamportsPerUnit,
);

void main() {
  test('ruleGross and splitFee mirror the program', () {
    expect(ruleGross(rule(amount: 10), 5), 5);
    expect(ruleGross(rule(mode: AmountMode.percent, amount: 2500), 1000), 250);
    expect(splitFee(10000, 200), (9800, 200));
    expect(splitFee(49, 200), (49, 0));
  });

  group('reserved shares (skip reserves the share)', () {
    test('tierGross mirrors payout_gross', () {
      // A skipped tier gets its reserved share, capped at the balance.
      expect(tierGross(skippedRule(reserved: 300), 1000), 300);
      expect(tierGross(skippedRule(reserved: 3000), 1000), 1000);
      // Nothing reserved: recompute on the balance minus other reservations.
      expect(
        tierGross(skippedRule(reserved: 0), 1000, otherReserved: 400),
        600,
      );
      // Any other tier works on the balance minus every reserved share.
      final half = rule(mode: AmountMode.percent, amount: 5000);
      expect(tierGross(half, 1000, otherReserved: 400), 300);
      expect(tierGross(half, 1000, otherReserved: 4000), 0);
    });

    test('reservedFor sums other skipped, unpaid tiers of the same asset', () {
      final v = f.vault(
        rules: [
          f.rule(seed: 11, skippedAt: 5, reserved: 100),
          f.rule(seed: 12, skippedAt: 5, reserved: 20, executedAt: 9),
          f.rule(seed: 13, skippedAt: 5, reserved: 7, mint: mint),
          f.rule(seed: 14, skippedAt: 6, reserved: 3),
          f.rule(seed: 15),
        ],
      );
      expect(reservedFor(v, 4), 103);
      expect(reservedFor(v, 0), 3, reason: 'excludes itself');
      expect(reservedFor(v, 2), 0, reason: 'other asset');
    });

    test(
      'a skipped SOL tier is executed when payable, never skipped again',
      () {
        expect(
          decideSol(skippedRule(), sol(), canSkip: false).action,
          KeeperAction.execute,
        );
        // Unpayable: canSkip is false for a skipped tier, so it waits.
        expect(
          decideSol(skippedRule(), sol(available: 0), canSkip: false).action,
          KeeperAction.wait,
        );
      },
    );

    test('later tiers only see the balance minus reserved shares', () {
      final all = rule(mode: AmountMode.percent, amount: 10000);
      expect(
        decideSol(all, sol(otherReserved: 5000000), canSkip: false).action,
        KeeperAction.wait,
        reason: 'everything left is reserved',
      );
      expect(
        decideToken(
          rule(mint: mint),
          treasury,
          token(otherReserved: 1000000),
          canSkip: false,
        ).action,
        KeeperAction.wait,
      );
    });

    test('a skipped token tier follows the same ATA rent policy', () {
      final r = skippedRule(reserved: 500000, mint: mint);
      expect(
        decideToken(r, treasury, token(), canSkip: false).action,
        KeeperAction.execute,
      );
      expect(
        decideToken(
          r,
          treasury,
          token(beneficiaryAta: AtaStatus.missing),
          canSkip: false,
        ).action,
        KeeperAction.wait,
      );
    });
  });

  group('SOL rules', () {
    test('executes a payout the beneficiary can receive', () {
      final d = decideSol(rule(), sol(), canSkip: false);
      expect(d.action, KeeperAction.execute);
      expect(d.createAtasFor, isEmpty);
    });

    test('never executes a zero payout; skips it after the grace', () {
      expect(
        decideSol(rule(), sol(available: 0), canSkip: false).action,
        KeeperAction.wait,
      );
      expect(
        decideSol(rule(), sol(available: 0), canSkip: true).action,
        KeeperAction.skip,
      );
    });

    test('waits on dust below the beneficiary rent minimum', () {
      final dust = rule(amount: 100000);
      expect(decideSol(dust, sol(), canSkip: false).action, KeeperAction.wait);
      expect(decideSol(dust, sol(), canSkip: true).action, KeeperAction.skip);
      // An existing funded account can take dust.
      expect(
        decideSol(
          dust,
          sol(beneficiaryLamports: 1000000),
          canSkip: false,
        ).action,
        KeeperAction.execute,
      );
    });

    test('counts the fee waiver when the treasury is below rent', () {
      // Net 882706 is short of 890880; with the fee waived it is 900720.
      final r = rule(amount: 900720);
      expect(decideSol(r, sol(), canSkip: false).action, KeeperAction.wait);
      expect(
        decideSol(r, sol(treasuryLamports: 0), canSkip: false).action,
        KeeperAction.execute,
      );
    });
  });

  group('token rules', () {
    final r = rule(mint: mint);

    test('executes without creating ATAs when both exist', () {
      final d = decideToken(r, treasury, token(), canSkip: false);
      expect(d.action, KeeperAction.execute);
      expect(d.createAtasFor, isEmpty);
    });

    test('does not pay ATA rent the fee does not cover (M-3)', () {
      for (final f in [
        token(beneficiaryAta: AtaStatus.missing),
        token(treasuryAta: AtaStatus.missing),
        // Fee of 20 000 units at 100 lamports each = 2M < 2 039 280 rent.
        token(beneficiaryAta: AtaStatus.missing, lamportsPerUnit: 100),
      ]) {
        final d = decideToken(r, treasury, f, canSkip: true);
        expect(d.action, KeeperAction.wait, reason: d.reason);
      }
    });

    test('creates ATAs when the fee is worth the rent', () {
      final d = decideToken(
        r,
        treasury,
        token(
          beneficiaryAta: AtaStatus.missing,
          treasuryAta: AtaStatus.missing,
          lamportsPerUnit: 250,
        ),
        canSkip: false,
      );
      expect(d.action, KeeperAction.execute);
      expect(d.createAtasFor, [heir, treasury]);
    });

    test('never executes an empty vault; skips it after the grace', () {
      final empty = token(vaultBalance: 0);
      expect(
        decideToken(r, treasury, empty, canSkip: false).action,
        KeeperAction.wait,
      );
      expect(
        decideToken(r, treasury, empty, canSkip: true).action,
        KeeperAction.skip,
      );
    });

    test('skips a frozen or reassigned beneficiary ATA only after grace', () {
      final broken = token(beneficiaryAta: AtaStatus.unusable);
      expect(
        decideToken(r, treasury, broken, canSkip: false).action,
        KeeperAction.wait,
      );
      expect(
        decideToken(r, treasury, broken, canSkip: true).action,
        KeeperAction.skip,
      );
    });

    test('never skips for protocol-side or unsupported-mint reasons', () {
      for (final f in [
        token(treasuryAta: AtaStatus.unusable),
        token(classicMint: false, vaultBalance: 0),
      ]) {
        expect(
          decideToken(r, treasury, f, canSkip: true).action,
          KeeperAction.wait,
        );
      }
    });
  });
}
