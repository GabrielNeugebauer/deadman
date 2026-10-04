import 'dart:async';
import 'dart:convert';
import 'dart:io' show SocketException;
import 'dart:typed_data';

import 'package:solana/dto.dart'
    show
        Account,
        BinaryAccountData,
        Commitment,
        DataSlice,
        Encoding,
        FutureContextResultExt,
        ProgramDataFilter;
import 'package:http/http.dart' show ClientException;
import 'package:solana/base58.dart';
import 'package:solana/encoder.dart';
import 'package:solana/solana.dart';

import '../core/config.dart';
import '../kora/kora_client.dart';
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
    final err = data is Map ? data['err'] : null;
    final funding = _fundingErrors[err is Map ? err.keys.firstOrNull : err];
    if (funding != null) {
      return DeadmanException(funding, name: 'NoFunds', logs: logs);
    }
    return DeadmanException.fromTxError(err, logs: logs, fallback: e.message);
  }

  /// Runtime errors that mean the paying account is empty or missing.
  static const _fundingErrors = {
    'AccountNotFound':
        'The paying wallet has no SOL on this network. Fund it and try again.',
    'InsufficientFundsForFee':
        'The paying wallet does not have enough SOL for the network fee.',
    'InsufficientFundsForRent':
        'Not enough SOL to cover the account rent this action needs.',
  };

  factory DeadmanException.fromTxError(
    Object? err, {
    List<String> logs = const [],
    String? fallback,
  }) {
    final code = _customCode(err);
    final known = programErrors[code];
    return DeadmanException(
      _userMessages[code] ??
          known?.$2 ??
          _fromLogs(logs) ??
          fallback ??
          'Transaction failed: $err',
      code: code,
      name: known?.$1,
      logs: logs,
    );
  }

  /// Readable text for failures outside the Deadman program, from the
  /// simulation logs (e.g. the System program refusing an existing account).
  static String? _fromLogs(List<String> logs) {
    if (logs.any((l) => l.contains('already in use'))) {
      return 'That account already exists on-chain (for a plan: that plan '
          'number is taken). Refresh and try again.';
    }
    final failed = logs.lastWhere(
      (l) => RegExp(r'^Program \w+ failed: ').hasMatch(l),
      orElse: () => '',
    );
    if (failed.isEmpty) return null;
    final m = RegExp(r'^Program (\w+) failed: (.*)$').firstMatch(failed)!;
    final program = switch (m.group(1)) {
      '11111111111111111111111111111111' => 'System program',
      'TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA' => 'Token program',
      'TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb' => 'Token-2022 program',
      'ATokenGPvbdGVxr1b2hvZbsiqW5xWH25efTNsLJA8knL' => 'Token account program',
      _ => 'Program ${m.group(1)}',
    };
    return '$program rejected the transaction: ${m.group(2)}';
  }

  /// Kora reports failures as text, e.g. `Invalid transaction: Transaction
  /// simulation failed: Error processing Instruction 1: custom program
  /// error: 0x1777`, so program errors are recovered from the message.
  factory DeadmanException.fromKora(KoraException e) {
    final m = e.message;
    final custom = RegExp(
      r'Instruction (\d+): custom program error: 0x([0-9a-fA-F]+)',
    ).firstMatch(m);
    if (custom != null) {
      return DeadmanException.fromTxError({
        'InstructionError': [
          int.parse(custom.group(1)!),
          {'Custom': int.parse(custom.group(2)!, radix: 16)},
        ],
      }, fallback: m);
    }
    if (e.httpStatus == 401) {
      return const DeadmanException(
        'The fee sponsor rejected this app. Check KORA_API_KEY.',
        name: 'KoraUnauthorized',
      );
    }
    if (RegExp(
      'insufficient funds for rent',
      caseSensitive: false,
    ).hasMatch(m)) {
      return DeadmanException(
        _fundingErrors['InsufficientFundsForRent']!,
        name: 'NoFunds',
      );
    }
    return DeadmanException('Fee sponsor error: $m', name: 'KoraError');
  }

  /// A Deadman program error raised client-side, before sending.
  factory DeadmanException.program(int code) {
    final known = programErrors[code];
    return DeadmanException(
      _userMessages[code] ?? known?.$2 ?? 'Program error $code',
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
    6015: (
      'PlanCompleted',
      'Every tier of this plan has released; check-ins are closed',
    ),
    6016: ('LabelTooLong', 'Plan label is too long'),
    6017: (
      'OwnerConfirmationRequired',
      "The owner's wallet must confirm before the guard key can check in again",
    ),
    6018: ('NothingToPay', 'Nothing to pay for this tier yet'),
    6019: (
      'BeneficiaryCannotReceive',
      'Beneficiary account cannot receive this amount',
    ),
    6020: (
      'SkipTooEarly',
      "This tier can only be skipped once the plan's grace period has passed",
    ),
    6021: ('InvalidConfig', 'Treasury must be set'),
    6022: ('MathOverflow', 'Arithmetic overflow'),
  };

  /// Clearer wording than the program's `msg` where the user must act.
  static const _userMessages = <int, String>{
    6002: 'Check-in interval, lockdown length or grace period is out of range',
    6017:
        'Open your wallet and check in: the device key can no longer keep '
        'this plan alive on its own',
    6018:
        'This tier has nothing to pay: the plan holds none of this asset '
        'right now',
    6019:
        "The beneficiary's account cannot receive this payout (too small to "
        'open a new account). Once the grace period passes, later tiers can '
        "skip past it; this tier's share stays reserved for its beneficiary",
    6020: "This tier can only be skipped after the plan's grace period",
  };

  static const planCompleted = 6015;
  static const labelTooLong = 6016;
  static const ownerConfirmationRequired = 6017;

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
  /// Uses the Kora sponsor in [AppConfig] when its URL is set.
  DeadmanClient([SolanaClient? client])
    : this.withKora(
        client: client,
        sponsor: KoraClient.fromConfig(AppConfig.koraSponsorUrl),
      );

  /// [sponsor] pays guard-key transactions (pulse, lockdown) for free.
  /// Wallet-signed transactions always pay their own fees and rent in SOL.
  ///
  /// [clock] returns unix seconds; it only drives client-side pre-checks.
  DeadmanClient.withKora({
    SolanaClient? client,
    this.sponsor,
    int Function()? clock,
  }) : _now = clock ?? _systemNow,
       _client =
           client ??
           SolanaClient(
             rpcUrl: Uri.parse(AppConfig.rpcUrl),
             websocketUrl: Uri.parse(AppConfig.wsUrl),
           );

  static const commitment = Commitment.confirmed;
  static const confirmTimeout = Duration(seconds: 60);
  static const _pollInterval = Duration(milliseconds: 1500);
  static const blockhashRetries = 8;
  static const netRetries = 5;
  static const _vaultScanTtl = Duration(seconds: 30);

  final SolanaClient _client;
  final KoraClient? sponsor;
  final int Function() _now;

  /// Whether the last [pulseWithGuard] or [lockdownWithGuard] was paid by
  /// the guard key because the sponsor failed (down, drained, rejected).
  /// The guard's SOL then shrinks; plan creation tops it up again.
  bool get lastSendUsedFallback => _lastSendUsedFallback;
  var _lastSendUsedFallback = false;

  /// Wallet-signed sends by first signature, so a re-tap with the same signed
  /// bytes awaits the first send instead of sending again.
  final _inflight = <String, _SignedSend>{};
  final _rent = <int, int>{};
  final _decimals = <String, int>{};

  RpcClient get _rpc => _client.rpcClient;

  @override
  String vaultAddressFor(String owner, int planId) =>
      vaultPda(owner, planId).address;

  @override
  Future<VaultState?> fetchVault(String owner, int planId) async {
    final address = vaultAddressFor(owner, planId);
    final account = await _account(address);
    return account == null ? null : _decodeVault(address, account);
  }

  /// Always fresh: the owner's own screens must reflect their last send.
  /// Next plan number for [owner]: one past every account found at this
  /// owner's plan addresses, including accounts this app version cannot
  /// decode (older layouts), so a new plan never collides with them.
  @override
  Future<int> nextFreePlanId(String owner) async {
    final accounts = await _net(
      () => _rpc.getProgramAccounts(
        AppConfig.programId,
        commitment: commitment,
        encoding: Encoding.base64,
        filters: [
          ProgramDataFilter.memcmp(offset: 0, bytes: Disc.vaultAccount),
          ProgramDataFilter.memcmpBase58(offset: 8, bytes: owner),
        ],
        dataSlice: const DataSlice(offset: 40, length: 2),
      ),
    );
    var next = 0;
    for (final pa in accounts) {
      final data = pa.account.data;
      if (data is! BinaryAccountData) continue;
      final b = data.data;
      // Sliced to [40, 42) by the RPC; tolerate nodes that ignore dataSlice.
      final at = b.length >= 42 ? 40 : 0;
      if (b.length < at + 2) continue;
      final id = b[at] | (b[at + 1] << 8);
      // Only trust the id if this account really is that plan's address.
      if (vaultAddressFor(owner, id) == pa.pubkey && id >= next) next = id + 1;
    }
    if (next > 0xFFFF) throw const DeadmanException('No plan numbers left');
    return next;
  }

  @override
  Future<List<VaultState>> fetchVaults(String owner) async {
    final vaults = await _programVaults([
      ProgramDataFilter.memcmpBase58(offset: 8, bytes: owner),
    ]);
    return vaults..sort((a, b) => a.planId.compareTo(b.planId));
  }

  Future<List<VaultState>>? _scan;
  DateTime _scanAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// getProgramAccounts is the most rate-limited RPC call, so one scan is
  /// shared by concurrent callers and reused briefly; sends clear it.
  @override
  Future<List<VaultState>> fetchAllVaults() {
    final cached = _scan;
    if (cached != null && DateTime.now().difference(_scanAt) < _vaultScanTtl) {
      return cached;
    }
    _scanAt = DateTime.now();
    return _scan = _scanVaults().catchError((Object e) {
      _scan = null;
      throw e;
    });
  }

  // Scans every Vault; fine on devnet, needs an indexer on mainnet
  // (rules sit after a variable-length Option, so memcmp can't target them).
  Future<List<VaultState>> _scanVaults() => _programVaults(const []);

  Future<List<VaultState>> _programVaults(
    List<ProgramDataFilter> filters,
  ) async {
    final accounts = await _net(
      () => _rpc.getProgramAccounts(
        AppConfig.programId,
        commitment: commitment,
        encoding: Encoding.base64,
        filters: [
          ProgramDataFilter.memcmp(offset: 0, bytes: Disc.vaultAccount),
          ...filters,
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
    required int planId,
    required String label,
    required String guard,
    required int intervalSecs,
    required int lockSecs,
    required int skipGraceSecs,
    required List<RuleSpec> rules,
    int depositLamports = 0,
  }) async {
    _checkAmount(depositLamports);
    _checkLabel(label);
    if (guard == owner || guard == defaultPubkey) {
      throw DeadmanException.program(6005);
    }
    final vault = vaultAddressFor(owner, planId);
    _checkPolicy(
      owner: owner,
      vault: vault,
      guard: guard,
      intervalSecs: intervalSecs,
      lockSecs: lockSecs,
      skipGraceSecs: skipGraceSecs,
      rules: rules,
    );
    // Even with a sponsor: the guard pays its own pulse or lockdown when the
    // sponsor is down. Later plans reuse a guard that is already funded.
    final fundGuard = await balance(guard) < AppConfig.guardFundingLamports;
    final data = encodeCreateVault(
      planId: planId,
      label: label,
      guard: guard,
      intervalSecs: intervalSecs,
      lockSecs: lockSecs,
      skipGraceSecs: skipGraceSecs,
      rules: rules,
    );
    return _build(owner, [
      if (fundGuard)
        SystemInstruction.transfer(
          fundingAccount: _pk(owner),
          recipientAccount: _pk(guard),
          lamports: AppConfig.guardFundingLamports,
        ),
      createVaultIx(owner: owner, payer: owner, planId: planId, data: data),
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
    required int planId,
    required int lamports,
  }) async {
    _checkAmount(lamports);
    return _build(owner, [
      SystemInstruction.transfer(
        fundingAccount: _pk(owner),
        recipientAccount: _pk(vaultAddressFor(owner, planId)),
        lamports: lamports,
      ),
    ]);
  }

  @override
  Future<Uint8List> buildDepositToken({
    required String owner,
    required int planId,
    required String mint,
    required int amount,
  }) async {
    _checkAmount(amount);
    final decimals = await _mintDecimals(mint);
    return _build(
      owner,
      depositTokenIxs(
        owner: owner,
        planId: planId,
        mint: mint,
        amount: amount,
        decimals: decimals,
      ),
    );
  }

  @override
  Future<Uint8List> buildWithdrawSol({
    required String owner,
    required int planId,
    required int lamports,
  }) async {
    _checkAmount(lamports);
    return _build(owner, [
      ownerActionIx(owner, planId, encodeWithdrawSol(lamports)),
    ]);
  }

  @override
  Future<Uint8List> buildWithdrawToken({
    required String owner,
    required int planId,
    required String mint,
    required int amount,
  }) async {
    _checkAmount(amount);
    return _build(
      owner,
      withdrawTokenIxs(
        owner: owner,
        planId: planId,
        mint: mint,
        amount: amount,
      ),
    );
  }

  @override
  Future<Uint8List> buildUpdatePolicy({
    required String owner,
    required int planId,
    required String label,
    required int intervalSecs,
    required int lockSecs,
    required int skipGraceSecs,
    required List<RuleSpec> rules,
    String? guardian,
  }) async {
    _checkLabel(label);
    final current = await fetchVault(owner, planId);
    if (current == null) throw const DeadmanException('Plan not found');
    _checkPolicy(
      owner: owner,
      vault: current.address,
      guard: current.guard,
      intervalSecs: intervalSecs,
      lockSecs: lockSecs,
      skipGraceSecs: skipGraceSecs,
      rules: rules,
      historyCount: policyHistoryCount(current),
      guardian: guardian,
    );
    final data = encodeUpdatePolicy(
      label: label,
      intervalSecs: intervalSecs,
      lockSecs: lockSecs,
      skipGraceSecs: skipGraceSecs,
      rules: rules,
      guardian: guardian,
    );
    return _build(owner, [ownerActionIx(owner, planId, data)]);
  }

  @override
  Future<Uint8List> buildSetGuard({
    required String owner,
    required List<int> planIds,
    required String newGuard,
  }) {
    final ids = _distinct(planIds);
    return _build(owner, [
      for (final id in ids) ownerActionIx(owner, id, encodeSetGuard(newGuard)),
    ]);
  }

  @override
  Future<Uint8List> buildPulseByOwner({
    required String owner,
    required List<int> planIds,
  }) async {
    final ids = await _pulsablePlans(owner, planIds, byGuard: false);
    return _build(owner, [
      for (final id in ids)
        pulseOrLockdownIx(
          signer: owner,
          vaultOwner: owner,
          planId: id,
          lockdown: false,
        ),
    ]);
  }

  @override
  Future<Uint8List> buildLockdownByOwner({
    required String owner,
    required List<int> planIds,
  }) async {
    if (planIds.isEmpty) throw ArgumentError('planIds is empty');
    return _build(owner, [
      for (final id in planIds.toSet())
        pulseOrLockdownIx(
          signer: owner,
          vaultOwner: owner,
          planId: id,
          lockdown: true,
        ),
    ]);
  }

  @override
  Future<Uint8List> buildExecuteRule({
    required String executor,
    required String vaultOwner,
    required int planId,
    required int index,
  }) async {
    final ixs = await _executeRuleIxs(executor, vaultOwner, planId, index);
    return _build(executor, ixs);
  }

  @override
  Future<Uint8List> buildSkipRule({
    required String caller,
    required String vaultOwner,
    required int planId,
    required int index,
  }) async {
    final rule = await _checkSkippable(vaultOwner, planId, index);
    return _build(caller, [
      skipRuleIx(
        caller: caller,
        vaultOwner: vaultOwner,
        planId: planId,
        index: index,
        mint: rule.mint,
      ),
    ]);
  }

  @override
  Future<Uint8List> buildCloseVault({
    required String owner,
    required int planId,
  }) => _build(owner, [ownerActionIx(owner, planId, Disc.closeVault)]);

  @override
  Future<String> pulseWithGuard(
    Ed25519HDKeyPair guard, {
    required String vaultOwner,
    required List<int> planIds,
  }) async => _sendWithKey(guard, sponsored: true, [
    for (final id in await _pulsablePlans(vaultOwner, planIds, byGuard: true))
      pulseOrLockdownIx(
        signer: guard.address,
        vaultOwner: vaultOwner,
        planId: id,
        lockdown: false,
      ),
  ]);

  @override
  Future<String> lockdownWithGuard(
    Ed25519HDKeyPair guard, {
    required String vaultOwner,
    required List<int> planIds,
  }) => _sendWithKey(guard, sponsored: true, [
    for (final id in _distinct(planIds))
      pulseOrLockdownIx(
        signer: guard.address,
        vaultOwner: vaultOwner,
        planId: id,
        lockdown: true,
      ),
  ]);

  @override
  Future<String> skipRuleWithKey(
    Ed25519HDKeyPair caller, {
    required String vaultOwner,
    required int planId,
    required int index,
  }) async {
    final rule = await _checkSkippable(vaultOwner, planId, index);
    return _sendWithKey(caller, [
      skipRuleIx(
        caller: caller.address,
        vaultOwner: vaultOwner,
        planId: planId,
        index: index,
        mint: rule.mint,
      ),
    ]);
  }

  @override
  Future<String> executeRuleWithKey(
    Ed25519HDKeyPair executor, {
    required String vaultOwner,
    required int planId,
    required int index,
  }) async => _sendWithKey(
    executor,
    await _executeRuleIxs(executor.address, vaultOwner, planId, index),
  );

  /// Sends in order, then confirms. Calling again with the same signed bytes
  /// while the first call is in flight, or within [confirmTimeout] after it
  /// succeeded, awaits that call instead of sending twice; after a failure
  /// the bytes may be sent again.
  @override
  Future<List<String>> sendSigned(List<Uint8List> signedTransactions) async {
    final now = DateTime.now();
    _inflight.removeWhere((_, e) {
      final at = e.confirmedAt;
      return at != null && now.difference(at) > confirmTimeout;
    });
    final confirmations = <Future<String>>[];
    for (final tx in signedTransactions) {
      final id = _txId(tx);
      var entry = _inflight[id];
      if (entry == null) {
        final sent = _send(base64Encode(tx));
        final e = _SignedSend(
          sent,
          sent.then((signature) async {
            await _confirm([signature]);
            return signature;
          }),
        );
        _inflight[id] = entry = e;
        e.done.then<void>(
          (_) => e.confirmedAt = DateTime.now(),
          onError: (Object _) {
            if (identical(_inflight[id], e)) _inflight.remove(id);
          },
        );
      }
      confirmations.add(entry.done);
      await entry.sent;
    }
    final signatures = await Future.wait(confirmations);
    _scan = null;
    return signatures;
  }

  /// First (fee payer) signature, which identifies a signed transaction.
  static String _txId(Uint8List tx) =>
      tx.length > 65 ? base58encode(tx.sublist(1, 65)) : base64Encode(tx);

  /// [planIds] minus completed or closed plans, which the program would
  /// reject (`PlanCompleted`) or cannot load. With [byGuard], also minus
  /// plans whose owner must check in from their wallet first; if that
  /// leaves nothing, throws `OwnerConfirmationRequired` naming them.
  Future<List<int>> _pulsablePlans(
    String owner,
    List<int> planIds, {
    required bool byGuard,
  }) async {
    final ids = _distinct(planIds);
    final addresses = [for (final id in ids) vaultAddressFor(owner, id)];
    final accounts = await _net(
      () => _rpc
          .getMultipleAccounts(
            addresses,
            commitment: commitment,
            encoding: Encoding.base64,
          )
          .value,
    );
    final open = <int>[];
    final needOwner = <VaultState>[];
    var completed = false;
    final now = _now();
    for (var i = 0; i < ids.length; i++) {
      final account = accounts[i];
      final vault = account == null
          ? null
          : await _decodeVault(addresses[i], account);
      if (vault == null) continue;
      if (vault.completed) {
        completed = true;
      } else if (byGuard && !vault.guardCanPulse(now)) {
        needOwner.add(vault);
      } else {
        open.add(ids[i]);
      }
    }
    if (open.isEmpty) {
      if (needOwner.isNotEmpty) {
        final names = needOwner
            .map((v) => v.label.isEmpty ? 'plan ${v.planId}' : v.label)
            .join(', ');
        throw DeadmanException(
          'Open your wallet and check in: the device key can no longer keep '
          '$names alive on its own.',
          code: DeadmanException.ownerConfirmationRequired,
          name: 'OwnerConfirmationRequired',
        );
      }
      if (completed) {
        throw DeadmanException.program(DeadmanException.planCompleted);
      }
      throw const DeadmanException('Plan not found');
    }
    return open;
  }

  static List<int> _distinct(List<int> planIds) {
    if (planIds.isEmpty) {
      throw ArgumentError.value(planIds, 'planIds', 'must not be empty');
    }
    return planIds.toSet().toList();
  }

  /// Rejects what `skip_rule` would, except the grace period, which only the
  /// chain clock decides. Returns the tier to skip.
  Future<RuleState> _checkSkippable(
    String vaultOwner,
    int planId,
    int index,
  ) async {
    final vault = await fetchVault(vaultOwner, planId);
    if (vault == null) throw const DeadmanException('Vault not found');
    if (index < 0 || index >= vault.rules.length) {
      throw DeadmanException.program(6011);
    }
    final rule = vault.rules[index];
    if (rule.settled) throw DeadmanException.program(6008);
    for (final earlier in vault.rules.take(index)) {
      if (earlier.mint == rule.mint && !earlier.settled) {
        throw DeadmanException.program(6009);
      }
    }
    return rule;
  }

  Future<List<Instruction>> _executeRuleIxs(
    String executor,
    String vaultOwner,
    int planId,
    int index,
  ) async {
    final vault = await fetchVault(vaultOwner, planId);
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
      planId: planId,
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
  Future<int> _mintDecimals(String mint) async =>
      _decimals[mint] ??= await _fetchMintDecimals(mint);

  Future<int> _fetchMintDecimals(String mint) async {
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

  /// Unsigned transaction for the wallet of [signer], which pays the fee
  /// and any rent, with a blockhash from our RPC.
  Future<Uint8List> _build(
    String signer,
    List<Instruction> instructions,
  ) async {
    final bh = await _net(
      () => _rpc.getLatestBlockhash(commitment: commitment).value,
    );
    return serializeUnsigned(
      instructions,
      feePayer: signer,
      recentBlockhash: bh.blockhash,
    );
  }

  /// Signs with [signer] and sends, [signer] paying the fee. When
  /// [sponsored] and a [sponsor] is set, the sponsor's signer is fee payer
  /// instead: [signer] fills its own slot, the sponsor co-signs and
  /// broadcasts. If the sponsor fails for any reason other than a program
  /// error, [signer] pays after all (see [lastSendUsedFallback]).
  Future<String> _sendWithKey(
    Ed25519HDKeyPair signer,
    List<Instruction> instructions, {
    bool sponsored = false,
  }) async {
    final sponsor = sponsored ? this.sponsor : null;
    String? signature;
    if (sponsored) _lastSendUsedFallback = false;
    if (sponsor != null) {
      try {
        signature = await _sendSponsored(sponsor, signer, instructions);
      } on Object catch (e) {
        // A program error fails the same way when the guard pays.
        if (e is DeadmanException && e.code != null) rethrow;
        _lastSendUsedFallback = true;
      }
    }
    signature ??= await _sendPaidBy(signer, instructions);
    await _confirm([signature]);
    _scan = null;
    return signature;
  }

  Future<String> _sendPaidBy(
    Ed25519HDKeyPair signer,
    List<Instruction> instructions,
  ) async {
    final bh = await _net(
      () => _rpc.getLatestBlockhash(commitment: commitment).value,
    );
    final tx = await signTransaction(bh, Message(instructions: instructions), [
      signer,
    ]);
    return _send(tx.encode());
  }

  Future<String> _sendSponsored(
    KoraClient sponsor,
    Ed25519HDKeyPair signer,
    List<Instruction> instructions,
  ) async {
    final payer = (await _kora(sponsor.getPayerSigner)).signerAddress;
    final blockhash = await _kora(sponsor.getBlockhash);
    final tx = await partiallySign(
      serializeUnsigned(
        instructions,
        feePayer: payer,
        recentBlockhash: blockhash,
      ),
      signer,
    );
    return _send(base64Encode(tx), kora: sponsor, koraSigner: payer);
  }

  /// A Kora call during building: retried like RPC, errors mapped.
  static Future<T> _kora<T>(Future<T> Function() call) async {
    try {
      return await _net(call);
    } on KoraException catch (e) {
      throw DeadmanException.fromKora(e);
    }
  }

  /// Retries transient failures: sockets Android drops while the wallet app
  /// is in front, timeouts, and rate limiting (HTTP 429) or 5xx from public
  /// RPCs. Resending a signed transaction is safe; duplicates are rejected.
  static Future<T> _net<T>(Future<T> Function() call) async {
    for (var attempt = 1; ; attempt++) {
      try {
        return await call();
      } on Object catch (e) {
        final status = RegExp(r'^http status code (\d+)').firstMatch('$e');
        final code = e is KoraException
            ? e.httpStatus
            : status == null
            ? null
            : int.parse(status.group(1)!);
        final throttled = code == 429 || (code != null && code >= 500);
        final transient =
            throttled ||
            e is SocketException ||
            e is ClientException ||
            e is TimeoutException ||
            e is RpcTimeoutException;
        if (!transient || attempt >= netRetries) {
          if (code == 429) {
            throw const DeadmanException(
              'The network is busy (rate limited). Wait a moment and try again.',
              name: 'RateLimited',
            );
          }
          rethrow;
        }
        // 0.5s, 1s, 2s, 4s: rate limits need real breathing room.
        await Future<void>.delayed(
          Duration(milliseconds: 500 << (attempt - 1)),
        );
      }
    }
  }

  /// Public RPC pools are load-balanced and nodes lag each other, so a fresh
  /// blockhash can be unknown to the node that simulates the send. Give it a
  /// few seconds before concluding the transaction really expired. With
  /// [kora], the node co-signs as [koraSigner] and broadcasts instead.
  Future<String> _send(
    String base64Tx, {
    KoraClient? kora,
    String? koraSigner,
  }) async {
    for (var attempt = 1; ; attempt++) {
      try {
        if (kora != null) {
          final r = await _net(
            () => kora.signAndSendTransaction(
              transaction: base64Tx,
              signerKey: koraSigner,
            ),
          );
          return r.signature!;
        }
        return await _net(
          () => _rpc.sendTransaction(base64Tx, preflightCommitment: commitment),
        );
      } on JsonRpcException catch (e) {
        final data = e.data;
        if (data is! Map || data['err'] != 'BlockhashNotFound') {
          throw DeadmanException.fromRpc(e);
        }
      } on KoraException catch (e) {
        if (!e.blockhashNotFound) throw DeadmanException.fromKora(e);
      }
      if (attempt >= blockhashRetries) {
        throw const DeadmanException(
          'The approval expired before reaching the network. Tap again and approve.',
          name: 'BlockhashExpired',
        );
      }
      await Future<void>.delayed(_pollInterval);
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

  static int _systemNow() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  static Ed25519HDPublicKey _pk(String address) =>
      Ed25519HDPublicKey.fromBase58(address);

  static void _checkPolicy({
    required String owner,
    required String vault,
    String? guard,
    required int intervalSecs,
    required int lockSecs,
    required int skipGraceSecs,
    required List<RuleSpec> rules,
    int historyCount = 0,
    String? guardian,
  }) {
    final code = policyError(
      owner: owner,
      vault: vault,
      guard: guard,
      intervalSecs: intervalSecs,
      lockSecs: lockSecs,
      skipGraceSecs: skipGraceSecs,
      rules: rules,
      historyCount: historyCount,
      guardian: guardian,
    );
    if (code != null) throw DeadmanException.program(code);
  }

  static void _checkLabel(String label) {
    if (!labelFits(label)) {
      throw DeadmanException.program(DeadmanException.labelTooLong);
    }
  }

  static void _checkAmount(int amount) {
    if (amount < 0) {
      throw ArgumentError.value(amount, 'amount', 'must be >= 0');
    }
  }
}

/// A wallet-signed send, kept while in flight and briefly after it confirms.
class _SignedSend {
  _SignedSend(this.sent, this.done);

  final Future<String> sent;
  final Future<String> done;
  DateTime? confirmedAt;
}
