// Protocol keeper: executes due rules in every Deadman vault. Execution is
// permissionless and destinations are fixed on-chain, so the keeper can't
// redirect funds; the payout fee is what pays for running it.
//
// Policy (audit M-3): never pay for an empty or unpayable tier, and never pay
// ATA rent the protocol fee does not cover. Tiers that cannot pay are skipped
// once their grace period is over; a skipped tier keeps its share reserved and
// stays claimable, so the keeper executes it (same policy) once it can pay,
// and never skips it again. At most one action per vault per sweep.
//
// Vesting plans: releases what has vested on each schedule, at most once per
// --vest-interval per schedule (and always once it is fully vested), under
// the same payability rules. Inheritance-only actions never touch them.
//
// dart run tool/keeper.dart --keypair <path> [--rpc <url>] [--every 60]
//   [--dry-run] [--price <mint>=<lamports per base unit>]...
//   [--vest-interval <seconds>] [--usdc-price-lamports <per base unit>]
import 'dart:convert';
import 'dart:io';

import 'package:deadman/core/config.dart';
import 'package:deadman/solana/codec.dart';
import 'package:deadman/solana/deadman_api.dart';
import 'package:deadman/solana/deadman_client.dart';
import 'package:solana/base58.dart';
import 'package:solana/dto.dart' show Account, BinaryAccountData, Encoding;
import 'package:solana/solana.dart';

const nativeMint = 'So11111111111111111111111111111111111111112';
const tokenAccountSize = 165;

enum KeeperAction { execute, skip, wait }

class Decision {
  const Decision(this.action, this.reason, {this.createAtasFor = const []});

  final KeeperAction action;
  final String reason;

  /// Owners whose ATA the keeper creates (and pays rent for) on execute.
  final List<String> createAtasFor;

  @override
  String toString() =>
      '${action.name}: $reason'
      '${createAtasFor.isEmpty ? '' : ' (creates ${createAtasFor.length} ATA)'}';
}

/// Mirrors the program's `rule_gross`.
int ruleGross(RuleSpec rule, int available) => switch (rule.mode) {
  AmountMode.fixed => rule.amount < available ? rule.amount : available,
  AmountMode.percent =>
    (BigInt.from(available) *
            BigInt.from(rule.amount) ~/
            BigInt.from(Limits.bpsDenominator))
        .toInt(),
};

/// Mirrors the program's `split_fee`: (net, fee).
(int, int) splitFee(int gross, int bps) {
  final fee =
      (BigInt.from(gross) *
              BigInt.from(bps) ~/
              BigInt.from(Limits.bpsDenominator))
          .toInt();
  return (gross - fee, fee);
}

/// Mirrors the program's `reserved_for`: shares set aside for skipped,
/// unpaid tiers of rule [index]'s asset, other than [index] itself.
int reservedFor(VaultState v, int index) {
  final mint = v.rules[index].mint;
  var sum = 0;
  for (final (j, r) in v.rules.indexed) {
    if (j != index && r.mint == mint && !r.executed && r.skipped) {
      sum += r.reserved;
    }
  }
  return sum;
}

/// Mirrors the program's `payout_gross`: a skipped tier gets its reserved
/// share (capped at [balance]); any other tier, or a skipped one with
/// nothing reserved, works on [balance] minus [otherReserved].
int tierGross(RuleSpec rule, int balance, {int otherReserved = 0}) {
  if (rule is RuleState && rule.skipped && rule.reserved > 0) {
    return rule.reserved < balance ? rule.reserved : balance;
  }
  final available = balance - otherReserved;
  return ruleGross(rule, available < 0 ? 0 : available);
}

Decision _cannotPay(String why, bool canSkip) => canSkip
    ? Decision(KeeperAction.skip, '$why; grace period over')
    : Decision(KeeperAction.wait, '$why; not skippable yet');

