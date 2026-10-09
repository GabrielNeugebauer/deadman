// Devnet end-to-end check of USDC vesting with network fees paid in USDC
// through the Kora paymaster gateway: an owner holding no SOL creates a
// revocable USDC vesting plan paying in two 60 s installments, checks that
// nothing more can be claimed between installments, releases each one and
// closes it.
//
// Needs the Kora stack (scripts/kora_start.sh) accepting --mint, and the
// `spl-token` CLI whose default wallet holds --mint to fund the owner.
//
// dart run tool/e2e_usdc_vesting.dart --mint <test USDC mint>
//   [--paymaster http://127.0.0.1:8081] [--rpc https://api.devnet.solana.com]
import 'dart:io';
import 'dart:typed_data';

import 'package:deadman/kora/kora_client.dart';
import 'package:deadman/solana/deadman_api.dart';
import 'package:deadman/solana/deadman_client.dart';
import 'package:solana/solana.dart';

Future<void> main(List<String> argv) async {
  final args = <String, String>{
    for (var i = 0; i + 1 < argv.length; i += 2)
      argv[i].replaceFirst('--', ''): argv[i + 1],
  };
  final mint = args['mint'];
  if (mint == null) {
    stderr.writeln('usage: --mint <test USDC mint> [--paymaster <url>]');
    exit(64);
  }
  final rpc = args['rpc'] ?? 'https://api.devnet.solana.com';
  final sol = SolanaClient(
    rpcUrl: Uri.parse(rpc),
    websocketUrl: Uri.parse(rpc.replaceFirst('http', 'ws')),
  );
  final client = DeadmanClient.withKora(
    client: sol,
    paymaster: KoraClient(
      Uri.parse(args['paymaster'] ?? 'http://127.0.0.1:8081'),
    ),
  )..feeToken = mint;

  final owner = await Ed25519HDKeyPair.random();
  final heir = await Ed25519HDKeyPair.random();
  final guard = await Ed25519HDKeyPair.random();
  stdout.writeln('owner ${owner.address} (no SOL), heir ${heir.address}');

  await _run('spl-token', [
    'transfer',
    mint,
    '20',
    owner.address,
    '--fund-recipient',
    '--allow-unfunded-recipient',
    '--url',
    rpc,
  ]);
  Future<int> usdc(String who) => client.tokenBalance(who, mint);
  stdout.writeln(
    'owner USDC ${await usdc(owner.address)}, '
    'SOL ${await client.balance(owner.address)}',
  );

  Future<void> step(String name, Future<Uint8List> Function() build) async {
    final before = await usdc(owner.address);
    final tx = await build();
    final [sig] = await client.sendSigned([await _sign(tx, owner)]);
    stdout.writeln(
      '$name: $sig, fee+moved ${before - await usdc(owner.address)}'
      ' base units',
    );
  }

  final start = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  await step(
    'create_vesting (Kora pays vault + ATA rent)',
    () => client.buildCreateVesting(
      owner: owner.address,
      planId: 0,
      label: 'E2E USDC vesting',
      guard: guard.address,
      lockSecs: 3600,
      startAt: start,
      revocable: true,
      schedules: [
        VestingSpec(
          beneficiary: heir.address,
          rail: Rail.solana,
          mint: mint,
          total: 10000000,
          cliffSecs: 0,
          durationSecs: 120,
        ),
      ],
      periodSecs: 60,
      tokenDeposits: {mint: 10000000},
    ),
  );
  var vault = (await client.fetchVault(owner.address, 0))!;
  stdout.writeln(
    'vault ${vault.address} kind=${vault.kind.name} '
    'rentPayer=${vault.rentPayer} '
    'period=${vault.vestPeriodSecs} '
    'held=${await usdc(vault.address)}',
  );
  Future<Uint8List> release() => client.buildReleaseVested(
    executor: owner.address,
    vaultOwner: owner.address,
    planId: 0,
    index: 0,
  );

  await Future<void>.delayed(const Duration(seconds: 30));
  await _expectNothingToPay('before the first installment', release);

  await Future<void>.delayed(const Duration(seconds: 35));
  await step('release #1 (installment 1 of 2, Kora pays heir ATA)', release);
  stdout.writeln('heir USDC ${await usdc(heir.address)}');
  await _expectNothingToPay('right after installment 1', release);

  await Future<void>.delayed(const Duration(seconds: 60));
  await step('release #2 (fully vested, basic tier)', release);
  vault = (await client.fetchVault(owner.address, 0))!;
  final heirGot = await usdc(heir.address);
  final feeBps = (await client.fetchFees()).feeBpsPublic;
  final expected = 10000000 - 10000000 * feeBps ~/ 10000;
  stdout.writeln(
    'heir USDC $heirGot (expect ~$expected after the $feeBps bps fee), '
    'released ${vault.rules[0].released}, '
    'committed ${vault.committed(mint)}',
  );

  await step(
    'close_vault (rent back to Kora)',
    () => client.buildCloseVault(owner: owner.address, planId: 0),
  );
  stdout.writeln('vault closed: ${await client.fetchVault(owner.address, 0)}');
  // Each release floors its fee, so the heir may get a unit more.
  if ((heirGot - expected).abs() > 2) exit(1);
  stdout.writeln('E2E OK');
  exit(0);
}

/// Fails the run unless [build] is refused with `NothingToPay` ([when]
/// names the moment).
Future<void> _expectNothingToPay(
  String when,
  Future<Uint8List> Function() build,
) async {
  try {
    await build();
  } on DeadmanException catch (e) {
    if (e.name != 'NothingToPay') rethrow;
    stdout.writeln('release $when refused: ${e.message}');
    return;
  }
  stderr.writeln('release $when was allowed: installments are not enforced');
  exit(1);
}

Future<void> _run(String cmd, List<String> args) async {
  final r = await Process.run(cmd, args);
  if (r.exitCode != 0) throw StateError('$cmd failed: ${r.stderr}');
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
