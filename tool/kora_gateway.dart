// Public entry to the Deadman Kora nodes (audit M-4). Kora listens behind an
// API key that only this gateway holds:
//
// - :8080 -> sponsor (:8090, free): a guard key's Deadman `pulse` /
//   `lockdown` on vaults it guards, or a beneficiary's own SOL claim
//   (`execute_sol_rule` / `release_vested_sol`), rate-limited per vault, per
//   signer and globally. Claims and lockdowns each have counters of their
//   own (audit M-3: pulses never use up the lockdown budget), and a
//   lockdown is sponsored only for a funded vault with a pending payout.
// - :8081 -> paymaster (:8091-8093, USDC: one fixed-price node per tier on
//   devnet, one margin-priced node on mainnet): owner-signed Deadman,
//   deposit and payment instructions; the last instruction must pay the
//   paymaster in USDC. Kora funds only the owner's new plan account and the
//   vault, beneficiary and treasury token accounts the transaction pays
//   into. Rate-limited per owner and globally; quota comes back when Kora
//   rejects the transaction.
//
// dart run tool/kora_gateway.dart
//
// Env: SPONSOR_API_KEY (required), RPC_URL, GATEWAY_PORT (8080),
// KORA_UPSTREAM (http://127.0.0.1:8090), GATEWAY_STATE
// (kora/gateway-usage.json), GATEWAY_PER_VAULT (24), GATEWAY_PER_SIGNER (48),
// GATEWAY_GLOBAL (2000), GATEWAY_PER_IP_MINUTE (60), GATEWAY_CLAIMS_STATE
// (kora/gateway-claims.json), GATEWAY_CLAIMS_PER_VAULT (12),
// GATEWAY_CLAIMS_PER_SIGNER (12), GATEWAY_CLAIMS_GLOBAL (500),
// GATEWAY_LOCKDOWNS_STATE (kora/gateway-lockdowns.json),
// GATEWAY_LOCKDOWNS_PER_VAULT (3), GATEWAY_LOCKDOWNS_PER_SIGNER (24),
// GATEWAY_LOCKDOWNS_GLOBAL (1000), GATEWAY_LOCKDOWN_MIN_LAMPORTS (10000000).
// Paymaster (enabled when PAYMASTER_API_KEY is set): PAYMASTER_PORT (8081),
// PAYMASTER_UPSTREAM (http://127.0.0.1:8091), PAYMASTER_STATE
// (kora/paymaster-usage.json), PAYMASTER_PER_OWNER (60), PAYMASTER_GLOBAL
// (2000), PAYMASTER_CREATES_STATE (kora/paymaster-creates.json),
// PAYMASTER_CREATES_PER_OWNER (3), PAYMASTER_CREATES_GLOBAL (20),
// PAYMASTER_ATAS_STATE (kora/paymaster-atas.json), PAYMASTER_ATAS_PER_OWNER
// (6), PAYMASTER_ATAS_GLOBAL (100).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:deadman/core/config.dart';
import 'package:deadman/solana/codec.dart'
    show
        Disc,
        ataProgramId,
        decodeVault,
        findPda,
        systemProgramId,
        token2022ProgramId,
        tokenProgramId,
        vaultAccountSize;
import 'package:deadman/solana/deadman_api.dart' show PlanKind, VaultState;
import 'package:http/http.dart' as http;
import 'package:solana/base58.dart';
import 'package:solana/dto.dart' show BinaryAccountData, Commitment, Encoding;
import 'package:solana/solana.dart';

const computeBudgetProgramId = ComputeBudgetProgram.programId;
const sponsorMethods = {
  'getPayerSigner',
  'getBlockhash',
  'signAndSendTransaction',
};
const paymasterMethods = {...sponsorMethods, 'estimateTransactionFee'};
const lamportsPerSignature = 5000;

/// A request the gateway refuses; sent back as a JSON-RPC error.
class GatewayRejection implements Exception {
  const GatewayRejection(this.message);
  final String message;

  @override
  String toString() => 'GatewayRejection: $message';
}

Never _reject(String message) => throw GatewayRejection(message);

class _Ix {
  const _Ix(this.programIndex, this.accounts, this.data);
  final int programIndex;
  final List<int> accounts;
  final Uint8List data;
}

class _Reader {
  _Reader(this._b);
  final List<int> _b;
  int offset = 0;

  bool get done => offset == _b.length;

  int u8() {
    if (offset >= _b.length) _reject('Malformed transaction');
    return _b[offset++];
  }

  Uint8List bytes(int n) {
    if (offset + n > _b.length) _reject('Malformed transaction');
    final out = Uint8List.fromList(_b.sublist(offset, offset + n));
    offset += n;
    return out;
  }

  /// compact-u16
  int shortVec() {
    var value = 0;
    for (var i = 0; i < 3; i++) {
      final b = u8();
      value |= (b & 0x7f) << (7 * i);
      if (b & 0x80 == 0) return value;
    }
    _reject('Malformed transaction');
  }
}

BigInt _uLe(List<int> b) {
  var v = BigInt.zero;
  for (var i = b.length - 1; i >= 0; i--) {
    v = (v << 8) | BigInt.from(b[i]);
  }
  return v;
}

