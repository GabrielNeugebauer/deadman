// Devnet end-to-end check of the SKR fee reserve, with fresh scratch keys:
//
// 1. SKR path: a scratch owner creates a plan with one Fixed SOL tier and,
//    in the same transaction, an SKR fee reserve. Once due, a third-party
//    sponsor (or the keeper, whichever is first) releases the tier with the
//    oracle accounts. The heir receives 100% of the tier; the program
//    takes fee_skr = 1.5% of the tier's USD value in SKR at the Pyth SOL/USD
//    and SKR/USD prices from the reserve (the SkrFeePaid event): the
//    reserve and the vault's SKR drop by fee_skr, the SKR supply by the
//    burned 10% of it, the treasury's SKR rises by the other 90%. fee_skr
//    matches the quote made from the prices before the release. Closing
//    the plan returns what is left of the reserve.
// 2. Fallback: a second plan whose reserve (1 base unit) cannot cover the
//    fee. Its release with the same accounts pays the normal 2% in SOL
//    (heir 98%), the reserve stays as it was, and no SKR moves. The owner
//    then withdraws the reserve, leaving it empty.
//
// Part 1 is skipped, with the reason, when the Config SKR mint is not
// --skr-mint, a PriceFeed for SOL or SKR is not registered, or a price is
// unusable (stale, partial, too uncertain): tool/set_price_feed.dart show
// and scripts/pyth_pusher_start.sh (docs/ADMIN_DEVNET.md).
//
// Live runs need the updated program deployed, and the `solana` /
// `spl-token` CLIs whose default wallet holds devnet SOL and is the mint
// authority of --skr-mint (it mints the owner's SKR). Wallet-signed
// transactions pay their own SOL fees (no Kora).
//
// --dry-run sends nothing and funds nobody: it reads the Config, the price
// registry and the prices, and prints the quote and what the live run
// would check or skip.
//
// dart run tool/e2e_skr_fee_reserve.dart [--dry-run] [--skr-mint <mint>]
//   [--rpc https://api.devnet.solana.com]
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:deadman/core/config.dart';
import 'package:deadman/solana/codec.dart';
import 'package:deadman/solana/deadman_api.dart';
import 'package:deadman/solana/deadman_client.dart';
import 'package:solana/dto.dart' show Account, BinaryAccountData, Encoding;
import 'package:solana/solana.dart';

import 'set_config.dart' show devnetRpc, devnetSkrMint, mainnetGenesis;

// Program minimum is 60 s; 120 s leaves room for the setup transactions.
const afterSecs = 120;

/// The SOL tier of each plan: 0.05 SOL.
const tierLamports = 50000000;

/// The SKR reserve funds this many times the quoted fee (prices move
/// between the quote and the release).
const reserveMargin = 3;

const _skrPlanId = 0;
const _fallbackPlanId = 1;

