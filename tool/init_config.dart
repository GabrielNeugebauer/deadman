// Admin-only: initializes the Deadman Config PDA. Must be signed by the
// program's upgrade authority.
//
// dart run tool/init_config.dart --keypair <path> --treasury <addr>
//   --skr-mint <addr> [--price 100000000] [--fee-bps 50] [--rpc <url>]
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:solana/encoder.dart';
import 'package:solana/solana.dart';

const programId = 'ACHVLMoLDM3YPpGbNST4cZW4Tf2jx6nzJGuusyLJHofL';
const loaderUpgradeable = 'BPFLoaderUpgradeab1e11111111111111111111111';

Future<void> main(List<String> argv) async {
  final args = <String, String>{};
  for (var i = 0; i + 1 < argv.length; i += 2) {
    args[argv[i].replaceFirst('--', '')] = argv[i + 1];
  }
  final keypairPath = args['keypair'];
  final treasury = args['treasury'];
  final skrMint = args['skr-mint'];
  if (keypairPath == null || treasury == null || skrMint == null) {
    stderr.writeln('usage: --keypair <path> --treasury <addr> --skr-mint <addr> '
        '[--price <base units>] [--fee-bps <0-100>] [--rpc <url>]');
    exit(64);
  }
  final price = int.parse(args['price'] ?? '100000000');
  final feeBps = int.parse(args['fee-bps'] ?? '50');
  final rpc = args['rpc'] ?? 'https://api.devnet.solana.com';

  final secret = (jsonDecode(File(keypairPath).readAsStringSync()) as List).cast<int>();
  final admin = await Ed25519HDKeyPair.fromPrivateKeyBytes(privateKey: secret.sublist(0, 32));

  final program = Ed25519HDPublicKey.fromBase58(programId);
  final config = await Ed25519HDPublicKey.findProgramAddress(
    seeds: [utf8.encode('config')],
    programId: program,
  );
  final programData = await Ed25519HDPublicKey.findProgramAddress(
    seeds: [program.bytes],
    programId: Ed25519HDPublicKey.fromBase58(loaderUpgradeable),
  );

  final discriminator = sha256.convert(utf8.encode('global:init_config')).bytes.sublist(0, 8);
  final data = ByteArray.merge([
    ByteArray(discriminator),
    ByteArray(Ed25519HDPublicKey.fromBase58(treasury).bytes),
    ByteArray(Ed25519HDPublicKey.fromBase58(skrMint).bytes),
    ByteArray.u64(price),
    ByteArray.u16(feeBps),
  ]);

  final ix = Instruction(
    programId: program,
    accounts: [
      AccountMeta.writeable(pubKey: admin.publicKey, isSigner: true),
      AccountMeta.writeable(pubKey: config, isSigner: false),
      AccountMeta.readonly(pubKey: program, isSigner: false),
      AccountMeta.readonly(pubKey: programData, isSigner: false),
      AccountMeta.readonly(pubKey: SystemProgram.id, isSigner: false),
    ],
    data: data,
  );

  final client = SolanaClient(
    rpcUrl: Uri.parse(rpc),
    websocketUrl: Uri.parse(rpc.replaceFirst('http', 'ws')),
  );
  final sig = await client.sendAndConfirmTransaction(
    message: Message.only(ix),
    signers: [admin],
    commitment: Commitment.confirmed,
  );
  stdout.writeln('Config ${config.toBase58()} initialized: $sig');
}
