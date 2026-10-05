// Admin-only: sets the monthly-plan terms (SubscriptionConfig PDA) that let
// an owner prepay a flat price instead of the payout fee. Also opens the
// treasury's token account for the mint (admin pays the rent) when missing,
// since subscribe pays into it. Refuses a mainnet RPC unless
// --mainnet is passed.
//
// dart run tool/set_subscription.dart --keypair <path> --price <base units>
//   --mint <mint> (--enable | --disable) [--period-days 30]
//   [--min-periods 12] [--rpc <url>] [--mainnet]
import 'dart:convert';
import 'dart:io';

import 'package:deadman/solana/codec.dart';
import 'package:deadman/solana/deadman_api.dart';
import 'package:solana/dto.dart' show BinaryAccountData, Encoding;
import 'package:solana/solana.dart';

const _usage =
    'usage: --keypair <path> --price <base units per period> --mint <mint> '
    '(--enable | --disable) [--period-days <1-366, default 30>] '
    '[--min-periods <1-36, default 12>] [--rpc <url>] [--mainnet]';

const devnetRpc = 'https://api.devnet.solana.com';
const mainnetGenesis = '5eykt4UsFv8P8NJdTREpY1vzqKqZKvdpKuc147dw2N9d';

typedef SubscriptionArgs = ({
  String keypair,
  int price,
  int periodSecs,
  String mint,
  bool enabled,
  int minPeriods,
  String rpc,
  bool mainnet,
});

/// Parses and validates the command line (mirrors `set_subscription`);
/// throws [FormatException] with the reason.
SubscriptionArgs parseArgs(List<String> argv) {
  final args = <String, String>{};
  bool? enabled;
  var mainnet = false;
  for (var i = 0; i < argv.length; i++) {
    final a = argv[i];
    if (a == '--enable' || a == '--disable') {
      if (enabled != null) {
        throw const FormatException('pass one of --enable or --disable');
      }
      enabled = a == '--enable';
    } else if (a == '--mainnet') {
      mainnet = true;
    } else if (a.startsWith('--') && i + 1 < argv.length) {
      args[a.substring(2)] = argv[++i];
    } else {
      throw FormatException('unexpected argument $a');
    }
  }
  final keypair = args['keypair'];
  final mint = args['mint'];
  final price = int.tryParse(args['price'] ?? '');
  final days = int.tryParse(args['period-days'] ?? '30');
  final minPeriods = int.tryParse(args['min-periods'] ?? '12');
  if (keypair == null || mint == null || price == null || enabled == null) {
    throw const FormatException(
      '--keypair, --price, --mint and --enable/--disable are required',
    );
  }
  if (days == null || minPeriods == null) {
    throw const FormatException('--period-days and --min-periods are numbers');
  }
  try {
    Ed25519HDPublicKey.fromBase58(mint);
  } on Object {
    throw FormatException('--mint $mint is not a public key');
  }
  final periodSecs = days * 86400;
  if (setSubscriptionError(
        pricePerPeriod: price,
        periodSecs: periodSecs,
        mint: mint,
        minPeriods: minPeriods,
      ) !=
      null) {
    throw FormatException(
      'the program rejects these terms: price must be > 0, period 1 to 366 '
      'days, min periods 1 to ${Limits.maxSubPeriods}, mint not the default '
      'key',
    );
  }
  return (
    keypair: keypair,
    price: price,
    periodSecs: periodSecs,
    mint: mint,
    enabled: enabled,
    minPeriods: minPeriods,
    rpc: args['rpc'] ?? devnetRpc,
    mainnet: mainnet,
  );
}

String describeTerms(SubscriptionTerms t, int decimals) {
  final unit = BigInt.from(10).pow(decimals);
  final whole = BigInt.from(t.pricePerPeriod) ~/ unit;
  final frac = (BigInt.from(t.pricePerPeriod) % unit)
      .toString()
      .padLeft(decimals, '0')
      .replaceFirst(RegExp(r'0+$'), '');
  final price = frac.isEmpty ? '$whole' : '$whole.$frac';
  return 'SubscriptionConfig ${subConfigPda().address}\n'
      '  enabled:          ${t.enabled}\n'
      '  mint:             ${t.mint}\n'
      '  price per period: ${t.pricePerPeriod} base units ($price)\n'
      '  period:           ${t.periodSecs ~/ 86400} days (${t.periodSecs} s)\n'
      '  min periods:      ${t.minPeriods} (new or lapsed plans)';
}

Future<void> main(List<String> argv) async {
  final SubscriptionArgs a;
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
  if (await rpc.getGenesisHash() == mainnetGenesis && !a.mainnet) {
    stderr.writeln('This RPC is mainnet-beta; pass --mainnet to confirm.');
    exit(1);
  }

  Future<List<int>?> data(String address) async {
    final acc = (await rpc.getAccountInfo(
      address,
      commitment: Commitment.confirmed,
      encoding: Encoding.base64,
    )).value;
    final d = acc?.data;
    return d is BinaryAccountData ? d.data : null;
  }

  final mintAccount = (await rpc.getAccountInfo(
    a.mint,
    commitment: Commitment.confirmed,
    encoding: Encoding.base64,
  )).value;
  final mintData = mintAccount?.data;
  if (mintAccount?.owner != tokenProgramId || mintData is! BinaryAccountData) {
    stderr.writeln('${a.mint} is not a classic SPL Token mint');
    exit(1);
  }
  final decimals = decodeMintDecimals(mintData.data);

  final configData = await data(configPda().address);
  if (configData == null) {
    stderr.writeln('Deadman Config not found; run tool/init_config.dart');
    exit(1);
  }
  final config = decodeConfig(configData);

  final secret = (jsonDecode(File(a.keypair).readAsStringSync()) as List)
      .cast<int>();
  final admin = await Ed25519HDKeyPair.fromPrivateKeyBytes(
    privateKey: secret.sublist(0, 32),
  );
  if (admin.address != config.admin) {
    stderr.writeln(
      'The keypair ${admin.address} is not the Config admin ${config.admin}',
    );
    exit(1);
  }

  final treasury = config.fees.treasury;
  final openTreasury = await data(ataAddress(treasury, a.mint)) == null;
  final sig = await sol.sendAndConfirmTransaction(
    message: Message(
      instructions: [
        if (openTreasury)
          createAtaIdempotentIx(
            payer: admin.address,
            owner: treasury,
            mint: a.mint,
          ),
        setSubscriptionIx(
          admin: admin.address,
          pricePerPeriod: a.price,
          periodSecs: a.periodSecs,
          mint: a.mint,
          enabled: a.enabled,
          minPeriods: a.minPeriods,
        ),
      ],
    ),
    signers: [admin],
    commitment: Commitment.confirmed,
  );
  stdout.writeln(
    'set_subscription: $sig'
    '${openTreasury ? ' (opened treasury ${ataAddress(treasury, a.mint)})' : ''}',
  );
  final after = await data(subConfigPda().address);
  if (after == null) {
    stderr.writeln('SubscriptionConfig not found after the transaction');
    exit(1);
  }
  stdout.writeln(describeTerms(decodeSubscriptionConfig(after), decimals));
}
