import '../solana/deadman_api.dart';
import 'plan_math.dart';

/// Where the owner's account-wide monthly plan stands.
enum SubscriptionStatus {
  /// Never subscribed: releases pay the percentage fee.
  none,

  /// Paid through now: every plan's releases are fee-free and any
  /// extension is allowed.
  active,

  /// Ended: a new start needs the minimum term again. Inheritance plans
  /// whose last check-in fell within the paid time stay covered until the
  /// next check-in (see [feeWaivedFor]).
  lapsed,
}

SubscriptionStatus subscriptionStatus(AccountSubscription? sub, int now) =>
    sub == null || sub.paidUntil == 0
    ? SubscriptionStatus.none
    : sub.active(now)
    ? SubscriptionStatus.active
    : SubscriptionStatus.lapsed;

/// Period counts to offer at [now] to an owner whose subscription is [sub]:
/// multiples of the minimum term when new or lapsed (12 / 24 / 36), short
/// extensions while active.
List<int> subscriptionChoices(
  SubscriptionTerms terms,
  AccountSubscription? sub,
  int now,
) {
  final min = terms.minPeriodsFor(sub, now);
  final options = min <= 1 ? const [1, 3, 6, 12] : [min, min * 2, min * 3];
  return [
    for (final p in options)
      if (p >= min && p <= SubscriptionTerms.maxPeriods) p,
  ];
}

/// A plan card's fee line: waived by the owner's subscription [sub], or
/// the [fees] schedule.
String planFeeText(
  VaultState v,
  AccountSubscription? sub,
  FeeSchedule? fees,
  int now,
) => feeWaivedFor(v, sub, now)
    ? '0% release fee · monthly plan'
    : fees == null
    ? 'Release fee on payouts'
    : releaseFeeText(fees);

/// What [v] still has to pay out, per unsettled tier or schedule of
/// [mint], from [balance]: (rule index, gross amount), in payout order.
List<(int, int)> _pendingPayouts(VaultState v, String? mint, int balance) {
  var left = balance;
  final out = <(int, int)>[];
  void pay(int i, int want) {
    final gross = want < left ? want : left;
    if (gross <= 0) return;
    out.add((i, gross));
    left -= gross;
  }

  if (v.isVesting) {
    for (final (i, r) in v.rules.indexed) {
      if (r.mint == mint) pay(i, v.vestingCap(i) - r.released);
    }
    return out;
  }
  // Skipped tiers keep their reserved share; the rest run in delay order.
  final order =
      [
        for (final (i, r) in v.rules.indexed)
          if (r.mint == mint && !r.executed) i,
      ]..sort((a, b) {
        final ra = v.rules[a], rb = v.rules[b];
        if (ra.skipped != rb.skipped) return ra.skipped ? -1 : 1;
        return ra.afterSecs.compareTo(rb.afterSecs);
      });
  for (final i in order) {
    final r = v.rules[i];
    pay(
      i,
      r.skipped && r.reserved > 0
          ? r.reserved
          : switch (r.mode) {
              AmountMode.fixed => r.amount,
              AmountMode.percent =>
                (BigInt.from(left) *
                        BigInt.from(r.amount) ~/
                        BigInt.from(10000))
                    .toInt(),
            },
    );
  }
  return out;
}

/// Protocol fee [v] would pay at [fees] (ignoring any subscription) if
/// [balance] of [mint] (null = SOL) were released as the plan stands.
int releaseFeeEstimate(
  VaultState v,
  FeeSchedule fees,
  String? mint,
  int balance,
) {
  var fee = 0;
  for (final (i, gross) in _pendingPayouts(v, mint, balance)) {
    fee +=
        (BigInt.from(gross) *
                BigInt.from(fees.bpsFor(v.rules[i].rail)) ~/
                BigInt.from(10000))
            .toInt();
  }
  return fee;
}

/// Protocol fee all of [plans] would pay at [fees] (ignoring any
/// subscription) if they released what they hold of [mint] (null = SOL):
/// [held] maps a vault address to its balance; SOL comes from the plans.
int plansReleaseFeeEstimate(
  Iterable<VaultState> plans,
  FeeSchedule fees,
  String? mint, [
  Map<String, int> held = const {},
]) {
  var fee = 0;
  for (final v in plans) {
    final balance = mint == null ? v.withdrawableLamports : held[v.address];
    if (balance != null) fee += releaseFeeEstimate(v, fees, mint, balance);
  }
  return fee;
}

/// "2%", "5%" or "2% / 5%": the rates [v]'s unsettled tiers pay.
String pendingFeeRates(VaultState v, FeeSchedule fees) =>
    plansPendingFeeRates([v], fees);

/// [pendingFeeRates] across all of [plans].
String plansPendingFeeRates(Iterable<VaultState> plans, FeeSchedule fees) {
  final bps = <int>{
    for (final v in plans)
      for (final (i, r) in v.rules.indexed)
        if (v.isVesting ? v.vestingCap(i) > r.released : !r.executed)
          fees.bpsFor(r.rail),
  }.toList()..sort();
  if (bps.isEmpty) bps.add(fees.feeBpsPublic);
  return bps.map((b) => percentText(b / 10000)).join(' / ');
}

/// "Release fee: 2% (5% private rails)".
String releaseFeeText(FeeSchedule fees) =>
    'Release fee: ${percentText(fees.feeBpsPublic / 10000)} '
    '(${percentText(fees.feeBpsPrivate / 10000)} private rails)';

/// "month" / "months" for a monthly plan, "period" / "periods" otherwise.
String periodWord(SubscriptionTerms terms, int n) =>
    '${terms.monthly ? 'month' : 'period'}${n == 1 ? '' : 's'}';
