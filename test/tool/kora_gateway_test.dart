import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:deadman/core/config.dart';
import 'package:deadman/solana/codec.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:solana/encoder.dart';
import 'package:solana/solana.dart';

import '../../tool/kora_gateway.dart';
import '../solana/helpers.dart';

final kora = key(1);
final owner = key(2);
final guardian = key(3);
final blockhash = key(9);
const policyFor = SponsorPolicy.new;

Future<Ed25519HDKeyPair> keypair(int seed) =>
    Ed25519HDKeyPair.fromPrivateKeyBytes(privateKey: List.filled(32, seed));

Instruction ix(String signer, int planId, List<int> disc) => deadmanIx([
  AccountMeta.readonly(
    pubKey: Ed25519HDPublicKey.fromBase58(signer),
    isSigner: true,
  ),
  AccountMeta.writeable(
    pubKey: Ed25519HDPublicKey.fromBase58(vaultPda(owner, planId).address),
    isSigner: false,
  ),
], disc);

/// Wire transaction with [payer] as fee payer, signed by [signers] (the
/// payer's slot stays zeroed, as when it reaches Kora).
Future<Uint8List> wire(
  List<Instruction> ixs, {
  String? payer,
  List<Ed25519HDKeyPair> signers = const [],
  bool v0 = false,
}) async {
  final message = Message(instructions: ixs);
  final feePayer = Ed25519HDPublicKey.fromBase58(payer ?? kora);
  final compiled = v0
      ? message.compileV0(recentBlockhash: blockhash, feePayer: feePayer)
      : message.compile(recentBlockhash: blockhash, feePayer: feePayer);
  final bytes = compiled.toByteArray().toList();
  final sigs = <Signature>[];
  for (final k in compiled.accountKeys.take(compiled.requiredSignatureCount)) {
    final s = signers.where((s) => s.publicKey == k);
    sigs.add(
      s.isEmpty
          ? Signature(List.filled(64, 0), publicKey: k)
          : await s.first.sign(bytes),
    );
  }
  return Uint8List.fromList(
    SignedTx(
      compiledMessage: compiled,
      signatures: sigs,
    ).toByteArray().toList(),
  );
}

VaultAccount vaultAccount({
  required String guard,
  String? guardian,
  String programOwner = AppConfig.programId,
}) => (
  owner: programOwner,
  data: Uint8List.fromList(
    vaultBytes(owner: owner, guard: guard, guardian: guardian),
  ),
);

Matcher rejects(Pattern message) => throwsA(
  isA<GatewayRejection>().having(
    (e) => e.message,
    'message',
    contains(message),
  ),
);

