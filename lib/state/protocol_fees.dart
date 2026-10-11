import '../solana/deadman_api.dart';
import 'plan_math.dart';

/// The fee model in one line, for places that can't read the fee schedule
/// (the program's defaults). "In SKR": SKR payouts, and any payout whose
/// fee the plan's SKR fee reserve pays.
const feeSummaryStaticText =
    '2% on release · 1.5% in SKR (10% burned) · withdrawals free';

/// What [v] still has to pay out, per unsettled tier or schedule of
/// [mint], from [balance] (the vault's whole balance; its SKR fee reserve
/// pays no tier): (rule index, gross amount), in payout order.
List<(int, int)> pendingPayouts(VaultState v, String? mint, int balance) {
  var left = v.tierFunds(mint, balance);
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
  for (final (i, gross) in pendingPayouts(v, mint, balance)) {
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
/// [v]'s unsettled tiers pay (the SKR rate where its fee reserve pays).
String pendingFeeRates(VaultState v, FeeSchedule fees) =>
    plansPendingFeeRates([v], fees);

/// [pendingFeeRates] across all of [plans].
String plansPendingFeeRates(Iterable<VaultState> plans, FeeSchedule fees) {
  final bps = <int>{
    for (final v in plans)
      for (final (i, r) in v.rules.indexed)
        if (v.isVesting ? v.vestingCap(i) > r.released : !r.executed)
          v.paysFeeInSkr(fees, r.mint)
              ? fees.feeBpsSkr
              : fees.bpsFor(r.rail, r.mint),
  }.toList()..sort();
  if (bps.isEmpty) bps.add(fees.feeBpsPublic);
  return bps.map((b) => percentText(b / 10000)).join(' / ');
}

/// "2%", or "2% (3% private rails)" when the rails differ.
String _rates(FeeSchedule fees) => fees.feeBpsPrivate == fees.feeBpsPublic
    ? _pct(fees.feeBpsPublic)
    : '${_pct(fees.feeBpsPublic)} (${_pct(fees.feeBpsPrivate)} private rails)';

String _pct(int bps) => percentText(bps / 10000);

/// "1.5% in SKR (10% burned)", "1.5% in SKR", or null without an SKR rate.
String? skrFeeText(FeeSchedule fees) {
  if (fees.skrMint == null) return null;
  final burn = fees.skrBurnBps > 0 ? ' (${_pct(fees.skrBurnBps)} burned)' : '';
  return '${_pct(fees.feeBpsSkr)} in SKR$burn';
}

/// "2% on release · 1.5% in SKR (10% burned) · withdrawals free", from the
/// on-chain schedule ([feeSummaryStaticText] until it is read).
String feeSummaryText(FeeSchedule? fees) {
  if (fees == null) return feeSummaryStaticText;
  final skr = skrFeeText(fees);
  return ['${_rates(fees)} on release', ?skr, 'withdrawals free'].join(' · ');
}

/// "Release fee: 2%", "Release fee: 1.5% · SKR fees 10% burned", or with
/// an SKR fee reserve "Release fee: 1.5% · paid in SKR from the reserve ·
/// SKR fees 10% burned" for a plan card: the rates [v]'s unsettled
/// payouts pay.
String planFeeText(VaultState v, FeeSchedule? fees) {
  if (fees == null) return 'Release fee on payouts';
  final rates = pendingFeeRates(v, fees);
  final pending = [
    for (final (i, r) in v.rules.indexed)
      if (v.isVesting ? v.vestingCap(i) > r.released : !r.executed) r,
  ];
  final reserve = pending.any((r) => v.paysFeeInSkr(fees, r.mint));
  final skr =
      fees.skrBurnBps > 0 &&
      (reserve || pending.any((r) => fees.isSkr(r.mint)));
  return 'Release fee: $rates'
      '${reserve ? ' · paid in SKR from the reserve' : ''}'
      '${skr ? ' · SKR fees ${_pct(fees.skrBurnBps)} burned' : ''}';
}

/// "2% of each payout, taken when it runs. 1.5% when paid in SKR (10% of
/// it burned): SKR payouts pay it themselves, others from an SKR fee
/// reserve." for a review screen; [noun] is "payout" or "release".
String releaseFeeTerms(FeeSchedule fees, String noun) {
  final base = fees.feeBpsPrivate == fees.feeBpsPublic
      ? '${_pct(fees.feeBpsPublic)} of each $noun'
      : '${_pct(fees.feeBpsPublic)} of each normal $noun, '
            '${_pct(fees.feeBpsPrivate)} of each private one';
  if (fees.skrMint == null) return '$base, taken when it runs.';
  final burn = fees.skrBurnBps > 0
      ? ' (${_pct(fees.skrBurnBps)} of it burned)'
      : '';
  return '$base, taken when it runs. ${_pct(fees.feeBpsSkr)} when paid in '
      'SKR$burn: SKR ${noun}s pay it themselves, others from an SKR fee '
      'reserve.';
}

/// "Pay fees in $SKR (1.5% instead of 2%)": the plan editor's option.
String skrOptionTitle(FeeSchedule fees) =>
    'Pay fees in \$SKR (${_pct(fees.feeBpsSkr)} instead of '
    '${_pct(fees.feeBpsPublic)})';
