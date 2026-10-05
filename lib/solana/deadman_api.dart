import 'dart:typed_data';

import 'package:solana/solana.dart';

import '../rails/rails.dart';

export '../rails/rails.dart' show Rail;

enum AmountMode { fixed, percent }

/// One release instruction: after [afterSecs] of owner silence, send
/// [amount] of [mint] (null = SOL) to [beneficiary] over [rail].
class RuleSpec {
  const RuleSpec({
    required this.beneficiary,
    required this.rail,
    required this.afterSecs,
    required this.mode,
    required this.amount,
    this.mint,
  });

  /// Solana key paid on-chain. For private rails this is the beneficiary's
  /// claim key from their Deadman app.
  final String beneficiary;
  final Rail rail;
  final int afterSecs;
  final String? mint;
  final AmountMode mode;

  /// Base units for [AmountMode.fixed], basis points for [AmountMode.percent].
  final int amount;
}

enum PlanKind { inheritance, vesting }

/// One beneficiary's vesting schedule: [total] of [mint] (null = SOL)
/// vests from the plan start over [durationSecs], continuously or in
/// installments (the plan's period); nothing is claimable before
/// [cliffSecs].
class VestingSpec {
  const VestingSpec({
    required this.beneficiary,
    required this.rail,
    required this.total,
    required this.cliffSecs,
    required this.durationSecs,
    this.mint,
  });

  final String beneficiary;
  final Rail rail;
  final String? mint;

  /// Base units (lamports for SOL).
  final int total;
  final int cliffSecs;
  final int durationSecs;
}

class RuleState extends RuleSpec {
  const RuleState({
    required super.beneficiary,
    required super.rail,
    required super.afterSecs,
    required super.mode,
    required super.amount,
    super.mint,
    required this.executedAt,
    required this.paid,
    this.skippedAt = 0,
    this.reserved = 0,
    this.durationSecs = 0,
    this.released = 0,
  });

  /// Unix seconds; 0 while pending.
  final int executedAt;

  /// Net amount the beneficiary received.
  final int paid;

  /// Unix seconds when later tiers were allowed to run past this one because
  /// it could not pay within the plan's grace period; 0 if never skipped. A
  /// skipped tier stays claimable by its own beneficiary.
  final int skippedAt;

  /// Gross share set aside for a skipped tier (0 = recomputed when claimed).
  final int reserved;

  /// Vesting only: seconds from the plan start to fully vested. For a
  /// vesting schedule [afterSecs] is the cliff and [amount] the total.
  final int durationSecs;

  /// Vesting only: gross amount released so far.
  final int released;

  bool get executed => executedAt != 0;
  bool get skipped => skippedAt != 0;

  /// Paid, or skipped: later tiers of the same asset may run.
  bool get settled => executed || skipped;
}

/// Mirror of the on-chain `Vault` account plus its lamport balance.
class VaultState {
  const VaultState({
    required this.address,
    required this.owner,
    required this.planId,
    required this.label,
    required this.guard,
    required this.guardian,
    required this.lockSecs,
    required this.skipGraceSecs,
    required this.lastPulse,
    required this.ownerLastSeen,
    required this.lockedUntil,
    required this.guardianReadyAt,
    required this.totalPulses,
    required this.streak,
    required this.bestStreak,
    required this.rules,
    required this.lamports,
    required this.withdrawableLamports,
    this.kind = PlanKind.inheritance,
    this.startAt = 0,
    this.revocable = false,
    this.revokedAt = 0,
    this.rentPayer = '',
    this.rentPaid = 0,
    this.vestPeriodSecs = 0,
  });

  final String address;
  final String owner;

  /// Owner-chosen id; an owner can hold many independent plans.
  final int planId;
  final String label;
  final String guard;
  final String? guardian;
  final int lockSecs;

  /// Owner-chosen time a due tier gets to pay before it may be skipped
  /// (the Deadman keeper skips it once this passes).
  final int skipGraceSecs;