class SolFacts {
  const SolFacts({
    required this.available,
    required this.feeBps,
    required this.beneficiaryLamports,
    required this.beneficiaryRentMin,
    required this.treasuryLamports,
    required this.treasuryRentMin,
    this.otherReserved = 0,
  });

  /// Vault lamports above its rent-exempt minimum.
  final int available;

  /// Lamports reserved for other skipped, unpaid SOL tiers.
  final int otherReserved;
  final int feeBps;
  final int beneficiaryLamports;
  final int beneficiaryRentMin;
  final int treasuryLamports;
  final int treasuryRentMin;
}

/// A due or skipped SOL rule: execute unless the payout is 0 or would leave
/// the beneficiary below rent exemption (the program rejects that with
/// BeneficiaryCannotReceive).
Decision decideSol(RuleSpec rule, SolFacts f, {required bool canSkip}) {
  final gross = tierGross(rule, f.available, otherReserved: f.otherReserved);
  if (gross <= 0) return _cannotPay('nothing to pay', canSkip);
  var (net, fee) = splitFee(gross, f.feeBps);
  if (fee > 0 && f.treasuryLamports + fee < f.treasuryRentMin) {
    net += fee;
    fee = 0;
  }
  if (f.beneficiaryLamports + net < f.beneficiaryRentMin) {
    return _cannotPay(
      'payout $net lamports leaves the beneficiary below rent exemption',
      canSkip,
    );
  }
  return Decision(KeeperAction.execute, 'pays $net lamports, fee $fee');
}

enum AtaStatus { missing, usable, unusable }

class TokenFacts {
  const TokenFacts({
    required this.classicMint,
    required this.vaultBalance,
    required this.feeBps,
    required this.beneficiaryAta,
    required this.treasuryAta,
    required this.ataRent,
    this.lamportsPerUnit,
    this.otherReserved = 0,
  });

  /// The mint is owned by the classic SPL Token program (the only one the
  /// client builds for).
  final bool classicMint;
  final int vaultBalance;
  final int feeBps;
  final AtaStatus beneficiaryAta;
  final AtaStatus treasuryAta;

  /// Rent the keeper pays per ATA it creates.
  final int ataRent;

  /// Value of one base unit in lamports, if known (see --price).
  final double? lamportsPerUnit;

  /// Units reserved for other skipped, unpaid tiers of this mint.
  final int otherReserved;
}

/// A due or skipped token rule: execute only when the vault holds the mint and either
/// both ATAs exist or the protocol fee is worth at least the ATA rent the
/// keeper would pay. A payable tier is never skipped just because it does
/// not pay the keeper; the beneficiary can create its ATA or execute itself.
Decision decideToken(
  RuleSpec rule,
  String treasury,
  TokenFacts f, {
  required bool canSkip,
}) {
  if (!f.classicMint) {
    return const Decision(KeeperAction.wait, 'mint not supported by keeper');
  }
  final gross = tierGross(rule, f.vaultBalance, otherReserved: f.otherReserved);
  if (gross <= 0) return _cannotPay('vault holds none of the mint', canSkip);
  if (f.beneficiaryAta == AtaStatus.unusable) {
    return _cannotPay('beneficiary ATA is frozen or reassigned', canSkip);
  }
  if (f.treasuryAta == AtaStatus.unusable) {
    return const Decision(KeeperAction.wait, 'treasury ATA unusable');
  }
  final (net, fee) = splitFee(gross, f.feeBps);
  final missing = [
    if (f.beneficiaryAta == AtaStatus.missing) rule.beneficiary,
    if (f.treasuryAta == AtaStatus.missing) treasury,
  ];
  if (missing.isEmpty) {
    return Decision(KeeperAction.execute, 'pays $net, fee $fee');
  }
  final rent = missing.length * f.ataRent;
  final price = f.lamportsPerUnit;
  final feeValue = price == null ? 0 : (fee * price).floor();
  if (feeValue < rent) {
    return Decision(
      KeeperAction.wait,
      'fee worth ~$feeValue lamports does not cover $rent lamports of ATA '
      'rent',
    );
  }
  return Decision(
    KeeperAction.execute,
    'pays $net, fee $fee (~$feeValue lamports) covers $rent rent',
    createAtasFor: missing,
  );
}

