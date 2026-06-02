import 'dart:convert';
import 'dart:typed_data';

import 'package:solana/dto.dart'
    show
        Account,
        BinaryAccountData,
        Commitment,
        Encoding,
        FutureContextResultExt,
        ProgramDataFilter;
import 'package:solana/encoder.dart';
import 'package:solana/solana.dart';

import '../core/config.dart';
import 'codec.dart';
import 'deadman_api.dart';

/// Failed RPC call or transaction. [name] is set for Deadman program errors
/// (e.g. `StillAlive`, `VaultLocked`) and [message] is then user-readable.
class DeadmanException implements Exception {
  const DeadmanException(
    this.message, {
    this.code,
    this.name,
    this.logs = const [],
  });

  factory DeadmanException.fromRpc(JsonRpcException e) {
    final data = e.data;
    final logs = data is Map && data['logs'] is List
        ? [for (final l in data['logs'] as List) '$l']
        : const <String>[];
    return DeadmanException.fromTxError(
      data is Map ? data['err'] : null,
      logs: logs,
      fallback: e.message,
    );
  }

  factory DeadmanException.fromTxError(
    Object? err, {
    List<String> logs = const [],
    String? fallback,
  }) {
    final code = _customCode(err);
    final known = programErrors[code];
    return DeadmanException(
      known?.$2 ?? fallback ?? 'Transaction failed: $err',
      code: code,
      name: known?.$1,
      logs: logs,
    );
  }

  final String message;

  /// `Custom` instruction error code, if any (Deadman errors are 6000+).
  final int? code;
  final String? name;
  final List<String> logs;

  static const programErrors = <int, (String, String)>{
    6000: ('Unauthorized', 'Signer is not allowed to perform this action'),
    6001: ('FeeTooHigh', 'Fee exceeds the 1% cap'),
    6002: ('InvalidDuration', 'Interval, grace or lock duration out of range'),
    6003: (
      'InvalidHeirs',
      'Heirs must be unique, non-empty and sum to 10000 bps',
    ),
    6004: ('TooManyHeirs', 'Too many heirs for this plan'),
    6005: ('PlusRequired', 'A guardian requires Deadman Plus'),
    6006: (
      'InvalidGuardian',
      'Guardian cannot be the owner, the guard key or an heir',
    ),
    6007: ('VaultLocked', 'Vault is locked down'),
    6008: ('VaultNotActive', 'Vault is not active'),
    6009: ('VaultNotTriggered', 'Vault has not been triggered'),
    6010: ('StillAlive', 'The owner is still within the heartbeat window'),
    6011: ('NotAnHeir', 'Signer is not an heir of this vault'),
    6012: ('AlreadyClaimed', 'Share already claimed'),
    6013: ('InsufficientFunds', 'Amount exceeds the withdrawable balance'),
    6014: ('InvalidMonths', 'Subscription months out of range'),
    6015: (
      'InvalidGuard',
      'Guard key must differ from the owner, heirs and guardian',
    ),
    6016: ('NoGuardian', 'Vault has no guardian'),
    6017: ('MathOverflow', 'Arithmetic overflow'),
    6018: ('InvalidConfig', 'Treasury and SKR mint must be set'),
  };

  static int? _customCode(Object? err) {
    if (err is! Map) return null;
    final ie = err['InstructionError'];
    if (ie is List && ie.length == 2 && ie[1] is Map) {
      final custom = (ie[1] as Map)['Custom'];
      if (custom is int) return custom;
    }
    return null;
  }

  @override
  String toString() => 'DeadmanException(${name ?? code ?? '-'}): $message';
}

class DeadmanClient implements DeadmanApi {
  DeadmanClient([SolanaClient? client])
    : _client =
          client ??
          SolanaClient(
            rpcUrl: Uri.parse(AppConfig.rpcUrl),
            websocketUrl: Uri.parse(AppConfig.wsUrl),
          );

  static const commitment = Commitment.confirmed;
  static const confirmTimeout = Duration(seconds: 60);
  static const _pollInterval = Duration(milliseconds: 800);

  final SolanaClient _client;
  final _program = Ed25519HDPublicKey.fromBase58(AppConfig.programId);
  final _vaultAddresses = <String, String>{};
  final _rent = <int, int>{};

  RpcClient get _rpc => _client.rpcClient;

  @override
  String vaultAddressFor(String owner) =>
      _vaultAddresses[owner] ??= vaultPda(owner).address;

  @override
  Future<VaultState?> fetchVault(String owner) async {
    final address = vaultAddressFor(owner);
    final account = await _rpc
        .getAccountInfo(
          address,
          commitment: commitment,
          encoding: Encoding.base64,
        )
        .value;
    return account == null ? null : _decodeVault(address, account);
  }