void main() {
  final policy = policyFor(koraPayer: kora);
  late Ed25519HDKeyPair guard;

  setUpAll(() async => guard = await keypair(7));

  test('pulse and lockdown discriminators match the IDL', () {
    final disc = {
      for (final i in loadIdl()['instructions'] as List)
        (i as Map)['name']: (i['discriminator'] as List).cast<int>(),
    };
    expect(Disc.pulse, disc['pulse']);
    expect(Disc.lockdown, disc['lockdown']);
    expect(Disc.vaultAccount, [211, 8, 232, 43, 2, 152, 117, 119]);
  });

  group('validateSponsorTx', () {
    test('accepts a guard-signed pulse', () async {
      final tx = await wire(
        [ix(guard.address, 0, Disc.pulse)],
        signers: [guard],
      );
      final r = validateSponsorTx(tx, policy);
      expect(r.signer, guard.address);
      expect(r.vaults, [vaultPda(owner, 0).address]);
      expect(r.feeLamports, 10000);
      expect(await verifyGuardSignature(r), isTrue);
      checkVaultAccounts(r, [vaultAccount(guard: guard.address)], policy);
    });

    test(
      'accepts a v0 lockdown on several plans with a small priority fee',
      () async {
        final tx = await wire(
          [
            ComputeBudgetInstruction.setComputeUnitLimit(units: 20000),
            ComputeBudgetInstruction.setComputeUnitPrice(
              microLamports: 2000000,
            ),
            for (var p = 0; p < 8; p++) ix(guard.address, p, Disc.lockdown),
          ],
          signers: [guard],
          v0: true,
        );
        final r = validateSponsorTx(tx, policy);
        expect(r.vaults, hasLength(8));
        expect(r.feeLamports, 10000 + 40000);
        expect(await verifyGuardSignature(r), isTrue);
      },
    );

    test('rejects a ComputeBudget-only transaction', () async {
      final tx = await wire([
        ComputeBudgetInstruction.setComputeUnitLimit(units: 1000),
      ]);
      expect(() => validateSponsorTx(tx, policy), rejects('2 signatures'));
    });

    test('rejects a transaction signed only by Kora', () async {
      final tx = await wire([ix(kora, 0, Disc.pulse)]);
      expect(() => validateSponsorTx(tx, policy), rejects('2 signatures'));
    });

    test('rejects a fee payer other than Kora', () async {
      final tx = await wire(
        [ix(guard.address, 0, Disc.pulse)],
        payer: key(5),
        signers: [guard],
      );
      expect(() => validateSponsorTx(tx, policy), rejects('fee payer'));
    });

    for (final (name, disc) in [
      ('update_policy', Disc.updatePolicy),
      ('execute_sol_rule', Disc.executeSolRule),
      ('skip_rule', [...Disc.skipRule, 0]),
      ('set_guard', Disc.setGuard),
      ('withdraw_sol', Disc.withdrawSol),
    ]) {
      test('rejects $name', () async {
        final tx = await wire([ix(guard.address, 0, disc)], signers: [guard]);
        expect(
          () => validateSponsorTx(tx, policy),
          rejects('Only Deadman pulse and lockdown'),
        );
      });
    }

    test('rejects a pulse hidden next to another program', () async {
      final tx = await wire(
        [
          ix(guard.address, 0, Disc.pulse),
          MemoInstruction(signers: const [], memo: 'x'),
        ],
        signers: [guard],
      );
      expect(() => validateSponsorTx(tx, policy), rejects('not sponsored'));
    });

    test('rejects an excessive compute unit price', () async {
      final tx = await wire(
        [
          ComputeBudgetInstruction.setComputeUnitLimit(units: 60000),
          ComputeBudgetInstruction.setComputeUnitPrice(microLamports: 1000000),
          ix(guard.address, 0, Disc.pulse),
        ],
        signers: [guard],
      );
      expect(() => validateSponsorTx(tx, policy), rejects('Fee 70000'));
    });

    test('prices a fee with no CU limit at the default limit', () async {
      final tx = await wire(
        [
          ComputeBudgetInstruction.setComputeUnitPrice(microLamports: 1000),
          ix(guard.address, 0, Disc.pulse),
        ],
        signers: [guard],
      );
      // 2 ixs x 200k CU x 1000 µlamports = 400 lamports of priority fee.
      expect(validateSponsorTx(tx, policy).feeLamports, 10400);
    });

    test('rejects a u64-max compute unit price without overflowing', () async {
      final tx = await wire(
        [
          ComputeBudgetInstruction.setComputeUnitLimit(units: 1000),
          Instruction(
            programId: ComputeBudgetProgram.id,
            accounts: const [],
            data: ByteArray([3, ...List.filled(8, 0xff)]),
          ),
          ix(guard.address, 0, Disc.pulse),
        ],
        signers: [guard],
      );
      expect(() => validateSponsorTx(tx, policy), rejects('exceeds'));
    });

    test('rejects a compute unit limit above 60k', () async {
      final tx = await wire(
        [
          ComputeBudgetInstruction.setComputeUnitLimit(units: 60001),
          ix(guard.address, 0, Disc.pulse),
        ],
        signers: [guard],
      );
      expect(() => validateSponsorTx(tx, policy), rejects('60000'));
    });

    test('rejects other ComputeBudget instructions', () async {
      final tx = await wire(
        [
          ComputeBudgetInstruction.requestHeapFrame(bytes: 64 * 1024),
          ix(guard.address, 0, Disc.pulse),
        ],
        signers: [guard],
      );
      expect(() => validateSponsorTx(tx, policy), rejects('ComputeBudget'));
    });

    test('rejects more than 8 Deadman instructions', () async {
      final tx = await wire(
        [for (var p = 0; p < 9; p++) ix(guard.address, p, Disc.pulse)],
        signers: [guard],
      );
      expect(() => validateSponsorTx(tx, policy), rejects('At most 8'));
    });

    test('rejects instructions signed by different keys', () async {
      final other = await keypair(8);
      final tx = await wire(
        [ix(guard.address, 0, Disc.pulse), ix(other.address, 1, Disc.pulse)],
        signers: [guard, other],
      );
      expect(() => validateSponsorTx(tx, policy), rejects('2 signatures'));
    });

    test('rejects truncated and garbage bytes', () async {
      final tx = await wire(
        [ix(guard.address, 0, Disc.pulse)],
        signers: [guard],
      );
      expect(
        () => validateSponsorTx(tx.sublist(0, tx.length - 3), policy),
        rejects('Malformed'),
      );
      expect(() => validateSponsorTx([...tx, 0], policy), rejects('Malformed'));
      expect(() => validateSponsorTx([], policy), rejects('Malformed'));
    });

    test('a forged guard signature fails verification', () async {
      final tx = await wire([ix(guard.address, 0, Disc.pulse)]);
      expect(
        await verifyGuardSignature(validateSponsorTx(tx, policy)),
        isFalse,
      );
    });
  });

  group('checkVaultAccounts', () {
    Future<SponsorRequest> pulseBy(Ed25519HDKeyPair signer) async =>
        validateSponsorTx(
          await wire([ix(signer.address, 0, Disc.pulse)], signers: [signer]),
          policy,
        );

    test('rejects an owner-signed pulse', () async {
      final ownerKey = await keypair(11);
      final r = await pulseBy(ownerKey);
      final account = (
        owner: AppConfig.programId,
        data: Uint8List.fromList(
          vaultBytes(owner: ownerKey.address, guard: ownerKey.address),
        ),
      );
      expect(
        () => checkVaultAccounts(r, [account], policy),
        rejects('Owner-signed'),
      );
    });

    test('rejects a guardian-signed lockdown', () async {
      final g = await keypair(12);
      final r = validateSponsorTx(
        await wire([ix(g.address, 0, Disc.lockdown)], signers: [g]),
        policy,
      );
      expect(
        () => checkVaultAccounts(r, [
          vaultAccount(guard: guard.address, guardian: g.address),
        ], policy),
        rejects('Guardian-signed'),
      );
    });

    test('rejects a key that is not the guard', () async {
      final r = await pulseBy(await keypair(13));
      expect(
        () =>
            checkVaultAccounts(r, [vaultAccount(guard: guard.address)], policy),
        rejects('is not the guard key'),
      );
    });

    test('rejects a missing vault or one owned by another program', () async {
      final r = await pulseBy(guard);
      expect(() => checkVaultAccounts(r, [null], policy), rejects('not found'));
      expect(
        () => checkVaultAccounts(r, [
          vaultAccount(guard: guard.address, programOwner: systemProgramId),
        ], policy),
        rejects('not a Deadman vault'),
      );
    });
  });

  group('UsageLimiter', () {
    test('caps sponsored transactions per vault over a rolling 24h', () {
      var now = 1000000;
      final l = UsageLimiter(clock: () => now);
      for (var i = 0; i < 24; i++) {
        l.acquire('guard', ['vaultA']);
        now += 60;
      }
      expect(() => l.acquire('guard', ['vaultA']), rejects('vault vaultA'));
      l.acquire('guard', ['vaultB']);
      now = 1000000 + 86400;
      l.acquire('guard', ['vaultA']); // the first hit left the window
      expect(() => l.acquire('guard', ['vaultA']), rejects('vault vaultA'));
    });

    test('caps per signer and globally', () {
      final l = UsageLimiter(clock: () => 5000);
      for (var i = 0; i < 48; i++) {
        l.acquire('g1', ['v$i']);
      }
      expect(() => l.acquire('g1', ['fresh']), rejects('guard key g1'));
      final small = UsageLimiter(global: 2, clock: () => 5000)
        ..acquire('a', ['x'])
        ..acquire('b', ['y']);
      expect(() => small.acquire('c', ['z']), rejects('sponsor reached'));
    });

    test('n slots at once, and release gives them back', () {
      final l = UsageLimiter(perVault: 0, perSigner: 3, global: 4);
      final at = l.acquire('a', const [], n: 2);
      expect(() => l.check('a', const [], n: 2), rejects('reached 3'));
      l.check('a', const []);
      l.acquire('b', const [], n: 2);
      expect(() => l.check('c', const []), rejects('cap of 4'));
      l.release('a', const [], at, n: 2);
      expect(l.toJson()['global'], hasLength(2));
      expect((l.toJson()['signers']! as Map).keys, ['b']);
      l.acquire('a', const [], n: 2);
    });

    test('a rejected transaction records nothing', () {
      final l = UsageLimiter(perVault: 1, clock: () => 5000)
        ..acquire('g', ['full']);
      expect(() => l.acquire('g', ['ok', 'full']), rejects('vault full'));
      l.acquire('g', ['ok']);
    });

    test('persists across restarts', () {
      final dir = Directory.systemTemp.createTempSync('gw');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/usage.json');
      UsageLimiter(
        perVault: 1,
        file: file,
        clock: () => 5000,
      ).acquire('g', ['v']);
      final reloaded = UsageLimiter(perVault: 1, file: file, clock: () => 5001);
      expect(() => reloaded.acquire('g', ['v']), rejects('vault v'));
    });
  });

  group('KoraGateway over HTTP', () {
    late HttpServer upstream;
    late HttpServer server;
    late List<Map<String, dynamic>> forwarded;
    late List<String?> keys;

    setUp(() async {
      forwarded = [];
      keys = [];
      upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      upstream.listen((req) async {
        keys.add(req.headers.value('x-api-key'));
        final body =
            jsonDecode(await utf8.decodeStream(req)) as Map<String, dynamic>;
        forwarded.add(body);
        req.response
          ..headers.contentType = ContentType.json
          ..write(
            jsonEncode({
              'jsonrpc': '2.0',
              'id': body['id'],
              'result': body['method'] == 'getBlockhash'
                  ? {'blockhash': blockhash}
                  : {'signature': 'sig', 'signed_transaction': 'x'},
            }),
          );
        await req.response.close();
      });
      final gateway = KoraGateway(
        upstream: Uri.parse('http://127.0.0.1:${upstream.port}'),
        apiKey: 'secret',
        route: SponsorRoute(
          policy: policy,
          limiter: UsageLimiter(perVault: 1),
          fetchAccounts: (vaults) async => [
            for (final _ in vaults) vaultAccount(guard: guard.address),
          ],
        ),
        payerSigner: {'signer_address': kora, 'payment_address': kora},
        maxBodyBytes: 4096,
        log: (_) {},
      );
      server = await gateway.serve(InternetAddress.loopbackIPv4, 0);
    });

    tearDown(() async {
      await server.close(force: true);
      await upstream.close(force: true);
    });

    Future<(int, Map<String, dynamic>?)> call(
      String method, [
      Object? params,
      String? rawBody,
    ]) async {
      final client = HttpClient();
      try {
        final req = await client.post('127.0.0.1', server.port, '/');
        req.headers.contentType = ContentType.json;
        req.write(
          rawBody ??
              jsonEncode({
                'jsonrpc': '2.0',
                'id': 7,
                'method': method,
                'params': ?params,
              }),
        );
        final res = await req.close();
        final text = await utf8.decodeStream(res);
        return (
          res.statusCode,
          text.isEmpty ? null : jsonDecode(text) as Map<String, dynamic>,
        );
      } finally {
        client.close(force: true);
      }
    }

    test(
      'serves getPayerSigner locally and getBlockhash with the key',
      () async {
        final (_, payer) = await call('getPayerSigner');
        expect(payer!['result']['signer_address'], kora);
        expect(payer['id'], 7);
        final (_, bh) = await call('getBlockhash');
        expect(bh!['result']['blockhash'], blockhash);
        expect(keys, ['secret']);
      },
    );

    test('refuses other methods and oversized bodies', () async {
      for (final m in [
        'signTransaction',
        'getConfig',
        'transferTransaction',
        'estimateTransactionFee',
      ]) {
        final (status, r) = await call(m);
        expect(status, 200);
        expect(r!['error']['code'], -32601);
      }
      final (status, _) = await call('', null, 'x' * 5000);
      expect(status, 413);
      expect(forwarded, isEmpty);
    });

    test('forwards a valid pulse once, then rate-limits the vault', () async {
      final tx = base64Encode(
        await wire([ix(guard.address, 0, Disc.pulse)], signers: [guard]),
      );
      final (_, ok) = await call('signAndSendTransaction', {
        'transaction': tx,
        'signer_key': kora,
      });
      expect(ok!['result']['signature'], 'sig');
      expect(forwarded.single['params'], {'transaction': tx});
      expect(keys.single, 'secret');

      final (_, limited) = await call('signAndSendTransaction', {
        'transaction': tx,
      });
      expect(limited!['error']['message'], contains('Rate limit'));
      expect(forwarded, hasLength(1));
    });

    test('never forwards a rejected transaction', () async {
      final cbOnly = base64Encode(
        await wire([ComputeBudgetInstruction.setComputeUnitLimit(units: 1)]),
      );
      final (_, r) = await call('signAndSendTransaction', {
        'transaction': cbOnly,
      });
      expect(r!['error']['message'], contains('2 signatures'));
      final (_, bad) = await call('signAndSendTransaction', {
        'transaction': '!!',
      });
      expect(bad!['error']['message'], contains('base64'));
      expect(forwarded, isEmpty);
    });
  });

  paymasterTests();
}

