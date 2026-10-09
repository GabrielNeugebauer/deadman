import 'package:deadman/core/config.dart';
import 'package:deadman/solana/deadman_api.dart';
import 'package:deadman/state/assets.dart';
import 'package:deadman/state/plan_draft.dart';
import 'package:deadman/state/vesting.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

const usdc = AppConfig.usdcMint;
final _fees = FeeSchedule(
  treasury: addr(9),
  feeBpsPublic: 200,
  feeBpsPrivate: 300,
);

PayoutDraft _share(
  int bps, {
  String? mint = usdc,
  Rail rail = Rail.solana,
  int after = 10 * 86400,
  String name = 'Ana',
}) => PayoutDraft(
  beneficiary: addr(12),
  rail: rail,
  mint: mint,
  shareBps: bps,
  afterSecs: after,
  name: name,
);

PayoutDraft _fixed(int amount, {String? mint = usdc, int after = 10 * 86400}) =>
    PayoutDraft(
      beneficiary: addr(12),
      mint: mint,
      mode: AmountMode.fixed,
      fixedAmount: amount,
      afterSecs: after,
      name: 'Ana',
    );

PlanPreview _preview(List<PayoutDraft> ps, int balance, {FeeInfo? fee}) =>
    PlanPreview.of(
      ps,
      balanceOf: (_) => balance,
      feeBps: (fee ?? FeeInfo(fees: _fees)).bpsFor,
    );

Set<IssueCode> _codes(
  List<PayoutDraft> ps,
  int balance, {
  DeliveryFacts facts = DeliveryFacts.unknown,
  FeeInfo? fee,
}) {
  final f = fee ?? FeeInfo(fees: _fees);
  final preview = _preview(ps, balance, fee: f);
  return {
    for (var i = 0; i < ps.length; i++)
      ...payoutWarnings(
        payouts: ps,
        index: i,
        preview: preview,
        fee: f,
        facts: facts,
      ).map((x) => x.code),
    for (final a in preview.assets)
      ...assetIssues(
        asset: a,
        mint: a.mint,
        payouts: ps,
        creating: true,
        balance: balance,
        numberOf: (i) => i + 1,
      ).map((x) => x.code),
  };
}

