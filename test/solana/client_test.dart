import 'dart:typed_data';

import 'package:deadman/core/config.dart';
import 'package:deadman/kora/kora_client.dart';
import 'package:deadman/solana/codec.dart';
import 'package:deadman/solana/deadman_api.dart';
import 'package:deadman/solana/deadman_client.dart';
import 'package:flutter_test/flutter_test.dart';
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

  RuleState rule({
    required String to,
    String? mint,
    int executedAt = 0,
    Rail rail = Rail.solana,
  }) => RuleState(
    beneficiary: to,
    rail: rail,
    afterSecs: 172800,
    mint: mint,
    mode: AmountMode.percent,
    amount: 5000,
    executedAt: executedAt,
    paid: 0,
  );

  late FakeRpc rpc;
  late DeadmanClient client;

  setUp(() async {
    rpc = await FakeRpc.start();
    client = DeadmanClient(rpc.client());
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
  void addPlan(int planId, List<RuleState> rules, {String? of}) {
    final o = of ?? owner;
    rpc.accounts[vaultPda(o, planId).address] = FakeAccount(
      AppConfig.programId,
      vaultBytes(
        owner: o,
        planId: planId,
        label: 'plan $planId',
        guard: guard,
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
      'ATA create', () async {
    final tx = await client.buildExecuteRule(
      executor: executor,
      vaultOwner: owner,
      planId: 0,
      index: 1,
    );
    final msg = Message.decompile(SignedTx.fromBytes(tx).compiledMessage);
    expect(msg.instructions, hasLength(2));
    expect(msg.instructions[0].programId.toBase58(), ataProgramId);
    expect(
      msg.instructions[0].accounts[1].pubKey.toBase58(),
      ataAddress(treasury, usdc),
    );
    expect(msg.instructions[1].data.toList(), [...Disc.executeTokenRule, 1]);
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
      rules: [rule(to: alice)],
      guardian: guardian,
    );
    expect(tx[0], 1);
  });

  group('Kora', () {
    late FakeKora sponsorNode;

    setUp(() {
      sponsorNode = FakeKora(signer: key(60), paymentAddress: key(60));
    });

    DeadmanClient koraClient() => DeadmanClient.withKora(
      client: rpc.client(),
      sponsor: sponsorNode.client(),
    );

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
        final sig = await koraClient().pulseWithGuard(
          g,
          vaultOwner: owner,
          planIds: [0],
        );
        expect(sig, startsWith('kora'));

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
      await expectLater(
        koraClient().pulseWithGuard(g, vaultOwner: owner, planIds: [0]),
        throwsA(
          isA<DeadmanException>()
              .having((e) => e.name, 'name', 'RuleNotDue')
              .having((e) => e.code, 'code', 6007),
        ),
      );
    });

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

    test(
      'create_vault with a sponsor: owner pays rent, no guard funding',
      () async {
        final wallet = await Ed25519HDKeyPair.random();
        final unsigned = await koraClient().buildCreateVault(
          owner: wallet.address,
          planId: 0,
          label: 'Kids',
          guard: guard,
          intervalSecs: 86400,
          lockSecs: 3600,
          rules: [rule(to: alice)],
        );
        final msg = SignedTx.fromBytes(unsigned).compiledMessage;
        expect(msg.requiredSignatureCount, 1);
        expect(msg.accountKeys[0].toBase58(), wallet.address);
        final ixs = Message.decompile(msg).instructions;
        expect(
          [
            for (final a in ixs.single.accounts)
              (a.pubKey.toBase58(), a.isWriteable, a.isSigner),
          ],
          [
            (wallet.address, true, true),
            (wallet.address, true, true),
            (vaultPda(wallet.address, 0).address, true, false),
            (systemProgramId, false, false),
          ],
        );
        expect(rpc.calls, isNot(contains('getBalance')));
        expect(sponsorNode.calls, isEmpty);
      },
    );

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
