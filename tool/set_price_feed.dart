// Admin-only: registers the Pyth feed that prices a mint for SKR fee
// payments (`set_price_feed`), and shows the registry with the live state of
// each price account. Refuses a mainnet RPC unless --mainnet is passed.
//
// dart run tool/set_price_feed.dart --keypair <admin>
//   --asset <sol|usdc|skr|ore|jitosol> [--max-age 600] [--shard 0]
//   [--rpc <url>] [--mainnet]
// dart run tool/set_price_feed.dart --keypair <admin> --mint <addr>
//   --feed-id <64 hex> [--max-age 600] [--shard 0] [--rpc <url>] [--mainnet]
// dart run tool/set_price_feed.dart show [--rpc <url>] [--mainnet]
//
// --asset picks the cluster's mint (devnet test mints, or the real ones
// with --mainnet; SOL is registered under the wrapped SOL mint) and its
// Pyth feed. The program derives the price account itself: the push
// oracle's shard-`--shard` account of the feed, which Pyth keeps fresh for
// sponsored feeds (SOL/USD, USDC/USD) and scripts/pyth_pusher_start.sh for
// the others (SKR/USD, ORE/USD). `--max-age 0` disables a feed: payouts in
// that asset then pay the normal fee in the asset. `show` sends nothing.
import 'dart:convert';
import 'dart:io';

import 'package:deadman/core/config.dart';
import 'package:deadman/solana/codec.dart';
import 'package:solana/dto.dart' show Account, BinaryAccountData, Encoding;
import 'package:solana/solana.dart';

import 'set_config.dart' show devnetRpc, mainnetGenesis;

const _usage =
    'usage: --keypair <admin> (--asset <${'sol|usdc|skr|ore|jitosol'}> | '
    '--mint <addr> --feed-id <64 hex>) [--max-age <0-${Limits.maxPriceAgeSecs}, '
    'default $defaultMaxAgeSecs>] [--shard <0-65535, default 0>] '
    '[--rpc <url>] [--mainnet]\n'
    '       show [--rpc <url>] [--mainnet]';

/// Staleness allowed by default. Pyth refreshes the sponsored devnet
/// SOL/USD and USDC/USD accounts about every 5 minutes (they reach ~320 s
/// old), and scripts/pyth_pusher_start.sh pushes ours at least every 120 s.
const defaultMaxAgeSecs = 600;

typedef FeedPreset = ({String symbol, String mint, String feedId});

/// What `--asset` registers on each cluster. Devnet uses the app's test
/// mints (`AppConfig.usdcMint`, `skrMint`, `oreMint`) priced by the real
/// feeds; there is no devnet JitoSOL.
const devnetPresets = <String, FeedPreset>{
  'sol': (symbol: 'SOL', mint: nativeMint, feedId: PythFeedIds.solUsd),
  'usdc': (
    symbol: 'USDC',
    mint: 'Ew8Z6hhRp7MFK8KJAxRqaBQvBEjtRj4Y4K4YhWsPMFGk',
    feedId: PythFeedIds.usdcUsd,
  ),
  'skr': (
    symbol: 'SKR',
    mint: '4JX81qZWhPPT38Tn4ZswaS2DyH3PffdrFqbYgsoZCuHc',
    feedId: PythFeedIds.skrUsd,
  ),
  'ore': (
    symbol: 'ORE',
    mint: '6KdRjrWYouFLmEcNeDpJkc9AUgzvmE7cn3DbAx2KfSyt',
    feedId: PythFeedIds.oreUsd,
  ),
};

