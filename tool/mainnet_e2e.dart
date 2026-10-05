// Full mainnet end-to-end test of Deadman with real (small) funds. Run it
// only after the program is deployed and its Config initialized on mainnet
// (docs/MAINNET.md). It drives everything from throwaway keys in --workdir:
//
//  a. create an inheritance plan (tiers due 120 s after the last check-in)
//     with a Zcash-rail SOL tier to claim key A and a Cloak-rail tier (SOL,
//     or USDC with --cloak-usdc) to claim key B, and deposit;
//  b. wait until the tiers are due and execute them, as the keeper would;
//  c. route claim key A through ZcashRoute (1Click) to --zcash-u1 and track
//     the swap to SUCCESS;
//  d. route claim key B through CloakRoute: the Cloak SDK bundle runs in
//     headless Chromium (tool/cloak_bundle/live.mjs) and private-sends to
//     --cloak-dest;
//  e. create a USDC vesting plan (60 s, no cliff), release it once and check
//     the heir got it minus the fee;
//  f. close both plans and sweep every key in --workdir back to --return-to.
//
// Keys: owner.json is a fresh random keypair; the guard, claim keys and the
// vesting heir derive from phrase.txt the way the app derives claim keys
// (m/44'/501'/<account>'/0': Cloak 1, Zcash 2, guard 3, heir 4). Only public
// keys are printed. state.json makes every step resumable: run the same
// command again after any failure.
//
//   dart run tool/mainnet_e2e.dart --workdir <dir> --dry-run [--rpc <url>]
//   dart run tool/mainnet_e2e.dart --cluster mainnet-beta --rpc <url> \
//     --workdir <dir> --zcash-u1 <u1...> --cloak-dest <solana address> \
//     --return-to <solana address> --i-funded-this
//
// Run with --help for every option. Env: ONECLICK_JWT (optional 1Click key).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bip39/bip39.dart' as bip39;
import 'package:deadman/core/config.dart';
import 'package:deadman/kora/kora_client.dart';
import 'package:deadman/rails/cloak_route.dart';
import 'package:deadman/rails/zcash_route.dart';
import 'package:deadman/solana/codec.dart';
import 'package:deadman/solana/deadman_api.dart';
import 'package:deadman/solana/deadman_client.dart';
import 'package:solana/dto.dart' show BinaryAccountData, Commitment, Encoding;
import 'package:solana/encoder.dart';
import 'package:solana/solana.dart';

import 'keeper.dart' show Keeper, clusters;

const _usage = '''
Deadman mainnet end-to-end test (real funds; see docs/MAINNET.md).

Required for a live run:
  --cluster mainnet-beta     (devnet = rehearsal: Zcash and Cloak are skipped)
  --rpc <url>                RPC for transactions (Helius recommended)
  --workdir <dir>            keys, phrase and state.json live here (created)
  --zcash-u1 <address>       shielded Zcash unified address (unless --skip-zcash)
  --cloak-dest <address>     Solana address the Cloak private send pays (unless --skip-cloak)
  --return-to <address>      where every leftover is swept at the end
  --i-funded-this            you funded the owner key printed by --dry-run

Options:
  --dry-run                  print the plan, amounts and costs; no network writes
                             (with --rpc it also reads balances and the config)
  --cloak-rpc <url>          RPC for the Cloak page; must allow browser requests
                             and serve history (default: --rpc)
  --zcash-sol <SOL>          Zcash tier, gross (default 0.05)
  --cloak-sol <SOL>          Cloak SOL tier, gross (default 0.035)
  --cloak-usdc <USDC>        make the Cloak tier USDC instead (>= 2 recommended)
  --vest-usdc <USDC>         vesting plan total (default 1; 0 skips step e)
  --paymaster <https url>    run step e through the Kora paymaster (fees in USDC)
  --zcash-fee-recipient <a>  NEAR account for the 1Click app fee (default none)
  --cu-price <micro-lamports> priority fee on this tool's own transfers (default 20000)
  --skip-zcash, --skip-cloak, --skip-vesting, --no-sweep
  --help''';

const _flags = {
  'dry-run',
  'i-funded-this',
  'skip-zcash',
  'skip-cloak',
  'skip-vesting',
  'no-sweep',
  'help',
};

const _usdcDecimals = 6;

/// Wallet derivation accounts for the phrase-derived keys (Cloak 1 and
/// Zcash 2 match SecureStore.claimAccounts).
const _accounts = (cloak: 1, zcash: 2, guard: 3, heir: 4);

/// Plan timings: short, near the program minimums.
const _tierAfterSecs = 120;
const _vestSecs = 60;
const _lockSecs = 3600;
const _skipGraceSecs = 3600;

/// Deposited with a USDC Cloak tier for the program's gas stipend: at most
/// 0.012 SOL (CLOAK_GAS_STIPEND; 0.003 in older builds, then this tool tops
/// the claim key up to the 0.01 SOL a Cloak SPL deposit needs) plus margin.
/// Whatever the program does not pay out returns to the owner on close.
const _cloakStipendMax = 13000000;
const _cloakSplReserve = CloakRoute.defaultSplFeeReserveLamports;

/// Account sizes used for the rent estimate.
const _vaultBytes = 1390;
const _tokenAccountBytes = 165;

Future<void> main(List<String> argv) async {
  final Map<String, String> args;
  try {
    args = _parse(argv);
  } on FormatException catch (e) {
    stderr.writeln('${e.message}\n\n$_usage');
    exit(64);
  }
  if (args.containsKey('help')) {
    stdout.writeln(_usage);
    exit(0);
  }
  final dryRun = args.containsKey('dry-run');
  final workdir = args['workdir'];
  if (workdir == null) _die('--workdir is required');
  final clusterName = args['cluster'] ?? (dryRun ? 'mainnet-beta' : null);
  final cluster = clusters[clusterName];
  if (cluster == null) {
    _die('--cluster mainnet-beta is required (devnet for a rehearsal)');
  }
  final mainnet = clusterName == 'mainnet-beta';
  final rpc = args['rpc'];
  if (!dryRun) {
    if (rpc == null) _die('--rpc is required');
    if (!args.containsKey('i-funded-this')) {
      _die(
        '--i-funded-this is required: run --dry-run first, fund the owner '
        'key it prints, then pass the flag',
      );
    }
    if (args['return-to'] == null && !args.containsKey('no-sweep')) {
      _die('--return-to is required (or --no-sweep)');
    }
  }

  final Plan plan;
  try {
    plan = Plan.fromArgs(args, mainnet: mainnet, usdcMint: cluster.usdcMint);
  } on FormatException catch (e) {
    _die(e.message);
  }
  final keys = await Keys.load(Directory(workdir));
  final state = E2eState.load(File('${keys.dir.path}/state.json'));
  stdout.writeln(
    'Deadman mainnet e2e ($clusterName), workdir ${keys.dir.path}',
  );
  keys.describe();

  if (dryRun) {
    await _dryRun(plan, keys, rpc, cluster.genesisHash);
    exit(0);
  }

  final run = E2e(
    plan: plan,
    keys: keys,
    state: state,
    rpc: rpc!,
    cluster: clusterName!,
    genesisHash: cluster.genesisHash,
    cuPrice: int.parse(args['cu-price'] ?? '20000'),
  );
  var ok = false;
  try {
    ok = await run.all();
  } on Object catch (e) {
    stderr.writeln(
      '\nStopped: $e\nFix the cause and run the same command '
      'again; finished steps are skipped (state.json).',
    );
  } finally {
    await run.close();
    run.summary();
  }
  exit(ok ? 0 : 1);
}