bool _eq(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// A decoded wire transaction (legacy or v0 without lookup tables).
class _Tx {
  _Tx(List<int> wire) {
    final r = _Reader(wire);
    signatures = [for (var i = r.shortVec(); i > 0; i--) r.bytes(64)];
    messageStart = r.offset;
    if (messageStart < wire.length && wire[messageStart] & 0x80 != 0) {
      final version = r.u8() & 0x7f;
      if (version != 0) _reject('Unsupported transaction version $version');
      v0 = true;
    }
    requiredSigs = r.u8();
    readonlySigned = r.u8();
    readonlyUnsigned = r.u8();
    keys = [for (var i = r.shortVec(); i > 0; i--) base58encode(r.bytes(32))];
    r.bytes(32); // recent blockhash
    for (var n = r.shortVec(); n > 0; n--) {
      final program = r.u8();
      final accounts = [for (var i = r.shortVec(); i > 0; i--) r.u8()];
      ixs.add(_Ix(program, accounts, r.bytes(r.shortVec())));
    }
    if (v0 && r.shortVec() != 0) {
      _reject('Address lookup tables are not allowed');
    }
    if (!r.done) _reject('Malformed transaction');
    message = Uint8List.fromList(wire.sublist(messageStart));
  }

  late final List<Uint8List> signatures;
  late final int messageStart;
  late final Uint8List message;
  bool v0 = false;
  late final int requiredSigs;
  late final int readonlySigned;
  late final int readonlyUnsigned;
  late final List<String> keys;
  final ixs = <_Ix>[];

  /// The shape both nodes require: Kora (account 0, writable) and exactly
  /// one other signer, no duplicate keys, in-range indices.
  void requireKoraPlusOneSigner(String koraPayer, String noun, String who) {
    if (requiredSigs != 2 || signatures.length != 2) {
      _reject(
        '$noun transactions need exactly 2 signatures: the $who and the '
        '${who == 'sponsor' ? 'guard key' : 'owner'}',
      );
    }
    if (keys.length < 3 ||
        keys.toSet().length != keys.length ||
        readonlySigned > 1 ||
        requiredSigs + readonlyUnsigned > keys.length) {
      _reject('Malformed transaction');
    }
    if (keys[0] != koraPayer) {
      _reject('The $who $koraPayer must be the fee payer');
    }
    for (final ix in ixs) {
      if (ix.programIndex >= keys.length ||
          ix.accounts.any((a) => a >= keys.length)) {
        _reject('Malformed transaction');
      }
    }
  }
}

/// SetComputeUnitLimit / SetComputeUnitPrice, each at most once.
class _Budget {
  int? cuLimit;
  BigInt? cuPrice;

  void add(_Ix ix) {
    final d = ix.data;
    if (ix.accounts.isNotEmpty) _reject('Malformed ComputeBudget instruction');
    if (d.length == 5 && d[0] == 2 && cuLimit == null) {
      cuLimit = _uLe(d.sublist(1)).toInt();
    } else if (d.length == 9 && d[0] == 3 && cuPrice == null) {
      cuPrice = _uLe(d.sublist(1));
    } else {
      _reject(
        'Only one SetComputeUnitLimit and one SetComputeUnitPrice '
        'ComputeBudget instruction are allowed',
      );
    }
  }

  /// Base fee plus ceil(limit x price / 1e6); with no limit, [defaultCuPerIx]
  /// per instruction (capped at 1.4M) is assumed. Rejects above the caps.
  int fee({
    required int signatures,
    required int ixCount,
    required int maxCuLimit,
    required int maxFeeLamports,
  }) {
    final l = cuLimit;
    if (l != null && l > maxCuLimit) {
      _reject('Compute unit limit $l exceeds $maxCuLimit');
    }
    final limit = l ?? (defaultCuPerIx * ixCount).clamp(0, maxTxCu);
    final micro = BigInt.from(1000000);
    final priority =
        (BigInt.from(limit) * (cuPrice ?? BigInt.zero) + micro - BigInt.one) ~/
        micro;
    final fee = BigInt.from(signatures * lamportsPerSignature) + priority;
    if (fee > BigInt.from(maxFeeLamports)) {
      _reject('Fee $fee lamports exceeds the maximum of $maxFeeLamports');
    }
    return fee.toInt();
  }

  static const defaultCuPerIx = 200000;
  static const maxTxCu = 1400000;
}

// ---------------------------------------------------------------------------
// Sponsor (:8080 -> :8090)

class SponsorPolicy {
  const SponsorPolicy({
    required this.koraPayer,
    this.programId = AppConfig.programId,
  });

  static const maxCuLimit = 60000;
  static const maxFeeLamports = 50000;
  static const maxDeadmanIxs = 8;

  final String koraPayer;
  final String programId;
}

/// A beneficiary's SOL claim the sponsor pays for: Deadman [name] on rule
/// [index] of [vault], which must be a plan of [kind].
typedef SponsorClaim = ({String name, String vault, int index, PlanKind kind});

/// SOL claims the sponsor pays when the beneficiary claims for itself:
/// discriminator and the plan kind the program requires.
const sponsorClaimIxs = <String, ({List<int> disc, PlanKind kind})>{
  'execute_sol_rule': (disc: Disc.executeSolRule, kind: PlanKind.inheritance),
  'release_vested_sol': (disc: Disc.releaseVestedSol, kind: PlanKind.vesting),
};

/// A transaction that passed [validateSponsorTx]; the signature and the
/// vaults are checked next.
class SponsorRequest {
  const SponsorRequest({
    required this.signer,
    required this.vaults,
    required this.feeLamports,
    required this.message,
    required this.signature,
    this.claim,
    this.lockdown = false,
  });

  /// The one non-Kora signer: every vault's guard, or the claiming
  /// beneficiary.
  final String signer;

  /// Distinct vault accounts, in instruction order.
  final List<String> vaults;
  final int feeLamports;
  final Uint8List message;
  final Uint8List signature;

  /// Set when the transaction is a beneficiary's SOL claim (then its only
  /// Deadman instruction) rather than pulses and lockdowns.
  final SponsorClaim? claim;

  /// Whether every Deadman instruction is a lockdown (lockdowns never share
  /// a transaction with pulses, so they draw on their own budget).
  final bool lockdown;
}

/// Checks a wire transaction (base64-decoded, legacy or v0) against the
/// sponsor policy. Pure: the signature ([verifyGuardSignature]) and the
/// vault accounts ([checkVaultAccounts], [checkClaimVault]) are checked
/// separately.
SponsorRequest validateSponsorTx(List<int> wire, SponsorPolicy policy) {
  final tx = _Tx(wire)
    ..requireKoraPlusOneSigner(policy.koraPayer, 'Sponsored', 'sponsor');
  final keys = tx.keys;
  final signer = keys[1];
  final config = findPda([
    utf8.encode('config'),
  ], programId: policy.programId).address;

  final budget = _Budget();
  var deadmanIxs = 0;
  final vaults = <String>{};
  final claims = <SponsorClaim>[];
  var pulses = 0;
  var lockdowns = 0;
  for (final ix in tx.ixs) {
    if (ix.accounts.contains(0)) {
      _reject('Instructions may not reference the sponsor account');
    }
    final program = keys[ix.programIndex];
    final d = ix.data;
    final a = ix.accounts;
    if (program == computeBudgetProgramId) {
      budget.add(ix);
    } else if (program == policy.programId) {
      if (++deadmanIxs > SponsorPolicy.maxDeadmanIxs) {
        _reject(
          'At most ${SponsorPolicy.maxDeadmanIxs} Deadman instructions per '
          'transaction',
        );
      }
      final head = d.length >= 8 ? d.sublist(0, 8) : d;
      final claim = d.length == 9
          ? sponsorClaimIxs.entries
                .where((e) => _eq(head, e.value.disc))
                .firstOrNull
          : null;
      if (claim != null) {
        // [executor, vault, config, beneficiary, treasury]
        if (a.length != 5 || a[1] < tx.requiredSigs) {
          _reject('Malformed Deadman ${claim.key}');
        }
        if (keys[a[0]] != signer || keys[a[3]] != signer) {
          _reject(
            'The sponsor only pays a beneficiary claiming for itself: the '
            '${claim.key} executor and beneficiary must both be the signer',
          );
        }
        if (keys[a[2]] != config) _reject('Wrong Deadman config account');
        claims.add((
          name: claim.key,
          vault: keys[a[1]],
          index: d[8],
          kind: claim.value.kind,
        ));
        vaults.add(keys[a[1]]);
      } else if (d.length == 8 &&
          (_eq(d, Disc.pulse) || _eq(d, Disc.lockdown))) {
        if (a.length != 2 || a[1] < tx.requiredSigs) {
          _reject('Malformed Deadman instruction');
        }
        if (keys[a[0]] != signer) {
          _reject(
            "Each pulse/lockdown must be signed by the transaction's guard key",
          );
        }
        if (_eq(d, Disc.lockdown)) {
          lockdowns++;
        } else {
          pulses++;
        }
        vaults.add(keys[a[1]]);
      } else if (_eq(head, Disc.executeTokenRule) ||
          _eq(head, Disc.releaseVestedToken)) {
        _reject(
          'Token claims are not sponsored: send them to the paymaster, where '
          'the payout pays the USDC fee',
        );
      } else {
        _reject(
          'Only Deadman pulse, lockdown and a beneficiary\'s own SOL claim '
          '(execute_sol_rule / release_vested_sol) are sponsored',
        );
      }
    } else {
      _reject('Program $program is not sponsored');
    }
  }
  if (deadmanIxs == 0) {
    _reject('No Deadman pulse, lockdown or SOL claim to sponsor');
  }
  if (claims.isNotEmpty && deadmanIxs != 1) {
    _reject(
      'A sponsored claim must be the only Deadman instruction in its '
      'transaction',
    );
  }
  if (pulses > 0 && lockdowns > 0) {
    _reject('Send lockdowns in a transaction of their own, without pulses');
  }
  final fee = budget.fee(
    signatures: tx.requiredSigs,
    ixCount: tx.ixs.length,
    maxCuLimit: SponsorPolicy.maxCuLimit,
    maxFeeLamports: SponsorPolicy.maxFeeLamports,
  );
  return SponsorRequest(
    signer: signer,
    vaults: vaults.toList(),
    feeLamports: fee,
    message: tx.message,
    signature: tx.signatures[1],
    claim: claims.firstOrNull,
    lockdown: lockdowns > 0,
  );
}

Future<bool> _signedBy(String signer, Uint8List message, Uint8List sig) =>
    verifySignature(
      message: message,
      signature: sig,
      publicKey: Ed25519HDPublicKey.fromBase58(signer),
    );

/// Whether the signer's (guard's or claimer's) signature is valid, so a
/// stranger cannot burn a vault's quota with unsigned copies.
Future<bool> verifyGuardSignature(SponsorRequest request) =>
    _signedBy(request.signer, request.message, request.signature);

/// An account as `getMultipleAccounts` returns it: owner program, data and
/// lamports.
typedef VaultAccount = ({String owner, Uint8List data, int lamports});

/// Rent-exempt minimum of an account of [dataLen] bytes at the runtime's
/// default rent (3480 lamports per byte-year, two years, 128 bytes of
/// account overhead). A cluster may charge less; the gateway asks the RPC
/// at startup ([SponsorRoute.vaultRent]).
int rentExemptLamports(int dataLen) => (dataLen + 128) * 6960;

/// Requires every vault to be a Deadman vault whose guard is the signer, and
/// the signer to be neither its owner nor its guardian (owner wallets pay
/// their own fees; the guardian's lockdown is not sponsored).
void checkVaultAccounts(
  SponsorRequest request,
  List<VaultAccount?> accounts,
  SponsorPolicy policy,
) {
  if (accounts.length != request.vaults.length) {
    _reject('Could not load the vault accounts');
  }
  for (var i = 0; i < accounts.length; i++) {
    final vault = request.vaults[i];
    final a = accounts[i];
    if (a == null) _reject('Vault $vault not found');
    final d = a.data;
    if (a.owner != policy.programId ||
        d.length < 75 ||
        !_eq(d.sublist(0, 8), Disc.vaultAccount)) {
      _reject('$vault is not a Deadman vault');
    }
    final owner = base58encode(d.sublist(8, 40));
    final guard = base58encode(d.sublist(42, 74));
    final guardian = d[74] == 1 && d.length >= 107
        ? base58encode(d.sublist(75, 107))
        : null;
    if (request.signer == owner) {
      _reject('Owner-signed transactions are not sponsored; the wallet pays');
    }
    if (request.signer == guardian) {
      _reject('Guardian-signed transactions are not sponsored');
    }
    if (request.signer != guard) {
      _reject('${request.signer} is not the guard key of vault $vault');
    }
  }
}

/// A current-layout Deadman vault, decoded; null if [a] is not one.
VaultState? _decodeCurrentVault(
  VaultAccount? a,
  String programId, {
  int? rentExemptMinimum,
}) {
  if (a == null ||
      a.owner != programId ||
      a.data.length != vaultAccountSize ||
      !_eq(a.data.sublist(0, 8), Disc.vaultAccount)) {
    return null;
  }
  try {
    return decodeVault(
      a.data,
      address: '',
      lamports: a.lamports,
      rentExemptMinimum: rentExemptMinimum ?? rentExemptLamports(a.data.length),
    );
  } on FormatException {
    return null;
  }
}

/// Requires rule [index] of [account] (the vault, `getMultipleAccounts`)
/// to be a pending rule of a [kind] plan paying [beneficiary] in [mint]
/// (null = SOL). [what] names the claim in rejections.
void _checkClaimRule(
  VaultAccount? account, {
  required String vault,
  required String programId,
  required int index,
  required PlanKind kind,
  required String beneficiary,
  required String? mint,
  required String what,
}) {
  final v = _decodeCurrentVault(account, programId);
  if (v == null) _reject('$vault is not a current Deadman vault');
  if (v.kind != kind) {
    String plan(PlanKind k) =>
        k == PlanKind.inheritance ? 'an inheritance plan' : 'a vesting plan';
    _reject('$what needs ${plan(kind)}; $vault is ${plan(v.kind)}');
  }
  if (index >= v.rules.length) _reject('Vault $vault has no rule $index');
  final rule = v.rules[index];
  if (rule.beneficiary != beneficiary) {
    _reject('$beneficiary is not the beneficiary of rule $index of $vault');
  }
  if (rule.mint != mint) {
    _reject(
      'Rule $index of $vault pays ${rule.mint ?? 'SOL'}, not ${mint ?? 'SOL'}',
    );
  }
  if (rule.executed) _reject('Rule $index of $vault is already fully paid');
}

/// Requires the claim's vault to be a current-layout Deadman vault whose
/// rule pays the signer in SOL, of the plan kind the instruction needs,
/// and not yet fully paid.
void checkClaimVault(
  SponsorRequest request,
  List<VaultAccount?> accounts,
  SponsorPolicy policy,
) {
  final claim = request.claim!;
  if (accounts.length != 1) _reject('Could not load the vault account');
  _checkClaimRule(
    accounts.single,
    vault: claim.vault,
    programId: policy.programId,
    index: claim.index,
    kind: claim.kind,
    beneficiary: request.signer,
    mint: null,
    what: claim.name,
  );
}

/// Default for [SponsorRoute.minLockdownLamports]: 0.01 SOL.
const defaultMinLockdownLamports = 10000000;

/// Whether [a] (the vault at [address]) is worth a sponsored lockdown
/// (audit M-3): a current-layout plan, not revoked, with a payout still
/// pending, that holds at least [minLamports] above its rent ([vaultRent])
/// or a token a
/// pending rule pays. [holdsTokens] tells whether the vault's classic SPL
/// Token ATA of any of the given mints holds a balance; it is only called
/// when the SOL test fails.
Future<bool> isFundedVault(
  VaultAccount? a,
  String address,
  String programId, {
  required int minLamports,
  required int vaultRent,
  required Future<bool> Function(String vault, Set<String> mints) holdsTokens,
}) async {
  final v = _decodeCurrentVault(a, programId, rentExemptMinimum: vaultRent);
  if (v == null || v.revokedAt != 0) return false;
  final pending = [
    for (final r in v.rules)
      if (!r.executed) r,
  ];
  if (pending.isEmpty) return false;
  if (v.withdrawableLamports >= minLamports) return true;
  final mints = {for (final r in pending) ?r.mint};
  return mints.isNotEmpty && await holdsTokens(address, mints);
}

// ---------------------------------------------------------------------------
// Paymaster (:8081 -> :8091)

/// What Kora funds in a paid transaction, which picks the Kora node (and
/// so the fixed price): nothing ([basic]), up to
/// [PaymasterPolicy.maxKoraAtas] token accounts ([account]), or a new
/// vault's rent, which comes back on close ([plan]).
enum PaymasterTier { basic, account, plan }

/// A paymaster token account that accepts the fee: the ATA of Kora's payment
/// address for [mint] under [tokenProgram]. [minAmounts] is each tier's
/// fixed price in this mint's base units.
typedef PaymentAta = ({
  String mint,
  String tokenProgram,
  Map<PaymasterTier, int> minAmounts,
});

/// A Deadman instruction the paymaster pays for: its exact account count
/// (plus up to [PaymasterPolicy.maxExtraAccounts] remaining accounts when
/// [extra]: the token mints a plan names, or Token-2022 hook accounts of a
/// withdrawal) and the one account slot that may be the Kora payer.
typedef DeadmanIxSpec = ({
  List<int> disc,
  int accounts,
  bool extra,
  int? koraSlot,
});

/// Discriminators from onchain/target/idl/deadman.json.
const paymasterDeadmanIxs = <String, DeadmanIxSpec>{
  // payer (slot 1) = Kora: the program CPIs System create_account (or a
  // top-up of a pre-funded address) from Kora, and records what Kora
  // actually paid as rent_paid, which close_vault gives back. Then one
  // read-only mint account per token the rules name.
  'create_plan': (
    disc: [77, 43, 141, 254, 212, 118, 41, 186],
    accounts: 4,
    extra: true,
    koraSlot: 1,
  ),
  'create_vesting': (
    disc: [135, 184, 171, 156, 197, 162, 246, 44],
    accounts: 4,
    extra: true,
    koraSlot: 1,
  ),
  'update_plan': (
    disc: [119, 112, 58, 60, 76, 205, 1, 100],
    accounts: 2,
    extra: true,
    koraSlot: null,
  ),
  'set_guard': (
    disc: [250, 44, 173, 235, 219, 76, 36, 198],
    accounts: 2,
    extra: false,
    koraSlot: null,
  ),
  'pulse': (
    disc: [192, 224, 96, 191, 190, 177, 63, 34],
    accounts: 2,
    extra: false,
    koraSlot: null,
  ),
  'lockdown': (
    disc: [21, 66, 102, 35, 233, 188, 139, 9],
    accounts: 2,
    extra: false,
    koraSlot: null,
  ),
  'withdraw_sol': (
    disc: [145, 131, 74, 136, 65, 137, 42, 38],
    accounts: 2,
    extra: false,
    koraSlot: null,
  ),
  'withdraw_token': (
    disc: [136, 235, 181, 5, 101, 109, 57, 81],
    accounts: 6,
    extra: true,
    koraSlot: null,
  ),
  'execute_sol_rule': (
    disc: [27, 74, 220, 147, 58, 73, 241, 103],
    accounts: 5,
    extra: false,
    koraSlot: null,
  ),
  'execute_token_rule': (
    disc: [172, 93, 237, 201, 225, 26, 97, 140],
    accounts: 9,
    extra: false,
    koraSlot: null,
  ),
  'skip_rule': (
    disc: [240, 82, 139, 70, 215, 222, 129, 174],
    accounts: 3,
    extra: false,
    koraSlot: null,
  ),
  'release_vested_sol': (
    disc: [136, 188, 48, 45, 14, 211, 200, 228],
    accounts: 5,
    extra: false,
    koraSlot: null,
  ),
  'release_vested_token': (
    disc: [50, 241, 129, 168, 233, 106, 179, 16],
    accounts: 9,
    extra: false,
    koraSlot: null,
  ),
  'revoke_vesting': (
    disc: [12, 252, 252, 168, 39, 101, 98, 9],
    accounts: 2,
    extra: false,
    koraSlot: null,
  ),
  // rent_payer (slot 2) is a lamport destination: the rent comes back to Kora.
  'close_vault': (
    disc: [141, 103, 17, 126, 72, 75, 29, 29],
    accounts: 3,
    extra: false,
    koraSlot: 2,
  ),
};

/// Named so rejections are readable; never paid for.
const _deniedDeadmanIxs = <String, List<int>>{
  'init_config': [23, 235, 115, 232, 168, 96, 1, 231],
  'set_config': [108, 158, 154, 175, 212, 98, 52, 66],
  'propose_admin': [121, 214, 199, 212, 87, 39, 117, 234],
  'accept_admin': [112, 42, 45, 90, 116, 181, 13, 170],
  'unlock': [101, 155, 40, 21, 158, 189, 56, 203],
};

class PaymasterPolicy {
  const PaymasterPolicy({
    required this.koraPayer,
    required this.paymentAtas,
    this.programId = AppConfig.programId,
  });

  static const maxCuLimit = 400000;
  static const maxFeeLamports = 50000;
  static const maxIxs = 12;
  static const maxExtraAccounts = 8;
  static const maxKoraAtas = 2;

  final String koraPayer;

  /// Payment token account -> what it accepts.
  final Map<String, PaymentAta> paymentAtas;
  final String programId;

  Set<String> get mints => {for (final a in paymentAtas.values) a.mint};
}

typedef Payment = ({String mint, String destination, int amount});

/// A token claim whose payout to the signer funds the paymaster fee:
/// Deadman [name] on rule [index] of [vault] (a [kind] plan) paying [mint].
typedef PaymasterClaim = ({
  String name,
  String vault,
  int index,
  PlanKind kind,
  String mint,
});

/// A transaction that passed [validatePaymasterTx]; the owner signature is
/// checked next ([verifyOwnerSignature]).
class PaymasterRequest {
  const PaymasterRequest({
    required this.signer,
    required this.instructions,
    required this.koraFundsRent,
    required this.koraAtas,
    required this.feeLamports,
    required this.payment,
    required this.message,
    required this.signature,
    this.paymentSource,
    this.paymentSourceNeeds,
    this.paymentSourceCreated = false,
    this.vaultChecks = const [],
    this.fundingClaim,
    this.koraFundedPlan,
  });

  /// The one non-Kora signer (vault owner, executor or depositor).
  final String signer;

  /// Instruction names, e.g. `deadman.create_plan`, `token.transfer_checked`.
  final List<String> instructions;

  /// Whether Kora is the `payer` of a create_plan / create_vesting (one
  /// account per transaction).
  final bool koraFundsRent;

  /// Associated token accounts created with Kora as the payer.
  final int koraAtas;
  final int feeLamports;

  PaymasterTier get tier => koraFundsRent
      ? PaymasterTier.plan
      : koraAtas > 0
      ? PaymasterTier.account
      : PaymasterTier.basic;

  /// The final USDC payment; null only when validated for an estimate.
  final Payment? payment;
  final Uint8List message;
  final Uint8List signature;

  /// The token account the payment comes from, and what it must hold before
  /// the transaction: every transfer out of it (the payment included) minus
  /// what a `withdraw_token` in the transaction pays into it.
  final String? paymentSource;
  final BigInt? paymentSourceNeeds;

  /// Whether an ATA create in the transaction opens [paymentSource].
  final bool paymentSourceCreated;

  /// Wallets of Kora-funded deposit ATAs that no Deadman instruction in the
  /// transaction names as its vault; each must be a Deadman vault on chain.
  final List<String> vaultChecks;

  /// The signer's own token claim that pays into [paymentSource] in the
  /// payment mint, earlier in the transaction. Its payout is not known
  /// before it runs, so the balance check is left to Kora's simulation and
  /// the vault's rule is checked on chain instead.
  final PaymasterClaim? fundingClaim;

  /// The plan account Kora pays the rent of, if any. It must not exist yet:
  /// the program tops up a pre-funded address with a System transfer,
  /// which Kora's fee payer policy refuses (and the plan price assumes the
  /// full rent).
  final String? koraFundedPlan;
}

/// A token account the transaction asks Kora to open.
typedef _KoraAta = ({String ata, String wallet, String mint});

/// Checks a wire transaction against the paymaster policy. Pure; the owner
/// signature is verified separately. With [requirePayment] false (fee
/// estimates), a final payment is optional.
PaymasterRequest validatePaymasterTx(
  List<int> wire,
  PaymasterPolicy policy, {
  bool requirePayment = true,
}) {
  final tx = _Tx(wire)
    ..requireKoraPlusOneSigner(policy.koraPayer, 'Paymaster', 'paymaster');
  final keys = tx.keys;
  final ixs = tx.ixs;
  if (ixs.isEmpty || ixs.length > PaymasterPolicy.maxIxs) {
    _reject('A transaction needs 1 to ${PaymasterPolicy.maxIxs} instructions');
  }
  const kora = 0;
  const owner = 1;

  final budget = _Budget();
  final names = <String>[];
  var koraCreates = 0;
  String? koraFundedPlan;
  final koraAtas = <_KoraAta>[];
  final createdAtas = <String>{};
  // What may justify a Kora-funded ATA (audit M-1).
  final deposits = <(String, String)>{}; // (destination ATA, mint)
  final vaults = <String>{}; // vault account of each Deadman instruction
  final payouts = <(String, String?, String)>{}; // (ATA, wallet?, mint)
  // Token claims: (beneficiary ATA, beneficiary, claim).
  final claims = <(String, String, PaymasterClaim)>[];
  final outflow = <String, BigInt>{};
  final credits = <String, BigInt>{};
  Payment? lastPayment;
  for (var i = 0; i < ixs.length; i++) {
    final ix = ixs[i];
    final a = ix.accounts;
    final d = ix.data;
    final program = keys[ix.programIndex];
    lastPayment = null;
    if (program == computeBudgetProgramId) {
      budget.add(ix);
      names.add('compute_budget');
    } else if (program == ataProgramId) {
      if (d.length != 1 || d[0] != 1 || a.length != 6) {
        _reject('Only Associated Token CreateIdempotent is allowed');
      }
      // [payer, ata, wallet, mint, system, token program]
      if (a.skip(1).contains(kora)) {
        _reject(
          'The paymaster can only be the payer of an Associated Token '
          'create',
        );
      }
      if (a[0] != owner && a[0] != kora) {
        _reject(
          'Associated token accounts are paid by the owner or the paymaster',
        );
      }
      createdAtas.add(keys[a[1]]);
      if (a[0] == kora) {
        koraAtas.add((ata: keys[a[1]], wallet: keys[a[2]], mint: keys[a[3]]));
        if (koraAtas.length > PaymasterPolicy.maxKoraAtas) {
          _reject(
            'At most ${PaymasterPolicy.maxKoraAtas} paymaster-funded token '
            'accounts per transaction',
          );
        }
      }
      names.add('ata.create_idempotent');
    } else if (program == tokenProgramId || program == token2022ProgramId) {
      final int authority;
      final int destination;
      int? mint;
      if (d.length == 10 && d[0] == 12 && a.length == 4) {
        (mint, destination, authority) = (a[1], a[2], a[3]);
        names.add('token.transfer_checked');
      } else if (d.length == 9 && d[0] == 3 && a.length == 3) {
        (destination, authority) = (a[1], a[2]);
        names.add('token.transfer');
      } else {
        _reject('Only single-signer token Transfer / TransferChecked allowed');
      }
      if (authority == kora) {
        _reject('The paymaster cannot be a token authority');
      }
      if (a.contains(kora)) {
        _reject('The paymaster cannot be a token account');
      }
      if (authority != owner) {
        _reject(
          "Token transfers must be authorized by the transaction's owner",
        );
      }
      final value = _uLe(d.sublist(1, 9));
      outflow.update(keys[a[0]], (v) => v + value, ifAbsent: () => value);
      if (mint != null && value > BigInt.zero) {
        deposits.add((keys[destination], keys[mint]));
      }
      final ata = policy.paymentAtas[keys[destination]];
      if (ata != null) {
        if (ata.tokenProgram != program ||
            (mint != null && keys[mint] != ata.mint)) {
          _reject('Payment to ${keys[destination]} uses the wrong mint');
        }
        lastPayment = (
          mint: ata.mint,
          destination: keys[destination],
          amount: value.isValidInt ? value.toInt() : -1,
        );
      }
    } else if (program == systemProgramId) {
      if (d.length != 12 || _uLe(d.sublist(0, 4)).toInt() != 2) {
        _reject('Only System transfers (deposits) are allowed');
      }
      if (a.length != 2) _reject('Malformed System transfer');
      if (a[0] == kora) _reject('The paymaster cannot fund a System transfer');
      if (a[0] != owner) {
        _reject("System transfers must come from the transaction's owner");
      }
      if (a[1] == kora) {
        _reject('The paymaster cannot receive a System transfer');
      }
      names.add('system.transfer');
    } else if (program == policy.programId) {
      final entry = d.length < 8
          ? null
          : paymasterDeadmanIxs.entries
                .where((e) => _eq(d.sublist(0, 8), e.value.disc))
                .firstOrNull;
      if (entry == null) {
        final denied = d.length < 8
            ? null
            : _deniedDeadmanIxs.entries
                  .where((e) => _eq(d.sublist(0, 8), e.value))
                  .firstOrNull;
        _reject(
          'Deadman ${denied?.key ?? 'instruction'} is not paid by the '
          'paymaster',
        );
      }
      final name = entry.key;
      final spec = entry.value;
      final max =
          spec.accounts + (spec.extra ? PaymasterPolicy.maxExtraAccounts : 0);
      if (a.length < spec.accounts || a.length > max) {
        _reject('Malformed Deadman $name');
      }
      if (a[0] != owner) {
        _reject("Deadman $name must be signed by the transaction's owner");
      }
      for (var j = 1; j < a.length; j++) {
        if (a[j] == kora && j != spec.koraSlot) {
          _reject(
            'The paymaster may only be the payer of create_plan / '
            'create_vesting or the rent_payer of close_vault',
          );
        }
      }
      if (spec.koraSlot == 1) {
        if (a[1] != kora && a[1] != owner) {
          _reject('The $name payer must be the paymaster or the owner');
        }
        if (a[1] == kora && ++koraCreates > 1) {
          _reject('At most one paymaster-funded account per transaction');
        }
        if (a[1] == kora) koraFundedPlan = keys[a[2]];
      }
      vaults.add(keys[a[spec.koraSlot == 1 ? 2 : 1]]);
      if (name == 'withdraw_token' && d.length >= 16) {
        // [owner, vault, mint, vault_token, owner_token, token_program]
        final amount = _uLe(d.sublist(8, 16));
        credits.update(keys[a[4]], (v) => v + amount, ifAbsent: () => amount);
      }
      if (name == 'execute_token_rule' || name == 'release_vested_token') {
        // [executor, vault, config, mint, vault_token, beneficiary,
        //  beneficiary_token, treasury_token, token_program]. The program
        // binds beneficiary_token to the beneficiary and treasury_token to
        // the treasury's ATA; treasury_token is the program id when no fee
        // goes to the treasury.
        final mint = keys[a[3]];
        payouts.add((keys[a[6]], keys[a[5]], mint));
        if (keys[a[7]] != policy.programId) {
          payouts.add((keys[a[7]], null, mint));
        }
        if (d.length == 9) {
          claims.add((
            keys[a[6]],
            keys[a[5]],
            (
              name: name,
              vault: keys[a[1]],
              index: d[8],
              kind: name == 'execute_token_rule'
                  ? PlanKind.inheritance
                  : PlanKind.vesting,
              mint: mint,
            ),
          ));
        }
      }
      names.add('deadman.$name');
    } else {
      _reject('Program $program is not allowed by the paymaster');
    }
  }
  if (lastPayment == null && requirePayment) {
    _reject(
      'The last instruction must pay the paymaster: a token transfer to '
      '${policy.paymentAtas.keys.join(' or ')}',
    );
  }
  // Kora funds only token accounts the transaction pays into (audit M-1):
  // a vault's ATA with a deposit of that mint, or a payout's beneficiary or
  // treasury ATA. Never an account its signer could close for the rent.
  final vaultChecks = <String>[];
  for (final c in koraAtas) {
    final payout = payouts.any(
      (p) => p.$1 == c.ata && p.$3 == c.mint && (p.$2 ?? c.wallet) == c.wallet,
    );
    if (payout) continue;
    if (!deposits.contains((c.ata, c.mint))) {
      _reject(
        'The paymaster only funds a token account the transaction pays '
        "into: a plan vault's (with a deposit of that mint) or a payout's "
        'beneficiary or treasury. ${c.wallet} (mint ${c.mint}) is neither',
      );
    }
    if (!vaults.contains(c.wallet)) vaultChecks.add(c.wallet);
  }

  final tier = koraCreates > 0
      ? PaymasterTier.plan
      : koraAtas.isNotEmpty
      ? PaymasterTier.account
      : PaymasterTier.basic;
  if (lastPayment != null) {
    final min =
        policy.paymentAtas[lastPayment.destination]!.minAmounts[tier] ?? 0;
    if (lastPayment.amount < min) {
      _reject(
        'Payment ${lastPayment.amount} is below the ${tier.name} price $min '
        '(${lastPayment.mint} base units)',
      );
    }
  }
  final fee = budget.fee(
    signatures: tx.requiredSigs,
    ixCount: ixs.length,
    maxCuLimit: PaymasterPolicy.maxCuLimit,
    maxFeeLamports: PaymasterPolicy.maxFeeLamports,
  );
  final source = lastPayment == null ? null : keys[ixs.last.accounts[0]];
  // A claimer with no USDC pays the fee out of the payout it just received.
  final fundingClaim = claims
      .where(
        (c) =>
            c.$1 == source &&
            c.$2 == keys[owner] &&
            c.$3.mint == lastPayment?.mint,
      )
      .firstOrNull
      ?.$3;
  return PaymasterRequest(
    signer: keys[owner],
    instructions: names,
    koraFundsRent: koraCreates > 0,
    koraAtas: koraAtas.length,
    feeLamports: fee,
    payment: lastPayment,
    message: tx.message,
    signature: tx.signatures[owner],
    paymentSource: source,
    paymentSourceNeeds: source == null
        ? null
        : outflow[source]! - (credits[source] ?? BigInt.zero),
    paymentSourceCreated: createdAtas.contains(source),
    vaultChecks: vaultChecks.toSet().toList(),
    fundingClaim: fundingClaim,
    koraFundedPlan: koraFundedPlan,
  );
}

/// Whether the owner's signature is valid, so nobody can burn an owner's
/// quota (or Kora's rent float) with unsigned copies.
Future<bool> verifyOwnerSignature(PaymasterRequest request) =>
    _signedBy(request.signer, request.message, request.signature);

// ---------------------------------------------------------------------------
// Rate limits

/// Rolling-window counters per vault, per signer and global, persisted to
/// [file] after every admitted transaction.
class UsageLimiter {
  UsageLimiter({
    this.perVault = 24,
    this.perSigner = 48,
    this.global = 2000,
    this.windowSecs = 86400,
    this.file,
    this.service = 'the sponsor',
    this.signerLabel = 'guard key',
    this.unit = 'sponsored transactions',
    int Function()? clock,
  }) : _now = clock ?? _systemNow {
    _load();
  }

  final int perVault;
  final int perSigner;
  final int global;
  final int windowSecs;
  final File? file;
  final String service;
  final String signerLabel;
  final String unit;
  final int Function() _now;

  final _vaults = <String, List<int>>{};
  final _signers = <String, List<int>>{};
  final _global = <int>[];

  static int _systemNow() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  /// Throws if [n] more transactions would exceed a limit; records nothing.
  void check(String signer, List<String> vaults, {int n = 1}) {
    final now = _now();
    _prune(now);
    String retry(List<int> hits) => DateTime.fromMillisecondsSinceEpoch(
      (hits.first + windowSecs) * 1000,
      isUtc: true,
    ).toIso8601String();
    if (_global.length + n > global) {
      _reject(
        'Rate limit: $service reached its cap of $global $unit per 24h; '
        'retry after ${retry(_global)}',
      );
    }
    final s = _signers[signer] ?? const [];
    if (s.length + n > perSigner) {
      _reject(
        'Rate limit: $signerLabel $signer reached $perSigner $unit per 24h; '
        'retry after ${retry(s)}',
      );
    }
    for (final v in vaults) {
      final hits = _vaults[v] ?? const [];
      if (hits.length + n > perVault) {
        _reject(
          'Rate limit: vault $v reached $perVault $unit per 24h; '
          'retry after ${retry(hits)}',
        );
      }
    }
  }

  /// [check], then records [n] transactions and returns their timestamp
  /// for [release]. Synchronous, so concurrent requests cannot both pass the
  /// last free slot.
  int acquire(String signer, List<String> vaults, {int n = 1}) {
    check(signer, vaults, n: n);
    final now = _now();
    for (var i = 0; i < n; i++) {
      _global.add(now);
      (_signers[signer] ??= []).add(now);
      for (final v in vaults.toSet()) {
        (_vaults[v] ??= []).add(now);
      }
    }
    _save();
    return now;
  }

  /// Gives back [n] slots taken by [acquire] at [at] (the upstream rejected
  /// the transaction, so it cost nothing).
  void release(String signer, List<String> vaults, int at, {int n = 1}) {
    void drop(List<int>? hits) {
      for (var i = 0; i < n; i++) {
        hits?.remove(at);
      }
    }

    drop(_global);
    drop(_signers[signer]);
    for (final v in vaults.toSet()) {
      drop(_vaults[v]);
    }
    _prune(_now());
    _save();
  }

  void _prune(int now) {
    final cutoff = now - windowSecs;
    _global.removeWhere((t) => t <= cutoff);
    for (final m in [_vaults, _signers]) {
      m.removeWhere(
        (_, hits) => (hits..removeWhere((t) => t <= cutoff)).isEmpty,
      );
    }
  }

  Map<String, Object> toJson() => {
    'global': _global,
    'signers': _signers,
    'vaults': _vaults,
  };

  void _load() {
    final f = file;
    if (f == null || !f.existsSync()) return;
    try {
      final j = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      List<int> ints(Object? l) => [for (final t in l as List) t as int];
      _global.addAll(ints(j['global']));
      for (final (key, into) in [('signers', _signers), ('vaults', _vaults)]) {
        (j[key] as Map<String, dynamic>).forEach((k, v) => into[k] = ints(v));
      }
    } on Object catch (e) {
      stderr.writeln('Ignoring unreadable usage file ${f.path}: $e');
    }
  }

  void _save() {
    final f = file;
    if (f == null) return;
    final tmp = File('${f.path}.tmp')..writeAsStringSync(jsonEncode(toJson()));
    tmp.renameSync(f.path);
  }
}

/// Fixed one-minute window per client IP, to keep junk off the upstream.
class _IpLimiter {
  _IpLimiter(this.perMinute);
  final int perMinute;
  final _hits = <String, (int, int)>{};

  bool allow(String ip, int nowSecs) {
    final window = nowSecs ~/ 60;
    if (_hits.length > 10000) _hits.removeWhere((_, e) => e.$1 != window);
    final e = _hits[ip];
    final count = e == null || e.$1 != window ? 1 : e.$2 + 1;
    _hits[ip] = (window, count);
    return count <= perMinute;
  }
}

// ---------------------------------------------------------------------------
// Routes and HTTP

/// An admitted transaction: a log [summary], and [release], which gives
/// back the quota it reserved when the upstream Kora rejects it.
typedef Admission = ({String summary, void Function() release});

/// What one public listener admits.
abstract interface class GatewayRoute {
  /// "sponsor" or "paymaster".
  String get name;
  Set<String> get methods;

  /// Validates [wire] and reserves rate-limit quota.
  Future<Admission> admit(List<int> wire);

  /// Validates an `estimateTransactionFee` request; returns the params to
  /// forward.
  Map<String, Object> admitEstimate(String tx, Object? feeToken);

  /// The Kora node for an admitted [wire] transaction; null = the default.
  Uri? upstreamFor(List<int> wire);

  /// The least `fee_in_token` this route accepts for [wire] paid in
  /// [feeToken]; estimates below it are raised to it. Null = no floor.
  int? minFee(List<int> wire, Object? feeToken);
}

class SponsorRoute implements GatewayRoute {
  SponsorRoute({
    required this.policy,
    required this.limiter,
    required this.fetchAccounts,
    UsageLimiter? claims,
    UsageLimiter? lockdowns,
    this.minLockdownLamports = defaultMinLockdownLamports,
    int? vaultRent,
  }) : claims =
           claims ??
           UsageLimiter(
             perVault: 12,
             perSigner: 12,
             global: 500,
             signerLabel: 'claimer',
             unit: 'sponsored claims',
           ),
       lockdowns =
           lockdowns ??
           UsageLimiter(
             perVault: 3,
             perSigner: 24,
             global: 1000,
             unit: lockdownUnit,
           ),
       vaultRent = vaultRent ?? rentExemptLamports(vaultAccountSize);

  static const lockdownUnit = 'sponsored lockdowns';

  final SponsorPolicy policy;

  /// Guard pulses.
  final UsageLimiter limiter;

  /// Beneficiaries' SOL claims, per vault, per claimer and global.
  final UsageLimiter claims;

  /// Guard lockdowns (audit M-3): a budget of their own, so pulses and
  /// claims never use it up, a few per vault, and only for funded vaults
  /// (see [isFundedVault]).
  final UsageLimiter lockdowns;

  /// What a vault must hold above its rent, in SOL, for a sponsored
  /// lockdown when it holds none of its rules' tokens.
  final int minLockdownLamports;

  /// Rent-exempt minimum of a vault on this cluster.
  final int vaultRent;
  final Future<List<VaultAccount?>> Function(List<String>) fetchAccounts;

  @override
  String get name => 'sponsor';

  @override
  Set<String> get methods => sponsorMethods;

  @override
  Future<Admission> admit(List<int> wire) async {
    final request = validateSponsorTx(wire, policy);
    final claim = request.claim;
    if (!await verifyGuardSignature(request)) {
      _reject('Invalid ${claim == null ? 'guard' : 'claimer'} signature');
    }
    final quota = claim != null
        ? claims
        : request.lockdown
        ? lockdowns
        : limiter;
    quota.check(request.signer, request.vaults);
    final accounts = await fetchAccounts(request.vaults);
    if (claim == null) {
      checkVaultAccounts(request, accounts, policy);
      if (request.lockdown) await _checkFunded(request, accounts);
    } else {
      checkClaimVault(request, accounts, policy);
    }
    final at = quota.acquire(request.signer, request.vaults);
    return (
      summary:
          '${claim == null ? '' : 'claim=${claim.name}#${claim.index} '}'
          '${request.lockdown ? 'lockdown ' : ''}'
          'signer=${request.signer} vaults=${request.vaults.join(',')} '
          'fee<=${request.feeLamports}',
      release: () => quota.release(request.signer, request.vaults, at),
    );
  }

  /// At least one of the vaults must be funded: an empty plan locked along
  /// with the owner's other plans is fine, a guard of empty plans only is
  /// not sponsored (it can still pay its own lockdown).
  Future<void> _checkFunded(
    SponsorRequest request,
    List<VaultAccount?> accounts,
  ) async {
    for (var i = 0; i < accounts.length; i++) {
      if (await isFundedVault(
        accounts[i],
        request.vaults[i],
        policy.programId,
        minLamports: minLockdownLamports,
        vaultRent: vaultRent,
        holdsTokens: _holdsTokens,
      )) {
        return;
      }
    }
    _reject(
      'Lockdowns are sponsored only for a plan with a pending payout that '
      'holds funds; the guard key can pay its own',
    );
  }

  Future<bool> _holdsTokens(String vault, Set<String> mints) async {
    final atas = [
      for (final m in mints) associatedTokenAddress(vault, m, tokenProgramId),
    ];
    final accounts = await fetchAccounts(atas);
    for (final (i, mint) in mints.indexed) {
      final a = i < accounts.length ? accounts[i] : null;
      final d = a?.data;
      if (a != null &&
          a.owner == tokenProgramId &&
          d != null &&
          d.length >= 165 &&
          base58encode(d.sublist(0, 32)) == mint &&
          base58encode(d.sublist(32, 64)) == vault &&
          _uLe(d.sublist(64, 72)) > BigInt.zero) {
        return true;
      }
    }
    return false;
  }

  @override
  Map<String, Object> admitEstimate(String tx, Object? feeToken) =>
      _reject('Method estimateTransactionFee is not available');

  @override
  Uri? upstreamFor(List<int> wire) => null;

  @override
  int? minFee(List<int> wire, Object? feeToken) => null;
}

class PaymasterRoute implements GatewayRoute {
  PaymasterRoute({
    required this.policy,
    required this.limiter,
    required this.creates,
    required this.atas,
    required this.fetchAccounts,
    this.upstreams = const {},
  });

  final PaymasterPolicy policy;

  /// Kora node per tier, each with its own fixed price; a missing tier
  /// uses the gateway's default upstream.
  final Map<PaymasterTier, Uri> upstreams;

  /// Every paid transaction, per owner and global.
  final UsageLimiter limiter;

  /// Kora-funded plan accounts, per owner and global.
  final UsageLimiter creates;

  /// Kora-funded token accounts (rent spent for good), per owner and
  /// global; each ATA is one slot.
  final UsageLimiter atas;

  /// Loads the payment source and any vault to verify (getMultipleAccounts).
  final Future<List<VaultAccount?>> Function(List<String>) fetchAccounts;

  @override
  String get name => 'paymaster';

  @override
  Set<String> get methods => paymasterMethods;

  /// Quota is checked first, then the accounts, and taken only once both
  /// pass; the gateway gives it back if Kora rejects the transaction.
  @override
  Future<Admission> admit(List<int> wire) async {
    final r = validatePaymasterTx(wire, policy);
    if (!await verifyOwnerSignature(r)) _reject('Invalid owner signature');
    void checkQuotas() {
      limiter.check(r.signer, const []);
      if (r.koraFundsRent) creates.check(r.signer, const []);
      if (r.koraAtas > 0) atas.check(r.signer, const [], n: r.koraAtas);
    }

    checkQuotas();
    await _checkAccounts(r);
    // Synchronous from here on, so no other request takes a slot between
    // the checks and the acquires.
    checkQuotas();
    final at = limiter.acquire(r.signer, const []);
    final createAt = r.koraFundsRent
        ? creates.acquire(r.signer, const [])
        : null;
    final atasAt = r.koraAtas > 0
        ? atas.acquire(r.signer, const [], n: r.koraAtas)
        : null;
    final p = r.payment!;
    final claim = r.fundingClaim;
    return (
      summary:
          'owner=${r.signer} ixs=${r.instructions.join(',')} '
          'tier=${r.tier.name} koraAtas=${r.koraAtas} '
          'fee<=${r.feeLamports} paid=${p.amount} ${p.mint}'
          '${claim == null ? '' : ' fundedBy=${claim.name}#${claim.index}'}',
      release: () {
        limiter.release(r.signer, const [], at);
        if (createAt != null) creates.release(r.signer, const [], createAt);
        if (atasAt != null) {
          atas.release(r.signer, const [], atasAt, n: r.koraAtas);
        }
      },
    );
  }

  /// The payment can succeed (audit M-2): its source is the owner's
  /// unfrozen token account of the payment mint and holds what the
  /// transaction takes from it, or receives the payout of the owner's own
  /// pending claim in the same transaction (the amount is then left to
  /// Kora's simulation). Kora-funded deposit ATAs belong to Deadman vaults
  /// (audit M-1).
  Future<void> _checkAccounts(PaymasterRequest r) async {
    final source = r.paymentSource!;
    final payment = r.payment!;
    final ata = policy.paymentAtas[payment.destination]!;
    final claim = r.fundingClaim;
    final plan = r.koraFundedPlan;
    final accounts = await fetchAccounts([
      source,
      ...r.vaultChecks,
      ?claim?.vault,
      ?plan,
    ]);
    final expected =
        1 +
        r.vaultChecks.length +
        (claim == null ? 0 : 1) +
        (plan == null ? 0 : 1);
    if (accounts.length != expected) {
      _reject('Could not load the payment account');
    }
    if (plan != null && accounts.last != null) {
      _reject(
        'The plan address $plan already holds lamports: the paymaster only '
        'pays the rent of a new plan at an empty address. Use another plan '
        'or pay the rent from the wallet',
      );
    }
    if (claim != null) {
      _checkClaimRule(
        accounts[1 + r.vaultChecks.length],
        vault: claim.vault,
        programId: policy.programId,
        index: claim.index,
        kind: claim.kind,
        beneficiary: r.signer,
        mint: claim.mint,
        what: claim.name,
      );
    }
    final a = accounts[0];
    var held = BigInt.zero;
    if (a == null) {
      if (!r.paymentSourceCreated) {
        _reject('The payment account $source does not exist');
      }
    } else {
      final d = a.data;
      if (a.owner != ata.tokenProgram ||
          d.length < 165 ||
          base58encode(d.sublist(0, 32)) != ata.mint ||
          base58encode(d.sublist(32, 64)) != r.signer ||
          d[108] != 1) {
        _reject(
          'The payment account $source is not an unfrozen ${ata.mint} '
          'account of ${r.signer}',
        );
      }
      held = _uLe(d.sublist(64, 72));
    }
    final needs = r.paymentSourceNeeds!;
    if (claim == null && held < needs) {
      _reject(
        'The payment account $source holds $held, the transaction needs '
        '$needs (${ata.mint} base units)',
      );
    }
    for (var i = 0; i < r.vaultChecks.length; i++) {
      final v = accounts[i + 1];
      if (v == null ||
          v.owner != policy.programId ||
          v.data.length < 8 ||
          !_eq(v.data.sublist(0, 8), Disc.vaultAccount)) {
        _reject(
          'The paymaster only funds token accounts of Deadman vaults; '
          '${r.vaultChecks[i]} is not one',
        );
      }
    }
  }

  @override
  Map<String, Object> admitEstimate(String tx, Object? feeToken) {
    if (feeToken != null &&
        (feeToken is! String || !policy.mints.contains(feeToken))) {
      _reject('fee_token must be one of ${policy.mints.join(', ')}');
    }
    validatePaymasterTx(base64Decode(tx), policy, requirePayment: false);
    return {'transaction': tx, 'fee_token': ?feeToken};
  }

  @override
  Uri? upstreamFor(List<int> wire) =>
      upstreams[validatePaymasterTx(wire, policy, requirePayment: false).tier];

  /// The tier's fixed price in [feeToken]: Kora values other mints through
  /// its price oracle, which may quote less than the gateway requires.
  @override
  int? minFee(List<int> wire, Object? feeToken) {
    final tier = validatePaymasterTx(wire, policy, requirePayment: false).tier;
    for (final ata in policy.paymentAtas.values) {
      if (ata.mint == feeToken) return ata.minAmounts[tier];
    }
    return null;
  }
}

class KoraGateway {
  KoraGateway({
    required this.upstream,
    required this.apiKey,
    required this.route,
    required this.payerSigner,
    this.maxBodyBytes = 8192,
    int perIpPerMinute = 60,
    http.Client? httpClient,
    void Function(String)? log,
  }) : _http = httpClient ?? http.Client(),
       _ips = _IpLimiter(perIpPerMinute),
       log = log ?? stdout.writeln;

  final Uri upstream;
  final String apiKey;
  final GatewayRoute route;

  /// Kora's cached `getPayerSigner` result.
  final Map<String, dynamic> payerSigner;
  final int maxBodyBytes;
  final void Function(String) log;
  final http.Client _http;
  final _IpLimiter _ips;

  (int, Object)? _blockhash;

  Future<HttpServer> serve(InternetAddress address, int port) async {
    final server = await HttpServer.bind(address, port);
    server.listen((r) => unawaited(handle(r)));
    return server;
  }

  Future<void> handle(HttpRequest req) async {
    final res = req.response;
    final ip = req.connectionInfo?.remoteAddress.address ?? '?';
    // The web app calls from the browser. No cookies or credentials are
    // involved, and every request is validated and rate-limited anyway.
    res.headers
      ..set('Access-Control-Allow-Origin', '*')
      ..set('Access-Control-Allow-Methods', 'POST, GET, OPTIONS')
      ..set('Access-Control-Allow-Headers', 'content-type')
      ..set('Access-Control-Max-Age', '86400');
    try {
      if (req.method == 'OPTIONS') {
        res.statusCode = HttpStatus.noContent;
        return;
      }
      if (req.method == 'GET' && req.uri.path == '/liveness') {
        final r = await _http.get(upstream.resolve('/liveness'));
        res.statusCode = r.statusCode == 200 ? 200 : 502;
        return;
      }
      if (req.method != 'POST') {
        res.statusCode = HttpStatus.methodNotAllowed;
        return;
      }
      if (!_ips.allow(ip, DateTime.now().millisecondsSinceEpoch ~/ 1000)) {
        _send(res, null, error: 'Too many requests', status: 429);
        return;
      }
      final body = await _readBody(req);
      if (body == null) {
        _send(res, null, error: 'Request body too large', status: 413);
        return;
      }
      Object? json;
      try {
        json = jsonDecode(utf8.decode(body));
      } on FormatException {
        _send(res, null, error: 'Parse error', code: -32700);
        return;
      }
      if (json is! Map<String, dynamic> || json['method'] is! String) {
        _send(res, null, error: 'Invalid request', code: -32600);
        return;
      }
      final id = json['id'];
      final method = json['method'] as String;
      if (!route.methods.contains(method)) {
        _send(
          res,
          id,
          error: 'Method $method is not available on the Deadman ${route.name}',
          code: -32601,
        );
        return;
      }
      switch (method) {
        case 'getPayerSigner':
          _send(res, id, result: payerSigner);
        case 'getBlockhash':
          await _getBlockhash(res, id);
        case 'estimateTransactionFee':
          await _estimate(res, id, json['params']);
        default:
          await _signAndSend(res, id, json['params'], ip);
      }
    } on GatewayRejection catch (e) {
      _send(res, null, error: e.message);
    } on Object catch (e) {
      log('${_ts()} error $ip: $e');
      try {
        _send(
          res,
          null,
          error: '${_title(route.name)} temporarily unavailable',
          status: 502,
        );
      } on StateError {
        // Headers already sent.
      }
    } finally {
      await res.close();
    }
  }

  static String _title(String s) => '${s[0].toUpperCase()}${s.substring(1)}';

  Future<List<int>?> _readBody(HttpRequest req) async {
    if (req.contentLength > maxBodyBytes) return null;
    final out = BytesBuilder(copy: false);
    await for (final chunk in req) {
      out.add(chunk);
      if (out.length > maxBodyBytes) return null;
    }
    return out.takeBytes();
  }

  Future<void> _getBlockhash(HttpResponse res, Object? id) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final cached = _blockhash;
    if (cached != null && now - cached.$1 < 1000) {
      _send(res, id, result: cached.$2);
      return;
    }
    final r = await _forward('getBlockhash', null);
    final result = r['result'];
    if (result != null) _blockhash = (now, result);
    _relay(res, id, r);
  }

  static String? _txParam(Object? params) {
    final tx = params is Map ? params['transaction'] : null;
    return tx is String && tx.length <= 2048 ? tx : null;
  }

  Future<void> _estimate(HttpResponse res, Object? id, Object? params) async {
    final tx = _txParam(params);
    if (tx == null) {
      _send(res, id, error: 'params.transaction must be a base64 transaction');
      return;
    }
    final Map<String, Object> forward;
    try {
      forward = route.admitEstimate(tx, (params! as Map)['fee_token']);
    } on FormatException {
      _send(res, id, error: 'params.transaction is not valid base64');
      return;
    } on GatewayRejection catch (e) {
      _send(res, id, error: e.message);
      return;
    }
    final wire = base64Decode(tx);
    final r = await _forward(
      'estimateTransactionFee',
      forward,
      to: route.upstreamFor(wire),
    );
    final result = r['result'];
    final min = route.minFee(wire, forward['fee_token']);
    if (result is Map && min != null) {
      final quoted = result['fee_in_token'];
      if (quoted is! num || quoted < min) result['fee_in_token'] = min;
    }
    _relay(res, id, r);
  }

  Future<void> _signAndSend(
    HttpResponse res,
    Object? id,
    Object? params,
    String ip,
  ) async {
    final tx = _txParam(params);
    if (tx == null) {
      _send(res, id, error: 'params.transaction must be a base64 transaction');
      return;
    }
    final Admission admission;
    try {
      admission = await route.admit(base64Decode(tx));
    } on FormatException {
      _send(res, id, error: 'params.transaction is not valid base64');
      return;
    } on GatewayRejection catch (e) {
      log('${_ts()} ${route.name} reject $ip: ${e.message}');
      _send(res, id, error: e.message);
      return;
    }
    // Kora's verdict decides whether the quota stays spent (audit M-2): a
    // rejection (or an HTTP refusal) gives it back, so wallets that cannot
    // pay cannot use it up. A timeout or a dropped connection keeps it,
    // since the transaction may have been sent.
    final Map<String, dynamic> r;
    try {
      r = await _forward('signAndSendTransaction', {
        'transaction': tx,
      }, to: route.upstreamFor(base64Decode(tx)));
    } on UpstreamHttpError {
      admission.release();
      rethrow;
    }
    final signature = (r['result'] as Map?)?['signature'];
    final sent = r['error'] is! Map && signature is String;
    if (!sent) admission.release();
    final outcome = sent
        ? 'sent $signature'
        : 'kora error: ${(r['error'] as Map?)?['message']} (quota released)';
    log('${_ts()} ${route.name} $ip ${admission.summary} $outcome');
    _relay(res, id, r);
  }

  Future<Map<String, dynamic>> _forward(
    String method,
    Map<String, Object>? params, {
    Uri? to,
  }) => koraCall(_http, to ?? upstream, apiKey, method, params);

  void _relay(HttpResponse res, Object? id, Map<String, dynamic> upstream) {
    final error = upstream['error'];
    if (error is Map) {
      _send(
        res,
        id,
        error: '${error['message']}',
        code: error['code'] as int? ?? -32000,
      );
    } else {
      _send(res, id, result: upstream['result']);
    }
  }

  static void _send(
    HttpResponse res,
    Object? id, {
    Object? result,
    String? error,
    int code = -32000,
    int status = 200,
  }) {
    res
      ..statusCode = status
      ..headers.contentType = ContentType.json
      ..write(
        jsonEncode({
          'jsonrpc': '2.0',
          if (error == null)
            'result': result
          else
            'error': {'code': code, 'message': error},
          'id': id,
        }),
      );
  }

  static String _ts() => DateTime.now().toUtc().toIso8601String();
}

