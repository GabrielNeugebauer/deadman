// Devnet end-to-end check that installment vesting pays each installment
// once: a scratch owner vests 0.06 SOL over 3 minutes in 1-minute
// installments to a beneficiary holding no SOL. Right after the first
// boundary the beneficiary claims through the free Kora sponsor (0.02 SOL
// minus the 2% release fee). An immediate second claim must be refused twice: by
// the client (NothingToPay with the next installment) and by the program
// itself (a raw `release_vested_sol` that skips the client check, simulated
// against devnet). After the next boundaries it claims again until fully
// vested.
//
// Stop tool/keeper.dart while this runs: it releases unlocked installments
// on its own, which would take the claims away from the beneficiary.
//
// Needs the program with installment vesting deployed to devnet,
// scripts/kora_start.sh (the sponsor on :8080), and the `solana` CLI whose
// default wallet holds devnet SOL (it funds the owner).
//
// dart run tool/e2e_vesting_installments.dart [--dry-run]
//   [--sponsor http://127.0.0.1:8080] [--rpc https://api.devnet.solana.com]
//
// --dry-run touches no network: it checks the plan against the client's
// validation, prints the instruction size and walks the installment
// timeline with the same math the program uses.
import 'dart:io';
import 'dart:typed_data';

import 'package:deadman/kora/kora_client.dart';
import 'package:deadman/solana/codec.dart';
import 'package:deadman/solana/deadman_api.dart';
import 'package:deadman/solana/deadman_client.dart';
import 'package:solana/dto.dart' show BinaryAccountData, Encoding;
import 'package:solana/encoder.dart';
import 'package:solana/solana.dart';

const total = 60000000; // 0.06 SOL
const durationSecs = 180;
const periodSecs = 60;
const installment = total * periodSecs ~/ durationSecs; // 0.02 SOL
const planId = 0;