Never _die(String message) {
  stderr.writeln('$message\n\n$_usage');
  exit(64);
}

Map<String, String> _parse(List<String> argv) {
  final args = <String, String>{};
  for (var i = 0; i < argv.length; i++) {
    final a = argv[i];
    if (!a.startsWith('--')) throw FormatException('unexpected argument $a');
    final name = a.substring(2);
    if (_flags.contains(name)) {
      args[name] = 'true';
    } else if (i + 1 < argv.length) {
      args[name] = argv[++i];
    } else {
      throw FormatException('$a needs a value');
    }
  }
  return args;
}

/// Decimal string to base units, without floating point.
int units(String value, int decimals) {
  final m = RegExp(r'^(\d+)(?:\.(\d+))?$').firstMatch(value.trim());
  if (m == null) throw FormatException('not an amount: $value');
  final frac = m.group(2) ?? '';
  if (frac.length > decimals) {
    throw FormatException('$value has more than $decimals decimals');
  }
  return int.parse(m.group(1)!) * _pow10(decimals) +
      (frac.isEmpty ? 0 : int.parse(frac.padRight(decimals, '0')));
}

int _pow10(int n) => [for (var i = 0; i < n; i++) 10].fold(1, (a, b) => a * b);

String fmtSol(int lamports) => '${_fmt(lamports, 9)} SOL';
String fmtUsdc(int base) => '${_fmt(base, _usdcDecimals)} USDC';

String _fmt(int v, int decimals) {
  final neg = v < 0;
  final s = v.abs().toString().padLeft(decimals + 1, '0');
  final whole = s.substring(0, s.length - decimals);
  final frac = s
      .substring(s.length - decimals)
      .replaceFirst(RegExp(r'0+$'), '');
  return '${neg ? '-' : ''}${frac.isEmpty ? whole : '$whole.$frac'}';
}

/// What the run does, from the command line.
class Plan {
  Plan({
    required this.usdcMint,
    required this.zcashLamports,
    required this.cloakLamports,
    required this.cloakUsdc,
    required this.vestUsdc,
    required this.zcashU1,
    required this.cloakDest,
    required this.returnTo,
    required this.cloakRpc,
    required this.paymaster,
    required this.zcashFeeRecipient,
    required this.sweep,
  });

  factory Plan.fromArgs(
    Map<String, String> a, {
    required bool mainnet,
    required String usdcMint,
  }) {
    final zcash = mainnet && !a.containsKey('skip-zcash');
    final cloak = mainnet && !a.containsKey('skip-cloak');
    final cloakUsdc = cloak && a['cloak-usdc'] != null
        ? units(a['cloak-usdc']!, _usdcDecimals)
        : 0;
    final plan = Plan(
      usdcMint: usdcMint,
      zcashLamports: zcash ? units(a['zcash-sol'] ?? '0.05', 9) : 0,
      cloakLamports: cloak && cloakUsdc == 0
          ? units(a['cloak-sol'] ?? '0.035', 9)
          : 0,
      cloakUsdc: cloakUsdc,
      vestUsdc: a.containsKey('skip-vesting')
          ? 0
          : units(a['vest-usdc'] ?? '1', _usdcDecimals),
      zcashU1: a['zcash-u1'],
      cloakDest: a['cloak-dest'],
      returnTo: a['return-to'],
      cloakRpc: a['cloak-rpc'] ?? a['rpc'],
      paymaster: a['paymaster'],
      zcashFeeRecipient: a['zcash-fee-recipient'] ?? '',
      sweep: !a.containsKey('no-sweep'),
    );
    plan._validate(a.containsKey('dry-run'));
    return plan;
  }

  final String usdcMint;

  /// Gross tier amounts; 0 = tier not in the plan.
  final int zcashLamports;
  final int cloakLamports;
  final int cloakUsdc;
  final int vestUsdc;
  final String? zcashU1;
  final String? cloakDest;
  final String? returnTo;
  final String? cloakRpc;
  final String? paymaster;
  final String zcashFeeRecipient;
  final bool sweep;

  bool get zcash => zcashLamports > 0;
  bool get cloak => cloakLamports > 0 || cloakUsdc > 0;
  bool get inheritance => zcash || cloak;
  bool get vesting => vestUsdc > 0;

  void _validate(bool dryRun) {
    if (!inheritance && !vesting) {
      throw const FormatException('nothing to test: every step is skipped');
    }
    if (zcash) {
      final u1 = zcashU1;
      if (u1 == null && !dryRun) {
        throw const FormatException('--zcash-u1 is required (or --skip-zcash)');
      }
      if (u1 != null && !ZcashRoute.isUnifiedAddress(u1)) {
        throw const FormatException('--zcash-u1 is not a shielded u1 address');
      }
      final r = u1 == null ? null : ZcashRoute.decodeUnifiedAddress(u1);
      if (r != null && r.transparent) {
        throw const FormatException(
          '--zcash-u1 has a transparent receiver; use a shielded-only address',
        );
      }
      if (zcashLamports < 20000000) {
        throw const FormatException('--zcash-sol must be at least 0.02');
      }
    }
    if (cloak) {
      if (cloakDest == null && !dryRun) {
        throw const FormatException(
          '--cloak-dest is required (or --skip-cloak)',
        );
      }
      if (cloakDest != null && !_isPubkey(cloakDest!)) {
        throw const FormatException('--cloak-dest is not a Solana address');
      }
      final rpcHost = cloakRpc == null ? '' : Uri.parse(cloakRpc!).host;
      if (rpcHost == 'api.mainnet-beta.solana.com') {
        throw const FormatException(
          'the Cloak page cannot use api.mainnet-beta.solana.com (HTTP 403 '
          'to browsers); pass --cloak-rpc <Helius URL>',
        );
      }
      // Net of the 3% private-rail fee, the deposit minus Cloak's minimum
      // and reserve must still cover the exit fee.
      if (cloakUsdc > 0 && cloakUsdc < 1600000) {
        throw const FormatException('--cloak-usdc must be at least 1.6');
      }
      if (cloakLamports > 0 && cloakLamports < 25000000) {
        throw const FormatException('--cloak-sol must be at least 0.025');
      }
    }
    if (returnTo != null && !_isPubkey(returnTo!)) {
      throw const FormatException('--return-to is not a Solana address');
    }
    if (paymaster != null && !vesting) {
      throw const FormatException('--paymaster is only used by step e');
    }
  }

  /// Inheritance deposit: both gross tiers, plus the Cloak stipend for a
  /// USDC tier.
  int get depositLamports =>
      zcashLamports + cloakLamports + (cloakUsdc > 0 ? _cloakStipendMax : 0);
}

/// The workdir's keys. Secrets stay in files (mode 600); only public keys
/// are printed.
class Keys {
  Keys._(
    this.dir,
    this.owner,
    this.guard,
    this.claimZcash,
    this.claimCloak,
    this.heir,
  );

  final Directory dir;
  final Ed25519HDKeyPair owner;
  final Ed25519HDKeyPair guard;
  final Ed25519HDKeyPair claimZcash;
  final Ed25519HDKeyPair claimCloak;
  final Ed25519HDKeyPair heir;

  String get cloakSecretFile => '${dir.path}/cloak_claim.json';