const mainnetPresets = <String, FeedPreset>{
  'sol': (symbol: 'SOL', mint: nativeMint, feedId: PythFeedIds.solUsd),
  'usdc': (
    symbol: 'USDC',
    mint: 'EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v',
    feedId: PythFeedIds.usdcUsd,
  ),
  'skr': (
    symbol: 'SKR',
    mint: 'SKRbvo6Gf7GondiT3BbTfuRDPqLWei4j2Qy2NPGZhW3',
    feedId: PythFeedIds.skrUsd,
  ),
  'ore': (
    symbol: 'ORE',
    mint: 'oreoU2P8bN6jkk3jbaiVxYnG1dCXcYxwhwyK9jSybcp',
    feedId: PythFeedIds.oreUsd,
  ),
  'jitosol': (
    symbol: 'JitoSOL',
    mint: 'J1toso1uCk3RLmjorhTtrVwY9HJ7X8V9yYac6Y7kGCPn',
    feedId: PythFeedIds.jitoSolUsd,
  ),
};

Map<String, FeedPreset> presetsFor({required bool mainnet}) =>
    mainnet ? mainnetPresets : devnetPresets;

/// Mirrors `PriceFeed::usable_price`: why the program would not use
/// [account] (owned by [owner]) as [feed]'s price at [now], or null when
/// it would.
String? priceProblem(
  PriceFeedEntry feed,
  String owner,
  List<int> account,
  int now,
) {
  if (feed.maxAgeSecs == 0) return 'feed disabled (max age 0)';
  if (owner != pythReceiverId) return 'not owned by the Pyth receiver';
  final PythPrice u;
  try {
    u = decodePriceUpdate(account);
  } on FormatException catch (e) {
    return e.message;
  }
  if (!u.full) return 'only partially verified';
  if (u.feedId != feed.feedId) return 'holds feed ${u.feedId}';
  if (u.price <= 0) return 'price ${u.price} is not positive';
  final age = now - u.publishTime;
  if (age > feed.maxAgeSecs) {
    return 'stale: ${age}s old, max ${feed.maxAgeSecs}s';
  }
  if (BigInt.from(u.conf) * BigInt.from(Limits.bpsDenominator) >
      BigInt.from(u.price) * BigInt.from(Limits.maxPriceConfBps)) {
    return 'confidence ${u.conf} above 2% of ${u.price}';
  }
  return null;
}

/// [PythPrice.price] as a decimal string.
String formatPrice(PythPrice u) {
  if (u.expo >= 0) return '${u.price * _pow10(u.expo)}';
  final s = u.price.abs().toString().padLeft(-u.expo + 1, '0');
  final cut = s.length + u.expo;
  return '${u.price < 0 ? '-' : ''}${s.substring(0, cut)}.${s.substring(cut)}';
}

int _pow10(int n) => List.filled(n, 10).fold(1, (a, b) => a * b);

typedef PriceFeedArgs = ({
  bool show,
  String? keypair,
  String? symbol,
  String mint,
  String feedId,
  int shard,
  int maxAgeSecs,
  String rpc,
  bool mainnet,
});

