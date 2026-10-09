import 'dart:convert';
import 'dart:typed_data';

import 'package:deadman/core/config.dart';
import 'package:deadman/kora/kora_client.dart';
import 'package:deadman/solana/codec.dart';
import 'package:deadman/solana/deadman_api.dart';
import 'package:deadman/solana/deadman_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:solana/base58.dart';
import 'package:solana/encoder.dart';
import 'package:solana/solana.dart'
    show
        Ed25519HDKeyPair,
        Ed25519HDPublicKey,
        JsonRpcException,
        verifySignature;

import '../kora/fake_kora.dart';
import 'helpers.dart';

void main() {
  final owner = key(1);
  final guard = key(2);
  final alice = key(3);
  final bob = key(4);
  final guardian = key(5);
  final usdc = key(6);
  final treasury = key(7);
  final executor = key(8);
  final vault = vaultPda(owner, 0).address;
  const now = 1790500000;
  const grace = 30 * 86400;

  RuleState rule({
    required String to,
    String? mint,
    int executedAt = 0,
    Rail rail = Rail.solana,
    int afterSecs = 172800,
    int skippedAt = 0,
    int reserved = 0,
  }) => RuleState(
    beneficiary: to,
    rail: rail,
    afterSecs: afterSecs,
    mint: mint,
    mode: AmountMode.percent,
    amount: 5000,
    executedAt: executedAt,
    paid: 0,
    skippedAt: skippedAt,
    reserved: reserved,
  );

  late FakeRpc rpc;
  late DeadmanClient client;

  setUp(() async {
    rpc = await FakeRpc.start();
    client = DeadmanClient.withKora(client: rpc.client(), clock: () => now);
    rpc.accounts
      ..[configPda().address] = FakeAccount(
        AppConfig.programId,
        configBytes(admin: owner, treasury: treasury),
      )
      ..[vault] = FakeAccount(
        AppConfig.programId,
        vaultBytes(
          owner: owner,
          guard: guard,
          guardian: guardian,
          ownerLastSeen: 1790172801,
          rules: [
            rule(to: alice, executedAt: 1790172801),
            rule(to: bob, mint: usdc, rail: Rail.zcash),
          ],
        ),
        lamports: 5000000000,
      )
      ..[usdc] = FakeAccount(tokenProgramId, mintBytes(6));
  });

  tearDown(() => rpc.close());

  List<(String, bool, bool)> keys(Uint8List tx) {
    final msg = Message.decompile(SignedTx.fromBytes(tx).compiledMessage);
    return [
      for (final ix in msg.instructions)
        for (final a in [
          AccountMeta.readonly(pubKey: ix.programId, isSigner: false),
          ...ix.accounts,
        ])
          (a.pubKey.toBase58(), a.isWriteable, a.isSigner),
    ];
  }

  List<Instruction> instructions(Uint8List tx) =>
      Message.decompile(SignedTx.fromBytes(tx).compiledMessage).instructions;

  /// Adds plan [planId] of [of] (default: owner) with the given rules.
  void addPlan(
    int planId,
    List<RuleState> rules, {
    String? of,
    String? label,
    int? ownerLastSeen,
  }) {
    final o = of ?? owner;
    rpc.accounts[vaultPda(o, planId).address] = FakeAccount(
      AppConfig.programId,
      vaultBytes(
        owner: o,
        planId: planId,
        label: label ?? 'plan $planId',
        guard: guard,
        ownerLastSeen: ownerLastSeen,
        rules: rules,
      ),
    );
  }

  final done = [rule(to: alice, executedAt: 1790172801)];
  final pending = [rule(to: alice)];

  test('fetchVault decodes and computes withdrawable lamports', () async {
    final v = await client.fetchVault(owner, 0);
    expect(v, isNotNull);
    expect(v!.address, vault);
    expect(v.planId, 0);
    expect(v.rules, hasLength(2));
    expect(v.withdrawableLamports, 5000000000 - rpc.rentExempt);
    expect(await client.fetchVault(alice, 0), isNull);
    expect(await client.fetchVault(owner, 1), isNull);
  });

  test('fetchVaults filters by owner at offset 8, sorted, uncached', () async {
    addPlan(7, pending);
    addPlan(2, done);
    addPlan(1, pending, of: alice);
    await client.fetchAllVaults();

    final plans = await client.fetchVaults(owner);
    expect(plans.map((v) => v.planId), [0, 2, 7]);
    expect(plans.map((v) => v.address), [
      vault,
      vaultPda(owner, 2).address,
      vaultPda(owner, 7).address,
    ]);
    expect(plans[1].label, 'plan 2');

    final filters = (rpc.programScans.last[1] as Map)['filters'] as List;
    expect(filters, [
      {
        'memcmp': {'offset': 0, 'bytes': base58encode(Disc.vaultAccount)},
      },
      {
        'memcmp': {'offset': 8, 'bytes': owner},
      },
    ]);

    await client.fetchVaults(owner);
    expect(
      rpc.calls.where((c) => c == 'getProgramAccounts'),
      hasLength(3),
      reason: 'one all-vault scan, then two fresh owner scans',
    );
    expect((await client.fetchVaults(alice)).single.planId, 1);
  });

  test('fetchVaults retries when rate limited', () async {
    rpc.throttleNext = 2;
    expect((await client.fetchVaults(owner)).single.address, vault);
  });

  test(
    'pulseWithGuard: one pulse per open plan, completed plans skipped',
    () async {
      final g = await Ed25519HDKeyPair.random();
      addPlan(3, done);
      addPlan(5, pending);
      await client.pulseWithGuard(g, vaultOwner: owner, planIds: [0, 3, 5, 5]);

      final tx = SignedTx.fromBytes(rpc.sent.single);
      expect(tx.compiledMessage.accountKeys.first.toBase58(), g.address);
      final ixs = instructions(rpc.sent.single);
      expect(ixs.map((i) => i.data.toList()), [Disc.pulse, Disc.pulse]);
      expect(ixs.map((i) => i.accounts[1].pubKey.toBase58()), [
        vault,
        vaultPda(owner, 5).address,
      ]);
      expect(ixs.first.accounts.first.isSigner, isTrue);
    },
  );

  test(
    'pulse throws PlanCompleted before sending when every plan is done',
    () async {
      final g = await Ed25519HDKeyPair.random();
      addPlan(3, done);
      addPlan(4, done);
      for (final send in [
        () => client.pulseWithGuard(g, vaultOwner: owner, planIds: [3, 4]),
        () => client.buildPulseByOwner(owner: owner, planIds: [3]),
      ]) {
        await expectLater(
          send(),
          throwsA(
            isA<DeadmanException>()
                .having((e) => e.name, 'name', 'PlanCompleted')
                .having((e) => e.code, 'code', 6015),
          ),
        );
      }
      expect(rpc.calls, isNot(contains('sendTransaction')));
      expect(rpc.calls, isNot(contains('getLatestBlockhash')));
    },
  );

  test('buildPulseByOwner skips completed plans', () async {
    addPlan(3, done);
    final ixs = instructions(
      await client.buildPulseByOwner(owner: owner, planIds: [3, 0]),
    );
    expect(ixs.single.accounts.map((a) => a.pubKey.toBase58()), [owner, vault]);
    expect(ixs.single.data.toList(), Disc.pulse);
  });

  test(
    'buildLockdownByOwner signs with the owner for every listed plan',
    () async {
      final ixs = instructions(
        await client.buildLockdownByOwner(owner: owner, planIds: [0, 3, 0]),
      );
      expect(ixs.map((i) => i.data.toList()), [Disc.lockdown, Disc.lockdown]);
      expect(ixs.map((i) => i.accounts.first.pubKey.toBase58()), [
        owner,
        owner,
      ]);
      expect(ixs.map((i) => i.accounts[1].pubKey.toBase58()), [
        vault,
        vaultPda(owner, 3).address,
      ]);
    },
  );

  test('lockdownWithGuard and buildSetGuard cover every listed plan', () async {
    final g = await Ed25519HDKeyPair.random();
    await client.lockdownWithGuard(g, vaultOwner: owner, planIds: [0, 3]);
    final lock = instructions(rpc.sent.single);
    expect(lock.map((i) => i.data.toList()), [Disc.lockdown, Disc.lockdown]);
    expect(lock.map((i) => i.accounts[1].pubKey.toBase58()), [
      vault,
      vaultPda(owner, 3).address,
    ]);

    final newGuard = key(9);
    final set = instructions(
      await client.buildSetGuard(
        owner: owner,
        planIds: [0, 1, 2],
        newGuard: newGuard,
      ),
    );
    expect(set, hasLength(3));
    for (final (i, ix) in set.indexed) {
      expect(ix.data.toList(), encodeSetGuard(newGuard));
      expect(ix.accounts.map((a) => a.pubKey.toBase58()), [
        owner,
        vaultPda(owner, i).address,
      ]);
    }
    expect(
      () => client.buildSetGuard(owner: owner, planIds: [], newGuard: newGuard),
      throwsArgumentError,
    );
  });

  List<(String, bool, bool)> metas(Instruction ix) => [
    for (final a in ix.accounts)
      (a.pubKey.toBase58(), a.isWriteable, a.isSigner),
  ];

  /// Account keys only: a decompiled message merges each key's flags across
  /// instructions (exact per-instruction flags are checked in codec_test).
  List<String> addrs(Instruction ix) => [
    for (final a in ix.accounts) a.pubKey.toBase58(),
  ];

  group('buildCreateVault', () {
    Future<List<Instruction>> create(
      int planId, {
      String label = 'Kids',
    }) async => instructions(
      await client.buildCreateVault(
        owner: owner,
        planId: planId,
        label: label,
        guard: guard,
        lockSecs: 3600,
        skipGraceSecs: grace,
        rules: [rule(to: alice)],
        depositLamports: 1000,
      ),
    );

    test('funds an empty guard key with the first plan', () async {
      final ixs = await create(0);
      expect(ixs, hasLength(3));
      expect(ixs[0].programId.toBase58(), systemProgramId);
      expect(ixs[0].accounts[1].pubKey.toBase58(), guard);
      expect(ixs[1].accounts.map((a) => a.pubKey.toBase58()), [
        owner,
        owner,
        vault,
        systemProgramId,
      ]);
      expect(ixs[1].data.toList().sublist(8, 10), [0, 0]);
    });

    test('names each rule mint once as a read-only remaining account; a '
        'Token-2022 mint is refused before signing', () async {
      final ixs = instructions(
        await client.buildCreateVault(
          owner: owner,
          planId: 0,
          label: 'Kids',
          guard: guard,
          lockSecs: 3600,
          skipGraceSecs: grace,
          rules: [
            rule(to: alice),
            rule(to: bob, mint: usdc),
            rule(to: alice, mint: usdc, afterSecs: 172801),
          ],
        ),
      );
      final create = ixs.firstWhere(
        (ix) => hasDiscriminator(ix.data.toList(), Disc.createPlan),
      );
      expect(create.accounts, hasLength(5));
      expect(create.accounts[4].pubKey.toBase58(), usdc);
      expect(create.accounts[4].isWriteable, isFalse);

      final t22 = key(31);
      rpc.accounts[t22] = FakeAccount(token2022ProgramId, mintBytes(6));
      await expectLater(
        client.buildCreateVault(
          owner: owner,
          planId: 0,
          label: 'Kids',
          guard: guard,
          lockSecs: 3600,
          skipGraceSecs: grace,
          rules: [rule(to: bob, mint: t22)],
        ),
        throwsA(
          isA<DeadmanException>().having(
            (e) => e.message,
            'message',
            contains('Token-2022'),
          ),
        ),
      );
    });

    test('without Kora the owner is the rent payer and fee payer', () async {
      final tx = await client.buildCreateVault(
        owner: owner,
        planId: 0,
        label: 'Kids',
        guard: guard,
        lockSecs: 3600,
        skipGraceSecs: grace,
        rules: [rule(to: alice)],
      );
      final msg = SignedTx.fromBytes(tx).compiledMessage;
      expect(msg.requiredSignatureCount, 1);
      expect(msg.accountKeys.first.toBase58(), owner);
      expect(keys(tx).where((k) => k.$1 == owner).toSet(), {
        (owner, true, true),
      });
    });

    test('skips guard funding for a second plan', () async {
      rpc.accounts[guard] = FakeAccount(
        systemProgramId,
        const [],
        lamports: AppConfig.guardFundingLamports,
      );
      final ixs = await create(7);
      expect(ixs, hasLength(2));
      expect(ixs[0].programId.toBase58(), AppConfig.programId);
      expect(ixs[0].accounts[2].pubKey.toBase58(), vaultPda(owner, 7).address);
      expect(ixs[0].data.toList().sublist(0, 8), Disc.createPlan);
      expect(ixs[0].data.toList().sublist(8, 14), [7, 0, 4, 0, 0, 0]);
      expect(ixs[0].data.toList().sublist(14 + 4 + 32, 14 + 4 + 32 + 16), [
        ...le(8, 3600),
        ...le(8, grace),
      ]);
      expect(ixs[1].accounts[1].pubKey.toBase58(), vaultPda(owner, 7).address);
    });

    test('tokenDeposits: vault ATA and TransferChecked after the create, '
        'empty deposits dropped', () async {
      final other = key(40);
      rpc.accounts[other] = FakeAccount(tokenProgramId, mintBytes(0));
      // A 0-decimal deposit (NFT-like) is checked against the owner's ATA.
      rpc.accounts[ataAddress(owner, other)] = FakeAccount(
        tokenProgramId,
        tokenAccountBytes(mint: other, owner: owner, amount: 7),
      );
      final ixs = instructions(
        await client.buildCreateVault(
          owner: owner,
          planId: 0,
          label: 'Kids',
          guard: guard,
          lockSecs: 3600,
          skipGraceSecs: grace,
          rules: [rule(to: alice, mint: usdc)],
          depositLamports: 1000,
          tokenDeposits: {usdc: 2500000, other: 7, key(41): 0},
        ),
      );
      expect(ixs, hasLength(7));
      expect(ixs[1].data.toList().sublist(0, 8), Disc.createPlan);
      expect(ixs[2].programId.toBase58(), systemProgramId);
      expect(ixs[2].accounts[1].pubKey.toBase58(), vault);
      for (final (i, mint, amount, decimals) in [
        (3, usdc, 2500000, 6),
        (5, other, 7, 0),
      ]) {
        expect(ixs[i].programId.toBase58(), ataProgramId);
        expect(metas(ixs[i]).take(2), [
          (owner, true, true),
          (ataAddress(vault, mint), true, false),
        ]);
        expect(ixs[i + 1].programId.toBase58(), tokenProgramId);
        expect(addrs(ixs[i + 1]), [
          ataAddress(owner, mint),
          mint,
          ataAddress(vault, mint),
          owner,
        ]);
        expect(ixs[i + 1].data.toList(), [12, ...le(8, amount), decimals]);
      }
    });

    test(
      'tokenDeposits: a Token-2022 mint is refused before signing',
      () async {
        rpc.accounts[usdc] = FakeAccount(token2022ProgramId, mintBytes(6));
        await expectLater(
          client.buildCreateVault(
            owner: owner,
            planId: 0,
            label: 'Kids',
            guard: guard,
            lockSecs: 3600,
            skipGraceSecs: grace,
            rules: [rule(to: alice, mint: usdc)],
            tokenDeposits: {usdc: 1},
          ),
          throwsA(
            isA<DeadmanException>().having(
              (e) => e.message,
              'message',
              contains('Token-2022'),
            ),
          ),
        );
        expect(rpc.calls, isNot(contains('getLatestBlockhash')));
      },
    );

    test('rejects labels over 32 bytes before building', () async {
      await expectLater(
        create(1, label: 'ã' * 17),
        throwsA(
          isA<DeadmanException>().having((e) => e.name, 'name', 'LabelTooLong'),
        ),
      );
      await expectLater(
        client.buildUpdatePolicy(
          owner: owner,
          planId: 0,
          label: 'x' * 33,
          lockSecs: 3600,
          skipGraceSecs: grace,
          rules: [rule(to: alice)],
        ),
        throwsA(isA<DeadmanException>().having((e) => e.code, 'code', 6016)),
      );
      expect(rpc.calls, isEmpty);
    });
  });

  test('retries requests whose connection was dropped', () async {
    rpc.dropNext = 2;
    final fees = await client.fetchFees();
    expect(fees.treasury, treasury);
  });

  test('resends while a lagging node does not know the blockhash', () async {
    rpc.blockhashMisses = 2;
    final sigs = await client.sendSigned([Uint8List(8)]);
    expect(sigs, hasLength(1));
    expect(rpc.calls.where((c) => c == 'sendTransaction'), hasLength(3));
  });

  test('reports an expired blockhash clearly', () async {
    rpc.blockhashMisses = DeadmanClient.blockhashRetries;
    await expectLater(
      client.sendSigned([Uint8List(8)]),
      throwsA(
        isA<DeadmanException>().having(
          (e) => e.name,
          'name',
          'BlockhashExpired',
        ),
      ),
    );
  });

  test('backs off and retries when rate limited', () async {
    rpc.throttleNext = 2;
    expect((await client.fetchFees()).treasury, treasury);
  });

  test('reports persistent rate limiting clearly', () async {
    rpc.throttleNext = DeadmanClient.netRetries;
    await expectLater(
      client.fetchFees(),
      throwsA(
        isA<DeadmanException>().having((e) => e.name, 'name', 'RateLimited'),
      ),
    );
  });

  test('watched-vault lookups share one program scan', () async {
    await Future.wait([
      client.fetchWatchedVaults(alice),
      client.fetchWatchedVaults(bob),
    ]);
    await client.fetchWatchedVaults(guardian);
    expect(rpc.calls.where((c) => c == 'getProgramAccounts'), hasLength(1));
  });

  test('explains an unfunded fee payer', () {
    final e = DeadmanException.fromRpc(
      JsonRpcException('Transaction simulation failed', -32002, {
        'err': 'AccountNotFound',
        'logs': <String>[],
      }),
    );
    expect(e.name, 'NoFunds');
    expect(e.message, contains('no SOL'));
  });

  test('nextFreePlanId counts plans this version cannot decode', () async {
    // An older-layout plan 3 at its real address: same discriminator,
    // owner and plan id, but a shorter body.
    final old = Uint8List(996)
      ..setAll(0, Disc.vaultAccount)
      ..setAll(8, base58decode(owner))
      ..setAll(40, [3, 0]);
    rpc.accounts[vaultPda(owner, 3).address] = FakeAccount(
      AppConfig.programId,
      old,
    );
    expect(await client.nextFreePlanId(owner), 4);
  });

  test('older-layout plans are hidden, listed and recoverable', () async {
    Uint8List old(String of, int planId, int len) => Uint8List(len)
      ..setAll(0, Disc.vaultAccount)
      ..setAll(8, base58decode(of))
      ..setAll(40, [planId & 0xff, planId >> 8]);
    final legacy = vaultPda(owner, 42801).address;
    rpc.accounts[legacy] = FakeAccount(
      AppConfig.programId,
      old(owner, 42801, 1318),
    );
    rpc.accounts[vaultPda(owner, 1).address] = FakeAccount(
      AppConfig.programId,
      old(owner, 1, 958),
    );
    // Bytes naming plan 9 at another address are not that plan.
    rpc.accounts[vaultPda(owner, 8).address] = FakeAccount(
      AppConfig.programId,
      old(owner, 9, 996),
    );
    rpc.accounts[vaultPda(bob, 2).address] = FakeAccount(
      AppConfig.programId,
      old(bob, 2, 958),
    );

    expect(await client.fetchLegacyPlanIds(owner), [1, 42801]);
    expect(await client.fetchVault(owner, 42801), isNull);
    expect(
      (await client.fetchVaults(owner)).map((v) => v.planId),
      isNot(contains(42801)),
    );

    final ix = instructions(
      await client.buildRecoverLegacyVault(owner: owner, planId: 42801),
    ).single;
    expect(ix.data.toList(), [...Disc.recoverLegacyVault, 0x31, 0xa7]);
    expect(ix.accounts.map((a) => a.pubKey.toBase58()), [owner, legacy]);
    await expectLater(
      client.buildRecoverLegacyVault(owner: owner, planId: 0),
      throwsA(
        isA<DeadmanException>().having((e) => e.name, 'name', 'NotLegacyVault'),
      ),
    );
  });

  test('a System program refusal reads as plain text', () {
    final e = DeadmanException.fromRpc(
      JsonRpcException('Transaction simulation failed', -32002, {
        'err': {
          'InstructionError': [
            1,
            {'Custom': 0},
          ],
        },
        'logs': [
          'Allocate: account Address { address: X, base: None } already in use',
          'Program 11111111111111111111111111111111 failed: custom program error: 0x0',
        ],
      }),
    );
    expect(e.message, contains('already exists'));
  });

  test('fetchFees reads Config', () async {
    final fees = await client.fetchFees();
    expect(fees.treasury, treasury);
    expect(fees.feeBpsPublic, 200);
    expect(fees.feeBpsPrivate, 300);
  });

  test('fetchWatchedVaults matches beneficiaries and the guardian', () async {
    expect((await client.fetchWatchedVaults(bob)).single.address, vault);
    expect((await client.fetchWatchedVaults(guardian)).single.owner, owner);
    expect(await client.fetchWatchedVaults(guard), isEmpty);
    expect(await client.fetchWatchedVaults(executor), isEmpty);
  });

  test('tokenBalance reads the ATA and returns 0 when missing', () async {
    expect(await client.tokenBalance(alice, usdc), 0);
    rpc.accounts[ataAddress(alice, usdc)] = FakeAccount(
      tokenProgramId,
      tokenAccountBytes(mint: usdc, owner: alice, amount: 4200),
    );
    expect(await client.tokenBalance(alice, usdc), 4200);
  });

  test('buildExecuteRule refuses a token tier the vault cannot pay', () async {
    await expectLater(
      client.buildExecuteRule(
        executor: executor,
        vaultOwner: owner,
        planId: 0,
        index: 1,
      ),
      throwsA(
        isA<DeadmanException>().having((e) => e.name, 'name', 'NothingToPay'),
      ),
    );
  });

  test('buildExecuteRule picks the token variant and prepends the treasury '
      'and beneficiary ATA creates', () async {
    rpc.accounts[ataAddress(vaultPda(owner, 0).address, usdc)] = FakeAccount(
      tokenProgramId,
      tokenAccountBytes(
        mint: usdc,
        owner: vaultPda(owner, 0).address,
        amount: 500,
      ),
    );
    final tx = await client.buildExecuteRule(
      executor: executor,
      vaultOwner: owner,
      planId: 0,
      index: 1,
    );
    final msg = Message.decompile(SignedTx.fromBytes(tx).compiledMessage);
    expect(msg.instructions, hasLength(3));
    expect(
      [
        for (final ix in msg.instructions.take(2))
          (ix.programId.toBase58(), ix.accounts[1].pubKey.toBase58()),
      ],
      [
        (ataProgramId, ataAddress(treasury, usdc)),
        (ataProgramId, ataAddress(bob, usdc)),
      ],
    );
    final exec = msg.instructions[2];
    expect(exec.data.toList(), [...Disc.executeTokenRule, 1]);
    expect(exec.accounts, hasLength(9));
    expect(exec.accounts[3].isWriteable, isTrue, reason: 'mint, for burns');
    expect(exec.accounts[6].pubKey.toBase58(), ataAddress(bob, usdc));
    expect(exec.accounts[7].pubKey.toBase58(), ataAddress(treasury, usdc));
    expect(
      exec.accounts.map((a) => a.pubKey.toBase58()),
      isNot(anyOf(contains(ataProgramId), contains(systemProgramId))),
    );
    expect(keys(tx).first, (ataProgramId, false, false));
    expect(
      SignedTx.fromBytes(tx).compiledMessage.accountKeys.first.toBase58(),
      executor,
    );
  });

  test(
    'buildExecuteRule rejects executed, out-of-range and Token-2022 rules',
    () async {
      await expectLater(
        client.buildExecuteRule(
          executor: executor,
          vaultOwner: owner,
          planId: 0,
          index: 0,
        ),
        throwsA(
          isA<DeadmanException>().having(
            (e) => e.name,
            'name',
            'RuleAlreadyExecuted',
          ),
        ),
      );
      await expectLater(
        client.buildExecuteRule(
          executor: executor,
          vaultOwner: owner,
          planId: 0,
          index: 2,
        ),
        throwsA(
          isA<DeadmanException>().having(
            (e) => e.name,
            'name',
            'InvalidRuleIndex',
          ),
        ),
      );
      rpc.accounts[usdc] = FakeAccount(token2022ProgramId, mintBytes(6));
      await expectLater(
        client.buildExecuteRule(
          executor: executor,
          vaultOwner: owner,
          planId: 0,
          index: 1,
        ),
        throwsA(isA<DeadmanException>()),
      );
    },
  );

  test('buildExecuteRule SOL variant pays the config treasury', () async {
    rpc.accounts[vault] = FakeAccount(
      AppConfig.programId,
      vaultBytes(
        owner: owner,
        guard: guard,
        rules: [rule(to: alice)],
      ),
    );
    final tx = await client.buildExecuteRule(
      executor: executor,
      vaultOwner: owner,
      planId: 0,
      index: 0,
    );
    final ix = Message.decompile(SignedTx.fromBytes(tx).compiledMessage)
        .instructions
        .single;
    expect(ix.data.toList(), [...Disc.executeSolRule, 0]);
    expect(ix.accounts.map((a) => a.pubKey.toBase58()), [
      executor,
      vault,
      configPda().address,
      alice,
      treasury,
    ]);
  });

  test('tokenBalances batches lookups, 0 for missing accounts', () async {
    rpc.accounts[ataAddress(vault, usdc)] = FakeAccount(
      tokenProgramId,
      tokenAccountBytes(mint: usdc, owner: vault, amount: 4200),
    );
    rpc.calls.clear();
    final got = await client.tokenBalances([
      (vault, usdc),
      (vault, key(40)),
      (owner, usdc),
    ]);
    expect(got, [4200, 0, 0]);
    expect(rpc.calls, ['getMultipleAccounts']);
    expect(await client.tokenBalances(const []), isEmpty);
  });

  test('buildDepositToken reads decimals from the mint', () async {
    final tx = await client.buildDepositToken(
      owner: owner,
      planId: 0,
      mint: usdc,
      amount: 1000000,
    );
    final ixs = Message.decompile(SignedTx.fromBytes(tx).compiledMessage)
        .instructions;
    expect(ixs, hasLength(2));
    expect(ixs[1].data.toList(), [12, ...le(8, 1000000), 6]);
  });

  test('build methods validate policy before signing', () async {
    await expectLater(
      client.buildCreateVault(
        owner: owner,
        planId: 0,
        label: '',
        guard: guard,
        lockSecs: 3600,
        skipGraceSecs: grace,
        rules: [rule(to: guard)],
      ),
      throwsA(isA<DeadmanException>().having((e) => e.code, 'code', 6003)),
    );
    final tx = await client.buildUpdatePolicy(
      owner: owner,
      planId: 0,
      label: 'Kids',
      lockSecs: 3600,
      skipGraceSecs: grace,
      rules: [rule(to: alice)],
      guardian: guardian,
    );
    expect(tx[0], 1);
  });

  group('buildUpdatePolicy', () {
    Future<Uint8List> update(
      List<RuleSpec> rules, {
      int planId = 0,
      int skipGraceSecs = grace,
    }) => client.buildUpdatePolicy(
      owner: owner,
      planId: planId,
      label: 'Kids',
      lockSecs: 3600,
      skipGraceSecs: skipGraceSecs,
      rules: rules,
    );
    DeadmanException code(int c) => DeadmanException.program(c);
    Matcher fails(int c) => throwsA(
      isA<DeadmanException>()
          .having((e) => e.code, 'code', c)
          .having((e) => e.name, 'name', code(c).name),
    );

    test(
      'names the new rules\' mints as read-only remaining accounts',
      () async {
        final ix = instructions(await update([rule(to: bob, mint: usdc)]))
            .single;
        expect(ix.accounts.map((a) => (a.pubKey.toBase58(), a.isWriteable)), [
          (owner, true),
          (vault, true),
          (usdc, false),
        ]);
        expect(
          instructions(await update([rule(to: bob)])).single.accounts,
          hasLength(2),
        );
      },
    );

    test('encodes the grace period after the lock duration', () async {
      final ix = instructions(await update([rule(to: bob)])).single;
      final data = ix.data.toList();
      expect(data.sublist(0, 8), Disc.updatePlan);
      expect(data.sublist(8, 8 + 4 + 4 + 16), [
        ...le(4, 4),
        ...'Kids'.codeUnits,
        ...le(8, 3600),
        ...le(8, grace),
      ]);
      expect(ix.accounts.map((a) => a.pubKey.toBase58()), [owner, vault]);
    });

    test('released tiers count toward the cap; a fully released plan is '
        'final', () async {
      addPlan(4, [
        for (var i = 0; i < 6; i++) rule(to: alice, executedAt: 1790172801),
        rule(to: bob),
      ]);
      await expectLater(
        update(List.filled(3, rule(to: bob)), planId: 4),
        fails(6003),
      );
      expect(
        instructions(await update(List.filled(2, rule(to: bob)), planId: 4)),
        hasLength(1),
      );

      addPlan(5, List.filled(8, rule(to: alice, executedAt: 1790172801)));
      await expectLater(
        update([rule(to: bob)], planId: 5),
        fails(6015),
        reason: 'the program refuses any change to a released plan',
      );
    });

    test('rejects grace out of range, the vault or guard as beneficiary, '
        'and a missing plan, before building', () async {
      await expectLater(
        update([rule(to: bob)], skipGraceSecs: 59),
        fails(6002),
      );
      await expectLater(
        update([rule(to: bob)], skipGraceSecs: 366 * 86400 + 1),
        fails(6002),
      );
      await expectLater(update([rule(to: vault)]), fails(6003));
      await expectLater(
        update([rule(to: guard)]),
        fails(6003),
        reason: 'guard read from the vault',
      );
      await expectLater(
        update([rule(to: bob)], planId: 9),
        throwsA(isA<DeadmanException>()),
      );
      expect(rpc.calls, isNot(contains('getLatestBlockhash')));
    });
  });

  group('skip_rule', () {
    List<(String, bool, bool)> metas(Instruction ix) => [
      for (final a in ix.accounts)
        (a.pubKey.toBase58(), a.isWriteable, a.isSigner),
    ];

    test('buildSkipRule token tier: caller pays and signs, vault writable, '
        'vault ATA as vault_token', () async {
      addPlan(2, [
        rule(to: alice, executedAt: 1790172801),
        rule(to: bob, mint: usdc),
        rule(to: bob, mint: usdc, afterSecs: 172900),
      ]);
      rpc.accounts[ataAddress(vaultPda(owner, 2).address, usdc)] = FakeAccount(
        tokenProgramId,
        tokenAccountBytes(
          mint: usdc,
          owner: vaultPda(owner, 2).address,
          amount: 0,
        ),
      );
      final tx = await client.buildSkipRule(
        caller: executor,
        vaultOwner: owner,
        planId: 2,
        index: 1,
      );
      final msg = SignedTx.fromBytes(tx).compiledMessage;
      expect(msg.accountKeys.first.toBase58(), executor);
      final ix = instructions(tx).single;
      expect(ix.programId.toBase58(), AppConfig.programId);
      expect(ix.data.toList(), [...Disc.skipRule, 1]);
      final plan = vaultPda(owner, 2).address;
      expect(metas(ix), [
        (executor, true, true),
        (plan, true, false),
        (ataAddress(plan, usdc), false, false),
      ], reason: 'the caller is writable only as fee payer');
      for (final (index, name) in [
        (0, 'RuleAlreadyExecuted'),
        (2, 'RuleOutOfOrder'),
        (3, 'InvalidRuleIndex'),
      ]) {
        await expectLater(
          client.buildSkipRule(
            caller: executor,
            vaultOwner: owner,
            planId: 2,
            index: index,
          ),
          throwsA(isA<DeadmanException>().having((e) => e.name, 'name', name)),
        );
      }
    });

    test('buildSkipRule creates the token account of a plan that never '
        'held the mint, paid by the caller', () async {
      addPlan(2, [rule(to: bob, mint: usdc)]);
      final ixs = instructions(
        await client.buildSkipRule(
          caller: executor,
          vaultOwner: owner,
          planId: 2,
          index: 0,
        ),
      );
      final plan = vaultPda(owner, 2).address;
      expect(ixs, hasLength(2));
      expect(ixs[0].programId.toBase58(), ataProgramId);
      expect(metas(ixs[0]).take(2), [
        (executor, true, true),
        (ataAddress(plan, usdc), true, false),
      ]);
      expect(ixs[1].data.toList(), [...Disc.skipRule, 0]);
    });

    test('buildSkipRule SOL tier passes the program id for vault_token; a '
        'skipped tier counts as settled and is never skipped again', () async {
      addPlan(4, [
        rule(to: alice, skippedAt: now - 10, reserved: 99),
        rule(to: bob, afterSecs: 172900),
      ]);
      final plan = vaultPda(owner, 4).address;
      final ix = instructions(
        await client.buildSkipRule(
          caller: executor,
          vaultOwner: owner,
          planId: 4,
          index: 1,
        ),
      ).single;
      expect(ix.data.toList(), [...Disc.skipRule, 1]);
      expect(metas(ix), [
        (executor, true, true),
        (plan, true, false),
        (AppConfig.programId, false, false),
      ]);
      await expectLater(
        client.buildSkipRule(
          caller: executor,
          vaultOwner: owner,
          planId: 4,
          index: 0,
        ),
        throwsA(
          isA<DeadmanException>().having(
            (e) => e.name,
            'name',
            'RuleAlreadyExecuted',
          ),
        ),
      );
    });

    test('a skipped tier stays claimable: buildExecuteRule pays it', () async {
      addPlan(4, [
        rule(to: alice, skippedAt: now - 10, reserved: 99),
        rule(to: bob, afterSecs: 172900),
      ]);
      final ix = instructions(
        await client.buildExecuteRule(
          executor: alice,
          vaultOwner: owner,
          planId: 4,
          index: 0,
        ),
      ).single;
      expect(ix.data.toList(), [...Disc.executeSolRule, 0]);
      expect(ix.accounts[3].pubKey.toBase58(), alice);
    });

    test('skipRuleWithKey signs and sends through our RPC, never the '
        'sponsor', () async {
      final sponsorNode = FakeKora();
      final c = DeadmanClient.withKora(
        client: rpc.client(),
        sponsor: sponsorNode.client(),
        clock: () => now,
      );
      final keeper = await Ed25519HDKeyPair.random();
      await c.skipRuleWithKey(keeper, vaultOwner: owner, planId: 0, index: 1);
      final tx = SignedTx.fromBytes(rpc.sent.single);
      expect(tx.compiledMessage.accountKeys.first.toBase58(), keeper.address);
      final ixs = instructions(rpc.sent.single);
      // The plan never held USDC: the keeper creates its empty account first.
      expect(ixs.first.programId.toBase58(), ataProgramId);
      final ix = ixs.last;
      expect(ix.data.toList(), [...Disc.skipRule, 1]);
      expect(
        ix.accounts[2].pubKey.toBase58(),
        ataAddress(vault, usdc),
        reason: 'token tier passes the vault ATA',
      );
      expect(sponsorNode.calls, isEmpty);
    });
  });

  group('guard pulse pre-check', () {
    const year = VaultState.guardWindowSecs;

    test('skips plans that need an owner check-in', () async {
      final g = await Ed25519HDKeyPair.random();
      // Plan 5: a tier released after the owner was last seen.
      addPlan(5, [rule(to: alice, executedAt: 1790172801), rule(to: bob)]);
      // Plan 6: the owner has been silent for more than a year.
      addPlan(6, pending, ownerLastSeen: now - year - 1);
      addPlan(7, pending, ownerLastSeen: now - year);
      // Plan 8: a tier was skipped after the owner was last seen.
      addPlan(8, [rule(to: alice, skippedAt: 1790172801), rule(to: bob)]);
      await client.pulseWithGuard(
        g,
        vaultOwner: owner,
        planIds: [0, 5, 6, 7, 8],
      );
      expect(instructions(rpc.sent.single).map((i) => i.accounts[1].pubKey), [
        Ed25519HDPublicKey.fromBase58(vault),
        Ed25519HDPublicKey.fromBase58(vaultPda(owner, 7).address),
      ]);
    });

    test('throws OwnerConfirmationRequired naming the plans when none is '
        'left; the owner wallet may still pulse', () async {
      final g = await Ed25519HDKeyPair.random();
      addPlan(5, [
        rule(to: alice, executedAt: 1790172801),
        rule(to: bob),
      ], label: 'Kids');
      addPlan(6, pending, ownerLastSeen: now - year - 1, label: '');
      addPlan(3, done);
      await expectLater(
        client.pulseWithGuard(g, vaultOwner: owner, planIds: [3, 5, 6]),
        throwsA(
          isA<DeadmanException>()
              .having((e) => e.name, 'name', 'OwnerConfirmationRequired')
              .having((e) => e.code, 'code', 6017)
              .having((e) => e.message, 'message', contains('Kids, plan 6')),
        ),
      );
      expect(rpc.calls, isNot(contains('sendTransaction')));

      final ixs = instructions(
        await client.buildPulseByOwner(owner: owner, planIds: [5, 6]),
      );
      expect(ixs, hasLength(2));
    });
  });

  group('sendSigned de-duplication', () {
    Future<Uint8List> signedTx(Ed25519HDKeyPair wallet) async => partiallySign(
      await client.buildDeposit(
        owner: wallet.address,
        planId: 0,
        lamports: 1000,
      ),
      wallet,
    );
    int sends() => rpc.calls.where((c) => c == 'sendTransaction').length;

    test('a re-tap with the same signed bytes awaits the first send', () async {
      final wallet = await Ed25519HDKeyPair.random();
      final tx = await signedTx(wallet);
      final results = await Future.wait([
        client.sendSigned([tx]),
        client.sendSigned([Uint8List.fromList(tx)]),
      ]);
      expect(results[0], results[1]);
      expect(sends(), 1);

      expect(await client.sendSigned([tx]), results[0]);
      expect(sends(), 1, reason: 'confirmed moments ago');

      rpc.blockhash = key(98);
      await client.sendSigned([await signedTx(wallet)]);
      expect(sends(), 2, reason: 'different bytes');
    });

    test('after a failed send the same bytes may be sent again', () async {
      final tx = await signedTx(await Ed25519HDKeyPair.random());
      rpc.blockhashMisses = DeadmanClient.blockhashRetries;
      await expectLater(
        client.sendSigned([tx]),
        throwsA(
          isA<DeadmanException>().having(
            (e) => e.name,
            'name',
            'BlockhashExpired',
          ),
        ),
      );
      final before = sends();
      expect(await client.sendSigned([tx]), hasLength(1));
      expect(sends(), before + 1);
    });
  });

  group('Kora', () {
    late FakeKora sponsorNode;

    setUp(() {
      sponsorNode = FakeKora(signer: key(60), paymentAddress: key(60));
    });

    DeadmanClient koraClient([KoraClient? sponsor]) => DeadmanClient.withKora(
      client: rpc.client(),
      sponsor: sponsor ?? sponsorNode.client(),
      clock: () => now,
    );

    /// A sponsor whose every call gets [status] and [body].
    KoraClient brokenSponsor(int status, String body) => KoraClient(
      Uri.parse('https://kora.test'),
      httpClient: MockClient((_) async => http.Response(body, status)),
    );

    void expectGuardPaid(Ed25519HDKeyPair g, List<int> disc) {
      final tx = SignedTx.fromBytes(rpc.sent.single);
      expect(tx.compiledMessage.requiredSignatureCount, 1);
      expect(tx.compiledMessage.accountKeys.first.toBase58(), g.address);
      expect(instructions(rpc.sent.single).single.data.toList(), disc);
    }

    Future<bool> signed(SignedTx tx, int slot, String by) => verifySignature(
      message: tx.compiledMessage.toByteArray().toList(),
      signature: tx.signatures[slot].bytes,
      publicKey: Ed25519HDPublicKey.fromBase58(by),
    );

    test('the default constructor has no Kora without dart-defines', () {
      expect(AppConfig.koraSponsorUrl, isEmpty);
      final c = DeadmanClient(rpc.client());
      expect(c.sponsor, isNull);
    });

    test(
      'guard pulse: sponsor pays, guard signs its slot, sponsor sends',
      () async {
        final g = await Ed25519HDKeyPair.random();
        final c = koraClient();
        final sig = await c.pulseWithGuard(g, vaultOwner: owner, planIds: [0]);
        expect(sig, startsWith('kora'));
        expect(c.lastSendUsedFallback, isFalse);

        final sent = sponsorNode.paramsOf('signAndSendTransaction').single;
        expect(sent['signer_key'], sponsorNode.signer);
        final tx = SignedTx.decode(sent['transaction'] as String);
        final msg = tx.compiledMessage;
        expect(msg.requiredSignatureCount, 2);
        expect(msg.accountKeys[0].toBase58(), sponsorNode.signer);
        expect(msg.accountKeys[1].toBase58(), g.address);
        expect(msg.recentBlockhash, sponsorNode.blockhash);
        expect(tx.signatures[0].bytes, List.filled(64, 0));
        expect(await signed(tx, 1, g.address), isTrue);
        final ixs = Message.decompile(msg).instructions;
        expect(ixs.single.data.toList(), Disc.pulse);
        expect(
          ixs.any((i) => i.programId.toBase58() == systemProgramId),
          isFalse,
        );

        expect(rpc.calls, isNot(contains('sendTransaction')));
        expect(rpc.calls, isNot(contains('getLatestBlockhash')));
        expect(rpc.calls, contains('getSignatureStatuses'));
      },
    );

    test(
      'guard lockdown resends while Kora does not know the blockhash',
      () async {
        sponsorNode.blockhashMisses = 2;
        final g = await Ed25519HDKeyPair.random();
        await koraClient().lockdownWithGuard(
          g,
          vaultOwner: owner,
          planIds: [0],
        );
        expect(sponsorNode.paramsOf('signAndSendTransaction'), hasLength(3));
      },
    );

    test('Kora simulation failures map to Deadman program errors', () async {
      sponsorNode.failNextSend =
          'Invalid transaction: Transaction simulation failed: Error '
          'processing Instruction 0: custom program error: 0x1777';
      final g = await Ed25519HDKeyPair.random();
      final c = koraClient();
      await expectLater(
        c.pulseWithGuard(g, vaultOwner: owner, planIds: [0]),
        throwsA(
          isA<DeadmanException>()
              .having((e) => e.name, 'name', 'RuleNotDue')
              .having((e) => e.code, 'code', 6007),
        ),
      );
      expect(rpc.sent, isEmpty, reason: 'the guard would fail the same way');
      expect(c.lastSendUsedFallback, isFalse);
    });

    test('drained sponsor: the guard pays its own pulse', () async {
      sponsorNode.failNextSend =
          'Invalid transaction: Fee payer has insufficient balance';
      final g = await Ed25519HDKeyPair.random();
      final c = koraClient();
      final sig = await c.pulseWithGuard(g, vaultOwner: owner, planIds: [0]);
      expect(sig, startsWith('sig'));
      expect(c.lastSendUsedFallback, isTrue);
      expectGuardPaid(g, Disc.pulse);

      await c.pulseWithGuard(g, vaultOwner: owner, planIds: [0]);
      expect(c.lastSendUsedFallback, isFalse, reason: 'sponsor is back');
      expect(rpc.sent, hasLength(1));
    });

    test(
      'rejected or broken sponsor: the guard pays its own lockdown',
      () async {
        for (final sponsor in [
          brokenSponsor(401, 'unauthorized'),
          brokenSponsor(200, 'not json'),
        ]) {
          rpc.sent.clear();
          final g = await Ed25519HDKeyPair.random();
          final c = koraClient(sponsor);
          await c.lockdownWithGuard(g, vaultOwner: owner, planIds: [0]);
          expect(c.lastSendUsedFallback, isTrue);
          expectGuardPaid(g, Disc.lockdown);
        }
      },
    );

    test('unreachable sponsor: the guard pays its own pulse', () async {
      final g = await Ed25519HDKeyPair.random();
      final c = koraClient(
        KoraClient(
          Uri.parse('https://kora.test'),
          httpClient: MockClient(
            (_) async => throw http.ClientException('Connection refused'),
          ),
        ),
      );
      await c.pulseWithGuard(g, vaultOwner: owner, planIds: [0]);
      expect(c.lastSendUsedFallback, isTrue);
      expectGuardPaid(g, Disc.pulse);
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('owner transactions: wallet pays in SOL, built and sent through '
        'our RPC even with a sponsor', () async {
      final wallet = await Ed25519HDKeyPair.random();
      final c = koraClient();
      final unsigned = await c.buildDeposit(
        owner: wallet.address,
        planId: 0,
        lamports: 1000,
      );
      final msg = SignedTx.fromBytes(unsigned).compiledMessage;
      expect(msg.requiredSignatureCount, 1);
      expect(msg.accountKeys[0].toBase58(), wallet.address);
      expect(rpc.calls, contains('getLatestBlockhash'));

      final vault = vaultPda(owner, 0).address;
      rpc.accounts[ataAddress(vault, usdc)] = FakeAccount(
        tokenProgramId,
        tokenAccountBytes(mint: usdc, owner: vault, amount: 500),
      );
      final rule = await c.buildExecuteRule(
        executor: executor,
        vaultOwner: owner,
        planId: 0,
        index: 1,
      );
      expect(
        SignedTx.fromBytes(rule).compiledMessage.accountKeys[0].toBase58(),
        executor,
      );

      final walletSigned = await partiallySign(unsigned, wallet);
      await c.sendSigned([walletSigned]);
      expect(rpc.calls.where((m) => m == 'sendTransaction'), hasLength(1));
      expect(sponsorNode.calls, isEmpty);
    });

    test('create_plan with a sponsor: owner pays rent and still funds an '
        'underfunded guard for the fallback', () async {
      final wallet = await Ed25519HDKeyPair.random();
      rpc.accounts[guard] = FakeAccount(
        systemProgramId,
        const [],
        lamports: AppConfig.guardFundingLamports - 1,
      );
      final unsigned = await koraClient().buildCreateVault(
        owner: wallet.address,
        planId: 0,
        label: 'Kids',
        guard: guard,
        lockSecs: 3600,
        skipGraceSecs: grace,
        rules: [rule(to: alice)],
      );
      final msg = SignedTx.fromBytes(unsigned).compiledMessage;
      expect(msg.requiredSignatureCount, 1);
      expect(msg.accountKeys[0].toBase58(), wallet.address);
      final ixs = Message.decompile(msg).instructions;
      expect(ixs, hasLength(2));
      expect(ixs[0].programId.toBase58(), systemProgramId);
      expect(
        [for (final a in ixs[0].accounts) a.pubKey.toBase58()],
        [wallet.address, guard],
      );
      expect(
        ixs[0].data.toList().sublist(4),
        le(8, AppConfig.guardFundingLamports),
      );
      expect(
        [
          for (final a in ixs[1].accounts)
            (a.pubKey.toBase58(), a.isWriteable, a.isSigner),
        ],
        [
          (wallet.address, true, true),
          (wallet.address, true, true),
          (vaultPda(wallet.address, 0).address, true, false),
          (systemProgramId, false, false),
        ],
      );
      expect(rpc.calls, contains('getBalance'));
      expect(sponsorNode.calls, isEmpty);
    });

    test('a rejected API key is reported clearly', () {
      expect(
        DeadmanException.fromKora(
          const KoraException(401, 'HTTP 401', httpStatus: 401),
        ).name,
        'KoraUnauthorized',
      );
    });
  });

  Matcher throwsNamed(String name) =>
      throwsA(isA<DeadmanException>().having((e) => e.name, 'name', name));

  const day = 86400;
  const start = now - 100 * day;

  RuleState schedule({
    required String to,
    String? mint,
    int total = 1000000000,
    int cliff = 30 * day,
    int duration = 365 * day,
    int released = 0,
    int executedAt = 0,
    Rail rail = Rail.solana,
  }) => RuleState(
    beneficiary: to,
    rail: rail,
    afterSecs: cliff,
    mint: mint,
    mode: AmountMode.fixed,
    amount: total,
    executedAt: executedAt,
    paid: released,
    durationSecs: duration,
    released: released,
  );

  /// Adds vesting plan [planId] of [of] (default: owner).
  String addVesting(
    int planId,
    List<RuleState> schedules, {
    String? of,
    bool revocable = true,
    int revokedAt = 0,
    int lockedUntil = 0,
    int lamports = 1000000,
    String? rentPayer,
    int vestPeriodSecs = 0,
  }) {
    final o = of ?? owner;
    final address = vaultPda(o, planId).address;
    rpc.accounts[address] = FakeAccount(
      AppConfig.programId,
      vaultBytes(
        owner: o,
        planId: planId,
        label: 'vest $planId',
        guard: guard,
        lockedUntil: lockedUntil,
        kind: PlanKind.vesting,
        startAt: start,
        revocable: revocable,
        revokedAt: revokedAt,
        rentPayer: rentPayer,
        rules: schedules,
        vestPeriodSecs: vestPeriodSecs,
      ),
      lamports: lamports,
    );
    return address;
  }

  void addTokens(String holder, String mint, int amount) =>
      rpc.accounts[ataAddress(holder, mint)] = FakeAccount(
        tokenProgramId,
        tokenAccountBytes(mint: mint, owner: holder, amount: amount),
      );

  group('vesting', () {
    final alpha = VestingSpec(
      beneficiary: alice,
      rail: Rail.solana,
      total: 3000000000,
      cliffSecs: 90 * day,
      durationSecs: 365 * day,
    );
    final beta = VestingSpec(
      beneficiary: bob,
      rail: Rail.cloak,
      mint: usdc,
      total: 1200000,
      cliffSecs: 0,
      durationSecs: 730 * day,
    );

    Future<Uint8List> createVesting({
      String label = 'Team',
      String? g,
      int startAt = now,
      List<VestingSpec>? schedules,
      int depositLamports = 0,
      Map<String, int> tokenDeposits = const {},
      int periodSecs = 0,
    }) => client.buildCreateVesting(
      owner: owner,
      planId: 4,
      label: label,
      guard: g ?? guard,
      lockSecs: 3600,
      startAt: startAt,
      revocable: true,
      schedules: schedules ?? [alpha, beta],
      periodSecs: periodSecs,
      depositLamports: depositLamports,
      tokenDeposits: tokenDeposits,
    );

    test('buildCreateVesting: guard funding, create_vesting, SOL and token '
        'deposits in one owner-paid transaction', () async {
      final tx = await createVesting(
        depositLamports: 5000,
        tokenDeposits: {usdc: 1200000},
      );
      final msg = SignedTx.fromBytes(tx).compiledMessage;
      expect(msg.requiredSignatureCount, 1);
      expect(msg.accountKeys.first.toBase58(), owner);
      final v = vaultPda(owner, 4).address;
      final ixs = instructions(tx);
      expect(ixs, hasLength(5));
      expect(ixs[0].programId.toBase58(), systemProgramId);
      expect(ixs[0].accounts[1].pubKey.toBase58(), guard);
      expect(
        ixs[1].data.toList(),
        encodeCreateVesting(
          planId: 4,
          label: 'Team',
          guard: guard,
          lockSecs: 3600,
          startAt: now,
          revocable: true,
          schedules: [alpha, beta],
        ),
      );
      expect(metas(ixs[1]), [
        (owner, true, true),
        (owner, true, true),
        (v, true, false),
        (systemProgramId, false, false),
        (usdc, false, false),
      ], reason: 'the schedule mint, for the SPL Token check');
      expect(ixs[2].programId.toBase58(), systemProgramId);
      expect(ixs[2].accounts[1].pubKey.toBase58(), v);
      expect(ixs[2].data.toList().sublist(4), le(8, 5000));
      expect(ixs[3].programId.toBase58(), ataProgramId);
      expect(metas(ixs[3]).take(2), [
        (owner, true, true),
        (ataAddress(v, usdc), true, false),
      ]);
      expect(ixs[4].programId.toBase58(), tokenProgramId);
      expect(addrs(ixs[4]), [
        ataAddress(owner, usdc),
        usdc,
        ataAddress(v, usdc),
        owner,
      ]);
      expect(ixs[4].data.toList(), [12, ...le(8, 1200000), 6]);
    });

    test('buildCreateVesting sends the installment period last', () async {
      final tx = await createVesting(periodSecs: 30 * day);
      expect(
        instructions(tx)[1].data.toList(),
        encodeCreateVesting(
          planId: 4,
          label: 'Team',
          guard: guard,
          lockSecs: 3600,
          startAt: now,
          revocable: true,
          schedules: [alpha, beta],
          periodSecs: 30 * day,
        ),
      );
      for (final bad in [59, 365 * day + 1, -1]) {
        await expectLater(
          createVesting(periodSecs: bad),
          throwsNamed('InvalidVesting'),
          reason: 'period $bad',
        );
      }
      await createVesting(periodSecs: 60);
      await createVesting(periodSecs: 365 * day);
    });

    test('buildCreateVesting validates before signing', () async {
      await expectLater(
        createVesting(
          schedules: [
            VestingSpec(
              beneficiary: owner,
              rail: Rail.solana,
              total: 1,
              cliffSecs: 0,
              durationSecs: 1,
            ),
          ],
        ),
        throwsNamed('InvalidVesting'),
      );
      await expectLater(
        createVesting(startAt: now + 367 * day),
        throwsNamed('InvalidVesting'),
      );
      await expectLater(createVesting(g: owner), throwsNamed('InvalidGuard'));
      await expectLater(
        createVesting(label: 'x' * 33),
        throwsNamed('LabelTooLong'),
      );
      rpc.accounts[usdc] = FakeAccount(token2022ProgramId, mintBytes(6));
      await expectLater(
        createVesting(),
        throwsA(
          isA<DeadmanException>().having(
            (e) => e.message,
            'message',
            contains('Token-2022'),
          ),
        ),
      );
      expect(rpc.calls, isNot(contains('getLatestBlockhash')));
    });

    test(
      'a plan too large for one transaction is refused before signing',
      () async {
        final eight = [
          for (var i = 0; i < 8; i++)
            VestingSpec(
              beneficiary: key(20 + i),
              rail: Rail.solana,
              total: 1,
              cliffSecs: 0,
              durationSecs: day,
            ),
        ];
        final more = [key(40), key(41)];
        for (final m in more) {
          rpc.accounts[m] = FakeAccount(tokenProgramId, mintBytes(6));
        }
        await createVesting(schedules: eight, tokenDeposits: {usdc: 1});
        await expectLater(
          createVesting(
            schedules: eight,
            tokenDeposits: {usdc: 1, for (final m in more) m: 1},
          ),
          throwsNamed('TxTooLarge'),
        );
      },
    );

    test('buildRevokeVesting and its pre-checks', () async {
      addVesting(4, [schedule(to: alice)]);
      final tx = await client.buildRevokeVesting(owner: owner, planId: 4);
      final ix = instructions(tx).single;
      expect(ix.data.toList(), Disc.revokeVesting);
      expect(metas(ix), [
        (owner, true, true),
        (vaultPda(owner, 4).address, true, false),
      ]);

      addVesting(5, [schedule(to: alice)], revocable: false);
      addVesting(6, [schedule(to: alice)], revokedAt: now - day);
      addVesting(7, [schedule(to: alice)], lockedUntil: now + 60);
      addVesting(8, [
        schedule(to: alice, released: 1000000000, executedAt: now - day),
      ]);
      for (final (id, name) in [
        (0, 'WrongPlanKind'),
        (5, 'NotRevocable'),
        (6, 'AlreadyRevoked'),
        (7, 'VaultLocked'),
        (8, 'PlanCompleted'),
      ]) {
        await expectLater(
          client.buildRevokeVesting(owner: owner, planId: id),
          throwsNamed(name),
          reason: 'plan $id',
        );
      }
    });

    test('buildReleaseVested SOL: execute_sol_rule accounts, release '
        'discriminator', () async {
      final v = addVesting(4, [
        schedule(to: alice),
      ], lamports: rpc.rentExempt + 1000000000);
      final tx = await client.buildReleaseVested(
        executor: executor,
        vaultOwner: owner,
        planId: 4,
        index: 0,
      );
      expect(
        SignedTx.fromBytes(tx).compiledMessage.accountKeys[0].toBase58(),
        executor,
      );
      final ix = instructions(tx).single;
      expect(ix.data.toList(), [...Disc.releaseVestedSol, 0]);
      expect(addrs(ix), [executor, v, configPda().address, alice, treasury]);
    });

    test(
      'buildReleaseVested token: executor creates both ATAs first',
      () async {
        final v = addVesting(4, [
          schedule(to: alice),
          schedule(to: bob, mint: usdc, cliff: 0, rail: Rail.zcash),
        ]);
        addTokens(v, usdc, 1000);
        final ixs = instructions(
          await client.buildReleaseVested(
            executor: executor,
            vaultOwner: owner,
            planId: 4,
            index: 1,
          ),
        );
        expect(ixs, hasLength(3));
        expect(metas(ixs[0]).take(2), [
          (executor, true, true),
          (ataAddress(treasury, usdc), true, false),
        ]);
        expect(metas(ixs[1]).take(2), [
          (executor, true, true),
          (ataAddress(bob, usdc), true, false),
        ]);
        expect(ixs[2].data.toList(), [...Disc.releaseVestedToken, 1]);
        expect(addrs(ixs[2]), [
          executor,
          v,
          configPda().address,
          usdc,
          ataAddress(v, usdc),
          bob,
          ataAddress(bob, usdc),
          ataAddress(treasury, usdc),
          tokenProgramId,
        ]);
      },
    );

    test('release rejects kind, index, cliff, released and empty mistakes '
        'before signing', () async {
      addVesting(4, [
        schedule(to: alice, cliff: 200 * day),
        schedule(to: bob, executedAt: now - day, released: 1000000000),
        schedule(to: alice, mint: usdc, cliff: 0),
        schedule(to: bob),
      ]);
      Future<Uint8List> release(int planId, int index) =>
          client.buildReleaseVested(
            executor: executor,
            vaultOwner: owner,
            planId: planId,
            index: index,
          );
      await expectLater(release(0, 0), throwsNamed('WrongPlanKind'));
      await expectLater(release(4, 4), throwsNamed('InvalidRuleIndex'));
      await expectLater(release(4, 0), throwsNamed('NothingToPay'));
      await expectLater(release(4, 1), throwsNamed('RuleAlreadyExecuted'));
      await expectLater(
        release(4, 2),
        throwsNamed('NothingToPay'),
        reason: 'the vault holds no USDC',
      );
      await expectLater(
        release(4, 3),
        throwsNamed('NothingToPay'),
        reason: 'the vault holds no spare SOL',
      );
      expect(rpc.calls, isNot(contains('getLatestBlockhash')));
    });

    group('installments', () {
      // 100 days in, monthly installments: 3 have unlocked (90 days); the
      // 4th unlocks at day 120, 20 days from now.
      const vested90 = 246575342;
      const usdcVested90 = 295890;
      late Ed25519HDKeyPair heir;
      setUp(() async {
        heir = await Ed25519HDKeyPair.random();
        final v = addVesting(
          4,
          [
            schedule(to: heir.address, cliff: 0, released: vested90),
            schedule(
              to: heir.address,
              mint: usdc,
              total: 1200000,
              cliff: 0,
              released: usdcVested90,
            ),
            schedule(to: heir.address, cliff: 0),
          ],
          lamports: rpc.rentExempt + 1000000000,
          vestPeriodSecs: 30 * day,
        );
        addTokens(v, usdc, 1200000);
      });

      Matcher nothingUntil(String amount) => throwsA(
        isA<DeadmanException>()
            .having((e) => e.name, 'name', 'NothingToPay')
            .having(
              (e) => e.message,
              'message',
              'Nothing new has unlocked yet. Next installment: $amount on '
                  '2026-10-17 09:06 UTC.',
            ),
      );

      test('every claim path refuses until the next installment', () async {
        const sol = '0.082191781 SOL';
        await expectLater(
          client.buildReleaseVested(
            executor: executor,
            vaultOwner: owner,
            planId: 4,
            index: 0,
          ),
          nothingUntil(sol),
        );
        await expectLater(
          client.releaseVestedWithKey(
            heir,
            vaultOwner: owner,
            planId: 4,
            index: 0,
          ),
          nothingUntil(sol),
        );
        await expectLater(
          client.quoteClaim(
            claimer: heir.address,
            vaultOwner: owner,
            planId: 4,
            index: 0,
          ),
          nothingUntil(sol),
        );
        await expectLater(
          client.buildClaim(
            claimer: heir.address,
            vaultOwner: owner,
            planId: 4,
            index: 0,
          ),
          nothingUntil(sol),
        );
        await expectLater(
          client.buildClaim(
            claimer: heir.address,
            vaultOwner: owner,
            planId: 4,
            index: 1,
          ),
          nothingUntil('0.09863 token ${usdc.substring(0, 4)}…'),
        );
        expect(rpc.sent, isEmpty);
      });

      test('an unclaimed installment releases exactly what unlocked', () async {
        final quote = await client.quoteClaim(
          claimer: heir.address,
          vaultOwner: owner,
          planId: 4,
          index: 2,
        );
        expect(quote.net, lessThanOrEqualTo(vested90));
        expect(quote.net, greaterThan(vested90 * 9 ~/ 10));
        final ix = instructions(
          await client.buildReleaseVested(
            executor: executor,
            vaultOwner: owner,
            planId: 4,
            index: 2,
          ),
        ).single;
        expect(ix.data.toList(), [...Disc.releaseVestedSol, 2]);
      });
    });

    test('inheritance-only builds reject vesting plans', () async {
      addVesting(4, [schedule(to: alice)]);
      await expectLater(
        client.buildExecuteRule(
          executor: executor,
          vaultOwner: owner,
          planId: 4,
          index: 0,
        ),
        throwsNamed('WrongPlanKind'),
      );
      await expectLater(
        client.buildSkipRule(
          caller: executor,
          vaultOwner: owner,
          planId: 4,
          index: 0,
        ),
        throwsNamed('WrongPlanKind'),
      );
      await expectLater(
        client.buildUpdatePolicy(
          owner: owner,
          planId: 4,
          label: '',
          lockSecs: 3600,
          skipGraceSecs: grace,
          rules: [rule(to: alice)],
        ),
        throwsNamed('WrongPlanKind'),
      );
    });

    test(
      'releaseVestedWithKey signs with the key and sends through our RPC',
      () async {
        final k = await Ed25519HDKeyPair.random();
        addVesting(4, [
          schedule(to: alice),
        ], lamports: rpc.rentExempt + 1000000000);
        await client.releaseVestedWithKey(
          k,
          vaultOwner: owner,
          planId: 4,
          index: 0,
        );
        final tx = SignedTx.fromBytes(rpc.sent.single);
        expect(tx.compiledMessage.accountKeys.first.toBase58(), k.address);
        expect(instructions(rpc.sent.single).single.data.toList(), [
          ...Disc.releaseVestedSol,
          0,
        ]);
      },
    );

    test('buildCloseVault passes the stored rent payer', () async {
      final kora = key(70);
      final close = instructions(
        await client.buildCloseVault(owner: owner, planId: 0),
      ).single;
      expect(addrs(close), [owner, vault, owner]);
      expect(close.data.toList(), Disc.closeVault);

      addVesting(4, [
        schedule(to: alice, released: 1000000000, executedAt: now - day),
      ], rentPayer: kora);
      final vest = instructions(
        await client.buildCloseVault(owner: owner, planId: 4),
      ).single;
      expect(addrs(vest), [owner, vaultPda(owner, 4).address, kora]);
      expect(metas(vest).last, (kora, true, false));

      addVesting(5, [schedule(to: alice, released: 10)]);
      await expectLater(
        client.buildCloseVault(owner: owner, planId: 5),
        throwsNamed('FundsCommitted'),
      );
      addVesting(6, [schedule(to: alice)], revokedAt: start + 10 * day);
      await client.buildCloseVault(owner: owner, planId: 6);
      await expectLater(
        client.buildCloseVault(owner: owner, planId: 9),
        throwsA(isA<DeadmanException>()),
      );
    });

    test('buildCloseVault sweeps every token the plan holds first, in the '
        'same transaction', () async {
      addPlan(4, [rule(to: alice), rule(to: bob, mint: usdc)]);
      final v = vaultPda(owner, 4).address;
      addTokens(v, usdc, 1200);
      final ixs = instructions(
        await client.buildCloseVault(owner: owner, planId: 4),
      );
      expect(ixs, hasLength(3), reason: 'owner ATA, withdraw, close');
      expect(ixs[1].data.toList().sublist(0, 8), Disc.withdrawToken);
      expect(ixs[1].data.toList().sublist(8), le(8, 1200));
      expect(addrs(ixs[1]).sublist(3, 5), [
        ataAddress(v, usdc),
        ataAddress(owner, usdc),
      ]);
      expect(ixs.last.data.toList(), Disc.closeVault);

      // The app's USDC, deposited into an all-SOL plan, is swept too.
      addPlan(5, [rule(to: alice)]);
      addTokens(vaultPda(owner, 5).address, AppConfig.usdcMint, 7);
      expect(
        instructions(await client.buildCloseVault(owner: owner, planId: 5)),
        hasLength(3),
      );
    });

    test('withdrawals stop at what vesting beneficiaries are owed', () async {
      // 1 SOL is owed (nothing released yet), 500 lamports are spare.
      addVesting(4, [
        schedule(to: alice),
        schedule(to: bob, mint: usdc, total: 700),
      ], lamports: rpc.rentExempt + 1000000000 + 500);
      final v = vaultPda(owner, 4).address;
      addTokens(v, usdc, 1000);

      await client.buildWithdrawSol(owner: owner, planId: 4, lamports: 500);
      await expectLater(
        client.buildWithdrawSol(owner: owner, planId: 4, lamports: 501),
        throwsNamed('FundsCommitted'),
      );
      await expectLater(
        client.buildWithdrawSol(owner: owner, planId: 4, lamports: 1000000501),
        throwsNamed('InsufficientFunds'),
      );
      await client.buildWithdrawToken(
        owner: owner,
        planId: 4,
        mint: usdc,
        amount: 300,
      );
      await expectLater(
        client.buildWithdrawToken(
          owner: owner,
          planId: 4,
          mint: usdc,
          amount: 301,
        ),
        throwsNamed('FundsCommitted'),
      );

      // Inheritance plans have nothing committed: no vault ATA read.
      final reads = rpc.calls.length;
      await client.buildWithdrawToken(
        owner: owner,
        planId: 0,
        mint: usdc,
        amount: 1,
      );
      expect(
        rpc.calls.skip(reads).where((c) => c == 'getAccountInfo'),
        hasLength(1),
        reason: 'only the vault itself',
      );
    });

    test(
      'check-in helpers skip vesting plans; lockdown still covers them',
      () async {
        addVesting(4, [schedule(to: alice)]);
        final pulse = instructions(
          await client.buildPulseByOwner(owner: owner, planIds: [0, 4]),
        );
        expect(pulse.map((i) => i.accounts[1].pubKey.toBase58()), [vault]);

        final g = await Ed25519HDKeyPair.random();
        await expectLater(
          client.pulseWithGuard(g, vaultOwner: owner, planIds: [4]),
          throwsNamed('WrongPlanKind'),
        );
        expect(rpc.sent, isEmpty);

        final lock = instructions(
          await client.buildLockdownByOwner(owner: owner, planIds: [0, 4]),
        );
        expect(lock.map((i) => i.data.toList()), [
          Disc.lockdown,
          Disc.lockdown,
        ]);
        expect(
          lock.last.accounts[1].pubKey.toBase58(),
          vaultPda(owner, 4).address,
        );
      },
    );
  });

  group('USDC fees via the Kora paymaster', () {
    late FakeKora node;
    late DeadmanClient c;
    late Ed25519HDKeyPair wallet;

    setUp(() async {
      node = FakeKora(signer: key(70), paymentAddress: key(70));
      c = DeadmanClient.withKora(
        client: rpc.client(),
        paymaster: node.client(),
        paymasterSigner: key(70),
        clock: () => now,
      )..feeToken = usdc;
      wallet = await Ed25519HDKeyPair.random();
      addTokens(wallet.address, usdc, 1000000);
    });

    Future<Uint8List> createVault({int deposit = 0}) => c.buildCreateVault(
      owner: wallet.address,
      planId: 0,
      label: 'Kids',
      guard: guard,
      lockSecs: 3600,
      skipGraceSecs: grace,
      rules: [rule(to: alice)],
      depositLamports: deposit,
    );

    void expectPaidByKora(Uint8List tx) {
      final msg = SignedTx.fromBytes(tx).compiledMessage;
      expect(msg.requiredSignatureCount, 2);
      expect(msg.accountKeys[0].toBase58(), node.signer);
      expect(msg.accountKeys[1].toBase58(), wallet.address);
      expect(msg.recentBlockhash, node.blockhash);
      final pay = instructions(tx).last;
      expect(pay.programId.toBase58(), tokenProgramId);
      expect(addrs(pay), [
        ataAddress(wallet.address, usdc),
        usdc,
        ataAddress(node.paymentAddress, usdc),
        wallet.address,
      ]);
      expect(pay.data.toList(), [12, ...le(8, node.feeInToken!), 6]);
    }

    test('create_plan: Kora pays fee and rent, the wallet pays USDC last; '
        'sent through Kora once', () async {
      final tx = await createVault();
      expectPaidByKora(tx);
      final ixs = instructions(tx);
      expect(ixs, hasLength(2), reason: 'no SOL to fund the guard with');
      expect(addrs(ixs[0]), [
        wallet.address,
        node.signer,
        vaultPda(wallet.address, 0).address,
        systemProgramId,
      ]);
      expect(ixs[0].data.toList().sublist(0, 8), Disc.createPlan);

      final est = node.paramsOf('estimateTransactionFee').single;
      expect(est['fee_token'], usdc);
      expect(est['signer_key'], node.signer);
      final estimated = SignedTx.decode(est['transaction'] as String);
      expect(
        Message.decompile(estimated.compiledMessage).instructions,
        hasLength(1),
        reason: 'estimated without the payment',
      );
      expect(
        estimated.compiledMessage.accountKeys.first.toBase58(),
        node.signer,
      );

      final signed = await partiallySign(tx, wallet);
      final sigs = await c.sendSigned([signed]);
      expect(sigs.single, startsWith('kora'));
      final sent = node.paramsOf('signAndSendTransaction').single;
      expect(sent['signer_key'], node.signer);
      expect(base64Decode(sent['transaction'] as String), signed);
      expect(rpc.calls, isNot(contains('sendTransaction')));
      expect(rpc.calls, contains('getSignatureStatuses'));
    });

    test('a wallet with spare SOL still funds the guard', () async {
      rpc.accounts[wallet.address] = FakeAccount(
        systemProgramId,
        const [],
        lamports: AppConfig.guardFundingLamports + 1000,
      );
      final ixs = instructions(await createVault(deposit: 1000));
      expect(ixs, hasLength(4));
      expect(ixs[0].programId.toBase58(), systemProgramId);
      expect(addrs(ixs[0]), [wallet.address, guard]);
    });

    test('NoFeeToken when the wallet cannot cover the fee (plus a deposit '
        'of the same token)', () async {
      addTokens(wallet.address, usdc, node.feeInToken! - 1);
      await expectLater(createVault(), throwsNamed('NoFeeToken'));

      addTokens(wallet.address, usdc, node.feeInToken! + 999);
      await expectLater(
        c.buildDepositToken(
          owner: wallet.address,
          planId: 0,
          mint: usdc,
          amount: 1000,
        ),
        throwsA(
          isA<DeadmanException>()
              .having((e) => e.name, 'name', 'NoFeeToken')
              .having(
                (e) => e.message,
                'message',
                allOf(contains('0.0025'), contains('back to SOL')),
              ),
        ),
      );
      final ok = await c.buildDepositToken(
        owner: wallet.address,
        planId: 0,
        mint: usdc,
        amount: 999,
      );
      expectPaidByKora(ok);
      expect(metas(instructions(ok).first).first, (
        node.signer,
        true,
        true,
      ), reason: 'Kora pays the vault ATA rent');
      expect(node.paramsOf('signAndSendTransaction'), isEmpty);
    });

    test('create_plan with a token deposit: the deposit counts against '
        'the USDC fee', () async {
      Future<Uint8List> create(int amount) => c.buildCreateVault(
        owner: wallet.address,
        planId: 0,
        label: 'Kids',
        guard: guard,
        lockSecs: 3600,
        skipGraceSecs: grace,
        rules: [rule(to: alice, mint: usdc)],
        tokenDeposits: {usdc: amount},
      );
      addTokens(wallet.address, usdc, node.feeInToken! + 999);
      await expectLater(create(1000), throwsNamed('NoFeeToken'));
      final tx = await create(999);
      expectPaidByKora(tx);
      final ixs = instructions(tx);
      expect(ixs[0].data.toList().sublist(0, 8), Disc.createPlan);
      expect(metas(ixs[1]).first, (
        node.signer,
        true,
        true,
      ), reason: 'Kora pays the vault ATA rent');
      expect(ixs[2].data.toList(), [12, ...le(8, 999), 6]);
    });

    test('a token withdrawal may pay its fee from what it withdraws', () async {
      addPlan(0, pending, of: wallet.address);
      addTokens(wallet.address, usdc, 0);
      final tx = await c.buildWithdrawToken(
        owner: wallet.address,
        planId: 0,
        mint: usdc,
        amount: node.feeInToken!,
      );
      expectPaidByKora(tx);
      // The owner's ATA exists: no Kora-paid create, so the cheapest tier.
      expect(
        instructions(tx).map((ix) => ix.programId.toBase58()),
        isNot(contains(ataProgramId)),
      );
    });

    test('executing a tier from the wallet: Kora pays the ATAs', () async {
      final ex = await Ed25519HDKeyPair.random();
      addTokens(ex.address, usdc, 1000000);
      addTokens(vaultPda(owner, 0).address, usdc, 500);
      final tx = await c.buildExecuteRule(
        executor: ex.address,
        vaultOwner: owner,
        planId: 0,
        index: 1,
      );
      final msg = SignedTx.fromBytes(tx).compiledMessage;
      expect(msg.accountKeys[0].toBase58(), node.signer);
      expect(msg.accountKeys[1].toBase58(), ex.address);
      final ixs = instructions(tx);
      expect(ixs, hasLength(4));
      expect(metas(ixs[0]).first, (node.signer, true, true));
      expect(metas(ixs[1]).first, (node.signer, true, true));
      expect(ixs[2].data.toList(), [...Disc.executeTokenRule, 1]);
      expect(addrs(ixs[3]).last, ex.address);
    });

    test('a withdrawal into a closed account reopens it on the wallet, '
        'never on Kora', () async {
      addPlan(0, pending, of: wallet.address);
      rpc.accounts.remove(ataAddress(wallet.address, usdc));
      await expectLater(
        c.buildWithdrawToken(
          owner: wallet.address,
          planId: 0,
          mint: usdc,
          amount: node.feeInToken!,
        ),
        throwsNamed('NoSolForAccount'),
      );
      rpc.accounts[wallet.address] = FakeAccount(
        systemProgramId,
        const [],
        lamports: rpc.rentExempt,
      );
      final tx = await c.buildWithdrawToken(
        owner: wallet.address,
        planId: 0,
        mint: usdc,
        amount: node.feeInToken!,
      );
      expectPaidByKora(tx);
      final create = instructions(tx).first;
      expect(create.programId.toBase58(), ataProgramId);
      expect(addrs(create).take(3), [
        wallet.address,
        ataAddress(wallet.address, usdc),
        wallet.address,
      ]);
    });

    group('paymaster pinning (M-3)', () {
      test('refuses another fee payer or payment address', () async {
        for (final (signer, payTo) in [
          (key(72), key(72)),
          (key(70), key(73)),
        ]) {
          final rogue = FakeKora(signer: signer, paymentAddress: payTo);
          final d = DeadmanClient.withKora(
            client: rpc.client(),
            paymaster: rogue.client(),
            paymasterSigner: key(70),
            clock: () => now,
          )..feeToken = usdc;
          await expectLater(
            d.buildDeposit(owner: wallet.address, planId: 0, lamports: 5),
            throwsNamed('KoraUntrusted'),
          );
          expect(rogue.paramsOf('estimateTransactionFee'), isEmpty);
        }
      });

      test('refuses an estimate naming another payment address', () async {
        node.estimatePaymentAddress = key(74);
        await expectLater(createVault(), throwsNamed('KoraUntrusted'));
      });

      test('an unpinned build refuses the paymaster', () async {
        final d = DeadmanClient.withKora(
          client: rpc.client(),
          paymaster: node.client(),
          paymasterSigner: '',
          clock: () => now,
        )..feeToken = usdc;
        await expectLater(
          d.buildDeposit(owner: wallet.address, planId: 0, lamports: 5),
          throwsNamed('KoraUnpinned'),
        );
        expect(node.calls, isEmpty);
      });

      test('caps the fee', () async {
        final d = DeadmanClient.withKora(
          client: rpc.client(),
          paymaster: node.client(),
          paymasterSigner: key(70),
          maxFee: 3000,
          clock: () => now,
        )..feeToken = usdc;
        addTokens(wallet.address, usdc, 10000000);
        node.feeInToken = 3000;
        expectPaidByKora(
          await d.buildDeposit(owner: wallet.address, planId: 0, lamports: 5),
        );
        node.feeInToken = 3001;
        await expectLater(
          d.buildDeposit(owner: wallet.address, planId: 0, lamports: 5),
          throwsA(
            isA<DeadmanException>()
                .having((e) => e.name, 'name', 'KoraFeeTooHigh')
                .having(
                  (e) => e.message,
                  'message',
                  allOf(contains('asks 0.003001 '), contains('the 0.003 ')),
                ),
          ),
        );
      });

      test('defaults: the devnet signer and a 3 USDC cap', () {
        expect(AppConfig.isMainnet, isFalse);
        expect(
          AppConfig.koraPaymasterSigner,
          'HCAeeSv4vBHGqWLEV7AdWK19xFYuosN76jwUGuoCs3pL',
        );
        expect(AppConfig.koraMaxFee, 3000000);
        final d = DeadmanClient.withKora(client: rpc.client());
        expect(d.paymasterSigner, AppConfig.koraPaymasterSigner);
        expect(d.maxFee, 3000000);
      });
    });

    test('a node that will not price the token is reported', () async {
      node.feeInToken = null;
      await expectLater(createVault(), throwsNamed('KoraError'));
    });

    test('SOL fees without a fee token or without a paymaster', () async {
      c.feeToken = null;
      final a = SignedTx.fromBytes(await createVault()).compiledMessage;
      expect(a.requiredSignatureCount, 1);
      expect(a.accountKeys.first.toBase58(), wallet.address);
      expect(node.calls, isEmpty);

      final noPaymaster = DeadmanClient.withKora(
        client: rpc.client(),
        clock: () => now,
      )..feeToken = usdc;
      expect(noPaymaster.paysFeesInToken, isFalse);
      final b = SignedTx.fromBytes(
        await noPaymaster.buildDeposit(
          owner: wallet.address,
          planId: 0,
          lamports: 5,
        ),
      ).compiledMessage;
      expect(b.requiredSignatureCount, 1);
      expect(node.calls, isEmpty);
    });

    test('de-duplicates by the wallet signature and resends on a lagging '
        'blockhash', () async {
      Future<Uint8List> deposit(int lamports) async => partiallySign(
        await c.buildDeposit(
          owner: wallet.address,
          planId: 0,
          lamports: lamports,
        ),
        wallet,
      );
      final a = await deposit(1);
      final b = await deposit(2);
      node.blockhashMisses = 1;
      final results = await Future.wait([
        c.sendSigned([a, b]),
        c.sendSigned([Uint8List.fromList(a)]),
      ]);
      expect(results[0], hasLength(2));
      expect(results[1].single, results[0].first);
      expect(
        node.paramsOf('signAndSendTransaction'),
        hasLength(3),
        reason: 'a (once after a blockhash miss) and b',
      );
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('the default constructor reads the paymaster from AppConfig', () {
      expect(AppConfig.koraPaymasterUrl, isEmpty);
      final d = DeadmanClient(rpc.client());
      expect(d.paymaster, isNull);
      expect(d.feeToken, isNull);
      d.feeToken = AppConfig.usdcMint;
      expect(d.feeToken, AppConfig.usdcMint);
      expect(d.paysFeesInToken, isFalse);
    });
  });

  group('beneficiary claims with zero SOL', () {
    late FakeKora sponsorNode;
    late FakeKora payNode;
    late DeadmanClient c;
    late Ed25519HDKeyPair heir;
    late String solVault;
    late String usdcVault;

    // Plan 3 pays half its 2 SOL to the heir, plan 4 half its 1 USDC.
    const withdrawable = 2000000000;
    const solGross = withdrawable ~/ 2;
    const solNet = solGross - solGross * 200 ~/ 10000;
    const usdcGross = 500000;
    const usdcNet = usdcGross - usdcGross * 200 ~/ 10000;

    String addPayoutPlan(int planId, RuleState r, {int lamports = 0}) {
      final address = vaultPda(owner, planId).address;
      rpc.accounts[address] = FakeAccount(
        AppConfig.programId,
        vaultBytes(owner: owner, planId: planId, guard: guard, rules: [r]),
        lamports: rpc.rentExempt + lamports,
      );
      return address;
    }

    setUp(() async {
      sponsorNode = FakeKora(signer: key(60), paymentAddress: key(60));
      payNode = FakeKora(signer: key(70), paymentAddress: key(70))
        ..feeInToken = 20000;
      c = DeadmanClient.withKora(
        client: rpc.client(),
        sponsor: sponsorNode.client(),
        paymaster: payNode.client(),
        paymasterSigner: key(70),
        paymasterToken: usdc,
        clock: () => now,
      );
      heir = await Ed25519HDKeyPair.random();
      // An existing treasury takes the protocol fee.
      rpc.accounts[treasury] = FakeAccount(
        systemProgramId,
        const [],
        lamports: rpc.rentExempt,
      );
      solVault = addPayoutPlan(
        3,
        rule(to: heir.address),
        lamports: withdrawable,
      );
      usdcVault = addPayoutPlan(4, rule(to: heir.address, mint: usdc));
      addTokens(usdcVault, usdc, 2 * usdcGross);
    });

    Future<ClaimTx> claim(int planId, {String? by, bool sponsored = true}) =>
        c.buildClaim(
          claimer: by ?? heir.address,
          vaultOwner: owner,
          planId: planId,
          index: 0,
          sponsored: sponsored,
        );

    Future<ClaimQuote> quote(int planId, {String? by}) => c.quoteClaim(
      claimer: by ?? heir.address,
      vaultOwner: owner,
      planId: planId,
      index: 0,
    );

    test('SOL: the sponsor pays the fee, the heir signs second, no Kora '
        'account in the claim; sent through the sponsor', () async {
      expect(await c.balance(heir.address), 0);
      final built = await claim(3);
      expect(built.payer, ClaimPayer.sponsor);
      expect(built.note, isNull);
      final msg = SignedTx.fromBytes(built.transaction).compiledMessage;
      expect(msg.requiredSignatureCount, 2);
      expect(msg.accountKeys[0].toBase58(), sponsorNode.signer);
      expect(msg.accountKeys[1].toBase58(), heir.address);
      expect(msg.recentBlockhash, sponsorNode.blockhash);
      final ix = instructions(built.transaction).single;
      expect(ix.data.toList(), [...Disc.executeSolRule, 0]);
      expect(addrs(ix), [
        heir.address,
        solVault,
        configPda().address,
        heir.address,
        treasury,
      ]);
      expect(addrs(ix), isNot(contains(sponsorNode.signer)));

      final signed = await partiallySign(built.transaction, heir);
      final sigs = await c.sendSigned([signed]);
      expect(sigs.single, startsWith('kora'));
      final sent = sponsorNode.paramsOf('signAndSendTransaction').single;
      expect(sent['signer_key'], sponsorNode.signer);
      expect(base64Decode(sent['transaction'] as String), signed);
      expect(rpc.calls, isNot(contains('sendTransaction')));
      expect(payNode.calls, isEmpty);
    });

    test('SOL vesting: release_vested_sol through the sponsor', () async {
      addVesting(5, [
        schedule(to: heir.address),
      ], lamports: rpc.rentExempt + withdrawable);
      final built = await claim(5);
      expect(built.payer, ClaimPayer.sponsor);
      final ix = instructions(built.transaction).single;
      expect(ix.data.toList(), [...Disc.releaseVestedSol, 0]);
      expect(
        SignedTx.fromBytes(built.transaction).compiledMessage.accountKeys.first
            .toBase58(),
        sponsorNode.signer,
      );
    });

    test('SOL: sponsor unreachable -> wallet-paid, said so; refused with '
        'no SOL in the wallet', () async {
      final down = DeadmanClient.withKora(
        client: rpc.client(),
        sponsor: KoraClient(
          Uri.parse('https://kora.test'),
          httpClient: MockClient((_) async => http.Response('gone', 404)),
        ),
        clock: () => now,
      );
      Future<ClaimTx> build() => down.buildClaim(
        claimer: heir.address,
        vaultOwner: owner,
        planId: 3,
        index: 0,
      );
      await expectLater(
        build(),
        throwsA(
          isA<DeadmanException>()
              .having((e) => e.name, 'name', 'SponsorUnavailable')
              .having((e) => e.message, 'message', contains('no SOL')),
        ),
      );

      rpc.accounts[heir.address] = FakeAccount(
        systemProgramId,
        const [],
        lamports: rpc.rentExempt,
      );
      final built = await build();
      expect(built.payer, ClaimPayer.wallet);
      expect(built.note, contains('your wallet paid the network fee'));
      final msg = SignedTx.fromBytes(built.transaction).compiledMessage;
      expect(msg.requiredSignatureCount, 1);
      expect(msg.accountKeys.first.toBase58(), heir.address);
      expect(msg.recentBlockhash, rpc.blockhash);
    });

    test(
      'SOL: sponsored false (the sponsor refused) builds wallet-paid',
      () async {
        rpc.accounts[heir.address] = FakeAccount(
          systemProgramId,
          const [],
          lamports: rpc.rentExempt,
        );
        final built = await claim(3, sponsored: false);
        expect(built.payer, ClaimPayer.wallet);
        expect(
          SignedTx.fromBytes(built.transaction)
              .compiledMessage
              .accountKeys
              .first
              .toBase58(),
          heir.address,
        );
        expect(sponsorNode.calls, isEmpty);
      },
    );

    test('SOL: a payout too small to open the account is explained before '
        'signing', () async {
      addPayoutPlan(6, rule(to: heir.address), lamports: 1000000);
      final q = await quote(6);
      expect(q.net, 490000);
      expect(q.problem, contains('too small to open your account'));
      await expectLater(
        claim(6),
        throwsA(
          isA<DeadmanException>()
              .having((e) => e.name, 'name', 'PayoutBelowRent')
              .having(
                (e) => e.message,
                'message',
                allOf(contains('0.002 SOL'), contains('Add 0.00151 SOL')),
              ),
        ),
      );
      expect(sponsorNode.calls, isEmpty);

      // An account that already exists can take any payout.
      rpc.accounts[heir.address] = FakeAccount(
        systemProgramId,
        const [],
        lamports: rpc.rentExempt,
      );
      expect((await quote(6)).problem, isNull);
      expect((await claim(6)).payer, ClaimPayer.sponsor);
    });

    test('SOL: the protocol fee stays with the heir when the treasury '
        'cannot hold it', () async {
      addPayoutPlan(6, rule(to: heir.address), lamports: 1000000);
      expect((await quote(6)).net, 490000);
      rpc.accounts.remove(treasury);
      expect((await quote(6)).net, 500000);
      expect((await quote(3)).net, solNet, reason: 'a fee above rent fits');
    });

    test('USDC: the paymaster pays fee and both ATAs, the fee comes last '
        'from the payout, even with SOL fees selected', () async {
      expect(c.feeToken, isNull);
      final built = await claim(4);
      expect(built.payer, ClaimPayer.payout);
      final msg = SignedTx.fromBytes(built.transaction).compiledMessage;
      expect(msg.requiredSignatureCount, 2);
      expect(msg.accountKeys[0].toBase58(), payNode.signer);
      expect(msg.accountKeys[1].toBase58(), heir.address);
      expect(msg.recentBlockhash, payNode.blockhash);

      final ixs = instructions(built.transaction);
      expect(ixs, hasLength(4));
      expect(addrs(ixs[0]).take(3), [
        payNode.signer,
        ataAddress(treasury, usdc),
        treasury,
      ]);
      expect(addrs(ixs[1]).take(3), [
        payNode.signer,
        ataAddress(heir.address, usdc),
        heir.address,
      ]);
      expect(ixs[2].data.toList(), [...Disc.executeTokenRule, 0]);
      expect(addrs(ixs[2]).first, heir.address);
      final pay = ixs[3];
      expect(pay.programId.toBase58(), tokenProgramId);
      expect(addrs(pay), [
        ataAddress(heir.address, usdc),
        usdc,
        ataAddress(payNode.signer, usdc),
        heir.address,
      ]);
      expect(pay.data.toList(), [12, ...le(8, 20000), 6]);

      final est = payNode.paramsOf('estimateTransactionFee').single;
      expect(est['fee_token'], usdc);
      expect(
        Message.decompile(
          SignedTx.decode(est['transaction'] as String).compiledMessage,
        ).instructions,
        hasLength(3),
        reason: 'estimated without the payment',
      );

      final signed = await partiallySign(built.transaction, heir);
      expect((await c.sendSigned([signed])).single, startsWith('kora'));
      expect(
        payNode.paramsOf('signAndSendTransaction').single['signer_key'],
        payNode.signer,
      );
      expect(sponsorNode.calls, isEmpty);
    });

    test('USDC: an existing heir ATA is not recreated on Kora', () async {
      addTokens(heir.address, usdc, 0);
      final ixs = instructions((await claim(4)).transaction);
      expect(ixs, hasLength(3));
      expect(addrs(ixs[0])[2], treasury);
    });

    test('USDC: refuses a prize smaller than the claim fee', () async {
      payNode.feeInToken = usdcNet + 1;
      await expectLater(
        claim(4),
        throwsA(
          isA<DeadmanException>()
              .having((e) => e.name, 'name', 'PrizeBelowFee')
              .having(
                (e) => e.message,
                'message',
                allOf(
                  contains('smaller than the claim fee'),
                  contains('pays 0.49 '),
                  contains('costs 0.490001 '),
                  contains('Add about'),
                ),
              ),
        ),
      );
      expect((await quote(4)).problem, contains('smaller than the claim fee'));
      expect(payNode.paramsOf('signAndSendTransaction'), isEmpty);

      // USDC the heir already holds makes up the difference.
      addTokens(heir.address, usdc, 1);
      expect((await claim(4)).payer, ClaimPayer.payout);
    });

    test(
      'USDC: a prize below the claim fee is paid by a wallet with SOL',
      () async {
        payNode.feeInToken = usdcNet + 1;
        rpc.accounts[heir.address] = FakeAccount(
          systemProgramId,
          const [],
          lamports: 100000000,
        );
        final built = await claim(4);
        expect(built.payer, ClaimPayer.wallet);
        expect(built.note, contains('smaller than the free-claim fee'));
        expect(
          SignedTx.fromBytes(built.transaction)
              .compiledMessage
              .accountKeys
              .first
              .toBase58(),
          heir.address,
        );
        expect((await quote(4)).payer, ClaimPayer.wallet);
        expect(payNode.paramsOf('signAndSendTransaction'), isEmpty);
      },
    );

    test(
      'quotes: free SOL, USDC fee from the prize, a keeper pays its own',
      () async {
        final sol = await quote(3);
        expect(sol.free, isTrue);
        expect(sol.payer, ClaimPayer.sponsor);
        expect(sol.mint, isNull);
        expect(sol.net, solNet);
        expect(sol.feeAmount, 0);
        expect(sol.problem, isNull);

        final token = await quote(4);
        expect(token.free, isFalse);
        expect(token.payer, ClaimPayer.payout);
        expect(token.mint, usdc);
        expect(token.feeToken, usdc);
        expect(token.feeAmount, 20000);
        expect(token.net, usdcNet);
        expect(token.problem, isNull);

        final keeper = await quote(3, by: executor);
        expect(keeper.payer, ClaimPayer.wallet);
        expect(payNode.paramsOf('estimateTransactionFee'), hasLength(1));
      },
    );

    test('a keeper claiming for the heir pays its own fee, no Kora', () async {
      for (final planId in [3, 4]) {
        final built = await claim(planId, by: executor);
        expect(built.payer, ClaimPayer.wallet);
        final msg = SignedTx.fromBytes(built.transaction).compiledMessage;
        expect(msg.requiredSignatureCount, 1);
        expect(msg.accountKeys.first.toBase58(), executor);
      }
      expect(sponsorNode.calls, isEmpty);
      expect(payNode.calls, isEmpty);
    });

    test('without a paymaster a USDC claim is wallet-paid as before', () async {
      final d = DeadmanClient.withKora(
        client: rpc.client(),
        sponsor: sponsorNode.client(),
        paymasterToken: usdc,
        clock: () => now,
      );
      final built = await d.buildClaim(
        claimer: heir.address,
        vaultOwner: owner,
        planId: 4,
        index: 0,
      );
      expect(built.payer, ClaimPayer.wallet);
      final ixs = instructions(built.transaction);
      expect(addrs(ixs[0]).first, heir.address, reason: 'the heir pays rent');
      expect(sponsorNode.calls, isEmpty);
    });

    test('another token than the paymaster takes is wallet-paid', () async {
      final bonk = key(9);
      rpc.accounts[bonk] = FakeAccount(tokenProgramId, mintBytes(5));
      addPayoutPlan(7, rule(to: heir.address, mint: bonk));
      addTokens(vaultPda(owner, 7).address, bonk, 1000);
      expect((await quote(7)).payer, ClaimPayer.wallet);
      expect((await claim(7)).payer, ClaimPayer.wallet);
      expect(payNode.calls, isEmpty);
    });
  });

  group('fee model', () {
    final skr = AppConfig.skrMint;
    final nft = key(30);

    setUp(() {
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
        ..[skr] = FakeAccount(tokenProgramId, mintBytes(6))
        ..[nft] = FakeAccount(tokenProgramId, mintBytes(0));
    });

    void addTokens(String holder, String mint, int amount) =>
        rpc.accounts[ataAddress(holder, mint)] = FakeAccount(
          tokenProgramId,
          tokenAccountBytes(mint: mint, owner: holder, amount: amount),
        );

    RuleState fixed(String to, String mint, int amount) => RuleState(
      beneficiary: to,
      rail: Rail.solana,
      afterSecs: 172800,
      mint: mint,
      mode: AmountMode.fixed,
      amount: amount,
      executedAt: 0,
      paid: 0,
    );

    test('fetchFees reads the SKR rate and burn share', () async {
      final fees = await client.fetchFees();
      expect(fees.feeBpsPublic, 200);
      expect(fees.feeBpsPrivate, 200);
      expect(fees.skrMint, skr);
      expect(fees.feeBpsSkr, 150);
      expect(fees.skrBurnBps, 1000);
    });

    test('a single NFT pays no fee: no treasury token account', () async {
      addPlan(5, [fixed(alice, nft, 1)]);
      addTokens(vaultPda(owner, 5).address, nft, 1);
      final ixs = instructions(
        await client.buildExecuteRule(
          executor: executor,
          vaultOwner: owner,
          planId: 5,
          index: 0,
        ),
      );
      expect(ixs, hasLength(2), reason: 'only the heir ATA create');
      expect(ixs[0].accounts[1].pubKey.toBase58(), ataAddress(alice, nft));
      final exec = ixs[1];
      expect(exec.accounts[3].pubKey.toBase58(), nft);
      expect(exec.accounts[3].isWriteable, isTrue);
      expect(exec.accounts[7].pubKey.toBase58(), AppConfig.programId);
      expect(exec.accounts[7].isWriteable, isFalse);
    });

    test('an SKR payout that leaves a fee passes the treasury ATA', () async {
      addPlan(6, [fixed(alice, skr, 1000000)]);
      addTokens(vaultPda(owner, 6).address, skr, 1000000);
      final ixs = instructions(
        await client.buildExecuteRule(
          executor: executor,
          vaultOwner: owner,
          planId: 6,
          index: 0,
        ),
      );
      expect(ixs, hasLength(3));
      expect(ixs[0].accounts[1].pubKey.toBase58(), ataAddress(treasury, skr));
      expect(ixs[2].accounts[3].isWriteable, isTrue, reason: 'burn');
      expect(ixs[2].accounts[7].pubKey.toBase58(), ataAddress(treasury, skr));
    });

    test('a percentage tier always passes the treasury ATA', () async {
      addPlan(7, [rule(to: alice, mint: nft)]);
      addTokens(vaultPda(owner, 7).address, nft, 1);
      final ixs = instructions(
        await client.buildExecuteRule(
          executor: executor,
          vaultOwner: owner,
          planId: 7,
          index: 0,
        ),
      );
      expect(ixs, hasLength(3));
    });

    test('the claim quote takes 1.5% from SKR and 2% from others', () async {
      addPlan(8, [fixed(alice, skr, 1000000), fixed(bob, usdc, 1000000)]);
      final v = vaultPda(owner, 8).address;
      addTokens(v, skr, 1000000);
      addTokens(v, usdc, 1000000);
      Future<int> net(int i, String claimer) async => (await client.quoteClaim(
        claimer: claimer,
        vaultOwner: owner,
        planId: 8,
        index: i,
      )).net;
      expect(await net(0, alice), 985000);
      expect(await net(1, bob), 980000);
    });

    test('withdrawals keep the share reserved for a skipped tier', () async {
      addPlan(9, [
        rule(to: alice, skippedAt: now - 100, reserved: 3000000000),
        rule(to: bob, afterSecs: 172801),
      ]);
      rpc.accounts[vaultPda(owner, 9).address] = FakeAccount(
        AppConfig.programId,
        rpc.accounts[vaultPda(owner, 9).address]!.data,
        lamports: 5000000000,
      );
      final free = 5000000000 - rpc.rentExempt;
      await expectLater(
        client.buildWithdrawSol(
          owner: owner,
          planId: 9,
          lamports: free - 3000000000 + 1,
        ),
        throwsA(
          isA<DeadmanException>().having(
            (e) => e.code,
            'code',
            DeadmanException.fundsCommitted,
          ),
        ),
      );
      await client.buildWithdrawSol(
        owner: owner,
        planId: 9,
        lamports: free - 3000000000,
      );
    });

    test('a plan with a pending reserve cannot be closed', () async {
      addPlan(10, [
        rule(to: alice, skippedAt: now - 100, reserved: 1000),
        rule(to: bob, afterSecs: 172801),
      ]);
      await expectLater(
        client.buildCloseVault(owner: owner, planId: 10),
        throwsA(
          isA<DeadmanException>()
              .having((e) => e.code, 'code', DeadmanException.fundsCommitted)
              .having((e) => e.message, 'message', contains('skipped')),
        ),
      );
    });
  });
}
