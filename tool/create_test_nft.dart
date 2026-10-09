// Devnet only: mints one classic (non-programmable) Metaplex NFT for demos
// and tests: SPL Token mint with 0 decimals, supply 1, a Token Metadata
// account (CreateMetadataAccountV3) and a master edition with max supply 0
// (CreateMasterEditionV3), which makes it a NonFungible and moves the mint
// and freeze authorities to the edition PDA. With --to, the NFT is then sent
// to that wallet. Checks the result the way the app reads it
// (DeadmanClient.fetchNftMetadata).
//
// --keypair pays everything and is the update authority; use a scratch key
// funded with `solana transfer <addr> 0.1 --allow-unfunded-recipient`.
//
// dart run tool/create_test_nft.dart --keypair <path> [--to <wallet>]
//   [--name 'Deadman Test Skull'] [--symbol DMSK] [--uri <json url>]
//   [--rpc https://api.devnet.solana.com]
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:deadman/solana/codec.dart';
import 'package:deadman/solana/deadman_client.dart';
import 'package:solana/dto.dart' show BinaryAccountData, Encoding;
import 'package:solana/encoder.dart';
import 'package:solana/solana.dart';

import 'set_config.dart' show devnetRpc, mainnetGenesis;

const _usage =
    'usage: --keypair <path> [--to <wallet>] [--name <max 32 bytes>] '
    '[--symbol <max 10 bytes>] [--uri <max 200 bytes>] [--rpc <url>]';

typedef NftArgs = ({
  String keypair,
  String? to,
  String name,
  String symbol,
  String uri,
  String rpc,
});

/// Parses the command line; throws [FormatException] with the reason.
NftArgs parseNftArgs(List<String> argv) {
  final args = <String, String>{};
  for (var i = 0; i < argv.length; i++) {
    final a = argv[i];
    if (!a.startsWith('--') || i + 1 >= argv.length) {
      throw FormatException('unexpected argument $a');
    }
    args[a.substring(2)] = argv[++i];
  }
  final keypair = args['keypair'];
  if (keypair == null) throw const FormatException('--keypair is required');
  final to = args['to'];
  if (to != null) {
    try {
      Ed25519HDPublicKey.fromBase58(to);
    } on Object {
      throw FormatException('--to $to is not a public key');
    }
  }
  final name = args['name'] ?? 'Deadman Test Skull';
  final symbol = args['symbol'] ?? 'DMSK';
  final uri = args['uri'] ?? '';
  for (final (field, value, max) in [
    ('name', name, 32),
    ('symbol', symbol, 10),
    ('uri', uri, 200),
  ]) {
    if (utf8.encode(value).length > max) {
      throw FormatException('--$field is longer than $max bytes');
    }
  }
  return (
    keypair: keypair,
    to: to,
    name: name,
    symbol: symbol,
    uri: uri,
    rpc: args['rpc'] ?? devnetRpc,
  );
}

/// Token Metadata master edition PDA: `["metadata", program, mint,
/// "edition"]`.
String editionPda(String mint) => findPda([
  utf8.encode('metadata'),
  Ed25519HDPublicKey.fromBase58(tokenMetadataProgramId).bytes,
  Ed25519HDPublicKey.fromBase58(mint).bytes,
  utf8.encode('edition'),
], programId: tokenMetadataProgramId).address;

/// `CreateMetadataAccountV3` data: tag 33, `DataV2` (no creators,
/// collection or uses, 0 royalties), `is_mutable`, no collection details.
Uint8List createMetadataV3Data({
  required String name,
  required String symbol,
  required String uri,
  bool isMutable = true,
}) {
  final b = BytesBuilder();
  void str(String s) {
    final bytes = utf8.encode(s);
    b.add(
      (ByteData(
        4,
      )..setUint32(0, bytes.length, Endian.little)).buffer.asUint8List(),
    );
    b.add(bytes);
  }

  b.addByte(33);
  str(name);
  str(symbol);
  str(uri);
  b
    ..add([0, 0]) // seller_fee_basis_points
    ..addByte(0) // creators: None
    ..addByte(0) // collection: None
    ..addByte(0) // uses: None
    ..addByte(isMutable ? 1 : 0)
    ..addByte(0); // collection_details: None
  return b.takeBytes();
}

/// `CreateMasterEditionV3` data: tag 17, `max_supply: Some(0)` (no prints).
Uint8List createMasterEditionV3Data() =>
    Uint8List.fromList([17, 1, 0, 0, 0, 0, 0, 0, 0, 0]);

AccountMeta _w(String k, {bool signer = false}) =>
    AccountMeta.writeable(pubKey: _pk(k), isSigner: signer);
AccountMeta _r(String k, {bool signer = false}) =>
    AccountMeta.readonly(pubKey: _pk(k), isSigner: signer);
Ed25519HDPublicKey _pk(String k) => Ed25519HDPublicKey.fromBase58(k);
const _rentSysvar = 'SysvarRent111111111111111111111111111111111';