/// Parses and validates the command line (mirrors the checks of
/// `set_price_feed`); throws [FormatException] with the reason.
PriceFeedArgs parseArgs(List<String> argv) {
  var rest = argv;
  var show = false;
  if (argv.isNotEmpty && !argv.first.startsWith('--')) {
    if (argv.first != 'show') {
      throw FormatException('unknown command ${argv.first}');
    }
    show = true;
    rest = argv.sublist(1);
  }
  final args = <String, String>{};
  var mainnet = false;
  for (var i = 0; i < rest.length; i++) {
    final a = rest[i];
    if (a == '--mainnet') {
      mainnet = true;
    } else if (a.startsWith('--') && i + 1 < rest.length) {
      args[a.substring(2)] = rest[++i];
    } else {
      throw FormatException('unexpected argument $a');
    }
  }
  final rpc = args.remove('rpc') ?? devnetRpc;
  if (show) {
    if (args.isNotEmpty) {
      throw FormatException('show takes only --rpc and --mainnet');
    }
    return (
      show: true,
      keypair: null,
      symbol: null,
      mint: '',
      feedId: '',
      shard: 0,
      maxAgeSecs: 0,
      rpc: rpc,
      mainnet: mainnet,
    );
  }
  final keypair = args['keypair'];
  if (keypair == null) throw const FormatException('--keypair is required');

  final asset = args['asset'];
  final String mint;
  final String feedId;
  String? symbol;
  if (asset != null) {
    if (args.containsKey('mint') || args.containsKey('feed-id')) {
      throw const FormatException('pass --asset or --mint/--feed-id, not both');
    }
    final presets = presetsFor(mainnet: mainnet);
    final p = presets[asset.toLowerCase()];
    if (p == null) {
      throw FormatException(
        '--asset is one of ${presets.keys.join(', ')} on '
        '${mainnet ? 'mainnet' : 'devnet'}',
      );
    }
    (symbol, mint, feedId) = (p.symbol, p.mint, p.feedId);
  } else {
    final m = args['mint'];
    final f = args['feed-id'];
    if (m == null || f == null) {
      throw const FormatException('pass --asset, or --mint and --feed-id');
    }
    try {
      Ed25519HDPublicKey.fromBase58(m);
    } on Object {
      throw FormatException('--mint $m is not a public key');
    }
    if (m == defaultPubkey) {
      throw const FormatException('--mint cannot be the default key');
    }
    if (!RegExp(r'^(0x)?[0-9a-fA-F]{64}$').hasMatch(f)) {
      throw FormatException('--feed-id $f is not a 32-byte hex feed id');
    }
    mint = m;
    feedId = (f.startsWith('0x') ? f.substring(2) : f).toLowerCase();
  }

  final maxAge = int.tryParse(args['max-age'] ?? '$defaultMaxAgeSecs');
  if (maxAge == null || maxAge < 0 || maxAge > Limits.maxPriceAgeSecs) {
    throw const FormatException(
      '--max-age is 0 to ${Limits.maxPriceAgeSecs} seconds (0 disables the feed)',
    );
  }
  final shard = int.tryParse(args['shard'] ?? '0');
  if (shard == null || shard < 0 || shard > 0xffff) {
    throw const FormatException('--shard is 0 to 65535');
  }
  return (
    show: false,
    keypair: keypair,
    symbol: symbol,
    mint: mint,
    feedId: feedId,
    shard: shard,
    maxAgeSecs: maxAge,
    rpc: rpc,
    mainnet: mainnet,
  );
}

List<int>? _data(Account? a) {
  final d = a?.data;
  return d is BinaryAccountData ? d.data : null;
}

/// One line on [feed]'s price account: price, age, confidence, and why the
/// program would not use it.
String describePrice(PriceFeedEntry feed, Account? account, int now) {
  final data = _data(account);
  if (account == null || data == null) {
    return 'price account ${feed.priceAccount} does not exist (never pushed)';
  }
  final problem = priceProblem(feed, account.owner, data, now);
  String detail;
  try {
    final u = decodePriceUpdate(data);
    final pct = u.price > 0 ? (100 * u.conf / u.price).toStringAsFixed(3) : '-';
    detail =
        '${formatPrice(u)} USD, ${now - u.publishTime}s old, conf $pct%'
        '${u.full ? '' : ', partial'}';
  } on FormatException {
    detail = 'unreadable';
  }
  return '$detail: ${problem == null ? 'usable' : 'NOT usable, $problem'}';
}

String describeFeed(String label, PriceFeedEntry? f, Account? price, int now) {
  if (f == null) return '$label: not registered';
  return [
    '$label: ${f.mint}',
    '  feed:       ${f.feedId}',
    '  account:    ${f.priceAccount}',
    '  max age:    ${f.maxAgeSecs == 0 ? 'disabled' : '${f.maxAgeSecs}s'}',
    '  price:      ${describePrice(f, price, now)}',
  ].join('\n');
}