/// Relative gap allowed between the fee quoted before the release and the
/// one the program took (prices move in between): 2%.
const quoteToleranceBps = 200;

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
  for (final k in args.keys) {
    if (k != 'skr-mint' && k != 'rpc') {
      throw FormatException('unknown option --$k');
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

typedef SkrFeePaid = ({String vault, int index, int fee, int burned});

/// The first `SkrFeePaid` event in [logs] (Anchor `Program data:` lines)
/// for [vault], or null.
SkrFeePaid? skrFeePaidFromLogs(List<String> logs, String vault) {
  const prefix = 'Program data: ';
  for (final line in logs) {
    if (!line.startsWith(prefix)) continue;
    final List<int> data;
    try {
      data = base64.decode(line.substring(prefix.length));
    } on FormatException {
      continue;
    }
    if (data.length < 57 || !hasDiscriminator(data, Disc.skrFeePaidEvent)) {
      continue;
    }
    final r = BorshReader(data)..offset = 8;
    final v = r.pubkey();
    if (v != vault) continue;
    return (vault: v, index: r.u8(), fee: r.u64(), burned: r.u64());
  }
  return null;
}

/// Whether [actual] is within [toleranceBps] of [quoted] (at least one
/// base unit apart is always fine: the quote rounds up).
bool nearQuote(int actual, int quoted, {int toleranceBps = quoteToleranceBps}) {
  final gap = (actual - quoted).abs();
  return gap <= 1 || gap * Limits.bpsDenominator <= quoted * toleranceBps;
}

/// What the program reads to price an SKR fee: SOL's and SKR's usable
/// prices, or why the SKR path cannot run.
typedef Prices = ({
  (int, int)? sol,
  (int, int)? skr,
  int skrDecimals,

  /// Why nothing can run here (the Config does not take --skr-mint);
  /// null = the fallback part runs.
  String? unusable,

  /// Why part 1 cannot run here; null = it runs.
  String? skip,
});

Future<List<Account?>> _accounts(SolanaClient sol, List<String> keys) async =>
    (await sol.rpcClient.getMultipleAccounts(
      keys,
      commitment: Commitment.confirmed,
      encoding: Encoding.base64,
    )).value;

List<int>? _data(Account? a) {
  final d = a?.data;
  return d is BinaryAccountData ? d.data : null;
}

Future<Prices> _prices(SolanaClient sol, String mint, FeeSchedule fees) async {
  final [mintAcct, solFeed, skrFeed] = await _accounts(sol, [
    mint,
    priceFeedPda(nativeMint).address,
    priceFeedPda(mint).address,
  ]);
  final mintData = _data(mintAcct);
  final decimals = mintData == null ? 6 : decodeMintDecimals(mintData);
  final unusable = mintAcct == null
      ? 'the mint $mint does not exist on this cluster'
      : mintAcct.owner != tokenProgramId
      ? '$mint is not a classic SPL Token mint'
      : !fees.isSkr(mint)
      ? 'the Config SKR mint is ${fees.skrMint ?? 'unset'}, not $mint: '
            'dart run tool/set_config.dart --keypair <admin> --skr-mint '
            '$mint (docs/ADMIN_DEVNET.md)'
      : null;
  String? skip =
      unusable ?? (fees.feeBpsSkr == 0 ? 'the Config SKR fee is 0 bps' : null);

  PriceFeedEntry? entry(Account? a) {
    final d = _data(a);
    if (d == null || a!.owner != AppConfig.programId) return null;
    try {
      return decodePriceFeed(d);
    } on FormatException {
      return null;
    }
  }

  final feeds = [entry(solFeed), entry(skrFeed)];
  for (final (i, f) in feeds.indexed) {
    if (f == null) {
      skip ??=
          'no PriceFeed for ${i == 0 ? 'SOL' : 'SKR'}: dart run '
          'tool/set_price_feed.dart --keypair <admin> --asset '
          '${i == 0 ? 'sol' : 'skr'} (docs/ADMIN_DEVNET.md)';
    }
  }
  if (feeds.contains(null)) {
    return (
      sol: null,
      skr: null,
      skrDecimals: decimals,
      unusable: unusable,
      skip: skip,
    );
  }
  final [solFeedEntry!, skrFeedEntry!] = feeds;
  final priceAccounts = await _accounts(sol, [
    solFeedEntry.priceAccount,
    skrFeedEntry.priceAccount,
  ]);
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final usable = <(int, int)?>[];
  for (final (i, f) in [solFeedEntry, skrFeedEntry].indexed) {
    final a = priceAccounts[i];
    final d = _data(a);
    (int, int)? px;
    if (a != null && d != null && a.owner == pythReceiverId) {
      try {
        px = usablePrice(f, decodePriceUpdate(d), now);
      } on FormatException {
        px = null;
      }
    }
    if (px == null) {
      skip ??=
          'the ${i == 0 ? 'SOL' : 'SKR'} price at ${f.priceAccount} is '
          'missing, stale, partial or too uncertain (dart run '
          'tool/set_price_feed.dart show; SKR needs '
          'scripts/pyth_pusher_start.sh)';
    }
    usable.add(px);
  }
  return (
    sol: usable[0],
    skr: usable[1],
    skrDecimals: decimals,
    unusable: unusable,
    skip: skip,
  );
}

/// The SKR fee of a [tierLamports] tier at [p], or null.
int? _quote(Prices p, FeeSchedule fees) {
  final (sol, skr) = (p.sol, p.skr);
  if (sol == null || skr == null) return null;
  return skrFeeQuote(
    gross: tierLamports,
    asset: sol,
    assetDecimals: 9,
    skr: skr,
    skrDecimals: p.skrDecimals,
    feeBps: fees.feeBpsSkr,
  );
}

String _units(int amount, int decimals) {
  final s = amount.toString().padLeft(decimals + 1, '0');
  final cut = s.length - decimals;
  return decimals == 0 ? s : '${s.substring(0, cut)}.${s.substring(cut)}';
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
    'program ${AppConfig.programId}, treasury ${fees.treasury}, fee '
    '${fees.feeBpsPublic} bps, SKR ${fees.skrMint ?? 'off'} at '
    '${fees.feeBpsSkr} bps with ${fees.skrBurnBps} bps of it burned',
  );
  if (!config.migrated) {
    stderr.writeln(
      'The Config is in the old layout and every payout fails until the '
      'admin runs set_config once (docs/ADMIN_DEVNET.md).',
    );
    if (!a.dryRun) exit(1);
  }

  final prices = await _prices(sol, a.skrMint, fees);
  final quote = prices.skip == null ? _quote(prices, fees) : null;
  final skip =
      prices.skip ??
      (quote == null || quote == 0
          ? 'the quote for a $tierLamports-lamport tier is ${quote ?? 'unpriceable'}'
          : null);
  final assetFee = fees.feeOf(tierLamports, Rail.solana);
  final d = prices.skrDecimals;
  if (skip == null) {
    final q = quote!;
    final burned = fees.burnedOf(q, a.skrMint);
    stdout.writeln(
      '${a.dryRun ? 'would' : 'will'}: plan $_skrPlanId with a '
      '$tierLamports-lamport tier and a reserve of '
      '${_units(q * reserveMargin, d)} SKR; expect heir +$tierLamports '
      '(100%), fee ~${_units(q, d)} SKR (SOL '
      '${prices.sol!.$1}e${prices.sol!.$2}, SKR ${prices.skr!.$1}e'
      '${prices.skr!.$2}), supply -${_units(burned, d)}, treasury '
      '+${_units(q - burned, d)} SKR and no SOL fee',
    );
  } else {
    stdout.writeln(
      '${a.dryRun ? 'would SKIP' : 'SKIPPING'} the SKR path: $skip',
    );
  }
  stdout.writeln(
    '${a.dryRun ? 'would' : 'will'}: plan $_fallbackPlanId with a '
    '$tierLamports-lamport tier and a 1-unit reserve; expect heir '
    '+${tierLamports - assetFee}, fee $assetFee lamports (2%), reserve '
    'unchanged; then the owner withdraws it',
  );
  if (prices.unusable != null) {
    stdout.writeln(
      '${a.dryRun ? 'would FAIL' : 'FAILED'}: no SKR reserve possible: '
      '${prices.unusable}',
    );
    exit(a.dryRun ? 0 : 1);
  }
  if (a.dryRun) {
    stdout.writeln('DRY RUN OK');
    exit(0);
  }

  final reserve = skip == null ? quote! * reserveMargin : 0;
  final owner = await Ed25519HDKeyPair.random();
  final sponsor = await Ed25519HDKeyPair.random();
  await _run('solana', [
    'transfer',
    owner.address,
    '0.2',
    '--allow-unfunded-recipient',
    '--url',
    a.rpc,
  ]);
  await _run('solana', [
    'transfer',
    sponsor.address,
    '0.02',
    '--allow-unfunded-recipient',
    '--url',
    a.rpc,
  ]);
  stdout.writeln('owner ${owner.address}\nsponsor ${sponsor.address}');

  // Mint to the CLI wallet, then send with --fund-recipient: spl-token 5.5
  // refuses `create-account --owner` without an explicit --fee-payer.
  final ownerSkr = reserve + 1;
  final whole = _units(ownerSkr, d);
  await _run('spl-token', ['mint', a.skrMint, whole, '--url', a.rpc]);
  await _run('spl-token', [
    'transfer',
    a.skrMint,
    whole,
    owner.address,
    '--fund-recipient',
    '--allow-unfunded-recipient',
    '--url',
    a.rpc,
  ]);
  _check(
    await client.tokenBalance(owner.address, a.skrMint) == ownerSkr,
    'owner holds $whole SKR',
  );

  // Without the treasury's SKR account the program falls back to the
  // asset fee; the owner opens it once if it is missing.
  final treasurySkr = ataAddress(fees.treasury, a.skrMint);
  if (skip == null && (await _accounts(sol, [treasurySkr])).first == null) {
    final sig = await sol.sendAndConfirmTransaction(
      message: Message.only(
        createAtaIdempotentIx(
          payer: owner.address,
          owner: fees.treasury,
          mint: a.skrMint,
        ),
      ),
      signers: [owner],
      commitment: Commitment.confirmed,
    );
    stdout.writeln('opened the treasury SKR account $treasurySkr: $sig');
  }

  final heirs = [
    await Ed25519HDKeyPair.random(),
    await Ed25519HDKeyPair.random(),
  ];
  final plans = [
    if (skip == null) (_skrPlanId, reserve, heirs[0]),
    (_fallbackPlanId, 1, heirs[1]),
  ];
  for (final (planId, skrReserve, heir) in plans) {
    final guard = await Ed25519HDKeyPair.random();
    final create = await client.buildCreateVault(
      owner: owner.address,
      planId: planId,
      label: 'E2E SKR fee $planId',
      guard: guard.address,
      lockSecs: 60,
      skipGraceSecs: 60,
      rules: [
        RuleSpec(
          beneficiary: heir.address,
          rail: Rail.solana,
          afterSecs: afterSecs,
          mode: AmountMode.fixed,
          amount: tierLamports,
        ),
      ],
      depositLamports: tierLamports,
      skrReserve: skrReserve,
    );
    final [sig] = await client.sendSigned([await _sign(create, owner)]);
    final vault = (await client.fetchVault(owner.address, planId))!;
    stdout.writeln(
      'create_plan + deposit + fund_skr_reserve $sig\n  vault '
      '${vault.address}',
    );
    _check(
      vault.skrFeeReserve == skrReserve && vault.skrReserveMint == a.skrMint,
      'plan $planId reserve is ${_units(skrReserve, d)} SKR',
    );
  }

  if (skip == null) {
    await _skrPath(client, sol, a, fees, owner, sponsor, heirs[0], quote!);
  }
  await _fallback(client, sol, a, fees, owner, sponsor, heirs[1]);
  stdout.writeln('E2E OK${skip == null ? '' : ' (SKR path skipped: $skip)'}');
  exit(0);
}

Future<int> _supply(SolanaClient sol, String mint) async => int.parse(
  (await sol.rpcClient.getTokenSupply(
    mint,
    commitment: Commitment.confirmed,
  )).value.amount,
);

Future<void> _skrPath(
  DeadmanClient client,
  SolanaClient sol,
  E2eArgs a,
  FeeSchedule fees,
  Ed25519HDKeyPair owner,
  Ed25519HDKeyPair sponsor,
  Ed25519HDKeyPair heir,
  int quote,
) async {
  final mint = a.skrMint;
  final vault = (await client.fetchVault(owner.address, _skrPlanId))!;
  await _waitPast(sol, vault.ruleDueAt(0));
  // Quote again right before the release: the prices moved while waiting.
  final fresh = _quote(await _prices(sol, mint, fees), fees) ?? quote;
  final reserve0 = vault.skrFeeReserve;
  final held0 = await client.tokenBalance(vault.address, mint);
  final supply0 = await _supply(sol, mint);
  final treasury0 = await client.tokenBalance(fees.treasury, mint);
  final (via, sig) = await _release(
    client,
    sol,
    owner.address,
    _skrPlanId,
    sponsor,
  );
  final after = (await client.fetchVault(owner.address, _skrPlanId))!;
  _check(after.rules[0].executed, 'SOL tier released ($via)');
  final event = sig == null
      ? null
      : skrFeePaidFromLogs(await _logs(sol, sig), vault.address);
  _check(
    event != null && event.index == 0,
    'SkrFeePaid logged: the fee was paid in SKR',
  );
  final fee = event!.fee;
  _check(
    await client.balance(heir.address) == tierLamports,
    'heir received $tierLamports lamports (100% of the tier)',
  );
  _check(
    nearQuote(fee, fresh),
    'fee $fee SKR units is within ${quoteToleranceBps / 100}% of the quote '
    '$fresh',
  );
  _check(
    reserve0 - after.skrFeeReserve == fee,
    'reserve dropped by the fee ($reserve0 -> ${after.skrFeeReserve})',
  );
  _check(
    held0 - await client.tokenBalance(vault.address, mint) == fee,
    "the vault's SKR dropped by the fee",
  );
  final burned = fees.burnedOf(fee, mint);
  _check(event.burned == burned, 'burned $burned (${fees.skrBurnBps} bps)');
  _check(
    supply0 - await _supply(sol, mint) == burned,
    'SKR supply dropped by the burned share',
  );
  _check(
    await client.tokenBalance(fees.treasury, mint) - treasury0 == fee - burned,
    'treasury received ${fee - burned} SKR units (the fee minus the burn)',
  );

  final left = after.skrFeeReserve;
  final owned0 = await client.tokenBalance(owner.address, mint);
  final close = await client.buildCloseVault(
    owner: owner.address,
    planId: _skrPlanId,
  );
  final [closeSig] = await client.sendSigned([await _sign(close, owner)]);
  stdout.writeln('close_vault $closeSig');
  _check(
    await client.fetchVault(owner.address, _skrPlanId) == null,
    'plan closed',
  );
  _check(
    await client.tokenBalance(owner.address, mint) - owned0 == left,
    'closing returned the rest of the reserve ($left)',
  );
}

Future<void> _fallback(
  DeadmanClient client,
  SolanaClient sol,
  E2eArgs a,
  FeeSchedule fees,
  Ed25519HDKeyPair owner,
  Ed25519HDKeyPair sponsor,
  Ed25519HDKeyPair heir,
) async {
  final mint = a.skrMint;
  final vault = (await client.fetchVault(owner.address, _fallbackPlanId))!;
  await _waitPast(sol, vault.ruleDueAt(0));
  final supply0 = await _supply(sol, mint);
  final (via, sig) = await _release(
    client,
    sol,
    owner.address,
    _fallbackPlanId,
    sponsor,
  );
  final after = (await client.fetchVault(owner.address, _fallbackPlanId))!;
  _check(after.rules[0].executed, 'fallback tier released ($via)');
  final fee = fees.feeOf(tierLamports, Rail.solana);
  _check(
    await client.balance(heir.address) == tierLamports - fee,
    'heir received ${tierLamports - fee} lamports (2% fee $fee in SOL)',
  );
  if (sig != null) {
    _check(
      skrFeePaidFromLogs(await _logs(sol, sig), vault.address) == null,
      'no SkrFeePaid event',
    );
  }
  _check(after.skrFeeReserve == 1, 'reserve unchanged (1 unit)');
  _check(await _supply(sol, mint) == supply0, 'no SKR burned');

  final owned0 = await client.tokenBalance(owner.address, mint);
  final withdraw = await client.buildWithdrawSkrReserve(
    owner: owner.address,
    planId: _fallbackPlanId,
    amount: 1,
  );
  final [wSig] = await client.sendSigned([await _sign(withdraw, owner)]);
  stdout.writeln('withdraw_skr_reserve $wSig');
  _check(
    (await client.fetchVault(owner.address, _fallbackPlanId))!.skrFeeReserve ==
        0,
    'reserve empty after the withdrawal',
  );
  _check(
    await client.tokenBalance(owner.address, mint) - owned0 == 1,
    'the owner got the unit back',
  );
}

Future<List<String>> _logs(SolanaClient sol, String sig) async =>
    (await sol.rpcClient.getTransaction(
      sig,
      commitment: Commitment.confirmed,
    ))?.meta?.logMessages ??
    const <String>[];

/// The sponsor releases the due tier of plan [planId] unless the keeper did
/// first; returns who released it and the release signature (for the
/// keeper, the vault's latest transaction).
Future<(String, String?)> _release(
  DeadmanClient client,
  SolanaClient sol,
  String owner,
  int planId,
  Ed25519HDKeyPair sponsor,
) async {
  Future<bool> done() async =>
      (await client.fetchVault(owner, planId))!.rules[0].executed;
  Future<(String, String?)> byKeeper() async {
    final sigs = await sol.rpcClient.getSignaturesForAddress(
      client.vaultAddressFor(owner, planId),
      limit: 1,
      commitment: Commitment.confirmed,
    );
    return ('keeper', sigs.firstOrNull?.signature);
  }

  for (var tries = 0; ; tries++) {
    if (await done()) return byKeeper();
    try {
      final tx = await client.buildExecuteRule(
        executor: sponsor.address,
        vaultOwner: owner,
        planId: planId,
        index: 0,
      );
      final [sig] = await client.sendSigned([await _sign(tx, sponsor)]);
      stdout.writeln('sponsor release $sig');
      return ('sponsor', sig);
    } on DeadmanException catch (e) {
      if (await done()) return byKeeper();
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