  /// Unix seconds.
  final int lastPulse;

  /// Last wallet-signed (owner) action. Guard-key check-ins keep the plan
  /// alive only within [guardWindowSecs] of it, and not at all after a tier
  /// released or was skipped since then.
  final int ownerLastSeen;
  final int lockedUntil;
  final int guardianReadyAt;
  final int totalPulses;
  final int streak;
  final int bestStreak;
  final List<RuleState> rules;
  final int lamports;

  /// Lamports above the rent reserve: the larger of [rentPaid] and the
  /// current rent-exempt minimum.
  final int withdrawableLamports;

  final PlanKind kind;

  /// Vesting: when every schedule starts vesting (unix seconds).
  final int startAt;

  /// Vesting: the owner may stop future vesting (vested stays claimable).
  final bool revocable;

  /// Vesting: when it was revoked; 0 if never.
  final int revokedAt;

  /// Who funded the account rent; closing returns it to them.
  final String rentPayer;

  /// Rent [rentPayer] deposited at creation; closing returns exactly this
  /// to them and everything else to the owner.
  final int rentPaid;

  /// Vesting: installment length in seconds; vesting unlocks only at whole
  /// multiples of it from [startAt] (fully at the duration). 0 = continuous
  /// (plans created before installments existed).
  final int vestPeriodSecs;

  bool get isVesting => kind == PlanKind.vesting;

  /// Seconds of schedule time counted at [now]: vesting stops at revocation.
  int _elapsed(int now) =>
      (revokedAt != 0 && revokedAt < now ? revokedAt : now) - startAt;

  /// Gross amount of schedule [index] vested after [elapsed] seconds.
  int _vestedAt(int index, int elapsed) {
    final r = rules[index];
    if (elapsed < r.afterSecs) return 0;
    if (elapsed >= r.durationSecs) return r.amount;
    final unlocked = vestPeriodSecs > 0
        ? elapsed ~/ vestPeriodSecs * vestPeriodSecs
        : elapsed;
    return (BigInt.from(r.amount) *
            BigInt.from(unlocked) ~/
            BigInt.from(r.durationSecs))
        .toInt();
  }

  /// Vesting: gross amount of schedule [index] vested at [now] (mirrors
  /// the program's `vested`, including the stop at revocation and the
  /// installment steps).
  int vested(int index, int now) => _vestedAt(index, _elapsed(now));

  /// Vesting: number of installments of schedule [index] (the last one may
  /// be shorter); null for continuous vesting.
  int? installmentCount(int index) {
    if (vestPeriodSecs <= 0) return null;
    final d = rules[index].durationSecs;
    return (d + vestPeriodSecs - 1) ~/ vestPeriodSecs;
  }

  /// Vesting: installments of schedule [index] unlocked at [now] (0 before
  /// the cliff, all of them once fully vested); null for continuous
  /// vesting.
  int? installmentsUnlocked(int index, int now) {
    final count = installmentCount(index);
    if (count == null) return null;
    final r = rules[index];
    final elapsed = _elapsed(now);
    if (elapsed < r.afterSecs) return 0;
    if (elapsed >= r.durationSecs) return count;
    final n = elapsed ~/ vestPeriodSecs;
    return n < count ? n : count;
  }

  /// Vesting: gross amount of one full installment of schedule [index]
  /// (the cliff may unlock several at once, the last one is the rest);
  /// null for continuous vesting.
  int? installmentAmount(int index) {
    if (vestPeriodSecs <= 0) return null;
    final r = rules[index];
    return (BigInt.from(r.amount) *
            BigInt.from(vestPeriodSecs) ~/
            BigInt.from(r.durationSecs))
        .toInt();
  }

