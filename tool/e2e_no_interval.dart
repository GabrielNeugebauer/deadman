// Devnet end-to-end check of plans without a check-in interval:
//  1. a scratch owner sends `create_plan` with one SOL tier due 60 s (the
//     program minimum) after the last check-in;
//  2. the plan decodes: no interval, the reserved slot is zero, and
//     `nextReleaseAt` is last check-in + 60 s;
//  3. once due, a beneficiary holding 0 SOL claims it through the free Kora
//     sponsor;
//  4. a raw instruction with the OLD `create_vault` discriminator and the
//     old arguments (with `interval_secs`) is rejected with
//     InstructionFallbackNotFound (101) and creates no account.
//
// The running keeper executes due SOL tiers too; if it wins the race, the
// run retries with a new plan and beneficiary (up to --attempts).
//
// Needs scripts/kora_start.sh running and the `solana` CLI, whose default
// wallet holds devnet SOL (it funds the scratch owner with 0.2 SOL).
//
// dart run tool/e2e_no_interval.dart [--dry-run]
//   [--sponsor http://127.0.0.1:8080] [--rpc https://api.devnet.solana.com]
//   [--attempts 3]
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:deadman/kora/kora_client.dart';
import 'package:deadman/solana/codec.dart';
import 'package:deadman/solana/deadman_api.dart';
import 'package:deadman/solana/deadman_client.dart';
import 'package:solana/dto.dart'
    show BinaryAccountData, ConfirmationStatus, Encoding;
import 'package:solana/encoder.dart';
import 'package:solana/solana.dart';

const solTier = 2000000; // 0.002 SOL
const afterSecs = 60; // MIN_RULE_DELAY_SECS
const oldPlanId = 900; // plan id for the rejected legacy instruction
const instructionFallbackNotFound = 101;

/// `create_vault` before the 2026-10-05 rename.
final oldCreateVaultDisc = _disc('create_vault');

Future<void> main(List<String> argv) async {
  final dryRun = argv.contains('--dry-run');
  final rest = [...argv]..remove('--dry-run');
  final args = <String, String>{
    for (var i = 0; i + 1 < rest.length; i += 2)
      rest[i].replaceFirst('--', ''): rest[i + 1],
  };
  final rpc = args['rpc'] ?? 'https://api.devnet.solana.com';
  final attempts = int.parse(args['attempts'] ?? '3');
  final sponsorUrl = Uri.parse(args['sponsor'] ?? 'http://127.0.0.1:8080');
  if (rpc.contains('mainnet')) {
    stderr.writeln('devnet only');
    exit(64);
  }
  if (dryRun) {
    await _dryRun();
    exit(0);
  }

  final sol = SolanaClient(
    rpcUrl: Uri.parse(rpc),
    websocketUrl: Uri.parse(rpc.replaceFirst('http', 'ws')),
  );
  final client = DeadmanClient.withKora(
    client: sol,
    sponsor: KoraClient(sponsorUrl),
  );
  final sponsorSigner = (await KoraClient(
    sponsorUrl,
  ).getPayerSigner()).signerAddress;
  stdout.writeln('sponsor signer $sponsorSigner');

  final owner = await Ed25519HDKeyPair.random();
  stdout.writeln('owner ${owner.address}');
  await _run('solana', [
    'transfer',
    owner.address,
    '0.2',
    '--allow-unfunded-recipient',
    '--url',
    rpc,
  ]);
  stdout.writeln('owner SOL ${await client.balance(owner.address)}');

  await _oldCreateVaultRejected(sol, owner);

  var ok = false;
  for (var planId = 0; planId < attempts && !ok; planId++) {
    stdout.writeln('\n--- attempt ${planId + 1} (plan $planId) ---');
    ok = await _attempt(client, sol, owner, planId, sponsorSigner);
  }
  stdout.writeln(
    '\nlegacy create_vault rejected: OK; '
    '60 s tier claimed via sponsor: ${ok ? 'OK' : 'NOT VERIFIED'}',
  );
  if (!ok) exit(1);
  stdout.writeln('E2E OK');
  exit(0);
}

