// Admin-only: updates the Deadman Config PDA through `set_config` (treasury,
// the release fee per rail, the SKR rate and its burned share), and rotates
// the admin in two steps (`propose_admin`, then `accept_admin` signed by the
// new key). Refuses a mainnet RPC unless --mainnet is passed.
//
// dart run tool/set_config.dart [fees] --keypair <admin> [--treasury <addr>]
//   [--fee-public 200] [--fee-private 200] [--fee-skr 150]
//   [--skr-burn-bps 1000] [--skr-mint <mint|none>] [--rpc <url>] [--mainnet]
// dart run tool/set_config.dart propose-admin --keypair <admin>
//   --new-admin <addr|none> [--rpc <url>] [--mainnet]
// dart run tool/set_config.dart accept-admin --keypair <new admin>
//   [--rpc <url>] [--mainnet]
//
// --treasury defaults to the current Config treasury, which must be a
// system-owned wallet. --skr-mint defaults to the cluster's SKR mint
// (devnet test SKR, or mainnet SKR with --mainnet); `none` turns the SKR
// rate off. The first `set_config` on a config in the old 77-byte layout
// reallocates it to the current one; the admin pays the extra rent.
// `propose-admin --new-admin none` cancels a pending proposal.
import 'dart:convert';
import 'dart:io';

import 'package:deadman/solana/codec.dart';
import 'package:solana/dto.dart' show BinaryAccountData, Encoding;
import 'package:solana/encoder.dart';
import 'package:solana/solana.dart';

const _usage =
    'usage: [fees] --keypair <admin> [--treasury <addr, default: current>] '
    '[--fee-public <0-${Limits.maxFeeBps}, default $defaultFeeBps>] '
    '[--fee-private <0-${Limits.maxFeeBps}, default $defaultFeeBps>] '
    '[--fee-skr <0-${Limits.maxFeeBps}, default $defaultFeeBpsSkr>] '
    '[--skr-burn-bps <0-${Limits.bpsDenominator}, default '
    '$defaultSkrBurnBps>] [--skr-mint <mint|none, default: the cluster '
    'SKR>] [--rpc <url>] [--mainnet]\n'
    '       propose-admin --keypair <admin> --new-admin <addr|none> '
    '[--rpc <url>] [--mainnet]\n'
    '       accept-admin --keypair <new admin> [--rpc <url>] [--mainnet]';

const devnetRpc = 'https://api.devnet.solana.com';
const mainnetGenesis = '5eykt4UsFv8P8NJdTREpY1vzqKqZKvdpKuc147dw2N9d';

/// Default rates of the release-fee model: 2% per release on every rail,
/// 1.5% for payouts in SKR, 10% of which is burned.
const defaultFeeBps = 200;
const defaultFeeBpsSkr = 150;
const defaultSkrBurnBps = 1000;

/// Test SKR (`AppConfig.skrMint` on devnet) and SKR on mainnet.
const devnetSkrMint = '4JX81qZWhPPT38Tn4ZswaS2DyH3PffdrFqbYgsoZCuHc';
const mainnetSkrMint = 'SKRbvo6Gf7GondiT3BbTfuRDPqLWei4j2Qy2NPGZhW3';

/// `sha256("global:<name>")[..8]` of the admin instructions.
const setConfigDisc = [108, 158, 154, 175, 212, 98, 52, 66];
const proposeAdminDisc = [121, 214, 199, 212, 87, 39, 117, 234];
const acceptAdminDisc = [112, 42, 45, 90, 116, 181, 13, 170];

enum ConfigCommand { fees, proposeAdmin, acceptAdmin }

const _commands = {
  'fees': ConfigCommand.fees,
  'propose-admin': ConfigCommand.proposeAdmin,
  'accept-admin': ConfigCommand.acceptAdmin,
};

typedef ConfigArgs = ({
  ConfigCommand command,
  String keypair,
  String? treasury,
  int feePublic,
  int feePrivate,
  int feeSkr,
  int skrBurnBps,

  /// [defaultPubkey] turns the SKR rate off.
  String skrMint,

  /// For propose-admin; [defaultPubkey] cancels a pending proposal.
  String? newAdmin,
  String rpc,
  bool mainnet,
});

String _pubkeyArg(String name, String value) {
  try {
    Ed25519HDPublicKey.fromBase58(value);
  } on Object {
    throw FormatException('--$name $value is not a public key');
  }
  return value;
}

