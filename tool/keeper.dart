// Protocol keeper: executes every due rule in every Deadman vault. Execution
// is permissionless and destinations are fixed on-chain, so the keeper can't
// redirect funds; the payout fee is what pays for running it.
//
// dart run tool/keeper.dart --keypair <path> [--rpc <url>] [--every 60]
import 'dart:convert';
import 'dart:io';

import 'package:deadman/solana/deadman_client.dart';
import 'package:solana/solana.dart';

Future<void> main(List<String> argv) async {
  final args = <String, String>{};
  for (var i = 0; i + 1 < argv.length; i += 2) {
    args[argv[i].replaceFirst('--', '')] = argv[i + 1];
  }
  final keypairPath = args['keypair'];
  if (keypairPath == null) {
    stderr.writeln('usage: --keypair <path> [--rpc <url>] [--every <seconds>]');
    exit(64);
  }
  final rpc = args['rpc'] ?? 'https://api.devnet.solana.com';
  final every = int.tryParse(args['every'] ?? '');

  final secret = (jsonDecode(File(keypairPath).readAsStringSync()) as List)
      .cast<int>();
  final keeper = await Ed25519HDKeyPair.fromPrivateKeyBytes(
    privateKey: secret.sublist(0, 32),
  );
  final client = DeadmanClient(
    SolanaClient(
      rpcUrl: Uri.parse(rpc),
      websocketUrl: Uri.parse(rpc.replaceFirst('http', 'ws')),
    ),
  );
  stdout.writeln('Keeper ${keeper.address} on $rpc');

  do {
    await sweep(client, keeper);
    if (every != null) await Future<void>.delayed(Duration(seconds: every));
  } while (every != null);
}

Future<void> sweep(DeadmanClient client, Ed25519HDKeyPair keeper) async {
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final vaults = await client.fetchAllVaults();
  var executed = 0;
  for (final v in vaults) {
    // Index order respects the program's per-asset ordering.
    for (var i = 0; i < v.rules.length; i++) {
      if (!v.canExecute(i, now)) continue;
      try {
        final sig = await client.executeRuleWithKey(
          keeper,
          vaultOwner: v.owner,
          index: i,
        );
        executed++;
        stdout.writeln(
          '${v.address} rule $i -> ${v.rules[i].beneficiary}: $sig',
        );
        // A Percent rule's share depends on what earlier rules left behind,
        // so stop and let the next sweep see fresh balances.
        break;
      } on Exception catch (e) {
        stderr.writeln('${v.address} rule $i failed: $e');
        break;
      }
    }
  }
  stdout.writeln(
    '${DateTime.now().toIso8601String()} scanned ${vaults.length} vaults, executed $executed',
  );
}
