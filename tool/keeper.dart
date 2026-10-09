// Protocol keeper: executes due rules in every Deadman vault. Execution is
// permissionless and destinations are fixed on-chain, so the keeper can't
// redirect funds; the release fee (2%, 1.5% in SKR) is what pays for running
// it.
//
// Policy (audits M-3, M-4): the keeper releases a tier or a vesting
// installment only when the fee the treasury earns from it covers what the
// keeper pays: the network fee and any ATA rent. Anything smaller (dust,
// NFTs, tokens without a known price) is left for the beneficiary to
// claim. Of an SKR fee only the share that is not burned counts. Tiers
// that cannot pay at all are skipped once their grace period is over, but
// only when that unblocks a later tier of the same asset; a skipped tier
// keeps its share reserved and stays claimable, so the keeper executes it
// (same policy) once it can pay, and never skips it again. At most one
// action per vault per sweep.
//
// Vesting plans: releases what has vested on each schedule under the same
// rules, at most once per --vest-interval per schedule (and always once
// fully vested), installments included. Inheritance-only actions never
// touch them.
//
// dart run tool/keeper.dart --keypair <path> [--cluster devnet|mainnet-beta]
//   [--rpc <url>] [--every 60] [--dry-run]
//   [--price <mint>=<lamports per base unit>]...
//   [--vest-interval <seconds>] [--usdc-price-lamports <per base unit>]
//   [--cu-price <micro-lamports per CU>]
//
// --cluster picks the default RPC and USDC mint, and the keeper refuses to
// start when the RPC's genesis hash belongs to another cluster.
//
// Only USDC has a default --price (--usdc-price-lamports). Other plan
// tokens, SKR and ORE included, have no known price unless passed (e.g.
// --price <SKR mint>=<lamports per base unit>): their fee is then worth 0
// and the keeper leaves their tiers to the beneficiary. The same holds for
// NFT tiers (amount 1, whose fee rounds down to 0); such a payout leaves
// out the treasury token account (FUNDS-5).
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

/// Base fee per signature; the keeper's transactions have one.
const lamportsPerSignature = 5000;

/// Compute units the runtime allows each instruction when no limit is set.
const defaultCuPerIx = 200000;

/// What the keeper pays to send [instructions] instructions (compute budget
/// excluded) at [cuPrice] micro-lamports per compute unit.
int networkFeeLamports({int instructions = 1, int cuPrice = 0}) {
  final micro = BigInt.from(1000000);
  final priority =
      (BigInt.from(instructions * defaultCuPerIx) * BigInt.from(cuPrice) +
          micro -
          BigInt.one) ~/
      micro;
  return lamportsPerSignature + priority.toInt();
}

class Decision {
  const Decision(
    this.action,
    this.reason, {
    this.createAtasFor = const [],
    this.treasuryFee = true,
  });

  final KeeperAction action;
  final String reason;

  /// Owners whose ATA the keeper creates (and pays rent for) on execute.
  final List<String> createAtasFor;

  /// Whether the payout leaves a fee for the treasury, so its token account
  /// must be passed (FUNDS-5).
  final bool treasuryFee;

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
  final fee = bpsShare(gross, bps);
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
    : Decision(KeeperAction.wait, '$why; not skippable');

/// Whether skipping tier [index] lets a later tier of the same asset run:
/// only then is a skip worth its network fee (a skip also reserves the
/// tier's share, which the owner can no longer withdraw).
bool skipUnblocks(VaultState v, int index) {
  final mint = v.rules[index].mint;
  for (var j = index + 1; j < v.rules.length; j++) {
    final r = v.rules[j];
    if (r.mint == mint && !r.executed && !r.skipped) return true;
  }
  return false;
}

Decision _leaveToBeneficiary(String payout, int earned, int cost, String of) =>
    Decision(
      KeeperAction.wait,
      '$payout: fee worth ~$earned lamports does not cover $cost lamports '
      'of $of; left for the beneficiary to claim',
    );

class SolFacts {
  const SolFacts({
    required this.available,
    required this.feeBps,
    required this.beneficiaryLamports,
    required this.beneficiaryRentMin,
    required this.treasuryLamports,
    required this.treasuryRentMin,
    this.otherReserved = 0,
    this.networkFee = lamportsPerSignature,
  });

