// Devnet end-to-end check of SKR payouts and of NFT plans, with fresh
// scratch keys:
//
// 1. SKR: a scratch owner gets test SKR, creates a plan with one Fixed tier
//    of it and deposits it. Once due, a third-party sponsor (or the keeper,
//    if it was given an SKR --price that makes the fee worth it) releases
//    the tier. The release fee is 1.5% (Config.fee_bps_skr) on any rail;
//    10% of it (Config.skr_burn_bps) is burned, so the SKR supply drops by
//    exactly that share, the treasury receives the rest, the heir the
//    payout minus the fee, and the transaction logs FeeBurned. Skipped,
//    with the reason, when the Config does not name --skr-mint as its SKR
//    mint (tool/set_config.dart, docs/ADMIN_DEVNET.md).
// 2. NFT: the owner mints a classic Metaplex NFT (as tool/create_test_nft.dart),
//    creates a plan with one Fixed 1 tier of it and deposits it. Once due, a
//    third-party sponsor (or the running keeper, whichever is first) releases
//    the tier: the heir, who never holds SOL, ends up with the NFT, the
//    treasury with none (the fee rounds down to 0, so no treasury token
//    account is needed), and the tier cannot run twice.
//
// Live runs need the updated program deployed with a migrated Config, and
// the `solana` / `spl-token` CLIs whose default wallet holds devnet SOL and
// is the mint authority of --skr-mint (it mints the owner's SKR).
// Wallet-signed transactions pay their own SOL fees (no Kora).
//
// --dry-run sends nothing and funds nobody: it reads the configuration,
// reports what the live run would check or skip, and builds the plan
// transactions offline.
//
// dart run tool/e2e_skr_nft.dart [--dry-run] [--skr-mint <mint>]
//   [--rpc https://api.devnet.solana.com]
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:deadman/core/config.dart';
import 'package:deadman/solana/codec.dart';
import 'package:deadman/solana/deadman_api.dart';
import 'package:deadman/solana/deadman_client.dart';
import 'package:solana/dto.dart'
    show Account, BinaryAccountData, Encoding, LatestBlockhash;
import 'package:solana/solana.dart';

import 'create_test_nft.dart' show createNftIxs, editionPda;
import 'set_config.dart' show devnetRpc, devnetSkrMint, mainnetGenesis;

// Program minimum is 60 s; 120 s leaves room for the setup transactions.
const afterSecs = 120;

/// Whole SKR tokens the SKR tier pays.
const skrTokens = 10;

const _skrPlanId = 0;
const _nftPlanId = 1;

typedef E2eArgs = ({bool dryRun, String skrMint, String rpc});

/// Parses the command line; throws [FormatException] with the reason.
E2eArgs parseE2eArgs(List<String> argv) {
  var dryRun = false;
  final args = <String, String>{};
  for (var i = 0; i < argv.length; i++) {
    final a = argv[i];
    if (a == '--dry-run') {
      dryRun = true;
    } else if (a.startsWith('--') && i + 1 < argv.length) {
      args[a.substring(2)] = argv[++i];
    } else {
      throw FormatException('unexpected argument $a');
    }
  }
  final skr = args['skr-mint'] ?? devnetSkrMint;
  try {
    Ed25519HDPublicKey.fromBase58(skr);
  } on Object {
    throw FormatException('--skr-mint $skr is not a public key');
  }
  final rpc = args['rpc'] ?? devnetRpc;
  if (rpc.contains('mainnet')) throw const FormatException('devnet only');
  return (dryRun: dryRun, skrMint: skr, rpc: rpc);
}

/// `amount` of the first `FeeBurned` event in [logs] (Anchor
/// `Program data:` lines) for [vault] and [mint], or null.
int? burnedFromLogs(List<String> logs, String vault, String mint) {
  const prefix = 'Program data: ';
  for (final line in logs) {
    if (!line.startsWith(prefix)) continue;
    final List<int> data;
    try {
      data = base64.decode(line.substring(prefix.length));
    } on FormatException {
      continue;
    }
    if (data.length < 80 || !hasDiscriminator(data, Disc.feeBurnedEvent)) {
      continue;
    }
    final r = BorshReader(data)..offset = 8;
    if (r.pubkey() != vault || r.pubkey() != mint) continue;
    return r.u64();
  }
  return null;
}

