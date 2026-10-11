import 'dart:math' as math;

import '../solana/deadman_api.dart';
import 'assets.dart';
import 'plan_draft.dart' show moneyText;
import 'protocol_fees.dart';

/// Extra SKR a suggested reserve holds on top of today's estimate: prices
/// move before the payouts run.
const skrReserveBuffer = 1.3;

/// Whether a payout of [mint] (null = SOL) can pay its fee from an SKR fee
/// reserve: SKR payouts pay their own fee in SKR, and NFTs pay none.
bool skrReserveCovers(FeeSchedule fees, String? mint) =>
    fees.skrMint != null && !fees.isSkr(mint) && !isNft(mint);

/// USD worth of [amount] base units of [mint] at [usd] per whole unit;
/// null when the token's decimals are unknown.
double? usdValue(int amount, String? mint, double usd) {
  final info = knownAsset(mint);
  if (info == null || info.nft) return null;
  return amount / math.pow(10, info.decimals) * usd;
}

/// SKR base units worth [feeBps] of [usdAmount] at [skrUsd], rounded up
/// (the program rounds each fee up too).
int skrForUsd(double usdAmount, int feeBps, double skrUsd, int skrDecimals) =>
    (usdAmount * feeBps / 10000 / skrUsd * math.pow(10, skrDecimals)).ceil();

/// SKR (base units) to set aside so a plan holding [deposits] (mint ->
/// base units, null = SOL) can pay every release fee in SKR: the value of
/// what the reserve covers x the SKR rate / the SKR price x [buffer]. SKR
/// itself and NFTs are left out. Null when SKR or a counted asset has no
/// price in [usd]; 0 when nothing would be covered.
int? suggestedSkrReserve({
  required Map<String?, int> deposits,
  required Map<String?, double> usd,
  required FeeSchedule fees,
  double buffer = skrReserveBuffer,
}) {
  final skr = fees.skrMint;
  final skrUsd = usd[skr];
  if (skr == null || skrUsd == null || skrUsd <= 0) return null;
  var total = 0.0;
  for (final MapEntry(key: mint, value: amount) in deposits.entries) {
    if (amount <= 0 || !skrReserveCovers(fees, mint)) continue;
    final price = usd[mint];
    final value = price == null ? null : usdValue(amount, mint, price);
    if (value == null) return null;
    total += value;
  }
  if (total <= 0) return 0;
  return skrForUsd(
    total * buffer,
    fees.feeBpsSkr,
    skrUsd,
    knownAsset(skr)?.decimals ?? 0,
  );
}

/// SKR (base units) [v]'s remaining payouts would take from its fee
/// reserve at the prices in [usd], if they paid out what the plan holds
/// today ([tokens]: mint -> base units; SOL from the plan). Null when a
/// price or a balance is missing.
int? skrReserveNeed(
  VaultState v,
  Map<String, int>? tokens,
  FeeSchedule fees,
  Map<String?, double> usd,
) {
  final skr = fees.skrMint;
  final skrUsd = usd[skr];
  if (skr == null || skrUsd == null || skrUsd <= 0) return null;
  final decimals = knownAsset(skr)?.decimals ?? 0;
  var need = 0;
  for (final mint in {for (final r in v.rules) r.mint}) {
    if (!skrReserveCovers(fees, mint)) continue;
    final balance = mint == null ? v.withdrawableLamports : tokens?[mint];
    if (balance == null) return null;
    for (final (i, gross) in pendingPayouts(v, mint, balance)) {
      if (fees.feeOf(gross, v.rules[i].rail, mint) <= 0) continue;
      final price = usd[mint];
      final value = price == null ? null : usdValue(gross, mint, price);
      if (value == null) return null;
      need += skrForUsd(value, fees.feeBpsSkr, skrUsd, decimals);
    }
  }
  return need;
}

/// What the plan editor's SKR option sets aside: the [typed] amount of
/// [skrMint] (null when unreadable), else the [suggested] one.
int? chosenSkrReserve(String typed, int? suggested, String skrMint) {
  final t = typed.trim();
  return t.isEmpty ? suggested : parseAmount(t, skrMint);
}

/// Why [amount] of [skrMint] cannot go into a new plan's SKR fee reserve
/// from a wallet holding [wallet] (null = unknown) while [alsoSpent] of it
/// goes into the plan as a deposit; null when it can.
String? skrReserveError({
  required int? amount,
  required int? wallet,
  required String skrMint,
  int alsoSpent = 0,
}) {
  if (amount == null) return 'Check this amount';
  if (amount <= 0) {
    return 'Enter how much SKR to set aside, or turn this off.';
  }
  if (wallet != null && amount + alsoSpent > wallet) {
    return alsoSpent > 0
        ? 'Your wallet holds ${moneyText(wallet, skrMint)}, and '
              '${moneyText(alsoSpent, skrMint)} of it goes into the plan.'
        : 'Your wallet holds ${moneyText(wallet, skrMint)}.';
  }
  return null;
}

/// The assets whose prices size [v]'s SKR fee reserve: SKR and what the
/// reserve pays fees for.
Set<String?> reservePricedAssets(VaultState v, FeeSchedule fees) => {
  fees.skrMint,
  for (final r in v.rules)
    if (skrReserveCovers(fees, r.mint)) r.mint,
};