/// A Kora node answered with a non-200 status, i.e. it did not process the
/// call.
class UpstreamHttpError extends StateError {
  UpstreamHttpError(super.message);
}

/// One JSON-RPC call to a Kora node with its API key.
Future<Map<String, dynamic>> koraCall(
  http.Client client,
  Uri upstream,
  String apiKey,
  String method, [
  Map<String, Object>? params,
]) async {
  final r = await client
      .post(
        upstream,
        headers: {'Content-Type': 'application/json', 'x-api-key': apiKey},
        body: jsonEncode({
          'jsonrpc': '2.0',
          'id': 1,
          'method': method,
          'params': params ?? const <Object>[],
        }),
      )
      .timeout(const Duration(seconds: 90));
  if (r.statusCode != 200) {
    throw UpstreamHttpError('upstream $method returned HTTP ${r.statusCode}');
  }
  return jsonDecode(r.body) as Map<String, dynamic>;
}

/// Loads [addresses] with getMultipleAccounts (base64).
Future<List<VaultAccount?>> Function(List<String>) rpcAccountFetcher(
  RpcClient rpc,
) => (addresses) async {
  final r = await rpc.getMultipleAccounts(
    addresses,
    commitment: Commitment.confirmed,
    encoding: Encoding.base64,
  );
  return [
    for (final a in r.value)
      if (a != null && a.data is BinaryAccountData)
        (
          owner: a.owner,
          data: Uint8List.fromList((a.data! as BinaryAccountData).data),
          lamports: a.lamports,
        )
      else
        null,
  ];
};