Future<void> main(List<String> argv) async {
  final dryRun = argv.contains('--dry-run');
  final rest = [...argv]..remove('--dry-run');
  final args = <String, String>{
    for (var i = 0; i + 1 < rest.length; i += 2)
      rest[i].replaceFirst('--', ''): rest[i + 1],
  };
  final rpc = args['rpc'] ?? 'https://api.devnet.solana.com';
  if (rpc.contains('mainnet')) {
    stderr.writeln('devnet only');
    exit(64);
  }

  final owner = await Ed25519HDKeyPair.random();
  final heir = await Ed25519HDKeyPair.random();
  final guard = await Ed25519HDKeyPair.random();
  final schedules = [
    VestingSpec(
      beneficiary: heir.address,
      rail: Rail.solana,
      total: total,
      cliffSecs: 0,
      durationSecs: durationSecs,
    ),
  ];
  if (dryRun) {
    _dryRun(owner.address, guard.address, schedules);
    exit(0);
  }

  final sol = SolanaClient(
    rpcUrl: Uri.parse(rpc),
    websocketUrl: Uri.parse(rpc.replaceFirst('http', 'ws')),
  );
  final sponsorUrl = Uri.parse(args['sponsor'] ?? 'http://127.0.0.1:8080');
  final client = DeadmanClient.withKora(
    client: sol,
    sponsor: KoraClient(sponsorUrl),
  );
  final sponsorSigner = (await KoraClient(
    sponsorUrl,
  ).getPayerSigner()).signerAddress;
  stdout.writeln(
    'owner ${owner.address}, heir ${heir.address}, '
    'sponsor signer $sponsorSigner',
  );
  await _run('solana', [
    'transfer',
    owner.address,
    '0.2',
    '--allow-unfunded-recipient',
    '--url',
    rpc,
  ]);
  _check(await client.balance(heir.address) == 0, 'heir starts with 0 SOL');

  final startAt = await _chainNow(sol);
  final create = await client.buildCreateVesting(
    owner: owner.address,
    planId: planId,
    label: 'E2E installments',
    guard: guard.address,
    lockSecs: 3600,
    startAt: startAt,
    revocable: false,
    schedules: schedules,
    periodSecs: periodSecs,
    depositLamports: total,
  );
  final [createSig] = await client.sendSigned([await _sign(create, owner)]);
  var vault = (await client.fetchVault(owner.address, planId))!;
  stdout.writeln(
    'create_vesting $createSig\n'
    'vault ${vault.address}, start $startAt, '
    'period ${vault.vestPeriodSecs} s',
  );
  _check(vault.vestPeriodSecs == periodSecs, 'vault stores the period');
  _check(vault.installmentCount(0) == 3, '3 installments');
  _check(vault.installmentAmount(0) == installment, 'of 0.02 SOL each');

  await _expectRefusedByClient(client, heir, owner.address, 'before #1');

  final fees = await client.fetchFees();
  final bps = fees.bpsFor(Rail.solana);
  if (bps != 50) stdout.writeln('note: public payout fee is $bps bps');
  final expectNet = installment - installment * bps ~/ 10000;

  // Installment 1: free claim right after the boundary.
  await _waitFor(sol, startAt + periodSecs);
  await _claim(
    client,
    heir,
    owner.address,
    sponsorSigner: sponsorSigner,
    releasedBefore: 0,
    expectGross: installment,
    expectNet: expectNet,
  );

  // Immediate second claim: the client and the program both refuse it.
  await _expectRefusedByClient(client, heir, owner.address, 'right after #1');
  final chainNow = await _chainNow(sol);
  if (chainNow >= startAt + 2 * periodSecs) {
    throw StateError(
      'FAILED: the second boundary passed before the program check could '
      'run (chain clock $chainNow); rerun on a faster RPC',
    );
  }
  await _expectRefusedByProgram(client, sol, heir, owner.address);

  // Installment 2.
  await _waitFor(sol, startAt + 2 * periodSecs);
  final heirAfter1 = await client.balance(heir.address);
  await _claim(
    client,
    heir,
    owner.address,
    sponsorSigner: sponsorSigner,
    releasedBefore: installment,
    expectGross: installment,
    expectNet: heirAfter1 + expectNet,
  );
  await _expectRefusedByClient(client, heir, owner.address, 'right after #2');

  // Installment 3: fully vested at start + duration.
  await _waitFor(sol, startAt + durationSecs);
  final heirAfter2 = await client.balance(heir.address);
  await _claim(
    client,
    heir,
    owner.address,
    sponsorSigner: sponsorSigner,
    releasedBefore: 2 * installment,
    expectGross: installment,
    expectNet: heirAfter2 + expectNet,
  );
  vault = (await client.fetchVault(owner.address, planId))!;
  _check(vault.rules[0].released == total, 'all 0.06 SOL released');
  _check(vault.rules[0].executed, 'schedule marked fully released');
  stdout.writeln(
    'heir SOL ${await client.balance(heir.address)} '
    '(3 x $expectNet net), paid no network fee',
  );
  stdout.writeln('E2E OK');
  exit(0);
}

/// Claims what has unlocked through the free sponsor and checks the heir
/// received [expectNet] in total and the vault released [expectGross] more.
/// Retries briefly while the client or chain clock lag the boundary.
Future<void> _claim(
  DeadmanClient client,
  Ed25519HDKeyPair heir,
  String owner, {
  required String sponsorSigner,
  required int releasedBefore,
  required int expectGross,
  required int expectNet,
}) async {
  for (var tries = 0; ; tries++) {
    final vault = (await client.fetchVault(owner, planId))!;
    if (vault.rules[0].released != releasedBefore) {
      throw StateError(
        'FAILED: released ${vault.rules[0].released} before the heir '
        'claimed (expected $releasedBefore): stop tool/keeper.dart and rerun',
      );
    }
    try {
      final quote = await client.quoteClaim(
        claimer: heir.address,
        vaultOwner: owner,
        planId: planId,
        index: 0,
      );
      _check(quote.free, 'claim quoted as free (sponsor)');
      _check(quote.problem == null, 'claim quoted without a problem');
      final claim = await client.buildClaim(
        claimer: heir.address,
        vaultOwner: owner,
        planId: planId,
        index: 0,
      );
      _check(claim.payer == ClaimPayer.sponsor, 'claim built sponsored');
      _check(
        _feePayer(claim.transaction) == sponsorSigner,
        'fee payer is the sponsor signer',
      );
      final [sig] = await client.sendSigned([
        await _sign(claim.transaction, heir),
      ]);
      final after = (await client.fetchVault(owner, planId))!;
      final got = await client.balance(heir.address);
      stdout.writeln(
        'claim $sig: released ${after.rules[0].released}, heir SOL $got',
      );
      _check(
        after.rules[0].released == releasedBefore + expectGross,
        'one installment (gross $expectGross) released',
      );
      _check(got == expectNet, 'heir holds $expectNet (release fee, no gas)');
      return;
    } on DeadmanException catch (e) {
      if (e.name != 'NothingToPay' || tries >= 8) rethrow;
      stdout.writeln('not unlocked yet by the clock, retrying: ${e.message}');
      await Future<void>.delayed(const Duration(milliseconds: 1500));
    }
  }
}