/// Parses and validates the command line (mirrors `validate_fees` and the
/// treasury check of `set_config`); throws [FormatException] with the
/// reason.
ConfigArgs parseArgs(List<String> argv) {
  var command = ConfigCommand.fees;
  var rest = argv;
  if (argv.isNotEmpty && !argv.first.startsWith('--')) {
    final c = _commands[argv.first];
    if (c == null) throw FormatException('unknown command ${argv.first}');
    command = c;
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
  final keypair = args['keypair'];
  if (keypair == null) throw const FormatException('--keypair is required');

  int bps(String name, int fallback, int max) {
    final v = int.tryParse(args[name] ?? '$fallback');
    if (v == null || v < 0 || v > max) {
      throw FormatException('--$name is 0 to $max bps');
    }
    return v;
  }

  final feeArgs = [
    'treasury',
    'fee-public',
    'fee-private',
    'fee-skr',
    'skr-burn-bps',
    'skr-mint',
  ];
  if (command != ConfigCommand.fees) {
    for (final name in feeArgs) {
      if (args.containsKey(name)) {
        throw FormatException('--$name only applies to the fees command');
      }
    }
  }
  if (command != ConfigCommand.proposeAdmin && args.containsKey('new-admin')) {
    throw const FormatException('--new-admin only applies to propose-admin');
  }

  final treasury = args['treasury'];
  if (treasury != null) {
    _pubkeyArg('treasury', treasury);
    if (treasury == defaultPubkey) {
      throw const FormatException('--treasury cannot be the default key');
    }
  }
  final skr = args['skr-mint'];
  final skrMint = skr == null
      ? (mainnet ? mainnetSkrMint : devnetSkrMint)
      : skr == 'none'
      ? defaultPubkey
      : _pubkeyArg('skr-mint', skr);

  String? newAdmin;
  if (command == ConfigCommand.proposeAdmin) {
    final n = args['new-admin'];
    if (n == null) {
      throw const FormatException('propose-admin needs --new-admin');
    }
    newAdmin = n == 'none' ? defaultPubkey : _pubkeyArg('new-admin', n);
  }

  return (
    command: command,
    keypair: keypair,
    treasury: treasury,
    feePublic: bps('fee-public', defaultFeeBps, Limits.maxFeeBps),
    feePrivate: bps('fee-private', defaultFeeBps, Limits.maxFeeBps),
    feeSkr: bps('fee-skr', defaultFeeBpsSkr, Limits.maxFeeBps),
    skrBurnBps: bps('skr-burn-bps', defaultSkrBurnBps, Limits.bpsDenominator),
    skrMint: skrMint,
    newAdmin: newAdmin,
    rpc: args['rpc'] ?? devnetRpc,
    mainnet: mainnet,
  );
}

List<int> encodeSetConfig({
  required int feePublic,
  required int feePrivate,
  required String skrMint,
  required int feeSkr,
  required int skrBurnBps,
}) =>
    (BorshWriter()
          ..bytes(setConfigDisc)
          ..u16(feePublic)
          ..u16(feePrivate)
          ..pubkey(skrMint)
          ..u16(feeSkr)
          ..u16(skrBurnBps))
        .toBytes();

AccountMeta _signer(String k, {bool writable = false}) => writable
    ? AccountMeta.writeable(
        pubKey: Ed25519HDPublicKey.fromBase58(k),
        isSigner: true,
      )
    : AccountMeta.readonly(
        pubKey: Ed25519HDPublicKey.fromBase58(k),
        isSigner: true,
      );

AccountMeta _configMeta() => AccountMeta.writeable(
  pubKey: Ed25519HDPublicKey.fromBase58(configPda().address),
  isSigner: false,
);

/// `set_config`: `admin` (writable signer, pays a v1 reallocation),
/// `config` (writable), `treasury`, `system_program`.
Instruction setConfigIx({
  required String admin,
  required String treasury,
  required int feePublic,
  required int feePrivate,
  required String skrMint,
  required int feeSkr,
  required int skrBurnBps,
}) => deadmanIx(
  [
    _signer(admin, writable: true),
    _configMeta(),
    AccountMeta.readonly(
      pubKey: Ed25519HDPublicKey.fromBase58(treasury),
      isSigner: false,
    ),
    AccountMeta.readonly(pubKey: SystemProgram.id, isSigner: false),
  ],
  encodeSetConfig(
    feePublic: feePublic,
    feePrivate: feePrivate,
    skrMint: skrMint,
    feeSkr: feeSkr,
    skrBurnBps: skrBurnBps,
  ),
);

/// `propose_admin`: `admin` (signer), `config` (writable); [newAdmin]
/// [defaultPubkey] cancels a pending proposal.
Instruction proposeAdminIx({required String admin, required String newAdmin}) =>
    deadmanIx(
      [_signer(admin), _configMeta()],
      (BorshWriter()
            ..bytes(proposeAdminDisc)
            ..pubkey(newAdmin))
          .toBytes(),
    );

/// `accept_admin`: `new_admin` (signer), `config` (writable).
Instruction acceptAdminIx(String newAdmin) =>
    deadmanIx([_signer(newAdmin), _configMeta()], acceptAdminDisc);

String _pct(int bps) {
  final s = (bps / 100).toStringAsFixed(2).replaceFirst(RegExp(r'\.?0+$'), '');
  return '$s%';
}

String describeConfig(DeadmanConfig c) {
  final f = c.fees;
  final skr = f.skrMint;
  return [
    'Config ${configPda().address}'
        '${c.migrated ? '' : ' (old 77-byte layout: the next set_config '
                  'migrates it; payouts fail until then)'}',
    '  admin:         ${c.admin}',
    '  pending admin: ${c.pendingAdmin ?? 'none'}',
    '  treasury:      ${f.treasury}',
    '  fee public:    ${f.feeBpsPublic} bps (${_pct(f.feeBpsPublic)}, '
        'Solana rail)',
    '  fee private:   ${f.feeBpsPrivate} bps (${_pct(f.feeBpsPrivate)}, '
        'Cloak and Zcash rails)',
    if (skr == null)
      '  SKR rate:      off'
    else ...[
      '  SKR mint:      $skr',
      '  fee SKR:       ${f.feeBpsSkr} bps (${_pct(f.feeBpsSkr)}, any rail)',
      '  SKR burned:    ${f.skrBurnBps} bps (${_pct(f.skrBurnBps)} of the '
          'SKR fee; the rest goes to the treasury)',
    ],
  ].join('\n');
}

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
  final onMainnet = await rpc.getGenesisHash() == mainnetGenesis;
  if (onMainnet && !a.mainnet) {
    stderr.writeln('This RPC is mainnet-beta; pass --mainnet to confirm.');
    exit(1);
  }
  if (!onMainnet && a.mainnet) {
    stderr.writeln('--mainnet was passed but this RPC is not mainnet-beta.');
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
  final signer = await Ed25519HDKeyPair.fromPrivateKeyBytes(
    privateKey: secret.sublist(0, 32),
  );

  final Instruction ix;
  switch (a.command) {
    case ConfigCommand.fees || ConfigCommand.proposeAdmin:
      if (signer.address != before.admin) {
        stderr.writeln(
          'The keypair ${signer.address} is not the Config admin '
          '${before.admin}',
        );
        exit(1);
      }
      if (a.command == ConfigCommand.proposeAdmin) {
        if (a.newAdmin == before.admin) {
          stderr.writeln('${a.newAdmin} is already the admin');
          exit(1);
        }
        if (!before.migrated) {
          stderr.writeln(
            'Run set_config once first: it migrates the old Config layout',
          );
          exit(1);
        }
        ix = proposeAdminIx(admin: signer.address, newAdmin: a.newAdmin!);
        break;
      }
      final treasury = a.treasury ?? before.fees.treasury;
      final t = (await rpc.getAccountInfo(
        treasury,
        commitment: Commitment.confirmed,
      )).value;
      if (t != null && (t.owner != SystemProgram.programId || t.executable)) {
        stderr.writeln(
          'The treasury $treasury must be a system-owned wallet (owner '
          '${t.owner})',
        );
        exit(1);
      }
      if (!before.migrated) {
        stdout.writeln(
          'The Config is in the old layout: this set_config reallocates it '
          'to $configAccountSize bytes and ${signer.address} pays the extra '
          'rent.',
        );
      }
      ix = setConfigIx(
        admin: signer.address,
        treasury: treasury,
        feePublic: a.feePublic,
        feePrivate: a.feePrivate,
        skrMint: a.skrMint,
        feeSkr: a.feeSkr,
        skrBurnBps: a.skrBurnBps,
      );
    case ConfigCommand.acceptAdmin:
      if (before.pendingAdmin != signer.address) {
        stderr.writeln(
          'The keypair ${signer.address} is not the proposed admin '
          '(${before.pendingAdmin ?? 'none proposed'})',
        );
        exit(1);
      }
      ix = acceptAdminIx(signer.address);
  }

  final sig = await sol.sendAndConfirmTransaction(
    message: Message.only(ix),
    signers: [signer],
    commitment: Commitment.confirmed,
  );
  stdout.writeln('${a.command.name}: $sig');
  final after = await readConfig();
  if (after == null) {
    stderr.writeln('Config not found after the transaction');
    exit(1);
  }
  stdout
    ..writeln('After:')
    ..writeln(describeConfig(after));
}