/// The ATA of [owner] for [mint] under [tokenProgram].
String associatedTokenAddress(String owner, String mint, String tokenProgram) =>
    findPda([
      Ed25519HDPublicKey.fromBase58(owner).bytes,
      Ed25519HDPublicKey.fromBase58(tokenProgram).bytes,
      Ed25519HDPublicKey.fromBase58(mint).bytes,
    ], programId: ataProgramId).address;

/// Payment ATAs for every `allowed_spl_paid_tokens` mint. With `fixed`
/// pricing (devnet, one node per tier), each tier node's price
/// ([koraConfigs], `getConfig` results) is converted to each mint's decimals
/// and all tiers must accept the same mints in the same token. With
/// `margin` pricing (mainnet, one node for every tier) there is no fixed
/// floor: Kora prices the fee plus its outflow at the oracle price and
/// checks the payment itself.
Future<Map<String, PaymentAta>> loadPaymentAtas(
  RpcClient rpc,
  Map<PaymasterTier, Map<String, dynamic>> koraConfigs,
  String paymentAddress,
) async {
  final prices = <PaymasterTier, int>{};
  final types = <Object?>{};
  Map<String, dynamic>? price;
  late List<String> mints;
  for (final e in koraConfigs.entries) {
    final v = e.value['validation_config'] as Map<String, dynamic>;
    final p = v['price'] as Map<String, dynamic>;
    types.add(p['type']);
    if (p['type'] == 'fixed') {
      price = p;
      prices[e.key] = p['amount'] as int;
    } else if (p['type'] != 'margin') {
      throw StateError(
        'paymaster pricing must be fixed or margin, got ${p['type']}',
      );
    }
    mints = (v['allowed_spl_paid_tokens'] as List).cast<String>();
  }
  if (types.length != 1) {
    throw StateError('paymaster tiers mix pricing types: $types');
  }
  final priceToken = price?['token'] as String?;
  final infos = await rpcAccountFetcher(rpc)([?priceToken, ...mints]);
  final mintInfos = priceToken == null ? infos : infos.sublist(1);
  int decimals(VaultAccount? m, String mint) {
    if (m == null ||
        (m.owner != tokenProgramId && m.owner != token2022ProgramId) ||
        m.data.length < 45) {
      throw StateError('$mint is not a token mint');
    }
    return m.data[44];
  }

  final priceDecimals = priceToken == null ? 0 : decimals(infos[0], priceToken);
  final out = <String, PaymentAta>{};
  for (var i = 0; i < mints.length; i++) {
    final mint = mints[i];
    final m = mintInfos[i];
    final scale = decimals(m, mint) - priceDecimals;
    int convert(int price) {
      final amount = BigInt.from(price);
      final p = BigInt.from(10).pow(scale.abs());
      return (scale >= 0 ? amount * p : (amount + p - BigInt.one) ~/ p).toInt();
    }

    out[associatedTokenAddress(paymentAddress, mint, m!.owner)] = (
      mint: mint,
      tokenProgram: m.owner,
      minAmounts: {for (final e in prices.entries) e.key: convert(e.value)},
    );
  }
  return out;
}

