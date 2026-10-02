import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:solana/dto.dart'
    show
        Account,
        BinaryAccountData,
        Commitment,
        Encoding,
        FutureContextResultExt,
        ProgramDataFilter;
import 'package:http/http.dart' show ClientException;
import 'package:solana/encoder.dart';
import 'package:solana/solana.dart';

import '../core/config.dart';
import 'codec.dart';
import 'deadman_api.dart';

/// Failed RPC call or transaction. [name] is set for Deadman program errors
/// (e.g. `RuleNotDue`, `VaultLocked`) and [message] is then user-readable.
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

  /// A Deadman program error raised client-side, before sending.
  factory DeadmanException.program(int code) {
    final known = programErrors[code];
    return DeadmanException(
      known?.$2 ?? 'Program error $code',
      code: code,
      name: known?.$1,
    );
  }

  final String message;

  /// `Custom` instruction error code, if any (Deadman errors are 6000+).
  final int? code;
  final String? name;
  final List<String> logs;

  /// From `onchain/target/idl/deadman.json`.
  static const programErrors = <int, (String, String)>{
    6000: ('Unauthorized', 'Signer is not allowed to perform this action'),
    6001: ('FeeTooHigh', 'Fee exceeds the 5% cap'),
    6002: ('InvalidDuration', 'Interval or lock duration out of range'),
    6003: (
      'InvalidRules',
      'Rules must be 1-8, sorted by delay, with valid amounts and beneficiaries',
    ),
    6004: (
      'InvalidGuardian',
      'Guardian cannot be the owner, the guard key or a beneficiary',
    ),
    6005: (
      'InvalidGuard',
      'Guard key must differ from the owner, beneficiaries and guardian',
    ),
    6006: ('VaultLocked', 'Vault is locked down'),
    6007: (
      'RuleNotDue',
      "The owner is still within this rule's inactivity window",
    ),
    6008: ('RuleAlreadyExecuted', 'Rule already executed'),
    6009: (
      'RuleOutOfOrder',
      'An earlier rule for the same asset must execute first',
    ),
    6010: ('WrongAsset', 'Rule asset does not match this instruction or mint'),
    6011: ('InvalidRuleIndex', 'Rule index out of range'),
    6012: ('InsufficientFunds', 'Amount exceeds the withdrawable balance'),
    6013: ('NoGuardian', 'Vault has no guardian'),
    6014: ('GuardianCooldown', 'Guardian lockdown is cooling down'),
    6015: ('InvalidConfig', 'Treasury must be set'),
    6016: ('MathOverflow', 'Arithmetic overflow'),
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
  static const blockhashRetries = 8;

  final SolanaClient _client;
  final _rent = <int, int>{};

  RpcClient get _rpc => _client.rpcClient;

  @override
  String vaultAddressFor(String owner) => vaultPda(owner).address;

  @override
  Future<VaultState?> fetchVault(String owner) async {
    final address = vaultAddressFor(owner);
    final account = await _account(address);
    return account == null ? null : _decodeVault(address, account);
  }

  @override
  Future<List<VaultState>> fetchAllVaults() async {
    // Scans every Vault; fine on devnet, needs an indexer on mainnet
    // (rules sit after a variable-length Option, so memcmp can't target them).
    final accounts = await _net(
      () => _rpc.getProgramAccounts(
        AppConfig.programId,
        commitment: commitment,
        encoding: Encoding.base64,
        filters: [
          ProgramDataFilter.memcmp(offset: 0, bytes: Disc.vaultAccount),
        ],
      ),
    );
    final vaults = <VaultState>[];
    for (final pa in accounts) {
      try {
        final v = await _decodeVault(pa.pubkey, pa.account);
        if (v != null) vaults.add(v);
      } on FormatException {
        continue;
      }
    }
    return vaults;
  }

  @override
  Future<List<VaultState>> fetchWatchedVaults(String wallet) async => [
    for (final v in await fetchAllVaults())
      if (v.guardian == wallet || v.rules.any((r) => r.beneficiary == wallet))
        v,
  ];

  /// On-chain Config (admin and fee schedule).
  Future<DeadmanConfig> fetchConfig() async {
    final data = _programData(await _account(configPda().address));
    if (data == null) {
      throw const DeadmanException('Deadman config account not found');
    }
    return decodeConfig(data);
  }

  @override
  Future<FeeSchedule> fetchFees() async => (await fetchConfig()).fees;

  @override
  Future<int> balance(String address) =>
      _net(() => _rpc.getBalance(address, commitment: commitment).value);

  @override
  Future<int> tokenBalance(String owner, String mint) async {
    final data = (await _account(ataAddress(owner, mint)))?.data;
    return data is BinaryAccountData ? decodeTokenAmount(data.data) : 0;
  }

  @override
  Future<Uint8List> buildCreateVault({
    required String owner,
    required String guard,
    required int intervalSecs,
    required int lockSecs,
    required List<RuleSpec> rules,
    int depositLamports = 0,
  }) async {
    _checkAmount(depositLamports);
    if (guard == owner || guard == defaultPubkey) {
      throw DeadmanException.program(6005);
    }
    _checkPolicy(
      owner: owner,
      guard: guard,
      intervalSecs: intervalSecs,
      lockSecs: lockSecs,
      rules: rules,
    );
    final vault = vaultAddressFor(owner);
    return _build(owner, [
      SystemInstruction.transfer(
        fundingAccount: _pk(owner),
        recipientAccount: _pk(guard),
        lamports: AppConfig.guardFundingLamports,
      ),
      deadmanIx(
        [
          AccountMeta.writeable(pubKey: _pk(owner), isSigner: true),
          AccountMeta.writeable(pubKey: _pk(vault), isSigner: false),
          AccountMeta.readonly(pubKey: _pk(systemProgramId), isSigner: false),
        ],
        encodeCreateVault(
          guard: guard,
          intervalSecs: intervalSecs,
          lockSecs: lockSecs,
          rules: rules,
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
  }) async {
    _checkAmount(lamports);
    return _build(owner, [
      SystemInstruction.transfer(
        fundingAccount: _pk(owner),
        recipientAccount: _pk(vaultAddressFor(owner)),
        lamports: lamports,
      ),
    ]);
  }

  @override
  Future<Uint8List> buildDepositToken({
    required String owner,
    required String mint,
    required int amount,
  }) async {
    _checkAmount(amount);
    final decimals = await _mintDecimals(mint);
    return _build(
      owner,
      depositTokenIxs(
        owner: owner,
        mint: mint,
        amount: amount,
        decimals: decimals,
      ),
    );
  }

  @override
  Future<Uint8List> buildWithdrawSol({
    required String owner,
    required int lamports,
  }) async {
    _checkAmount(lamports);
    return _build(owner, [ownerActionIx(owner, encodeWithdrawSol(lamports))]);
  }

  @override
  Future<Uint8List> buildWithdrawToken({
    required String owner,
    required String mint,
    required int amount,
  }) async {
    _checkAmount(amount);
    return _build(
      owner,
      withdrawTokenIxs(owner: owner, mint: mint, amount: amount),
    );
  }

  @override
  Future<Uint8List> buildUpdatePolicy({
    required String owner,
    required int intervalSecs,
    required int lockSecs,
    required List<RuleSpec> rules,
    String? guardian,
  }) async {
    _checkPolicy(
      owner: owner,
      intervalSecs: intervalSecs,
      lockSecs: lockSecs,
      rules: rules,
      guardian: guardian,
    );
    return _build(owner, [
      ownerActionIx(
        owner,
        encodeUpdatePolicy(
          intervalSecs: intervalSecs,
          lockSecs: lockSecs,
          rules: rules,
          guardian: guardian,
        ),
      ),
    ]);
  }

  @override
  Future<Uint8List> buildSetGuard({
    required String owner,
    required String newGuard,
  }) => _build(owner, [ownerActionIx(owner, encodeSetGuard(newGuard))]);

  @override
  Future<Uint8List> buildPulseByOwner({required String owner}) => _build(
    owner,
    [pulseOrLockdownIx(signer: owner, vaultOwner: owner, lockdown: false)],
  );

  @override
  Future<Uint8List> buildExecuteRule({
    required String executor,
    required String vaultOwner,
    required int index,
  }) async =>
      _build(executor, await _executeRuleIxs(executor, vaultOwner, index));

  @override
  Future<Uint8List> buildCloseVault({required String owner}) =>
      _build(owner, [ownerActionIx(owner, Disc.closeVault)]);

  @override
  Future<String> pulseWithGuard(
    Ed25519HDKeyPair guard, {
    required String vaultOwner,
  }) => _sendWithKey(guard, [
    pulseOrLockdownIx(
      signer: guard.address,
      vaultOwner: vaultOwner,
      lockdown: false,
    ),
  ]);

  @override
  Future<String> lockdownWithGuard(
    Ed25519HDKeyPair guard, {
    required String vaultOwner,
  }) => _sendWithKey(guard, [
    pulseOrLockdownIx(
      signer: guard.address,
      vaultOwner: vaultOwner,
      lockdown: true,
    ),
  ]);

  @override
  Future<String> executeRuleWithKey(
    Ed25519HDKeyPair executor, {
    required String vaultOwner,
    required int index,
  }) async => _sendWithKey(
    executor,
    await _executeRuleIxs(executor.address, vaultOwner, index),
  );

  @override
  Future<List<String>> sendSigned(List<Uint8List> signedTransactions) async {
    final signatures = [
      for (final tx in signedTransactions) await _send(base64Encode(tx)),
    ];
    await _confirm(signatures);
    return signatures;
  }

  Future<List<Instruction>> _executeRuleIxs(
    String executor,
    String vaultOwner,
    int index,
  ) async {
    final vault = await fetchVault(vaultOwner);
    if (vault == null) throw const DeadmanException('Vault not found');
    if (index < 0 || index >= vault.rules.length) {
      throw DeadmanException.program(6011);
    }
    final rule = vault.rules[index];
    if (rule.executed) throw DeadmanException.program(6008);
    final mint = rule.mint;
    if (mint != null) await _mintDecimals(mint);
    final fees = await fetchFees();
    return executeRuleIxs(
      executor: executor,
      vaultOwner: vaultOwner,
      rule: rule,
      index: index,
      treasury: fees.treasury,
    );
  }

  Future<Account?> _account(String address) => _net(
    () => _rpc
        .getAccountInfo(
          address,
          commitment: commitment,
          encoding: Encoding.base64,
        )
        .value,
  );

  /// Data of an account owned by the Deadman program, or null.
  static List<int>? _programData(Account? account) {
    final data = account?.data;
    if (account == null ||
        account.owner != AppConfig.programId ||
        data is! BinaryAccountData) {
      return null;
    }
    return data.data;
  }

  /// Also rejects Token-2022 mints, which this client does not support yet.
  Future<int> _mintDecimals(String mint) async {
    final account = await _account(mint);
    final data = account?.data;
    if (account == null || data is! BinaryAccountData) {
      throw DeadmanException('Mint $mint not found');
    }
    if (account.owner != tokenProgramId) {
      throw DeadmanException(
        account.owner == token2022ProgramId
            ? 'Token-2022 mints are not supported yet'
            : 'Account $mint is not an SPL token mint',
      );
    }
    return decodeMintDecimals(data.data);
  }

  Future<VaultState?> _decodeVault(String address, Account account) async {
    final data = _programData(account);
    if (data == null || !hasDiscriminator(data, Disc.vaultAccount)) {
      return null;
    }
    final len = data.length;
    final rent = _rent[len] ??= await _net(
      () => _rpc.getMinimumBalanceForRentExemption(len, commitment: commitment),
    );
    return decodeVault(
      data,
      address: address,
      lamports: account.lamports,
      rentExemptMinimum: rent,
    );
  }

  Future<Uint8List> _build(
    String feePayer,
    List<Instruction> instructions,
  ) async {
    final bh = await _net(
      () => _rpc.getLatestBlockhash(commitment: commitment).value,
    );
    return serializeUnsigned(
      instructions,
      feePayer: feePayer,
      recentBlockhash: bh.blockhash,
    );
  }

  Future<String> _sendWithKey(
    Ed25519HDKeyPair signer,
    List<Instruction> instructions,
  ) async {
    final bh = await _net(
      () => _rpc.getLatestBlockhash(commitment: commitment).value,
    );
    final tx = await signTransaction(bh, Message(instructions: instructions), [
      signer,
    ]);
    final signature = await _send(tx.encode());
    await _confirm([signature]);
    return signature;
  }

  /// Retries transient network failures. Android can drop sockets while the
  /// wallet app is in front; resending the same signed transaction is safe
  /// because the network rejects duplicate signatures.
  static Future<T> _net<T>(Future<T> Function() call) async {
    for (var attempt = 1; ; attempt++) {
      try {
        return await call();
      } on Object catch (e) {
        final transient =
            e is SocketException ||
            e is ClientException ||
            e is TimeoutException ||
            e is RpcTimeoutException;
        if (!transient || attempt >= 4) rethrow;
        await Future<void>.delayed(Duration(milliseconds: 400 * attempt));
      }
    }
  }

  /// Public RPC pools are load-balanced and nodes lag each other, so a fresh
  /// blockhash can be unknown to the node that simulates the send. Give it a
  /// few seconds before concluding the transaction really expired.
  Future<String> _send(String base64Tx) async {
    for (var attempt = 1; ; attempt++) {
      try {
        return await _net(
          () => _rpc.sendTransaction(base64Tx, preflightCommitment: commitment),
        );
      } on JsonRpcException catch (e) {
        final data = e.data;
        final unknownBlockhash =
            data is Map && data['err'] == 'BlockhashNotFound';
        if (!unknownBlockhash) throw DeadmanException.fromRpc(e);
        if (attempt >= blockhashRetries) {
          throw const DeadmanException(
            'The approval expired before reaching the network. Tap again and approve.',
            name: 'BlockhashExpired',
          );
        }
        await Future<void>.delayed(_pollInterval * 2);
      }
    }
  }

  Future<void> _confirm(List<String> signatures) async {
    final deadline = DateTime.now().add(confirmTimeout);
    final pending = [...signatures];
    while (pending.isNotEmpty) {
      final statuses = await _net(
        () => _rpc.getSignatureStatuses(pending).value,
      );
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

  static Ed25519HDPublicKey _pk(String address) =>
      Ed25519HDPublicKey.fromBase58(address);

  static void _checkPolicy({
    required String owner,
    String? guard,
    required int intervalSecs,
    required int lockSecs,
    required List<RuleSpec> rules,
    String? guardian,
  }) {
    final code = policyError(
      owner: owner,
      guard: guard,
      intervalSecs: intervalSecs,
      lockSecs: lockSecs,
      rules: rules,
      guardian: guardian,
    );
    if (code != null) throw DeadmanException.program(code);
  }

  static void _checkAmount(int amount) {
    if (amount < 0) {
      throw ArgumentError.value(amount, 'amount', 'must be >= 0');
    }
  }
}
