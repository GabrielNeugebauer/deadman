import 'dart:io';

import 'package:deadman/core/config.dart';
import 'package:deadman/solana/codec.dart';
import 'package:deadman/solana/deadman_api.dart';
import 'package:deadman/solana/deadman_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:solana/solana.dart' show Ed25519HDKeyPair;

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

  group('vesting', () {
    test('waits with nothing new vested', () {
      expect(
        vestingReleaseDue(
          claimable: 0,
          fullyVested: true,
          now: 100,
          interval: 86400,
        ),
        isFalse,
      );
    });

    test('releases once per interval, always once fully vested', () {
      bool due(int now, {bool full = false, int? last}) => vestingReleaseDue(
        claimable: 5,
        fullyVested: full,
        now: now,
        interval: 86400,
        lastRelease: last,
      );
      expect(due(1000), isTrue, reason: 'never released this run');
      expect(due(1000 + 3600, last: 1000), isFalse);
      expect(due(1000 + 86400, last: 1000), isTrue);
      expect(due(1000 + 60, full: true, last: 1000), isTrue);
    });

    test('installment plans release each unlock right away', () {
      bool due(int claimable, {int? last}) => vestingReleaseDue(
        claimable: claimable,
        fullyVested: false,
        now: 1000 + 60,
        interval: 86400,
        lastRelease: last,
        installments: true,
      );
      expect(due(5, last: 1000), isTrue, reason: 'no --vest-interval wait');
      expect(due(5), isTrue);
      expect(due(0, last: 1000), isFalse, reason: 'between installments');
    });

    test('an underfunded vault releases what it holds', () {
      final tier = vestingAsTier(rule(), 4000000);
      final d = decideSol(tier, sol(available: 3000000), canSkip: false);
      expect(d.action, KeeperAction.execute);
      expect(d.reason, contains('pays 2940000'));
    });

    test('never skips a vesting release', () {
      final tier = vestingAsTier(rule(), 1000);
      expect(
        decideSol(tier, sol(), canSkip: false).action,
        KeeperAction.wait,
        reason: 'payout leaves a fresh beneficiary below rent exemption',
      );
    });

    test('token releases follow the ATA rent rule', () {
      final tier = vestingAsTier(rule(mint: mint), 500000000);
      final missing = token(
        vaultBalance: 500000000,
        beneficiaryAta: AtaStatus.missing,
      );
      expect(
        decideToken(tier, treasury, missing, canSkip: false).action,
        KeeperAction.wait,
        reason: 'unknown price',
      );
      final priced = token(
        vaultBalance: 500000000,
        beneficiaryAta: AtaStatus.missing,
        lamportsPerUnit: defaultUsdcLamportsPerUnit,
      );
      final d = decideToken(tier, treasury, priced, canSkip: false);
      expect(d.action, KeeperAction.execute);
      expect(d.createAtasFor, [heir]);
    });

    test('USDC default price is 0.006 SOL per USDC', () {
      expect(defaultUsdcLamportsPerUnit * 1000000, 6000000);
    });
  });

  group('subscription waiver', () {
    const fees = FeeSchedule(
      treasury: '7ZQi6r2ZbKGCDFqKpvVjwMBVHzH2bqoqXuRnDKxDtjXY',
      feeBpsPublic: 200,
      feeBpsPrivate: 300,
    );
    const now = 1790500000;
    const lastPulse = 1790000000;
    late FakeRpc rpc;
    late Keeper keeper;

    setUp(() async {
      rpc = await FakeRpc.start();
      final sol = rpc.client();
      keeper = Keeper(
        sol,
        DeadmanClient.withKora(client: sol),
        await Ed25519HDKeyPair.random(),
        prices: {mint: 1000000},
      );
      rpc.accounts
        ..[mint] = FakeAccount(tokenProgramId, mintBytes(6))
        ..[heir] = const FakeAccount(systemProgramId, [], lamports: 5000000)
        ..[fees.treasury] = const FakeAccount(
          systemProgramId,
          [],
          lamports: 5000000,
        );
    });

    tearDown(() => rpc.close());

    final owner = key(30);
    AccountSubscription paid(int until) =>
        AccountSubscription(owner: owner, paidUntil: until);

    VaultState plan({String? ruleMint, int planId = 0}) {
      return decodeVault(
        vaultBytes(
          owner: owner,
          planId: planId,
          guard: key(31),
          lastPulse: lastPulse,
          rules: [
            RuleState(
              beneficiary: heir,
              rail: Rail.solana,
              afterSecs: 90000,
              mode: AmountMode.fixed,
              amount: 1000000,
              mint: ruleMint,
              executedAt: 0,
              paid: 0,
            ),
          ],
        ),
        address: vaultPda(owner, planId).address,
        lamports: 1000000000,
        rentExemptMinimum: 2000000,
      );
    }

    void holdTokens(VaultState v, {bool heirAta = true}) {
      rpc.accounts[ataAddress(v.address, mint)] = FakeAccount(
        tokenProgramId,
        [...tokenAccountBytes(mint: mint, owner: v.address, amount: 5000000)]
          ..[108] = 1,
      );
      rpc.accounts[ataAddress(fees.treasury, mint)] = FakeAccount(
        tokenProgramId,
        tokenAccountBytes(mint: mint, owner: fees.treasury, amount: 0)
          ..[108] = 1,
      );
      if (heirAta) {
        rpc.accounts[ataAddress(heir, mint)] = FakeAccount(
          tokenProgramId,
          tokenAccountBytes(mint: mint, owner: heir, amount: 0)..[108] = 1,
        );
      }
    }

    test("every plan of a subscribed owner executes fee-free", () async {
      for (final id in [0, 9]) {
        final d = await keeper.decide(
          plan(planId: id),
          0,
          fees,
          now,
          sub: paid(lastPulse),
        );
        expect(d.action, KeeperAction.execute);
        expect(d.reason, 'pays 1000000 lamports, fee 0');
      }
    });

    test('no subscription, a lapsed one or another owner\'s pays the '
        'fee', () async {
      for (final sub in [
        null,
        paid(lastPulse - 1),
        AccountSubscription(owner: key(32), paidUntil: now + 86400),
      ]) {
        final d = await keeper.decide(plan(), 0, fees, now, sub: sub);
        expect(d.reason, 'pays 980000 lamports, fee 20000');
      }
    });

    test('a covered token tier executes when its ATAs exist', () async {
      final v = plan(ruleMint: mint);
      holdTokens(v);
      final d = await keeper.decide(v, 0, fees, now, sub: paid(now + 86400));
      expect(d.action, KeeperAction.execute);
      expect(d.reason, 'pays 1000000, fee 0');
      expect(d.createAtasFor, isEmpty);
    });

    test('a covered token tier never pays ATA rent', () async {
      final v = plan(ruleMint: mint);
      holdTokens(v, heirAta: false);
      final d = await keeper.decide(v, 0, fees, now, sub: paid(now));
      expect(d.action, KeeperAction.wait, reason: d.reason);
      expect(d.createAtasFor, isEmpty);

      // The same tier without the waiver: its fee is worth the rent.
      final charged = await keeper.decide(v, 0, fees, now);
      expect(charged.action, KeeperAction.execute);
      expect(charged.createAtasFor, [heir]);
    });
  });

  group('sweep', () {
    test("reads every owner's subscription once, in one batch, and charges "
        'no fee on any plan of a subscribed owner', () async {
      final rpc = await FakeRpc.start();
      addTearDown(rpc.close);
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final lastPulse = now - 100 * 86400;
      final subscribed = key(40);
      final other = key(41);
      rpc.accounts
        ..[configPda().address] = FakeAccount(
          AppConfig.programId,
          configBytes(admin: key(42), treasury: treasury),
        )
        ..[treasury] = const FakeAccount(systemProgramId, [], lamports: 5000000)
        ..[heir] = const FakeAccount(systemProgramId, [], lamports: 5000000)
        ..[subPda(subscribed).address] = FakeAccount(
          AppConfig.programId,
          subscriptionBytes(owner: subscribed, paidUntil: lastPulse),
        );
      for (final (owner, planId) in [
        (subscribed, 0),
        (subscribed, 1),
        (other, 0),
      ]) {
        rpc.accounts[vaultPda(owner, planId).address] = FakeAccount(
          AppConfig.programId,
          vaultBytes(
            owner: owner,
            planId: planId,
            guard: key(43),
            lastPulse: lastPulse,
            lockedUntil: 0,
            guardianReadyAt: 0,
            rules: [
              RuleState(
                beneficiary: heir,
                rail: Rail.solana,
                afterSecs: 90000,
                mode: AmountMode.fixed,
                amount: 1000000,
                executedAt: 0,
                paid: 0,
              ),
            ],
          ),
          lamports: 1000000000,
        );
      }
      final sol = rpc.client();
      final keeper = Keeper(
        sol,
        DeadmanClient.withKora(client: sol),
        await Ed25519HDKeyPair.random(),
        dryRun: true,
      );
      final out = _Out();
      await IOOverrides.runZoned(keeper.sweep, stdout: () => out);

      final subReads = [
        for (final keys in rpc.multiReads)
          if (keys.contains(subPda(subscribed).address)) keys,
      ];
      expect(subReads, [
        unorderedEquals([subPda(subscribed).address, subPda(other).address]),
      ]);
      String line(String owner, int planId) => out.lines.singleWhere(
        (l) => l.contains(vaultPda(owner, planId).address),
      );
      expect(line(subscribed, 0), endsWith('pays 1000000 lamports, fee 0'));
      expect(line(subscribed, 1), endsWith('pays 1000000 lamports, fee 0'));
      expect(line(other, 0), endsWith('pays 980000 lamports, fee 20000'));
      expect(rpc.sent, isEmpty);
    });
  });
}

/// Captures what the keeper prints.
class _Out implements Stdout {
  final lines = <String>[];

  @override
  void writeln([Object? object = '']) => lines.add('$object');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