  static Future<Keys> load(Directory dir) async {
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
      await _chmod(dir.path, '700');
    }
    final phraseFile = File('${dir.path}/phrase.txt');
    if (!phraseFile.existsSync()) {
      await _writeSecret(phraseFile, '${bip39.generateMnemonic()}\n');
    }
    final phrase = phraseFile.readAsStringSync().trim();
    if (!bip39.validateMnemonic(phrase)) {
      throw StateError('${phraseFile.path} is not a valid phrase');
    }
    final ownerFile = File('${dir.path}/owner.json');
    if (!ownerFile.existsSync()) {
      await _writeSecret(
        ownerFile,
        await _keypairJson(await Ed25519HDKeyPair.random()),
      );
    }
    final ownerBytes = (jsonDecode(ownerFile.readAsStringSync()) as List)
        .cast<int>();
    final owner = await Ed25519HDKeyPair.fromPrivateKeyBytes(
      privateKey: ownerBytes.sublist(0, 32),
    );
    Future<Ed25519HDKeyPair> derive(int account) =>
        Ed25519HDKeyPair.fromMnemonic(phrase, account: account, change: 0);
    final keys = Keys._(
      dir,
      owner,
      await derive(_accounts.guard),
      await derive(_accounts.zcash),
      await derive(_accounts.cloak),
      await derive(_accounts.heir),
    );
    final cloakFile = File(keys.cloakSecretFile);
    if (!cloakFile.existsSync()) {
      await _writeSecret(cloakFile, await _keypairJson(keys.claimCloak));
    }
    return keys;
  }

  List<(String, Ed25519HDKeyPair)> get all => [
    ('owner', owner),
    ('guard', guard),
    ('claim A (Zcash)', claimZcash),
    ('claim B (Cloak)', claimCloak),
    ('vesting heir', heir),
  ];

  void describe() {
    for (final (name, k) in all) {
      stdout.writeln('  ${name.padRight(16)} ${k.address}');
    }
    stdout.writeln(
      '  secrets: owner.json, phrase.txt, cloak_claim.json (mode 600)\n',
    );
  }

  /// Solana CLI keypair format: 32-byte private key + 32-byte public key.
  static Future<String> _keypairJson(Ed25519HDKeyPair k) async {
    final secret = await k.extract();
    final bytes = [...secret.bytes, ...k.publicKey.bytes];
    secret.destroy();
    return jsonEncode(bytes);
  }

  static Future<void> _writeSecret(File f, String contents) async {
    f.createSync();
    await _chmod(f.path, '600');
    f.writeAsStringSync(contents, flush: true);
  }

  static Future<void> _chmod(String path, String mode) async {
    if (Platform.isWindows) return;
    await Process.run('chmod', [mode, path]);
  }
}

/// state.json: step results, written atomically after every change.
class E2eState {
  E2eState._(this.file, this.data);

  factory E2eState.load(File file) => E2eState._(
    file,
    file.existsSync()
        ? jsonDecode(file.readAsStringSync()) as Map<String, dynamic>
        : {'version': 1, 'steps': <String, dynamic>{}, 'txs': <dynamic>[]},
  );

  final File file;
  final Map<String, dynamic> data;

  Map<String, dynamic> get steps => data['steps'] as Map<String, dynamic>;
  List<dynamic> get txs => data['txs'] as List<dynamic>;

  Map<String, dynamic> step(String name) =>
      (steps[name] ??= <String, dynamic>{}) as Map<String, dynamic>;

  bool done(String name) => step(name)['status'] == 'PASS';

  void set(String name, Map<String, Object?> fields) {
    step(name).addAll(fields);
    save();
  }

  void save() {
    final tmp = File('${file.path}.tmp');
    tmp.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(data));
    tmp.renameSync(file.path);
  }
}

/// A Cloak runtime backed by tool/cloak_bundle/live.mjs: the bundled SDK in
/// headless Chromium. The claim key secret goes from its file to the page;
/// it is stripped from the requests [CloakRoute] builds.
class NodeCloakRuntime implements CloakJsRuntime {
  NodeCloakRuntime._(this._process, this._lines);

  final Process _process;
  final StreamIterator<String> _lines;
  var _id = 0;

  static Future<NodeCloakRuntime> start({
    required String bundleDir,
    required String secretFile,
    required String expectAddress,
  }) async {
    final process = await Process.start('node', [
      'live.mjs',
      '--secret-file',
      secretFile,
    ], workingDirectory: bundleDir);
    process.stderr.transform(utf8.decoder).listen(stderr.write);
    final lines = StreamIterator(
      process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
    );
    if (!await lines.moveNext().timeout(const Duration(minutes: 2))) {
      throw StateError('live.mjs exited before it was ready');
    }
    final ready = jsonDecode(lines.current) as Map<String, dynamic>;
    if (ready['ready'] != true || ready['address'] != expectAddress) {
      process.kill();
      throw StateError('live.mjs is not running claim key B: $ready');
    }
    stdout.writeln('  Cloak runtime ${ready['version']} ready');
    return NodeCloakRuntime._(process, lines);
  }

  @override
  Future<String> run(String op, String payloadJson) async {
    final payload = jsonDecode(payloadJson) as Map<String, dynamic>
      ..remove('secret');
    final id = ++_id;
    _process.stdin.writeln(
      jsonEncode({'id': id, 'op': op, 'payload': jsonEncode(payload)}),
    );
    await _process.stdin.flush();
    // Proofs take seconds; a deposit plus send can take a few minutes.
    if (!await _lines.moveNext().timeout(const Duration(minutes: 10))) {
      throw const CloakRouteException('Cloak runtime exited');
    }
    final reply = jsonDecode(_lines.current) as Map<String, dynamic>;
    if (reply['id'] != id) {
      throw CloakRouteException('Cloak runtime answered ${reply['id']}');
    }
    return reply['reply'] as String;
  }

  Future<void> close() async {
    await _process.stdin.close();
    await _process.exitCode.timeout(
      const Duration(seconds: 20),
      onTimeout: () {
        _process.kill();
        return -1;
      },
    );
  }
}

class E2e {
  E2e({
    required this.plan,
    required this.keys,
    required this.state,
    required this.rpc,
    required this.cluster,
    required this.genesisHash,
    required this.cuPrice,
  }) : sol = SolanaClient(
         rpcUrl: Uri.parse(rpc),
         websocketUrl: Uri.parse(rpc.replaceFirst('http', 'ws')),
       ) {
    client = DeadmanClient.withKora(
      client: sol,
      paymaster: plan.paymaster == null
          ? null
          : KoraClient(Uri.parse(plan.paymaster!)),
    );
  }

  final Plan plan;
  final Keys keys;
  final E2eState state;
  final String rpc;
  final String cluster;
  final String genesisHash;
  final int cuPrice;
  final SolanaClient sol;
  late final DeadmanClient client;
  NodeCloakRuntime? _cloakRuntime;

  RpcClient get _rpc => sol.rpcClient;
  String get owner => keys.owner.address;

  String link(String sig) =>
      'https://solscan.io/tx/$sig${cluster == 'devnet' ? '?cluster=devnet' : ''}';

  Future<bool> all() async {
    // Always re-checked: a resumed run may point at another RPC.
    state.steps.remove('preflight');
    await _step('preflight', _preflight);
    if (plan.inheritance) {
      await _step('a_create_inheritance', _createInheritance);
      await _step('b_execute_tiers', _executeTiers);
      if (plan.zcash) await _step('c_route_zcash', _routeZcash);
      if (plan.cloak) await _step('d_route_cloak', _routeCloak);
    }
    if (plan.vesting) await _step('e_vesting', _vesting);
    if (plan.inheritance) {
      await _step('f_close_inheritance', _closeInheritance);
    }
    if (plan.sweep) await _step('f_sweep', _sweep);
    return state.steps.values.every(
      (s) => (s as Map)['status'] == 'PASS' || s['status'] == 'SKIP',
    );
  }