const usdc = '4zMMC9srt5Ri5X14GAgXhaHii3GnPAEERYPJgZJDncDU';
final payAta = associatedTokenAddress(kora, usdc, tokenProgramId);
final pmPolicy = PaymasterPolicy(
  koraPayer: kora,
  paymentAtas: {
    payAta: (
      mint: usdc,
      tokenProgram: tokenProgramId,
      minAmounts: {
        PaymasterTier.basic: 20000,
        PaymasterTier.account: 1000000,
        PaymasterTier.plan: 3000000,
      },
    ),
  },
);

Ed25519HDPublicKey pk(String k) => Ed25519HDPublicKey.fromBase58(k);

AccountMeta ro(String k, {bool signer = false}) =>
    AccountMeta.readonly(pubKey: pk(k), isSigner: signer);

AccountMeta rw(String k, {bool signer = false}) =>
    AccountMeta.writeable(pubKey: pk(k), isSigner: signer);

Instruction createVault(String owner, String payer) => deadmanIx(
  [
    ro(owner, signer: true),
    rw(payer, signer: true),
    rw(vaultPda(owner, 0).address),
    ro(systemProgramId),
  ],
  [...Disc.createVault, 0, 0, 1, 2, 3],
);

Instruction transferChecked({
  required String source,
  required String dest,
  required String authority,
  int amount = 1000,
  String mint = usdc,
}) => Instruction(
  programId: pk(tokenProgramId),
  accounts: [rw(source), ro(mint), rw(dest), ro(authority, signer: true)],
  data: ByteArray([12, ...le(8, amount), 6]),
);

Instruction pay(String owner, {int amount = 3000000}) => transferChecked(
  source: associatedTokenAddress(owner, usdc, tokenProgramId),
  dest: payAta,
  authority: owner,
  amount: amount,
);

