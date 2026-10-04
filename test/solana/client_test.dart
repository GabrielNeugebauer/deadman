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

  List<(String, bool, bool)> metas(Instruction ix) => [
    for (final a in ix.accounts)
      (a.pubKey.toBase58(), a.isWriteable, a.isSigner),
  ];

  /// Account keys only: a decompiled message merges each key's flags across
  /// instructions (exact per-instruction flags are checked in codec_test).
  List<String> addrs(Instruction ix) => [
    for (final a in ix.accounts) a.pubKey.toBase58(),
  ];

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
    }) => client.buildCreateVesting(
      owner: owner,
      planId: 4,
      label: label,
      guard: g ?? guard,
      lockSecs: 3600,
      startAt: startAt,
      revocable: true,
      schedules: schedules ?? [alpha, beta],
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
      ]);
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
      for (final (id, name) in [
        (0, 'WrongPlanKind'),
        (5, 'NotRevocable'),
        (6, 'AlreadyRevoked'),
        (7, 'VaultLocked'),
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
          intervalSecs: 86400,
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
      node = FakeKora(signer: key(70), paymentAddress: key(71));
      c = DeadmanClient.withKora(
        client: rpc.client(),
        paymaster: node.client(),
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
      intervalSecs: 86400,
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

    test('create_vault: Kora pays fee and rent, the wallet pays USDC last; '
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
      expect(ixs[0].data.toList().sublist(0, 8), Disc.createVault);

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
}