void main() {
  group('the incident', () {
    test('1% of 1 USDC to a new wallet: 0.0098 USDC, D2 + A1 + L1', () {
      final ps = [_share(100)];
      expect(_preview(ps, 1000000).amounts.single.net, 9800);
      expect(moneyText(9800, usdc), '0.0098 USDC');
      expect(_codes(ps, 1000000), {IssueCode.d2, IssueCode.a1, IssueCode.l1});
    });

    test('100% of 1 USDC needs a claim (D3), not D2', () {
      final ps = [_share(10000)];
      expect(_preview(ps, 1000000).amounts.single.net, 980000);
      expect(_codes(ps, 1000000), {IssueCode.d3});
    });

    test('an existing heir token account clears D2 and D3', () {
      const held = DeliveryFacts(walletLamports: 0, tokenUnits: 5);
      expect(_codes([_share(100)], 1000000, facts: held), {
        IssueCode.a1,
        IssueCode.l1,
      });
      expect(_codes([_share(10000)], 1000000, facts: held), isEmpty);
    });

    test('while facts load no delivery warning is raised', () {
      final ps = [_share(10000)];
      final preview = _preview(ps, 1000000);
      expect(
        payoutWarnings(
          payouts: ps,
          index: 0,
          preview: preview,
          fee: FeeInfo(fees: _fees),
          facts: null,
        ),
        isEmpty,
      );
    });

    test('above the keeper threshold it arrives on its own', () {
      expect(_codes([_share(10000)], 20000000), isEmpty);
    });
  });

  group('keeperAutoDeliverMin', () {
    test('USDC at 2% and 3%', () {
      expect(keeperAutoDeliverMin(usdc, 200), 16994000);
      expect(keeperAutoDeliverMin(usdc, 300), 11329334);
    });

    test('never with no fee or an unpriced token', () {
      expect(keeperAutoDeliverMin(usdc, 0), isNull);
      expect(keeperAutoDeliverMin(addr(40), 200), isNull);
      expect(keeperAutoDeliverMin(null, 200), isNull);
    });

    test('matches the keeper floor', () {
      final min = keeperAutoDeliverMin(usdc, 200)!;
      int feeValue(int gross) =>
          (splitFee(gross, 200).$2 * keeperUsdcLamportsPerUnit).floor();
      expect(feeValue(min), greaterThanOrEqualTo(tokenAccountRentLamports));
      expect(feeValue(min - 50), lessThan(tokenAccountRentLamports));
    });

    test('with no fee a new wallet always needs a claim', () {
      final free = FeeInfo(
        fees: FeeSchedule(treasury: addr(9), feeBpsPublic: 0, feeBpsPrivate: 0),
      );
      expect(_codes([_share(10000)], 900000000, fee: free), {IssueCode.d3});
    });
  });

  group('SOL delivery', () {
    test('0.0005 SOL to an empty wallet cannot arrive (D4)', () {
      final ps = [_fixed(510205, mint: null)];
      final net = _preview(ps, 1000000000).amounts.single.net!;
      expect(net, lessThan(walletRentMinLamports));
      expect(_codes(ps, 1000000000), {IssueCode.d4, IssueCode.l1});
    });

    test('the same payout to a funded wallet is fine', () {
      final ps = [_fixed(510205, mint: null)];
      expect(
        _codes(
          ps,
          1000000000,
          facts: const DeliveryFacts(walletLamports: 1000000),
        ),
        {IssueCode.l1},
      );
    });

    test('a small private SOL payout cannot be routed (D5)', () {
      final ps = [_share(10000, mint: null, rail: Rail.cloak)];
      expect(
        _codes(
          ps,
          10000000,
          facts: const DeliveryFacts(walletLamports: 1000000),
        ),
        {IssueCode.d5},
      );
    });

    test('private token payouts warn they are not routed yet (D6)', () {
      final ps = [_share(10000, rail: Rail.zcash)];
      expect(_codes(ps, 50000000, facts: const DeliveryFacts(tokenUnits: 1)), {
        IssueCode.d6,
      });
      expect(stipendNeed(ps), 3000000);
    });
  });

  group('previews', () {
    test('shares compound in delay order per asset', () {
      final ps = [
        _share(10000, after: 20 * 86400),
        _share(5000, after: 10 * 86400),
      ];
      final p = _preview(ps, 1000000);
      expect(p.amounts[1].gross, 500000);
      expect(p.amounts[0].gross, 500000);
      expect(p.assetOf(usdc).order, [1, 0]);
      expect(p.assetOf(usdc).leftover, 0);
      expect(p.assetOf(usdc).feeTotal, 20000);
    });

    test('fixed payouts are capped at what is left', () {
      final ps = [_fixed(700000), _fixed(700000, after: 20 * 86400)];
      final p = _preview(ps, 1000000);
      expect([p.amounts[0].gross, p.amounts[1].gross], [700000, 300000]);
      expect(
        assetIssues(
          asset: p.assetOf(usdc),
          mint: usdc,
          payouts: ps,
          creating: true,
          balance: 1000000,
          numberOf: (i) => i + 1,
        ).map((i) => i.code),
        [IssueCode.f4, IssueCode.l1],
      );
    });

    test('an unknown balance gives no amounts', () {
      final p = PlanPreview.of(
        [_share(10000)],
        balanceOf: (_) => null,
        feeBps: (_, _) => 200,
      );
      expect(p.amounts.single.net, isNull);
      expect(p.assets.single.leftover, isNull);
    });

    test('SOL, then USDC, then other tokens', () {
      expect(assetOrder([addr(40), usdc, null, usdc]), [null, usdc, addr(40)]);
    });

    test('A1 only on the last payout of an asset', () {
      final ps = [_share(500), _share(10000, after: 20 * 86400)];
      expect(_codes(ps, 100000000), {IssueCode.d3});
      expect(_codes([_share(501)], 100000000), {IssueCode.l1, IssueCode.d3});
    });

    test('F2 when a used asset gets no deposit', () {
      expect(
        assetIssues(
          asset: _preview([_share(10000)], 0).assetOf(usdc),
          mint: usdc,
          payouts: [_share(10000)],
          creating: true,
          balance: 0,
          numberOf: (i) => i + 1,
        ).single.body,
        'The plan will hold no USDC, so payout 1 has nothing to send until '
        'you deposit some from the plan card.',
      );
    });
  });

  group('text', () {
    test('words line', () {
      expect(shareWords(10000, 'USDC'), "Everything that's left");
      expect(shareWords(5000, 'USDC'), "Half of what's left");
      expect(shareWords(100, 'USDC'), '1 out of every 100 USDC left');
      expect(shareWords(1250, 'SOL'), '12.5 out of every 100 SOL left');
      expect(shareWords(null, 'SOL'), isNull);
    });

    test('share parsing: 0.01 to 100, at most 2 decimals', () {
      expect(parseShareBps('1'), 100);
      expect(parseShareBps('100'), 10000);
      expect(parseShareBps('0,5'), 50);
      expect(parseShareBps('0.01'), 1);
      expect(parseShareBps('0'), isNull);
      expect(parseShareBps('100.01'), isNull);
      expect(parseShareBps('1.005'), isNull);
      expect(parseShareBps(''), isNull);
    });

    test('money keeps two significant digits', () {
      expect(moneyText(9800, usdc), '0.0098 USDC');
      expect(moneyText(490000, null), '0.00049 SOL');
      expect(moneyText(980000, usdc), '0.98 USDC');
      expect(moneyText(98000000, usdc), '98 USDC');
      expect(moneyText(1234567890, null), '1.235 SOL');
    });

    test('payout sentences on each rail', () {
      final a = addr(12);
      final shortA = '${a.substring(0, 4)}…\u2060${a.substring(a.length - 4)}';
      expect(
        payoutSentence(_share(10000), net: 980000),
        'Ana gets everything left of your USDC (≈\u00a00.98 USDC) as a normal '
        'transfer to $shortA.',
      );
      expect(
        payoutSentence(_share(2500, rail: Rail.cloak)),
        'Ana gets 25% of the USDC left at that point privately through '
        'Cloak, using their claim code.',
      );
      expect(
        payoutSentence(
          PayoutDraft(
            beneficiary: a,
            rail: Rail.zcash,
            mode: AmountMode.fixed,
            fixedAmount: 1500000000,
            afterSecs: 86400,
          ),
          net: 1455000000,
        ),
        '$shortA gets 1.5 SOL (≈\u00a01.455 SOL) privately as Zcash, using '
        'their claim code.',
      );
      expect(
        payoutSentence(
          PayoutDraft(
            beneficiary: a,
            rail: Rail.solana,
            mode: AmountMode.fixed,
            fixedAmount: 50000000,
            mint: usdc,
            afterSecs: 86400,
          ),
          net: 11760000,
          capped: true,
        ),
        '$shortA gets 50 USDC (only ≈\u00a011.76 USDC will be left for it) as '
        'a normal transfer.',
      );
      expect(
        payoutSentence(_share(10000)),
        'Ana gets everything left of your USDC as a normal transfer to '
        '$shortA.',
      );
      expect(payoutWhen(10 * 86400), 'Sent 10 days after your last check-in');
      expect(delayText(365 * 86400), '1 year');
      expect(delayText(120), '2 minutes');
    });

    test('leftover sentences', () {
      final p = _preview([_share(100)], 1000000);
      expect(
        leftoverSentence(p.assets.single),
        '0.99 USDC (99% of what the plan holds) stays locked in the plan '
        "after the last payout. Nobody can withdraw it once you're gone.",
      );
      expect(
        leftoverSentence(_preview([_fixed(1000000)], 1000000).assets.single),
        startsWith('Nothing is left over today, but the last USDC payout'),
      );
      expect(
        leftoverSentence(_preview([_share(10000)], 1000000).assets.single),
        'Nothing of your USDC is left behind.',
      );
    });
  });

  group('PayoutDraft', () {
    test('round-trips RuleSpec; 100% reads "100"', () {
      final r = RuleSpec(
        beneficiary: addr(12),
        rail: Rail.solana,
        afterSecs: 10 * 86400,
        mode: AmountMode.percent,
        amount: 10000,
        mint: usdc,
      );
      final d = PayoutDraft.fromRule(r);
      expect(shareInput(d.shareBps!), '100');
      final back = d.toRuleSpec();
      expect(
        [back.beneficiary, back.rail, back.afterSecs, back.mode, back.amount],
        [r.beneficiary, r.rail, r.afterSecs, r.mode, r.amount],
      );
      expect(back.mint, usdc);
    });

    test('validate reports each field', () {
      expect(_share(10000).validate(), isEmpty);
      expect(
        PayoutDraft(
          beneficiary: 'nope',
          mode: AmountMode.fixed,
          fixedAmount: 1000,
          afterSecs: 59,
        ).validate().map((i) => i.code),
        [IssueCode.b2, IssueCode.a2, IssueCode.d1],
      );
    });

    test('a wait is between a minute and 3 years', () {
      expect(delayError(59)!.body, 'Must be at least 1 minute.');
      expect(delayError(60), isNull);
      expect(delayError(3 * 366 * 86400), isNull);
      expect(delayError(3 * 366 * 86400 + 1)!.body, 'Must be 3 years or less.');
    });

    test('delay presets: 7 or 30 days, minutes with demo timings', () {
      expect(delayChoices(demo: false).map(delayText), ['7 days', '30 days']);
      expect(delayChoices(demo: true), [60, 120, 300, 600]);
      expect(defaultDelay(demo: false), 30 * 86400);
      expect(defaultDelay(demo: true), 120);
      for (final s in [
        ...delayChoices(demo: false),
        ...delayChoices(demo: true),
      ]) {
        expect(delayError(s), isNull);
      }
    });
  });

  group('funding', () {
    test('defaults cover fixed payouts, capped by the wallet', () {
      expect(defaultDeposit(fixedSum: 0, stipend: 0), isNull);
      expect(defaultDeposit(fixedSum: 5, stipend: 0, wallet: 100), 5);
      expect(
        defaultDeposit(fixedSum: 100, stipend: 0, wallet: 100, reserve: 30),
        70,
      );
      expect(defaultDeposit(fixedSum: 0, stipend: 12000000), 12000000);
    });

    test('the SOL fee reserve', () {
      expect(feeReserveLamports(solFeeMode: false, sponsored: false), 0);
      expect(feeReserveLamports(solFeeMode: true, sponsored: true), 20000000);
      expect(feeReserveLamports(solFeeMode: true, sponsored: false), 30000000);
    });

    test('V1 when a vesting deposit is short', () {
      expect(vestingShortfall(usdc, 100, 100), isNull);
      expect(
        vestingShortfall(usdc, 1000000000, 400000000)!.body,
        'The deposit is 600 USDC short. Unlocking pauses when the plan runs '
        'dry, until you deposit more.',
      );
    });
  });

  group('installments', () {
    const year = 12 * monthSecs;
    const start = 1000;
    ScheduleDraft draft({
      int total = 1200000000,
      int cliff = 0,
      int duration = year,
      String? mint = usdc,
    }) => ScheduleDraft(
      beneficiary: addr(30),
      mint: mint,
      total: total,
      cliffSecs: cliff,
      durationSecs: duration,
      name: 'Ana',
    );
    String date(int at) => 't+${at - start}';
    String dur(int secs) => '${secs}s';

    test('monthly over a year: 12 even installments, first after a month', () {
      final n = draft().installments(periodSecs: monthSecs, startAt: start)!;
      expect(n.count, 12);
      expect(n.amount, 100000000);
      expect(n.firstAt, start + monthSecs);
      expect(n.firstCount, 1);
      expect(n.firstAmount, 100000000);
      expect(n.even, isTrue);
      expect(n.lastSmaller, isFalse);
      expect(draft().installments(periodSecs: 0, startAt: start), isNull);
    });

    test('a cliff unlocks the installments it covered at once', () {
      final n = draft(cliff: 3 * monthSecs)
          .installments(periodSecs: monthSecs, startAt: start)!;
      expect(n.firstAt, start + 3 * monthSecs);
      expect(n.firstCount, 3);
      expect(n.firstAmount, 300000000);

      // A cliff between boundaries unlocks the whole periods it covered.
      final m = draft(cliff: 90 * 86400)
          .installments(periodSecs: monthSecs, startAt: start)!;
      expect(m.firstAt, start + 90 * 86400);
      expect(m.firstCount, 2);
      expect(m.firstAmount, 200000000);

      // A cliff shorter than a period: the first boundary.
      final short = draft(cliff: 86400)
          .installments(periodSecs: monthSecs, startAt: start)!;
      expect(short.firstAt, start + monthSecs);
      expect(short.firstCount, 1);
    });

    test('weeks over 3 months: 14, the last one partial', () {
      final n = draft(duration: 3 * monthSecs)
          .installments(periodSecs: weekSecs, startAt: start)!;
      expect(n.count, 14);
      expect(n.lastSmaller, isTrue);
      expect(n.even, isFalse);
    });

    test('demo: 10 one-minute installments after a 2-minute cliff', () {
      final n = draft(
        mint: null,
        total: 500000000,
        cliff: 120,
        duration: 600,
      ).installments(periodSecs: 60, startAt: start)!;
      expect(n.count, 10);
      expect(n.amount, 50000000);
      expect(n.firstAt, start + 120);
      expect(n.firstCount, 2);
      expect(n.firstAmount, 100000000);
    });

    test('vestedAfter steps at whole periods, mirroring the program', () {
      int at(int elapsed, {int period = 60, int cliff = 0}) => vestedAfter(
        total: 1000,
        cliffSecs: cliff,
        durationSecs: 600,
        periodSecs: period,
        elapsed: elapsed,
      );
      expect(at(59), 0);
      expect(at(60), 100);
      expect(at(119), 100);
      expect(at(599), 900);
      expect(at(600), 1000);
      expect(at(5000), 1000);
      expect(at(150, cliff: 180), 0);
      expect(at(180, cliff: 180), 300);
      expect(at(59, period: 0), 98);
      // A duration that is not a whole number of periods ends on time.
      expect(
        vestedAfter(
          total: 1000,
          cliffSecs: 0,
          durationSecs: 650,
          periodSecs: 60,
          elapsed: 649,
        ),
        923,
      );
    });

    test('a period longer than a schedule is explained', () {
      final schedules = [draft(), draft(duration: 600)];
      expect(vestPeriodError(0, schedules, duration: dur), isNull);
      expect(vestPeriodError(60, schedules, duration: dur), isNull);
      expect(
        vestPeriodError(monthSecs, schedules, duration: dur),
        'Schedule 2 is fully unlocked after 600s, before its first '
        'installment (one every month). Release more often, or give it a '
        'longer duration.',
      );
      expect(vestPeriodError(30, schedules, duration: dur), isNotNull);
    });

    test('sentences', () {
      expect(
        installmentsText(
          draft(),
          periodSecs: monthSecs,
          startAt: start,
          date: date,
        ),
        '12 installments of 100 USDC every month, first on t+$monthSecs',
      );
      expect(
        installmentsText(
          draft(cliff: 3 * monthSecs),
          periodSecs: quarterSecs,
          startAt: start,
          date: date,
        ),
        '4 installments of 300 USDC every quarter, first on t+$quarterSecs',
      );
      expect(
        installmentsText(
          draft(cliff: 6 * monthSecs),
          periodSecs: monthSecs,
          startAt: start,
          date: date,
        ),
        '12 installments of 100 USDC every month, the first 6 together '
        '(600 USDC) on t+${6 * monthSecs}',
      );
      expect(
        installmentsText(
          draft(total: 1000000000, duration: 3 * monthSecs),
          periodSecs: weekSecs,
          startAt: start,
          date: date,
        ),
        startsWith(
          '14 installments of about 76.66 USDC every week (the last one '
          'smaller), first on',
        ),
      );
      expect(
        vestingSentence(
          draft(),
          start: 'today',
          duration: (s) => s == year ? '12 months' : '?',
          periodSecs: monthSecs,
          startAt: start,
          date: date,
        ),
        'Starting today, Ana receives 1200 USDC over 12 months in 12 '
        'installments of 100 USDC every month, first on t+$monthSecs, as a '
        'normal transfer.',
      );
      expect(
        vestingSentence(
          draft(),
          start: 'today',
          duration: (s) => '12 months',
          date: date,
        ),
        startsWith('Starting today, Ana receives 1200 USDC gradually'),
      );
      expect(
        [
          for (final p in [
            60,
            86400,
            weekSecs,
            monthSecs,
            quarterSecs,
            2592000,
          ])
            vestPeriodWord(p),
        ],
        ['minute', 'day', 'week', 'month', 'quarter', '30 days'],
      );
      expect(periodChoices(demo: false).first, (monthSecs, 'Month'));
      expect(periodChoices(demo: false).last, (0, 'Continuously'));
      expect(periodChoices(demo: true).first.$1, 60);
      expect(defaultPeriodSecs(demo: true), 60);
      expect(defaultPeriodSecs(demo: false), monthSecs);
    });
  });

  group('NFT payouts', () {
    final nft = addr(80);
    setUp(() => rememberNft(nft, 'Saga Genesis #7'));
    tearDown(forgetNfts);

    PayoutDraft nftPayout({Rail rail = Rail.solana, int after = 10 * 86400}) =>
        PayoutDraft(
          beneficiary: addr(12),
          rail: rail,
          mint: nft,
          mode: AmountMode.fixed,
          fixedAmount: 1,
          afterSecs: after,
          name: 'Ana',
        );

    test('read as the NFT itself, sent whole', () {
      final p = nftPayout();
      expect(p.nft, isTrue);
      expect(p.toRuleSpec().amount, 1);
      expect(p.toRuleSpec().mode, AmountMode.fixed);
      expect(payoutAmountLabel(p), 'The NFT Saga Genesis #7');
      expect(
        payoutSentence(p, net: 1),
        'Ana gets the NFT Saga Genesis #7 as a normal transfer to '
        '${addr(12).substring(0, 4)}…\u2060${addr(12).substring(40)}.',
      );
      expect(
        payoutSentence(p, net: 0),
        contains("(only if it's in the plan by then)"),
      );
      expect(moneyText(1, nft), 'Saga Genesis #7');
    });

    test('A5: only by normal transfer', () {
      expect(nftPayout().validate(), isEmpty);
      expect(nftPayout(rail: Rail.cloak).validate().map((i) => i.code), [
        IssueCode.a5,
      ]);
    });

    test('no "money stays behind", no fee taken from one', () {
      final ps = [nftPayout()];
      expect(_codes(ps, 1), {IssueCode.d3});
      final (net, fee) = splitFee(1, 200);
      expect((net, fee), (1, 0));
    });

    test('a heir new to it must claim it, with SOL for the fee', () {
      final ps = [nftPayout()];
      final preview = _preview(ps, 1);
      final d3 = payoutWarnings(
        payouts: ps,
        index: 0,
        preview: preview,
        fee: FeeInfo(fees: _fees),
        facts: const DeliveryFacts(walletLamports: 0, tokenUnits: 0),
      ).single;
      expect(d3.code, IssueCode.d3);
      expect(d3.body, contains("NFTs aren't sent automatically"));
      expect(d3.body, isNot(contains('USDC')));
    });

    test('two payouts of one NFT: only the first gets it', () {
      final ps = [nftPayout(), nftPayout(after: 20 * 86400)];
      final f4 = assetIssues(
        asset: _preview(ps, 1).assetOf(nft),
        mint: nft,
        payouts: ps,
        creating: true,
        balance: 1,
        numberOf: (i) => i + 1,
      ).single;
      expect(f4.code, IssueCode.f4);
      expect(f4.title, 'Only one payout can receive it');
      expect(f4.body, startsWith('Payouts 1 and 2 both send Saga Genesis #7'));
      expect(f4.action, isNull);
    });

    test('nothing deposited: F2 names the NFT', () {
      final ps = [nftPayout()];
      final f2 = assetIssues(
        asset: _preview(ps, 0).assetOf(nft),
        mint: nft,
        payouts: ps,
        creating: true,
        balance: 0,
        numberOf: (i) => i + 1,
      ).single;
      expect(f2.code, IssueCode.f2);
      expect(f2.body, contains('no Saga Genesis #7'));
    });
  });

  group('other tokens', () {
    test('a heir new to SKR claims it with a little SOL, not USDC', () {
      final p = _share(10000, mint: AppConfig.skrMint);
      final ps = [p];
      final d3 = payoutWarnings(
        payouts: ps,
        index: 0,
        preview: _preview(ps, 1000000000),
        fee: FeeInfo(fees: _fees),
        facts: const DeliveryFacts(walletLamports: 0, tokenUnits: 0),
      ).single;
      expect(d3.code, IssueCode.d3);
      expect(d3.body, contains('a little SOL for the network fee'));
      expect(d3.body, isNot(contains('0.50 USDC')));
    });
  });

  group('FeeInfo with an SKR rate', () {
    const skr = AppConfig.skrMint;
    final fee = FeeInfo(
      fees: FeeSchedule(
        treasury: addr(9),
        feeBpsPublic: 200,
        feeBpsPrivate: 200,
        skrMint: skr,
        feeBpsSkr: 150,
        skrBurnBps: 1000,
      ),
    );

    test('SKR pays 1.5% on every rail and shows the burn', () {
      expect(fee.bpsFor(Rail.cloak, skr), 150);
      expect(fee.bpsFor(Rail.solana, usdc), 200);
      expect(fee.railLine(Rail.zcash, skr), '1.5% fee · 10% burned');
      expect(fee.railLine(Rail.solana), '2% fee');
      expect(fee.note(Rail.solana, skr), '(after the 1.5% fee)');
      expect(const FeeInfo().railLine(Rail.solana), 'fee loading…');
      expect(const FeeInfo(failed: true).railLine(Rail.solana), 'Fee unknown');
    });

    test('the preview takes the SKR rate from SKR payouts', () {
      final p = PlanPreview.of(
        [_share(10000, mint: skr), _share(10000, name: 'Bo')],
        balanceOf: (_) => 1000000,
        feeBps: fee.bpsFor,
      );
      expect(p.amounts[0].net, 985000);
      expect(p.amounts[1].net, 980000);
    });
  });
}
