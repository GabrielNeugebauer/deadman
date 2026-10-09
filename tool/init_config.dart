// Admin-only: initializes the Deadman Config PDA. Must be signed by the
// program's upgrade authority, which becomes the admin. The program sets
// the default fees: 2% per release on every rail, 1.5% for payouts in
// --skr-mint, 10% of which is burned (change them with set_config.dart).
// The treasury must be a system-owned wallet. Refuses a mainnet RPC unless
// --mainnet is passed.
//
// dart run tool/init_config.dart --keypair <path> --treasury <addr>
//   [--skr-mint <mint|none>] [--rpc <url>] [--mainnet]
//
// --skr-mint defaults to the cluster's SKR mint (devnet test SKR, or
// mainnet SKR with --mainnet); `none` turns the SKR rate off.
import 'dart:convert';
import 'dart:io';

import 'package:deadman/core/config.dart';
import 'package:deadman/solana/codec.dart';
import 'package:solana/encoder.dart';
import 'package:solana/solana.dart';

import 'set_config.dart'
    show devnetRpc, devnetSkrMint, mainnetGenesis, mainnetSkrMint;

const loaderUpgradeable = 'BPFLoaderUpgradeab1e11111111111111111111111';

/// `sha256("global:init_config")[..8]`.
const initConfigDisc = [23, 235, 115, 232, 168, 96, 1, 231];

/// `init_config`: `admin` (writable signer), `config` (writable),
/// `treasury`, `program`, `program_data`, `system_program`; arg `skr_mint`.
Instruction initConfigIx({
  required String admin,
  required String treasury,
  required String skrMint,
}) {
  const programId = AppConfig.programId;
  final program = Ed25519HDPublicKey.fromBase58(programId);
  final programData = findPda([
    program.bytes,
  ], programId: loaderUpgradeable).address;
  AccountMeta ro(String k) => AccountMeta.readonly(
    pubKey: Ed25519HDPublicKey.fromBase58(k),
    isSigner: false,
  );
  return deadmanIx(
    [
      AccountMeta.writeable(
        pubKey: Ed25519HDPublicKey.fromBase58(admin),
        isSigner: true,
      ),
      AccountMeta.writeable(
        pubKey: Ed25519HDPublicKey.fromBase58(configPda().address),
        isSigner: false,
      ),
      ro(treasury),
      ro(programId),
      ro(programData),
      ro(SystemProgram.programId),
    ],
    (BorshWriter()
          ..bytes(initConfigDisc)
          ..pubkey(skrMint))
        .toBytes(),
  );
}

Future<void> main(List<String> argv) async {
  final args = <String, String>{};
  var mainnet = false;
  for (var i = 0; i < argv.length; i++) {
    if (argv[i] == '--mainnet') {
      mainnet = true;
    } else if (argv[i].startsWith('--') && i + 1 < argv.length) {
      args[argv[i].substring(2)] = argv[++i];
    }
  }
  final keypairPath = args['keypair'];
  final treasury = args['treasury'];
  if (keypairPath == null || treasury == null) {
    stderr.writeln(
      'usage: --keypair <path> --treasury <addr> '
      '[--skr-mint <mint|none, default: the cluster SKR>] [--rpc <url>] '
      '[--mainnet]',
    );
    exit(64);
  }
  final skr = args['skr-mint'];
  final skrMint = skr == null
      ? (mainnet ? mainnetSkrMint : devnetSkrMint)
      : skr == 'none'
      ? defaultPubkey
      : skr;
  final rpc = args['rpc'] ?? devnetRpc;

  final client = SolanaClient(
    rpcUrl: Uri.parse(rpc),
    websocketUrl: Uri.parse(rpc.replaceFirst('http', 'ws')),
  );
  final onMainnet = await client.rpcClient.getGenesisHash() == mainnetGenesis;
  if (onMainnet != mainnet) {
    stderr.writeln(
      onMainnet
          ? 'This RPC is mainnet-beta; pass --mainnet to confirm.'
          : '--mainnet was passed but this RPC is not mainnet-beta.',
    );
    exit(1);
  }

  final secret = (jsonDecode(File(keypairPath).readAsStringSync()) as List)
      .cast<int>();
  final admin = await Ed25519HDKeyPair.fromPrivateKeyBytes(
    privateKey: secret.sublist(0, 32),
  );
  final sig = await client.sendAndConfirmTransaction(
    message: Message.only(
      initConfigIx(admin: admin.address, treasury: treasury, skrMint: skrMint),
    ),
    signers: [admin],
    commitment: Commitment.confirmed,
  );
  stdout.writeln('Config ${configPda().address} initialized: $sig');
}