  /// Vesting: unix seconds of the first moment after [now] when schedule
  /// [index] vests more (the cliff, an installment boundary, or the end of
  /// the duration); null when fully vested, revoked, or continuous.
  int? nextInstallmentAt(int index, int now) {
    if (vestPeriodSecs <= 0 || revokedAt != 0) return null;
    final r = rules[index];
    final elapsed = now - startAt;
    if (elapsed >= r.durationSecs) return null;
    final current = _vestedAt(index, elapsed);
    if (current >= r.amount) return null;
    final first = elapsed + 1 > r.afterSecs ? elapsed + 1 : r.afterSecs;
    if (_vestedAt(index, first) > current) return startAt + first;
    // Fewest whole periods k with floor(total * k * period / duration)
    // above the current amount.
    final p = BigInt.from(vestPeriodSecs);
    final need = BigInt.from(current + 1) * BigInt.from(r.durationSecs);
    final per = BigInt.from(r.amount) * p;
    final k = (need + per - BigInt.one) ~/ per;
    final at = k * p;
    final end = BigInt.from(r.durationSecs);
    return startAt + (at < end ? at : end).toInt();
  }

  /// Vesting: the most schedule [index] can ever release.
  int vestingCap(int index) =>
      revokedAt != 0 ? vested(index, revokedAt) : rules[index].amount;

  /// Vesting: what schedule [index] could release right now (before the
  /// vault balance cap and fees).
  int claimable(int index, int now) {
    final left = vested(index, now) - rules[index].released;
    return left < 0 ? 0 : left;
  }

  /// Vesting: amount of [mint] (null = SOL) still owed to beneficiaries;
  /// the owner cannot withdraw below it. 0 for inheritance plans.
  int committed(String? mint) {
    if (!isVesting) return 0;
    var total = 0;
    for (var i = 0; i < rules.length; i++) {
      if (rules[i].mint != mint) continue;
      final owed = vestingCap(i) - rules[i].released;
      if (owed > 0) total += owed;
    }
    return total;
  }

  static const guardWindowSecs = 365 * 86400;

  /// When guard-key check-ins stop being accepted without a wallet check-in.
  int get guardWindowEnd => ownerLastSeen + guardWindowSecs;

  /// The guard key may check in now (otherwise the owner's wallet must).
  bool guardCanPulse(int now) =>
      now <= guardWindowEnd &&
      !rules.any(
        (r) => r.executedAt > ownerLastSeen || r.skippedAt > ownerLastSeen,
      );

  /// Earlier tiers of rule [index]'s asset have all paid or been skipped.
  bool _earlierSettled(int index) {
    final mint = rules[index].mint;
    for (var j = 0; j < index; j++) {
      if (rules[j].mint == mint && !rules[j].settled) return false;
    }
    return true;
  }

  /// Rule [index] is pending, next for its asset, and still has not paid
  /// after its grace period. Skipping reserves its share; it stays claimable.
  bool canSkip(int index, int now) {
    final r = rules[index];
    if (r.settled || now <= ruleDueAt(index) + skipGraceSecs) return false;
    return _earlierSettled(index);
  }

  /// Every tier has paid; the program rejects further check-ins. A skipped
  /// but unclaimed tier keeps the plan open.
  bool get completed => rules.every((r) => r.executed);
  int ruleDueAt(int index) => lastPulse + rules[index].afterSecs;
  bool isLocked(int now) => now < lockedUntil;

  /// When the next tier releases unless the owner checks in first: the
  /// earliest pending tier deadline (last check-in + its delay), or null
  /// when every tier has paid or been skipped. The plan is alive until then.
  int? get nextReleaseAt => nextRuleDue;

  /// Earliest pending rule deadline, or null when every rule has paid or
  /// been skipped.
  int? get nextRuleDue {
    int? next;
    for (var i = 0; i < rules.length; i++) {
      if (rules[i].settled) continue;
      final due = ruleDueAt(i);
      if (next == null || due < next) next = due;
    }
    return next;
  }

