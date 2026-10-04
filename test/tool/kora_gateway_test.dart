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

    test('routes each tier to its own Kora node', () async {
      final route = PaymasterRoute(
        policy: pmPolicy,
        limiter: UsageLimiter(perVault: 0, perSigner: 9, global: 9),
        creates: UsageLimiter(perVault: 0, perSigner: 9, global: 9),
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
      final route = PaymasterRoute(
        policy: pmPolicy,
        limiter: UsageLimiter(perVault: 0, perSigner: 60, clock: () => 5000),
        creates: UsageLimiter(
          perVault: 0,
          perSigner: 1,
          clock: () => 5000,
          signerLabel: 'owner',
          unit: 'paymaster-funded vaults',
        ),
      );
      final create = await wire(
        [createVault(owner.address, kora), pay(owner.address)],
        signers: [owner],
      );
      expect(await route.admit(create), contains('tier=plan'));
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
      expect(await route.admit(deposit), contains('tier=basic'));
    });

    test('rejects an unsigned transaction before counting it', () async {
      final limiter = UsageLimiter(perVault: 0, perSigner: 1);
      final route = PaymasterRoute(
        policy: pmPolicy,
        limiter: limiter,
        creates: UsageLimiter(perVault: 0),
      );
      final tx = await wire([pay(owner.address)]);
      await expectLater(route.admit(tx), rejects('Invalid owner signature'));
      expect(limiter.toJson()['global'], isEmpty);
    });

    test('estimates reject an unknown fee_token', () {
      final tx = base64Encode(Uint8List(0));
      expect(
        () => PaymasterRoute(
          policy: pmPolicy,
          limiter: UsageLimiter(),
          creates: UsageLimiter(),
        ).admitEstimate(tx, key(50)),
        rejects('fee_token must be one of'),
      );
    });
  });

  group('paymaster over HTTP', () {
    late HttpServer upstream;
    late HttpServer server;
    late List<Map<String, dynamic>> forwarded;

    setUp(() async {
      forwarded = [];
      upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      upstream.listen((req) async {
        final body =
            jsonDecode(await utf8.decodeStream(req)) as Map<String, dynamic>;
        forwarded.add(body);
        req.response
          ..headers.contentType = ContentType.json
          ..write(
            jsonEncode({
              'jsonrpc': '2.0',
              'id': body['id'],
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
          limiter: UsageLimiter(perVault: 0),
          creates: UsageLimiter(perVault: 0),
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

    test('refuses sponsor-only and admin methods', () async {
      for (final m in ['signTransaction', 'getConfig', 'transferTransaction']) {
        final r = await call(m, null);
        expect(r['error']['code'], -32601);
        expect(r['error']['message'], contains('Deadman paymaster'));
      }
    });
  });
}