  @override
  Future<List<VaultState>> fetchWatchedVaults(String wallet) async {
    // Scans every Vault and filters client-side; fine on devnet, needs an
    // indexer on mainnet (heirs sit after a variable-length Option).
    final accounts = await _rpc.getProgramAccounts(
      AppConfig.programId,
      commitment: commitment,
      encoding: Encoding.base64,
      filters: [ProgramDataFilter.memcmp(offset: 0, bytes: Disc.vaultAccount)],
    );
    final vaults = <VaultState>[];
    for (final pa in accounts) {
      final VaultState? v;
      try {
        v = await _decodeVault(pa.pubkey, pa.account);
      } on FormatException {
        continue;
      }
      if (v != null &&
          (v.guardian == wallet || v.heirs.any((h) => h.wallet == wallet))) {
        vaults.add(v);
      }
    }
    return vaults;
  }

  @override
  Future<int> balance(String address) =>
      _rpc.getBalance(address, commitment: commitment).value;

  /// On-chain Config (treasury, SKR mint, Plus price, fee).
  Future<DeadmanConfig> fetchConfig() async {
    final account = await _rpc
        .getAccountInfo(
          configPda().address,
          commitment: commitment,
          encoding: Encoding.base64,
        )
        .value;
    final data = account?.data;
    if (account == null ||
        account.owner != AppConfig.programId ||
        data is! BinaryAccountData) {
      throw const DeadmanException('Deadman config account not found');
    }
    return decodeConfig(data.data);
  }

  @override
  Future<Uint8List> buildCreateVault({
    required String owner,
    required String guard,
    required int intervalSecs,
    required int graceSecs,
    required int lockSecs,
    required List<Heir> heirs,
    int depositLamports = 0,
  }) {
    _checkLamports(depositLamports);
    final vault = vaultAddressFor(owner);
    return _build(owner, [
      SystemInstruction.transfer(
        fundingAccount: _pk(owner),
        recipientAccount: _pk(guard),
        lamports: AppConfig.guardFundingLamports,
      ),
      _ix(
        [_w(owner, signer: true), _w(vault), _r(SystemProgram.programId)],
        encodeCreateVault(
          guard: guard,
          intervalSecs: intervalSecs,
          graceSecs: graceSecs,
          lockSecs: lockSecs,
          heirs: heirs,
        ),
      ),
      if (depositLamports > 0)
        SystemInstruction.transfer(
          fundingAccount: _pk(owner),
          recipientAccount: _pk(vault),
          lamports: depositLamports,
        ),
    ]);
  }

  @override
  Future<Uint8List> buildDeposit({
    required String owner,
    required int lamports,
  }) {
    _checkLamports(lamports);
    return _build(owner, [
      SystemInstruction.transfer(
        fundingAccount: _pk(owner),
        recipientAccount: _pk(vaultAddressFor(owner)),
        lamports: lamports,
      ),
    ]);
  }

  @override
  Future<Uint8List> buildWithdrawSol({
    required String owner,
    required int lamports,
  }) {
    _checkLamports(lamports);
    return _ownerAction(owner, encodeWithdrawSol(lamports));
  }

  @override
  Future<Uint8List> buildUpdatePolicy({
    required String owner,
    required int intervalSecs,
    required int graceSecs,
    required int lockSecs,
    required List<Heir> heirs,
    String? guardian,
  }) => _ownerAction(
    owner,
    encodeUpdatePolicy(
      intervalSecs: intervalSecs,
      graceSecs: graceSecs,
      lockSecs: lockSecs,
      heirs: heirs,
      guardian: guardian,
    ),
  );

  @override
  Future<Uint8List> buildSetGuard({
    required String owner,
    required String newGuard,
  }) => _ownerAction(owner, encodeSetGuard(newGuard));

  @override
  Future<Uint8List> buildSubscribe({
    required String owner,
    required int months,
  }) async {
    if (months < 1 || months > 12) {
      throw ArgumentError.value(months, 'months', 'must be 1..12');
    }
    final config = await fetchConfig();
    final mint = AppConfig.skrMint.isNotEmpty
        ? AppConfig.skrMint
        : config.skrMint;
    final ownerSkr = await findAssociatedTokenAddress(
      owner: _pk(owner),
      mint: _pk(mint),
    );
    final treasurySkr = await findAssociatedTokenAddress(
      owner: _pk(config.treasury),
      mint: _pk(mint),
    );
    return _build(owner, [
      _ix([
        _w(owner, signer: true),
        _w(vaultAddressFor(owner)),
        _r(configPda().address),
        _r(mint),
        AccountMeta.writeable(pubKey: ownerSkr, isSigner: false),
        AccountMeta.writeable(pubKey: treasurySkr, isSigner: false),
        _r(TokenProgram.programId),
      ], encodeSubscribe(months)),
    ]);
  }

  @override
  Future<Uint8List> buildPulseByOwner({required String owner}) =>
      _build(owner, [
        _ix([_r(owner, signer: true), _w(vaultAddressFor(owner))], Disc.pulse),
      ]);