/// Whether to release a vesting schedule now: never with nothing new
/// vested, at most once per [interval] (unix seconds since [lastRelease]),
/// except once [fullyVested] so the last part never waits.
bool vestingReleaseDue({
  required int claimable,
  required bool fullyVested,
  required int now,
  required int interval,
  int? lastRelease,
}) {
  if (claimable <= 0) return false;
  if (fullyVested || lastRelease == null) return true;
  return now - lastRelease >= interval;
}

/// A vesting release as a Fixed tier of [claimable], so the SOL and token
/// payability rules apply unchanged (the program caps it at the balance).
RuleSpec vestingAsTier(RuleSpec schedule, int claimable) => RuleSpec(
  beneficiary: schedule.beneficiary,
  rail: schedule.rail,
  afterSecs: 0,
  mode: AmountMode.fixed,
  amount: claimable,
  mint: schedule.mint,
);

/// Default value of one USDC base unit: 1 USDC ~ 0.006 SOL, i.e.
/// 6_000_000 lamports per 1_000_000 base units.
const defaultUsdcLamportsPerUnit = 6.0;

class Keeper {
  Keeper(
    this.sol,
    this.client,
    this.key, {
    this.dryRun = false,
    this.prices = const {},
    this.vestInterval = 86400,
  });

  final SolanaClient sol;
  final DeadmanClient client;
  final Ed25519HDKeyPair key;
  final bool dryRun;
  final Map<String, double> prices;

  /// Seconds between releases of one vesting schedule.
  final int vestInterval;
  final _rent = <int, int>{};

  /// Last release per `vault:index`, this run.
  final _lastRelease = <String, int>{};

  RpcClient get _rpc => sol.rpcClient;

  Future<int> _rentMin(int len) async => _rent[len] ??= await _rpc
      .getMinimumBalanceForRentExemption(len, commitment: Commitment.confirmed);

  Future<List<Account?>> _accounts(List<String> keys) async =>
      (await _rpc.getMultipleAccounts(
        keys,
        commitment: Commitment.confirmed,
        encoding: Encoding.base64,
      )).value;

  static List<int>? _data(Account? a) {
    final d = a?.data;
    return d is BinaryAccountData ? d.data : null;
  }

  static AtaStatus _ataStatus(Account? a, String mint, String owner) {
    if (a == null) return AtaStatus.missing;
    final d = _data(a);
    if (a.owner != tokenProgramId || d == null || d.length < 165) {
      return AtaStatus.unusable;
    }
    final ok =
        base58encode(d.sublist(0, 32)) == mint &&
        base58encode(d.sublist(32, 64)) == owner &&
        d[108] == 1; // Initialized, not frozen
    return ok ? AtaStatus.usable : AtaStatus.unusable;
  }