  Future<void> _step(String name, Future<String> Function() body) async {
    if (state.done(name)) {
      stdout.writeln('== $name: already done (${state.step(name)['detail']})');
      return;
    }
    stdout.writeln('== $name');
    state.set(name, {'status': 'RUNNING', 'startedAt': _iso()});
    try {
      final detail = await body();
      state.set(name, {'status': 'PASS', 'detail': detail, 'at': _iso()});
      stdout.writeln('   PASS: $detail');
    } on Object catch (e) {
      state.set(name, {'status': 'FAIL', 'detail': '$e', 'at': _iso()});
      stdout.writeln('   FAIL: $e');
      rethrow;
    }
  }

  void _tx(String step, String label, String sig) {
    state.txs.add({'step': step, 'label': label, 'sig': sig, 'at': _iso()});
    state.save();
    stdout.writeln('   $label: ${link(sig)}');
  }

  static String _iso() => DateTime.now().toUtc().toIso8601String();
  static int _now() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  // ---- preflight -------------------------------------------------------

  Future<String> _preflight() async {
    final genesis = await _rpc.getGenesisHash();
    if (genesis != genesisHash) {
      throw StateError('RPC genesis $genesis is not $cluster');
    }
    final program = await _account(AppConfig.programId);
    if (program == null || program.executable != true) {
      throw StateError('program ${AppConfig.programId} is not deployed here');
    }
    final config = await client.fetchConfig();
    final fees = config.fees;
    final ownerSol = await client.balance(owner);
    final ownerUsdc = await client.tokenBalance(owner, plan.usdcMint);
    final first =
        !state.steps.containsKey('a_create_inheritance') &&
        !state.steps.containsKey('e_vesting');
    // Starting funds, for the summary: until something was spent.
    if (first) state.data['start'] = {'sol': ownerSol, 'usdc': ownerUsdc};
    state.data['treasury'] = fees.treasury;
    state.save();
    final need = await Costs.compute(plan, _rentFor, paymaster: plan.paymaster);
    if (first && (ownerSol < need.ownerSol || ownerUsdc < need.ownerUsdc)) {
      throw StateError(
        'owner $owner holds ${fmtSol(ownerSol)} and ${fmtUsdc(ownerUsdc)}; '
        'needs ${fmtSol(need.ownerSol)} and ${fmtUsdc(need.ownerUsdc)}',
      );
    }
    if (plan.cloak && first) {
      final ping = await Process.run('node', [
        'live.mjs',
        '--ping',
      ], workingDirectory: _findBundle());
      if (ping.exitCode != 0) {
        throw StateError('Cloak runtime check failed: ${ping.stderr}');
      }
    }
    return 'cluster $cluster, config treasury ${fees.treasury} '
        '(${fees.feeBpsPublic}/${fees.feeBpsPrivate} bps), owner '
        '${fmtSol(ownerSol)} + ${fmtUsdc(ownerUsdc)}';
  }

  Future<int> _rentFor(int bytes) =>
      _rpc.getMinimumBalanceForRentExemption(bytes, commitment: _commitment);

  static const _commitment = Commitment.confirmed;

  Future<dynamic> _account(String address) async => (await _rpc.getAccountInfo(
    address,
    commitment: _commitment,
    encoding: Encoding.base64,
  )).value;

  // ---- a. inheritance plan --------------------------------------------

  List<RuleSpec> get _rules => [
    if (plan.zcash)
      RuleSpec(
        beneficiary: keys.claimZcash.address,
        rail: Rail.zcash,
        afterSecs: _tierAfterSecs,
        mode: AmountMode.fixed,
        amount: plan.zcashLamports,
      ),
    if (plan.cloak)
      RuleSpec(
        beneficiary: keys.claimCloak.address,
        rail: Rail.cloak,
        afterSecs: _tierAfterSecs,
        mode: AmountMode.fixed,
        amount: plan.cloakUsdc > 0 ? plan.cloakUsdc : plan.cloakLamports,
        mint: plan.cloakUsdc > 0 ? plan.usdcMint : null,
      ),
  ];

  int get _inheritanceId => state.data['inheritancePlanId'] as int;

  Future<String> _createInheritance() async {
    if (state.data['inheritancePlanId'] == null) {
      state.data['inheritancePlanId'] = await client.nextFreePlanId(owner);
      state.save();
    }
    final id = _inheritanceId;
    var vault = await client.fetchVault(owner, id);
    if (vault == null) {
      final tx = await client.buildCreateVault(
        owner: owner,
        planId: id,
        label: 'E2E inheritance',
        guard: keys.guard.address,
        lockSecs: _lockSecs,
        skipGraceSecs: _skipGraceSecs,
        rules: _rules,
        depositLamports: plan.depositLamports,
      );
      _tx('a', 'create_plan + deposit', await _sendWallet(tx));
      vault = (await client.fetchVault(owner, id))!;
    }
    if (plan.cloakUsdc > 0 &&
        await client.tokenBalance(vault.address, plan.usdcMint) <
            plan.cloakUsdc) {
      final tx = await client.buildDepositToken(
        owner: owner,
        planId: id,
        mint: plan.usdcMint,
        amount: plan.cloakUsdc,
      );
      _tx('a', 'deposit USDC', await _sendWallet(tx));
    }
    return 'plan $id vault ${vault.address}, ${vault.rules.length} tiers, '
        'holds ${fmtSol(vault.withdrawableLamports)}'
        '${plan.cloakUsdc > 0 ? ' + ${fmtUsdc(plan.cloakUsdc)}' : ''}';
  }

  // ---- b. execute tiers -----------------------------------------------

  Future<String> _executeTiers() async {
    final id = _inheritanceId;
    final keeper = Keeper(
      sol,
      client,
      keys.owner,
      prices: {plan.usdcMint: 6.0},
    );
    final out = <String>[];
    var vault = (await client.fetchVault(owner, id))!;
    for (var i = 0; i < vault.rules.length; i++) {
      vault = (await client.fetchVault(owner, id))!;
      final rule = vault.rules[i];
      if (rule.executed) {
        out.add('tier $i paid ${rule.paid}');
        continue;
      }
      // The chain clock may trail ours by a few seconds.
      final due = vault.ruleDueAt(i) + 10;
      final wait = due - _now();
      if (wait > 0) {
        stdout.writeln('   tier $i due in ${wait}s; waiting');
        await Future<void>.delayed(Duration(seconds: wait));
      }
      final fees = await client.fetchFees();
      final decision = await keeper.decide(vault, i, fees, _now());
      stdout.writeln('   keeper verdict for tier $i: $decision');
      final sig = await _retryNotDue(
        () => client.executeRuleWithKey(
          keys.owner,
          vaultOwner: owner,
          planId: id,
          index: i,
        ),
      );
      _tx('b', 'execute tier $i (${rule.rail.name})', sig);
      vault = (await client.fetchVault(owner, id))!;
      out.add('tier $i paid ${vault.rules[i].paid}');
    }
    if (plan.cloakUsdc > 0) await _topUpCloakClaim();
    return out.join(', ');
  }

  Future<String> _retryNotDue(Future<String> Function() send) async {
    for (var attempt = 1; ; attempt++) {
      try {
        return await send();
      } on DeadmanException catch (e) {
        if (e.name != 'RuleNotDue' || attempt >= 6) rethrow;
        await Future<void>.delayed(const Duration(seconds: 10));
      }
    }
  }

