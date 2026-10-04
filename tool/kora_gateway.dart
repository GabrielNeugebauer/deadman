// Public entry to the Deadman Kora nodes (audit M-4). Kora listens behind an
// API key that only this gateway holds:
//
// - :8080 -> sponsor (:8090, free): only a guard key's Deadman `pulse` /
//   `lockdown` on vaults it guards, rate-limited per vault, per guard key and
//   globally.
// - :8081 -> paymaster (:8091, fixed USDC price): owner-signed Deadman,
//   deposit and payment instructions; the last instruction must pay the
//   paymaster in USDC. Rate-limited per owner and globally.
//
// dart run tool/kora_gateway.dart
//
// Env: SPONSOR_API_KEY (required), RPC_URL, GATEWAY_PORT (8080),
// KORA_UPSTREAM (http://127.0.0.1:8090), GATEWAY_STATE
// (kora/gateway-usage.json), GATEWAY_PER_VAULT (24), GATEWAY_PER_SIGNER (48),
// GATEWAY_GLOBAL (2000), GATEWAY_PER_IP_MINUTE (60).
// Paymaster (enabled when PAYMASTER_API_KEY is set): PAYMASTER_PORT (8081),
// PAYMASTER_UPSTREAM (http://127.0.0.1:8091), PAYMASTER_STATE
// (kora/paymaster-usage.json), PAYMASTER_PER_OWNER (60), PAYMASTER_GLOBAL
// (2000), PAYMASTER_CREATES_STATE (kora/paymaster-creates.json),
// PAYMASTER_CREATES_PER_OWNER (3), PAYMASTER_CREATES_GLOBAL (20).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:deadman/core/config.dart';
import 'package:deadman/solana/codec.dart'
    show
        Disc,
        ataProgramId,
        findPda,
        systemProgramId,
        token2022ProgramId,
        tokenProgramId;
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

/// A transaction that passed [validateSponsorTx]; the guard signature and the
/// vaults are checked next.
class SponsorRequest {
  const SponsorRequest({
    required this.signer,
    required this.vaults,
    required this.feeLamports,
    required this.message,
    required this.signature,
  });

  /// The one non-Kora signer (must be every vault's guard).
  final String signer;

  /// Distinct vault accounts, in instruction order.
  final List<String> vaults;
  final int feeLamports;
  final Uint8List message;
  final Uint8List signature;
}

/// Checks a wire transaction (base64-decoded, legacy or v0) against the
/// sponsor policy. Pure: the guard signature ([verifyGuardSignature]) and the
/// vault accounts ([checkVaultAccounts]) are checked separately.
SponsorRequest validateSponsorTx(List<int> wire, SponsorPolicy policy) {
  final tx = _Tx(wire)
    ..requireKoraPlusOneSigner(policy.koraPayer, 'Sponsored', 'sponsor');
  final keys = tx.keys;
  final signer = keys[1];

  final budget = _Budget();
  var deadmanIxs = 0;
  final vaults = <String>{};
  for (final ix in tx.ixs) {
    if (ix.accounts.contains(0)) {
      _reject('Instructions may not reference the sponsor account');
    }
    final program = keys[ix.programIndex];
    final d = ix.data;
    if (program == computeBudgetProgramId) {
      budget.add(ix);
    } else if (program == policy.programId) {
      if (++deadmanIxs > SponsorPolicy.maxDeadmanIxs) {
        _reject(
          'At most ${SponsorPolicy.maxDeadmanIxs} Deadman instructions per '
          'transaction',
        );
      }
      if (d.length != 8 || !(_eq(d, Disc.pulse) || _eq(d, Disc.lockdown))) {
        _reject('Only Deadman pulse and lockdown are sponsored');
      }
      if (ix.accounts.length != 2 || ix.accounts[1] < tx.requiredSigs) {
        _reject('Malformed Deadman instruction');
      }
      if (keys[ix.accounts[0]] != signer) {
        _reject(
          "Each pulse/lockdown must be signed by the transaction's guard key",
        );
      }
      vaults.add(keys[ix.accounts[1]]);
    } else {
      _reject('Program $program is not sponsored');
    }
  }
  if (deadmanIxs == 0) _reject('No Deadman pulse or lockdown to sponsor');
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
  );
}

Future<bool> _signedBy(String signer, Uint8List message, Uint8List sig) =>
    verifySignature(
      message: message,
      signature: sig,
      publicKey: Ed25519HDPublicKey.fromBase58(signer),
    );