  /// For a vesting plan pass [asTier] (see [vestingAsTier]); it is never
  /// skippable and reserves nothing.
  Future<Decision> decide(
    VaultState v,
    int i,
    FeeSchedule fees,
    int now, {
    RuleSpec? asTier,
  }) async {
    final rule = asTier ?? v.rules[i];
    // False for an already-skipped tier: it waits until it can pay.
    final canSkip = asTier == null && v.canSkip(i, now);
    final otherReserved = asTier == null ? reservedFor(v, i) : 0;
    final bps = fees.bpsFor(rule.rail);
    final mint = rule.mint;
    if (mint == null) {
      final [ben, tre] = await _accounts([rule.beneficiary, fees.treasury]);
      return decideSol(
        rule,
        SolFacts(
          available: v.withdrawableLamports,
          feeBps: bps,
          beneficiaryLamports: ben?.lamports ?? 0,
          beneficiaryRentMin: await _rentMin(_data(ben)?.length ?? 0),
          treasuryLamports: tre?.lamports ?? 0,
          treasuryRentMin: await _rentMin(_data(tre)?.length ?? 0),
          otherReserved: otherReserved,
        ),
        canSkip: canSkip,
      );
    }
    final [mintAcct, vaultAta, benAta, treAta] = await _accounts([
      mint,
      ataAddress(v.address, mint),
      ataAddress(rule.beneficiary, mint),
      ataAddress(fees.treasury, mint),
    ]);
    final vaultData = _data(vaultAta);
    return decideToken(
      rule,
      fees.treasury,
      TokenFacts(
        classicMint: mintAcct?.owner == tokenProgramId,
        vaultBalance:
            vaultAta?.owner == tokenProgramId &&
                vaultData != null &&
                vaultData.length >= 165
            ? decodeTokenAmount(vaultData)
            : 0,
        feeBps: bps,
        beneficiaryAta: _ataStatus(benAta, mint, rule.beneficiary),
        treasuryAta: _ataStatus(treAta, mint, fees.treasury),
        ataRent: await _rentMin(tokenAccountSize),
        lamportsPerUnit: prices[mint] ?? (mint == nativeMint ? 1 : null),
        otherReserved: otherReserved,
      ),
      canSkip: canSkip,
    );
  }

  /// Sends the rule's instructions minus the ATA creates the decision did not
  /// approve, so an ATA closed after the check fails the transaction instead
  /// of charging the keeper rent.
  Future<String> _execute(
    VaultState v,
    int i,
    FeeSchedule fees,
    Decision d,
  ) async {
    final build = v.isVesting ? releaseVestedIxs : executeRuleIxs;
    final ixs = [
      for (final ix in build(
        executor: key.address,
        vaultOwner: v.owner,
        planId: v.planId,
        rule: v.rules[i],
        index: i,
        treasury: fees.treasury,
      ))
        if (ix.programId.toBase58() != ataProgramId ||
            d.createAtasFor.contains(ix.accounts[2].pubKey.toBase58()))
          ix,
    ];
    return sol.sendAndConfirmTransaction(
      message: Message(instructions: ixs),
      signers: [key],
      commitment: Commitment.confirmed,
    );
  }

  Future<void> sweep() async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final vaults = await client.fetchAllVaults();
    final fees = await client.fetchFees();
    var acted = 0;
    for (final v in vaults) {
      if (v.isVesting) {
        if (await _sweepVesting(v, fees, now)) acted++;
        continue;
      }
      // Index order respects the program's per-asset ordering; skipped
      // tiers are claimable whenever they can pay.
      for (var i = 0; i < v.rules.length; i++) {
        if (!v.canExecute(i, now)) continue;
        final rule = v.rules[i];
        final tag = '${v.address} rule $i -> ${rule.beneficiary}';
        try {
          final d = await decide(v, i, fees, now);
          if (d.action == KeeperAction.wait || dryRun) {
            stdout.writeln('${dryRun ? 'DRY ' : ''}$tag: $d');
            if (d.action == KeeperAction.wait) continue;
            break;
          }
          final sig = d.action == KeeperAction.skip
              ? await client.skipRuleWithKey(
                  key,
                  vaultOwner: v.owner,
                  planId: v.planId,
                  index: i,
                )
              : await _execute(v, i, fees, d);
          acted++;
          stdout.writeln('$tag: $d: $sig');
        } on Exception catch (e) {
          stderr.writeln('$tag failed: $e');
        }
        // A Percent rule's share depends on what earlier rules left behind,
        // so stop and let the next sweep see fresh balances.
        break;
      }
    }
    stdout.writeln(
      '${DateTime.now().toIso8601String()} scanned ${vaults.length} vaults, '
      '${dryRun ? 'dry run' : 'acted on $acted'}',
    );
  }
}