  /// Shares reserved for skipped, unpaid tiers of [mint] (null = SOL),
  /// other than [except] (mirrors the program's `reserved_for`).
  int reservedFor(String? mint, {int except = -1}) {
    var total = 0;
    for (var j = 0; j < rules.length; j++) {
      final r = rules[j];
      if (j != except && r.mint == mint && !r.executed && r.skipped) {
        total += r.reserved;
      }
    }
    return total;
  }

  /// Gross amount tier [index] pays from [balance] of its asset (mirrors
  /// the program's `payout_gross`): a skipped tier gets its reserved share;
  /// any other tier works on the balance minus every reserved share.
  int payoutGross(int index, int balance) {
    final r = rules[index];
    if (r.skipped && r.reserved > 0) {
      return r.reserved < balance ? r.reserved : balance;
    }
    final left = balance - reservedFor(r.mint, except: index);
    if (left <= 0) return 0;
    return switch (r.mode) {
      AmountMode.fixed => r.amount < left ? r.amount : left,
      AmountMode.percent =>
        (BigInt.from(left) * BigInt.from(r.amount) ~/ BigInt.from(10000))
            .toInt(),
    };
  }

  /// Unpaid and either skipped (claimable any time) or due with every
  /// earlier rule for the same asset paid or skipped.
  bool canExecute(int index, int now) {
    final r = rules[index];
    if (r.executed) return false;
    if (r.skipped) return true;
    if (now <= ruleDueAt(index)) return false;
    return _earlierSettled(index);
  }
}

class FeeSchedule {
  const FeeSchedule({
    required this.treasury,
    required this.feeBpsPublic,
    required this.feeBpsPrivate,
  });

  final String treasury;
  final int feeBpsPublic;
  final int feeBpsPrivate;

  int bpsFor(Rail rail) => rail == Rail.solana ? feeBpsPublic : feeBpsPrivate;
}

/// An owner's account-wide subscription (`Subscription`, PDA
/// `["sub", owner]`): while paid it waives the payout fee on every plan of
/// [owner], present and future.
class AccountSubscription {
  const AccountSubscription({required this.owner, required this.paidUntil});

  final String owner;

  /// End of the paid coverage (unix seconds); 0 if never paid.
  final int paidUntil;

  /// Paid through [now]: an extension may then be any number of periods,
  /// while a new or lapsed subscription needs the minimum term.
  bool active(int now) => paidUntil >= now;
}

/// Whether [sub] (the owner's subscription, null when never created)
/// waives the payout fee of [vault] at [now]. Mirrors the program's
/// `Subscription::covers`: for inheritance, the owner's last check-in fell
/// within a paid period, however late the payout runs; for vesting, the
/// subscription is paid at [now].
bool feeWaivedFor(VaultState vault, AccountSubscription? sub, int now) =>
    sub != null &&
    sub.owner == vault.owner &&
    sub.paidUntil != 0 &&
    switch (vault.kind) {
      PlanKind.inheritance => sub.paidUntil >= vault.lastPulse,
      PlanKind.vesting => sub.paidUntil >= now,
    };

/// Payout fee of [vault] on [rail] at [now]: 0 while [sub] covers it (see
/// [feeWaivedFor]), else the [fees] schedule (mirrors `payout_fee_bps`).
int payoutFeeBps(
  FeeSchedule fees,
  VaultState vault,
  AccountSubscription? sub,
  Rail rail,
  int now,
) => feeWaivedFor(vault, sub, now) ? 0 : fees.bpsFor(rail);

/// The optional flat subscription (`SubscriptionConfig`) that waives the
/// payout fee on all of an owner's plans while paid.
class SubscriptionTerms {
  const SubscriptionTerms({
    required this.pricePerPeriod,
    required this.periodSecs,
    required this.mint,
    required this.minPeriods,
    this.enabled = true,
  });

  /// Base units of [mint] per period.
  final int pricePerPeriod;
  final int periodSecs;
  final String mint;

  /// Periods a new or lapsed subscription must buy at once.
  final int minPeriods;
  final bool enabled;

  /// Most periods one `subscribe` may buy.
  static const maxPeriods = 36;