/// What an SKR payout of [gross] base units splits into under [fees]:
/// the heir's net, the fee, its burned share and the treasury's share.
typedef SkrSplit = ({int net, int fee, int burned, int toTreasury});

SkrSplit skrSplit(FeeSchedule fees, String mint, int gross) {
  final fee = fees.feeOf(gross, Rail.solana, mint);
  final burned = fees.burnedOf(fee, mint);
  return (net: gross - fee, fee: fee, burned: burned, toTreasury: fee - burned);
}

Future<void> main(List<String> argv) async {
  final E2eArgs a;
  try {
    a = parseE2eArgs(argv);
  } on FormatException catch (e) {
    stderr
      ..writeln(e.message)
      ..writeln('usage: [--dry-run] [--skr-mint <mint>] [--rpc <devnet url>]');
    exit(64);
  }
  final sol = SolanaClient(
    rpcUrl: Uri.parse(a.rpc),
    websocketUrl: Uri.parse(a.rpc.replaceFirst('http', 'ws')),
  );
  if (await sol.rpcClient.getGenesisHash() == mainnetGenesis) {
    stderr.writeln('devnet only: this RPC is mainnet-beta');
    exit(64);
  }
  // No Kora: every wallet-signed transaction pays its own SOL fee.
  final client = DeadmanClient.withKora(client: sol);
  final config = await client.fetchConfig();
  final fees = config.fees;
  stdout.writeln(
    '${a.dryRun ? 'DRY RUN (nothing is sent)' : 'LIVE'} on ${a.rpc}\n'
    'program ${AppConfig.programId}, treasury ${fees.treasury}, fees '
    '${fees.feeBpsPublic}/${fees.feeBpsPrivate} bps, SKR '
    '${fees.skrMint ?? 'off'} at ${fees.feeBpsSkr} bps with '
    '${fees.skrBurnBps} bps of it burned',
  );
  if (!config.migrated) {
    stderr.writeln(
      'The Config is in the old layout and every payout fails until the '
      'admin runs set_config once (docs/ADMIN_DEVNET.md).',
    );
    if (!a.dryRun) exit(1);
  }

  final skr = await _skrSetup(sol, a.skrMint, fees);
  if (a.dryRun) {
    await _dryRun(skr, fees);
    stdout.writeln('DRY RUN OK');
    exit(0);
  }

  final owner = await Ed25519HDKeyPair.random();
  final sponsor = await Ed25519HDKeyPair.random();
  await _run('solana', [
    'transfer',
    owner.address,
    '0.1',
    '--allow-unfunded-recipient',
    '--url',
    a.rpc,
  ]);
  await _run('solana', [
    'transfer',
    sponsor.address,
    '0.05',
    '--allow-unfunded-recipient',
    '--url',
    a.rpc,
  ]);
  stdout.writeln('owner ${owner.address}\nsponsor ${sponsor.address}');

  if (skr.skip == null) {
    await _skrPlan(client, sol, a, skr, fees, owner, sponsor);
  } else {
    stdout.writeln('SKIPPED SKR payout: ${skr.skip}');
  }
  await _nftPlan(client, sol, owner, sponsor, fees.treasury);
  stdout.writeln('E2E OK${skr.skip == null ? '' : ' (SKR part skipped)'}');
  exit(0);
}

typedef _Skr = ({
  String mint,
  int decimals,

  /// The tier's gross amount in base units.
  int gross,

  /// Why the SKR part cannot run here; null = it runs.
  String? skip,
});

