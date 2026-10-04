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
        intervalSecs: 86400,
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

    test('without Kora the owner is the rent payer and fee payer', () async {
      final tx = await client.buildCreateVault(
        owner: owner,
        planId: 0,
        label: 'Kids',
        guard: guard,
        intervalSecs: 86400,
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
      expect(ixs[0].data.toList().sublist(8, 14), [7, 0, 4, 0, 0, 0]);
      expect(
        ixs[0].data.toList().sublist(14 + 4 + 32 + 16, 14 + 4 + 32 + 24),
        le(8, grace),
      );
      expect(ixs[1].accounts[1].pubKey.toBase58(), vaultPda(owner, 7).address);
    });

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
          intervalSecs: 86400,
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
    expect(fees.feeBpsPrivate, 500);
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

  test('buildExecuteRule picks the token variant and prepends the treasury '
      'and beneficiary ATA creates', () async {
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
    expect(exec.accounts[6].pubKey.toBase58(), ataAddress(bob, usdc));
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
        intervalSecs: 86400,
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
      intervalSecs: 86400,
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
      intervalSecs: 86400,
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

    test('encodes the grace period after the lock duration', () async {
      final ix = instructions(await update([rule(to: bob)])).single;
      final data = ix.data.toList();
      expect(data.sublist(8, 8 + 4 + 4 + 24), [
        ...le(4, 4),
        ...'Kids'.codeUnits,
        ...le(8, 86400),
        ...le(8, 3600),
        ...le(8, grace),
      ]);
      expect(ix.accounts.map((a) => a.pubKey.toBase58()), [owner, vault]);
    });

    test('released tiers count toward the cap until all have run', () async {
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
      expect(
        instructions(await update(List.filled(8, rule(to: bob)), planId: 5)),
        hasLength(1),
        reason: 'a fully released plan starts fresh',
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
      final ix = instructions(rpc.sent.single).single;
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

    test('create_vault with a sponsor: owner pays rent and still funds an '
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
        intervalSecs: 86400,
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
}
