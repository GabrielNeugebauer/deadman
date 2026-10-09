import '../solana/deadman_api.dart';
import 'plan_math.dart';

/// The fee model in one line, for places that can't read the fee schedule
/// (the program's defaults).
const feeSummaryStaticText =
    '2% on release · 1.5% for SKR (10% burned) · withdrawals free';

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

/// Release fee [v] would pay at [fees] if [balance] of [mint] (null = SOL)
/// were released as the plan stands.
int releaseFeeEstimate(
  VaultState v,
  FeeSchedule fees,
  String? mint,
  int balance,
) {
  var fee = 0;
  for (final (i, gross) in _pendingPayouts(v, mint, balance)) {
    fee += fees.feeOf(gross, v.rules[i].rail, mint);
  }
  return fee;
}

/// Release fee all of [plans] would pay at [fees] if they released what
/// they hold of [mint] (null = SOL):
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

/// "2%", or "1.5% / 2%" when tiers differ (SKR, private rails): the rates
/// [v]'s unsettled tiers pay.
String pendingFeeRates(VaultState v, FeeSchedule fees) =>
    plansPendingFeeRates([v], fees);

/// [pendingFeeRates] across all of [plans].
String plansPendingFeeRates(Iterable<VaultState> plans, FeeSchedule fees) {
  final bps = <int>{
    for (final v in plans)
      for (final (i, r) in v.rules.indexed)
        if (v.isVesting ? v.vestingCap(i) > r.released : !r.executed)
          fees.bpsFor(r.rail, r.mint),
  }.toList()..sort();
  if (bps.isEmpty) bps.add(fees.feeBpsPublic);
  return bps.map((b) => percentText(b / 10000)).join(' / ');
}

/// "2%", or "2% (3% private rails)" when the rails differ.
String _rates(FeeSchedule fees) => fees.feeBpsPrivate == fees.feeBpsPublic
    ? _pct(fees.feeBpsPublic)
    : '${_pct(fees.feeBpsPublic)} (${_pct(fees.feeBpsPrivate)} private rails)';

String _pct(int bps) => percentText(bps / 10000);

/// "1.5% for SKR (10% burned)", "1.5% for SKR", or null without an SKR rate.
String? skrFeeText(FeeSchedule fees) {
  if (fees.skrMint == null) return null;
  final burn = fees.skrBurnBps > 0 ? ' (${_pct(fees.skrBurnBps)} burned)' : '';
  return '${_pct(fees.feeBpsSkr)} for SKR$burn';
}

/// "2% on release · 1.5% for SKR (10% burned) · withdrawals free", from the
/// on-chain schedule ([feeSummaryStaticText] until it is read).
String feeSummaryText(FeeSchedule? fees) {
  if (fees == null) return feeSummaryStaticText;
  final skr = skrFeeText(fees);
  return ['${_rates(fees)} on release', ?skr, 'withdrawals free'].join(' · ');
}

/// "Release fee: 2%" or "Release fee: 1.5% · SKR, 10% burned" for a plan
/// card: the rates [v]'s unsettled payouts pay.
String planFeeText(VaultState v, FeeSchedule? fees) {
  if (fees == null) return 'Release fee on payouts';
  final rates = pendingFeeRates(v, fees);
  final skr =
      fees.skrBurnBps > 0 &&
      v.rules.any((r) => fees.isSkr(r.mint) && !r.executed);
  return 'Release fee: $rates'
      '${skr ? ' · SKR fees ${_pct(fees.skrBurnBps)} burned' : ''}';
}

/// "2% of each payout, 1.5% for SKR (10% of it burned), taken when it
/// runs." for a review screen; [noun] is "payout" or "release".
String releaseFeeTerms(FeeSchedule fees, String noun) {
  final base = fees.feeBpsPrivate == fees.feeBpsPublic
      ? '${_pct(fees.feeBpsPublic)} of each $noun'
      : '${_pct(fees.feeBpsPublic)} of each normal $noun, '
            '${_pct(fees.feeBpsPrivate)} of each private one';
  final burn = fees.skrBurnBps > 0
      ? ' (${_pct(fees.skrBurnBps)} of it burned)'
      : '';
  final skr = fees.skrMint == null
      ? ''
      : ', ${_pct(fees.feeBpsSkr)} for SKR$burn';
  return '$base$skr, taken when it runs.';
}
