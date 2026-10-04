import 'dart:convert';
import 'dart:typed_data';

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
      expect(Disc.skipRule, ix('skip_rule'));
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
        'skip_grace_secs',
        'rules',
      ]);
      expect(args('update_policy'), [
        'label',
        'interval_secs',
        'lock_secs',
        'skip_grace_secs',
        'rules',
        'guardian',
      ]);
      expect(args('skip_rule'), ['index']);
    });

    test('IDL Rule field order matches the decoder', () {
      final fields = [
        for (final f
            in ((loadIdl()['types'] as List).firstWhere(
                  (t) => t['name'] == 'Rule',
                )['type']['fields']
                as List))
          f['name'] as String,
      ];
      expect(fields, [
        'beneficiary',
        'rail',
        'after_secs',
        'mint',
        'mode',
        'amount',
        'executed_at',
        'paid',
        'skipped_at',
        'reserved',
        'duration_secs',
        'released',
      ]);
    });

    test('IDL skip_rule takes an optional vault_token', () {
      final accounts =
          (loadIdl()['instructions'] as List).firstWhere(
                (i) => i['name'] == 'skip_rule',
              )['accounts']
              as List;
      expect(accounts.map((a) => a['name']), [
        'caller',
        'vault',
        'vault_token',
      ]);
      expect(accounts.last['optional'], isTrue);
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
        skipGraceSecs: 604800,
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
        ...le(8, 604800),
        ...le(4, 2),
        ...fixedSolBytes,
        ...percentMintBytes,
      ]);
      expect(data.length, 8 + 2 + 4 + 4 + 32 + 24 + 4 + 51 + 83);
    });

    test('update_policy with guardian Some', () {
      final data = encodeUpdatePolicy(
        label: 'Fundo de emergência',
        intervalSecs: 60,
        lockSecs: 180,
        skipGraceSecs: 120,
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
        ...le(8, 120),
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
        skipGraceSecs: 366 * 86400,
        rules: [tokenPercent],
      );
      expect(data, [
        ...Disc.updatePolicy,
        ...le(4, 0),
        ...le(8, 60),
        ...le(8, 180),
        ...le(8, 366 * 86400),
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
      expect(encodeSkipRule(5), [...Disc.skipRule, 5]);
      expect(() => encodeSkipRule(256), throwsArgumentError);
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
    final vault = vaultPda(owner, 0).address;
    int? check(
      List<RuleSpec> rules, {
      int interval = 86400,
      int grace = 30 * 86400,
      int history = 0,
      String? g,
    }) => policyError(
      owner: owner,
      vault: vault,
      guard: guard,
      intervalSecs: interval,
      lockSecs: 3600,
      skipGraceSecs: grace,
      rules: rules,
      historyCount: history,
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
      expect(check([rule(to: vault)]), 6003, reason: 'FUNDS-8');
    });

    test('skip grace bounds are 60 s ..= 366 days', () {
      expect(check([solFixed], grace: 59), 6002);
      expect(check([solFixed], grace: 60), isNull);
      expect(check([solFixed], grace: 366 * 86400), isNull);
      expect(check([solFixed], grace: 366 * 86400 + 1), 6002);
    });

    test('released tiers kept as history count toward the 8-rule cap', () {
      expect(check(List.filled(3, solFixed), history: 5), isNull);
      expect(check(List.filled(3, solFixed), history: 6), 6003);
      expect(check([], history: 2), 6003, reason: 'new rules are required');
    });

    test('policyHistoryCount: paid or skipped tiers, or none once all '
        'paid', () {
      RuleState r({bool done = false, bool skipped = false}) => RuleState(
        beneficiary: alice,
        rail: Rail.solana,
        afterSecs: 172800,
        mode: AmountMode.fixed,
        amount: 1,
        executedAt: done ? 5 : 0,
        paid: 0,
        skippedAt: skipped ? 4 : 0,
      );
      VaultState v(List<RuleState> rules) => decodeVault(
        vaultBytes(owner: owner, guard: guard, rules: rules),
        address: vault,
        lamports: 0,
        rentExemptMinimum: 0,
      );
      expect(policyHistoryCount(v([r(done: true), r(), r(done: true)])), 2);
      expect(policyHistoryCount(v([r(done: true), r(done: true)])), 0);
      expect(policyHistoryCount(v([r()])), 0);
      // A skipped, unclaimed tier stays as history and keeps the plan open.
      expect(policyHistoryCount(v([r(done: true), r(skipped: true), r()])), 2);
      expect(policyHistoryCount(v([r(done: true), r(skipped: true)])), 2);
      expect(
        policyHistoryCount(v([r(done: true, skipped: true), r(done: true)])),
        0,
      );
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
      RuleState(
        beneficiary: guardian,
        rail: Rail.solana,
        afterSecs: 2592000,
        mode: AmountMode.fixed,
        amount: 7,
        executedAt: 0,
        paid: 0,
        skippedAt: 1790300000,
        reserved: 123456789,
      ),
    ];

    test(
      'decodes 3 rules (paid, pending, skipped) with the new vault fields',
      () {
        final v = decodeVault(
          vaultBytes(
            owner: owner,
            planId: 7,
            label: 'Crianças',
            guard: guard,
            guardian: guardian,
            skipGraceSecs: 604800,
            ownerLastSeen: 1789000000,
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
        expect(v.skipGraceSecs, 604800);
        expect(v.lastPulse, 1790000000);
        expect(v.ownerLastSeen, 1789000000);
        expect(v.lockedUntil, 1790003600);
        expect(v.guardianReadyAt, 1790007200);
        expect(v.totalPulses, 42);
        expect(v.streak, 7);
        expect(v.bestStreak, 12);
        expect(v.rules.length, 3);

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
        expect(a.skipped, isFalse);

        final b = v.rules[1];
        expect(b.beneficiary, bob);
        expect(b.rail, Rail.cloak);
        expect(b.mint, usdc);
        expect(b.mode, AmountMode.percent);
        expect(b.amount, 10000);
        expect(b.executed, isFalse);
        expect(b.paid, 0);
        expect(b.skipped, isFalse);

        final c = v.rules[2];
        expect(c.executed, isFalse);
        expect(c.skipped, isTrue);
        expect(c.skippedAt, 1790300000);
        expect(c.reserved, 123456789);
        expect(c.paid, 0);
        expect(a.skippedAt, 0);
        expect(a.reserved, 0);

        expect(v.lamports, 3000000000);
        expect(v.withdrawableLamports, 3000000000 - 3194880);
      },
    );

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
      expect(v.rules.map((r) => r.beneficiary), [alice, bob, guardian]);
      expect(v.skipGraceSecs, 30 * 86400);
      expect(v.ownerLastSeen, v.lastPulse);
      expect(v.withdrawableLamports, 0);
    });

    test('rejects wrong discriminator, truncated data and bad enums', () {
      List<int> bytes() => vaultBytes(owner: owner, guard: guard, rules: rules);
      final bad = bytes()..[0] ^= 1;
      expect(
        () => decodeVault(bad, address: 'x', lamports: 0, rentExemptMinimum: 0),
        throwsFormatException,
      );
      // Cut inside rule 0 (the zero padding after the label is not data).
      final short = bytes().sublist(0, 260);
      expect(
        () =>
            decodeVault(short, address: 'x', lamports: 0, rentExemptMinimum: 0),
        throwsFormatException,
      );
      // Rail byte of rule 0: 8 + 32 + 2 + 32 + 1 + 7*8 + 8 + 4 + 4
      // + kind 1 + start_at 8 + revocable 1 + revoked_at 8 + rent_payer 32
      // + rent_paid 8 + 4 + 32.
      final badRail = bytes()..[241] = 3;
      expect(
        () => decodeVault(
          badRail,
          address: 'x',
          lamports: 0,
          rentExemptMinimum: 0,
        ),
        throwsFormatException,
      );
      // AmountMode of rule 0: rail offset + 1 + 8 + 1 (no mint).
      final badMode = bytes()..[241 + 10] = 2;
      expect(
        () => decodeVault(
          badMode,
          address: 'x',
          lamports: 0,
          rentExemptMinimum: 0,
        ),
        throwsFormatException,
      );
    });

    test('rule layout: skipped_at, reserved, duration_secs, released after '
        'paid (99 bytes)', () {
      // SOL rule: beneficiary 32, rail 1, after_secs 8, mint None 1, mode 1,
      // amount 8, then executed_at, paid, skipped_at, reserved,
      // duration_secs, released (8 each).
      final bytes = Uint8List.fromList(
        vaultBytes(owner: owner, guard: guard, rules: rules),
      );
      const start = 241 - 32; // beneficiary of rule 0
      int at(int offset) => ByteData.sublistView(
        bytes,
        start + offset,
        start + offset + 8,
      ).getInt64(0, Endian.little);
      expect(at(51), 1790172801, reason: 'executed_at');
      expect(at(59), 1470000000, reason: 'paid');
      expect(at(67), 0, reason: 'skipped_at');
      expect(at(75), 0, reason: 'reserved');
      expect(at(83), 0, reason: 'duration_secs');
      expect(at(91), 0, reason: 'released');
      expect(bytes.sublist(start + 99, start + 131), keyBytes(bob));
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
    RuleState r(
      int after, {
      String? mint,
      bool done = false,
      int skippedAt = 0,
    }) => RuleState(
      beneficiary: alice,
      rail: Rail.solana,
      afterSecs: after,
      mint: mint,
      mode: AmountMode.fixed,
      amount: 1,
      executedAt: done ? 999 : 0,
      paid: 0,
      skippedAt: skippedAt,
      reserved: skippedAt == 0 ? 0 : 5,
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
      skipGraceSecs: 100,
      lastPulse: 1000,
      ownerLastSeen: 900,
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

    test('canSkip: after due + grace, per-asset order', () {
      expect(v.canSkip(1, 1400), isFalse, reason: 'needs now > due + grace');
      expect(v.canSkip(1, 1401), isTrue);
      expect(v.canSkip(3, 9999), isFalse, reason: 'rule 1 pending');
      expect(v.canSkip(0, 9999), isFalse, reason: 'already executed');
    });

    test('guardCanPulse: within a year of the owner, no release since', () {
      final open = vault([r(200), r(300)]);
      const year = VaultState.guardWindowSecs;
      expect(open.guardCanPulse(900 + year), isTrue);
      expect(open.guardCanPulse(901 + year), isFalse);
      expect(v.guardCanPulse(1000), isFalse, reason: 'tier ran at 999 > 900');
    });

    test('completed once every rule has executed', () {
      expect(v.completed, isFalse);
      expect(vault([r(200, done: true), r(300, done: true)]).completed, isTrue);
    });

    group('skipped tiers', () {
      // Tier 1 (SOL) was skipped at 1500; tier 3 (SOL) follows it.
      final s = vault([
        r(200, done: true),
        r(300, skippedAt: 1500),
        r(250, mint: usdc),
        r(400),
      ]);

      test('a skipped tier is claimable at any time, until it pays', () {
        expect(s.canExecute(1, 0), isTrue, reason: 'no due check');
        expect(s.canExecute(1, 99999), isTrue);
        final claimed = vault([r(300, done: true, skippedAt: 1500)]);
        expect(claimed.canExecute(0, 99999), isFalse, reason: 'already paid');
        // Skipped tiers are claimable even out of order: an unsettled
        // earlier tier of the same asset does not block the claim.
        final out = vault([r(200), r(300, skippedAt: 1500)]);
        expect(out.canExecute(1, 0), isTrue);
      });

      test('later same-asset tiers treat a skipped tier as settled', () {
        expect(s.canExecute(3, 1400), isFalse, reason: 'needs now > due');
        expect(s.canExecute(3, 1401), isTrue);
        expect(s.canSkip(3, 1501), isTrue);
        expect(s.canSkip(3, 1500), isFalse, reason: 'needs now > due + grace');
      });

      test('a skipped tier is never skipped again', () {
        expect(s.canSkip(1, 99999), isFalse);
        expect(
          vault([r(300, done: true, skippedAt: 1500)]).canSkip(0, 99999),
          isFalse,
        );
      });

      test('guard pulse is rejected after a skip the owner has not seen', () {
        expect(s.guardCanPulse(1600), isFalse, reason: 'skipped 1500 > 900');
        final seen = vault([r(300, skippedAt: 800), r(400)]);
        expect(seen.guardCanPulse(1600), isTrue, reason: 'skipped 800 < 900');
      });

      test('a skipped but unpaid tier keeps the plan open', () {
        final waiting = vault([r(200, done: true), r(300, skippedAt: 1500)]);
        expect(waiting.completed, isFalse);
        expect(waiting.nextRuleDue, isNull, reason: 'nothing left pending');
        expect(
          vault([r(200, done: true), r(300, done: true, skippedAt: 1500)])
              .completed,
          isTrue,
        );
      });

      test('nextRuleDue ignores skipped tiers', () {
        expect(s.nextRuleDue, 1250);
        expect(vault([r(300, skippedAt: 1500), r(400)]).nextRuleDue, 1400);
      });
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

    test('execute_token_rule: treasury and beneficiary ATA creates first, '
        'no ATA or system program', () {
      final ixs = executeRuleIxs(
        executor: executor,
        vaultOwner: owner,
        planId: planId,
        rule: tokenPercent,
        index: 1,
        treasury: treasury,
      );
      expect(ixs, hasLength(3));

      for (final (create, owner) in [(ixs[0], treasury), (ixs[1], bob)]) {
        expect(create.programId.toBase58(), ataProgramId);
        expect(create.data.toList(), [1], reason: 'CreateIdempotent');
        expect(metas(create), [
          (executor, true, true),
          (ataAddress(owner, usdc), true, false),
          (owner, false, false),
          (usdc, false, false),
          (systemProgramId, false, false),
          (tokenProgramId, false, false),
        ]);
      }

      final exec = ixs[2];
      expect(exec.programId.toBase58(), AppConfig.programId);
      expect(metas(exec), [
        (executor, false, true),
        (vault, true, false),
        (configPda().address, false, false),
        (usdc, false, false),
        (ataAddress(vault, usdc), true, false),
        (bob, true, false),
        (ataAddress(bob, usdc), true, false),
        (ataAddress(treasury, usdc), true, false),
        (tokenProgramId, false, false),
      ]);
      expect(exec.data.toList(), [...Disc.executeTokenRule, 1]);
    });

    test('skip_rule SOL tier: vault_token omitted as the program id', () {
      final ix = skipRuleIx(
        caller: executor,
        vaultOwner: owner,
        planId: planId,
        index: 2,
      );
      expect(ix.programId.toBase58(), AppConfig.programId);
      expect(metas(ix), [
        (executor, false, true),
        (vault, true, false),
        (AppConfig.programId, false, false),
      ]);
      expect(ix.data.toList(), [...Disc.skipRule, 2]);
    });

    test('skip_rule token tier: vault_token is the vault ATA', () {
      final ix = skipRuleIx(
        caller: executor,
        vaultOwner: owner,
        planId: planId,
        index: 1,
        mint: usdc,
      );
      expect(metas(ix), [
        (executor, false, true),
        (vault, true, false),
        (ataAddress(vault, usdc), false, false),
      ]);
      expect(ix.data.toList(), [...Disc.skipRule, 1]);
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
      for (final mint in [null, usdc]) {
        final skip = skipRuleIx(
          caller: executor,
          vaultOwner: owner,
          planId: planId,
          index: 0,
          mint: mint,
        );
        expect(skip.accounts.map(f), flags('skip_rule'));
      }
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
      expect(errors, hasLength(29));
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

    test('new errors have names and user-facing messages', () {
      for (final (code, name, words) in [
        (6017, 'OwnerConfirmationRequired', 'wallet'),
        (6018, 'NothingToPay', 'nothing to pay'),
        (6019, 'BeneficiaryCannotReceive', 'cannot receive'),
        (6020, 'SkipTooEarly', 'grace period'),
        (6021, 'WrongPlanKind', 'vesting plans need no check-ins'),
        (6022, 'InvalidVesting', 'cliff no longer than its duration'),
        (6023, 'NotRevocable', 'irrevocable'),
        (6024, 'AlreadyRevoked', 'already stopped'),
        (6025, 'FundsCommitted', 'owed to vesting beneficiaries'),
        (6026, 'InvalidConfig', 'Treasury'),
        (6027, 'MathOverflow', 'overflow'),
      ]) {
        final e = DeadmanException.fromTxError({
          'InstructionError': [
            0,
            {'Custom': code},
          ],
        });
        expect(e.name, name);
        expect(e.message, contains(words));
      }
      int codeOf(String name) => DeadmanException.programErrors.entries
          .firstWhere((e) => e.value.$1 == name)
          .key;
      expect(
        DeadmanException.ownerConfirmationRequired,
        codeOf('OwnerConfirmationRequired'),
      );
      for (final (code, name) in [
        (DeadmanException.vaultLocked, 'VaultLocked'),
        (DeadmanException.ruleAlreadyExecuted, 'RuleAlreadyExecuted'),
        (DeadmanException.invalidRuleIndex, 'InvalidRuleIndex'),
        (DeadmanException.insufficientFunds, 'InsufficientFunds'),
        (DeadmanException.nothingToPay, 'NothingToPay'),
        (DeadmanException.wrongPlanKind, 'WrongPlanKind'),
        (DeadmanException.invalidVesting, 'InvalidVesting'),
        (DeadmanException.notRevocable, 'NotRevocable'),
        (DeadmanException.alreadyRevoked, 'AlreadyRevoked'),
        (DeadmanException.fundsCommitted, 'FundsCommitted'),
      ]) {
        expect(code, codeOf(name), reason: name);
      }
    });
  });

  group('vesting', () {
    final treasury = key(7);
    final executor = key(8);
    final kora = key(9);
    const planId = 3;
    final vault = vaultPda(owner, planId).address;
    const now = 1790500000;

    Map<String, dynamic> idlIx(String name) =>
        ((loadIdl()['instructions'] as List).firstWhere(
          (i) => i['name'] == name,
        ) as Map).cast<String, dynamic>();
    List<String> idlFields(String type) => [
      for (final f
          in ((loadIdl()['types'] as List).firstWhere(
                (t) => t['name'] == type,
              )['type']['fields']
              as List))
        f['name'] as String,
    ];
    List<(bool, bool)> idlFlags(String name) => [
      for (final a in idlIx(name)['accounts'] as List)
        (a['writable'] == true, a['signer'] == true),
    ];
    List<(String, bool, bool)> metas(Instruction ix) => [
      for (final a in ix.accounts)
        (a.pubKey.toBase58(), a.isWriteable, a.isSigner),
    ];

    final solSchedule = VestingSpec(
      beneficiary: alice,
      rail: Rail.solana,
      total: 4000000000,
      cliffSecs: 86400 * 90,
      durationSecs: 86400 * 365,
    );
    final usdcSchedule = VestingSpec(
      beneficiary: bob,
      rail: Rail.cloak,
      mint: usdc,
      total: 1200000000,
      cliffSecs: 0,
      durationSecs: 86400 * 730,
    );

    test('discriminators, args and types match the IDL', () {
      List<int> disc(String name) =>
          List<int>.from(idlIx(name)['discriminator'] as List);
      expect(Disc.createVesting, disc('create_vesting'));
      expect(Disc.revokeVesting, disc('revoke_vesting'));
      expect(Disc.releaseVestedSol, disc('release_vested_sol'));
      expect(Disc.releaseVestedToken, disc('release_vested_token'));
      expect(
        [for (final a in idlIx('create_vesting')['args'] as List) a['name']],
        [
          'plan_id',
          'label',
          'guard',
          'lock_secs',
          'start_at',
          'revocable',
          'schedules',
        ],
      );
      expect(idlIx('revoke_vesting')['args'], isEmpty);
      expect(idlFields('VestingInput'), [
        'beneficiary',
        'rail',
        'mint',
        'total',
        'cliff_secs',
        'duration_secs',
      ]);
      expect(idlFields('Vault'), [
        'owner',
        'plan_id',
        'guard',
        'guardian',
        'interval_secs',
        'lock_secs',
        'skip_grace_secs',
        'last_pulse',
        'owner_last_seen',
        'locked_until',
        'guardian_ready_at',
        'total_pulses',
        'streak',
        'best_streak',
        'kind',
        'start_at',
        'revocable',
        'revoked_at',
        'rent_payer',
        'rent_paid',
        'rules',
        'label',
        'bump',
        'stipend_paid',
        '_reserved',
      ]);
      final kinds = [
        for (final v
            in ((loadIdl()['types'] as List).firstWhere(
                  (t) => t['name'] == 'PlanKind',
                )['type']['variants']
                as List))
          (v['name'] as String).toLowerCase(),
      ];
      expect(kinds, PlanKind.values.map((k) => k.name));
    });

    test('create_vesting encoding', () {
      final data = encodeCreateVesting(
        planId: 0x0203,
        label: 'Team',
        guard: guard,
        lockSecs: 3600,
        startAt: 1790000000,
        revocable: true,
        schedules: [solSchedule, usdcSchedule],
      );
      expect(data, [
        ...Disc.createVesting,
        3,
        2,
        ...le(4, 4),
        ...utf8.encode('Team'),
        ...keyBytes(guard),
        ...le(8, 3600),
        ...le(8, 1790000000),
        1,
        ...le(4, 2),
        ...keyBytes(alice),
        0,
        0,
        ...le(8, 4000000000),
        ...le(8, 86400 * 90),
        ...le(8, 86400 * 365),
        ...keyBytes(bob),
        1,
        1,
        ...keyBytes(usdc),
        ...le(8, 1200000000),
        ...le(8, 0),
        ...le(8, 86400 * 730),
      ]);
      final irrevocable = encodeCreateVesting(
        planId: 0,
        label: '',
        guard: guard,
        lockSecs: 60,
        startAt: 0,
        revocable: false,
        schedules: [solSchedule],
      );
      expect(irrevocable[8 + 2 + 4 + 32 + 16], 0, reason: 'revocable false');
    });

    test('release, revoke and close instructions match the IDL accounts', () {
      (bool, bool) f(AccountMeta a) => (a.isWriteable, a.isSigner);
      final sol = releaseVestedIxs(
        executor: executor,
        vaultOwner: owner,
        planId: planId,
        rule: RuleSpec(
          beneficiary: alice,
          rail: Rail.solana,
          afterSecs: 0,
          mode: AmountMode.fixed,
          amount: 1,
        ),
        index: 0,
        treasury: treasury,
      );
      expect(sol, hasLength(1));
      expect(sol.single.data.toList(), [...Disc.releaseVestedSol, 0]);
      expect(sol.single.accounts.map(f), idlFlags('release_vested_sol'));
      expect(metas(sol.single), [
        (executor, false, true),
        (vault, true, false),
        (configPda().address, false, false),
        (alice, true, false),
        (treasury, true, false),
      ]);

      final token = releaseVestedIxs(
        executor: executor,
        vaultOwner: owner,
        planId: planId,
        rule: RuleSpec(
          beneficiary: bob,
          rail: Rail.cloak,
          afterSecs: 0,
          mint: usdc,
          mode: AmountMode.fixed,
          amount: 1,
        ),
        index: 1,
        treasury: treasury,
        payer: kora,
      );
      expect(token, hasLength(3));
      expect(token[0].programId.toBase58(), ataProgramId);
      expect(metas(token[0]).first, (kora, true, true), reason: 'payer');
      expect(metas(token[0])[1].$1, ataAddress(treasury, usdc));
      expect(metas(token[1]).first, (kora, true, true));
      expect(metas(token[1])[1].$1, ataAddress(bob, usdc));
      expect(token[2].data.toList(), [...Disc.releaseVestedToken, 1]);
      expect(token[2].accounts.map(f), idlFlags('release_vested_token'));
      expect(metas(token[2]), [
        (executor, false, true),
        (vault, true, false),
        (configPda().address, false, false),
        (usdc, false, false),
        (ataAddress(vault, usdc), true, false),
        (bob, true, false),
        (ataAddress(bob, usdc), true, false),
        (ataAddress(treasury, usdc), true, false),
        (tokenProgramId, false, false),
      ]);

      final revoke = ownerActionIx(owner, planId, Disc.revokeVesting);
      expect(revoke.accounts.map(f), idlFlags('revoke_vesting'));
      expect(revoke.data.toList(), Disc.revokeVesting);

      final close = closeVaultIx(owner: owner, planId: planId, rentPayer: kora);
      expect(close.accounts.map(f), idlFlags('close_vault'));
      expect(metas(close), [
        (owner, true, true),
        (vault, true, false),
        (kora, true, false),
      ]);
      expect(close.data.toList(), Disc.closeVault);

      final create = createVaultIx(
        owner: owner,
        payer: kora,
        planId: planId,
        data: const [],
      );
      expect(create.accounts.map(f), idlFlags('create_vesting'));
      expect(metas(create)[1], (kora, true, true));
    });

    test('deposit and withdraw token ixs take an optional rent payer', () {
      final deposit = depositTokenIxs(
        owner: owner,
        planId: planId,
        mint: usdc,
        amount: 5,
        decimals: 6,
        payer: kora,
      );
      expect(metas(deposit.first).first, (kora, true, true));
      expect(metas(deposit.last).last, (owner, false, true), reason: 'auth');
      final withdraw = withdrawTokenIxs(
        owner: owner,
        planId: planId,
        mint: usdc,
        amount: 5,
        payer: kora,
      );
      expect(metas(withdraw.first).first, (kora, true, true));
      expect(
        metas(
          depositTokenIxs(
            owner: owner,
            planId: planId,
            mint: usdc,
            amount: 5,
            decimals: 6,
          ).first,
        ).first,
        (owner, true, true),
      );
    });

    test('decodes a vesting vault and mirrors vested/claimable/committed', () {
      const start = 1780000000;
      const year = 365 * 86400;
      final v = decodeVault(
        vaultBytes(
          owner: owner,
          planId: planId,
          label: 'Team',
          guard: guard,
          kind: PlanKind.vesting,
          startAt: start,
          revocable: true,
          revokedAt: 0,
          rentPayer: kora,
          rules: [
            RuleState(
              beneficiary: alice,
              rail: Rail.solana,
              afterSecs: 90 * 86400,
              mode: AmountMode.fixed,
              amount: 1000,
              executedAt: 0,
              paid: 98,
              durationSecs: year,
              released: 100,
            ),
            RuleState(
              beneficiary: bob,
              rail: Rail.cloak,
              afterSecs: 0,
              mint: usdc,
              mode: AmountMode.fixed,
              amount: 500,
              executedAt: 0,
              paid: 0,
              durationSecs: 2 * year,
            ),
          ],
        ),
        address: vault,
        lamports: 10,
        rentExemptMinimum: 0,
      );
      expect(v.kind, PlanKind.vesting);
      expect(v.isVesting, isTrue);
      expect(v.startAt, start);
      expect(v.revocable, isTrue);
      expect(v.revokedAt, 0);
      expect(v.rentPayer, kora);
      expect(v.rules[0].durationSecs, year);
      expect(v.rules[0].released, 100);
      expect(v.rules[0].paid, 98);
      expect(v.rules[1].mint, usdc);

      expect(v.vested(0, start + 89 * 86400), 0, reason: 'before the cliff');
      expect(v.vested(0, start + year ~/ 2), 500);
      expect(v.vested(0, start + 2 * year), 1000);
      expect(v.claimable(0, start + year ~/ 2), 400);
      expect(v.committed(null), 900);
      expect(v.committed(usdc), 500);

      final inheritance = decodeVault(
        vaultBytes(owner: owner, guard: guard),
        address: vault,
        lamports: 0,
        rentExemptMinimum: 0,
      );
      expect(inheritance.kind, PlanKind.inheritance);
      expect(inheritance.rentPayer, owner);
      expect(inheritance.committed(null), 0);
    });

    test('revoked vesting stops at revoked_at', () {
      const start = 1780000000;
      const year = 365 * 86400;
      final v = decodeVault(
        vaultBytes(
          owner: owner,
          guard: guard,
          kind: PlanKind.vesting,
          startAt: start,
          revocable: true,
          revokedAt: start + year ~/ 4,
          rules: [
            RuleState(
              beneficiary: alice,
              rail: Rail.solana,
              afterSecs: 0,
              mode: AmountMode.fixed,
              amount: 1000,
              executedAt: 0,
              paid: 0,
              durationSecs: year,
            ),
          ],
        ),
        address: vault,
        lamports: 0,
        rentExemptMinimum: 0,
      );
      expect(v.vested(0, start + year), 250);
      expect(v.vestingCap(0), 250);
      expect(v.committed(null), 250);
    });

    test('vestingError mirrors create_vesting', () {
      int? check({
        String? g,
        int lockSecs = 3600,
        int startAt = now,
        List<VestingSpec>? schedules,
      }) => vestingError(
        owner: owner,
        vault: vault,
        guard: g ?? guard,
        lockSecs: lockSecs,
        startAt: startAt,
        schedules: schedules ?? [solSchedule, usdcSchedule],
        now: now,
      );
      VestingSpec s({
        String? to,
        int total = 10,
        int cliff = 0,
        int duration = 100,
        String? mint,
      }) => VestingSpec(
        beneficiary: to ?? alice,
        rail: Rail.solana,
        total: total,
        cliffSecs: cliff,
        durationSecs: duration,
        mint: mint,
      );
      expect(check(), isNull);
      expect(check(g: owner), 6005);
      expect(check(g: defaultPubkey), 6005);
      expect(check(lockSecs: 59), 6002);
      expect(check(lockSecs: 30 * 86400 + 1), 6002);
      expect(check(schedules: []), 6022);
      expect(check(schedules: List.filled(9, s())), 6022);
      expect(check(schedules: List.filled(8, s())), isNull);
      expect(check(startAt: now - 366 * 86400), isNull);
      expect(check(startAt: now - 366 * 86400 - 1), 6022);
      expect(check(startAt: now + 366 * 86400 + 1), 6022);
      for (final bad in [
        s(total: 0),
        s(cliff: -1),
        s(duration: 0),
        s(cliff: 101),
        s(duration: 20 * 366 * 86400 + 1),
        s(to: owner),
        s(to: guard),
        s(to: vault),
        s(to: defaultPubkey),
        s(mint: defaultPubkey),
      ]) {
        expect(check(schedules: [bad]), 6022);
      }
      expect(check(schedules: [s(cliff: 100, duration: 100)]), isNull);
      expect(check(schedules: [s(duration: 20 * 366 * 86400)]), isNull);
    });
  });

  group('mainnet layout', () {
    Map<String, dynamic> idlIx(String name) =>
        (loadIdl()['instructions'] as List).firstWhere((i) => i['name'] == name)
            as Map<String, dynamic>;

    test('recover_legacy_vault matches the IDL', () {
      final idl = idlIx('recover_legacy_vault');
      expect(Disc.recoverLegacyVault, List<int>.from(idl['discriminator']));
      expect((idl['args'] as List).map((a) => a['name']), ['plan_id']);
      final ix = recoverLegacyVaultIx(owner: owner, planId: 42801);
      expect(
        ix.accounts.map(
          (a) => (a.pubKey.toBase58(), a.isWriteable, a.isSigner),
        ),
        [(owner, true, true), (vaultPda(owner, 42801).address, true, false)],
      );
      expect((idl['accounts'] as List).map((a) => a['name']), [
        'owner',
        'legacy',
      ]);
      expect(ix.data.toList(), [...Disc.recoverLegacyVault, 0x31, 0xa7]);
    });

    test('fixtures are exactly one Vault account long', () {
      for (final guardian in [null, key(9)]) {
        final bytes = vaultBytes(
          owner: owner,
          planId: 0x1234,
          guard: guard,
          guardian: guardian,
        );
        expect(bytes, hasLength(vaultAccountSize));
        expect(bytes.sublist(8, 40), keyBytes(owner));
        expect(bytes.sublist(40, 42), [0x34, 0x12]);
        expect(bytes.sublist(42, 74), keyBytes(guard));
        expect(bytes[74], guardian == null ? 0 : 1);
      }
    });

    test('withdrawable keeps the larger of rent paid and the current rent', () {
      VaultState v(int rentPaid, int minimum) => decodeVault(
        vaultBytes(owner: owner, guard: guard, rentPaid: rentPaid),
        address: 'vault',
        lamports: 10000000,
        rentExemptMinimum: minimum,
      );
      expect(v(7711440, 7711440).withdrawableLamports, 2288560);
      expect(v(7711440, 7711440).rentPaid, 7711440);
      // Rent cut: the sponsor's deposit stays locked.
      expect(v(7711440, 3855720).withdrawableLamports, 2288560);
      // Rent rise: the account stays rent-exempt.
      expect(v(7711440, 9000000).withdrawableLamports, 1000000);
      expect(v(7711440, 20000000).withdrawableLamports, 0);
    });

    test('per-rail gas stipends mirror the program', () {
      expect(Limits.gasStipend(Rail.solana), 0);
      expect(Limits.gasStipend(Rail.cloak), 12000000);
      expect(Limits.gasStipend(Rail.zcash), 3000000);
    });
  });
}