  /// Vault lamports above its rent-exempt minimum.
  final int available;

  /// What sending the release costs the keeper.
  final int networkFee;

  /// Lamports reserved for other skipped, unpaid SOL tiers.
  final int otherReserved;
  final int feeBps;
  final int beneficiaryLamports;
  final int beneficiaryRentMin;
  final int treasuryLamports;
  final int treasuryRentMin;
}

/// A due or skipped SOL rule: cannot pay when the payout is 0 or would leave
/// the beneficiary below rent exemption (the program rejects that with
/// BeneficiaryCannotReceive); executes only when the fee covers the
/// network fee (audit M-4).
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
  final payout = 'pays $net lamports, fee $fee';
  if (fee < f.networkFee) {
    return _leaveToBeneficiary(payout, fee, f.networkFee, 'network fee');
  }
  return Decision(KeeperAction.execute, payout);
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
    this.burnBps = 0,
    this.networkFee = lamportsPerSignature,
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

  /// Share of the fee that is burned (SKR); the treasury gets the rest.
  final int burnBps;

  /// What sending the release costs the keeper, ATA creates included.
  final int networkFee;
}

/// A due or skipped token rule: execute only when the vault holds the mint
/// and the treasury's share of the fee is worth at least the network fee
/// plus the ATA rent the keeper would pay (audit M-4). A payable tier is
/// never skipped just because it does not pay the keeper; the beneficiary
/// can claim it. A payout that leaves the treasury nothing needs no
/// treasury ATA (FUNDS-5).
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
  final (net, fee) = splitFee(gross, f.feeBps);
  final burned = bpsShare(fee, f.burnBps);
  final toTreasury = fee - burned;
  final treasuryFee = toTreasury > 0;
  if (treasuryFee && f.treasuryAta == AtaStatus.unusable) {
    return const Decision(KeeperAction.wait, 'treasury ATA unusable');
  }
  final missing = [
    if (f.beneficiaryAta == AtaStatus.missing) rule.beneficiary,
    if (treasuryFee && f.treasuryAta == AtaStatus.missing) treasury,
  ];
  final rent = missing.length * f.ataRent;
  final cost = f.networkFee + rent;
  final price = f.lamportsPerUnit;
  final feeValue = price == null ? 0 : (toTreasury * price).floor();
  final payout = 'pays $net, fee $fee${burned > 0 ? ' ($burned burned)' : ''}';
  if (feeValue < cost) {
    return _leaveToBeneficiary(
      payout,
      feeValue,
      cost,
      rent > 0 ? 'network fee and ATA rent' : 'network fee',
    );
  }
  return Decision(
    KeeperAction.execute,
    '$payout (~$feeValue lamports) covers $cost lamports'
    '${rent > 0 ? ' with $rent rent' : ''}',
    createAtasFor: missing,
    treasuryFee: treasuryFee,
  );
}

/// Whether to release a vesting schedule now: never with nothing new
/// vested; at most once per [interval] (unix seconds since [lastRelease]),
/// installment schedules included (audit M-4), except once [fullyVested]
/// so the last part never waits.
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

/// Defaults per `--cluster`: genesis hash (checked against the RPC), RPC
/// and USDC mint.
const clusters = <String, ({String genesisHash, String rpc, String usdcMint})>{
  'devnet': (
    genesisHash: 'EtWTRABZaYq6iMfeYKouRu166VU2xqa1wcaWoxPkrZBG',
    rpc: 'https://api.devnet.solana.com',
    usdcMint: '4zMMC9srt5Ri5X14GAgXhaHii3GnPAEERYPJgZJDncDU',
  ),
  'mainnet-beta': (
    genesisHash: '5eykt4UsFv8P8NJdTREpY1vzqKqZKvdpKuc147dw2N9d',
    rpc: 'https://api.mainnet-beta.solana.com',
    usdcMint: 'EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v',
  ),
};