  /// A Cloak USDC deposit needs 0.01 SOL on the claim key; the program's
  /// stipend may be less (docs/research/private-rails-test-2026-10-04.md).
  Future<void> _topUpCloakClaim() async {
    final have = await client.balance(keys.claimCloak.address);
    final want = _cloakSplReserve + 100000;
    if (have >= want) return;
    stdout.writeln(
      '   claim B holds ${fmtSol(have)} after the stipend; topping up to '
      '${fmtSol(want)} (Cloak SPL deposit reserve)',
    );
    final sig = await _send(
      [
        SystemInstruction.transfer(
          fundingAccount: keys.owner.publicKey,
          recipientAccount: keys.claimCloak.publicKey,
          lamports: want - have,
        ),
      ],
      [keys.owner],
    );
    _tx('b', 'top up claim B', sig);
  }

  // ---- c. Zcash --------------------------------------------------------

  Future<String> _routeZcash() async {
    final route = ZcashRoute(
      cluster: 'mainnet-beta',
      rpcUrl: rpc,
      apiKey: Platform.environment['ONECLICK_JWT'] ?? '',
      appFeeRecipient: plan.zcashFeeRecipient,
    );
    final s = state.step('c_route_zcash');
    final claim = keys.claimZcash;
    var deposit = s['depositAddress'] as String?;
    if (deposit != null && s['sent'] != true) {
      // Interrupted between saving the quote and confirming the send: the
      // send spends the whole balance, so a full balance means nothing left.
      final at = DateTime.parse(s['quotedAt'] as String);
      final settle = at
          .add(const Duration(seconds: 90))
          .difference(DateTime.now());
      if (settle > Duration.zero) await Future<void>.delayed(settle);
      final left = await route.spendable(
        claimKey: claim.address,
        inputMint: null,
      );
      if (left >= (s['amountIn'] as int)) {
        stdout.writeln('   earlier quote was never sent; quoting again');
        deposit = null;
      } else {
        state.set('c_route_zcash', {'sent': true});
      }
    }
    if (deposit == null) {
      final amount = await route.spendable(
        claimKey: claim.address,
        inputMint: null,
      );
      if (amount <= 0) throw StateError('claim key A holds no SOL to route');
      final q = await route.quote(
        claimKey: claim.address,
        inputMint: null,
        amount: amount,
        destination: plan.zcashU1!,
      );
      deposit = q.depositAddress!;
      state.set('c_route_zcash', {
        'depositAddress': deposit,
        'amountIn': q.amountIn,
        'estimatedOut': q.estimatedOut,
        'quotedAt': _iso(),
        'sent': false,
      });
      stdout.writeln(
        '   quote: ${fmtSol(q.amountIn)} -> ${q.estimatedOut}, deposit $deposit',
      );
      try {
        await route.execute(claimKey: claim, quote: q);
      } on ZcashRouteException {
        // Raised before anything was sent.
        state.step('c_route_zcash').remove('depositAddress');
        state.save();
        rethrow;
      }
      state.set('c_route_zcash', {'sent': true});
    }
    stdout.writeln('   tracking 1Click deposit $deposit');
    var last = '';
    await for (final status
        in route
            .track(deposit, maxEvery: const Duration(seconds: 30))
            .timeout(const Duration(minutes: 45))) {
      last = status;
      state.set('c_route_zcash', {'oneClickStatus': status});
      stdout.writeln('   ${_iso()} $status');
    }
    if (last != 'SUCCESS') {
      throw StateError('1Click ended with $last (deposit $deposit)');
    }
    return '${fmtSol(s['amountIn'] as int)} -> ${s['estimatedOut']}, '
        '1Click SUCCESS (deposit $deposit)';
  }

  // ---- d. Cloak --------------------------------------------------------

  Future<String> _routeCloak() async {
    final s = state.step('d_route_cloak');
    final claim = keys.claimCloak;
    final mint = plan.cloakUsdc > 0 ? plan.usdcMint : null;
    final dest = plan.cloakDest!;
    Future<int> destBalance() =>
        mint == null ? client.balance(dest) : client.tokenBalance(dest, mint);
    s['destBefore'] ??= await destBalance();
    state.save();

    var sig = s['sendSignature'] as String?;
    if (sig == null) {
      final runtime = _cloakRuntime ??= await NodeCloakRuntime.start(
        bundleDir: _findBundle(),
        secretFile: keys.cloakSecretFile,
        expectAddress: claim.address,
      );
      final route = CloakRoute(
        runtime: runtime,
        cluster: 'mainnet-beta',
        rpcUrl: plan.cloakRpc,
      );
      final reserve = route.solFeeReserveLamports;
      // Resume with the amount of the interrupted run, so the bundle finds
      // the note it already deposited instead of depositing again.
      final saved = s['amountIn'] as int?;
      final amount = saved != null
          ? (mint == null ? saved + reserve : saved)
          : (mint == null
                ? await client.balance(claim.address)
                : await client.tokenBalance(claim.address, mint));
      final q = await route.quote(
        claimKey: claim.address,
        inputMint: mint,
        amount: amount,
        destination: dest,
      );
      state.set('d_route_cloak', {
        'amountIn': q.amountIn,
        'estimatedOut': q.estimatedOut,
        'cloakStatus': 'SENDING',
      });
      stdout.writeln(
        '   ${saved != null ? 'resuming' : 'routing'} '
        '${mint == null ? fmtSol(q.amountIn) : fmtUsdc(q.amountIn)} -> '
        '${q.estimatedOut} to $dest (deposit, proof, private send)',
      );
      try {
        sig = await route.execute(claimKey: claim, quote: q);
      } on CloakRouteException {
        state.set('d_route_cloak', {'cloakStatus': 'INTERRUPTED'});
        rethrow;
      }
      state.set('d_route_cloak', {'sendSignature': sig, 'cloakStatus': 'SENT'});
      if (sig != CloakRoute.alreadySent) _tx('d', 'Cloak private send', sig);
    }
    final route = CloakRoute(cluster: 'mainnet-beta', rpcUrl: plan.cloakRpc);
    var status = 'PENDING';
    final deadline = DateTime.now().add(const Duration(minutes: 5));
    while (status == 'PENDING' && DateTime.now().isBefore(deadline)) {
      status = await route.status(sig);
      if (status == 'PENDING') {
        await Future<void>.delayed(const Duration(seconds: 5));
      }
    }
    state.set('d_route_cloak', {'cloakStatus': status});
    if (status != 'SUCCESS') throw StateError('Cloak send $sig is $status');
    // The relay lands the withdrawal; give the destination a moment.
    var delta = 0;
    for (var i = 0; i < 12 && delta <= 0; i++) {
      delta = await destBalance() - (s['destBefore'] as int);
      if (delta <= 0) await Future<void>.delayed(const Duration(seconds: 5));
    }
    state.set('d_route_cloak', {'destReceived': delta});
    final fmt = mint == null ? fmtSol : fmtUsdc;
    return '${fmt(s['amountIn'] as int)} shielded, ${fmt(delta)} arrived at '
        '$dest (quoted ${s['estimatedOut']})';
  }

  // ---- e. vesting ------------------------------------------------------

