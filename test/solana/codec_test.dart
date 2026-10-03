import 'dart:convert';

import 'package:deadman/core/config.dart';
import 'package:deadman/solana/codec.dart';
import 'package:deadman/solana/deadman_api.dart';
import 'package:deadman/solana/deadman_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:solana/encoder.dart';
import 'package:solana/solana.dart';

import 'helpers.dart';

void main() {
  final owner = key(1);
  final guard = key(2);
  final alice = key(3);
  final bob = key(4);
  final guardian = key(5);
  final usdc = key(6);

  final solFixed = RuleSpec(
    beneficiary: alice,
    rail: Rail.solana,
    afterSecs: 86400 * 2,
    mode: AmountMode.fixed,
    amount: 1500000000,
  );
  final tokenPercent = RuleSpec(
    beneficiary: bob,
    rail: Rail.zcash,
    afterSecs: 86400 * 30,
    mint: usdc,
    mode: AmountMode.percent,
    amount: 5000,
  );

  group('PDA', () {
    test('plan vault PDAs match the async package derivation', () async {
      final client = DeadmanClient();
      final seen = <String>{};
      for (final planId in [0, 7, 0x0102]) {
        final seed = [planId & 0xff, planId >> 8];
        final expected = await Ed25519HDPublicKey.findProgramAddress(
          seeds: [utf8.encode('vault'), keyBytes(owner), seed],
          programId: Ed25519HDPublicKey.fromBase58(AppConfig.programId),
        );
        final pda = vaultPda(owner, planId);
        expect(pda.address, expected.toBase58(), reason: 'plan $planId');
        expect(client.vaultAddressFor(owner, planId), expected.toBase58());
        expect(identical(vaultPda(owner, planId), pda), isTrue);

        final check = await Ed25519HDPublicKey.createProgramAddress(
          seeds: [
            ...utf8.encode('vault'),
            ...keyBytes(owner),
            ...seed,
            pda.bump,
          ],
          programId: Ed25519HDPublicKey.fromBase58(AppConfig.programId),
        );
        expect(check.toBase58(), pda.address);
        seen.add(pda.address);
      }
      expect(seen, hasLength(3), reason: 'plans get distinct vaults');
      expect(() => vaultPda(owner, 0x10000), throwsArgumentError);
      expect(() => vaultPda(owner, -1), throwsArgumentError);
    });

    test('config PDA matches the async package derivation', () async {
      final expected = await Ed25519HDPublicKey.findProgramAddress(
        seeds: [utf8.encode('config')],
        programId: Ed25519HDPublicKey.fromBase58(AppConfig.programId),
      );
      expect(configPda().address, expected.toBase58());
    });

    test(
      'ATA matches the package derivation, including off-curve owners',
      () async {
        for (final o in [alice, vaultPda(owner, 0).address]) {
          final expected = await findAssociatedTokenAddress(
            owner: Ed25519HDPublicKey.fromBase58(o),
            mint: Ed25519HDPublicKey.fromBase58(usdc),
          );
          expect(ataAddress(o, usdc), expected.toBase58());
        }
      },
    );
  });

  group('instruction data', () {
    test('discriminators match the IDL', () {
      final idl = loadIdl();
      List<int> ix(String name) => List<int>.from(
        (idl['instructions'] as List).firstWhere(
              (i) => i['name'] == name,
            )['discriminator']
            as List,
      );
      List<int> acc(String name) => List<int>.from(
        (idl['accounts'] as List).firstWhere(
              (a) => a['name'] == name,
            )['discriminator']
            as List,
      );
      expect(Disc.createVault, ix('create_vault'));
      expect(Disc.updatePolicy, ix('update_policy'));
      expect(Disc.setGuard, ix('set_guard'));
      expect(Disc.pulse, ix('pulse'));
      expect(Disc.lockdown, ix('lockdown'));
      expect(Disc.unlock, ix('unlock'));
      expect(Disc.closeVault, ix('close_vault'));
      expect(Disc.withdrawSol, ix('withdraw_sol'));
      expect(Disc.withdrawToken, ix('withdraw_token'));
      expect(Disc.executeSolRule, ix('execute_sol_rule'));
      expect(Disc.executeTokenRule, ix('execute_token_rule'));
      expect(Disc.vaultAccount, acc('Vault'));
      expect(Disc.configAccount, acc('Config'));
    });

    test('create_vault and update_policy arg order matches the IDL', () {
      List<String> args(String name) => [
        for (final a
            in (loadIdl()['instructions'] as List).firstWhere(
                  (i) => i['name'] == name,
                )['args']
                as List)
          a['name'] as String,
      ];
      expect(args('create_vault'), [
        'plan_id',
        'label',
        'guard',
        'interval_secs',
        'lock_secs',
        'rules',
      ]);
      expect(args('update_policy'), [
        'label',
        'interval_secs',
        'lock_secs',
        'rules',
        'guardian',
      ]);
    });

    test('IDL enum variant order matches Rail and AmountMode', () {
      List<String> variants(String name) => [
        for (final v
            in ((loadIdl()['types'] as List).firstWhere(
                  (t) => t['name'] == name,
                )['type']['variants']
                as List))
          (v['name'] as String).toLowerCase(),
      ];
      expect(variants('Rail'), Rail.values.map((r) => r.name));
      expect(variants('AmountMode'), AmountMode.values.map((m) => m.name));
    });

    final fixedSolBytes = [
      ...keyBytes(alice),
      0,
      ...le(8, 172800),
      0,
      0,
      ...le(8, 1500000000),
    ];
    final percentMintBytes = [
      ...keyBytes(bob),
      2,
      ...le(8, 2592000),
      1,
      ...keyBytes(usdc),
      1,
      ...le(8, 5000),
    ];

    test('create_vault with a Fixed SOL rule and a Percent token rule', () {
      final data = encodeCreateVault(
        planId: 0x0107,
        label: 'Kids',
        guard: guard,
        intervalSecs: 86400,
        lockSecs: 3600,
        rules: [solFixed, tokenPercent],
      );
      expect(data, [
        29, 237, 247, 208, 193, 82, 54, 135, //
        7, 1,
        ...le(4, 4),
        ...utf8.encode('Kids'),
        ...keyBytes(guard),
        ...le(8, 86400),
        ...le(8, 3600),
        ...le(4, 2),
        ...fixedSolBytes,
        ...percentMintBytes,
      ]);
      expect(data.length, 8 + 2 + 4 + 4 + 32 + 16 + 4 + 51 + 83);
    });

    test('update_policy with guardian Some', () {
      final data = encodeUpdatePolicy(
        label: 'Fundo de emergência',
        intervalSecs: 60,
        lockSecs: 180,
        rules: [solFixed, tokenPercent],
        guardian: guardian,
      );
      final label = utf8.encode('Fundo de emergência');
      expect(label, hasLength(20), reason: 'ê is 2 bytes');
      expect(data, [
        212, 245, 246, 7, 163, 151, 18, 57, //
        ...le(4, label.length),
        ...label,
        ...le(8, 60),
        ...le(8, 180),
        ...le(4, 2),
        ...fixedSolBytes,
        ...percentMintBytes,
        1,
        ...keyBytes(guardian),
      ]);
    });

    test('update_policy with guardian None', () {
      final data = encodeUpdatePolicy(
        label: '',
        intervalSecs: 60,
        lockSecs: 180,
        rules: [tokenPercent],
      );
      expect(data, [
        ...Disc.updatePolicy,
        ...le(4, 0),
        ...le(8, 60),
        ...le(8, 180),
        ...le(4, 1),
        ...percentMintBytes,
        0,
      ]);
    });

    test('scalar args', () {
      expect(encodeWithdrawSol(1500000000), [
        ...Disc.withdrawSol,
        ...le(8, 1500000000),
      ]);
      expect(encodeWithdrawToken(7), [...Disc.withdrawToken, ...le(8, 7)]);
      expect(encodeSetGuard(guardian), [
        ...Disc.setGuard,
        ...keyBytes(guardian),
      ]);
      expect(encodeExecuteRule(3, token: false), [...Disc.executeSolRule, 3]);
      expect(encodeExecuteRule(7, token: true), [...Disc.executeTokenRule, 7]);
      expect(() => encodeExecuteRule(256, token: false), throwsArgumentError);
      expect(() => encodeWithdrawSol(-1), throwsArgumentError);
    });

    test('labels are limited to 32 UTF-8 bytes', () {
      expect(labelFits('a' * 32), isTrue);
      expect(labelFits('a' * 33), isFalse);
      expect(labelFits('é' * 16), isTrue);
      expect(labelFits('é' * 17), isFalse, reason: '34 bytes, 17 chars');
    });
  });

  group('policy validation mirrors apply_policy', () {
    int? check(List<RuleSpec> rules, {int interval = 86400, String? g}) =>
        policyError(
          owner: owner,
          guard: guard,
          intervalSecs: interval,
          lockSecs: 3600,
          rules: rules,
          guardian: g,
        );
    RuleSpec rule({
      String? to,
      int after = 172800,
      AmountMode mode = AmountMode.fixed,
      int amount = 1,
    }) => RuleSpec(
      beneficiary: to ?? alice,
      rail: Rail.solana,
      afterSecs: after,
      mode: mode,
      amount: amount,
    );

    test('accepts a valid policy', () {
      expect(check([solFixed, tokenPercent], g: guardian), isNull);
    });

    test('rejects bad durations, rules and guardians', () {
      expect(check([solFixed], interval: 59), 6002);
      expect(check([]), 6003);
      expect(check(List.filled(9, solFixed)), 6003);
      expect(check([rule(after: 86400 + 59)]), 6003);
      expect(check([rule(after: 86400 + 60)]), isNull);
      expect(check([rule(after: 300000), rule(after: 200000)]), 6003);
      expect(check([rule(amount: 0)]), 6003);
      expect(check([rule(mode: AmountMode.percent, amount: 10001)]), 6003);
      expect(check([rule(to: owner)]), 6003);
      expect(check([rule(to: guard)]), 6003);
      expect(check([solFixed], g: alice), 6004);
      expect(check([solFixed], g: owner), 6004);
    });
  });

  group('Vault decoding', () {
    final rules = [
      RuleState(
        beneficiary: alice,
        rail: Rail.solana,
        afterSecs: 172800,
        mode: AmountMode.fixed,
        amount: 1500000000,
        executedAt: 1790172801,
        paid: 1470000000,
      ),
      RuleState(
        beneficiary: bob,
        rail: Rail.cloak,
        afterSecs: 2592000,
        mint: usdc,
        mode: AmountMode.percent,
        amount: 10000,
        executedAt: 0,
        paid: 0,
      ),
    ];

    test('decodes 2 rules (one executed) with guardian, plan id and label', () {
      final v = decodeVault(
        vaultBytes(
          owner: owner,
          planId: 7,
          label: 'Crianças',
          guard: guard,
          guardian: guardian,
          rules: rules,
        ),
        address: 'vault',
        lamports: 3000000000,
        rentExemptMinimum: 3194880,
      );
      expect(v.owner, owner);
      expect(v.planId, 7);
      expect(v.label, 'Crianças');
      expect(v.guard, guard);
      expect(v.guardian, guardian);
      expect(v.intervalSecs, 86400);
      expect(v.lockSecs, 3600);
      expect(v.lastPulse, 1790000000);
      expect(v.lockedUntil, 1790003600);
      expect(v.guardianReadyAt, 1790007200);
      expect(v.totalPulses, 42);
      expect(v.streak, 7);
      expect(v.bestStreak, 12);
      expect(v.rules.length, 2);

      final a = v.rules[0];
      expect(a.beneficiary, alice);
      expect(a.rail, Rail.solana);
      expect(a.afterSecs, 172800);
      expect(a.mint, isNull);
      expect(a.mode, AmountMode.fixed);
      expect(a.amount, 1500000000);
      expect(a.executed, isTrue);
      expect(a.executedAt, 1790172801);
      expect(a.paid, 1470000000);

      final b = v.rules[1];
      expect(b.beneficiary, bob);
      expect(b.rail, Rail.cloak);
      expect(b.mint, usdc);
      expect(b.mode, AmountMode.percent);
      expect(b.amount, 10000);
      expect(b.executed, isFalse);
      expect(b.paid, 0);

      expect(v.lamports, 3000000000);
      expect(v.withdrawableLamports, 3000000000 - 3194880);
    });

    test('decodes guardian None (fields shift by 32 bytes)', () {
      final v = decodeVault(
        vaultBytes(owner: owner, guard: guard, rules: rules),
        address: 'vault',
        lamports: 100,
        rentExemptMinimum: 200,
      );
      expect(v.guardian, isNull);
      expect(v.planId, 0);
      expect(v.label, '');
      expect(v.intervalSecs, 86400);
      expect(v.rules.map((r) => r.beneficiary), [alice, bob]);
      expect(v.withdrawableLamports, 0);
    });

    test('rejects wrong discriminator, truncated data and bad enums', () {
      List<int> bytes() => vaultBytes(owner: owner, guard: guard, rules: rules);
      final bad = bytes()..[0] ^= 1;
      expect(
        () => decodeVault(bad, address: 'x', lamports: 0, rentExemptMinimum: 0),
        throwsFormatException,
      );
      final short = bytes().sublist(0, bytes().length - 1);
      expect(
        () =>
            decodeVault(short, address: 'x', lamports: 0, rentExemptMinimum: 0),
        throwsFormatException,
      );
      // Rail byte of rule 0: 8 + 32 + 2 + 32 + 1 + 5*8 + 8 + 4 + 4 + 4 + 32.
      final badRail = bytes()..[167] = 3;
      expect(
        () => decodeVault(
          badRail,
          address: 'x',
          lamports: 0,
          rentExemptMinimum: 0,
        ),
        throwsFormatException,
      );
    });

    test('decodes Config, mint decimals and token amounts', () {
      final c = decodeConfig(configBytes(admin: owner, treasury: guardian));
      expect(c.admin, owner);
      expect(c.fees.treasury, guardian);
      expect(c.fees.feeBpsPublic, 200);
      expect(c.fees.feeBpsPrivate, 500);
      expect(c.fees.bpsFor(Rail.solana), 200);
      expect(c.fees.bpsFor(Rail.cloak), 500);
      expect(c.fees.bpsFor(Rail.zcash), 500);
      expect(decodeMintDecimals(mintBytes(6)), 6);
      expect(
        decodeTokenAmount(
          tokenAccountBytes(mint: usdc, owner: alice, amount: 123456789),
        ),
        123456789,
      );
    });
  });

  group('VaultState schedule', () {
    RuleState r(int after, {String? mint, bool done = false}) => RuleState(
      beneficiary: alice,
      rail: Rail.solana,
      afterSecs: after,
      mint: mint,
      mode: AmountMode.fixed,
      amount: 1,
      executedAt: done ? 999 : 0,
      paid: 0,
    );
    VaultState vault(List<RuleState> rules) => VaultState(
      address: 'v',
      owner: owner,
      planId: 0,
      label: '',
      guard: guard,
      guardian: null,
      intervalSecs: 60,
      lockSecs: 60,
      lastPulse: 1000,
      lockedUntil: 0,
      guardianReadyAt: 0,
      totalPulses: 1,
      streak: 1,
      bestStreak: 1,
      rules: rules,
      lamports: 0,
      withdrawableLamports: 0,
    );

    final v = vault([r(200, done: true), r(300), r(250, mint: usdc), r(400)]);

    test('nextRuleDue skips executed rules', () {
      expect(v.nextRuleDue, 1250);
      expect(vault([r(200, done: true)]).nextRuleDue, isNull);
    });

    test('canExecute: strictly after the deadline, per-asset order', () {
      expect(v.canExecute(0, 5000), isFalse, reason: 'already executed');
      expect(v.canExecute(1, 1300), isFalse, reason: 'needs now > due');
      expect(v.canExecute(1, 1301), isTrue);
      expect(v.canExecute(2, 1251), isTrue, reason: 'other asset');
      expect(v.canExecute(3, 5000), isFalse, reason: 'rule 1 pending');
      expect(
        vault([r(200, done: true), r(300, done: true), r(400)])
            .canExecute(2, 1401),
        isTrue,
      );
    });

    test('completed once every rule has executed', () {
      expect(v.completed, isFalse);
      expect(vault([r(200, done: true), r(300, done: true)]).completed, isTrue);
    });
  });

  group('instruction accounts', () {
    final treasury = key(7);
    final executor = key(8);
    const planId = 3;
    final vault = vaultPda(owner, planId).address;

    List<(String, bool, bool)> metas(Instruction ix) => [
      for (final a in ix.accounts)
        (a.pubKey.toBase58(), a.isWriteable, a.isSigner),
    ];

    test('execute_sol_rule', () {
      final ixs = executeRuleIxs(
        executor: executor,
        vaultOwner: owner,
        planId: planId,
        rule: solFixed,
        index: 0,
        treasury: treasury,
      );
      expect(ixs, hasLength(1));
      expect(ixs.single.programId.toBase58(), AppConfig.programId);
      expect(metas(ixs.single), [
        (executor, false, true),
        (vault, true, false),
        (configPda().address, false, false),
        (alice, true, false),
        (treasury, true, false),
      ]);
      expect(ixs.single.data.toList(), [...Disc.executeSolRule, 0]);
    });

    test('execute_token_rule with the treasury ATA create prepended', () {
      final ixs = executeRuleIxs(
        executor: executor,
        vaultOwner: owner,
        planId: planId,
        rule: tokenPercent,
        index: 1,
        treasury: treasury,
      );
      expect(ixs, hasLength(2));

      final create = ixs[0];
      expect(create.programId.toBase58(), ataProgramId);
      expect(create.data.toList(), [1]);
      expect(metas(create), [
        (executor, true, true),
        (ataAddress(treasury, usdc), true, false),
        (treasury, false, false),
        (usdc, false, false),
        (systemProgramId, false, false),
        (tokenProgramId, false, false),
      ]);

      final exec = ixs[1];
      expect(exec.programId.toBase58(), AppConfig.programId);
      expect(metas(exec), [
        (executor, true, true),
        (vault, true, false),
        (configPda().address, false, false),
        (usdc, false, false),
        (ataAddress(vault, usdc), true, false),
        (bob, true, false),
        (ataAddress(bob, usdc), true, false),
        (ataAddress(treasury, usdc), true, false),
        (tokenProgramId, false, false),
        (ataProgramId, false, false),
        (systemProgramId, false, false),
      ]);
      expect(exec.data.toList(), [...Disc.executeTokenRule, 1]);
    });

    test('execute_* account names and flags match the IDL', () {
      final idl = loadIdl()['instructions'] as List;
      List<(bool, bool)> flags(String name) => [
        for (final a
            in idl.firstWhere((i) => i['name'] == name)['accounts'] as List)
          (a['writable'] == true, a['signer'] == true),
      ];
      final sol = executeRuleIxs(
        executor: executor,
        vaultOwner: owner,
        planId: planId,
        rule: solFixed,
        index: 0,
        treasury: treasury,
      ).single;
      final token = executeRuleIxs(
        executor: executor,
        vaultOwner: owner,
        planId: planId,
        rule: tokenPercent,
        index: 1,
        treasury: treasury,
      ).last;
      final withdraw = withdrawTokenIxs(
        owner: owner,
        planId: planId,
        mint: usdc,
        amount: 5,
      ).last;
      (bool, bool) f(AccountMeta a) => (a.isWriteable, a.isSigner);
      final create = createVaultIx(
        owner: owner,
        payer: executor,
        planId: planId,
        data: const [],
      );
      expect(create.accounts.map(f), flags('create_vault'));
      expect(sol.accounts.map(f), flags('execute_sol_rule'));
      expect(token.accounts.map(f), flags('execute_token_rule'));
      expect(withdraw.accounts.map(f), flags('withdraw_token'));
    });

    test('deposit token: vault ATA create, then TransferChecked', () {
      final ixs = depositTokenIxs(
        owner: owner,
        planId: planId,
        mint: usdc,
        amount: 2500000,
        decimals: 6,
      );
      expect(ixs, hasLength(2));
      expect(metas(ixs[0]), [
        (owner, true, true),
        (ataAddress(vault, usdc), true, false),
        (vault, false, false),
        (usdc, false, false),
        (systemProgramId, false, false),
        (tokenProgramId, false, false),
      ]);
      expect(ixs[1].programId.toBase58(), tokenProgramId);
      expect(metas(ixs[1]), [
        (ataAddress(owner, usdc), true, false),
        (usdc, false, false),
        (ataAddress(vault, usdc), true, false),
        (owner, false, true),
      ]);
      expect(ixs[1].data.toList(), [12, ...le(8, 2500000), 6]);
    });

    test('create_vault: read-only owner, separate rent payer', () {
      final kora = key(9);
      final ix = createVaultIx(
        owner: owner,
        payer: kora,
        planId: planId,
        data: Disc.createVault,
      );
      expect(ix.programId.toBase58(), AppConfig.programId);
      expect(metas(ix), [
        (owner, false, true),
        (kora, true, true),
        (vault, true, false),
        (systemProgramId, false, false),
      ]);
    });

    test('withdraw token: owner ATA create, then withdraw_token', () {
      final ixs = withdrawTokenIxs(
        owner: owner,
        planId: planId,
        mint: usdc,
        amount: 9,
      );
      expect(ixs[0].accounts[1].pubKey.toBase58(), ataAddress(owner, usdc));
      expect(metas(ixs[1]), [
        (owner, true, true),
        (vault, true, false),
        (usdc, false, false),
        (ataAddress(vault, usdc), true, false),
        (ataAddress(owner, usdc), true, false),
        (tokenProgramId, false, false),
      ]);
      expect(ixs[1].data.toList(), [...Disc.withdrawToken, ...le(8, 9)]);
    });
  });

  group('transaction serialization', () {
    test('zeroed signature slot and fee payer first', () {
      final blockhash = key(9);
      final ix = pulseOrLockdownIx(
        signer: owner,
        vaultOwner: owner,
        planId: 0,
        lockdown: false,
      );
      final bytes = serializeUnsigned(
        [ix],
        feePayer: owner,
        recentBlockhash: blockhash,
      );
      expect(bytes[0], 1);
      expect(bytes.sublist(1, 65), List.filled(64, 0));

      final tx = SignedTx.fromBytes(bytes);
      final msg = tx.compiledMessage;
      expect(msg.requiredSignatureCount, 1);
      expect(msg.accountKeys.first.toBase58(), owner);
      expect(msg.recentBlockhash, blockhash);
      expect(msg.instructions.single.data.toList(), Disc.pulse);
    });

    test('external fee payer: two zeroed slots, payer first, then partial '
        'signing fills only the signer slot', () async {
      final kora = key(9);
      final wallet = await Ed25519HDKeyPair.random();
      final bytes = serializeUnsigned(
        [
          pulseOrLockdownIx(
            signer: wallet.address,
            vaultOwner: owner,
            planId: 0,
            lockdown: false,
          ),
        ],
        feePayer: kora,
        recentBlockhash: key(10),
      );
      expect(bytes[0], 2);
      expect(bytes.sublist(1, 129), List.filled(128, 0));
      final msg = SignedTx.fromBytes(bytes).compiledMessage;
      expect(msg.accountKeys[0].toBase58(), kora);
      expect(msg.accountKeys[1].toBase58(), wallet.address);

      final signed = SignedTx.fromBytes(await partiallySign(bytes, wallet));
      expect(signed.signatures[0].bytes, List.filled(64, 0));
      expect(
        await verifySignature(
          message: msg.toByteArray().toList(),
          signature: signed.signatures[1].bytes,
          publicKey: wallet.publicKey,
        ),
        isTrue,
      );
      expect(
        signed.compiledMessage.toByteArray().toList(),
        msg.toByteArray().toList(),
      );
      await expectLater(
        partiallySign(bytes, await Ed25519HDKeyPair.random()),
        throwsArgumentError,
      );
    });
  });

  group('errors', () {
    test('error table matches the IDL exactly', () {
      final errors = loadIdl()['errors'] as List;
      expect(errors, hasLength(19));
      expect(DeadmanException.programErrors, {
        for (final e in errors)
          e['code'] as int: (e['name'] as String, e['msg'] as String),
      });
    });

    test('maps Anchor custom errors', () {
      final e = DeadmanException.fromTxError({
        'InstructionError': [
          1,
          {'Custom': 6007},
        ],
      });
      expect(e.name, 'RuleNotDue');
      expect(e.code, 6007);
      expect(
        e.message,
        "The owner is still within this rule's inactivity window",
      );
    });

    test('maps preflight failures with logs', () {
      final e = DeadmanException.fromRpc(
        JsonRpcException('Transaction simulation failed', -32002, {
          'err': {
            'InstructionError': [
              0,
              {'Custom': 6009},
            ],
          },
          'logs': ['Program log: AnchorError'],
        }),
      );
      expect(e.name, 'RuleOutOfOrder');
      expect(e.logs, ['Program log: AnchorError']);
    });

    test('unknown errors fall back', () {
      final e = DeadmanException.fromTxError({
        'InstructionError': [
          0,
          {'Custom': 1},
        ],
      }, fallback: 'insufficient funds');
      expect(e.name, isNull);
      expect(e.code, 1);
      expect(e.message, 'insufficient funds');
      expect(DeadmanException.program(6011).name, 'InvalidRuleIndex');
      expect(
        DeadmanException.program(DeadmanException.planCompleted).name,
        'PlanCompleted',
      );
      expect(
        DeadmanException.program(DeadmanException.labelTooLong).name,
        'LabelTooLong',
      );
    });
  });
}