Future<_Skr> _skrSetup(SolanaClient sol, String mint, FeeSchedule fees) async {
  final Account? info = (await sol.rpcClient.getAccountInfo(
    mint,
    commitment: Commitment.confirmed,
    encoding: Encoding.base64,
  )).value;
  final data = info?.data;
  final decimals = data is BinaryAccountData
      ? decodeMintDecimals(data.data)
      : 6;
  final skip = info == null
      ? 'the mint $mint does not exist on this cluster'
      : info.owner != tokenProgramId
      ? '$mint is not a classic SPL Token mint'
      : !fees.isSkr(mint)
      ? 'the Config SKR mint is ${fees.skrMint ?? 'unset'}, not $mint: '
            'dart run tool/set_config.dart --keypair <admin> --skr-mint '
            '$mint (docs/ADMIN_DEVNET.md)'
      : fees.feeBpsSkr == 0
      ? 'the Config SKR fee is 0 bps'
      : null;
  return (
    mint: mint,
    decimals: decimals,
    gross: skrTokens * BigInt.from(10).pow(decimals).toInt(),
    skip: skip,
  );
}

RuleSpec _tier(String heir, String mint, int amount) => RuleSpec(
  beneficiary: heir,
  rail: Rail.solana,
  afterSecs: afterSecs,
  mode: AmountMode.fixed,
  amount: amount,
  mint: mint,
);

Future<void> _dryRun(_Skr skr, FeeSchedule fees) async {
  final heir = await Ed25519HDKeyPair.random();
  final guard = await Ed25519HDKeyPair.random();
  if (skr.skip == null) {
    final s = skrSplit(fees, skr.mint, skr.gross);
    final plan = encodeCreatePlan(
      planId: _skrPlanId,
      label: 'E2E SKR',
      guard: guard.address,
      lockSecs: 60,
      skipGraceSecs: 60,
      rules: [_tier(heir.address, skr.mint, skr.gross)],
    );
    _check(plan.isNotEmpty, 'create_plan data with a Fixed SKR tier encodes');
    stdout.writeln(
      'would: mint ${skr.gross} base units of SKR to the owner; create plan '
      '$_skrPlanId with one Fixed tier of them and deposit them; after '
      '$afterSecs s a sponsor (or the keeper) releases it; expect heir '
      '+${s.net}, fee ${s.fee} (${fees.feeBpsSkr} bps), supply -${s.burned}, '
      'treasury +${s.toTreasury}, FeeBurned(amount ${s.burned})',
    );
  } else {
    stdout.writeln('would SKIP the SKR payout: ${skr.skip}');
  }

  // NFT part, built offline with throwaway keys.
  final owner = await Ed25519HDKeyPair.random();
  final mint = await Ed25519HDKeyPair.random();
  final create = await signTransaction(
    const LatestBlockhash(
      blockhash: '11111111111111111111111111111111',
      lastValidBlockHeight: 0,
    ),
    Message(
      instructions: createNftIxs(
        authority: owner.address,
        mint: mint.address,
        mintRent: 1461600,
        name: 'Deadman Test Skull',
        symbol: 'DMSK',
        uri: '',
      ),
    ),
    [owner, mint],
  );
  final size = base64.decode(create.encode()).length;
  _check(size <= 1232, 'NFT creation transaction is $size bytes (max 1232)');
  final plan = encodeCreatePlan(
    planId: _nftPlanId,
    label: 'E2E NFT',
    guard: guard.address,
    lockSecs: 60,
    skipGraceSecs: 60,
    rules: [_tier(heir.address, mint.address, 1)],
  );
  _check(plan.isNotEmpty, 'create_plan data with a Fixed 1 NFT tier encodes');
  stdout.writeln(
    'would: mint NFT (metadata ${metadataPda(mint.address)}, edition '
    '${editionPda(mint.address)}); create plan $_nftPlanId with one Fixed 1 '
    'tier and deposit 1; after $afterSecs s a sponsor (or the keeper) '
    'releases it; expect heir 1, vault 0, treasury '
    '${ataAddress(fees.treasury, mint.address)} 0, heir 0 SOL, second '
    'release refused',
  );
}

Future<int> _supply(SolanaClient sol, String mint) async => int.parse(
  (await sol.rpcClient.getTokenSupply(
    mint,
    commitment: Commitment.confirmed,
  )).value.amount,
);