  int cost(int periods) => pricePerPeriod * periods;

  /// Fewest periods an owner whose subscription is [sub] (null = never
  /// created) may buy at [now]: [minPeriods] when new or lapsed, else 1.
  int minPeriodsFor(AccountSubscription? sub, int now) =>
      sub != null && sub.active(now) ? 1 : minPeriods;

  /// `Subscription.paid_until` after buying [periods] at [now].
  int paidUntilAfter(AccountSubscription? sub, int periods, int now) {
    final current = sub?.paidUntil ?? 0;
    return (current > now ? current : now) + periodSecs * periods;
  }

  /// Whether a period is about a month (28 to 31 days).
  bool get monthly => periodSecs >= 28 * 86400 && periodSecs <= 31 * 86400;
}

/// Who pays for a beneficiary's own claim.
enum ClaimPayer {
  /// The Kora sponsor pays the network fee: the claim is free.
  sponsor,

  /// The Kora paymaster pays the network fee and any token account rent,
  /// and takes its USDC fee from the payout in the same transaction.
  payout,

  /// The wallet pays the network fee (in SOL, or in the fee token).
  wallet,
}

/// What claiming a tier or vested amount costs its beneficiary.
class ClaimQuote {
  const ClaimQuote({
    required this.payer,
    required this.mint,
    required this.net,
    this.feeToken,
    this.feeAmount = 0,
    this.problem,
  });

  final ClaimPayer payer;

  /// Asset paid out (null = SOL).
  final String? mint;

  /// What the beneficiary receives from the plan, base units of [mint],
  /// before any claim fee.
  final int net;

  /// Token the paymaster charges ([ClaimPayer.payout]); null otherwise.
  final String? feeToken;

  /// Claim fee in [feeToken] base units; 0 when free or paid by the wallet.
  final int feeAmount;

  /// Why the claim cannot go through as quoted; null when it can.
  final String? problem;

  bool get free => payer == ClaimPayer.sponsor;
}

/// A beneficiary's unsigned claim and who pays for it.
class ClaimTx {
  const ClaimTx(this.transaction, this.payer, {this.note});

  final Uint8List transaction;
  final ClaimPayer payer;

  /// Why the claim is not paid as quoted (the free service is down).
  final String? note;
}

/// Client for the Deadman program. `build*` methods return serialized,
/// unsigned transactions (fee payer = the signer named first) to hand to
/// [WalletBridge.signTransactions]. Key-signed methods sign and send directly.
abstract class DeadmanApi {
  /// Plan vault PDA: seeds `["vault", owner, planId as u16 LE]`.
  String vaultAddressFor(String owner, int planId);

  Future<VaultState?> fetchVault(String owner, int planId);

  /// Plan number for [owner]'s next new plan (never reuses an address that
  /// already holds an account, even one in an older layout).
  Future<int> nextFreePlanId(String owner);

  /// Every plan of [owner], sorted by plan id.
  Future<List<VaultState>> fetchVaults(String owner);

  /// Plan ids of [owner]'s accounts left in an older layout by a program
  /// upgrade (not readable as plans; see [buildRecoverLegacyVault]).
  Future<List<int>> fetchLegacyPlanIds(String owner);

  /// Closes [owner]'s plan [planId] that is in an older layout and returns
  /// all its SOL to the owner. Tokens in that plan's token accounts stay
  /// where they are.
  Future<Uint8List> buildRecoverLegacyVault({
    required String owner,
    required int planId,
  });

  /// Every Deadman vault (keepers use this to find due rules).
  Future<List<VaultState>> fetchAllVaults();

  /// Vaults where [wallet] is a rule beneficiary or the guardian.
  Future<List<VaultState>> fetchWatchedVaults(String wallet);

  Future<FeeSchedule> fetchFees();

  Future<int> balance(String address);

  /// Token balance (base units) of [owner]'s ATA for [mint]; 0 if missing.
  Future<int> tokenBalance(String owner, String mint);