/// Both client paths refuse a claim with nothing new unlocked, naming the
/// next installment.
Future<void> _expectRefusedByClient(
  DeadmanClient client,
  Ed25519HDKeyPair heir,
  String owner,
  String when,
) async {
  for (final path in ['quoteClaim', 'buildClaim']) {
    try {
      if (path == 'quoteClaim') {
        await client.quoteClaim(
          claimer: heir.address,
          vaultOwner: owner,
          planId: planId,
          index: 0,
        );
      } else {
        await client.buildClaim(
          claimer: heir.address,
          vaultOwner: owner,
          planId: planId,
          index: 0,
        );
      }
    } on DeadmanException catch (e) {
      _check(e.name == 'NothingToPay', '$path $when refused: ${e.message}');
      _check(
        e.message.contains('Next installment: 0.02 SOL on'),
        '$path $when names the next installment',
      );
      continue;
    }
    throw StateError('FAILED: $path $when was allowed by the client');
  }
}

/// Sends the raw `release_vested_sol` (no client-side check) through a
/// devnet simulation and expects the program's own NothingToPay.
Future<void> _expectRefusedByProgram(
  DeadmanClient client,
  SolanaClient sol,
  Ed25519HDKeyPair heir,
  String owner,
) async {
  final vault = (await client.fetchVault(owner, planId))!;
  final ixs = releaseVestedIxs(
    executor: heir.address,
    vaultOwner: owner,
    planId: planId,
    rule: vault.rules[0],
    index: 0,
    treasury: (await client.fetchFees()).treasury,
  );
  final blockhash = await sol.rpcClient.getLatestBlockhash(
    commitment: Commitment.confirmed,
  );
  final tx = await signTransaction(
    blockhash.value,
    Message(instructions: ixs),
    [heir],
  );
  final sim = (await sol.rpcClient.simulateTransaction(
    tx.encode(),
    commitment: Commitment.confirmed,
  )).value;
  final logs = sim.logs ?? const <String>[];
  final err = DeadmanException.fromTxError(sim.err, logs: logs);
  stdout.writeln('raw release_vested_sol: err=${sim.err}');
  _check(sim.err != null, 'program rejected the raw second claim');
  _check(
    err.code == DeadmanException.nothingToPay ||
        logs.any((l) => l.contains('NothingToPay')),
    'program error is NothingToPay',
  );
}

void _dryRun(String owner, String guard, List<VestingSpec> schedules) {
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final vault = vaultPda(owner, planId).address;
  final code = vestingError(
    owner: owner,
    vault: vault,
    guard: guard,
    lockSecs: 3600,
    startAt: now,
    schedules: schedules,
    now: now,
    periodSecs: periodSecs,
  );
  _check(code == null, 'plan passes client-side validation');
  final data = encodeCreateVesting(
    planId: planId,
    label: 'E2E installments',
    guard: guard,
    lockSecs: 3600,
    startAt: now,
    revocable: false,
    schedules: schedules,
    periodSecs: periodSecs,
  );
  stdout.writeln('create_vesting data ${data.length} bytes (period last)');
  for (final bad in [30, durationSecs + 1]) {
    _check(
      vestingError(
            owner: owner,
            vault: vault,
            guard: guard,
            lockSecs: 3600,
            startAt: now,
            schedules: schedules,
            now: now,
            periodSecs: bad,
          ) ==
          DeadmanException.invalidVesting,
      'period $bad s rejected client-side',
    );
  }

  VaultState at(int released) => VaultState(
    address: vault,
    owner: owner,
    planId: planId,
    label: 'E2E installments',
    guard: guard,
    guardian: null,
    lockSecs: 3600,
    skipGraceSecs: 0,
    lastPulse: now,
    ownerLastSeen: now,
    lockedUntil: 0,
    guardianReadyAt: 0,
    totalPulses: 0,
    streak: 0,
    bestStreak: 0,
    lamports: total,
    withdrawableLamports: total,
    kind: PlanKind.vesting,
    startAt: now,
    vestPeriodSecs: periodSecs,
    rules: [
      RuleState(
        beneficiary: schedules[0].beneficiary,
        rail: Rail.solana,
        afterSecs: 0,
        mode: AmountMode.fixed,
        amount: total,
        executedAt: 0,
        paid: 0,
        durationSecs: durationSecs,
        released: released,
      ),
    ],
  );
  _check(at(0).installmentAmount(0) == installment, '0.02 SOL installments');
  final steps = <(String, int, int, int)>[
    ('before #1', 59, 0, 0),
    ('at #1', 60, 0, installment),
    ('right after claiming #1', 61, installment, 0),
    ('just before #2', 119, installment, 0),
    ('at #2', 120, installment, installment),
    ('right after claiming #2', 121, 2 * installment, 0),
    ('at the end', 180, 2 * installment, installment),
  ];
  for (final (name, t, released, want) in steps) {
    final v = at(released);
    final c = v.claimable(0, now + t);
    final next = v.nextInstallmentAt(0, now + t);
    stdout.writeln(
      '  t+${t}s $name: claimable $c, '
      'unlocked ${v.installmentsUnlocked(0, now + t)}/3, '
      'next ${next == null ? '-' : 't+${next - now}s'}',
    );
    _check(c == want, '$name claimable $want');
  }
  stdout.writeln(
    'DRY RUN OK (nothing sent). The live run needs the installment '
    'program on devnet and the Kora sponsor.',
  );
}