Future<void> _skrPlan(
  DeadmanClient client,
  SolanaClient sol,
  E2eArgs a,
  _Skr skr,
  FeeSchedule fees,
  Ed25519HDKeyPair owner,
  Ed25519HDKeyPair sponsor,
) async {
  final heir = await Ed25519HDKeyPair.random();
  final guard = await Ed25519HDKeyPair.random();
  final gross = skr.gross;
  await _run('spl-token', [
    'create-account',
    skr.mint,
    '--owner',
    owner.address,
    '--url',
    a.rpc,
  ]);
  await _run('spl-token', [
    'mint',
    skr.mint,
    '$skrTokens',
    '--recipient-owner',
    owner.address,
    '--url',
    a.rpc,
  ]);
  _check(
    await client.tokenBalance(owner.address, skr.mint) == gross,
    'owner holds $gross base units of SKR',
  );

  final create = await client.buildCreateVault(
    owner: owner.address,
    planId: _skrPlanId,
    label: 'E2E SKR',
    guard: guard.address,
    lockSecs: 60,
    skipGraceSecs: 60,
    rules: [_tier(heir.address, skr.mint, gross)],
    tokenDeposits: {skr.mint: gross},
  );
  final [planSig] = await client.sendSigned([await _sign(create, owner)]);
  final vault = (await client.fetchVault(owner.address, _skrPlanId))!;
  stdout.writeln('create_plan + deposit $planSig\n  vault ${vault.address}');
  _check(
    await client.tokenBalance(vault.address, skr.mint) == gross,
    'plan holds the SKR',
  );

  final s = skrSplit(fees, skr.mint, gross);
  stdout.writeln(
    'expect fee ${s.fee} (${fees.feeBpsSkr} bps), ${s.burned} of it burned '
    '(${fees.skrBurnBps} bps)',
  );
  final supply0 = await _supply(sol, skr.mint);
  final treasury0 = await client.tokenBalance(fees.treasury, skr.mint);
  await _waitPast(sol, vault.ruleDueAt(0));
  final (via, sig) = await _release(client, owner.address, _skrPlanId, sponsor);
  _check(
    (await client.fetchVault(owner.address, _skrPlanId))!.rules[0].executed,
    'SKR tier released ($via)',
  );
  _check(
    await client.tokenBalance(heir.address, skr.mint) == s.net,
    'heir received ${s.net} (gross $gross minus the fee)',
  );
  _check(
    await client.tokenBalance(vault.address, skr.mint) == 0,
    'plan is empty',
  );
  _check(
    supply0 - await _supply(sol, skr.mint) == s.burned,
    'SKR supply dropped by the burned share ${s.burned}',
  );
  _check(
    await client.tokenBalance(fees.treasury, skr.mint) - treasury0 ==
        s.toTreasury,
    'treasury received ${s.toTreasury} (the fee minus the burn)',
  );
  if (sig != null) {
    final logs =
        (await sol.rpcClient.getTransaction(
          sig,
          commitment: Commitment.confirmed,
        ))?.meta?.logMessages ??
        const <String>[];
    _check(
      burnedFromLogs(logs, vault.address, skr.mint) == s.burned,
      'FeeBurned event logged with amount ${s.burned}',
    );
  }
}