Future<Map<String, dynamic>> _koraResult(
  http.Client client,
  Uri upstream,
  String apiKey,
  String method,
) async {
  for (var attempt = 0; ; attempt++) {
    try {
      final r = await koraCall(client, upstream, apiKey, method);
      final result = r['result'];
      if (result is! Map<String, dynamic>) throw StateError('${r['error']}');
      return result;
    } on Object catch (e) {
      if (attempt >= 60) {
        stderr.writeln('Kora at $upstream unreachable: $e');
        exit(1);
      }
      await Future<void>.delayed(const Duration(seconds: 1));
    }
  }
}

Future<void> main() async {
  final env = Platform.environment;
  final apiKey = env['SPONSOR_API_KEY'] ?? '';
  if (apiKey.isEmpty) {
    stderr.writeln('SPONSOR_API_KEY is not set (see docs/KORA.md)');
    exit(64);
  }
  int envInt(String name, int fallback) =>
      int.tryParse(env[name] ?? '') ?? fallback;
  final rpcUrl = env['RPC_URL'] ?? AppConfig.rpcUrl;
  final rpc = RpcClient(rpcUrl);
  final client = http.Client();
  final perIp = envInt('GATEWAY_PER_IP_MINUTE', 60);
  final servers = <HttpServer>[];

  final upstream = Uri.parse(env['KORA_UPSTREAM'] ?? 'http://127.0.0.1:8090');
  final port = envInt('GATEWAY_PORT', 8080);
  final payer = await _koraResult(client, upstream, apiKey, 'getPayerSigner');
  final sponsor = KoraGateway(
    upstream: upstream,
    apiKey: apiKey,
    route: SponsorRoute(
      policy: SponsorPolicy(koraPayer: payer['signer_address'] as String),
      limiter: UsageLimiter(
        perVault: envInt('GATEWAY_PER_VAULT', 24),
        perSigner: envInt('GATEWAY_PER_SIGNER', 48),
        global: envInt('GATEWAY_GLOBAL', 2000),
        file: File(env['GATEWAY_STATE'] ?? 'kora/gateway-usage.json'),
      ),
      claims: UsageLimiter(
        perVault: envInt('GATEWAY_CLAIMS_PER_VAULT', 12),
        perSigner: envInt('GATEWAY_CLAIMS_PER_SIGNER', 12),
        global: envInt('GATEWAY_CLAIMS_GLOBAL', 500),
        file: File(env['GATEWAY_CLAIMS_STATE'] ?? 'kora/gateway-claims.json'),
        signerLabel: 'claimer',
        unit: 'sponsored claims',
      ),
      lockdowns: UsageLimiter(
        perVault: envInt('GATEWAY_LOCKDOWNS_PER_VAULT', 3),
        perSigner: envInt('GATEWAY_LOCKDOWNS_PER_SIGNER', 24),
        global: envInt('GATEWAY_LOCKDOWNS_GLOBAL', 1000),
        file: File(
          env['GATEWAY_LOCKDOWNS_STATE'] ?? 'kora/gateway-lockdowns.json',
        ),
        unit: SponsorRoute.lockdownUnit,
      ),
      minLockdownLamports: envInt(
        'GATEWAY_LOCKDOWN_MIN_LAMPORTS',
        defaultMinLockdownLamports,
      ),
      vaultRent: await rpc.getMinimumBalanceForRentExemption(
        vaultAccountSize,
        commitment: Commitment.confirmed,
      ),
      fetchAccounts: rpcAccountFetcher(rpc),
    ),
    payerSigner: payer,
    perIpPerMinute: perIp,
    httpClient: client,
  );
  servers.add(await sponsor.serve(InternetAddress.anyIPv4, port));
  stdout.writeln(
    '${KoraGateway._ts()} sponsor gateway on :$port -> $upstream, '
    'payer ${payer['signer_address']}, rpc $rpcUrl',
  );

  final pmKey = env['PAYMASTER_API_KEY'] ?? '';
  if (pmKey.isNotEmpty) {
    // One Kora node per tier (same signer and payment address), each with
    // its own fixed price: PAYMASTER_UPSTREAM is the plan tier.
    final pmUpstream = Uri.parse(
      env['PAYMASTER_UPSTREAM'] ?? 'http://127.0.0.1:8091',
    );
    final tiers = {
      PaymasterTier.plan: pmUpstream,
      PaymasterTier.account: Uri.parse(
        env['PAYMASTER_ACCOUNT_UPSTREAM'] ?? 'http://127.0.0.1:8092',
      ),
      PaymasterTier.basic: Uri.parse(
        env['PAYMASTER_BASIC_UPSTREAM'] ?? 'http://127.0.0.1:8093',
      ),
    };
    final pmPort = envInt('PAYMASTER_PORT', 8081);
    final pmPayer = await _koraResult(
      client,
      pmUpstream,
      pmKey,
      'getPayerSigner',
    );
    final configs = {
      for (final e in tiers.entries)
        e.key: await _koraResult(client, e.value, pmKey, 'getConfig'),
    };
    final atas = await loadPaymentAtas(
      rpc,
      configs,
      pmPayer['payment_address'] as String,
    );
    final paymaster = KoraGateway(
      upstream: pmUpstream,
      apiKey: pmKey,
      route: PaymasterRoute(
        policy: PaymasterPolicy(
          koraPayer: pmPayer['signer_address'] as String,
          paymentAtas: atas,
        ),
        upstreams: tiers,
        fetchAccounts: rpcAccountFetcher(rpc),
        limiter: UsageLimiter(
          perVault: 0,
          perSigner: envInt('PAYMASTER_PER_OWNER', 60),
          global: envInt('PAYMASTER_GLOBAL', 2000),
          file: File(env['PAYMASTER_STATE'] ?? 'kora/paymaster-usage.json'),
          service: 'the paymaster',
          signerLabel: 'owner',
          unit: 'paid transactions',
        ),
        creates: UsageLimiter(
          perVault: 0,
          perSigner: envInt('PAYMASTER_CREATES_PER_OWNER', 3),
          global: envInt('PAYMASTER_CREATES_GLOBAL', 20),
          file: File(
            env['PAYMASTER_CREATES_STATE'] ?? 'kora/paymaster-creates.json',
          ),
          service: 'the paymaster',
          signerLabel: 'owner',
          unit: 'paymaster-funded accounts',
        ),
        atas: UsageLimiter(
          perVault: 0,
          perSigner: envInt('PAYMASTER_ATAS_PER_OWNER', 6),
          global: envInt('PAYMASTER_ATAS_GLOBAL', 100),
          file: File(env['PAYMASTER_ATAS_STATE'] ?? 'kora/paymaster-atas.json'),
          service: 'the paymaster',
          signerLabel: 'owner',
          unit: 'paymaster-funded token accounts',
        ),
      ),
      payerSigner: pmPayer,
      perIpPerMinute: perIp,
      httpClient: client,
    );
    servers.add(await paymaster.serve(InternetAddress.anyIPv4, pmPort));
    stdout.writeln(
      '${KoraGateway._ts()} paymaster gateway on :$pmPort -> $pmUpstream, '
      'payer ${pmPayer['signer_address']}, payment ATAs '
      '${[for (final e in atas.entries) '${e.key} (${e.value.mint} ${e.value.minAmounts.entries.map((t) => '${t.key.name}>=${t.value}').join(' ')})'].join(', ')}',
    );
  }

  for (final signal in [ProcessSignal.sigint, ProcessSignal.sigterm]) {
    signal.watch().listen((_) async {
      for (final s in servers) {
        await s.close(force: true);
      }
      exit(0);
    });
  }
}