  @override
  Future<Uint8List> buildTrigger({
    required String caller,
    required String vaultOwner,
  }) => _build(caller, [
    _ix([
      _r(caller, signer: true),
      _w(vaultAddressFor(vaultOwner)),
    ], Disc.trigger),
  ]);

  @override
  Future<Uint8List> buildClaimSol({
    required String heir,
    required String vaultOwner,
  }) async {
    final config = await fetchConfig();
    return _build(heir, [
      _ix([
        _w(heir, signer: true),
        _w(vaultAddressFor(vaultOwner)),
        _r(configPda().address),
        _w(config.treasury),
      ], Disc.claimSol),
    ]);
  }

  @override
  Future<Uint8List> buildCloseVault({required String owner}) =>
      _ownerAction(owner, Disc.closeVault);

  @override
  Future<String> pulseWithGuard(
    Ed25519HDKeyPair guard, {
    required String vaultOwner,
  }) => _sendWithGuard(guard, vaultOwner, Disc.pulse);

  @override
  Future<String> lockdownWithGuard(
    Ed25519HDKeyPair guard, {
    required String vaultOwner,
  }) => _sendWithGuard(guard, vaultOwner, Disc.lockdown);

  @override
  Future<List<String>> sendSigned(List<Uint8List> signedTransactions) async {
    final signatures = [
      for (final tx in signedTransactions) await _send(base64Encode(tx)),
    ];
    await _confirm(signatures);
    return signatures;
  }

  Future<VaultState?> _decodeVault(String address, Account account) async {
    final data = account.data;
    if (account.owner != AppConfig.programId ||
        data is! BinaryAccountData ||
        !hasDiscriminator(data.data, Disc.vaultAccount)) {
      return null;
    }
    final len = data.data.length;
    final rent = _rent[len] ??= await _rpc.getMinimumBalanceForRentExemption(
      len,
      commitment: commitment,
    );
    return decodeVault(
      data.data,
      address: address,
      lamports: account.lamports,
      rentExemptMinimum: rent,
    );
  }

  Future<Uint8List> _ownerAction(String owner, List<int> data) =>
      _build(owner, [
        _ix([_w(owner, signer: true), _w(vaultAddressFor(owner))], data),
      ]);

  Future<Uint8List> _build(
    String feePayer,
    List<Instruction> instructions,
  ) async {
    final bh = await _rpc.getLatestBlockhash(commitment: commitment).value;
    return serializeUnsigned(
      instructions,
      feePayer: feePayer,
      recentBlockhash: bh.blockhash,
    );
  }

  Future<String> _sendWithGuard(
    Ed25519HDKeyPair guard,
    String vaultOwner,
    List<int> data,
  ) async {
    final ix = _ix([
      AccountMeta.readonly(pubKey: guard.publicKey, isSigner: true),
      _w(vaultAddressFor(vaultOwner)),
    ], data);
    final bh = await _rpc.getLatestBlockhash(commitment: commitment).value;
    final tx = await signTransaction(bh, Message.only(ix), [guard]);
    final signature = await _send(tx.encode());
    await _confirm([signature]);
    return signature;
  }

  Future<String> _send(String base64Tx) async {
    try {
      return await _rpc.sendTransaction(
        base64Tx,
        preflightCommitment: commitment,
      );
    } on JsonRpcException catch (e) {
      throw DeadmanException.fromRpc(e);
    }
  }

  Future<void> _confirm(List<String> signatures) async {
    final deadline = DateTime.now().add(confirmTimeout);
    final pending = [...signatures];
    while (pending.isNotEmpty) {
      final statuses = await _rpc.getSignatureStatuses(pending).value;
      final done = <String>[];
      for (var i = 0; i < pending.length; i++) {
        final s = statuses[i];
        if (s == null) continue;
        if (s.err != null) throw DeadmanException.fromTxError(s.err);
        if (s.confirmationStatus != Commitment.processed) done.add(pending[i]);
      }
      pending.removeWhere(done.contains);
      if (pending.isEmpty) return;
      if (DateTime.now().isAfter(deadline)) {
        throw DeadmanException(
          'Transaction ${pending.first} not confirmed in time',
        );
      }
      await Future<void>.delayed(_pollInterval);
    }
  }

  Instruction _ix(List<AccountMeta> accounts, List<int> data) => Instruction(
    programId: _program,
    accounts: accounts,
    data: ByteArray(data),
  );

  static Ed25519HDPublicKey _pk(String address) =>
      Ed25519HDPublicKey.fromBase58(address);

  static AccountMeta _w(String address, {bool signer = false}) =>
      AccountMeta.writeable(pubKey: _pk(address), isSigner: signer);

  static AccountMeta _r(String address, {bool signer = false}) =>
      AccountMeta.readonly(pubKey: _pk(address), isSigner: signer);

  static void _checkLamports(int lamports) {
    if (lamports < 0) {
      throw ArgumentError.value(lamports, 'lamports', 'must be >= 0');
    }
  }
}
