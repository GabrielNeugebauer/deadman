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
  final bob = key(4);
  final guardian = key(5);
  final usdc = key(6);
  final treasury = key(7);
  final executor = key(8);
  final vault = vaultPda(owner).address;

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

  test('fetchVault decodes and computes withdrawable lamports', () async {
    final v = await client.fetchVault(owner);
    expect(v, isNotNull);
    expect(v!.address, vault);
    expect(v.rules, hasLength(2));
    expect(v.withdrawableLamports, 5000000000 - rpc.rentExempt);
    expect(await client.fetchVault(alice), isNull);
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
        guard: guard,
        intervalSecs: 86400,
        lockSecs: 3600,
        rules: [rule(to: guard)],
      ),
      throwsA(isA<DeadmanException>().having((e) => e.code, 'code', 6003)),
    );
    final tx = await client.buildUpdatePolicy(
      owner: owner,
      intervalSecs: 86400,
      lockSecs: 3600,
      rules: [rule(to: alice)],
      guardian: guardian,
    );
    expect(tx[0], 1);
  });
}
