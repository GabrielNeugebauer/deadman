import 'dart:convert';
import 'dart:typed_data';

import 'package:deadman/core/config.dart';
import 'package:deadman/solana/codec.dart';
import 'package:deadman/solana/deadman_api.dart';
import 'package:deadman/solana/deadman_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:solana/encoder.dart';
import 'package:solana/solana.dart' show Ed25519HDPublicKey;

import 'helpers.dart';

void main() {
  final owner = key(1);
  final usdc = key(6);
  final treasury = key(7);
  const skr = AppConfig.skrMint;
  const now = 1790500000;
  const price = 50000000; // 50 SKR per period

  late FakeRpc rpc;
  late DeadmanClient client;

  void addTokens(String holder, String mint, int amount, {int state = 1}) =>
      rpc.accounts[ataAddress(holder, mint)] = FakeAccount(
        tokenProgramId,
        tokenAccountWithState(
          mint: mint,
          owner: holder,
          amount: amount,
          state: state,
        ),
      );

  List<Instruction> instructions(Uint8List tx) =>
      Message.decompile(SignedTx.fromBytes(tx).compiledMessage).instructions;

  List<String> addrs(Instruction ix) => [
    for (final a in ix.accounts) a.pubKey.toBase58(),
  ];

  Matcher throwsNamed(String name, [Pattern words = '']) => throwsA(
    isA<DeadmanException>()
        .having((e) => e.name, 'name', name)
        .having((e) => e.message, 'message', contains(words)),
  );

  setUp(() async {
    rpc = await FakeRpc.start();
    client = DeadmanClient.withKora(client: rpc.client(), clock: () => now);
    rpc.accounts
      ..[configPda().address] = FakeAccount(
        AppConfig.programId,
        configBytes(admin: owner, treasury: treasury),
      )
      ..[usdc] = FakeAccount(tokenProgramId, mintBytes(6))
      ..[skr] = FakeAccount(tokenProgramId, mintBytes(6));
  });

  tearDown(() => rpc.close());

  group('SKR payouts', () {
    final alice = key(3);
    const day = 86400;

    test('the metadata PDA matches the async derivation', () async {
      final metadata = Ed25519HDPublicKey.fromBase58(tokenMetadataProgramId);
      final meta = await Ed25519HDPublicKey.findProgramAddress(
        seeds: [utf8.encode('metadata'), metadata.bytes, keyBytes(skr)],
        programId: metadata,
      );
      expect(metadataPda(skr), meta.toBase58());
    });

    test('an SKR vesting release: writable mint for the burn, treasury '
        'ATA for the rest, 1.5% fee', () async {
      rpc.accounts[configPda().address] = FakeAccount(
        AppConfig.programId,
        configBytes(admin: owner, treasury: treasury, skrMint: skr),
      );
      final v = vaultPda(owner, 3).address;
      rpc.accounts[v] = FakeAccount(
        AppConfig.programId,
        vaultBytes(
          owner: owner,
          planId: 3,
          guard: key(2),
          kind: PlanKind.vesting,
          startAt: now - 400 * day,
          rules: [
            RuleState(
              beneficiary: alice,
              rail: Rail.cloak,
              afterSecs: 0,
              mint: skr,
              mode: AmountMode.fixed,
              amount: price,
              executedAt: 0,
              paid: 0,
              durationSecs: 365 * day,
            ),
          ],
        ),
      );
      addTokens(v, skr, price);
      final ixs = instructions(
        await client.buildReleaseVested(
          executor: alice,
          vaultOwner: owner,
          planId: 3,
          index: 0,
        ),
      );
      expect(ixs, hasLength(3));
      expect(addrs(ixs[0])[1], ataAddress(treasury, skr));
      final release = ixs[2];
      expect(release.data.toList(), [...Disc.releaseVestedToken, 0]);
      expect(release.accounts[3].pubKey.toBase58(), skr);
      expect(release.accounts[3].isWriteable, isTrue);
      expect(addrs(release)[7], ataAddress(treasury, skr));
      final quote = await client.quoteClaim(
        claimer: alice,
        vaultOwner: owner,
        planId: 3,
        index: 0,
      );
      expect(quote.net, price - price * 150 ~/ 10000);
    });
  });

  group('NFTs', () {
    final classic = key(50);
    final pnft = key(51);
    final legacy = key(52);
    final fungible = key(53);
    final edition = key(54);
    final semi = key(55);
    final bare = key(56);
    final staked = key(57);

    void nft(
      String mint, {
      int? standard = 0,
      bool legacyLayout = false,
      int supply = 1,
      int decimals = 0,
      String? uri,
      bool metadata = true,
    }) {
      rpc.accounts[mint] = FakeAccount(
        tokenProgramId,
        mintWithSupply(decimals, supply),
      );
      if (metadata) {
        rpc.accounts[metadataPda(mint)] = FakeAccount(
          tokenMetadataProgramId,
          metadataBytes(
            mint: mint,
            name: 'NFT ${mint.substring(0, 3)}',
            uri: uri ?? 'https://example.com/$mint.json',
            tokenStandard: standard,
            legacy: legacyLayout,
          ),
        );
      }
    }

    http.Client images(Map<String, Object> answers, {List<Uri>? seen}) =>
        MockClient((req) async {
          seen?.add(req.url);
          final a = answers[req.url.toString()];
          if (a is Duration) {
            await Future<void>.delayed(a);
            return http.Response('{}', 200);
          }
          if (a is http.Response) return a;
          if (a == null) return http.Response('nope', 404);
          return http.Response(jsonEncode(a), 200);
        });

    test('decodeMetadata: name, symbol, uri and token standard; legacy '
        'accounts have none', () {
      final m = decodeMetadata(
        metadataBytes(mint: classic, tokenStandard: 4, creators: 3),
      );
      expect(m.mint, classic);
      expect(m.name, 'Boney #1');
      expect(m.symbol, 'BONE');
      expect(m.uri, 'https://example.com/1.json');
      expect(m.tokenStandard, TokenStandard.programmableNonFungible);
      expect(isProgrammable(m.tokenStandard), isTrue);
      final old = decodeMetadata(
        metadataBytes(mint: classic, legacy: true, creators: 0),
      );
      expect(old.tokenStandard, isNull);
      expect(old.name, 'Boney #1');
      expect(
        decodeMetadata(metadataBytes(mint: classic, tokenStandard: null))
            .tokenStandard,
        isNull,
      );
      expect(() => decodeMetadata(mintBytes(0)), throwsFormatException);
    });

    test('fetchWalletNfts lists classic NFTs, flags pNFTs and frozen ones, '
        'and skips everything else', () async {
      nft(classic);
      nft(pnft, standard: 4);
      nft(legacy, standard: null, legacyLayout: true);
      nft(fungible, standard: 2);
      nft(edition, standard: 3);
      nft(semi, supply: 5);
      nft(bare, metadata: false);
      nft(staked);
      rpc.tokenAccountsByOwner[owner] = [
        FakeTokenAccount(classic),
        FakeTokenAccount(pnft, frozen: true),
        FakeTokenAccount(legacy, address: key(90)),
        FakeTokenAccount(fungible),
        FakeTokenAccount(edition),
        FakeTokenAccount(semi),
        FakeTokenAccount(bare),
        FakeTokenAccount(staked, frozen: true),
        FakeTokenAccount(usdc, amount: 1, decimals: 6),
        FakeTokenAccount(key(58), amount: 0),
        FakeTokenAccount(key(59), amount: 2),
      ];
      final c = DeadmanClient.withKora(
        client: rpc.client(),
        clock: () => now,
        metadataHttp: images({}),
      );
      final nfts = await c.fetchWalletNfts(owner);
      expect(
        {for (final n in nfts) n.mint},
        {classic, pnft, legacy, edition, staked},
      );
      final byMint = {for (final n in nfts) n.mint: n};
      expect(byMint[classic]!.supported, isTrue);
      expect(byMint[classic]!.name, 'NFT ${classic.substring(0, 3)}');
      expect(byMint[classic]!.symbol, 'BONE');
      expect(byMint[classic]!.uri, 'https://example.com/$classic.json');
      expect(byMint[pnft]!.programmable, isTrue);
      expect(byMint[pnft]!.supported, isFalse);
      expect(byMint[legacy]!.supported, isTrue);
      expect(byMint[edition]!.supported, isTrue);
      expect(byMint[staked]!.frozen, isTrue);
      expect(byMint[staked]!.supported, isFalse);
      expect(rpc.tokenAccountQueries.single[1], {'programId': tokenProgramId});
      expect(
        (rpc.tokenAccountQueries.single[2] as Map)['encoding'],
        'jsonParsed',
      );
      expect(await c.fetchWalletNfts(key(60)), isEmpty);
    });

    test('images: http(s) JSON only, slow, large or broken links leave '
        'the image null', () async {
      final ok = key(61);
      final slow = key(62);
      final big = key(63);
      final ipfs = key(64);
      final badImage = key(65);
      final broken = key(66);
      for (final m in [ok, slow, big, badImage, broken]) {
        nft(m);
      }
      nft(ipfs, uri: 'ipfs://bafy/1.json');
      rpc.tokenAccountsByOwner[owner] = [
        for (final m in [ok, slow, big, ipfs, badImage, broken])
          FakeTokenAccount(m),
      ];
      final seen = <Uri>[];
      final c = DeadmanClient.withKora(
        client: rpc.client(),
        clock: () => now,
        metadataHttp: images({
          'https://example.com/$ok.json': {
            'name': 'x',
            'image': 'https://img.example.com/ok.png',
          },
          'https://example.com/$slow.json': const Duration(seconds: 10),
          'https://example.com/$big.json': http.Response(
            '{"image":"https://img.example.com/big.png","pad":"'
            '${'x' * DeadmanClient.nftJsonMaxBytes}"}',
            200,
          ),
          'https://example.com/$badImage.json': {
            'image': 'javascript:alert(1)',
          },
          'https://example.com/$broken.json': http.Response('{nope', 200),
        }, seen: seen),
      );
      final started = DateTime.now();
      final nfts = {for (final n in await c.fetchWalletNfts(owner)) n.mint: n};
      expect(
        DateTime.now().difference(started),
        lessThan(DeadmanClient.nftJsonTimeout + const Duration(seconds: 2)),
      );
      expect(nfts, hasLength(6));
      expect(nfts[ok]!.imageUrl, 'https://img.example.com/ok.png');
      for (final m in [slow, big, ipfs, badImage, broken]) {
        expect(nfts[m]!.imageUrl, isNull, reason: m);
      }
      expect(seen.map((u) => u.scheme).toSet(), {
        'https',
      }, reason: 'ipfs:// is never fetched');
    });

    test(
      'fetchNftMetadata: one NFT, or null for a token or no metadata',
      () async {
        nft(classic);
        nft(semi, supply: 2);
        nft(bare, metadata: false);
        final c = DeadmanClient.withKora(
          client: rpc.client(),
          clock: () => now,
          metadataHttp: images({
            'https://example.com/$classic.json': {
              'image': 'https://img.example.com/c.png',
            },
          }),
        );
        final n = await c.fetchNftMetadata(classic);
        expect(n!.mint, classic);
        expect(n.imageUrl, 'https://img.example.com/c.png');
        expect(await c.fetchNftMetadata(semi), isNull);
        expect(await c.fetchNftMetadata(bare), isNull);
        expect(await c.fetchNftMetadata(usdc), isNull);
      },
    );

    test('depositing an NFT moves exactly 1 with 0 decimals', () async {
      nft(classic);
      addTokens(owner, classic, 1);
      final ixs = instructions(
        await client.buildDepositToken(
          owner: owner,
          planId: 0,
          mint: classic,
          amount: 1,
        ),
      );
      expect(ixs, hasLength(2));
      expect(ixs[0].programId.toBase58(), ataProgramId);
      expect(addrs(ixs[1]), [
        ataAddress(owner, classic),
        classic,
        ataAddress(vaultPda(owner, 0).address, classic),
        owner,
      ]);
      expect(ixs[1].data.toList(), [12, ...le(8, 1), 0]);
    });

    test('an NFT deposit is refused before signing when frozen, missing or '
        'not in the main token account', () async {
      nft(pnft, standard: 4);
      Future<Uint8List> deposit() => client.buildDepositToken(
        owner: owner,
        planId: 0,
        mint: pnft,
        amount: 1,
      );
      await expectLater(deposit(), throwsNamed('NoTokenAccount'));
      addTokens(owner, pnft, 0);
      await expectLater(deposit(), throwsNamed('InsufficientTokens'));
      addTokens(owner, pnft, 1, state: 2);
      await expectLater(
        deposit(),
        throwsNamed('TokenFrozen', 'Programmable NFTs cannot'),
      );
      await expectLater(
        client.buildCreateVault(
          owner: owner,
          planId: 0,
          label: 'Art',
          guard: key(2),
          lockSecs: 3600,
          skipGraceSecs: 30 * 86400,
          rules: [
            RuleSpec(
              beneficiary: key(3),
              rail: Rail.solana,
              afterSecs: 86400,
              mode: AmountMode.fixed,
              amount: 1,
              mint: pnft,
            ),
          ],
          tokenDeposits: {pnft: 1},
        ),
        throwsNamed('TokenFrozen'),
      );
      expect(rpc.sent, isEmpty);
    });
  });
}