  Future<String> _vesting() async {
    final s = state.step('e_vesting');
    if (s['planId'] == null) {
      s['planId'] = await client.nextFreePlanId(owner);
      state.save();
    }
    final id = s['planId'] as int;
    final mint = plan.usdcMint;
    final heir = keys.heir.address;
    final viaKora = plan.paymaster != null;
    client.feeToken = viaKora ? mint : null;
    try {
      var vault = await client.fetchVault(owner, id);
      // `created` without a vault means it was closed after the last save.
      if (vault == null && s['created'] != true) {
        final tx = await client.buildCreateVesting(
          owner: owner,
          planId: id,
          label: 'E2E vesting',
          guard: keys.guard.address,
          lockSecs: _lockSecs,
          startAt: _now() - 5,
          revocable: true,
          schedules: [
            VestingSpec(
              beneficiary: heir,
              rail: Rail.solana,
              mint: mint,
              total: plan.vestUsdc,
              cliffSecs: 0,
              durationSecs: _vestSecs,
            ),
          ],
          tokenDeposits: {mint: plan.vestUsdc},
        );
        final sig = await _sendWallet(tx);
        state.set('e_vesting', {'created': true});
        _tx('e', 'create_vesting${viaKora ? ' (Kora)' : ''}', sig);
        vault = (await client.fetchVault(owner, id))!;
      }
      if (vault != null && !vault.rules[0].executed) {
        final wait = vault.startAt + _vestSecs + 10 - _now();
        if (wait > 0) {
          stdout.writeln('   fully vested in ${wait}s; waiting');
          await Future<void>.delayed(Duration(seconds: wait));
        }
        final sig = viaKora
            ? await _sendWallet(
                await client.buildReleaseVested(
                  executor: owner,
                  vaultOwner: owner,
                  planId: id,
                  index: 0,
                ),
              )
            : await client.releaseVestedWithKey(
                keys.owner,
                vaultOwner: owner,
                planId: id,
                index: 0,
              );
        _tx('e', 'release_vested_token', sig);
        vault = (await client.fetchVault(owner, id))!;
      }
      final got = await client.tokenBalance(heir, mint);
      final fees = await client.fetchFees();
      final expected =
          plan.vestUsdc - plan.vestUsdc * fees.feeBpsPublic ~/ 10000;
      if (got < expected - 1 && vault != null) {
        throw StateError(
          'heir holds ${fmtUsdc(got)}, expected ${fmtUsdc(expected)}',
        );
      }
      s['heirReceived'] ??= got;
      if (vault != null) {
        final tx = await client.buildCloseVault(owner: owner, planId: id);
        _tx('e', 'close vesting plan', await _sendWallet(tx));
      }
      state.set('e_vesting', {'closed': true});
      return 'plan $id: heir received ${fmtUsdc(s['heirReceived'] as int)} of '
          '${fmtUsdc(plan.vestUsdc)} (fee ${fees.feeBpsPublic} bps), plan closed';
    } finally {
      client.feeToken = null;
    }
  }

  // ---- f. close and sweep ---------------------------------------------

  Future<String> _closeInheritance() async {
    final id = _inheritanceId;
    final vault = await client.fetchVault(owner, id);
    if (vault == null) return 'plan $id already closed';
    final tx = await client.buildCloseVault(owner: owner, planId: id);
    _tx('f', 'close inheritance plan', await _sendWallet(tx));
    return 'plan $id closed; rent and leftover back to the owner';
  }

  Future<String> _sweep() async {
    final to = plan.returnTo!;
    final toKey = Ed25519HDPublicKey.fromBase58(to);
    final mint = Ed25519HDPublicKey.fromBase58(plan.usdcMint);
    final toAta = Ed25519HDPublicKey.fromBase58(ataAddress(to, plan.usdcMint));
    void swept(int lamports, int usdcUnits) {
      final total = (state.data['swept'] ??= {'sol': 0, 'usdc': 0}) as Map;
      total['sol'] = (total['sol'] as int) + lamports;
      total['usdc'] = (total['usdc'] as int) + usdcUnits;
      state.save();
    }

    /// Moves [k]'s USDC to [to] and closes its token account (rent to [to]).
    Future<(List<Instruction>, int)> tokenIxs(Ed25519HDKeyPair k) async {
      final ata = ataAddress(k.address, plan.usdcMint);
      final account = await _account(ata);
      if (account == null) return (<Instruction>[], 0);
      final data = account.data;
      final amount = data is BinaryAccountData
          ? decodeTokenAmount(data.data)
          : 0;
      final ataKey = Ed25519HDPublicKey.fromBase58(ata);
      return (
        <Instruction>[
          if (amount > 0) ...[
            AssociatedTokenAccountInstruction.createAccountIdempotent(
              funder: keys.owner.publicKey,
              address: toAta,
              owner: toKey,
              mint: mint,
            ),
            TokenInstruction.transferChecked(
              amount: amount,
              decimals: _usdcDecimals,
              source: ataKey,
              mint: mint,
              destination: toAta,
              owner: k.publicKey,
            ),
          ],
          TokenInstruction.closeAccount(
            accountToClose: ataKey,
            destination: toKey,
            owner: k.publicKey,
          ),
        ],
        amount,
      );
    }

    // Every other key first, the owner paying their fees.
    for (final (name, k) in keys.all) {
      if (identical(k, keys.owner)) continue;
      final (ixs, amount) = await tokenIxs(k);
      final lamports = await client.balance(k.address);
      if (lamports > 0) {
        ixs.add(
          SystemInstruction.transfer(
            fundingAccount: k.publicKey,
            recipientAccount: toKey,
            lamports: lamports,
          ),
        );
      }
      if (ixs.isEmpty) continue;
      _tx('f', 'sweep $name', await _send(ixs, [keys.owner, k]));
      swept(lamports, amount);
    }
    final (ownerTokens, ownerUsdc) = await tokenIxs(keys.owner);
    if (ownerTokens.isNotEmpty) {
      _tx('f', 'sweep owner USDC', await _send(ownerTokens, [keys.owner]));
      swept(0, ownerUsdc);
    }
    // Last, without a priority fee, so the fee is exactly one signature.
    final left = await client.balance(owner) - 5000;
    if (left > 0) {
      final sig = await _send(
        [
          SystemInstruction.transfer(
            fundingAccount: keys.owner.publicKey,
            recipientAccount: toKey,
            lamports: left,
          ),
        ],
        [keys.owner],
        priority: false,
      );
      _tx('f', 'sweep owner SOL', sig);
      swept(left, 0);
    }
    final total = state.data['swept'] as Map? ?? const {'sol': 0, 'usdc': 0};
    return 'swept ${fmtSol(total['sol'] as int)} + '
        '${fmtUsdc(total['usdc'] as int)} (plus token-account rent) to $to';
  }

  // ---- sending ---------------------------------------------------------

  /// Signs a `build*` transaction as the owner's wallet would and sends it
  /// (through the paymaster when it built it).
  Future<String> _sendWallet(Uint8List tx) async {
    final [sig] = await client.sendSigned([await _sign(tx, keys.owner)]);
    return sig;
  }