List<RuleSpec> _rules(String heir) => [
  RuleSpec(
    beneficiary: heir,
    rail: Rail.solana,
    afterSecs: afterSecs,
    mode: AmountMode.fixed,
    amount: solTier,
  ),
];

/// The pre-rename `create_vault` data: old discriminator, then plan_id,
/// label, guard, interval_secs, lock_secs, skip_grace_secs, rules.
Uint8List _oldCreateVaultData({
  required int planId,
  required String guard,
  required String heir,
}) =>
    (BorshWriter()
          ..bytes(oldCreateVaultDisc)
          ..u16(planId)
          ..string('E2E legacy')
          ..pubkey(guard)
          ..i64(120) // interval_secs
          ..i64(60)
          ..i64(60)
          ..ruleInputs([
            RuleSpec(
              beneficiary: heir,
              rail: Rail.solana,
              afterSecs: 180,
              mode: AmountMode.fixed,
              amount: solTier,
            ),
          ]))
        .toBytes();

List<int> _disc(String name) =>
    sha256.convert(utf8.encode('global:$name')).bytes.sublist(0, 8);

Future<void> _dryRun() async {
  stdout.writeln('dry run: no RPC, no Kora, nothing funded or sent');
  final owner = await Ed25519HDKeyPair.random();
  final guard = await Ed25519HDKeyPair.random();
  final heir = await Ed25519HDKeyPair.random();
  _check(_eq(Disc.createPlan, _disc('create_plan')), 'Disc.createPlan');
  _check(_eq(Disc.updatePlan, _disc('update_plan')), 'Disc.updatePlan');
  _check(
    !_eq(oldCreateVaultDisc, Disc.createPlan) &&
        !_eq(_disc('update_policy'), Disc.updatePlan),
    'old discriminators differ from the new ones',
  );
  final fresh = encodeCreatePlan(
    planId: 0,
    label: 'E2E no interval',
    guard: guard.address,
    lockSecs: 60,
    skipGraceSecs: 60,
    rules: _rules(heir.address),
  );
  final old = _oldCreateVaultData(
    planId: oldPlanId,
    guard: guard.address,
    heir: heir.address,
  );
  _check(
    policyError(
          owner: owner.address,
          vault: vaultPda(owner.address, 0).address,
          guard: guard.address,
          lockSecs: 60,
          skipGraceSecs: 60,
          rules: _rules(heir.address),
        ) ==
        null,
    'a single 60 s tier passes client validation',
  );
  _check(
    policyError(
          owner: owner.address,
          vault: vaultPda(owner.address, 0).address,
          guard: guard.address,
          lockSecs: 60,
          skipGraceSecs: 60,
          rules: [
            RuleSpec(
              beneficiary: heir.address,
              rail: Rail.solana,
              afterSecs: afterSecs - 1,
              mode: AmountMode.fixed,
              amount: solTier,
            ),
          ],
        ) !=
        null,
    'a 59 s tier is refused',
  );
  stdout.writeln(
    'create_plan data (${fresh.length} B): ${_hex(fresh)}\n'
    'legacy create_vault data (${old.length} B): ${_hex(old)}\n'
    'legacy vault PDA (must stay empty): '
    '${vaultPda(owner.address, oldPlanId).address}\n'
    'live run: fund owner 0.2 SOL, simulate + send legacy ix '
    '(expect Custom $instructionFallbackNotFound), create_plan with one '
    '${solTier / 1e9} SOL tier after $afterSecs s, decode, wait, sponsor '
    'claim by a 0-SOL heir.',
  );
  stdout.writeln('DRY RUN OK');
}

