// Admin-only: updates the Deadman Config PDA (treasury and the payout fee
// per rail) through `set_config`. Must be signed by `Config.admin`. Refuses
// a mainnet RPC unless --mainnet is passed.
//
// dart run tool/set_config.dart --keypair <path> [--treasury <addr>]
//   [--fee-public 200] [--fee-private 300] [--rpc <url>] [--mainnet]
//
// --treasury defaults to the current Config treasury.
import 'dart:convert';
import 'dart:io';

import 'package:deadman/solana/codec.dart';
import 'package:solana/dto.dart' show BinaryAccountData, Encoding;
import 'package:solana/encoder.dart';
import 'package:solana/solana.dart';

const _usage =
    'usage: --keypair <path> [--treasury <addr, default: current>] '
    '[--fee-public <0-${Limits.maxFeeBps}, default 200>] '
    '[--fee-private <0-${Limits.maxFeeBps}, default 300>] [--rpc <url>] '
    '[--mainnet]';

const devnetRpc = 'https://api.devnet.solana.com';
const mainnetGenesis = '5eykt4UsFv8P8NJdTREpY1vzqKqZKvdpKuc147dw2N9d';

/// `set_config` discriminator (`sha256("global:set_config")[..8]`).
const setConfigDisc = [108, 158, 154, 175, 212, 98, 52, 66];

typedef ConfigArgs = ({
  String keypair,
  String? treasury,
  int feePublic,
  int feePrivate,
  String rpc,
  bool mainnet,
});

/// Parses and validates the command line (mirrors `validate_config`);
/// throws [FormatException] with the reason.
ConfigArgs parseArgs(List<String> argv) {
  final args = <String, String>{};
  var mainnet = false;
  for (var i = 0; i < argv.length; i++) {
    final a = argv[i];
    if (a == '--mainnet') {
      mainnet = true;
    } else if (a.startsWith('--') && i + 1 < argv.length) {
      args[a.substring(2)] = argv[++i];
    } else {
      throw FormatException('unexpected argument $a');
    }
  }
  final keypair = args['keypair'];
  if (keypair == null) throw const FormatException('--keypair is required');
  final feePublic = int.tryParse(args['fee-public'] ?? '200');
  final feePrivate = int.tryParse(args['fee-private'] ?? '300');
  for (final bps in [feePublic, feePrivate]) {
    if (bps == null || bps < 0 || bps > Limits.maxFeeBps) {
      throw const FormatException(
        '--fee-public and --fee-private are 0 to ${Limits.maxFeeBps} bps',
      );
    }
  }
  final treasury = args['treasury'];
  if (treasury != null) {
    try {
      Ed25519HDPublicKey.fromBase58(treasury);
    } on Object {
      throw FormatException('--treasury $treasury is not a public key');
    }
    if (treasury == defaultPubkey) {
      throw const FormatException('--treasury cannot be the default key');
    }
  }
  return (
    keypair: keypair,
    treasury: treasury,
    feePublic: feePublic!,
    feePrivate: feePrivate!,
    rpc: args['rpc'] ?? devnetRpc,
    mainnet: mainnet,
  );
}

List<int> encodeSetConfig({
  required String treasury,
  required int feePublic,
  required int feePrivate,
}) =>
    (BorshWriter()
          ..bytes(setConfigDisc)
          ..pubkey(treasury)
          ..u16(feePublic)
          ..u16(feePrivate))
        .toBytes();

/// `set_config`: accounts `admin` (signer) and `config` (writable).
Instruction setConfigIx({
  required String admin,
  required String treasury,
  required int feePublic,
  required int feePrivate,
}) => deadmanIx(
  [
    AccountMeta.readonly(
      pubKey: Ed25519HDPublicKey.fromBase58(admin),
      isSigner: true,
    ),
    AccountMeta.writeable(
      pubKey: Ed25519HDPublicKey.fromBase58(configPda().address),
      isSigner: false,
    ),
  ],
  encodeSetConfig(
    treasury: treasury,
    feePublic: feePublic,
    feePrivate: feePrivate,
  ),
);

String _pct(int bps) {
  final s = (bps / 100).toStringAsFixed(2).replaceFirst(RegExp(r'\.?0+$'), '');
  return '$s%';
}

String describeConfig(DeadmanConfig c) =>
    'Config ${configPda().address}\n'
    '  admin:       ${c.admin}\n'
    '  treasury:    ${c.fees.treasury}\n'
    '  fee public:  ${c.fees.feeBpsPublic} bps (${_pct(c.fees.feeBpsPublic)}, '
    'Solana rail)\n'
    '  fee private: ${c.fees.feeBpsPrivate} bps '
    '(${_pct(c.fees.feeBpsPrivate)}, Cloak and Zcash rails)';

Future<void> main(List<String> argv) async {
  final ConfigArgs a;
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

  Future<DeadmanConfig?> readConfig() async {
    final d = (await rpc.getAccountInfo(
      configPda().address,
      commitment: Commitment.confirmed,
      encoding: Encoding.base64,
    )).value?.data;
    return d is BinaryAccountData ? decodeConfig(d.data) : null;
  }

  final before = await readConfig();
  if (before == null) {
    stderr.writeln('Deadman Config not found; run tool/init_config.dart');
    exit(1);
  }
  stdout
    ..writeln('Before:')
    ..writeln(describeConfig(before));

  final secret = (jsonDecode(File(a.keypair).readAsStringSync()) as List)
      .cast<int>();
  final admin = await Ed25519HDKeyPair.fromPrivateKeyBytes(
    privateKey: secret.sublist(0, 32),
  );
  if (admin.address != before.admin) {
    stderr.writeln(
      'The keypair ${admin.address} is not the Config admin ${before.admin}',
    );
    exit(1);
  }

  final sig = await sol.sendAndConfirmTransaction(
    message: Message.only(
      setConfigIx(
        admin: admin.address,
        treasury: a.treasury ?? before.fees.treasury,
        feePublic: a.feePublic,
        feePrivate: a.feePrivate,
      ),
    ),
    signers: [admin],
    commitment: Commitment.confirmed,
  );
  stdout.writeln('set_config: $sig');
  final after = await readConfig();
  if (after == null) {
    stderr.writeln('Config not found after the transaction');
    exit(1);
  }
  stdout
    ..writeln('After:')
    ..writeln(describeConfig(after));
}