class Keeper {
  Keeper(
    this.sol,
    this.client,
    this.key, {
    this.dryRun = false,
    this.prices = const {},
    this.vestInterval = 86400,
    this.cuPrice = 0,
  });

  final SolanaClient sol;
  final DeadmanClient client;
  final Ed25519HDKeyPair key;
  final bool dryRun;
  final Map<String, double> prices;

  /// Seconds between releases of one vesting schedule (the last part never
  /// waits).
  final int vestInterval;

  /// Priority fee (micro-lamports per compute unit) on execute and release
  /// transactions; 0 = none.
  final int cuPrice;
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
    final canSkip = asTier == null && v.canSkip(i, now) && skipUnblocks(v, i);
    final otherReserved = asTier == null ? reservedFor(v, i) : 0;
    final mint = rule.mint;
    final bps = fees.bpsFor(rule.rail, mint);
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
          networkFee: networkFeeLamports(cuPrice: cuPrice),
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
        burnBps: fees.isSkr(mint) ? fees.skrBurnBps : 0,
        // Up to two ATA creates and the payout.
        networkFee: networkFeeLamports(instructions: 3, cuPrice: cuPrice),
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
      if (cuPrice > 0)
        ComputeBudgetInstruction.setComputeUnitPrice(microLamports: cuPrice),
      for (final ix in build(
        executor: key.address,
        vaultOwner: v.owner,
        planId: v.planId,
        rule: v.rules[i],
        index: i,
        treasury: fees.treasury,
        treasuryFee: d.treasuryFee,
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
    'usage: --keypair <path> [--cluster devnet|mainnet-beta] [--rpc <url>] '
    '[--every <seconds>] [--dry-run] '
    '[--price <mint>=<lamports per base unit>]... '
    '[--vest-interval <seconds between releases of a schedule, default '
    '86400>] '
    '[--usdc-price-lamports <per USDC base unit, default 6 = 0.006 SOL/USDC>] '
    '[--cu-price <micro-lamports per compute unit, default 0>]';

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
  final cluster = clusters[args['cluster'] ?? AppConfig.cluster];
  if (cluster == null) {
    stderr.writeln('--cluster must be one of ${clusters.keys.join(', ')}');
    exit(64);
  }
  final rpc = args['rpc'] ?? cluster.rpc;
  final every = int.tryParse(args['every'] ?? '');
  prices[cluster.usdcMint] ??=
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
  final genesis = await sol.rpcClient.getGenesisHash();
  if (genesis != cluster.genesisHash) {
    stderr.writeln(
      'RPC genesis hash $genesis does not match --cluster '
      '${args['cluster'] ?? AppConfig.cluster}',
    );
    exit(1);
  }
  // No sponsor: the keeper pays its own fees.
  final client = DeadmanClient.withKora(client: sol);
  final keeper = Keeper(
    sol,
    client,
    key,
    dryRun: dryRun,
    prices: prices,
    vestInterval: int.tryParse(args['vest-interval'] ?? '') ?? 86400,
    cuPrice: int.tryParse(args['cu-price'] ?? '') ?? 0,
  );
  // Host only: RPC URLs often carry an API key in the query.
  stdout.writeln(
    'Keeper ${key.address} on ${Uri.parse(rpc).host} '
    '(${args['cluster'] ?? AppConfig.cluster})${dryRun ? ' (dry run)' : ''}',
  );

  do {
    try {
      await keeper.sweep();
    } on Exception catch (e) {
      stderr.writeln('sweep failed: $e');
    }
    if (every != null) await Future<void>.delayed(Duration(seconds: every));
  } while (every != null);
}
