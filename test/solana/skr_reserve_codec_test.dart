import 'package:deadman/core/config.dart';
import 'package:deadman/solana/codec.dart';
import 'package:deadman/solana/deadman_api.dart';
import 'package:deadman/solana/deadman_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:solana/encoder.dart';

import 'helpers.dart';

void main() {
  final owner = key(1);
  final guard = key(2);
  final alice = key(3);
  final usdc = key(6);
  final treasury = key(7);
  final skr = key(9);
  final idl = loadIdl();
  Map<String, dynamic> idlIx(String name) =>
      ((idl['instructions'] as List).firstWhere(
        (i) => i['name'] == name,
      ) as Map).cast<String, dynamic>();
  List<String> names(List<dynamic> items) => [
    for (final i in items) (i as Map)['name'] as String,
  ];
  List<int> disc(String section, String name) => List<int>.from(
    (idl[section] as List).firstWhere((i) => i['name'] == name)['discriminator']
        as List,
  );

  group('IDL', () {
    test('discriminators of the new instructions, account and events', () {
      expect(Disc.fundSkrReserve, disc('instructions', 'fund_skr_reserve'));
      expect(
        Disc.withdrawSkrReserve,
        disc('instructions', 'withdraw_skr_reserve'),
      );
      expect(Disc.setPriceFeed, disc('instructions', 'set_price_feed'));
      expect(Disc.priceFeedAccount, disc('accounts', 'PriceFeed'));
      expect(Disc.skrFeePaidEvent, disc('events', 'SkrFeePaid'));
    });

    test('instruction accounts and args in the order the builders use', () {
      expect(names(idlIx('fund_skr_reserve')['accounts'] as List), [
        'owner',
        'vault',
        'config',
        'mint',
        'vault_token',
        'owner_token',
        'token_program',
      ]);
      expect(names(idlIx('withdraw_skr_reserve')['accounts'] as List), [
        'owner',
        'vault',
        'mint',
        'vault_token',
        'owner_token',
        'token_program',
      ]);
      expect(names(idlIx('set_price_feed')['accounts'] as List), [
        'admin',
        'config',
        'price_feed',
        'system_program',
      ]);
      expect(names(idlIx('set_price_feed')['args'] as List), [
        'mint',
        'feed_id',
        'shard_id',
        'max_age_secs',
      ]);
      expect(
        names(
          (idl['types'] as List).firstWhere(
                (t) => t['name'] == 'PriceFeed',
              )['type']['fields']
              as List,
        ),
        ['mint', 'feed_id', 'price_account', 'max_age_secs', 'bump'],
      );
    });

    test('the SKR fee errors read clearly', () {
      for (final (code, name) in [
        (6033, 'SkrFeeAccountsRequired'),
        (6034, 'InvalidSkrFeeAccounts'),
        (6035, 'FeeReserveNotEmpty'),
      ]) {
        final e = DeadmanException.program(code);
        expect(e.name, name);
        expect(e.message, isNot(contains('pass the price feeds')));
      }
      expect(
        DeadmanException.program(6035).message,
        contains('Withdraw the SKR fee reserve first'),
      );
    });
  });

  group('price registry', () {
    test('canonical push-oracle accounts match the live ones', () {
      expect(
        pythPriceAccount(PythFeedIds.solUsd),
        '7UVimffxr9ow1uXYxsr4LHAcV58mLzhmwaeKvJ1pjLiE',
      );
      expect(
        pythPriceAccount(PythFeedIds.usdcUsd),
        'Dpw1EAVrSB1ibxiDQyTAW6Zip3J4Btk2x4SgApQCeFbX',
      );
      expect(
        pythPriceAccount(PythFeedIds.skrUsd),
        'AFrJWhfWt3vDtGPdcwTyLyHz8ZQ4M9L2z1YHThY5Vbj5',
      );
      expect(
        pythPriceAccount(PythFeedIds.solUsd, shard: 1),
        isNot(pythPriceAccount(PythFeedIds.solUsd)),
      );
    });

    test('PriceFeed decodes; a bad discriminator or feed id is refused', () {
      final bytes = priceFeedBytes(
        mint: nativeMint,
        feedId: PythFeedIds.solUsd,
        maxAgeSecs: 90,
      );
      expect(bytes, hasLength(priceFeedAccountSize));
      final f = decodePriceFeed(bytes);
      expect(f.mint, nativeMint);
      expect(f.feedId, PythFeedIds.solUsd);
      expect(f.priceAccount, '7UVimffxr9ow1uXYxsr4LHAcV58mLzhmwaeKvJ1pjLiE');
      expect(f.maxAgeSecs, 90);
      expect(
        () => decodePriceFeed([0, ...bytes.skip(1)]),
        throwsFormatException,
      );
      expect(() => feedIdBytes('abc'), throwsFormatException);
      expect(feedIdBytes('0x${PythFeedIds.skrUsd}'), hasLength(32));
    });

    test('set_price_feed: admin signs, the PDA of the mint is written', () {
      final ix = setPriceFeedIx(
        admin: owner,
        mint: skr,
        feedId: PythFeedIds.skrUsd,
        maxAgeSecs: 120,
      );
      expect(ix.accounts.map((a) => a.pubKey.toBase58()), [
        owner,
        configPda().address,
        priceFeedPda(skr).address,
        systemProgramId,
      ]);
      expect(ix.accounts[0].isSigner, isTrue);
      expect(ix.accounts[2].isWriteable, isTrue);
      expect(ix.data.toList(), [
        ...Disc.setPriceFeed,
        ...keyBytes(skr),
        ...feedIdBytes(PythFeedIds.skrUsd),
        ...le(2, 0),
        ...le(4, 120),
      ]);
    });
  });

  group('PriceUpdateV2', () {
    const now = 1790000000;
    final feed = decodePriceFeed(
      priceFeedBytes(mint: nativeMint, feedId: PythFeedIds.solUsd),
    );
    PythPrice update({
      String feedId = PythFeedIds.solUsd,
      int price = 15000000000,
      int conf = 1000000,
      int age = 10,
      bool full = true,
    }) => decodePriceUpdate(
      priceUpdateBytes(
        feedId: feedId,
        price: price,
        conf: conf,
        expo: -8,
        publishTime: now - age,
        full: full,
      ),
    );

    test('decodes full and partially verified updates', () {
      final p = update();
      expect(p.full, isTrue);
      expect(p.feedId, PythFeedIds.solUsd);
      expect(p.price, 15000000000);
      expect(p.conf, 1000000);
      expect(p.expo, -8);
      expect(p.publishTime, now - 10);
      final partial = update(full: false);
      expect(partial.full, isFalse);
      expect(partial.price, 15000000000, reason: 'message after the count');
      expect(
        () => decodePriceUpdate(List<int>.filled(134, 0)),
        throwsFormatException,
      );
    });

    test('usable only when full, of the feed, fresh, tight and positive', () {
      expect(usablePrice(feed, update(), now), (15000000000, -8));
      expect(usablePrice(feed, update(age: 120), now), isNotNull);
      expect(usablePrice(feed, update(age: 121), now), isNull, reason: 'stale');
      expect(usablePrice(feed, update(full: false), now), isNull);
      expect(
        usablePrice(feed, update(feedId: PythFeedIds.skrUsd), now),
        isNull,
      );
      // 2% of the price is still usable, a hair more is not.
      expect(usablePrice(feed, update(conf: 300000000), now), isNotNull);
      expect(usablePrice(feed, update(conf: 300000001), now), isNull);
      expect(usablePrice(feed, update(price: 0), now), isNull);
      expect(usablePrice(feed, update(price: -5), now), isNull);
      final disabled = (
        mint: feed.mint,
        feedId: feed.feedId,
        priceAccount: feed.priceAccount,
        maxAgeSecs: 0,
      );
      expect(usablePrice(disabled, update(age: 0), now), isNull);
    });
  });

  group('skrFeeQuote mirrors the program', () {
    int? q(int gross, (int, int) a, int ad, (int, int) s, int sd, int bps) =>
        skrFeeQuote(
          gross: gross,
          asset: a,
          assetDecimals: ad,
          skr: s,
          skrDecimals: sd,
          feeBps: bps,
        );

    test('the program test vectors', () {
      expect(q(1000000, (5, -2), 6, (5, -2), 6, 150), 15000);
      expect(q(1, (1, 2), 0, (1, 0), 0, 10000), 100);
      expect(q(100, (1, 0), 2, (1, 0), 0, 10000), 1);
      expect(q(1, (1, 0), 0, (3, 0), 0, 10000), 1, reason: 'rounds up');
      expect(q(1, (1, 40), 0, (1, 0), 0, 150), isNull);
      expect(q(1, (1, 0), 0, (0, 0), 0, 150), isNull);
    });

    test('1 SOL at 150 USD pays 2.25 USD of SKR at 0.02 USD', () {
      // 1.5% of 150 USD = 2.25 USD = 112.5 SKR = 112,500,000 base units.
      expect(
        q(1000000000, (15000000000, -8), 9, (2000000, -8), 6, 150),
        112500000,
      );
      // One lamport more rounds up to the next SKR base unit.
      expect(
        q(1000000001, (15000000000, -8), 9, (2000000, -8), 6, 150),
        112500001,
      );
    });
  });

  group('vault reserve', () {
    VaultState decode({
      int reserve = 0,
      String? mint,
      List<RuleState>? rules,
    }) => decodeVault(
      vaultBytes(
        owner: owner,
        guard: guard,
        rules:
            rules ??
            [
              RuleState(
                beneficiary: alice,
                rail: Rail.solana,
                afterSecs: 60,
                mint: skr,
                mode: AmountMode.percent,
                amount: 10000,
                executedAt: 0,
                paid: 0,
              ),
            ],
        vestPeriodSecs: 3600,
        skrFeeReserve: reserve,
        skrReserveMint: mint,
      ),
      address: vaultPda(owner, 0).address,
      lamports: 5000000,
      rentExemptMinimum: 1000000,
    );

    test('decodes the reserve after vest_period_secs; none reads as null', () {
      final v = decode(reserve: 7000, mint: skr);
      expect(v.vestPeriodSecs, 3600);
      expect(v.skrFeeReserve, 7000);
      expect(v.skrReserveMint, skr);
      final none = decode();
      expect(none.skrFeeReserve, 0);
      expect(none.skrReserveMint, isNull);
    });

    test('the reserve pays no tier and is not withdrawable as tier funds', () {
      final v = decode(reserve: 7000, mint: skr);
      expect(v.feeReserveIn(skr), 7000);
      expect(v.feeReserveIn(usdc), 0);
      expect(v.feeReserveIn(null), 0);
      expect(v.tierFunds(skr, 10000), 3000);
      expect(v.tierFunds(skr, 5000), 0);
      expect(v.payoutGross(0, 10000), 3000, reason: '100% of what is left');
      expect(v.lockedForOwner(skr), 7000);
      expect(v.lockedForOwner(usdc), 0);
    });

    test('paysFeeInSkr: a reserve in the configured mint, non-SKR payouts', () {
      final fees = FeeSchedule(
        treasury: treasury,
        feeBpsPublic: 200,
        feeBpsPrivate: 200,
        skrMint: skr,
        feeBpsSkr: 150,
        skrBurnBps: 1000,
      );
      final v = decode(reserve: 1, mint: skr);
      expect(v.paysFeeInSkr(fees, null), isTrue);
      expect(v.paysFeeInSkr(fees, usdc), isTrue);
      expect(v.paysFeeInSkr(fees, skr), isFalse);
      expect(decode(mint: skr).paysFeeInSkr(fees, null), isFalse);
      expect(decode(reserve: 1, mint: usdc).paysFeeInSkr(fees, null), isFalse);
      final noRate = FeeSchedule(
        treasury: treasury,
        feeBpsPublic: 200,
        feeBpsPrivate: 200,
      );
      expect(v.paysFeeInSkr(noRate, null), isFalse);
    });
  });

  group('instructions', () {
    final vault = vaultPda(owner, 0).address;

    test('fund_skr_reserve creates the vault ATA, then moves the SKR', () {
      final ixs = fundSkrReserveIxs(
        owner: owner,
        planId: 0,
        mint: skr,
        amount: 500,
      );
      expect(ixs.first.programId.toBase58(), ataProgramId);
      expect(ixs.first.accounts[1].pubKey.toBase58(), ataAddress(vault, skr));
      final ix = ixs.last;
      expect(ix.data.toList(), [...Disc.fundSkrReserve, ...le(8, 500)]);
      expect(
        [
          for (final a in ix.accounts)
            (a.pubKey.toBase58(), a.isWriteable, a.isSigner),
        ],
        [
          (owner, false, true),
          (vault, true, false),
          (configPda().address, false, false),
          (skr, false, false),
          (ataAddress(vault, skr), true, false),
          (ataAddress(owner, skr), true, false),
          (tokenProgramId, false, false),
        ],
      );
    });

    test('withdraw_skr_reserve reopens the owner ATA, then withdraws', () {
      final ixs = withdrawSkrReserveIxs(
        owner: owner,
        planId: 0,
        mint: skr,
        amount: 42,
      );
      expect(ixs.first.accounts[1].pubKey.toBase58(), ataAddress(owner, skr));
      final ix = ixs.last;
      expect(ix.data.toList(), [...Disc.withdrawSkrReserve, ...le(8, 42)]);
      expect(ix.accounts.map((a) => a.pubKey.toBase58()), [
        owner,
        vault,
        skr,
        ataAddress(vault, skr),
        ataAddress(owner, skr),
        tokenProgramId,
      ]);
      expect(ix.accounts.first.isWriteable, isTrue);
    });

    test('SKR fee accounts follow the payout accounts, in program order', () {
      final accounts = skrFeeAccounts(
        vault: vault,
        assetMint: null,
        skrMint: skr,
        treasury: treasury,
        assetPriceAccount: pythPriceAccount(PythFeedIds.solUsd),
        skrPriceAccount: null,
      );
      expect(
        [
          for (final a in accounts)
            (a.pubKey.toBase58(), a.isWriteable, a.isSigner),
        ],
        [
          (priceFeedPda(nativeMint).address, false, false),
          (pythPriceAccount(PythFeedIds.solUsd), false, false),
          (priceFeedPda(skr).address, false, false),
          (systemProgramId, false, false),
          (ataAddress(vault, skr), true, false),
          (skr, true, false),
          (ataAddress(treasury, skr), true, false),
          (tokenProgramId, false, false),
        ],
      );
      const rule = RuleSpec(
        beneficiary: '11111111111111111111111111111112',
        rail: Rail.solana,
        afterSecs: 60,
        mode: AmountMode.percent,
        amount: 10000,
      );
      final sol = executeRuleIxs(
        executor: owner,
        vaultOwner: owner,
        planId: 0,
        rule: rule,
        index: 0,
        treasury: treasury,
        skrFee: accounts,
      ).single;
      expect(sol.accounts, hasLength(5 + 8));
      expect(sol.accounts.skip(5).map((a) => a.pubKey), [
        for (final a in accounts) a.pubKey,
      ]);
      final token = releaseVestedIxs(
        executor: owner,
        vaultOwner: owner,
        planId: 0,
        rule: RuleSpec(
          beneficiary: alice,
          rail: Rail.solana,
          afterSecs: 60,
          mode: AmountMode.fixed,
          amount: 1,
          mint: AppConfig.usdcMint,
        ),
        index: 0,
        treasury: treasury,
        skrFee: accounts,
      ).last;
      expect(token.accounts, hasLength(9 + 8));
      expect(token.accounts[8].pubKey.toBase58(), tokenProgramId);
      expect(
        token.accounts.skip(9).map((a) => a.pubKey.toBase58()).first,
        priceFeedPda(nativeMint).address,
      );
      expect(
        executeRuleIxs(
          executor: owner,
          vaultOwner: owner,
          planId: 0,
          rule: rule,
          index: 0,
          treasury: treasury,
        ).single.accounts,
        hasLength(5),
      );
    });

    test('a token payout with the fee accounts still fits a transaction', () {
      final rule = RuleSpec(
        beneficiary: alice,
        rail: Rail.solana,
        afterSecs: 60,
        mode: AmountMode.percent,
        amount: 10000,
        mint: usdc,
      );
      final tx = serializeUnsigned(
        executeRuleIxs(
          executor: key(8),
          vaultOwner: owner,
          planId: 0,
          rule: rule,
          index: 0,
          treasury: treasury,
          skrFee: skrFeeAccounts(
            vault: vault,
            assetMint: usdc,
            skrMint: skr,
            treasury: treasury,
            assetPriceAccount: pythPriceAccount(PythFeedIds.usdcUsd),
            skrPriceAccount: pythPriceAccount(PythFeedIds.skrUsd),
          ),
        ),
        feePayer: key(8),
        recentBlockhash: key(99),
      );
      expect(tx.length, lessThan(DeadmanClient.maxTxBytes - 200));
      expect(
        Message.decompile(SignedTx.fromBytes(tx).compiledMessage).instructions,
        hasLength(3),
      );
    });
  });
}
