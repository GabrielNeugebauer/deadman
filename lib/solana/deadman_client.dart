import 'dart:async';
import 'dart:convert';
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
import 'socket_exception_stub.dart'
    if (dart.library.io) 'dart:io'
    show SocketException;
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
    6021: (
      'WrongPlanKind',
      'This instruction does not apply to this kind of plan',
    ),
    6022: (
      'InvalidVesting',
      'Vesting schedules need a total, a cliff no longer than the duration, '
          'and a duration up to 20 years',
    ),
    6023: ('NotRevocable', 'This vesting plan cannot be revoked'),
    6024: ('AlreadyRevoked', 'Vesting was already revoked'),
    6025: (
      'FundsCommitted',
      'Those funds are committed to vesting beneficiaries',
    ),
    6026: ('InvalidConfig', 'Treasury must be set'),
    6027: ('MathOverflow', 'Arithmetic overflow'),
    6028: ('NotLegacyVault', 'Not a plan account in an older layout'),
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
        'open a new account). Once the grace period passes, Deadman skips it '
        "automatically; this tier's share stays reserved for its beneficiary",
    6020: "This tier can only be skipped after the plan's grace period",
    6021:
        'This action does not apply to this kind of plan: vesting plans need '
        'no check-ins and have no tiers to execute or skip, and only vesting '
        'plans can be released or revoked',
    6022:
        'Each vesting schedule needs an amount, a cliff no longer than its '
        'duration (at most 20 years), a beneficiary other than you or this '
        'device, and a start date within a year of today (1 to 8 schedules)',
    6023:
        'This vesting plan was created as irrevocable, so it cannot be stopped',
    6024: 'Vesting on this plan was already stopped',
    6025:
        'Those funds are owed to vesting beneficiaries. You can only withdraw '
        'what is above the amount still to be released to them',
  };

  static const vaultLocked = 6006;
  static const ruleAlreadyExecuted = 6008;
  static const invalidRuleIndex = 6011;
  static const insufficientFunds = 6012;
  static const planCompleted = 6015;
  static const labelTooLong = 6016;
  static const ownerConfirmationRequired = 6017;
  static const nothingToPay = 6018;
  static const wrongPlanKind = 6021;
  static const invalidVesting = 6022;
  static const notRevocable = 6023;
  static const alreadyRevoked = 6024;
  static const fundsCommitted = 6025;
  static const notLegacyVault = 6028;

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
  /// Uses the Kora sponsor and paymaster in [AppConfig] when their URLs are
  /// set.
  DeadmanClient([SolanaClient? client])
    : this.withKora(
        client: client,
        sponsor: KoraClient.fromConfig(AppConfig.koraSponsorUrl),
        paymaster: KoraClient.fromConfig(AppConfig.koraPaymasterUrl),
      );

  /// [sponsor] pays guard-key transactions (pulse, lockdown) for free.
  ///
  /// [paymaster], once [feeToken] is set, is fee payer and rent payer of
  /// every wallet-signed `build*` transaction and charges the wallet in
  /// [feeToken] (a final SPL transfer). Without either, wallet-signed
  /// transactions pay their own fees and rent in SOL.
  ///
  /// The paymaster must answer as [paymasterSigner] (fee payer and payment
  /// address) and quote at most [maxFee] base units of the fee token.
  ///
  /// [clock] returns unix seconds; it only drives client-side pre-checks.
  DeadmanClient.withKora({
    SolanaClient? client,
    this.sponsor,
    this.paymaster,
    this.paymasterSigner = AppConfig.koraPaymasterSigner,
    this.maxFee = AppConfig.koraMaxFee,
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
  final KoraClient? paymaster;

  /// Pinned paymaster key (audit M-3); empty refuses the paymaster.
  final String paymasterSigner;

  /// Highest paymaster fee accepted, in fee-token base units.
  final int maxFee;
  final int Function() _now;

  @override
  String? get feeToken => _feeToken;
  @override
  set feeToken(String? mint) => _feeToken = mint;
  String? _feeToken;

  /// Wallet-signed builds go through [paymaster] and charge [feeToken].
  bool get paysFeesInToken => paymaster != null && _feeToken != null;

  /// Fee payers of transactions built for the paymaster; signed bytes with
  /// one of these first are sent through it.
  final _paymasterPayers = <String>{};

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

  @override
  Future<List<int>> fetchLegacyPlanIds(String owner) async {
    final accounts = await _net(
      () => _rpc.getProgramAccounts(
        AppConfig.programId,
        commitment: commitment,
        encoding: Encoding.base64,
        filters: [
          ProgramDataFilter.memcmp(offset: 0, bytes: Disc.vaultAccount),
          ProgramDataFilter.memcmpBase58(offset: 8, bytes: owner),
        ],
      ),
    );
    final ids = <int>[];
    for (final pa in accounts) {
      final data = _programData(pa.account);
      if (data == null || data.length == vaultAccountSize || data.length < 42) {
        continue;
      }
      final id = data[40] | (data[41] << 8);
      // The program only recovers the account at the plan's own address.
      if (vaultAddressFor(owner, id) == pa.pubkey) ids.add(id);
    }
    return ids..sort();
  }

  @override
  Future<Uint8List> buildRecoverLegacyVault({
    required String owner,
    required int planId,
  }) async {
    if (!(await fetchLegacyPlanIds(owner)).contains(planId)) {
      throw DeadmanException.program(DeadmanException.notLegacyVault);
    }
    return _build(
      owner,
      (_) => [recoverLegacyVaultIx(owner: owner, planId: planId)],
    );
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
  Future<List<int>> tokenBalances(List<(String, String)> accounts) async {
    final out = <int>[];
    // getMultipleAccounts takes at most 100 keys.
    for (var i = 0; i < accounts.length; i += 100) {
      final atas = [
        for (final (owner, mint) in accounts.skip(i).take(100))
          ataAddress(owner, mint),
      ];
      final found = await _net(
        () => _rpc
            .getMultipleAccounts(
              atas,
              commitment: commitment,
              encoding: Encoding.base64,
            )
            .value,
      );
      for (final a in found) {
        final data = a?.data;
        out.add(data is BinaryAccountData ? decodeTokenAmount(data.data) : 0);
      }
    }
    return out;
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
    Map<String, int> tokenDeposits = const {},
  }) async {
    _checkAmount(depositLamports);
    tokenDeposits.values.forEach(_checkAmount);
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
    final deposits = {
      for (final e in tokenDeposits.entries)
        if (e.value > 0) e.key: e.value,
    };
    // Rejects Token-2022 and non-mint accounts before anything is signed.
    final decimals = {
      for (final mint in deposits.keys) mint: await _mintDecimals(mint),
    };
    final fundGuard = await _shouldFundGuard(owner, guard, depositLamports);
    final data = encodeCreateVault(
      planId: planId,
      label: label,
      guard: guard,
      intervalSecs: intervalSecs,
      lockSecs: lockSecs,
      skipGraceSecs: skipGraceSecs,
      rules: rules,
    );
    return _build(
      owner,
      (payer) => [
        if (fundGuard) _transfer(owner, guard, AppConfig.guardFundingLamports),
        createVaultIx(owner: owner, payer: payer, planId: planId, data: data),
        if (depositLamports > 0) _transfer(owner, vault, depositLamports),
        for (final e in deposits.entries)
          ...depositTokenIxs(
            owner: owner,
            planId: planId,
            mint: e.key,
            amount: e.value,
            decimals: decimals[e.key]!,
            payer: payer,
          ),
      ],
      spend: deposits,
    );
  }

  @override
  Future<Uint8List> buildCreateVesting({
    required String owner,
    required int planId,
    required String label,
    required String guard,
    required int lockSecs,
    required int startAt,
    required bool revocable,
    required List<VestingSpec> schedules,
    int depositLamports = 0,
    Map<String, int> tokenDeposits = const {},
  }) async {
    _checkAmount(depositLamports);
    tokenDeposits.values.forEach(_checkAmount);
    _checkLabel(label);
    final vault = vaultAddressFor(owner, planId);
    final code = vestingError(
      owner: owner,
      vault: vault,
      guard: guard,
      lockSecs: lockSecs,
      startAt: startAt,
      schedules: schedules,
      now: _now(),
    );
    if (code != null) throw DeadmanException.program(code);
    // Rejects Token-2022 and non-mint accounts before anything is signed.
    for (final mint in {for (final s in schedules) ?s.mint}) {
      await _mintDecimals(mint);
    }
    final deposits = {
      for (final e in tokenDeposits.entries)
        if (e.value > 0) e.key: e.value,
    };
    final decimals = {
      for (final mint in deposits.keys) mint: await _mintDecimals(mint),
    };
    final fundGuard = await _shouldFundGuard(owner, guard, depositLamports);
    final data = encodeCreateVesting(
      planId: planId,
      label: label,
      guard: guard,
      lockSecs: lockSecs,
      startAt: startAt,
      revocable: revocable,
      schedules: schedules,
    );
    return _build(
      owner,
      (payer) => [
        if (fundGuard) _transfer(owner, guard, AppConfig.guardFundingLamports),
        createVaultIx(owner: owner, payer: payer, planId: planId, data: data),
        if (depositLamports > 0) _transfer(owner, vault, depositLamports),
        for (final e in deposits.entries)
          ...depositTokenIxs(
            owner: owner,
            planId: planId,
            mint: e.key,
            amount: e.value,
            decimals: decimals[e.key]!,
            payer: payer,
          ),
      ],
      spend: deposits,
    );
  }

  @override
  Future<Uint8List> buildDeposit({
    required String owner,
    required int planId,
    required int lamports,
  }) async {
    _checkAmount(lamports);
    return _build(
      owner,
      (_) => [_transfer(owner, vaultAddressFor(owner, planId), lamports)],
    );
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
      (payer) => depositTokenIxs(
        owner: owner,
        planId: planId,
        mint: mint,
        amount: amount,
        decimals: decimals,
        payer: payer,
      ),
      spend: {mint: amount},
    );
  }

  @override
  Future<Uint8List> buildWithdrawSol({
    required String owner,
    required int planId,
    required int lamports,
  }) async {
    _checkAmount(lamports);
    final vault = await _ownedVault(owner, planId);
    _checkUnlocked(vault);
    _checkWithdrawable(vault, null, lamports, vault.withdrawableLamports);
    return _build(
      owner,
      (_) => [ownerActionIx(owner, planId, encodeWithdrawSol(lamports))],
    );
  }

  @override
  Future<Uint8List> buildWithdrawToken({
    required String owner,
    required int planId,
    required String mint,
    required int amount,
  }) async {
    _checkAmount(amount);
    final vault = await _ownedVault(owner, planId);
    _checkUnlocked(vault);
    if (vault.committed(mint) > 0) {
      _checkWithdrawable(
        vault,
        mint,
        amount,
        await tokenBalance(vault.address, mint),
      );
    }
    return _build(
      owner,
      (payer) => withdrawTokenIxs(
        owner: owner,
        planId: planId,
        mint: mint,
        amount: amount,
        payer: payer,
      ),
      // Arrives before the fee payment, which runs last.
      spend: {mint: -amount},
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
    final current = await _ownedVault(owner, planId);
    if (current.isVesting) {
      throw DeadmanException.program(DeadmanException.wrongPlanKind);
    }
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
    return _build(owner, (_) => [ownerActionIx(owner, planId, data)]);
  }

  @override
  Future<Uint8List> buildSetGuard({
    required String owner,
    required List<int> planIds,
    required String newGuard,
  }) {
    final ids = _distinct(planIds);
    return _build(
      owner,
      (_) => [
        for (final id in ids)
          ownerActionIx(owner, id, encodeSetGuard(newGuard)),
      ],
    );
  }

  @override
  Future<Uint8List> buildPulseByOwner({
    required String owner,
    required List<int> planIds,
  }) async {
    final ids = await _pulsablePlans(owner, planIds, byGuard: false);
    return _build(
      owner,
      (_) => [
        for (final id in ids)
          pulseOrLockdownIx(
            signer: owner,
            vaultOwner: owner,
            planId: id,
            lockdown: false,
          ),
      ],
    );
  }

  @override
  Future<Uint8List> buildLockdownByOwner({
    required String owner,
    required List<int> planIds,
  }) async {
    if (planIds.isEmpty) throw ArgumentError('planIds is empty');
    return _build(
      owner,
      (_) => [
        for (final id in planIds.toSet())
          pulseOrLockdownIx(
            signer: owner,
            vaultOwner: owner,
            planId: id,
            lockdown: true,
          ),
      ],
    );
  }

  @override
  Future<Uint8List> buildExecuteRule({
    required String executor,
    required String vaultOwner,
    required int planId,
    required int index,
  }) async => _build(
    executor,
    await _executeRuleIxs(executor, vaultOwner, planId, index),
  );

  @override
  Future<Uint8List> buildSkipRule({
    required String caller,
    required String vaultOwner,
    required int planId,
    required int index,
  }) async {
    final rule = await _checkSkippable(vaultOwner, planId, index);
    final createAta = await _vaultAtaMissing(vaultOwner, planId, rule.mint);
    return _build(
      caller,
      (payer) => [
        if (createAta)
          createAtaIdempotentIx(
            payer: payer,
            owner: vaultAddressFor(vaultOwner, planId),
            mint: rule.mint!,
          ),
        skipRuleIx(
          caller: caller,
          vaultOwner: vaultOwner,
          planId: planId,
          index: index,
          mint: rule.mint,
        ),
      ],
    );
  }

  @override
  Future<Uint8List> buildRevokeVesting({
    required String owner,
    required int planId,
  }) async {
    final vault = await _ownedVault(owner, planId);
    if (!vault.isVesting) {
      throw DeadmanException.program(DeadmanException.wrongPlanKind);
    }
    _checkUnlocked(vault);
    if (!vault.revocable) {
      throw DeadmanException.program(DeadmanException.notRevocable);
    }
    if (vault.revokedAt != 0) {
      throw DeadmanException.program(DeadmanException.alreadyRevoked);
    }
    return _build(
      owner,
      (_) => [ownerActionIx(owner, planId, Disc.revokeVesting)],
    );
  }

  @override
  Future<Uint8List> buildReleaseVested({
    required String executor,
    required String vaultOwner,
    required int planId,
    required int index,
  }) async => _build(
    executor,
    await _releaseVestedIxs(executor, vaultOwner, planId, index),
  );

  @override
  Future<String> releaseVestedWithKey(
    Ed25519HDKeyPair executor, {
    required String vaultOwner,
    required int planId,
    required int index,
  }) async => _sendWithKey(
    executor,
    (await _releaseVestedIxs(executor.address, vaultOwner, planId, index))(
      executor.address,
    ),
  );

  @override
  Future<Uint8List> buildCloseVault({
    required String owner,
    required int planId,
  }) async {
    final vault = await _ownedVault(owner, planId);
    _checkUnlocked(vault);
    if (vault.isVesting) {
      for (var i = 0; i < vault.rules.length; i++) {
        if (vault.vestingCap(i) > vault.rules[i].released) {
          throw DeadmanException.program(DeadmanException.fundsCommitted);
        }
      }
    }
    final rentPayer = vault.rentPayer.isEmpty ? owner : vault.rentPayer;
    return _build(
      owner,
      (_) => [closeVaultIx(owner: owner, planId: planId, rentPayer: rentPayer)],
    );
  }

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
    final createAta = await _vaultAtaMissing(vaultOwner, planId, rule.mint);
    return _sendWithKey(caller, [
      if (createAta)
        createAtaIdempotentIx(
          payer: caller.address,
          owner: vaultAddressFor(vaultOwner, planId),
          mint: rule.mint!,
        ),
      skipRuleIx(
        caller: caller.address,
        vaultOwner: vaultOwner,
        planId: planId,
        index: index,
        mint: rule.mint,
      ),
    ]);
  }

  /// A token tier's plan that never held its mint has no token account,
  /// which `skip_rule` must read; creating it (empty) lets the skip record
  /// that nothing was there to reserve.
  Future<bool> _vaultAtaMissing(
    String vaultOwner,
    int planId,
    String? mint,
  ) async =>
      mint != null &&
      await _account(ataAddress(vaultAddressFor(vaultOwner, planId), mint)) ==
          null;

  @override
  Future<String> executeRuleWithKey(
    Ed25519HDKeyPair executor, {
    required String vaultOwner,
    required int planId,
    required int index,
  }) async => _sendWithKey(
    executor,
    (await _executeRuleIxs(executor.address, vaultOwner, planId, index))(
      executor.address,
    ),
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
        final payer = _feePayerOf(tx);
        final viaPaymaster = _paymasterPayers.contains(payer);
        final sent = _send(
          base64Encode(tx),
          kora: viaPaymaster ? paymaster : null,
          koraSigner: viaPaymaster ? payer : null,
        );
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

  /// First filled signature, which identifies a signed transaction (the
  /// fee payer's, or the wallet's when a paymaster still has to co-sign).
  static String _txId(Uint8List tx) {
    final count = tx.isEmpty ? 0 : tx[0];
    if (count < 0x80) {
      for (var i = 0; i < count && 65 + i * 64 <= tx.length; i++) {
        final sig = tx.sublist(1 + i * 64, 65 + i * 64);
        if (sig.any((b) => b != 0)) return base58encode(sig);
      }
    }
    return base64Encode(tx);
  }

  static String? _feePayerOf(Uint8List tx) {
    try {
      return SignedTx.fromBytes(tx).compiledMessage.accountKeys.first
          .toBase58();
    } on Object {
      return null;
    }
  }

  /// [planIds] minus completed, closed or vesting plans, which the program
  /// would reject (`PlanCompleted`, `WrongPlanKind`) or cannot load. With
  /// [byGuard], also minus plans whose owner must check in from their wallet
  /// first; if that leaves nothing, throws `OwnerConfirmationRequired`
  /// naming them.
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
    var vesting = false;
    final now = _now();
    for (var i = 0; i < ids.length; i++) {
      final account = accounts[i];
      final vault = account == null
          ? null
          : await _decodeVault(addresses[i], account);
      if (vault == null) continue;
      if (vault.isVesting) {
        vesting = true;
      } else if (vault.completed) {
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
      if (vesting) {
        throw const DeadmanException(
          'Vesting plans need no check-ins.',
          code: DeadmanException.wrongPlanKind,
          name: 'WrongPlanKind',
        );
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
    final vault = await _payoutVault(vaultOwner, planId, index, vesting: false);
    final rule = vault.rules[index];
    if (rule.settled) throw DeadmanException.program(6008);
    for (final earlier in vault.rules.take(index)) {
      if (earlier.mint == rule.mint && !earlier.settled) {
        throw DeadmanException.program(6009);
      }
    }
    return rule;
  }

  /// Plan [planId] of [vaultOwner], checked to be of the right kind for an
  /// execute/skip ([vesting] false) or release ([vesting] true) of
  /// [index].
  Future<VaultState> _payoutVault(
    String vaultOwner,
    int planId,
    int index, {
    required bool vesting,
  }) async {
    final vault = await fetchVault(vaultOwner, planId);
    if (vault == null) throw const DeadmanException('Vault not found');
    if (vault.isVesting != vesting) {
      throw DeadmanException.program(DeadmanException.wrongPlanKind);
    }
    if (index < 0 || index >= vault.rules.length) {
      throw DeadmanException.program(DeadmanException.invalidRuleIndex);
    }
    return vault;
  }

  /// Instructions for a given rent payer (the executor, or the paymaster).
  Future<List<Instruction> Function(String payer)> _executeRuleIxs(
    String executor,
    String vaultOwner,
    int planId,
    int index,
  ) async {
    final vault = await _payoutVault(vaultOwner, planId, index, vesting: false);
    final rule = vault.rules[index];
    if (rule.executed) throw DeadmanException.program(6008);
    final mint = rule.mint;
    if (mint != null) {
      await _mintDecimals(mint);
      // A vault that never held the mint has no token account: the program
      // would fail with AccountNotInitialized inside the wallet's preview.
      if (await tokenBalance(vault.address, mint) <= 0) {
        throw DeadmanException(
          'This plan holds none of ${_tokenName(mint)} yet, so this tier has '
          'nothing to pay. The owner must deposit it first; after the grace '
          'period Deadman skips the tier automatically and keeps its share '
          'reserved.',
          code: DeadmanException.nothingToPay,
          name: 'NothingToPay',
        );
      }
    }
    final fees = await fetchFees();
    return (payer) => executeRuleIxs(
      executor: executor,
      vaultOwner: vaultOwner,
      planId: planId,
      rule: rule,
      index: index,
      treasury: fees.treasury,
      payer: payer,
    );
  }

  /// Rejects what `release_vested_*` would, as far as the client knows
  /// (the chain clock decides at the edges).
  Future<List<Instruction> Function(String payer)> _releaseVestedIxs(
    String executor,
    String vaultOwner,
    int planId,
    int index,
  ) async {
    final vault = await _payoutVault(vaultOwner, planId, index, vesting: true);
    final rule = vault.rules[index];
    if (rule.executed) {
      throw DeadmanException.program(DeadmanException.ruleAlreadyExecuted);
    }
    if (vault.claimable(index, _now()) <= 0) {
      throw const DeadmanException(
        'Nothing new has vested on this schedule yet.',
        code: DeadmanException.nothingToPay,
        name: 'NothingToPay',
      );
    }
    final mint = rule.mint;
    final held = mint == null
        ? vault.withdrawableLamports
        : await tokenBalance(vault.address, mint);
    if (held <= 0) {
      throw DeadmanException.program(DeadmanException.nothingToPay);
    }
    if (mint != null) await _mintDecimals(mint);
    final fees = await fetchFees();
    return (payer) => releaseVestedIxs(
      executor: executor,
      vaultOwner: vaultOwner,
      planId: planId,
      rule: rule,
      index: index,
      treasury: fees.treasury,
      payer: payer,
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
    // Other sizes are older layouts (see fetchLegacyPlanIds).
    if (data == null ||
        !hasDiscriminator(data, Disc.vaultAccount) ||
        data.length != vaultAccountSize) {
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

  /// Unsigned transaction for the wallet of [signer]. [instructions] gets
  /// the account that pays the fee and any rent: [signer] itself with a
  /// blockhash from our RPC, or, when [paysFeesInToken], the paymaster's
  /// signer with a Kora blockhash plus a final [feeToken] payment.
  /// [spend] is how much of each token the instructions take from (or,
  /// negative, add to) the signer's ATA before the fee payment.
  Future<Uint8List> _build(
    String signer,
    List<Instruction> Function(String payer) instructions, {
    Map<String, int> spend = const {},
  }) async {
    final paymaster = this.paymaster;
    final token = _feeToken;
    final Uint8List tx;
    if (paymaster != null && token != null) {
      tx = await _buildPaid(paymaster, token, signer, instructions, spend);
    } else {
      final bh = await _net(
        () => _rpc.getLatestBlockhash(commitment: commitment).value,
      );
      tx = serializeUnsigned(
        instructions(signer),
        feePayer: signer,
        recentBlockhash: bh.blockhash,
      );
    }
    if (tx.length > maxTxBytes) {
      throw const DeadmanException(
        'This is too much for one transaction. Split it into smaller steps '
        '(for example, deposit some tokens afterwards).',
        name: 'TxTooLarge',
      );
    }
    return tx;
  }

  /// Solana's packet limit for a serialized transaction.
  static const maxTxBytes = 1232;

  Future<Uint8List> _buildPaid(
    KoraClient paymaster,
    String token,
    String signer,
    List<Instruction> Function(String payer) instructions,
    Map<String, int> spend,
  ) async {
    final pinned = paymasterSigner;
    if (pinned.isEmpty) {
      throw const DeadmanException(
        'Paying network fees in USDC is not set up in this build '
        '(KORA_PAYMASTER_SIGNER). Switch network fees back to SOL.',
        name: 'KoraUnpinned',
      );
    }
    final payer = await _kora(paymaster.getPayerSigner);
    _checkPaymasterKey(payer.signerAddress, payer.paymentAddress);
    final kora = payer.signerAddress;
    final blockhash = await _kora(paymaster.getBlockhash);
    final decimals = await _mintDecimals(token);
    final ixs = await _withoutExistingKoraAtas(
      instructions(kora),
      kora,
      signer,
    );
    final estimate = await _kora(
      () => paymaster.estimateTransactionFee(
        transaction: base64Encode(
          serializeUnsigned(ixs, feePayer: kora, recentBlockhash: blockhash),
        ),
        feeToken: token,
        signerKey: kora,
      ),
    );
    _checkPaymasterKey(estimate.signerPubkey, estimate.paymentAddress);
    final fee = estimate.feeInToken;
    if (fee == null || fee < 0) {
      throw DeadmanException(
        'The fee service does not accept ${_tokenName(token)}. Switch '
        'network fees back to SOL.',
        name: 'KoraError',
      );
    }
    if (fee > maxFee) {
      final name = _tokenName(token);
      throw DeadmanException(
        'The fee service asks ${_units(fee, decimals)} $name for this, more '
        'than the ${_units(maxFee, decimals)} $name limit. Nothing was '
        'signed. Switch network fees back to SOL.',
        name: 'KoraFeeTooHigh',
      );
    }
    final extra = spend[token] ?? 0;
    final needed = fee + (extra > 0 ? extra : 0);
    final held = await tokenBalance(signer, token) + (extra < 0 ? -extra : 0);
    if (held < needed) {
      final name = _tokenName(token);
      throw DeadmanException(
        'Not enough $name for the network fee: this needs '
        '${_units(fee, decimals)} $name'
        '${extra > 0 ? ' plus the ${_units(extra, decimals)} $name moved' : ''}'
        ', the wallet holds ${_units(held, decimals)}. Add $name or switch '
        'network fees back to SOL.',
        name: 'NoFeeToken',
      );
    }
    _paymasterPayers.add(kora);
    return serializeUnsigned(
      [
        ...ixs,
        if (fee > 0)
          transferCheckedIx(
            source: ataAddress(signer, token),
            mint: token,
            destination: ataAddress(paymasterSigner, token),
            authority: signer,
            amount: fee,
            decimals: decimals,
          ),
      ],
      feePayer: kora,
      recentBlockhash: blockhash,
    );
  }

  /// The paymaster must be the pinned key, as fee payer and as payment
  /// address, so a tampered response cannot take the fee (audit M-3).
  void _checkPaymasterKey(String signer, String paymentAddress) {
    if (signer != paymasterSigner || paymentAddress != paymasterSigner) {
      throw DeadmanException(
        'The fee service answered as $signer (payments to $paymentAddress), '
        'not the expected $paymasterSigner. Nothing was signed. Switch '
        'network fees back to SOL.',
        name: 'KoraUntrusted',
      );
    }
  }

  /// Drops token-account creates paid by [kora] whose account already
  /// exists: the paymaster prices a transaction by what it funds, so a
  /// no-op create would move it into a dearer tier. The paymaster never
  /// funds a token account of [signer]'s own wallet (audit M-1), so such a
  /// create (a token withdrawal into a closed account) is paid by [signer].
  Future<List<Instruction>> _withoutExistingKoraAtas(
    List<Instruction> ixs,
    String kora,
    String signer,
  ) async {
    bool koraAta(Instruction ix) =>
        ix.programId.toBase58() == ataProgramId &&
        ix.accounts.first.pubKey.toBase58() == kora;
    final atas = [
      for (final ix in ixs)
        if (koraAta(ix)) ix.accounts[1].pubKey.toBase58(),
    ];
    if (atas.isEmpty) return ixs;
    final accounts = await _net(
      () => _rpc
          .getMultipleAccounts(
            atas,
            commitment: commitment,
            encoding: Encoding.base64,
          )
          .value,
    );
    final existing = {
      for (var i = 0; i < atas.length; i++)
        if (accounts[i] != null) atas[i],
    };
    // withdraw_token pays into the signer's own account.
    final own = {
      for (final ix in ixs)
        if (ix.programId.toBase58() == AppConfig.programId &&
            hasDiscriminator(ix.data.toList(), Disc.withdrawToken))
          ix.accounts[4].pubKey.toBase58(),
    };
    var ownCreates = 0;
    final out = <Instruction>[];
    for (final ix in ixs) {
      final ata = koraAta(ix) ? ix.accounts[1].pubKey.toBase58() : null;
      if (ata == null) {
        out.add(ix);
      } else if (existing.contains(ata)) {
        continue;
      } else if (own.contains(ata)) {
        ownCreates++;
        out.add(
          createAtaIdempotentIx(
            payer: signer,
            owner: ix.accounts[2].pubKey.toBase58(),
            mint: ix.accounts[3].pubKey.toBase58(),
          ),
        );
      } else {
        out.add(ix);
      }
    }
    if (ownCreates > 0) {
      final rent = ownCreates * await _ataRent();
      final held = await balance(signer);
      if (held < rent) {
        throw DeadmanException(
          'This reopens your closed token account, which costs '
          '${_units(rent, 9)} SOL from your wallet (it holds '
          '${_units(held, 9)}). Add SOL first.',
          name: 'NoSolForAccount',
        );
      }
    }
    return out;
  }

  Future<int> _ataRent() async => _rent[165] ??= await _net(
    () => _rpc.getMinimumBalanceForRentExemption(165, commitment: commitment),
  );

  static String _tokenName(String mint) =>
      mint == AppConfig.usdcMint ? 'USDC' : 'token ${mint.substring(0, 4)}…';

  /// [amount] base units as a decimal string, e.g. 12340 at 6 -> 0.01234.
  static String _units(int amount, int decimals) {
    if (decimals == 0) return '$amount';
    final digits = amount.abs().toString().padLeft(decimals + 1, '0');
    final whole = digits.substring(0, digits.length - decimals);
    final frac = digits
        .substring(digits.length - decimals)
        .replaceFirst(RegExp(r'0+$'), '');
    return '${amount < 0 ? '-' : ''}$whole${frac.isEmpty ? '' : '.$frac'}';
  }

  /// Even with a sponsor the guard pays its own pulse or lockdown when the
  /// sponsor is down, so a new plan tops it up (later plans reuse a funded
  /// guard). When the paymaster pays fees the wallet may hold no SOL: the
  /// guard is then funded only if the wallet can spare it.
  Future<bool> _shouldFundGuard(
    String owner,
    String guard,
    int depositLamports,
  ) async {
    if (await balance(guard) >= AppConfig.guardFundingLamports) return false;
    if (!paysFeesInToken) return true;
    return await balance(owner) >=
        AppConfig.guardFundingLamports + depositLamports;
  }

  Future<VaultState> _ownedVault(String owner, int planId) async {
    final vault = await fetchVault(owner, planId);
    if (vault == null) throw const DeadmanException('Plan not found');
    return vault;
  }

  void _checkUnlocked(VaultState vault) {
    if (vault.isLocked(_now())) {
      throw DeadmanException.program(DeadmanException.vaultLocked);
    }
  }

  /// [held] is the vault's balance of [mint] (null = withdrawable SOL).
  static void _checkWithdrawable(
    VaultState vault,
    String? mint,
    int amount,
    int held,
  ) {
    if (amount > held) {
      throw DeadmanException.program(DeadmanException.insufficientFunds);
    }
    if (amount > held - vault.committed(mint)) {
      throw DeadmanException.program(DeadmanException.fundsCommitted);
    }
  }

  static Instruction _transfer(String from, String to, int lamports) =>
      SystemInstruction.transfer(
        fundingAccount: _pk(from),
        recipientAccount: _pk(to),
        lamports: lamports,
      );

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