Future<void> _oldCreateVaultRejected(
  SolanaClient sol,
  Ed25519HDKeyPair owner,
) async {
  stdout.writeln('\n--- legacy create_vault ---');
  final guard = await Ed25519HDKeyPair.random();
  final heir = await Ed25519HDKeyPair.random();
  final pda = vaultPda(owner.address, oldPlanId).address;
  final ix = createVaultIx(
    owner: owner.address,
    payer: owner.address,
    planId: oldPlanId,
    data: _oldCreateVaultData(
      planId: oldPlanId,
      guard: guard.address,
      heir: heir.address,
    ),
  );
  final blockhash = (await sol.rpcClient.getLatestBlockhash(
    commitment: Commitment.confirmed,
  )).value.blockhash;
  final tx = await partiallySign(
    serializeUnsigned(
      [ix],
      feePayer: owner.address,
      recentBlockhash: blockhash,
    ),
    owner,
  );
  final encoded = base64Encode(tx);

  final sim = (await sol.rpcClient.simulateTransaction(
    encoded,
    sigVerify: true,
    commitment: Commitment.confirmed,
  )).value;
  stdout.writeln('simulation err ${sim.err}');
  for (final l in sim.logs ?? const <String>[]) {
    stdout.writeln('  $l');
  }
  _check(
    _customCode(sim.err) == instructionFallbackNotFound,
    'simulation rejects the old discriminator with 101',
  );
  _check(
    (sim.logs ?? const []).any(
      (l) => l.contains('InstructionFallbackNotFound'),
    ),
    'program log names InstructionFallbackNotFound',
  );

  final sig = await sol.rpcClient.sendTransaction(
    encoded,
    skipPreflight: true,
    preflightCommitment: Commitment.confirmed,
  );
  stdout.writeln('sent legacy create_vault (skip preflight) $sig');
  Map<String, dynamic>? err;
  for (var i = 0; ; i++) {
    final s = (await sol.rpcClient.getSignatureStatuses([
      sig,
    ], searchTransactionHistory: true)).value.first;
    if (s != null && s.confirmationStatus != ConfirmationStatus.processed) {
      err = s.err;
      break;
    }
    if (i >= 60) throw StateError('legacy tx not confirmed: $sig');
    await Future<void>.delayed(const Duration(seconds: 1));
  }
  stdout.writeln('on-chain err $err');
  _check(
    _customCode(err) == instructionFallbackNotFound,
    'the chain rejects it with 101',
  );
  final account = (await sol.rpcClient.getAccountInfo(
    pda,
    commitment: Commitment.confirmed,
    encoding: Encoding.base64,
  )).value;
  _check(account == null, 'no vault account at $pda');
}

/// `{InstructionError: [0, {Custom: n}]}` -> n.
int? _customCode(Object? err) {
  if (err is! Map) return null;
  final ie = err['InstructionError'];
  if (ie is! List || ie.length != 2) return null;
  final inner = ie[1];
  return inner is Map && inner['Custom'] is int ? inner['Custom'] as int : null;
}

Future<bool> _attempt(
  DeadmanClient client,
  SolanaClient sol,
  Ed25519HDKeyPair owner,
  int planId,
  String sponsorSigner,
) async {
  final heir = await Ed25519HDKeyPair.random();
  final guard = await Ed25519HDKeyPair.random();
  final create = await client.buildCreateVault(
    owner: owner.address,
    planId: planId,
    label: 'E2E no interval',
    guard: guard.address,
    lockSecs: 60,
    skipGraceSecs: 60,
    rules: _rules(heir.address),
    depositLamports: solTier,
  );
  final [createSig] = await client.sendSigned([
    await partiallySign(create, owner),
  ]);
  final vault = (await client.fetchVault(owner.address, planId))!;
  final due = vault.ruleDueAt(0);
  stdout.writeln(
    'create_plan $createSig\n'
    'vault ${vault.address}, heir ${heir.address}, last check-in '
    '${vault.lastPulse}, due at $due',
  );
  _check(vault.rules.length == 1, 'one tier');
  _check(vault.rules[0].afterSecs == afterSecs, 'tier waits $afterSecs s');
  _check(
    vault.lockSecs == 60 && vault.skipGraceSecs == 60,
    'lock and grace decode',
  );
  _check(vault.nextReleaseAt == vault.lastPulse + afterSecs, 'nextReleaseAt');
  _check(
    await _reservedIntervalIsZero(sol, vault.address),
    'reserved interval slot is zero',
  );
  _check(await client.balance(heir.address) == 0, 'heir starts with 0 SOL');

  final quote = await client.quoteClaim(
    claimer: heir.address,
    vaultOwner: owner.address,
    planId: planId,
    index: 0,
  );
  stdout.writeln(
    'quote: payer=${quote.payer.name} free=${quote.free} '
    'net=${quote.net} problem=${quote.problem}',
  );
  _check(quote.payer == ClaimPayer.sponsor, 'claim quoted as sponsored');
  _check(quote.problem == null, 'claim quoted without a problem');

  await _waitPast(sol, due);
  return _claim(client, heir, owner.address, planId, sponsorSigner, quote.net);
}

