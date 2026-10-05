// Devnet end-to-end check of zero-SOL beneficiary claims through the local
// Kora stack: a scratch owner creates an inheritance plan with one SOL tier
// and one USDC tier for a beneficiary holding no SOL at all. Once due, the
// beneficiary claims the SOL tier through the free sponsor (:8080) and the
// USDC tier through the paymaster (:8081), whose fee comes out of the payout
// in the same transaction.
//
// The running keeper (tool/keeper.dart) executes due SOL tiers too. The
// claim is sent as soon as the chain clock passes the due time; if the
// keeper still wins, the run retries with a new plan and beneficiary (up to
// --attempts). The keeper leaves the USDC tier alone while the
// beneficiary's token account is missing (the fee does not cover its rent).
//
// Needs scripts/kora_start.sh running, and the `solana` / `spl-token` CLIs
// whose default wallet holds devnet SOL and --mint (it funds the owner).
//
// dart run tool/e2e_gasless_claims.dart [--mint <test USDC mint>]
//   [--sponsor http://127.0.0.1:8080] [--paymaster http://127.0.0.1:8081]
//   [--rpc https://api.devnet.solana.com] [--attempts 3]
import 'dart:io';
import 'dart:typed_data';

import 'package:deadman/kora/kora_client.dart';
import 'package:deadman/solana/deadman_api.dart';
import 'package:deadman/solana/deadman_client.dart';
import 'package:solana/dto.dart' show BinaryAccountData, Encoding;
import 'package:solana/encoder.dart';
import 'package:solana/solana.dart';

const solTier = 2000000; // 0.002 SOL
const usdcTier = 1000000; // 1 USDC (6 decimals)
// Program minimum is 60 s; 120 s leaves room for the setup transactions.
const afterSecs = 120;

Future<void> main(List<String> argv) async {
  final args = <String, String>{
    for (var i = 0; i + 1 < argv.length; i += 2)
      argv[i].replaceFirst('--', ''): argv[i + 1],
  };
  final mint = args['mint'] ?? 'Ew8Z6hhRp7MFK8KJAxRqaBQvBEjtRj4Y4K4YhWsPMFGk';
  final rpc = args['rpc'] ?? 'https://api.devnet.solana.com';
  final attempts = int.parse(args['attempts'] ?? '3');
  final sponsorUrl = Uri.parse(args['sponsor'] ?? 'http://127.0.0.1:8080');
  final paymasterUrl = Uri.parse(args['paymaster'] ?? 'http://127.0.0.1:8081');
  if (rpc.contains('mainnet')) {
    stderr.writeln('devnet only');
    exit(64);
  }
  final sol = SolanaClient(
    rpcUrl: Uri.parse(rpc),
    websocketUrl: Uri.parse(rpc.replaceFirst('http', 'ws')),
  );
  final client = DeadmanClient.withKora(
    client: sol,
    sponsor: KoraClient(sponsorUrl),
    paymaster: KoraClient(paymasterUrl),
    paymasterToken: mint,
  );
  final sponsorSigner = (await KoraClient(
    sponsorUrl,
  ).getPayerSigner()).signerAddress;
  final pm = await KoraClient(paymasterUrl).getPayerSigner();
  stdout.writeln(
    'sponsor signer $sponsorSigner, paymaster signer ${pm.signerAddress}, '
    'payment address ${pm.paymentAddress}',
  );

  final owner = await Ed25519HDKeyPair.random();
  stdout.writeln('owner ${owner.address}');
  await _run('solana', [
    'transfer',
    owner.address,
    '0.3',
    '--allow-unfunded-recipient',
    '--url',
    rpc,
  ]);
  await _run('spl-token', [
    'transfer',
    mint,
    '${attempts * usdcTier ~/ 1000000 + 2}',
    owner.address,
    '--fund-recipient',
    '--allow-unfunded-recipient',
    '--url',
    rpc,
  ]);
  stdout.writeln(
    'owner SOL ${await client.balance(owner.address)}, '
    'USDC ${await client.tokenBalance(owner.address, mint)}',
  );

  var solOk = false;
  var usdcOk = false;
  for (var planId = 0; planId < attempts && !(solOk && usdcOk); planId++) {
    stdout.writeln('\n--- attempt ${planId + 1} (plan $planId) ---');
    final r = await _attempt(
      client,
      sol,
      owner,
      planId,
      mint,
      sponsorSigner: sponsorSigner,
      paymasterSigner: pm.signerAddress,
      paymentAddress: pm.paymentAddress,
      claimUsdc: !usdcOk,
    );
    solOk |= r.sol;
    usdcOk |= r.usdc;
  }
  stdout.writeln(
    '\nSOL claim via sponsor: ${solOk ? 'OK' : 'NOT VERIFIED'}; '
    'USDC claim via paymaster: ${usdcOk ? 'OK' : 'NOT VERIFIED'}',
  );
  if (!(solOk && usdcOk)) exit(1);
  stdout.writeln('E2E OK');
  exit(0);
}