/// Instructions that create the NFT [mint] held by [authority], who pays,
/// is mint, freeze and update authority until the master edition takes the
/// mint and freeze authorities.
List<Instruction> createNftIxs({
  required String authority,
  required String mint,
  required int mintRent,
  required String name,
  required String symbol,
  required String uri,
}) {
  final metadata = metadataPda(mint);
  return [
    SystemInstruction.createAccount(
      fundingAccount: _pk(authority),
      newAccount: _pk(mint),
      lamports: mintRent,
      space: TokenProgram.neededMintAccountSpace,
      owner: _pk(tokenProgramId),
    ),
    TokenInstruction.initializeMint(
      decimals: 0,
      mint: _pk(mint),
      mintAuthority: _pk(authority),
      freezeAuthority: _pk(authority),
    ),
    createAtaIdempotentIx(payer: authority, owner: authority, mint: mint),
    TokenInstruction.mintTo(
      amount: 1,
      mint: _pk(mint),
      destination: _pk(ataAddress(authority, mint)),
      authority: _pk(authority),
    ),
    Instruction(
      programId: _pk(tokenMetadataProgramId),
      accounts: [
        _w(metadata),
        _r(mint),
        _r(authority, signer: true), // mint authority
        _w(authority, signer: true), // payer
        _r(authority, signer: true), // update authority
        _r(systemProgramId),
        _r(_rentSysvar),
      ],
      data: ByteArray(
        createMetadataV3Data(name: name, symbol: symbol, uri: uri),
      ),
    ),
    Instruction(
      programId: _pk(tokenMetadataProgramId),
      accounts: [
        _w(editionPda(mint)),
        _w(mint),
        _r(authority, signer: true), // update authority
        _r(authority, signer: true), // mint authority
        _w(authority, signer: true), // payer
        _w(metadata),
        _r(tokenProgramId),
        _r(systemProgramId),
        _r(_rentSysvar),
      ],
      data: ByteArray(createMasterEditionV3Data()),
    ),
  ];
}

Future<void> main(List<String> argv) async {
  final NftArgs a;
  try {
    a = parseNftArgs(argv);
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
  if (await rpc.getGenesisHash() == mainnetGenesis) {
    stderr.writeln('devnet only: this RPC is mainnet-beta');
    exit(1);
  }
  final secret = (jsonDecode(File(a.keypair).readAsStringSync()) as List)
      .cast<int>();
  final payer = await Ed25519HDKeyPair.fromPrivateKeyBytes(
    privateKey: secret.sublist(0, 32),
  );
  final mint = await Ed25519HDKeyPair.random();
  final mintRent = await rpc.getMinimumBalanceForRentExemption(
    TokenProgram.neededMintAccountSpace,
  );

  final createSig = await sol.sendAndConfirmTransaction(
    message: Message(
      instructions: createNftIxs(
        authority: payer.address,
        mint: mint.address,
        mintRent: mintRent,
        name: a.name,
        symbol: a.symbol,
        uri: a.uri,
      ),
    ),
    signers: [payer, mint],
    commitment: Commitment.confirmed,
  );
  stdout.writeln(
    'created NFT ${mint.address}: $createSig\n'
    '  metadata ${metadataPda(mint.address)}\n'
    '  edition  ${editionPda(mint.address)}',
  );

  var holder = payer.address;
  final to = a.to;
  if (to != null) {
    final sendSig = await sol.sendAndConfirmTransaction(
      message: Message(
        instructions: [
          createAtaIdempotentIx(
            payer: payer.address,
            owner: to,
            mint: mint.address,
          ),
          transferCheckedIx(
            source: ataAddress(payer.address, mint.address),
            mint: mint.address,
            destination: ataAddress(to, mint.address),
            authority: payer.address,
            amount: 1,
            decimals: 0,
          ),
        ],
      ),
      signers: [payer],
      commitment: Commitment.confirmed,
    );
    holder = to;
    stdout.writeln('sent to $to: $sendSig');
  }

  // Read back as the app does.
  final nft = await DeadmanClient.withKora(client: sol)
      .fetchNftMetadata(mint.address);
  final held = (await rpc.getAccountInfo(
    ataAddress(holder, mint.address),
    commitment: Commitment.confirmed,
    encoding: Encoding.base64,
  )).value?.data;
  final amount = held is BinaryAccountData
      ? ByteData.sublistView(Uint8List.fromList(held.data))
            .getUint64(64, Endian.little)
      : 0;
  stdout.writeln(
    'app view: ${nft == null ? 'NOT an NFT the app lists' : '${nft.name} '
              '(${nft.symbol}), programmable=${nft.programmable}, '
              'supported=${nft.supported}, uri=${nft.uri ?? '-'}, '
              'image=${nft.imageUrl ?? '-'}'}\n'
    '$holder holds $amount',
  );
  if (nft == null || !nft.supported || amount != 1) exit(1);
  stdout.writeln('NFT_MINT=${mint.address}');
}