/// Reads the 8 bytes after `guardian` (`Option<Pubkey>`) in the raw account.
Future<bool> _reservedIntervalIsZero(SolanaClient sol, String vault) async {
  final data = (await sol.rpcClient.getAccountInfo(
    vault,
    commitment: Commitment.confirmed,
    encoding: Encoding.base64,
  )).value?.data;
  if (data is! BinaryAccountData) throw StateError('no vault data');
  final bytes = data.data;
  const guardianTag = 8 + 32 + 2 + 32;
  final at = guardianTag + (bytes[guardianTag] == 1 ? 33 : 1);
  return bytes.sublist(at, at + 8).every((b) => b == 0);
}

Future<bool> _claim(
  DeadmanClient client,
  Ed25519HDKeyPair heir,
  String owner,
  int planId,
  String sponsorSigner,
  int net,
) async {
  for (var tries = 0; ; tries++) {
    if ((await client.fetchVault(owner, planId))!.rules[0].executed) {
      stdout.writeln('the keeper executed the tier first (race lost)');
      return false;
    }
    try {
      final claim = await client.buildClaim(
        claimer: heir.address,
        vaultOwner: owner,
        planId: planId,
        index: 0,
      );
      _check(claim.payer == ClaimPayer.sponsor, 'claim built sponsored');
      _check(
        SignedTx.fromBytes(claim.transaction).compiledMessage.accountKeys.first
                .toBase58() ==
            sponsorSigner,
        'claim fee payer is the sponsor signer',
      );
      final [sig] = await client.sendSigned([
        await partiallySign(claim.transaction, heir),
      ]);
      final got = await client.balance(heir.address);
      stdout.writeln('claim (sponsor pays the fee) $sig\n  heir SOL $got');
      _check(got == net, 'heir received the net payout and paid no fee');
      return true;
    } on DeadmanException catch (e) {
      if ((await client.fetchVault(owner, planId))!.rules[0].executed) {
        stdout.writeln('the keeper executed the tier first (race lost)');
        return false;
      }
      if (tries >= 5) rethrow;
      stdout.writeln('claim retry after: $e');
      await Future<void>.delayed(const Duration(seconds: 2));
    }
  }
}

/// Polls the chain clock until it is past [due] (`execute_*` needs
/// `now > due`).
Future<void> _waitPast(SolanaClient sol, int due) async {
  final wall = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  if (due - wall > 6) {
    stdout.writeln('waiting ${due - wall - 5} s for the tier to fall due');
    await Future<void>.delayed(Duration(seconds: due - wall - 5));
  }
  while (true) {
    try {
      final now = await _chainNow(sol);
      if (now > due) {
        stdout.writeln('chain clock $now > due $due');
        return;
      }
    } on Object catch (e) {
      stdout.writeln('clock read failed: $e');
    }
    await Future<void>.delayed(const Duration(milliseconds: 400));
  }
}

Future<int> _chainNow(SolanaClient sol) async {
  final data = (await sol.rpcClient.getAccountInfo(
    'SysvarC1ock11111111111111111111111111111111',
    commitment: Commitment.confirmed,
    encoding: Encoding.base64,
  )).value?.data;
  if (data is! BinaryAccountData) throw StateError('no clock sysvar');
  return ByteData.sublistView(Uint8List.fromList(data.data))
      .getInt64(32, Endian.little);
}

String _hex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

bool _eq(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

void _check(bool ok, String what) {
  if (!ok) throw StateError('FAILED: $what');
  stdout.writeln('  ok: $what');
}

Future<void> _run(String cmd, List<String> args) async {
  final r = await Process.run(cmd, args);
  if (r.exitCode != 0) throw StateError('$cmd failed: ${r.stderr}');
  stdout.writeln('$cmd ${args.first}: ${(r.stdout as String).trim()}');
}