/// Waits until both the chain clock and this machine's clock reach [at]
/// (the program checks the first, the client pre-check the second).
Future<void> _waitFor(SolanaClient sol, int at) async {
  final wall = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  if (at - wall > 6) {
    stdout.writeln('waiting ${at - wall - 5} s for the next installment');
    await Future<void>.delayed(Duration(seconds: at - wall - 5));
  }
  while (true) {
    try {
      final now = await _chainNow(sol);
      final wallNow = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      if (now >= at && wallNow >= at) {
        stdout.writeln('chain clock $now >= boundary $at');
        return;
      }
    } on Object catch (e) {
      stdout.writeln('clock read failed: $e');
    }
    await Future<void>.delayed(const Duration(milliseconds: 400));
  }
}

Future<int> _chainNow(SolanaClient sol) async {
  final account = (await sol.rpcClient.getAccountInfo(
    'SysvarC1ock11111111111111111111111111111111',
    commitment: Commitment.confirmed,
    encoding: Encoding.base64,
  )).value;
  final data = account?.data;
  if (data is! BinaryAccountData) throw StateError('no clock sysvar');
  return ByteData.sublistView(Uint8List.fromList(data.data))
      .getInt64(32, Endian.little);
}

String _feePayer(Uint8List tx) =>
    SignedTx.fromBytes(tx).compiledMessage.accountKeys.first.toBase58();

void _check(bool ok, String what) {
  if (!ok) throw StateError('FAILED: $what');
  stdout.writeln('  ok: $what');
}

Future<void> _run(String cmd, List<String> args) async {
  final r = await Process.run(cmd, args);
  if (r.exitCode != 0) throw StateError('$cmd failed: ${r.stderr}');
  stdout.writeln('$cmd ${args.first}: ${(r.stdout as String).trim()}');
}

/// Fills [signer]'s signature slot of an unsigned wire transaction (legacy
/// or v0), as a wallet would.
Future<Uint8List> _sign(Uint8List tx, Ed25519HDKeyPair signer) async {
  final sigCount = tx[0];
  final message = tx.sublist(1 + 64 * sigCount);
  var o = message[0] & 0x80 != 0 ? 1 : 0;
  final required = message[o];
  o += 3;
  final keyCount = message[o++];
  final me = Ed25519HDPublicKey.fromBase58(signer.address).bytes;
  for (var i = 0; i < keyCount && i < required; i++) {
    final key = message.sublist(o + 32 * i, o + 32 * i + 32);
    if (_eq(key, me)) {
      final sig = await signer.sign(message);
      final out = Uint8List.fromList(tx);
      out.setRange(1 + 64 * i, 1 + 64 * i + 64, sig.bytes);
      return out;
    }
  }
  throw StateError('${signer.address} is not a signer of this transaction');
}

bool _eq(List<int> a, List<int> b) {
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
