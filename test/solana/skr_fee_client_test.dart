import 'dart:typed_data';

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
  final executor = key(8);
  final skr = key(9);
  final vault = vaultPda(owner, 0).address;
  const now = 1790500000;
  const lastPulse = 1790000000;

  late FakeRpc rpc;
  late DeadmanClient client;

  RuleState tier({String? mint, int amount = 10000, AmountMode? mode}) =>
      RuleState(
        beneficiary: alice,
        rail: Rail.solana,
        afterSecs: 60,
        mint: mint,
        mode: mode ?? AmountMode.percent,
        amount: amount,
        executedAt: 0,
        paid: 0,
      );

  void putVault(
    List<RuleState> rules, {
    int reserve = 0,
    String? reserveMint,
    int lamports = 2000000000,
    int lockedUntil = 0,
    PlanKind kind = PlanKind.inheritance,
  }) => rpc.accounts[vault] = FakeAccount(
    AppConfig.programId,
    vaultBytes(
      owner: owner,
      guard: guard,
      lastPulse: lastPulse,
      lockedUntil: lockedUntil,
      guardianReadyAt: 0,
      rules: rules,
      kind: kind,
      startAt: kind == PlanKind.vesting ? lastPulse : 0,
      skrFeeReserve: reserve,
      skrReserveMint: reserveMint ?? (reserve > 0 ? skr : null),
    ),
    lamports: lamports,
  );

  void putTokens(String holder, String mint, int amount, {int state = 1}) =>
      rpc.accounts[ataAddress(holder, mint)] = FakeAccount(
        tokenProgramId,
        tokenAccountWithState(
          mint: mint,
          owner: holder,
          amount: amount,
          state: state,
        ),
      );

  void register(String mint, String feedId, {int maxAge = 120}) =>
      rpc.accounts[priceFeedPda(mint).address] = FakeAccount(
        AppConfig.programId,
        priceFeedBytes(mint: mint, feedId: feedId, maxAgeSecs: maxAge),
      );

  void post(
    String feedId,
    int price, {
    int age = 5,
    bool full = true,
    String owner = pythReceiverId,
  }) => rpc.accounts[pythPriceAccount(feedId)] = FakeAccount(
    owner,
    priceUpdateBytes(
      feedId: feedId,
      price: price,
      expo: -8,
      publishTime: now - age,
      full: full,
    ),
  );

  /// SOL at 150 USD, USDC at 1, SKR at 0.02, all registered and fresh,
  /// and the treasury's SKR account in place.
  void pricesUp() {
    register(nativeMint, PythFeedIds.solUsd);
    register(usdc, PythFeedIds.usdcUsd);
    register(skr, PythFeedIds.skrUsd);
    post(PythFeedIds.solUsd, 15000000000);
    post(PythFeedIds.usdcUsd, 100000000);
    post(PythFeedIds.skrUsd, 2000000);
    putTokens(treasury, skr, 0);
  }

  setUp(() async {
    rpc = await FakeRpc.start();
    client = DeadmanClient.withKora(client: rpc.client(), clock: () => now);
    rpc.accounts
      ..[configPda().address] = FakeAccount(
        AppConfig.programId,
        configBytes(
          admin: owner,
          treasury: treasury,
          feeBpsPrivate: 200,
          skrMint: skr,
        ),
      )
      ..[usdc] = FakeAccount(tokenProgramId, mintBytes(6))
      ..[skr] = FakeAccount(tokenProgramId, mintBytes(6))
      ..[treasury] = FakeAccount(systemProgramId, const [], lamports: 5000000);
  });

  tearDown(() => rpc.close());

  List<Instruction> instructions(Uint8List tx) =>
      Message.decompile(SignedTx.fromBytes(tx).compiledMessage).instructions;

  List<String> addrs(Instruction ix) => [
    for (final a in ix.accounts) a.pubKey.toBase58(),
  ];

  Future<Instruction> executeIx() async => instructions(
    await client.buildExecuteRule(
      executor: executor,
      vaultOwner: owner,
      planId: 0,
      index: 0,
    ),
  ).last;

  Matcher throwsNamed(String name) =>
      throwsA(isA<DeadmanException>().having((e) => e.name, 'name', name));

  group('payouts of a plan with an SKR fee reserve', () {
    test('a SOL payout passes the registered feeds and SKR accounts', () async {
      putVault([tier()], reserve: 200000000);
      putTokens(vault, skr, 200000000);
      pricesUp();
      final ix = await executeIx();
      expect(ix.data.toList(), [...Disc.executeSolRule, 0]);
      expect(addrs(ix).skip(5), [
        priceFeedPda(nativeMint).address,
        pythPriceAccount(PythFeedIds.solUsd),
        priceFeedPda(skr).address,
        pythPriceAccount(PythFeedIds.skrUsd),
        ataAddress(vault, skr),
        skr,
        ataAddress(treasury, skr),
        tokenProgramId,
      ]);
      expect(
        [for (final a in ix.accounts.skip(5)) a.isWriteable],
        [false, false, false, false, true, true, true, false],
      );
    });

    test('a token payout appends them after the token program', () async {
      putVault([tier(mint: usdc)], reserve: 5000000);
      putTokens(vault, skr, 5000000);
      putTokens(vault, usdc, 1000000);
      pricesUp();
      final ix = await executeIx();
      expect(ix.accounts, hasLength(9 + 8));
      expect(addrs(ix)[8], tokenProgramId);
      expect(addrs(ix).sublist(9, 11), [
        priceFeedPda(usdc).address,
        pythPriceAccount(PythFeedIds.usdcUsd),
      ]);
    });

    test('an asset with no PriceFeed passes its empty PDA, no price', () async {
      putVault([tier(mint: usdc)], reserve: 5000000);
      putTokens(vault, usdc, 1000000);
      register(skr, PythFeedIds.skrUsd);
      final ix = await executeIx();
      expect(addrs(ix).sublist(9, 13), [
        priceFeedPda(usdc).address,
        systemProgramId,
        priceFeedPda(skr).address,
        pythPriceAccount(PythFeedIds.skrUsd),
      ]);
    });

    test('vesting releases pass them too', () async {
      putVault(
        [
          RuleState(
            beneficiary: alice,
            rail: Rail.solana,
            afterSecs: 0,
            mode: AmountMode.fixed,
            amount: 1000000000,
            executedAt: 0,
            paid: 0,
            durationSecs: 1000,
          ),
        ],
        reserve: 200000000,
        kind: PlanKind.vesting,
      );
      pricesUp();
      final ix = instructions(
        await client.buildReleaseVested(
          executor: executor,
          vaultOwner: owner,
          planId: 0,
          index: 0,
        ),
      ).single;
      expect(ix.data.toList(), [...Disc.releaseVestedSol, 0]);
      expect(ix.accounts, hasLength(5 + 8));
    });

    test('none for SKR payouts, NFTs, plans without a reserve or with one '
        'in an older SKR mint', () async {
      pricesUp();
      putVault([tier(mint: skr)], reserve: 1000);
      putTokens(vault, skr, 5000);
      expect((await executeIx()).accounts, hasLength(9), reason: 'SKR');

      final nft = key(40);
      rpc.accounts[nft] = FakeAccount(tokenProgramId, mintBytes(0));
      putVault([
        tier(mint: nft, mode: AmountMode.fixed, amount: 1),
      ], reserve: 1000);
      putTokens(vault, nft, 1);
      final nftIx = await executeIx();
      expect(nftIx.accounts, hasLength(9), reason: 'NFT pays no fee');
      expect(addrs(nftIx)[7], AppConfig.programId);

      putVault([tier()]);
      expect((await executeIx()).accounts, hasLength(5), reason: 'none');

      putVault([tier()], reserve: 1000, reserveMint: key(41));
      expect((await executeIx()).accounts, hasLength(5), reason: 'old mint');
    });
  });

  group('claim quotes', () {
    Future<ClaimQuote> quote() => client.quoteClaim(
      claimer: alice,
      vaultOwner: owner,
      planId: 0,
      index: 0,
    );

    // 1 SOL pays 1.5% of 150 USD = 2.25 USD = 112.5 SKR from the reserve.
    const gross = 1000000000;
    const skrFee = 112500000;

    setUp(() {
      rpc.accounts[alice] = FakeAccount(systemProgramId, const []);
    });

    test('the reserve pays: the beneficiary gets the whole payout', () async {
      putVault([tier()], reserve: skrFee, lamports: gross + 2000000);
      putTokens(vault, skr, skrFee);
      pricesUp();
      expect((await quote()).net, gross);
    });

    test('otherwise the normal fee comes out of the payout', () async {
      const net = gross - gross * 200 ~/ 10000;
      void plan({int reserve = skrFee}) {
        putVault([tier()], reserve: reserve, lamports: gross + 2000000);
        putTokens(vault, skr, reserve);
      }

      plan(reserve: skrFee - 1);
      pricesUp();
      expect((await quote()).net, net, reason: 'reserve short');

      plan();
      post(PythFeedIds.skrUsd, 2000000, age: 121);
      expect((await quote()).net, net, reason: 'stale SKR price');

      pricesUp();
      post(PythFeedIds.solUsd, 15000000000, full: false);
      expect((await quote()).net, net, reason: 'partially verified');

      pricesUp();
      post(PythFeedIds.solUsd, 15000000000, owner: key(50));
      expect((await quote()).net, net, reason: 'not owned by the receiver');

      pricesUp();
      rpc.accounts.remove(ataAddress(treasury, skr));
      expect((await quote()).net, net, reason: 'no treasury SKR account');

      pricesUp();
      putTokens(vault, skr, skrFee, state: 2);
      expect((await quote()).net, net, reason: 'frozen reserve account');

      pricesUp();
      plan();
      rpc.accounts.remove(priceFeedPda(nativeMint).address);
      expect((await quote()).net, net, reason: 'SOL not registered');
      expect((await quote()).net, isNot(gross));

      pricesUp();
      expect((await quote()).net, gross, reason: 'all good again');
    });
  });

  group('fund and withdraw the reserve', () {
    test('fund: vault ATA, then fund_skr_reserve; refuses a short wallet or '
        'a reserve in an older mint', () async {
      putVault([tier()]);
      putTokens(owner, skr, 1000);
      final ixs = instructions(
        await client.buildFundSkrReserve(owner: owner, planId: 0, amount: 600),
      );
      expect(ixs, hasLength(2));
      expect(ixs.first.programId.toBase58(), ataProgramId);
      expect(ixs.last.data.toList(), [...Disc.fundSkrReserve, ...le(8, 600)]);

      await expectLater(
        client.buildFundSkrReserve(owner: owner, planId: 0, amount: 1001),
        throwsNamed('InsufficientTokens'),
      );
      putVault([tier()], reserve: 5, reserveMint: key(41));
      await expectLater(
        client.buildFundSkrReserve(owner: owner, planId: 0, amount: 10),
        throwsNamed('WrongAsset'),
      );
    });

    test('fund needs an SKR rate in the config', () async {
      rpc.accounts[configPda().address] = FakeAccount(
        AppConfig.programId,
        configBytes(admin: owner, treasury: treasury),
      );
      putVault([tier()]);
      await expectLater(
        client.buildFundSkrReserve(owner: owner, planId: 0, amount: 1),
        throwsNamed('NoSkrRate'),
      );
    });

    test(
      'withdraw: up to the reserve, from its own mint, not while locked',
      () async {
        putVault([tier()], reserve: 700, reserveMint: key(41));
        final ix = instructions(
          await client.buildWithdrawSkrReserve(
            owner: owner,
            planId: 0,
            amount: 700,
          ),
        ).last;
        expect(ix.data.toList(), [...Disc.withdrawSkrReserve, ...le(8, 700)]);
        expect(addrs(ix)[2], key(41));
        await expectLater(
          client.buildWithdrawSkrReserve(owner: owner, planId: 0, amount: 701),
          throwsNamed('InsufficientFunds'),
        );
        putVault([tier()], reserve: 700, lockedUntil: now + 60);
        await expectLater(
          client.buildWithdrawSkrReserve(owner: owner, planId: 0, amount: 1),
          throwsNamed('VaultLocked'),
        );
      },
    );

    test('token withdrawals stop at the reserve', () async {
      putVault([tier(mint: skr)], reserve: 700);
      putTokens(vault, skr, 1000);
      await client.buildWithdrawToken(
        owner: owner,
        planId: 0,
        mint: skr,
        amount: 300,
      );
      await expectLater(
        client.buildWithdrawToken(
          owner: owner,
          planId: 0,
          mint: skr,
          amount: 301,
        ),
        throwsNamed('FundsCommitted'),
      );
    });
  });

  group('plans created with a reserve', () {
    test(
      'create_plan, deposits, then fund_skr_reserve in one transaction',
      () async {
        putTokens(owner, skr, 1000);
        putTokens(owner, usdc, 50);
        rpc.accounts[guard] = FakeAccount(systemProgramId, const []);
        final ixs = instructions(
          await client.buildCreateVault(
            owner: owner,
            planId: 0,
            label: 'p',
            guard: guard,
            lockSecs: 3600,
            skipGraceSecs: 86400,
            rules: [tier(mint: usdc)],
            tokenDeposits: {usdc: 50},
            skrReserve: 400,
          ),
        );
        expect(ixs.last.data.toList(), [...Disc.fundSkrReserve, ...le(8, 400)]);
        expect(ixs[ixs.length - 2].programId.toBase58(), ataProgramId);
        expect(
          ixs[ixs.length - 2].accounts[1].pubKey.toBase58(),
          ataAddress(vault, skr),
        );
      },
    );

    test('an SKR deposit and the reserve share one vault ATA create, and '
        'must both fit the wallet', () async {
      putTokens(owner, skr, 1000);
      rpc.accounts[guard] = FakeAccount(systemProgramId, const []);
      Future<Uint8List> create(int deposit, int reserve) =>
          client.buildCreateVesting(
            owner: owner,
            planId: 0,
            label: 'v',
            guard: guard,
            lockSecs: 3600,
            startAt: now,
            revocable: true,
            schedules: [
              VestingSpec(
                beneficiary: alice,
                rail: Rail.solana,
                total: 600,
                cliffSecs: 0,
                durationSecs: 1000,
                mint: skr,
              ),
            ],
            tokenDeposits: {skr: deposit},
            skrReserve: reserve,
          );
      final ixs = instructions(await create(600, 400));
      final creates = ixs.where(
        (ix) =>
            ix.programId.toBase58() == ataProgramId &&
            ix.accounts[1].pubKey.toBase58() == ataAddress(vault, skr),
      );
      expect(creates, hasLength(1));
      expect(ixs.last.data.toList(), [...Disc.fundSkrReserve, ...le(8, 400)]);
      await expectLater(create(600, 401), throwsNamed('InsufficientTokens'));
    });
  });

  test(
    'closing withdraws the reserve first, then the rest of the token',
    () async {
      putVault([tier(mint: skr)], reserve: 700);
      putTokens(vault, skr, 1000);
      final ixs = instructions(
        await client.buildCloseVault(owner: owner, planId: 0),
      );
      final program = [
        for (final ix in ixs)
          if (ix.programId.toBase58() == AppConfig.programId) ix,
      ];
      expect(
        [for (final ix in program) ix.data.toList().sublist(0, 8)],
        [Disc.withdrawSkrReserve, Disc.withdrawToken, Disc.closeVault],
      );
      expect(program[0].data.toList().sublist(8), le(8, 700));
      expect(program[1].data.toList().sublist(8), le(8, 300));

      // A reserve in a mint no tier uses is returned as well.
      putVault([tier()], reserve: 50);
      putTokens(vault, skr, 50);
      final only = [
        for (final ix in instructions(
          await client.buildCloseVault(owner: owner, planId: 0),
        ))
          if (ix.programId.toBase58() == AppConfig.programId)
            ix.data.toList().sublist(0, 8),
      ];
      expect(only, [Disc.withdrawSkrReserve, Disc.closeVault]);
    },
  );
}