  /// This tool's own transfers: [signers].first pays, with a priority fee.
  Future<String> _send(
    List<Instruction> ixs,
    List<Ed25519HDKeyPair> signers, {
    bool priority = true,
  }) async {
    final bh = (await _rpc.getLatestBlockhash(commitment: _commitment)).value;
    final tx = await signTransaction(
      bh,
      Message(
        instructions: [
          if (priority && cuPrice > 0) ...[
            ComputeBudgetInstruction.setComputeUnitLimit(units: 60000),
            ComputeBudgetInstruction.setComputeUnitPrice(
              microLamports: cuPrice,
            ),
          ],
          ...ixs,
        ],
      ),
      signers,
    );
    final sig = await _rpc.sendTransaction(
      tx.encode(),
      preflightCommitment: _commitment,
    );
    final deadline = DateTime.now().add(const Duration(seconds: 90));
    while (DateTime.now().isBefore(deadline)) {
      final [status] = (await _rpc.getSignatureStatuses([
        sig,
      ], searchTransactionHistory: true)).value;
      if (status != null) {
        if (status.err != null) throw StateError('$sig failed: ${status.err}');
        if (status.confirmationStatus != Commitment.processed) return sig;
      }
      await Future<void>.delayed(const Duration(seconds: 2));
    }
    throw StateError('$sig not confirmed in 90 s; check ${link(sig)}');
  }

  Future<void> close() async => _cloakRuntime?.close();

  // ---- summary ---------------------------------------------------------

  void summary() {
    stdout.writeln('\n${'=' * 78}\nSummary ($cluster)');
    for (final MapEntry(:key, :value) in state.steps.entries) {
      final s = value as Map;
      stdout.writeln(
        '${'${s['status']}'.padRight(7)} ${key.padRight(20)} ${s['detail'] ?? ''}',
      );
    }
    final zcash = state.steps['c_route_zcash'] as Map?;
    if (zcash?['depositAddress'] != null) {
      stdout.writeln(
        '\n1Click deposit ${zcash!['depositAddress']}: '
        '${zcash['oneClickStatus'] ?? 'not tracked yet'}\n'
        '  ${ZcashRoute.baseUrl}/v0/status?depositAddress='
        '${zcash['depositAddress']}',
      );
    }
    if (state.txs.isNotEmpty) {
      stdout.writeln('\nTransactions');
      for (final t in state.txs) {
        final m = t as Map;
        stdout.writeln(
          '  ${'${m['step']}'.padRight(2)} ${'${m['label']}'.padRight(28)} '
          '${link(m['sig'] as String)}',
        );
      }
    }
    final start = state.data['start'] as Map?;
    final swept = state.data['swept'] as Map?;
    if (start != null && swept != null) {
      final zcashIn = zcash?['sent'] == true ? zcash!['amountIn'] as int : 0;
      final cloak = state.steps['d_route_cloak'] as Map?;
      final cloakSol = plan.cloakUsdc == 0
          ? (cloak?['destReceived'] as int? ?? 0)
          : 0;
      final cloakUsdc = plan.cloakUsdc > 0
          ? (cloak?['destReceived'] as int? ?? 0)
          : 0;
      final costSol =
          (start['sol'] as int) - (swept['sol'] as int) - zcashIn - cloakSol;
      final costUsdc =
          (start['usdc'] as int) - (swept['usdc'] as int) - cloakUsdc;
      stdout.writeln(
        '\nFunds: started ${fmtSol(start['sol'] as int)} + '
        '${fmtUsdc(start['usdc'] as int)}; swept back ${fmtSol(swept['sol'] as int)}'
        ' + ${fmtUsdc(swept['usdc'] as int)}; delivered ${fmtSol(zcashIn)} into '
        '1Click and ${fmtSol(cloakSol)} + ${fmtUsdc(cloakUsdc)} via Cloak.\n'
        'Spent: ${fmtSol(costSol)} + ${fmtUsdc(costUsdc)} (protocol fees to the '
        'treasury ${state.data['treasury']}, Cloak fees, network fees, '
        'vault token-account rent, and token-account rent swept as SOL).',
      );
    }
  }
}

// Expected Config rates (bps) for the cost estimate; preflight prints the
// live ones from the Config PDA.
const _publicFeeBps = 200;
const _privateFeeBps = 300;

/// Funding the owner needs and what the run is expected to spend.
class Costs {
  Costs(this.ownerSol, this.ownerUsdc, this.lines);

  final int ownerSol;
  final int ownerUsdc;

  /// (item, amount, note).
  final List<(String, String, String)> lines;

  static Future<Costs> compute(
    Plan plan,
    Future<int> Function(int bytes) rent, {
    String? paymaster,
  }) async {
    final vaultRent = await rent(_vaultBytes);
    final ataRent = await rent(_tokenAccountBytes);
    final lines = <(String, String, String)>[];
    var needSol = 0;
    var needUsdc = 0;
    // Each owner-paid tx ~ 5000 lamports + this tool's priority fee.
    var txs = 0;
    if (plan.inheritance) {
      needSol += vaultRent + plan.depositLamports + 10000000;
      txs += 4;
      lines.add((
        'inheritance vault rent',
        fmtSol(vaultRent),
        'refunded on close',
      ));
      lines.add(('guard funding', fmtSol(10000000), 'swept back'));
      if (plan.zcash) {
        final fee = plan.zcashLamports * _privateFeeBps ~/ 10000;
        lines.add((
          'Zcash tier ${fmtSol(plan.zcashLamports)}',
          fmtSol(fee),
          'protocol fee 3% to the treasury',
        ));
        lines.add((
          '1Click swap',
          '~${fmtSol(plan.zcashLamports * 4 ~/ 100)}',
          '~4% spread (2026-10-04 quotes), output is ZEC to --zcash-u1',
        ));
      }
      if (plan.cloakLamports > 0) {
        final net =
            plan.cloakLamports - plan.cloakLamports * _privateFeeBps ~/ 10000;
        final shielded = net - 5000000;
        lines.add((
          'Cloak tier ${fmtSol(plan.cloakLamports)}',
          fmtSol(plan.cloakLamports - net),
          'protocol fee 3% to the treasury',
        ));
        lines.add((
          'Cloak exit fee',
          fmtSol(5000000 + shielded * 3 ~/ 1000),
          '0.005 SOL + 0.3%; ~${fmtSol(5000000)} reserve on claim B is swept back',
        ));
      }
      if (plan.cloakUsdc > 0) {
        final net = plan.cloakUsdc - plan.cloakUsdc * _privateFeeBps ~/ 10000;
        needUsdc += plan.cloakUsdc;
        needSol += 3 * ataRent + _cloakSplReserve;
        txs += 2;
        lines.add((
          'Cloak tier ${fmtUsdc(plan.cloakUsdc)}',
          fmtUsdc(plan.cloakUsdc - net),
          'protocol fee 3% to the treasury',
        ));
        lines.add((
          'Cloak exit fee',
          fmtUsdc(450000 + net * 3 ~/ 1000),
          '0.45 USDC + 0.3%',
        ));
        lines.add((
          'Cloak SPL deposit',
          '<= ${fmtSol(5600000)}',
          'may create a lookup table on claim B (rent not swept)',
        ));
        lines.add((
          'vault USDC account',
          fmtSol(ataRent),
          'not refunded: close_vault leaves token accounts',
        ));
      }
    }
    if (plan.vesting) {
      needUsdc += plan.vestUsdc;
      needSol += vaultRent + 3 * ataRent;
      txs += 3;
      lines.add((
        'vesting ${fmtUsdc(plan.vestUsdc)}',
        fmtUsdc(plan.vestUsdc * _publicFeeBps ~/ 10000),
        'protocol fee 2% to the treasury',
      ));
      lines.add((
        'vesting vault USDC account',
        fmtSol(ataRent),
        'not refunded: close_vault leaves token accounts',
      ));
      lines.add((
        'treasury USDC account',
        '<= ${fmtSol(ataRent)}',
        'only if missing; stays with the treasury',
      ));
      if (paymaster != null) {
        needUsdc += 4100000;
        lines.add((
          'Kora paymaster tiers',
          fmtUsdc(4020000),
          'plan 3 + account 1 + basic 0.02 USDC',
        ));
      }
    }
    if (plan.sweep) {
      needSol += ataRent;
      txs += 6;
    }
    final fees = txs * 20000;
    needSol += fees + 5000000;
    lines.add(('network fees', '~${fmtSol(fees)}', '$txs transactions'));
    return Costs(needSol, needUsdc, lines);
  }