extension on Keeper {
  /// Releases the first schedule of [v] that is due; true if it acted.
  Future<bool> _sweepVesting(VaultState v, FeeSchedule fees, int now) async {
    for (var i = 0; i < v.rules.length; i++) {
      final rule = v.rules[i];
      if (rule.executed) continue;
      final claimable = v.claimable(i, now);
      final slot = '${v.address}:$i';
      if (!vestingReleaseDue(
        claimable: claimable,
        fullyVested: v.vested(i, now) >= v.vestingCap(i),
        now: now,
        interval: vestInterval,
        lastRelease: _lastRelease[slot],
      )) {
        continue;
      }
      final tag = '${v.address} vesting $i -> ${rule.beneficiary}';
      try {
        final d = await decide(
          v,
          i,
          fees,
          now,
          asTier: vestingAsTier(rule, claimable),
        );
        if (d.action != KeeperAction.execute || dryRun) {
          stdout.writeln('${dryRun ? 'DRY ' : ''}$tag: $d');
          continue;
        }
        final sig = await _execute(v, i, fees, d);
        _lastRelease[slot] = now;
        stdout.writeln('$tag: release $d: $sig');
        return true;
      } on Exception catch (e) {
        stderr.writeln('$tag failed: $e');
      }
    }
    return false;
  }
}

const _usage =
    'usage: --keypair <path> [--rpc <url>] [--every <seconds>] [--dry-run] '
    '[--price <mint>=<lamports per base unit>]... '
    '[--vest-interval <seconds, default 86400>] '
    '[--usdc-price-lamports <per USDC base unit, default 6 = 0.006 SOL/USDC>]';

Future<void> main(List<String> argv) async {
  final args = <String, String>{};
  final prices = <String, double>{};
  var dryRun = false;
  for (var i = 0; i < argv.length; i++) {
    final a = argv[i];
    if (a == '--dry-run') {
      dryRun = true;
    } else if (a.startsWith('--') && i + 1 < argv.length) {
      final value = argv[++i];
      if (a == '--price') {
        final [mint, lamports] = value.split('=');
        prices[mint] = double.parse(lamports);
      } else {
        args[a.substring(2)] = value;
      }
    } else {
      stderr.writeln(_usage);
      exit(64);
    }
  }
  final keypairPath = args['keypair'];
  if (keypairPath == null) {
    stderr.writeln(_usage);
    exit(64);
  }
  final rpc = args['rpc'] ?? 'https://api.devnet.solana.com';
  final every = int.tryParse(args['every'] ?? '');
  prices[AppConfig.usdcMint] ??=
      double.tryParse(args['usdc-price-lamports'] ?? '') ??
      defaultUsdcLamportsPerUnit;

  final secret = (jsonDecode(File(keypairPath).readAsStringSync()) as List)
      .cast<int>();
  final key = await Ed25519HDKeyPair.fromPrivateKeyBytes(
    privateKey: secret.sublist(0, 32),
  );
  final sol = SolanaClient(
    rpcUrl: Uri.parse(rpc),
    websocketUrl: Uri.parse(rpc.replaceFirst('http', 'ws')),
  );
  // No sponsor: the keeper pays its own fees.
  final client = DeadmanClient.withKora(client: sol);
  final keeper = Keeper(
    sol,
    client,
    key,
    dryRun: dryRun,
    prices: prices,
    vestInterval: int.tryParse(args['vest-interval'] ?? '') ?? 86400,
  );
  stdout.writeln('Keeper ${key.address} on $rpc${dryRun ? ' (dry run)' : ''}');

  do {
    try {
      await keeper.sweep();
    } on Exception catch (e) {
      stderr.writeln('sweep failed: $e');
    }
    if (every != null) await Future<void>.delayed(Duration(seconds: every));
  } while (every != null);
}