Future<void> _nftPlan(
  DeadmanClient client,
  SolanaClient sol,
  Ed25519HDKeyPair owner,
  Ed25519HDKeyPair sponsor,
  String treasury,
) async {
  final mint = await Ed25519HDKeyPair.random();
  final heir = await Ed25519HDKeyPair.random();
  final guard = await Ed25519HDKeyPair.random();
  final mintRent = await sol.rpcClient.getMinimumBalanceForRentExemption(
    TokenProgram.neededMintAccountSpace,
  );
  final createSig = await sol.sendAndConfirmTransaction(
    message: Message(
      instructions: createNftIxs(
        authority: owner.address,
        mint: mint.address,
        mintRent: mintRent,
        name: 'Deadman E2E Skull',
        symbol: 'DMSK',
        uri: '',
      ),
    ),
    signers: [owner, mint],
    commitment: Commitment.confirmed,
  );
  final nft = mint.address;
  stdout.writeln('NFT $nft $createSig');
  final listed = await client.fetchWalletNfts(owner.address);
  _check(
    listed.any((n) => n.mint == nft && n.supported),
    'the app lists the NFT as supported',
  );

  final create = await client.buildCreateVault(
    owner: owner.address,
    planId: _nftPlanId,
    label: 'E2E NFT',
    guard: guard.address,
    lockSecs: 60,
    skipGraceSecs: 60,
    rules: [_tier(heir.address, nft, 1)],
    tokenDeposits: {nft: 1},
  );
  final [planSig] = await client.sendSigned([await _sign(create, owner)]);
  final vault = (await client.fetchVault(owner.address, _nftPlanId))!;
  stdout.writeln('create_plan + deposit $planSig\n  vault ${vault.address}');
  _check(await client.tokenBalance(vault.address, nft) == 1, 'plan holds it');
  _check(await client.tokenBalance(owner.address, nft) == 0, 'owner gave it');
  try {
    await client
        .buildExecuteRule(
          executor: sponsor.address,
          vaultOwner: owner.address,
          planId: _nftPlanId,
          index: 0,
        )
        .then((tx) async => client.sendSigned([await _sign(tx, sponsor)]));
    _check(false, 'the tier is not payable before it is due');
  } on DeadmanException catch (e) {
    _check(true, 'not payable before it is due: ${e.name ?? e.code}');
  }

  await _waitPast(sol, vault.ruleDueAt(0));
  final (via, _) = await _release(client, owner.address, _nftPlanId, sponsor);
  final after = (await client.fetchVault(owner.address, _nftPlanId))!;
  _check(after.rules[0].executed, 'tier released ($via)');
  _check(await client.tokenBalance(heir.address, nft) == 1, 'heir holds it');
  _check(await client.balance(heir.address) == 0, 'heir never held SOL');
  _check(await client.tokenBalance(vault.address, nft) == 0, 'plan is empty');
  _check(
    await client.tokenBalance(treasury, nft) == 0,
    'treasury took no fee (1 x bps rounds down to 0)',
  );
  try {
    await client.buildExecuteRule(
      executor: sponsor.address,
      vaultOwner: owner.address,
      planId: _nftPlanId,
      index: 0,
    );
    _check(false, 'the tier cannot run twice');
  } on DeadmanException catch (e) {
    _check(true, 'the tier cannot run twice: ${e.name ?? e.code}');
  }
}

/// The sponsor releases the due tier of plan [planId] unless the keeper did
/// first; returns who released it and, for the sponsor, the signature.
Future<(String, String?)> _release(
  DeadmanClient client,
  String owner,
  int planId,
  Ed25519HDKeyPair sponsor,
) async {
  Future<bool> done() async =>
      (await client.fetchVault(owner, planId))!.rules[0].executed;
  for (var tries = 0; ; tries++) {
    if (await done()) return ('keeper', null);
    try {
      final tx = await client.buildExecuteRule(
        executor: sponsor.address,
        vaultOwner: owner,
        planId: planId,
        index: 0,
      );
      final [sig] = await client.sendSigned([await _sign(tx, sponsor)]);
      stdout.writeln('sponsor release (sponsor pays fees and rent) $sig');
      return ('sponsor', sig);
    } on DeadmanException catch (e) {
      if (await done()) return ('keeper', null);
      if (tries >= 5) rethrow;
      stdout.writeln('release retry after: $e');
      await Future<void>.delayed(const Duration(seconds: 3));
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
      final account = (await sol.rpcClient.getAccountInfo(
        'SysvarC1ock11111111111111111111111111111111',
        commitment: Commitment.confirmed,
        encoding: Encoding.base64,
      )).value;
      final data = account?.data;
      if (data is BinaryAccountData &&
          ByteData.sublistView(Uint8List.fromList(data.data))
                  .getInt64(32, Endian.little) >
              due) {
        return;
      }
    } on Object catch (e) {
      stdout.writeln('clock read failed: $e');
    }
    await Future<void>.delayed(const Duration(milliseconds: 400));
  }
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