  void print() {
    final w = lines.map((l) => l.$1.length).fold(0, (a, b) => a > b ? a : b);
    for (final (item, amount, note) in lines) {
      stdout.writeln('  ${item.padRight(w)}  ${amount.padRight(16)} $note');
    }
    stdout.writeln(
      '\n  Fund the owner with at least ${fmtSol(ownerSol)}'
      '${ownerUsdc > 0 ? ' and ${fmtUsdc(ownerUsdc)}' : ''} '
      '(includes a 0.005 SOL margin; everything not spent is swept back).',
    );
  }
}

Future<void> _dryRun(
  Plan plan,
  Keys keys,
  String? rpc,
  String genesisHash,
) async {
  stdout.writeln('DRY RUN: nothing is signed or sent.\n\nPlan');
  var n = 0;
  void line(String s) => stdout.writeln('  ${++n}. $s');
  if (plan.inheritance) {
    line(
      'create inheritance plan: tiers due ${_tierAfterSecs}s after the last '
      'check-in; deposit ${fmtSol(plan.depositLamports)}'
      '${plan.cloakUsdc > 0 ? ' + ${fmtUsdc(plan.cloakUsdc)}' : ''}',
    );
    if (plan.zcash) {
      stdout.writeln(
        '       tier: ${fmtSol(plan.zcashLamports)} -> claim A '
        '${keys.claimZcash.address} (Zcash rail)',
      );
    }
    if (plan.cloak) {
      stdout.writeln(
        '       tier: ${plan.cloakUsdc > 0 ? fmtUsdc(plan.cloakUsdc) : fmtSol(plan.cloakLamports)}'
        ' -> claim B ${keys.claimCloak.address} (Cloak rail)',
      );
    }
    line('wait until due, execute the tiers with the owner key (keeper logic)');
    if (plan.zcash) {
      line(
        'route claim A via 1Click: SOL -> ZEC to '
        '${plan.zcashU1 ?? '<--zcash-u1>'}, track to SUCCESS',
      );
    }
    if (plan.cloak) {
      line(
        'route claim B via Cloak (headless Chromium): deposit, proof, private '
        'send to ${plan.cloakDest ?? '<--cloak-dest>'}',
      );
    }
  }
  if (plan.vesting) {
    line(
      'USDC vesting: ${fmtUsdc(plan.vestUsdc)} over ${_vestSecs}s to heir '
      '${keys.heir.address}, release once, close'
      '${plan.paymaster != null ? ' (fees in USDC via ${plan.paymaster})' : ''}',
    );
  }
  if (plan.inheritance) line('close the inheritance plan');
  if (plan.sweep) {
    line('sweep every workdir key to ${plan.returnTo ?? '<--return-to>'}');
  }

  // Rent from the RPC when given, else the 2026-10 mainnet rate.
  Future<int> offlineRent(int bytes) async => (bytes + 128) * 5080;
  SolanaClient? client;
  if (rpc != null) {
    client = SolanaClient(
      rpcUrl: Uri.parse(rpc),
      websocketUrl: Uri.parse(rpc.replaceFirst('http', 'ws')),
    );
  }
  final rpcClient = client?.rpcClient;
  final costs = await Costs.compute(
    plan,
    rpcClient == null
        ? offlineRent
        : (b) => rpcClient.getMinimumBalanceForRentExemption(b),
    paymaster: plan.paymaster,
  );
  stdout.writeln(
    '\nEstimated costs (rent ${rpcClient == null ? 'at 5080 lamports/byte, offline' : 'from the RPC'})',
  );
  costs.print();

  stdout.writeln('\nRead-only checks');
  void check(bool ok, String what) =>
      stdout.writeln('  ${ok ? 'OK  ' : 'WARN'} $what');
  if (rpcClient == null) {
    stdout.writeln('  (pass --rpc to check the cluster, program and balances)');
  } else {
    try {
      final genesis = await rpcClient.getGenesisHash();
      check(genesis == genesisHash, 'RPC genesis hash $genesis');
      final program = (await rpcClient.getAccountInfo(
        AppConfig.programId,
        encoding: Encoding.base64,
      )).value;
      check(
        program?.executable == true,
        'program ${AppConfig.programId} '
        '${program?.executable == true ? 'deployed' : 'NOT deployed yet'}',
      );
      final deadman = DeadmanClient.withKora(client: client);
      try {
        final fees = await deadman.fetchFees();
        check(
          true,
          'config: treasury ${fees.treasury}, ${fees.feeBpsPublic}/'
          '${fees.feeBpsPrivate} bps',
        );
      } on Object {
        check(false, 'config PDA ${configPda().address} not initialized');
      }
      final have = await deadman.balance(keys.owner.address);
      final haveUsdc = await deadman.tokenBalance(
        keys.owner.address,
        plan.usdcMint,
      );
      check(
        have >= costs.ownerSol && haveUsdc >= costs.ownerUsdc,
        'owner holds ${fmtSol(have)} + ${fmtUsdc(haveUsdc)}',
      );
    } on Object catch (e) {
      check(false, 'RPC read failed: $e');
    }
    if (plan.zcash && plan.zcashU1 != null) {
      try {
        final q =
            await ZcashRoute(
              cluster: 'mainnet-beta',
              rpcUrl: rpc,
              apiKey: Platform.environment['ONECLICK_JWT'] ?? '',
            ).estimate(
              claimKey: keys.claimZcash.address,
              inputMint: null,
              amount:
                  plan.zcashLamports -
                  plan.zcashLamports * _privateFeeBps ~/ 10000,
              destination: plan.zcashU1!,
            );
        check(
          true,
          '1Click dry quote: ${fmtSol(q.amountIn)} -> ${q.estimatedOut}',
        );
      } on Object catch (e) {
        check(false, '1Click dry quote failed: $e');
      }
    }
  }
  if (plan.cloak) {
    try {
      final dir = _findBundle();
      final ping = await Process.run('node', [
        'live.mjs',
        '--ping',
      ], workingDirectory: dir);
      check(
        ping.exitCode == 0,
        'Cloak runtime (headless Chromium): ${'${ping.stdout}'.trim()}'
        '${ping.exitCode == 0 ? '' : ' ${ping.stderr}'}',
      );
    } on Object catch (e) {
      check(false, 'Cloak runtime: $e');
    }
  }
  stdout.writeln(
    '\nNext: fund owner ${keys.owner.address}, then run again without '
    '--dry-run and with --i-funded-this.',
  );
}

String _findBundle() {
  for (var d = Directory.current; ; d = d.parent) {
    final dir = '${d.path}/tool/cloak_bundle';
    if (File('$dir/live.mjs').existsSync()) return dir;
    if (d.parent.path == d.path) {
      throw StateError('run from the repository (tool/cloak_bundle not found)');
    }
  }
}

bool _isPubkey(String s) {
  try {
    return Ed25519HDPublicKey.fromBase58(s).bytes.length == 32;
  } on Object {
    return false;
  }
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
  final me = signer.publicKey.bytes;
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