Future<void> main(List<String> argv) async {
  final PriceFeedArgs a;
  try {
    a = parseArgs(argv);
  } on FormatException catch (e) {
    stderr
      ..writeln(e.message)
      ..writeln(_usage);
    exit(64);
  }
  final sol = SolanaClient(
    rpcUrl: Uri.parse(a.rpc),
    websocketUrl: Uri.parse(a.rpc.replaceFirst('http', 'ws')),
  );
  final rpc = sol.rpcClient;
  final onMainnet = await rpc.getGenesisHash() == mainnetGenesis;
  if (onMainnet && !a.mainnet) {
    stderr.writeln('This RPC is mainnet-beta; pass --mainnet to confirm.');
    exit(1);
  }
  if (!onMainnet && a.mainnet) {
    stderr.writeln('--mainnet was passed but this RPC is not mainnet-beta.');
    exit(1);
  }

  Future<List<Account?>> accounts(List<String> keys) async =>
      (await rpc.getMultipleAccounts(
        keys,
        commitment: Commitment.confirmed,
        encoding: Encoding.base64,
      )).value;

  /// The registry entry of [mint] and its price account.
  Future<(PriceFeedEntry?, Account?)> readFeed(String mint) async {
    final [entry] = await accounts([priceFeedPda(mint).address]);
    final d = _data(entry);
    if (d == null || entry!.owner != AppConfig.programId) return (null, null);
    final f = decodePriceFeed(d);
    final [price] = await accounts([f.priceAccount]);
    return (f, price);
  }

  int now() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  if (a.show) {
    for (final p in presetsFor(mainnet: a.mainnet).values) {
      final (f, price) = await readFeed(p.mint);
      stdout.writeln(describeFeed(p.symbol, f, price, now()));
      if (f == null) {
        // What registering the preset would read.
        final shard0 = pythPriceAccount(p.feedId);
        final [acct] = await accounts([shard0]);
        final planned = (
          mint: p.mint,
          feedId: p.feedId,
          priceAccount: shard0,
          maxAgeSecs: defaultMaxAgeSecs,
        );
        stdout
          ..writeln('  shard 0:    $shard0')
          ..writeln('  price:      ${describePrice(planned, acct, now())}');
      } else if (f.feedId != p.feedId) {
        stdout.writeln('  (expected feed ${p.feedId})');
      }
    }
    return;
  }

  final [configAcct] = await accounts([configPda().address]);
  final configData = _data(configAcct);
  if (configData == null) {
    stderr.writeln('Deadman Config not found; run tool/init_config.dart');
    exit(1);
  }
  final admin = decodeConfig(configData).admin;
  final secret = (jsonDecode(File(a.keypair!).readAsStringSync()) as List)
      .cast<int>();
  final signer = await Ed25519HDKeyPair.fromPrivateKeyBytes(
    privateKey: secret.sublist(0, 32),
  );
  if (signer.address != admin) {
    stderr.writeln(
      'The keypair ${signer.address} is not the Config admin $admin',
    );
    exit(1);
  }

  final label = a.symbol ?? a.mint;
  final (before, beforePrice) = await readFeed(a.mint);
  stdout
    ..writeln('Before:')
    ..writeln(describeFeed(label, before, beforePrice, now()));

  final priceAccount = pythPriceAccount(a.feedId, shard: a.shard);
  final [price] = await accounts([priceAccount]);
  final planned = (
    mint: a.mint,
    feedId: a.feedId,
    priceAccount: priceAccount,
    maxAgeSecs: a.maxAgeSecs,
  );
  stdout.writeln(
    'Registering shard ${a.shard} account $priceAccount '
    '(${describePrice(planned, price, now())})',
  );

  final sig = await sol.sendAndConfirmTransaction(
    message: Message.only(
      setPriceFeedIx(
        admin: signer.address,
        mint: a.mint,
        feedId: a.feedId,
        shardId: a.shard,
        maxAgeSecs: a.maxAgeSecs,
      ),
    ),
    signers: [signer],
    commitment: Commitment.confirmed,
  );
  stdout.writeln('set_price_feed: $sig');
  final (after, afterPrice) = await readFeed(a.mint);
  stdout
    ..writeln('After:')
    ..writeln(describeFeed(label, after, afterPrice, now()));
}
