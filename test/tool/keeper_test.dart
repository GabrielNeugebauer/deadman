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
  int feeBps = 200,
  int burnBps = 0,
  int networkFee = lamportsPerSignature,
}) => TokenFacts(
  otherReserved: otherReserved,
  classicMint: classicMint,
  vaultBalance: vaultBalance,
  feeBps: feeBps,
  beneficiaryAta: beneficiaryAta,
  treasuryAta: treasuryAta,
  ataRent: 2039280,
  lamportsPerUnit: lamportsPerUnit,
  burnBps: burnBps,
  networkFee: networkFee,
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
      // Fee of 10 000 units at 1 lamport each covers the network fee only.
      expect(
        decideToken(
          r,
          treasury,
          token(lamportsPerUnit: 1),
          canSkip: false,
        ).action,
        KeeperAction.execute,
      );
      expect(
        decideToken(
          r,
          treasury,
          token(beneficiaryAta: AtaStatus.missing, lamportsPerUnit: 1),
          canSkip: false,
        ).action,
        KeeperAction.wait,
      );
    });

    test('skips only when a later tier of the same asset is waiting', () {
      VaultState v(List<RuleState> rules) => f.vault(rules: rules);
      final open = v([f.rule(seed: 11), f.rule(seed: 12)]);
      expect(skipUnblocks(open, 0), isTrue);
      expect(skipUnblocks(open, 1), isFalse, reason: 'last tier');
      expect(
        skipUnblocks(v([f.rule(seed: 11), f.rule(seed: 12, mint: mint)]), 0),
        isFalse,
        reason: 'other asset',
      );
      expect(
        skipUnblocks(v([f.rule(seed: 11), f.rule(seed: 12, executedAt: 9)]), 0),
        isFalse,
        reason: 'already paid',
      );
      expect(
        skipUnblocks(v([f.rule(seed: 11), f.rule(seed: 12, skippedAt: 5)]), 0),
        isFalse,
        reason: 'already skipped, claimable anyway',
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
    });

    test('M-4: executes only when the fee covers the network fee', () {
      final funded = sol(beneficiaryLamports: 1000000);
      // 2% of 249 950 is 4999 lamports, short of the 5000 lamport fee.
      final d = decideSol(rule(amount: 249950), funded, canSkip: true);
      expect(d.action, KeeperAction.wait, reason: 'never skipped for it');
      expect(
        d.reason,
        'pays 244951 lamports, fee 4999: fee worth ~4999 lamports does not '
        'cover 5000 lamports of network fee; left for the beneficiary to '
        'claim',
      );
      expect(
        decideSol(rule(amount: 250000), funded, canSkip: false).action,
        KeeperAction.execute,
      );
      // A priority fee raises the bar.
      final busy = SolFacts(
        available: 5000000,
        feeBps: 200,
        beneficiaryLamports: 1000000,
        beneficiaryRentMin: 890880,
        treasuryLamports: 1000000000,
        treasuryRentMin: 890880,
        networkFee: networkFeeLamports(cuPrice: 100000),
      );
      expect(busy.networkFee, 25000);
      expect(
        decideSol(rule(amount: 1000000), busy, canSkip: false).action,
        KeeperAction.wait,
      );
    });

    test('folds the fee into the payout when the treasury is below rent, '
        'which leaves the keeper nothing', () {
      // Net 882706 is short of 890880; with the fee folded in it is 900720.
      final r = rule(amount: 900720);
      final short = decideSol(r, sol(), canSkip: false);
      expect(short.action, KeeperAction.wait);
      expect(short.reason, contains('below rent exemption'));
      final folded = decideSol(r, sol(treasuryLamports: 0), canSkip: false);
      expect(folded.action, KeeperAction.wait);
      expect(folded.reason, startsWith('pays 900720 lamports, fee 0:'));
    });
  });

  group('token rules', () {
    final r = rule(mint: mint);

    test('executes without creating ATAs when both exist', () {
      final d = decideToken(
        r,
        treasury,
        token(lamportsPerUnit: 1),
        canSkip: false,
      );
      expect(d.action, KeeperAction.execute);
      expect(
        d.reason,
        'pays 980000, fee 20000 (~20000 lamports) covers 5000 '
        'lamports',
      );
      expect(d.createAtasFor, isEmpty);
      expect(d.treasuryFee, isTrue);
    });

    test('M-4: a token without a known price is left to the beneficiary, '
        'even with both ATAs', () {
      final d = decideToken(r, treasury, token(), canSkip: true);
      expect(d.action, KeeperAction.wait);
      expect(d.reason, endsWith('left for the beneficiary to claim'));
    });

    test('SKR: only the fee share that is not burned counts', () {
      final skr = token(feeBps: 150, burnBps: 1000, lamportsPerUnit: 0.36);
      // 1.5% of 1 000 000 = 15 000, 1500 burned, 13 500 to the treasury,
      // worth 4860 lamports: short of the network fee.
      final d = decideToken(r, treasury, skr, canSkip: false);
      expect(d.action, KeeperAction.wait);
      expect(
        d.reason,
        startsWith(
          'pays 985000, fee 15000 (1500 burned): fee '
          'worth ~4860 lamports',
        ),
      );
      final worth = decideToken(
        r,
        treasury,
        token(feeBps: 150, burnBps: 1000, lamportsPerUnit: 1),
        canSkip: false,
      );
      expect(worth.action, KeeperAction.execute);
      expect(worth.reason, contains('(~13500 lamports)'));
    });

    test('FUNDS-5: a payout that leaves the treasury nothing needs no '
        'treasury ATA', () {
      final nft = rule(mint: mint, amount: 1);
      final f = token(
        vaultBalance: 1,
        treasuryAta: AtaStatus.missing,
        lamportsPerUnit: 1e9,
      );
      final d = decideToken(nft, treasury, f, canSkip: false);
      expect(d.action, KeeperAction.wait, reason: 'no fee for the keeper');
      expect(d.reason, contains('fee 0'));
      // Were it worth sending, the treasury ATA would be left out.
      final free = decideToken(
        nft,
        treasury,
        token(vaultBalance: 1, treasuryAta: AtaStatus.unusable, networkFee: 0),
        canSkip: false,
      );
      expect(free.action, KeeperAction.execute);
      expect(free.treasuryFee, isFalse);
      expect(free.createAtasFor, isEmpty);
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

    test('installment plans wait --vest-interval too, except the last', () {
      bool due(int claimable, {int? last, bool full = false}) =>
          vestingReleaseDue(
            claimable: claimable,
            fullyVested: full,
            now: 1000 + 60,
            interval: 86400,
            lastRelease: last,
          );
      expect(due(5, last: 1000), isFalse, reason: 'released a minute ago');
      expect(due(5), isTrue);
      expect(due(5, last: 1000, full: true), isTrue);
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

    test('network fee: 5000 per signature plus the priority fee', () {
      expect(networkFeeLamports(), 5000);
      expect(networkFeeLamports(instructions: 3, cuPrice: 1000), 5600);
      expect(networkFeeLamports(cuPrice: 1), 5001, reason: 'rounded up');
    });
  });

  group('Keeper.decide with the Config fees', () {
    const skr = 'Skr1111111111111111111111111111111111111111';
    const fees = FeeSchedule(
      treasury: '7ZQi6r2ZbKGCDFqKpvVjwMBVHzH2bqoqXuRnDKxDtjXY',
      feeBpsPublic: 200,
      feeBpsPrivate: 200,
      skrMint: skr,
      feeBpsSkr: 150,
      skrBurnBps: 1000,
    );
    const now = 1790500000;
    late FakeRpc rpc;
    late Keeper keeper;

    setUp(() async {
      rpc = await FakeRpc.start();
      final sol = rpc.client();
      keeper = Keeper(
        sol,
        DeadmanClient.withKora(client: sol),
        await Ed25519HDKeyPair.random(),
        prices: {mint: 1, skr: 1},
      );
      rpc.accounts
        ..[heir] = const FakeAccount(systemProgramId, [], lamports: 5000000)
        ..[fees.treasury] = const FakeAccount(
          systemProgramId,
          [],
          lamports: 5000000,
        );
      for (final m in [mint, skr]) {
        rpc.accounts[m] = FakeAccount(tokenProgramId, mintBytes(6));
      }
    });

    tearDown(() => rpc.close());

    final owner = key(30);
    VaultState plan({String? ruleMint, int amount = 1000000}) => decodeVault(
      vaultBytes(
        owner: owner,
        guard: key(31),
        rules: [
          RuleState(
            beneficiary: heir,
            rail: Rail.solana,
            afterSecs: 90000,
            mode: AmountMode.fixed,
            amount: amount,
            mint: ruleMint,
            executedAt: 0,
            paid: 0,
          ),
        ],
      ),
      address: vaultPda(owner, 0).address,
      lamports: 1000000000,
      rentExemptMinimum: 2000000,
    );

    void holdTokens(VaultState v, String m, {int amount = 5000000}) {
      for (final (holder, held) in [
        (v.address, amount),
        (fees.treasury, 0),
        (heir, 0),
      ]) {
        rpc.accounts[ataAddress(holder, m)] = FakeAccount(
          tokenProgramId,
          tokenAccountBytes(mint: m, owner: holder, amount: held)..[108] = 1,
        );
      }
    }

    test('a SOL tier pays 2%', () async {
      final d = await keeper.decide(plan(), 0, fees, now);
      expect(d.action, KeeperAction.execute);
      expect(d.reason, 'pays 980000 lamports, fee 20000');
    });

    test('a token tier pays 2%, an SKR tier 1.5% with 10% burned', () async {
      final usdcPlan = plan(ruleMint: mint);
      holdTokens(usdcPlan, mint);
      final d = await keeper.decide(usdcPlan, 0, fees, now);
      expect(d.action, KeeperAction.execute);
      expect(d.reason, startsWith('pays 980000, fee 20000 (~20000 lamports)'));

      final skrPlan = plan(ruleMint: skr);
      holdTokens(skrPlan, skr);
      final s = await keeper.decide(skrPlan, 0, fees, now);
      expect(s.action, KeeperAction.execute);
      expect(
        s.reason,
        startsWith('pays 985000, fee 15000 (1500 burned) (~13500 lamports)'),
      );
    });

    test('an SKR dust tier is left to the beneficiary', () async {
      final v = plan(ruleMint: skr, amount: 30000);
      holdTokens(v, skr);
      final d = await keeper.decide(v, 0, fees, now);
      expect(d.action, KeeperAction.wait);
      expect(d.reason, contains('fee 450 (45 burned)'));
    });
  });

  group('sweep', () {
    test('reads the Config once and leaves dust to the beneficiary', () async {
      final rpc = await FakeRpc.start();
      addTearDown(rpc.close);
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final lastPulse = now - 100 * 86400;
      final paying = key(40);
      final dust = key(41);
      rpc.accounts
        ..[configPda().address] = FakeAccount(
          AppConfig.programId,
          configBytes(admin: key(42), treasury: treasury),
        )
        ..[treasury] = const FakeAccount(systemProgramId, [], lamports: 5000000)
        ..[heir] = const FakeAccount(systemProgramId, [], lamports: 5000000);
      for (final (owner, amount) in [(paying, 1000000), (dust, 100000)]) {
        rpc.accounts[vaultPda(owner, 0).address] = FakeAccount(
          AppConfig.programId,
          vaultBytes(
            owner: owner,
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
                amount: amount,
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

      String line(String owner) =>
          out.lines.singleWhere((l) => l.contains(vaultPda(owner, 0).address));
      expect(line(paying), endsWith('pays 980000 lamports, fee 20000'));
      expect(line(dust), endsWith('left for the beneficiary to claim'));
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
