// Devnet end-to-end check of the account-wide monthly subscription: a
// scratch owner with no plan yet is refused fewer than the minimum periods,
// then pays the 12-month minimum in USDC to the treasury. Only afterwards it
// creates TWO inheritance plans (one SOL tier each, same short timings),
// proving that plans created after subscribing are covered. A second owner
// without a subscription creates the same plan. Once due, every tier is
// claimed by its beneficiary, who holds no SOL, through the free sponsor:
// the subscribed owner's tiers pay in full (no protocol fee), the other
// owner's pays the public-rail fee (2%).
//
// If the running keeper executes a tier first, the amount checks are the
// same; the run reports who released each tier.
//
// Needs the subscription configured (tool/set_subscription.dart), the local
// Kora stack (scripts/kora_start.sh), and the `solana` / `spl-token` CLIs
// whose default wallet holds devnet SOL and --mint (it funds the owners).
//
// dart run tool/e2e_subscription.dart [--mint <test USDC mint>]
//   [--sponsor http://127.0.0.1:8080] [--rpc https://api.devnet.solana.com]
import 'dart:io';
import 'dart:typed_data';

import 'package:deadman/kora/kora_client.dart';
import 'package:deadman/solana/codec.dart' show subPda;
import 'package:deadman/solana/deadman_api.dart';
import 'package:deadman/solana/deadman_client.dart';
import 'package:solana/dto.dart' show BinaryAccountData, Encoding;
import 'package:solana/encoder.dart' show SignedTx;
import 'package:solana/solana.dart';

const solTier = 10000000; // 0.01 SOL, above a new account's rent minimum
const intervalSecs = 60;
const afterSecs = 120; // the program's minimum: interval + 60 s margin

/// One plan under test: whose, which beneficiary, and the payout expected.
typedef _Plan = ({
  Ed25519HDKeyPair owner,
  int planId,
  Ed25519HDKeyPair heir,
  int expected,
});