/// Whether the guard's signature is valid, so a stranger cannot burn a
/// vault's quota with unsigned copies of its pulse.
Future<bool> verifyGuardSignature(SponsorRequest request) =>
    _signedBy(request.signer, request.message, request.signature);

typedef VaultAccount = ({String owner, Uint8List data});

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
/// (plus up to [PaymasterPolicy.maxExtraAccounts] Token-2022 hook accounts
/// when [extra]) and the one account slot that may be the Kora payer.
typedef DeadmanIxSpec = ({
  List<int> disc,
  int accounts,
  bool extra,
  int? koraSlot,
});

/// Discriminators from onchain/target/idl/deadman.json.
const paymasterDeadmanIxs = <String, DeadmanIxSpec>{
  // payer (slot 1) = Kora: Anchor `init` CPIs System create_account from Kora.
  'create_vault': (
    disc: [29, 237, 247, 208, 193, 82, 54, 135],
    accounts: 4,
    extra: false,
    koraSlot: 1,
  ),
  'create_vesting': (
    disc: [135, 184, 171, 156, 197, 162, 246, 44],
    accounts: 4,
    extra: false,
    koraSlot: 1,
  ),
  'update_policy': (
    disc: [212, 245, 246, 7, 163, 151, 18, 57],
    accounts: 2,
    extra: false,
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
    extra: true,
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
    extra: true,
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
  });

  /// The one non-Kora signer (vault owner, executor or depositor).
  final String signer;

  /// Instruction names, e.g. `deadman.create_vault`, `token.transfer_checked`.
  final List<String> instructions;

  /// Whether Kora is the `payer` of a create_vault / create_vesting.
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
}

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
  var koraAtas = 0;
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
      if (a[0] == kora && ++koraAtas > PaymasterPolicy.maxKoraAtas) {
        _reject(
          'At most ${PaymasterPolicy.maxKoraAtas} paymaster-funded token '
          'accounts per transaction',
        );
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
      final ata = policy.paymentAtas[keys[destination]];
      if (ata != null) {
        if (ata.tokenProgram != program ||
            (mint != null && keys[mint] != ata.mint)) {
          _reject('Payment to ${keys[destination]} uses the wrong mint');
        }
        final amount = _uLe(d.sublist(1, 9));
        lastPayment = (
          mint: ata.mint,
          destination: keys[destination],
          amount: amount.isValidInt ? amount.toInt() : -1,
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
            'The paymaster may only be the payer of create_vault / '
            'create_vesting or the rent_payer of close_vault',
          );
        }
      }
      if (spec.koraSlot == 1) {
        if (a[1] != kora && a[1] != owner) {
          _reject('The $name payer must be the paymaster or the owner');
        }
        if (a[1] == kora && ++koraCreates > 1) {
          _reject('At most one paymaster-funded vault per transaction');
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
  final tier = koraCreates > 0
      ? PaymasterTier.plan
      : koraAtas > 0
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
  return PaymasterRequest(
    signer: keys[owner],
    instructions: names,
    koraFundsRent: koraCreates > 0,
    koraAtas: koraAtas,
    feeLamports: fee,
    payment: lastPayment,
    message: tx.message,
    signature: tx.signatures[owner],
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

  /// Throws if this transaction would exceed a limit; records nothing.
  void check(String signer, List<String> vaults) {
    final now = _now();
    _prune(now);
    String retry(List<int> hits) => DateTime.fromMillisecondsSinceEpoch(
      (hits.first + windowSecs) * 1000,
      isUtc: true,
    ).toIso8601String();
    if (_global.length >= global) {
      _reject(
        'Rate limit: $service reached its cap of $global $unit per 24h; '
        'retry after ${retry(_global)}',
      );
    }
    final s = _signers[signer] ?? const [];
    if (s.length >= perSigner) {
      _reject(
        'Rate limit: $signerLabel $signer reached $perSigner $unit per 24h; '
        'retry after ${retry(s)}',
      );
    }
    for (final v in vaults) {
      final hits = _vaults[v] ?? const [];
      if (hits.length >= perVault) {
        _reject(
          'Rate limit: vault $v reached $perVault $unit per 24h; '
          'retry after ${retry(hits)}',
        );
      }
    }
  }

  /// [check], then records the transaction. Synchronous, so concurrent
  /// requests cannot both pass the last free slot.
  void acquire(String signer, List<String> vaults) {
    check(signer, vaults);
    final now = _now();
    _global.add(now);
    (_signers[signer] ??= []).add(now);
    for (final v in vaults.toSet()) {
      (_vaults[v] ??= []).add(now);
    }
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

/// What one public listener admits.
abstract interface class GatewayRoute {
  /// "sponsor" or "paymaster".
  String get name;
  Set<String> get methods;

  /// Validates [wire] and reserves rate-limit quota; returns a log summary.
  Future<String> admit(List<int> wire);

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
  });

  final SponsorPolicy policy;
  final UsageLimiter limiter;
  final Future<List<VaultAccount?>> Function(List<String>) fetchAccounts;

  @override
  String get name => 'sponsor';

  @override
  Set<String> get methods => sponsorMethods;

  @override
  Future<String> admit(List<int> wire) async {
    final request = validateSponsorTx(wire, policy);
    if (!await verifyGuardSignature(request)) {
      _reject('Invalid guard signature');
    }
    limiter.check(request.signer, request.vaults);
    checkVaultAccounts(request, await fetchAccounts(request.vaults), policy);
    limiter.acquire(request.signer, request.vaults);
    return 'signer=${request.signer} vaults=${request.vaults.join(',')} '
        'fee<=${request.feeLamports}';
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
    this.upstreams = const {},
  });

  final PaymasterPolicy policy;

  /// Kora node per tier, each with its own fixed price; a missing tier
  /// uses the gateway's default upstream.
  final Map<PaymasterTier, Uri> upstreams;

  /// Every paid transaction, per owner and global.
  final UsageLimiter limiter;

  /// Kora-funded vault creations (rent float), per owner and global.
  final UsageLimiter creates;

  @override
  String get name => 'paymaster';

  @override
  Set<String> get methods => paymasterMethods;

  @override
  Future<String> admit(List<int> wire) async {
    final r = validatePaymasterTx(wire, policy);
    if (!await verifyOwnerSignature(r)) _reject('Invalid owner signature');
    limiter.check(r.signer, const []);
    if (r.koraFundsRent) creates.acquire(r.signer, const []);
    limiter.acquire(r.signer, const []);
    final p = r.payment!;
    return 'owner=${r.signer} ixs=${r.instructions.join(',')} '
        'tier=${r.tier.name} fee<=${r.feeLamports} '
        'paid=${p.amount} ${p.mint}';
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
    try {
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
    final String summary;
    try {
      summary = await route.admit(base64Decode(tx));
    } on FormatException {
      _send(res, id, error: 'params.transaction is not valid base64');
      return;
    } on GatewayRejection catch (e) {
      log('${_ts()} ${route.name} reject $ip: ${e.message}');
      _send(res, id, error: e.message);
      return;
    }
    final r = await _forward('signAndSendTransaction', {
      'transaction': tx,
    }, to: route.upstreamFor(base64Decode(tx)));
    final outcome = r['error'] is Map
        ? 'kora error: ${(r['error'] as Map)['message']}'
        : 'sent ${(r['result'] as Map?)?['signature']}';
    log('${_ts()} ${route.name} $ip $summary $outcome');
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
    throw StateError('upstream $method returned HTTP ${r.statusCode}');
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

/// Payment ATAs for every `allowed_spl_paid_tokens` mint, with each tier
/// node's fixed price ([koraConfigs], `getConfig` results) converted to each
/// mint's decimals. All tiers must accept the same mints in the same token.
Future<Map<String, PaymentAta>> loadPaymentAtas(
  RpcClient rpc,
  Map<PaymasterTier, Map<String, dynamic>> koraConfigs,
  String paymentAddress,
) async {
  final prices = <PaymasterTier, int>{};
  late Map<String, dynamic> price;
  late List<String> mints;
  for (final e in koraConfigs.entries) {
    final v = e.value['validation_config'] as Map<String, dynamic>;
    price = v['price'] as Map<String, dynamic>;
    if (price['type'] != 'fixed') {
      throw StateError('paymaster pricing must be fixed, got ${price['type']}');
    }
    prices[e.key] = price['amount'] as int;
    mints = (v['allowed_spl_paid_tokens'] as List).cast<String>();
  }
  final infos = await rpcAccountFetcher(rpc)([
    price['token'] as String,
    ...mints,
  ]);
  int decimals(VaultAccount? m, String mint) {
    if (m == null ||
        (m.owner != tokenProgramId && m.owner != token2022ProgramId) ||
        m.data.length < 45) {
      throw StateError('$mint is not a token mint');
    }
    return m.data[44];
  }

  final priceDecimals = decimals(infos[0], price['token'] as String);
  final out = <String, PaymentAta>{};
  for (var i = 0; i < mints.length; i++) {
    final mint = mints[i];
    final m = infos[i + 1];
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
          unit: 'paymaster-funded vaults',
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