  /// [tokenBalance] for many (owner, mint) pairs, batched into as few RPC
  /// calls as possible; same order as [accounts].
  Future<List<int>> tokenBalances(List<(String, String)> accounts);

  /// Creates plan [planId], funds the guard key with fee money if it holds
  /// less than that, and optionally deposits [depositLamports] and tokens
  /// ([tokenDeposits]: mint -> base units, from the owner's ATA), in one tx.
  Future<Uint8List> buildCreateVault({
    required String owner,
    required int planId,
    required String label,
    required String guard,
    required int lockSecs,
    required int skipGraceSecs,
    required List<RuleSpec> rules,
    int depositLamports = 0,
    Map<String, int> tokenDeposits = const {},
  });

  Future<Uint8List> buildDeposit({
    required String owner,
    required int planId,
    required int lamports,
  });

  /// Moves [amount] of [mint] from the owner's ATA into the plan vault's ATA
  /// (created idempotently).
  Future<Uint8List> buildDepositToken({
    required String owner,
    required int planId,
    required String mint,
    required int amount,
  });

  Future<Uint8List> buildWithdrawSol({
    required String owner,
    required int planId,
    required int lamports,
  });

  Future<Uint8List> buildWithdrawToken({
    required String owner,
    required int planId,
    required String mint,
    required int amount,
  });

  /// [rules] are the new pending tiers only: tiers that already released
  /// stay on-chain as history and are not resent. A fully released plan is
  /// final: it throws `PlanCompleted`.
  Future<Uint8List> buildUpdatePolicy({
    required String owner,
    required int planId,
    required String label,
    required int lockSecs,
    required int skipGraceSecs,
    required List<RuleSpec> rules,
    String? guardian,
  });

  /// Rotates the guard on every listed plan in one transaction.
  Future<Uint8List> buildSetGuard({
    required String owner,
    required List<int> planIds,
    required String newGuard,
  });

  /// Owner-signed lockdown, for plans this device's guard key cannot lock.
  Future<Uint8List> buildLockdownByOwner({
    required String owner,
    required List<int> planIds,
  });

  Future<Uint8List> buildPulseByOwner({
    required String owner,
    required List<int> planIds,
  });

  /// Executes rule [index] of a plan (SOL or token variant, chosen from the
  /// rule). For token rules it also creates, idempotently, the treasury's
  /// and the beneficiary's ATAs (paid by [executor]): the program pays into
  /// any token account the beneficiary owns but no longer creates one.
  Future<Uint8List> buildExecuteRule({
    required String executor,
    required String vaultOwner,
    required int planId,
    required int index,
  });

  /// Skips rule [index] (see [VaultState.canSkip]); anyone may sign (the
  /// keeper does it automatically; the app offers no manual skip). Token
  /// tiers pass the vault's ATA so the program can reserve the tier's share.
  Future<Uint8List> buildSkipRule({
    required String caller,
    required String vaultOwner,
    required int planId,
    required int index,
  });

  /// Creates vesting plan [planId]: [schedules] vest from [startAt]
  /// whatever the owner does, in installments of [periodSecs] (at least
  /// `Limits.minVestPeriodSecs` and at most the shortest schedule duration;
  /// 0 = continuously). Optionally funds it in the same transaction with
  /// SOL ([depositLamports]) and/or tokens ([tokenDeposits]: mint -> base
  /// units, from the owner's ATA).
  Future<Uint8List> buildCreateVesting({
    required String owner,
    required int planId,
    required String label,
    required String guard,
    required int lockSecs,
    required int startAt,
    required bool revocable,
    required List<VestingSpec> schedules,
    int periodSecs = 0,
    int depositLamports = 0,
    Map<String, int> tokenDeposits = const {},
  });

  /// Stops future vesting of a revocable plan (owner wallet).
  Future<Uint8List> buildRevokeVesting({
    required String owner,
    required int planId,
  });