Future<void> main(List<String> argv) async {
  final args = <String, String>{
    for (var i = 0; i + 1 < argv.length; i += 2)
      argv[i].replaceFirst('--', ''): argv[i + 1],
  };
  final mint = args['mint'] ?? 'Ew8Z6hhRp7MFK8KJAxRqaBQvBEjtRj4Y4K4YhWsPMFGk';
  final rpc = args['rpc'] ?? 'https://api.devnet.solana.com';
  if (rpc.contains('mainnet')) {
    stderr.writeln('devnet only');
    exit(64);
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

  final terms = await client.fetchSubscriptionTerms();
  _check(terms != null, 'subscription is configured and enabled');
  stdout.writeln(
    'terms: ${terms!.pricePerPeriod} base units / ${terms.periodSecs} s, '
    'min ${terms.minPeriods} periods, mint ${terms.mint}',
  );
  _check(terms.mint == mint, 'subscription is priced in --mint');
  final fees = await client.fetchFees();
  final bps = fees.bpsFor(Rail.solana);
  _check(bps > 0, 'the public-rail fee is $bps bps');

  final owner = await Ed25519HDKeyPair.random();
  final other = await Ed25519HDKeyPair.random();
  final guard = await Ed25519HDKeyPair.random();
  final price = terms.cost(terms.minPeriods);
  await _run('solana', [
    'transfer',
    owner.address,
    '0.1',
    '--allow-unfunded-recipient',
    '--url',
    rpc,
  ]);
  await _run('solana', [
    'transfer',
    other.address,
    '0.05',
    '--allow-unfunded-recipient',
    '--url',
    rpc,
  ]);
  await _run('spl-token', [
    'transfer',
    mint,
    '${price / 1e6}',
    owner.address,
    '--fund-recipient',
    '--allow-unfunded-recipient',
    '--url',
    rpc,
  ]);
  stdout.writeln(
    'subscribed owner ${owner.address}\n'
    'other owner ${other.address} (no subscription)',
  );

  // Subscribe first, with no plan at all.
  _check(
    await client.fetchSubscription(owner.address) == null,
    'no subscription account yet',
  );
  _check(
    (await client.fetchVaults(owner.address)).isEmpty,
    'the owner has no plan when subscribing',
  );
  try {
    await client.buildSubscribe(
      owner: owner.address,
      periods: terms.minPeriods - 1,
    );
    _check(false, 'fewer than the minimum is refused');
  } on DeadmanException catch (e) {
    _check(e.name == 'InvalidSubscription', 'fewer than the minimum: $e');
  }
  final t0 = await client.tokenBalance(fees.treasury, mint);
  final subTx = await client.buildSubscribe(
    owner: owner.address,
    periods: terms.minPeriods,
  );
  final [subSig] = await client.sendSigned([await _sign(subTx, owner)]);
  final sub = await client.fetchSubscription(owner.address);
  stdout.writeln(
    'subscribe ${terms.minPeriods} periods $subSig\n'
    '  account ${subPda(owner.address).address}, paid until '
    '${sub == null ? '-' : DateTime.fromMillisecondsSinceEpoch(sub.paidUntil * 1000).toUtc()}',
  );
  _check(sub != null && sub.owner == owner.address, 'subscription created');
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  _check(
    sub!.paidUntil >= now + terms.periodSecs * terms.minPeriods - 120,
    'paid ${terms.minPeriods} periods ahead',
  );
  _check(
    await client.tokenBalance(fees.treasury, mint) - t0 == price,
    'treasury received $price',
  );
  _check(await client.tokenBalance(owner.address, mint) == 0, 'owner paid');
  _check(
    await client.fetchSubscription(other.address) == null,
    'the other owner has no subscription',
  );

  // Plans created after subscribing.
  final plans = <_Plan>[
    (
      owner: owner,
      planId: 0,
      heir: await Ed25519HDKeyPair.random(),
      expected: solTier,
    ),
    (
      owner: owner,
      planId: 1,
      heir: await Ed25519HDKeyPair.random(),
      expected: solTier,
    ),
    (
      owner: other,
      planId: 0,
      heir: await Ed25519HDKeyPair.random(),
      expected: solTier - solTier * bps ~/ 10000,
    ),
  ];
  var due = 0;
  for (final p in plans) {
    final create = await client.buildCreateVault(
      owner: p.owner.address,
      planId: p.planId,
      label: 'E2E subscription ${p.planId}',
      guard: guard.address,
      intervalSecs: intervalSecs,
      lockSecs: 60,
      skipGraceSecs: 60,
      rules: [
        RuleSpec(
          beneficiary: p.heir.address,
          rail: Rail.solana,
          afterSecs: afterSecs,
          mode: AmountMode.fixed,
          amount: solTier,
        ),
      ],
      depositLamports: solTier,
    );
    final [sig] = await client.sendSigned([await _sign(create, p.owner)]);
    final vault = (await client.fetchVault(p.owner.address, p.planId))!;
    final at = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final waived = feeWaivedFor(
      vault,
      await client.fetchSubscription(p.owner.address),
      at,
    );
    stdout.writeln(
      'create_vault ${p.owner.address == owner.address ? 'subscribed' : 'other'}'
      ' plan ${p.planId} $sig\n'
      '  vault ${vault.address}, heir ${p.heir.address} (0 SOL)',
    );
    _check(
      waived == (p.expected == solTier),
      'plan ${p.planId} of ${p.owner.address}: fee '
      '${waived ? 'waived' : 'charged'}',
    );
    final q = await client.quoteClaim(
      claimer: p.heir.address,
      vaultOwner: p.owner.address,
      planId: p.planId,
      index: 0,
    );
    _check(q.payer == ClaimPayer.sponsor, 'claim quoted as free');
    _check(q.net == p.expected, 'quoted net ${q.net} == ${p.expected}');
    final d = vault.ruleDueAt(0);
    if (d > due) due = d;
  }

  await _waitPast(sol, due);
  final via = <String>[];
  for (final p in plans) {
    via.add(await _claim(client, p, sponsorSigner));
  }
  for (final (i, p) in plans.indexed) {
    final v = (await client.fetchVault(p.owner.address, p.planId))!;
    final tag = 'plan ${p.planId} of ${p.owner.address} (${via[i]})';
    _check(v.rules[0].executed, '$tag: tier released');
    _check(
      await client.balance(p.heir.address) == p.expected,
      '$tag: heir received ${p.expected} lamports '
      '(${p.expected == solTier ? 'no fee' : '$bps bps fee'})',
    );
  }
  stdout.writeln('E2E OK');
  exit(0);
}

/// The beneficiary claims through the sponsor, unless the keeper released
/// the tier first; returns who released it.
Future<String> _claim(
  DeadmanClient client,
  _Plan p,
  String sponsorSigner,
) async {
  for (var tries = 0; ; tries++) {
    final v = (await client.fetchVault(p.owner.address, p.planId))!;
    if (v.rules[0].executed) return 'keeper';
    try {
      final claim = await client.buildClaim(
        claimer: p.heir.address,
        vaultOwner: p.owner.address,
        planId: p.planId,
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
        await _sign(claim.transaction, p.heir),
      ]);
      stdout.writeln('heir claim (sponsor pays the fee) $sig');
      return 'sponsored claim';
    } on DeadmanException catch (e) {
      final v = (await client.fetchVault(p.owner.address, p.planId))!;
      if (v.rules[0].executed) return 'keeper';
      if (tries >= 5) rethrow;
      stdout.writeln('claim retry after: $e');
      await Future<void>.delayed(const Duration(seconds: 3));
    }
  }
}

/// Polls the chain clock until it is past [due] (`execute_*` needs
/// `now > due`).
Future<void> _waitPast(SolanaClient sol, int due) async {
  final wall = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  if (due - wall > 6) {
    stdout.writeln('waiting ${due - wall - 5} s for the tiers to fall due');
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

void _check(bool ok, String what) {
  if (!ok) throw StateError('FAILED: $what');
  stdout.writeln('  ok: $what');
}

Future<void> _run(String cmd, List<String> args) async {
  final r = await Process.run(cmd, args);
  if (r.exitCode != 0) throw StateError('$cmd failed: ${r.stderr}');
}

/// Fills [signer]'s signature slot of an unsigned wire transaction.
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
    var same = true;
    for (var j = 0; j < 32; j++) {
      if (key[j] != me[j]) same = false;
    }
    if (same) {
      final sig = await signer.sign(message);
      final out = Uint8List.fromList(tx);
      out.setRange(1 + 64 * i, 1 + 64 * i + 64, sig.bytes);
      return out;
    }
  }
  throw StateError('${signer.address} is not a signer of this transaction');
}