Future<({bool sol, bool usdc})> _attempt(
  DeadmanClient client,
  SolanaClient sol,
  Ed25519HDKeyPair owner,
  int planId,
  String mint, {
  required String sponsorSigner,
  required String paymasterSigner,
  required String paymentAddress,
  required bool claimUsdc,
}) async {
  final heir = await Ed25519HDKeyPair.random();
  final guard = await Ed25519HDKeyPair.random();
  final create = await client.buildCreateVault(
    owner: owner.address,
    planId: planId,
    label: 'E2E gasless claims',
    guard: guard.address,
    lockSecs: 60,
    skipGraceSecs: 60,
    rules: [
      RuleSpec(
        beneficiary: heir.address,
        rail: Rail.solana,
        afterSecs: afterSecs,
        mode: AmountMode.fixed,
        amount: solTier,
      ),
      RuleSpec(
        beneficiary: heir.address,
        rail: Rail.solana,
        afterSecs: afterSecs,
        mode: AmountMode.fixed,
        amount: usdcTier,
        mint: mint,
      ),
    ],
    depositLamports: solTier,
    tokenDeposits: {mint: usdcTier},
  );
  final [createSig] = await client.sendSigned([await _sign(create, owner)]);
  final vault = (await client.fetchVault(owner.address, planId))!;
  final due = vault.ruleDueAt(0);
  stdout.writeln(
    'create_plan $createSig\n'
    'vault ${vault.address}, heir ${heir.address} '
    '(SOL ${await client.balance(heir.address)}), due at $due',
  );
  _check(await client.balance(heir.address) == 0, 'heir starts with 0 SOL');

  final solQuote = await client.quoteClaim(
    claimer: heir.address,
    vaultOwner: owner.address,
    planId: planId,
    index: 0,
  );
  stdout.writeln(
    'SOL quote: payer=${solQuote.payer.name} free=${solQuote.free} '
    'net=${solQuote.net} problem=${solQuote.problem}',
  );
  _check(solQuote.payer == ClaimPayer.sponsor, 'SOL claim quoted as free');
  _check(solQuote.problem == null, 'SOL claim quoted without a problem');

  await _waitPast(sol, due);
  final solOk = await _claimSol(
    client,
    heir,
    owner.address,
    planId,
    sponsorSigner: sponsorSigner,
    net: solQuote.net,
  );
  if (!claimUsdc) return (sol: solOk, usdc: false);
  final usdcOk = await _claimUsdc(
    client,
    heir,
    owner.address,
    planId,
    mint,
    paymasterSigner: paymasterSigner,
    paymentAddress: paymentAddress,
  );
  return (sol: solOk, usdc: usdcOk);
}

Future<bool> _claimSol(
  DeadmanClient client,
  Ed25519HDKeyPair heir,
  String owner,
  int planId, {
  required String sponsorSigner,
  required int net,
}) async {
  for (var tries = 0; ; tries++) {
    final vault = (await client.fetchVault(owner, planId))!;
    if (vault.rules[0].executed) {
      stdout.writeln('SOL tier: the keeper executed it first (race lost)');
      return false;
    }
    try {
      final claim = await client.buildClaim(
        claimer: heir.address,
        vaultOwner: owner,
        planId: planId,
        index: 0,
      );
      _check(claim.payer == ClaimPayer.sponsor, 'SOL claim built sponsored');
      _check(
        _feePayer(claim.transaction) == sponsorSigner,
        'SOL claim fee payer is the sponsor signer',
      );
      final [sig] = await client.sendSigned([
        await _sign(claim.transaction, heir),
      ]);
      final got = await client.balance(heir.address);
      stdout.writeln(
        'SOL claim (sponsor pays the fee) $sig\n'
        '  heir SOL $got (quoted net $net)',
      );
      _check(got == net, 'heir received the full net payout, paid no fee');
      return true;
    } on DeadmanException catch (e) {
      final v = (await client.fetchVault(owner, planId))!;
      if (v.rules[0].executed) {
        stdout.writeln('SOL tier: the keeper executed it first (race lost)');
        return false;
      }
      if (tries >= 5) rethrow;
      stdout.writeln('SOL claim retry after: $e');
      await Future<void>.delayed(const Duration(seconds: 2));
    }
  }
}

Future<bool> _claimUsdc(
  DeadmanClient client,
  Ed25519HDKeyPair heir,
  String owner,
  int planId,
  String mint, {
  required String paymasterSigner,
  required String paymentAddress,
}) async {
  if ((await client.fetchVault(owner, planId))!.rules[1].executed) {
    stdout.writeln('USDC tier: executed by someone else first');
    return false;
  }
  final quote = await client.quoteClaim(
    claimer: heir.address,
    vaultOwner: owner,
    planId: planId,
    index: 1,
  );
  stdout.writeln(
    'USDC quote: payer=${quote.payer.name} net=${quote.net} '
    'fee=${quote.feeAmount} ${quote.feeToken} problem=${quote.problem}',
  );
  _check(quote.payer == ClaimPayer.payout, 'USDC claim quoted from payout');
  _check(quote.problem == null, 'USDC claim quoted without a problem');
  final heirSol = await client.balance(heir.address);
  final paymentBefore = await client.tokenBalance(paymentAddress, mint);
  final claim = await client.buildClaim(
    claimer: heir.address,
    vaultOwner: owner,
    planId: planId,
    index: 1,
  );
  _check(claim.payer == ClaimPayer.payout, 'USDC claim built on the payout');
  _check(
    _feePayer(claim.transaction) == paymasterSigner,
    'USDC claim fee payer is the paymaster signer',
  );
  final [sig] = await client.sendSigned([await _sign(claim.transaction, heir)]);
  final heirUsdc = await client.tokenBalance(heir.address, mint);
  final fee = await client.tokenBalance(paymentAddress, mint) - paymentBefore;
  final heirSolAfter = await client.balance(heir.address);
  stdout.writeln(
    'USDC claim (paymaster pays fee + ATA rent, fee from payout) $sig\n'
    '  heir USDC $heirUsdc = net ${quote.net} - fee $fee; '
    'Kora payment ATA +$fee; heir SOL $heirSol -> $heirSolAfter',
  );
  _check(fee > 0, "Kora's payment ATA received the fee");
  _check(heirUsdc + fee == quote.net, 'heir got the net payout minus the fee');
  _check(heirSolAfter == heirSol, 'heir spent no SOL on the USDC claim');
  return true;
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