  /// Releases what has vested on schedule [index] (SOL or token variant
  /// from the schedule; token releases create the ATAs like executing a
  /// tier). Anyone may sign.
  Future<Uint8List> buildReleaseVested({
    required String executor,
    required String vaultOwner,
    required int planId,
    required int index,
  });

  /// What [buildClaim] would cost [claimer], the beneficiary of rule or
  /// schedule [index].
  Future<ClaimQuote> quoteClaim({
    required String claimer,
    required String vaultOwner,
    required int planId,
    required int index,
  });

  /// Rule or schedule [index] (execute or release, from the plan kind)
  /// claimed by its own beneficiary [claimer], who needs no SOL: a SOL
  /// payout goes through the free Kora sponsor, a USDC payout through the
  /// paymaster, which takes its fee from the payout. Falls back to
  /// [buildExecuteRule] / [buildReleaseVested] (the wallet pays) when
  /// [claimer] is not the beneficiary, Kora is not configured, or, for
  /// SOL, the sponsor is unreachable or [sponsored] is false (after the
  /// sponsor refused the signed claim).
  Future<ClaimTx> buildClaim({
    required String claimer,
    required String vaultOwner,
    required int planId,
    required int index,
    bool sponsored = true,
  });

  /// Same as [buildReleaseVested], signed by a local key (keeper, claim
  /// key) and sent.
  Future<String> releaseVestedWithKey(
    Ed25519HDKeyPair executor, {
    required String vaultOwner,
    required int planId,
    required int index,
  });

  /// Network fees for wallet-signed owner transactions: null = the wallet
  /// pays in SOL; a mint (USDC) = the Kora paymaster pays and charges the
  /// owner in that token (needs `AppConfig.koraPaymasterUrl`).
  String? get feeToken;
  set feeToken(String? mint);

  /// Closes plan [planId]: every token it holds goes back to the owner's
  /// token accounts and its SOL to the owner (the rent to the rent payer),
  /// in one transaction. Vesting plans close only once nothing is owed.
  Future<Uint8List> buildCloseVault({
    required String owner,
    required int planId,
  });

  /// Guard-key actions over several plans, one transaction, no wallet prompt.
  Future<String> pulseWithGuard(
    Ed25519HDKeyPair guard, {
    required String vaultOwner,
    required List<int> planIds,
  });

  Future<String> lockdownWithGuard(
    Ed25519HDKeyPair guard, {
    required String vaultOwner,
    required List<int> planIds,
  });

  /// Skips a rule, signed by a local key (keeper).
  Future<String> skipRuleWithKey(
    Ed25519HDKeyPair caller, {
    required String vaultOwner,
    required int planId,
    required int index,
  });

  /// Executes a rule signed by a local key (claim key or keeper).
  Future<String> executeRuleWithKey(
    Ed25519HDKeyPair executor, {
    required String vaultOwner,
    required int planId,
    required int index,
  });

  /// The monthly-plan terms, or null when not offered (no config on chain,
  /// or disabled).
  Future<SubscriptionTerms?> fetchSubscriptionTerms();

  /// [owner]'s account-wide subscription, or null when never created.
  Future<AccountSubscription?> fetchSubscription(String owner);

  /// Prepays [periods] periods of [owner]'s account-wide subscription,
  /// which waives the payout fee on every plan of the owner, including
  /// plans created later (see [feeWaivedFor]). A new or lapsed subscription
  /// must buy at least [SubscriptionTerms.minPeriods]; an active one may
  /// extend by any number (1 to [SubscriptionTerms.maxPeriods] per
  /// transaction). The price comes from the owner's token account of
  /// [SubscriptionTerms.mint]; the subscription account's rent, on first
  /// use, from the owner (or the paymaster when fees are paid in USDC).
  Future<Uint8List> buildSubscribe({
    required String owner,
    required int periods,
  });

  /// Submits wallet-signed transactions; returns signatures after confirmation.
  Future<List<String>> sendSigned(List<Uint8List> signedTransactions);
}