Instruction ataCreateIdempotent(String payer, String wallet) => Instruction(
  programId: pk(ataProgramId),
  accounts: [
    rw(payer, signer: true),
    rw(associatedTokenAddress(wallet, usdc, tokenProgramId)),
    ro(wallet),
    ro(usdc),
    ro(systemProgramId),
    ro(tokenProgramId),
  ],
  data: ByteArray([1]),
);

/// An SPL token account as the RPC returns it; [state] 1 = initialized,
/// 2 = frozen.
VaultAccount tokenAccount(
  String holder,
  int amount, {
  String mint = usdc,
  int state = 1,
}) => (
  owner: tokenProgramId,
  data: Uint8List.fromList(
    tokenAccountBytes(mint: mint, owner: holder, amount: amount)..[108] = state,
  ),
);

String usdcAta(String holder) =>
    associatedTokenAddress(holder, usdc, tokenProgramId);

PaymasterRoute pmRoute({
  UsageLimiter? limiter,
  UsageLimiter? creates,
  UsageLimiter? atas,
  Map<String, VaultAccount?> chain = const {},
  Map<PaymasterTier, Uri> upstreams = const {},
}) => PaymasterRoute(
  policy: pmPolicy,
  limiter: limiter ?? UsageLimiter(perVault: 0),
  creates: creates ?? UsageLimiter(perVault: 0),
  atas: atas ?? UsageLimiter(perVault: 0),
  fetchAccounts: (addresses) async => [for (final a in addresses) chain[a]],
  upstreams: upstreams,
);

Instruction ataCreateFor(String payer, String wallet, String mint) =>
    Instruction(
      programId: pk(ataProgramId),
      accounts: [
        rw(payer, signer: true),
        rw(associatedTokenAddress(wallet, mint, tokenProgramId)),
        ro(wallet),
        ro(mint),
        ro(systemProgramId),
        ro(tokenProgramId),
      ],
      data: ByteArray([1]),
    );

/// `execute_token_rule` / `release_vested_token` accounts, as the client
/// builds them.
Instruction payoutIx(
  String executor,
  String vaultOwner,
  String beneficiary,
  String treasury,
  List<int> disc, {
  String mint = usdc,
}) {
  final vault = vaultPda(vaultOwner, 0).address;
  return deadmanIx(
    [
      ro(executor, signer: true),
      rw(vault),
      ro(configPda().address),
      ro(mint),
      rw(associatedTokenAddress(vault, mint, tokenProgramId)),
      rw(beneficiary),
      rw(associatedTokenAddress(beneficiary, mint, tokenProgramId)),
      rw(associatedTokenAddress(treasury, mint, tokenProgramId)),
      ro(tokenProgramId),
    ],
    [...disc, 0],
  );
}

void paymasterTests() {
  late Ed25519HDKeyPair owner;

  setUpAll(() async => owner = await keypair(21));

  test('paymaster Deadman discriminators match the IDL', () {
    final disc = {
      for (final i in loadIdl()['instructions'] as List)
        (i as Map)['name']: (i['discriminator'] as List).cast<int>(),
    };
    for (final MapEntry(:key, :value) in paymasterDeadmanIxs.entries) {
      expect(value.disc, disc[key], reason: key);
      final accounts =
          (loadIdl()['instructions'] as List).firstWhere(
                (i) => (i as Map)['name'] == key,
              )['accounts']
              as List;
      expect(value.accounts, accounts.length, reason: key);
    }
    expect(paymasterDeadmanIxs.keys, isNot(contains('init_config')));
    expect(paymasterDeadmanIxs.keys, isNot(contains('set_config')));
  });

  group('validatePaymasterTx', () {
    test(
      'accepts create_vault with Kora as payer and a USDC payment',
      () async {
        final tx = await wire(
          [
            ComputeBudgetInstruction.setComputeUnitLimit(units: 200000),
            createVault(owner.address, kora),
            pay(owner.address),
          ],
          signers: [owner],
        );
        final r = validatePaymasterTx(tx, pmPolicy);
        expect(r.signer, owner.address);
        expect(r.koraFundsRent, isTrue);
        expect(r.instructions, [
          'compute_budget',
          'deadman.create_vault',
          'token.transfer_checked',
        ]);
        expect(r.payment, (mint: usdc, destination: payAta, amount: 3000000));
        expect(r.feeLamports, 10000);
        expect(await verifyOwnerSignature(r), isTrue);
      },
    );

    test('accepts a SOL and token deposit paid in USDC', () async {
      final vault = vaultPda(owner.address, 0).address;
      final tx = await wire(
        [
          ataCreateIdempotent(owner.address, vault),
          transferChecked(
            source: associatedTokenAddress(owner.address, usdc, tokenProgramId),
            dest: associatedTokenAddress(vault, usdc, tokenProgramId),
            authority: owner.address,
            amount: 50000000,
          ),
          SystemInstruction.transfer(
            fundingAccount: owner.publicKey,
            recipientAccount: pk(vault),
            lamports: 100000000,
          ),
          pay(owner.address, amount: 3500000),
        ],
        signers: [owner],
        v0: true,
      );
      final r = validatePaymasterTx(tx, pmPolicy);
      expect(r.koraFundsRent, isFalse);
      expect(r.payment!.amount, 3500000);
      expect(await verifyOwnerSignature(r), isTrue);
    });

    test('prices by what Kora funds: basic, account, plan', () async {
      final vault = vaultPda(owner.address, 0).address;
      final deposit = transferChecked(
        source: associatedTokenAddress(owner.address, usdc, tokenProgramId),
        dest: associatedTokenAddress(vault, usdc, tokenProgramId),
        authority: owner.address,
        amount: 5,
      );
      Future<PaymasterRequest> check(List<Instruction> ixs, int paid) async =>
          validatePaymasterTx(
            await wire(
              [...ixs, pay(owner.address, amount: paid)],
              signers: [owner],
            ),
            pmPolicy,
          );

      expect((await check([deposit], 20000)).tier, PaymasterTier.basic);
      final account = await check([
        ataCreateIdempotent(kora, vault),
        deposit,
      ], 1000000);
      expect(account.tier, PaymasterTier.account);
      expect(account.koraAtas, 1);
      expect(
        (await check([createVault(owner.address, kora)], 3000000)).tier,
        PaymasterTier.plan,
      );
      await expectLater(
        check([ataCreateIdempotent(kora, vault), deposit], 20000),
        throwsA(
          isA<GatewayRejection>().having(
            (e) => e.message,
            'message',
            contains('below the account price'),
          ),
        ),
      );
      await expectLater(
        check([
          ataCreateIdempotent(kora, vault),
          ataCreateIdempotent(kora, owner.address),
          ataCreateIdempotent(kora, key(50)),
        ], 1000000),
        throwsA(isA<GatewayRejection>()),
      );
    });

    group('Kora-funded token accounts (M-1)', () {
      final other = key(60);

      Future<PaymasterRequest> check(List<Instruction> ixs) async =>
          validatePaymasterTx(
            await wire(
              [...ixs, pay(owner.address, amount: 1000000)],
              signers: [owner],
            ),
            pmPolicy,
          );

      test(
        'PoC: two Kora-paid ATAs on the signer own wallet are refused',
        () async {
          await expectLater(
            check([
              ataCreateFor(kora, owner.address, usdc),
              ataCreateFor(kora, owner.address, other),
            ]),
            throwsA(
              isA<GatewayRejection>().having(
                (e) => e.message,
                'message',
                allOf(
                  contains('only funds a token account the transaction pays'),
                  contains(owner.address),
                ),
              ),
            ),
          );
        },
      );

      test('a Kora-paid ATA needs a deposit of its own mint', () async {
        final vault = vaultPda(owner.address, 0).address;
        // Deposit of another mint (or none) does not justify it.
        await expectLater(
          check([
            ataCreateFor(kora, vault, other),
            transferChecked(
              source: usdcAta(owner.address),
              dest: usdcAta(vault),
              authority: owner.address,
            ),
          ]),
          rejects('only funds a token account'),
        );
        // A zero deposit does not either.
        await expectLater(
          check([
            ataCreateIdempotent(kora, vault),
            transferChecked(
              source: usdcAta(owner.address),
              dest: usdcAta(vault),
              authority: owner.address,
              amount: 0,
            ),
          ]),
          rejects('only funds a token account'),
        );
      });

      test('a deposit ATA of a vault created in the same transaction '
          'needs no on-chain check', () async {
        final vault = vaultPda(owner.address, 0).address;
        final r = validatePaymasterTx(
          await wire(
            [
              createVault(owner.address, kora),
              ataCreateIdempotent(kora, vault),
              transferChecked(
                source: usdcAta(owner.address),
                dest: usdcAta(vault),
                authority: owner.address,
              ),
              pay(owner.address),
            ],
            signers: [owner],
          ),
          pmPolicy,
        );
        expect(r.tier, PaymasterTier.plan);
        expect(r.koraAtas, 1);
        expect(r.vaultChecks, isEmpty);
      });

      test('a deposit ATA outside a Deadman instruction is checked on '
          'chain', () async {
        final r = await check([
          ataCreateFor(kora, other, usdc),
          transferChecked(
            source: usdcAta(owner.address),
            dest: usdcAta(other),
            authority: owner.address,
          ),
        ]);
        expect(r.vaultChecks, [other]);
      });

      for (final (name, disc) in [
        ('execute_token_rule', Disc.executeTokenRule),
        ('release_vested_token', Disc.releaseVestedToken),
      ]) {
        test(
          '$name: Kora may open the beneficiary and treasury ATAs',
          () async {
            final treasury = key(61);
            final r = await check([
              ataCreateFor(kora, treasury, usdc),
              ataCreateFor(kora, owner.address, usdc),
              payoutIx(owner.address, key(62), owner.address, treasury, disc),
            ]);
            expect(r.koraAtas, 2);
            expect(r.vaultChecks, isEmpty);
            // Not the ATA of a wallet that is not the beneficiary, nor of
            // another mint.
            await expectLater(
              check([
                ataCreateFor(kora, other, usdc),
                payoutIx(owner.address, key(62), owner.address, treasury, disc),
              ]),
              rejects('only funds a token account'),
            );
            await expectLater(
              check([
                ataCreateFor(kora, owner.address, other),
                payoutIx(owner.address, key(62), owner.address, treasury, disc),
              ]),
              rejects('only funds a token account'),
            );
          },
        );
      }

      test("withdraw_token: Kora never opens the owner's ATA", () async {
        final vault = vaultPda(owner.address, 0).address;
        await expectLater(
          check([
            ataCreateIdempotent(kora, owner.address),
            deadmanIx(
              [
                rw(owner.address, signer: true),
                rw(vault),
                ro(usdc),
                rw(usdcAta(vault)),
                rw(usdcAta(owner.address)),
                ro(tokenProgramId),
              ],
              [...Disc.withdrawToken, ...le(8, 5)],
            ),
          ]),
          rejects('only funds a token account'),
        );
      });
    });

    test('routes each tier to its own Kora node', () async {
      final route = pmRoute(
        upstreams: {
          PaymasterTier.basic: Uri.parse('http://basic'),
          PaymasterTier.plan: Uri.parse('http://plan'),
        },
      );
      final basic = await wire(
        [pay(owner.address, amount: 20000)],
        signers: [owner],
      );
      final plan = await wire(
        [createVault(owner.address, kora), pay(owner.address)],
        signers: [owner],
      );
      expect(route.upstreamFor(basic), Uri.parse('http://basic'));
      expect(route.upstreamFor(plan), Uri.parse('http://plan'));
      expect(route.minFee(basic, usdc), 20000);
      expect(route.minFee(plan, usdc), 3000000);
      expect(route.minFee(plan, 'other'), isNull);
    });

    test('accepts close_vault returning the rent to Kora', () async {
      final tx = await wire(
        [
          deadmanIx([
            rw(owner.address, signer: true),
            rw(vaultPda(owner.address, 0).address),
            rw(kora),
          ], Disc.closeVault),
          pay(owner.address),
        ],
        signers: [owner],
      );
      expect(validatePaymasterTx(tx, pmPolicy).koraFundsRent, isFalse);
    });

    test('rejects a transaction without the payment', () async {
      final tx = await wire(
        [createVault(owner.address, kora)],
        signers: [owner],
      );
      expect(
        () => validatePaymasterTx(tx, pmPolicy),
        rejects('The last instruction must pay'),
      );
      // Estimates may omit it; the client appends it once priced.
      expect(
        validatePaymasterTx(tx, pmPolicy, requirePayment: false).payment,
        isNull,
      );
    });

    test('rejects a payment that is not the last instruction', () async {
      final tx = await wire(
        [pay(owner.address), createVault(owner.address, kora)],
        signers: [owner],
      );
      expect(
        () => validatePaymasterTx(tx, pmPolicy),
        rejects('The last instruction must pay'),
      );
    });

    test('rejects a payment below the fixed price', () async {
      final tx = await wire(
        [createVault(owner.address, kora), pay(owner.address, amount: 2999999)],
        signers: [owner],
      );
      expect(
        () => validatePaymasterTx(tx, pmPolicy),
        rejects('below the plan price 3000000'),
      );
    });

    test('rejects a payment in another mint', () async {
      final tx = await wire(
        [
          transferChecked(
            source: key(30),
            dest: payAta,
            authority: owner.address,
            amount: 3000000,
            mint: key(31),
          ),
        ],
        signers: [owner],
      );
      expect(() => validatePaymasterTx(tx, pmPolicy), rejects('wrong mint'));
    });

    test('rejects Kora as a token authority', () async {
      final tx = await wire(
        [
          transferChecked(
            source: associatedTokenAddress(kora, usdc, tokenProgramId),
            dest: associatedTokenAddress(owner.address, usdc, tokenProgramId),
            authority: kora,
          ),
          pay(owner.address),
        ],
        signers: [owner],
      );
      expect(
        () => validatePaymasterTx(tx, pmPolicy),
        rejects('cannot be a token authority'),
      );
    });

    test('rejects Kora as a System transfer source', () async {
      final tx = await wire(
        [
          SystemInstruction.transfer(
            fundingAccount: pk(kora),
            recipientAccount: owner.publicKey,
            lamports: 1000000,
          ),
          pay(owner.address),
        ],
        signers: [owner],
      );
      expect(
        () => validatePaymasterTx(tx, pmPolicy),
        rejects('cannot fund a System transfer'),
      );
    });

    test('rejects Kora in any other Deadman account slot', () async {
      final tx = await wire(
        [
          deadmanIx(
            [rw(owner.address, signer: true), rw(kora)],
            [...Disc.updatePolicy, 0],
          ),
          pay(owner.address),
        ],
        signers: [owner],
      );
      expect(
        () => validatePaymasterTx(tx, pmPolicy),
        rejects('may only be the payer'),
      );
    });

    test('rejects two Kora-funded vaults in one transaction', () async {
      final tx = await wire(
        [
          createVault(owner.address, kora),
          deadmanIx(
            [
              ro(owner.address, signer: true),
              rw(kora, signer: true),
              rw(vaultPda(owner.address, 1).address),
              ro(systemProgramId),
            ],
            [...Disc.createVault, 1, 0],
          ),
          pay(owner.address),
        ],
        signers: [owner],
      );
      expect(
        () => validatePaymasterTx(tx, pmPolicy),
        rejects('At most one paymaster-funded vault'),
      );
    });

    for (final (name, data) in [
      ('init_config', [23, 235, 115, 232, 168, 96, 1, 231]),
      ('set_config', [108, 158, 154, 175, 212, 98, 52, 66]),
    ]) {
      test('rejects $name', () async {
        final tx = await wire(
          [
            deadmanIx([rw(owner.address, signer: true), rw(key(40))], data),
            pay(owner.address),
          ],
          signers: [owner],
        );
        expect(
          () => validatePaymasterTx(tx, pmPolicy),
          rejects('Deadman $name is not paid by the paymaster'),
        );
      });
    }

    test('rejects other programs', () async {
      final tx = await wire(
        [MemoInstruction(signers: const [], memo: 'x'), pay(owner.address)],
        signers: [owner],
      );
      expect(
        () => validatePaymasterTx(tx, pmPolicy),
        rejects('not allowed by the paymaster'),
      );
    });

    test('rejects 3 signers', () async {
      final other = await keypair(22);
      final tx = await wire(
        [
          SystemInstruction.transfer(
            fundingAccount: other.publicKey,
            recipientAccount: owner.publicKey,
            lamports: 1,
          ),
          pay(owner.address),
        ],
        signers: [owner, other],
      );
      expect(
        () => validatePaymasterTx(tx, pmPolicy),
        rejects('exactly 2 signatures'),
      );
    });

    test('rejects a fee payer other than Kora', () async {
      final tx = await wire(
        [pay(owner.address)],
        payer: key(5),
        signers: [owner],
      );
      expect(() => validatePaymasterTx(tx, pmPolicy), rejects('fee payer'));
    });

    test('rejects a priority fee above the cap', () async {
      final tx = await wire(
        [
          ComputeBudgetInstruction.setComputeUnitLimit(units: 400000),
          ComputeBudgetInstruction.setComputeUnitPrice(microLamports: 200000),
          pay(owner.address),
        ],
        signers: [owner],
      );
      expect(() => validatePaymasterTx(tx, pmPolicy), rejects('Fee 90000'));
    });

    test('a forged owner signature fails verification', () async {
      final forger = await keypair(23);
      final tx = await wire(
        [createVault(owner.address, kora), pay(owner.address)],
        signers: [forger],
      );
      final r = validatePaymasterTx(tx, pmPolicy);
      expect(await verifyOwnerSignature(r), isFalse);
    });
  });

  group('PaymasterRoute', () {
    test('rate-limits Kora-funded vaults separately', () async {
      final route = pmRoute(
        limiter: UsageLimiter(perVault: 0, perSigner: 60, clock: () => 5000),
        creates: UsageLimiter(
          perVault: 0,
          perSigner: 1,
          clock: () => 5000,
          signerLabel: 'owner',
          unit: 'paymaster-funded vaults',
        ),
        chain: {usdcAta(owner.address): tokenAccount(owner.address, 9000000)},
      );
      final create = await wire(
        [createVault(owner.address, kora), pay(owner.address)],
        signers: [owner],
      );
      expect((await route.admit(create)).summary, contains('tier=plan'));
      await expectLater(
        route.admit(create),
        rejects('reached 1 paymaster-funded vaults'),
      );
      final deposit = await wire(
        [
          SystemInstruction.transfer(
            fundingAccount: owner.publicKey,
            recipientAccount: pk(vaultPda(owner.address, 0).address),
            lamports: 1,
          ),
          pay(owner.address),
        ],
        signers: [owner],
      );
      expect((await route.admit(deposit)).summary, contains('tier=basic'));
    });

    test('rejects an unsigned transaction before counting it', () async {
      final limiter = UsageLimiter(perVault: 0, perSigner: 1);
      final route = pmRoute(limiter: limiter);
      final tx = await wire([pay(owner.address)]);
      await expectLater(route.admit(tx), rejects('Invalid owner signature'));
      expect(limiter.toJson()['global'], isEmpty);
    });

    test('caps Kora-funded token accounts per owner, one slot each', () async {
      final vault = vaultPda(owner.address, 0).address;
      final atas = UsageLimiter(
        perVault: 0,
        perSigner: 2,
        signerLabel: 'owner',
        unit: 'paymaster-funded token accounts',
      );
      final route = pmRoute(
        atas: atas,
        chain: {
          usdcAta(owner.address): tokenAccount(owner.address, 90000000),
          vault: vaultAccount(guard: key(63)),
        },
      );
      Future<Uint8List> deposit(String mint) async => wire(
        [
          ataCreateFor(kora, vault, mint),
          transferChecked(
            source: associatedTokenAddress(owner.address, mint, tokenProgramId),
            dest: associatedTokenAddress(vault, mint, tokenProgramId),
            authority: owner.address,
            mint: mint,
          ),
          pay(owner.address, amount: 1000000),
        ],
        signers: [owner],
      );
      final a = await route.admit(await deposit(usdc));
      expect(a.summary, contains('koraAtas=1'));
      await route.admit(await deposit(key(64)));
      await expectLater(
        route.admit(await deposit(key(65))),
        rejects('reached 2 paymaster-funded token accounts'),
      );
      a.release();
      expect(
        (await route.admit(await deposit(key(65)))).summary,
        contains('tier=account'),
      );
    });

    test('a Kora-funded deposit ATA must belong to a Deadman vault', () async {
      final notVault = key(66);
      final route = pmRoute(
        chain: {
          usdcAta(owner.address): tokenAccount(owner.address, 9000000),
          notVault: (owner: systemProgramId, data: Uint8List(0)),
        },
      );
      final tx = await wire(
        [
          ataCreateFor(kora, notVault, usdc),
          transferChecked(
            source: usdcAta(owner.address),
            dest: usdcAta(notVault),
            authority: owner.address,
          ),
          pay(owner.address, amount: 1000000),
        ],
        signers: [owner],
      );
      await expectLater(route.admit(tx), rejects('$notVault is not one'));
    });

    group('payment account pre-check (M-2)', () {
      late UsageLimiter limiter;
      setUp(() => limiter = UsageLimiter(perVault: 0));

      Future<void> expectRefused(
        Map<String, VaultAccount?> chain,
        List<Instruction> ixs,
        Pattern message,
      ) async {
        final tx = await wire(ixs, signers: [owner]);
        await expectLater(
          pmRoute(limiter: limiter, chain: chain).admit(tx),
          rejects(message),
        );
        expect(limiter.toJson()['global'], isEmpty);
      }

      List<Instruction> basic() => [pay(owner.address, amount: 20000)];

      test('missing, foreign, wrong-mint or frozen accounts', () async {
        final src = usdcAta(owner.address);
        await expectRefused({}, basic(), 'does not exist');
        await expectRefused(
          {src: tokenAccount(key(67), 20000)},
          basic(),
          'is not an unfrozen',
        );
        await expectRefused(
          {src: tokenAccount(owner.address, 20000, mint: key(68))},
          basic(),
          'is not an unfrozen',
        );
        await expectRefused(
          {src: tokenAccount(owner.address, 20000, state: 2)},
          basic(),
          'is not an unfrozen',
        );
      });

      test('the balance must cover every transfer out of it', () async {
        final src = usdcAta(owner.address);
        await expectRefused(
          {src: tokenAccount(owner.address, 19999)},
          basic(),
          'holds 19999, the transaction needs 20000',
        );
        final vault = vaultPda(owner.address, 0).address;
        await expectRefused(
          {src: tokenAccount(owner.address, 25000)},
          [
            transferChecked(
              source: src,
              dest: usdcAta(vault),
              authority: owner.address,
              amount: 5001,
            ),
            ...basic(),
          ],
          'needs 25001',
        );
        final ok = await pmRoute(
          limiter: limiter,
          chain: {src: tokenAccount(owner.address, 20000)},
        ).admit(await wire(basic(), signers: [owner]));
        expect(ok.summary, contains('tier=basic'));
        expect(limiter.toJson()['global'], hasLength(1));
        ok.release();
        expect(limiter.toJson()['global'], isEmpty);
      });

      test('a withdrawal into the payment account counts, even into one the '
          'transaction opens', () async {
        final vault = vaultPda(owner.address, 0).address;
        final withdraw = deadmanIx(
          [
            rw(owner.address, signer: true),
            rw(vault),
            ro(usdc),
            rw(usdcAta(vault)),
            rw(usdcAta(owner.address)),
            ro(tokenProgramId),
          ],
          [...Disc.withdrawToken, ...le(8, 20000)],
        );
        final route = pmRoute(
          chain: {usdcAta(owner.address): tokenAccount(owner.address, 0)},
        );
        await route.admit(await wire([withdraw, ...basic()], signers: [owner]));
        await expectLater(
          pmRoute().admit(await wire([withdraw, ...basic()], signers: [owner])),
          rejects('does not exist'),
        );
        final opened = await pmRoute().admit(
          await wire(
            [
              ataCreateIdempotent(owner.address, owner.address),
              withdraw,
              ...basic(),
            ],
            signers: [owner],
          ),
        );
        expect(opened.summary, contains('tier=basic'));
      });
    });

    test('estimates reject an unknown fee_token', () {
      final tx = base64Encode(Uint8List(0));
      expect(
        () => pmRoute().admitEstimate(tx, key(50)),
        rejects('fee_token must be one of'),
      );
    });
  });

  group('loadPaymentAtas', () {
    late FakeRpc rpc;
    setUp(() async {
      rpc = await FakeRpc.start();
      rpc.accounts[usdc] = FakeAccount(tokenProgramId, mintBytes(6));
    });
    tearDown(() => rpc.close());

    Map<String, dynamic> config(Map<String, Object> price) => {
      'validation_config': {
        'price': price,
        'allowed_spl_paid_tokens': [usdc],
      },
    };

    test('fixed: each tier price in the mint decimals', () async {
      final atas = await loadPaymentAtas(rpc.client().rpcClient, {
        for (final (tier, amount) in [
          (PaymasterTier.plan, 3000000),
          (PaymasterTier.basic, 20000),
        ])
          tier: config({'type': 'fixed', 'amount': amount, 'token': usdc}),
      }, kora);
      expect(atas[payAta]!.minAmounts, {
        PaymasterTier.plan: 3000000,
        PaymasterTier.basic: 20000,
      });
    });

    test(
      'margin (mainnet): no gateway floor, Kora prices the outflow',
      () async {
        final margin = config({'type': 'margin', 'margin': 0.15});
        final atas = await loadPaymentAtas(rpc.client().rpcClient, {
          for (final tier in PaymasterTier.values) tier: margin,
        }, kora);
        expect(atas[payAta]!.mint, usdc);
        expect(atas[payAta]!.minAmounts, isEmpty);
        final tx = await wire([pay(key(2), amount: 1)], signers: const []);
        expect(
          validatePaymasterTx(
            tx,
            PaymasterPolicy(koraPayer: kora, paymentAtas: atas),
          ).tier,
          PaymasterTier.basic,
        );
        await expectLater(
          loadPaymentAtas(rpc.client().rpcClient, {
            PaymasterTier.plan: margin,
            PaymasterTier.basic: config({
              'type': 'fixed',
              'amount': 1,
              'token': usdc,
            }),
          }, kora),
          throwsA(isA<StateError>()),
        );
        await expectLater(
          loadPaymentAtas(rpc.client().rpcClient, {
            PaymasterTier.plan: config({'type': 'free'}),
          }, kora),
          throwsA(isA<StateError>()),
        );
      },
    );
  });

  group('paymaster over HTTP', () {
    late HttpServer upstream;
    late HttpServer server;
    late List<Map<String, dynamic>> forwarded;
    late UsageLimiter limiter;
    late UsageLimiter creates;
    late Map<String, VaultAccount?> chain;
    String? failSend;
    int? sendStatus;

    setUp(() async {
      forwarded = [];
      chain = {};
      failSend = null;
      sendStatus = null;
      limiter = UsageLimiter(perVault: 0);
      creates = UsageLimiter(perVault: 0, perSigner: 3, global: 20);
      upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      upstream.listen((req) async {
        final body =
            jsonDecode(await utf8.decodeStream(req)) as Map<String, dynamic>;
        forwarded.add(body);
        final send = body['method'] == 'signAndSendTransaction';
        if (send && sendStatus != null) {
          req.response.statusCode = sendStatus!;
          await req.response.close();
          return;
        }
        req.response
          ..headers.contentType = ContentType.json
          ..write(
            jsonEncode({
              'jsonrpc': '2.0',
              'id': body['id'],
              if (send && failSend != null)
                'error': {'code': -32000, 'message': failSend}
              else
                'result': body['method'] == 'estimateTransactionFee'
                    ? {'fee_in_lamports': 300000, 'fee_in_token': 3000000}
                    : {'signature': 'sig', 'signed_transaction': 'x'},
            }),
          );
        await req.response.close();
      });
      final gateway = KoraGateway(
        upstream: Uri.parse('http://127.0.0.1:${upstream.port}'),
        apiKey: 'pm-secret',
        route: PaymasterRoute(
          policy: pmPolicy,
          limiter: limiter,
          creates: creates,
          atas: UsageLimiter(perVault: 0),
          fetchAccounts: (addresses) async => [
            for (final a in addresses) chain[a],
          ],
        ),
        payerSigner: {'signer_address': kora, 'payment_address': kora},
        log: (_) {},
      );
      server = await gateway.serve(InternetAddress.loopbackIPv4, 0);
    });

    tearDown(() async {
      await server.close(force: true);
      await upstream.close(force: true);
    });

    Future<Map<String, dynamic>> call(String method, Object? params) async {
      final client = HttpClient();
      try {
        final req = await client.post('127.0.0.1', server.port, '/');
        req.headers.contentType = ContentType.json;
        req.write(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': 3,
            'method': method,
            'params': params,
          }),
        );
        final res = await req.close();
        return jsonDecode(await utf8.decodeStream(res)) as Map<String, dynamic>;
      } finally {
        client.close(force: true);
      }
    }

    test('forwards a paid create_vault, refuses an unpaid one', () async {
      final owner = await keypair(24);
      chain[usdcAta(owner.address)] = tokenAccount(owner.address, 3000000);
      final unpaid = base64Encode(
        await wire([createVault(owner.address, kora)], signers: [owner]),
      );
      final r1 = await call('signAndSendTransaction', {'transaction': unpaid});
      expect(r1['error']['message'], contains('The last instruction must pay'));
      expect(forwarded, isEmpty);

      final est = await call('estimateTransactionFee', {
        'transaction': unpaid,
        'fee_token': usdc,
      });
      expect(est['result']['fee_in_token'], 3000000);
      expect(forwarded.single['params'], {
        'transaction': unpaid,
        'fee_token': usdc,
      });

      final paid = base64Encode(
        await wire(
          [createVault(owner.address, kora), pay(owner.address)],
          signers: [owner],
        ),
      );
      final r2 = await call('signAndSendTransaction', {'transaction': paid});
      expect(r2['result']['signature'], 'sig');
      expect(forwarded.last['params'], {'transaction': paid});
    });

    test('gives the quota back when Kora rejects the transaction', () async {
      final owner = await keypair(25);
      chain[usdcAta(owner.address)] = tokenAccount(owner.address, 9000000);
      final paid = base64Encode(
        await wire(
          [createVault(owner.address, kora), pay(owner.address)],
          signers: [owner],
        ),
      );
      failSend = 'Invalid transaction: simulation failed';
      final r1 = await call('signAndSendTransaction', {'transaction': paid});
      expect(r1['error']['message'], contains('simulation failed'));
      sendStatus = 503;
      final r2 = await call('signAndSendTransaction', {'transaction': paid});
      expect(r2['error']['message'], contains('temporarily unavailable'));
      expect(forwarded, hasLength(2));
      expect(limiter.toJson()['global'], isEmpty);
      expect(creates.toJson()['global'], isEmpty);

      failSend = null;
      sendStatus = null;
      final r3 = await call('signAndSendTransaction', {'transaction': paid});
      expect(r3['result']['signature'], 'sig');
      expect(limiter.toJson()['global'], hasLength(1));
      expect(creates.toJson()['global'], hasLength(1));
    });

    test('M-2 PoC: 21 unfunded wallets never reach Kora nor fill the vault '
        'quota', () async {
      for (var i = 0; i < 21; i++) {
        final w = await keypair(100 + i);
        final tx = base64Encode(
          await wire(
            [createVault(w.address, kora), pay(w.address)],
            signers: [w],
          ),
        );
        final r = await call('signAndSendTransaction', {'transaction': tx});
        expect(r['error']['message'], contains('does not exist'));
      }
      expect(forwarded, isEmpty);
      expect(creates.toJson()['global'], isEmpty);
      expect(limiter.toJson()['global'], isEmpty);
    });

    test('refuses sponsor-only and admin methods', () async {
      for (final m in ['signTransaction', 'getConfig', 'transferTransaction']) {
        final r = await call(m, null);
        expect(r['error']['code'], -32601);
        expect(r['error']['message'], contains('Deadman paymaster'));
      }
    });
  });
}
