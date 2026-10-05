import 'dart:convert';
import 'dart:math' as math;

import '../core/config.dart';
import '../solana/codec.dart' show Limits;
import '../solana/deadman_api.dart';
import 'assets.dart';
import 'plan_math.dart';
import 'vesting.dart';

// Delivery facts. Each constant copies a value that lives elsewhere.

/// Rent-exempt minimum of a 0-byte system account (a fresh wallet): the
/// keeper's `beneficiaryRentMin` (tool/keeper.dart) for an empty wallet.
const walletRentMinLamports = 890880;

/// Rent of one SPL token account (165 bytes, `tokenAccountSize` in
/// tool/keeper.dart).
const tokenAccountRentLamports = 2039280;

/// The keeper's default USDC price, lamports per USDC base unit
/// (`defaultUsdcLamportsPerUnit` in tool/keeper.dart).
const keeperUsdcLamportsPerUnit = 6.0;

/// What a 0-SOL beneficiary pays the paymaster for a token claim that opens
/// their token account: 0.50 USDC, account tier (docs/KORA.md).
const firstTokenClaimCost = 500000;

/// The same claim when the account exists: 0.02 USDC, basic tier.
const laterTokenClaimCost = 20000;

/// SOL a private rail needs to move a payout on (`minRoutableLamports` in
/// lib/state/private_rails.dart).
const privateMinRoutableLamports = {Rail.zcash: 2000000, Rail.cloak: 15000000};

/// SOL kept in the owner's wallet for network fees when they pay in SOL.
const solFeeReserveLamports = 20000000;

/// Mirrors the program's `split_fee` (floor): (net, fee).
(int, int) splitFee(int gross, int bps) {
  final fee =
      (BigInt.from(gross) *
              BigInt.from(bps) ~/
              BigInt.from(Limits.bpsDenominator))
          .toInt();
  return (gross - fee, fee);
}

/// Smallest gross payout of [mint] whose protocol fee pays the keeper for
/// opening the heir's token account; null when it never does (fee waived,
/// or no price for the token).
int? keeperAutoDeliverMin(String? mint, int feeBps) {
  if (feeBps <= 0 || mint == null || mint != AppConfig.usdcMint) return null;
  final minFee = (tokenAccountRentLamports / keeperUsdcLamportsPerUnit).ceil();
  return (minFee * Limits.bpsDenominator + feeBps - 1) ~/ feeBps;
}

/// What a beneficiary holds; null fields are unknown.
class DeliveryFacts {
  const DeliveryFacts({this.walletLamports, this.tokenUnits});

  static const unknown = DeliveryFacts();

  final int? walletLamports;

  /// The API can't tell a missing token account from an empty one, so 0
  /// counts as missing.
  final int? tokenUnits;

  bool get hasTokenAccount => (tokenUnits ?? 0) > 0;
}

// Formatting.

/// "7xKX…9fGh", kept on one line (a word joiner after the ellipsis).
String _short(String a) => a.length <= 10
    ? a
    : '${a.substring(0, 4)}…\u2060${a.substring(a.length - 4)}';

/// The name when set, else the short address, else "this person".
String whoText(String name, String address) => name.trim().isNotEmpty
    ? name.trim()
    : address.trim().isNotEmpty
    ? _short(address.trim())
    : 'this person';

/// An amount with at least 2 significant digits, so a payout never reads
/// "0.00": "0.0098 USDC", "0.00049 SOL", "98 USDC".
String moneyText(int base, String? mint) {
  final info = knownAsset(mint);
  if (info == null) return amountText(base, mint);
  final digits = base <= 0
      ? info.displayDigits
      : math.max(
          info.displayDigits,
          math.min(info.decimals, info.decimals - '$base'.length + 2),
        );
  return '${formatUnits(base, info.decimals, digits: digits)} ${info.symbol}';
}

String _plural(int n, String unit) => '$n $unit${n == 1 ? '' : 's'}';

/// "10 days", "3 minutes", "36 hours".
String delayText(int secs) {
  if (secs >= 86400 && secs % 86400 == 0) return _plural(secs ~/ 86400, 'day');
  if (secs >= 3600 && secs % 3600 == 0) return _plural(secs ~/ 3600, 'hour');
  if (secs >= 60 && secs % 60 == 0) return _plural(secs ~/ 60, 'minute');
  return _plural(secs, 'second');
}

/// Basis points as the share field shows them: "100", "12.5", "0.01".
String shareInput(int bps) => formatUnits(bps, 2);

/// A typed share (0.01 to 100, at most 2 decimals) in basis points.
int? parseShareBps(String text) {
  final v = parseUnits(text, 2);
  return v == null || v < 1 || v > Limits.bpsDenominator ? null : v;
}

/// The words line under the share field; null when [bps] is invalid.
String? shareWords(int? bps, String asset) => switch (bps) {
  null => null,
  10000 => "Everything that's left",
  7500 => "Three quarters of what's left",
  5000 => "Half of what's left",
  2500 => "A quarter of what's left",
  1000 => "A tenth of what's left",
  _ => '${shareInput(bps)} out of every 100 $asset left',
};

/// Delay presets per check-in interval; the first is the default.
List<int> delayChoices(int intervalSecs) {
  const d = 86400;
  final all = switch (intervalSecs) {
    120 => const [180, 300, 600, 1800],
    604800 => const [10 * d, 14 * d, 30 * d, 90 * d],
    2592000 => const [37 * d, 45 * d, 60 * d, 180 * d],
    7776000 => const [104 * d, 120 * d, 180 * d, 365 * d],
    _ => [intervalSecs + 3 * d, intervalSecs * 2, intervalSecs * 4],
  };
  return [
    for (final s in all)
      if (s >= intervalSecs + Limits.minRuleMarginSecs) s,
  ];
}

/// Duress-lock presets.
List<int> lockChoices({required bool demo}) => [
  if (demo) 300,
  86400,
  3 * 86400,
  7 * 86400,
  30 * 86400,
];

// Drafts.

/// One payout of an inheritance plan as the editor holds it. Each amount
/// mode keeps its own value, so switching modes never reinterprets one.
class PayoutDraft {
  const PayoutDraft({
    required this.beneficiary,
    this.rail = Rail.solana,
    this.mint,
    this.mode = AmountMode.percent,
    this.shareBps = Limits.bpsDenominator,
    this.fixedAmount,
    required this.afterSecs,
    this.name = '',
  });

  factory PayoutDraft.fromRule(RuleSpec r, {String name = ''}) => PayoutDraft(
    beneficiary: r.beneficiary,
    rail: r.rail,
    mint: r.mint,
    mode: r.mode,
    shareBps: r.mode == AmountMode.percent ? r.amount : null,
    fixedAmount: r.mode == AmountMode.fixed ? r.amount : null,
    afterSecs: r.afterSecs,
    name: name,
  );

  final String beneficiary;
  final Rail rail;
  final String? mint;
  final AmountMode mode;

  /// Null when the typed share is invalid.
  final int? shareBps;

  /// Base units; null when empty or invalid.
  final int? fixedAmount;
  final int afterSecs;

  /// Saved on this phone only.
  final String name;

  /// Basis points or base units, per [mode].
  int? get amount => mode == AmountMode.percent ? shareBps : fixedAmount;

  bool get takesAll =>
      mode == AmountMode.percent && shareBps == Limits.bpsDenominator;

  String get who => whoText(name, beneficiary);

  PayoutDraft copyWith({
    String? name,
    int? afterSecs,
    AmountMode? mode,
    int? shareBps,
  }) => PayoutDraft(
    beneficiary: beneficiary,
    rail: rail,
    mint: mint,
    mode: mode ?? this.mode,
    shareBps: shareBps ?? this.shareBps,
    fixedAmount: fixedAmount,
    afterSecs: afterSecs ?? this.afterSecs,
    name: name ?? this.name,
  );

  /// Share of everything left of this asset.
  PayoutDraft takeAll() =>
      copyWith(mode: AmountMode.percent, shareBps: Limits.bpsDenominator);

  RuleSpec toRuleSpec() => RuleSpec(
    beneficiary: beneficiary.trim(),
    rail: rail,
    afterSecs: afterSecs,
    mint: mint,
    mode: mode,
    amount: amount!,
  );

  /// Problems that block Done (A2-A4, B2, D1).
  List<PlanIssue> validate({required int intervalSecs}) => [
    if (!isAddress(beneficiary)) _b2,
    ...amountErrors(
      mode: mode,
      shareBps: shareBps,
      fixedAmount: fixedAmount,
      mint: mint,
    ),
    ?delayError(afterSecs, intervalSecs),
  ];
}

/// One vesting schedule as the editor holds it.
class ScheduleDraft {
  const ScheduleDraft({
    required this.beneficiary,
    this.rail = Rail.solana,
    this.mint = AppConfig.usdcMint,
    required this.total,
    this.cliffSecs = 0,
    this.durationSecs = 12 * monthSecs,
    this.name = '',
  });

  final String beneficiary;
  final Rail rail;
  final String? mint;
  final int total;
  final int cliffSecs;
  final int durationSecs;
  final String name;

  String get who => whoText(name, beneficiary);

  /// What unlocks at once when the cliff ends.
  int get atCliff => durationSecs <= 0
      ? 0
      : (BigInt.from(total) *
                BigInt.from(cliffSecs) ~/
                BigInt.from(durationSecs))
            .toInt();

  /// Its installments when the plan releases every [periodSecs]; null when
  /// continuous.
  Installments? installments({required int periodSecs, required int startAt}) =>
      installmentsOf(
        total: total,
        cliffSecs: cliffSecs,
        durationSecs: durationSecs,
        periodSecs: periodSecs,
        startAt: startAt,
      );

  VestingSpec toSpec() => VestingSpec(
    beneficiary: beneficiary.trim(),
    rail: rail,
    mint: mint,
    total: total,
    cliffSecs: cliffSecs,
    durationSecs: durationSecs,
  );

  ScheduleDraft withDuration(int secs) => ScheduleDraft(
    beneficiary: beneficiary,
    rail: rail,
    mint: mint,
    total: total,
    cliffSecs: cliffSecs > secs ? 0 : cliffSecs,
    durationSecs: secs,
    name: name,
  );

  ScheduleDraft withCliff(int secs) => ScheduleDraft(
    beneficiary: beneficiary,
    rail: rail,
    mint: mint,
    total: total,
    cliffSecs: secs,
    durationSecs: durationSecs,
    name: name,
  );
}

// Issues.

/// Ordered most to least blocking.
enum Severity {
  /// Blocks Next or Done; shown on the field.
  error,

  /// May never arrive: needs the Review checkbox.
  danger,
  warn,
  info,
}

enum IssueCode {
  a1,
  a2,
  a3,
  a4,
  b1,
  b2,
  d1,
  d2,
  d3,
  d4,
  d5,
  d6,
  f1,
  f2,
  f3,
  f4,
  f5,
  f6,
  l1,
  p1,
  p2,
  n1,
  v1,
}

class PlanIssue {
  const PlanIssue(
    this.code,
    this.severity, {
    this.title = '',
    required this.body,
    this.action,
    this.mint,
  });

  final IssueCode code;
  final Severity severity;
  final String title;
  final String body;

  /// Label of the one-tap fix, when there is one.
  final String? action;

  /// The asset an asset-level issue is about.
  final String? mint;

  /// Short text for a card: the title, or the body for field errors.
  String get headline => title.isEmpty ? body : title;
}

List<PlanIssue> bySeverity(Iterable<PlanIssue> issues) =>
    issues.toList()..sort((a, b) => a.severity.index - b.severity.index);

PlanIssue? worstOf(Iterable<PlanIssue> issues) {
  final sorted = bySeverity(issues);
  return sorted.isEmpty ? null : sorted.first;
}

const _b2 = PlanIssue(
  IssueCode.b2,
  Severity.error,
  body: "This isn't a valid Solana address or claim code.",
);

const p1 = PlanIssue(
  IssueCode.p1,
  Severity.error,
  body: 'Add at least one payout.',
);

const p2 = PlanIssue(
  IssueCode.p2,
  Severity.error,
  body: 'A plan holds up to 8 payouts, paid ones included.',
);

const n1 = PlanIssue(
  IssueCode.n1,
  Severity.error,
  body: 'Plan name must be 32 characters or fewer.',
);

PlanIssue? labelError(String label) =>
    utf8.encode(label.trim()).length > Limits.maxLabelBytes ? n1 : null;

PlanIssue? addressError(String address) => isAddress(address) ? null : _b2;

/// A3 (share), A4 or A2 (fixed).
List<PlanIssue> amountErrors({
  required AmountMode mode,
  required int? shareBps,
  required int? fixedAmount,
  required String? mint,
}) {
  if (mode == AmountMode.percent) {
    return [
      if (shareBps == null)
        const PlanIssue(
          IssueCode.a3,
          Severity.error,
          body: 'Enter a share from 0.01 to 100.',
        ),
    ];
  }
  if (fixedAmount == null || fixedAmount <= 0) {
    return [
      PlanIssue(
        IssueCode.a4,
        Severity.error,
        body: 'Enter an amount in ${unitLabel(mint)}.',
      ),
    ];
  }
  if (mint == null && fixedAmount < 1000000) {
    return const [
      PlanIssue(
        IssueCode.a2,
        Severity.error,
        body: 'Fixed SOL payouts must be at least 0.001 SOL.',
      ),
    ];
  }
  return const [];
}

/// D1: the delay must outlast the check-in interval.
PlanIssue? delayError(int afterSecs, int intervalSecs) {
  if (afterSecs > Limits.maxRuleDelaySecs) {
    return const PlanIssue(
      IssueCode.d1,
      Severity.error,
      body: 'Must be 3 years or less.',
    );
  }
  if (afterSecs < intervalSecs + Limits.minRuleMarginSecs) {
    return PlanIssue(
      IssueCode.d1,
      Severity.error,
      body:
          'Must be longer than your check-in interval '
          '(${delayText(intervalSecs)}).',
      action: 'Move to ${delayText(delayChoices(intervalSecs).first)}',
    );
  }
  return null;
}

// Previews.

/// What one payout sends, when the balance it pays from is known.
class PayoutAmount {
  const PayoutAmount({this.gross, this.net, this.fee});

  final int? gross;
  final int? net;
  final int? fee;
}

/// The payouts of one asset, in the order they run.
class AssetSummary {
  const AssetSummary({
    required this.mint,
    required this.order,
    required this.balance,
    required this.leftover,
    required this.fixedSum,
    required this.hasShares,
    required this.feeTotal,
    required this.lastTakesAll,
  });

  final String? mint;

  /// Payout indices in delay order.
  final List<int> order;

  /// What the plan holds (or would hold) of this asset; null = unknown.
  final int? balance;

  /// Left in the plan after the last payout; null = unknown.
  final int? leftover;
  final int fixedSum;
  final bool hasShares;

  /// Protocol fee if every payout runs; null = unknown.
  final int? feeTotal;
  final bool lastTakesAll;

  int get last => order.last;
}

/// What every payout of a plan sends. Payouts of one asset run in delay
/// order; a share is taken from what is left of that asset at that point
/// (mirrors the program's `payout_gross`).
class PlanPreview {
  const PlanPreview._(this.amounts, this.assets);

  /// [balanceOf] is what the plan holds of each asset (null = unknown);
  /// [feeBps] the release fee per rail (0 when waived).
  factory PlanPreview.of(
    List<PayoutDraft> payouts, {
    required int? Function(String? mint) balanceOf,
    required int Function(Rail rail) feeBps,
  }) {
    final amounts = List<PayoutAmount>.filled(
      payouts.length,
      const PayoutAmount(),
    );
    final assets = <AssetSummary>[];
    for (final mint in assetOrder(payouts.map((p) => p.mint))) {
      final order = [
        for (final (i, p) in payouts.indexed)
          if (p.mint == mint) i,
      ];
      sortByDelay(order, payouts);
      final balance = balanceOf(mint);
      int? remaining = balance;
      int? feeTotal = 0;
      var fixedSum = 0;
      var hasShares = false;
      for (final i in order) {
        final p = payouts[i];
        if (p.mode == AmountMode.fixed) {
          fixedSum += p.fixedAmount ?? 0;
        } else {
          hasShares = true;
        }
        final amount = p.amount;
        if (remaining == null || amount == null) {
          remaining = null;
          feeTotal = null;
          continue;
        }
        final gross = p.mode == AmountMode.percent
            ? (BigInt.from(remaining) *
                      BigInt.from(amount) ~/
                      BigInt.from(Limits.bpsDenominator))
                  .toInt()
            : math.min(amount, remaining);
        final (net, fee) = splitFee(gross, feeBps(p.rail));
        amounts[i] = PayoutAmount(gross: gross, net: net, fee: fee);
        remaining -= gross;
        feeTotal = feeTotal == null ? null : feeTotal + fee;
      }
      assets.add(
        AssetSummary(
          mint: mint,
          order: order,
          balance: balance,
          leftover: remaining,
          fixedSum: fixedSum,
          hasShares: hasShares,
          feeTotal: feeTotal,
          lastTakesAll: payouts[order.last].takesAll,
        ),
      );
    }
    return PlanPreview._(amounts, assets);
  }

  final List<PayoutAmount> amounts;
  final List<AssetSummary> assets;

  AssetSummary assetOf(String? mint) =>
      assets.firstWhere((a) => a.mint == mint);

  /// The payout runs last for its asset.
  bool isLast(int index, String? mint) => assetOf(mint).last == index;
}

/// Sorts payout indices by delay, keeping list order on ties.
void sortByDelay(List<int> order, List<PayoutDraft> payouts) =>
    order.sort((a, b) {
      final c = payouts[a].afterSecs.compareTo(payouts[b].afterSecs);
      return c != 0 ? c : a.compareTo(b);
    });

/// [payouts] in the order they run (by delay, list order on ties).
List<PayoutDraft> sortedByDelay(List<PayoutDraft> payouts) {
  final order = [for (var i = 0; i < payouts.length; i++) i];
  sortByDelay(order, payouts);
  return [for (final i in order) payouts[i]];
}

/// SOL first, then USDC, then other tokens in first-use order.
List<String?> assetOrder(Iterable<String?> mints) {
  final seen = <String?>[];
  for (final m in mints) {
    if (!seen.contains(m)) seen.add(m);
  }
  int rank(String? m) => m == null
      ? 0
      : m == AppConfig.usdcMint
      ? 1
      : 2;
  final out = [...seen];
  out.sort((a, b) {
    final r = rank(a) - rank(b);
    return r != 0 ? r : seen.indexOf(a) - seen.indexOf(b);
  });
  return out;
}

// Fees.

/// The release fee as the editor knows it.
class FeeInfo {
  const FeeInfo({this.fees, this.waived = false, this.failed = false});

  final FeeSchedule? fees;

  /// The owner's monthly plan covers payouts saved now.
  final bool waived;

  /// The fee schedule couldn't be loaded.
  final bool failed;

  bool get known => waived || fees != null;

  int bpsFor(Rail rail) => waived ? 0 : fees?.bpsFor(rail) ?? 0;

  /// "2% fee", "No fee: monthly plan active", "fee loading…".
  String railLine(Rail rail) => waived
      ? 'No fee: monthly plan active'
      : fees == null
      ? (failed ? 'Fee unknown' : 'fee loading…')
      : '${percentText(fees!.bpsFor(rail) / 10000)} fee';

  /// "(after the 2% fee)", "(no fee)", "(before fees)".
  String note(Rail rail) => waived
      ? '(no fee)'
      : fees == null
      ? '(before fees)'
      : '(after the ${percentText(fees!.bpsFor(rail) / 10000)} fee)';
}

/// SOL to leave in the owner's wallet: network fees, plus funding this
/// phone's check-in key when no sponsor pays for it. 0 when fees are paid
/// in USDC.
int feeReserveLamports({required bool solFeeMode, required bool sponsored}) =>
    !solFeeMode
    ? 0
    : solFeeReserveLamports + (sponsored ? 0 : AppConfig.guardFundingLamports);

/// SOL private-rail token payouts carry to their claim key
/// (`Rail::gas_stipend`).
int stipendNeed(Iterable<PayoutDraft> payouts) => payouts
    .where((p) => p.mint != null)
    .fold(0, (sum, p) => sum + Limits.gasStipend(p.rail));

/// The deposit a Fund field starts with: the fixed payouts (capped at the
/// wallet, less [reserve] for SOL) plus [stipend]; null (empty) for
/// share-only assets.
int? defaultDeposit({
  required int fixedSum,
  required int stipend,
  int? wallet,
  int reserve = 0,
}) {
  final want = fixedSum + stipend;
  if (want <= 0) return null;
  if (wallet == null) return want;
  final cap = math.max(0, wallet - reserve);
  return math.min(want, cap);
}

// Warnings.

/// D2-D6 for one payout of [gross] (before the fee).
List<PlanIssue> deliveryIssues({
  required PayoutDraft p,
  required int? gross,
  required int feeBps,
  required DeliveryFacts? facts,
}) {
  final who = p.who;
  final asset = assetSymbol(p.mint);
  final private = p.rail != Rail.solana;
  final out = <PlanIssue>[];
  if (gross != null && gross > 0) {
    final (net, _) = splitFee(gross, feeBps);
    final netText = moneyText(net, p.mint);
    if (p.mint != null) {
      if (facts != null && !facts.hasTokenAccount) {
        final autoMin = keeperAutoDeliverMin(p.mint, feeBps);
        if (p.mint == AppConfig.usdcMint && net < firstTokenClaimCost) {
          out.add(
            PlanIssue(
              IssueCode.d2,
              Severity.danger,
              title: 'Too small to arrive',
              body:
                  '$who would get ≈ $netText. Sending $asset to a wallet that has '
                  'never held $asset costs more than that (about 0.50 USDC the '
                  "first time), so it would never arrive. If $who already holds "
                  "$asset, it's fine.",
              action: p.mode == AmountMode.percent && !p.takesAll
                  ? 'Use 100%'
                  : 'Raise the amount',
            ),
          );
        } else if (autoMin == null || gross < autoMin) {
          out.add(
            PlanIssue(
              IssueCode.d3,
              Severity.warn,
              title: '$who will need to claim it',
              body:
                  '${autoMin == null ? 'Payouts' : 'Payouts under about ${_wholeUp(autoMin, p.mint)}'} '
                  "to a wallet new to $asset aren't sent automatically. $who "
                  'claims it in the Deadman app (Family Circle → Claim); with no '
                  'SOL, the first claim costs about 0.50 USDC, taken from the '
                  'payout.',
            ),
          );
        }
      }
    } else {
      if (facts != null &&
          (facts.walletLamports ?? 0) + net < walletRentMinLamports) {
        out.add(
          PlanIssue(
            IssueCode.d4,
            Severity.danger,
            title: 'Too small to arrive',
            body:
                'A Solana wallet must hold at least 0.00089 SOL to exist. '
                "$who's wallet is empty, so ≈ $netText can't be sent there.",
            action: 'Raise the amount',
          ),
        );
      }
      final min = privateMinRoutableLamports[p.rail];
      if (private && min != null && net < min) {
        out.add(
          PlanIssue(
            IssueCode.d5,
            Severity.warn,
            title: 'Too small to move privately',
            body:
                'Private delivery needs at least ${moneyText(min, null)} to '
                "move it on. A smaller amount stays on $who's claim key.",
          ),
        );
      }
    }
  }
  if (private && p.mint != null) {
    out.add(
      PlanIssue(
        IssueCode.d6,
        Severity.warn,
        title: "Private $asset isn't routed yet",
        body:
            '$who receives the $asset on their private claim key, but the app '
            "can't move private $asset onward yet (it can for SOL). Deadman "
            'also sends ${moneyText(Limits.gasStipend(p.rail), null)} with it so '
            'they can, when it\'s ready; keep that much SOL in the plan.',
      ),
    );
  }
  return out;
}

String _wholeUp(int base, String? mint) {
  final decimals = knownAsset(mint)?.decimals ?? 0;
  final unit = BigInt.from(10).pow(decimals).toInt();
  return amountText((base + unit - 1) ~/ unit * unit, mint);
}

/// Warnings for payout [index] of [payouts]: A1, B1 and D2-D6.
List<PlanIssue> payoutWarnings({
  required List<PayoutDraft> payouts,
  required int index,
  required PlanPreview preview,
  required FeeInfo fee,
  required DeliveryFacts? facts,
  String? owner,
}) {
  final p = payouts[index];
  final asset = assetSymbol(p.mint);
  final bps = p.shareBps;
  return bySeverity([
    if (p.mode == AmountMode.percent &&
        bps != null &&
        bps <= 500 &&
        preview.isLast(index, p.mint))
      PlanIssue(
        IssueCode.a1,
        Severity.warn,
        title: 'Did you mean 100%?',
        body:
            'Only ${shareInput(bps)}% of your $asset goes to ${p.who}. The other '
            "${shareInput(Limits.bpsDenominator - bps)}% stays locked in the plan "
            "after you're gone.",
        action: 'Use 100%',
      ),
    if (owner != null && p.beneficiary.trim() == owner)
      // The program rejects the owner as a beneficiary, so this blocks.
      const PlanIssue(
        IssueCode.b1,
        Severity.error,
        title: "That's your own wallet",
        body:
            "A plan can't pay its owner. Use the address of the person who "
            'should receive it.',
      ),
    ...deliveryIssues(
      p: p,
      gross: preview.amounts[index].gross,
      feeBps: fee.bpsFor(p.rail),
      facts: facts,
    ),
  ]);
}

/// "payout 2", "payouts 1 and 3", "payouts 1, 2 and 4".
String payoutNumbers(List<int> numbers) {
  if (numbers.length == 1) return 'payout ${numbers.single}';
  final head = numbers.sublist(0, numbers.length - 1).join(', ');
  return 'payouts $head and ${numbers.last}';
}

/// Fund-level warnings for one asset (F1, F2, F4, F5, F6, L1).
///
/// [balance] is the deposit (create) or what the plan holds (edit); null =
/// unknown or unparseable. [numberOf] maps a payout index to its display
/// number. SOL-only inputs: [wallet], [reserve], [stipend].
List<PlanIssue> assetIssues({
  required AssetSummary? asset,
  required String? mint,
  required List<PayoutDraft> payouts,
  required bool creating,
  required int? balance,
  required int Function(int index) numberOf,
  int? wallet,
  int reserve = 0,
  bool sponsored = true,
  int stipend = 0,
}) {
  final symbol = assetSymbol(mint);
  final out = <PlanIssue>[];
  if (creating && balance != null && wallet != null && balance > wallet) {
    out.add(
      PlanIssue(
        IssueCode.f1,
        Severity.error,
        body: 'Your wallet has only ${moneyText(wallet, mint)}.',
        action: 'Use all',
        mint: mint,
      ),
    );
  }
  if (asset != null) {
    if (balance == 0) {
      final ns = payoutNumbers([for (final i in asset.order) numberOf(i)]);
      out.add(
        PlanIssue(
          IssueCode.f2,
          Severity.danger,
          title: 'Nothing to pay out',
          body: creating
              ? 'The plan will hold no $symbol, so $ns '
                    '${asset.order.length == 1 ? 'has' : 'have'} nothing to send '
                    'until you deposit some from the plan card.'
              : 'This plan holds no $symbol, so $ns '
                    '${asset.order.length == 1 ? 'has' : 'have'} nothing to send '
                    'until you deposit some from the plan card.',
          action: creating ? 'Add $symbol' : null,
          mint: mint,
        ),
      );
    } else if (balance != null && asset.fixedSum > balance) {
      out.add(
        PlanIssue(
          IssueCode.f4,
          Severity.warn,
          title: 'Not enough for every payout',
          body:
              'Fixed payouts add up to ${moneyText(asset.fixedSum, mint)}, but the '
              'plan will hold ${moneyText(balance, mint)}. Later payouts get '
              'less, or nothing.',
          action: creating ? 'Put in ${moneyText(asset.fixedSum, mint)}' : null,
          mint: mint,
        ),
      );
    }
    // With nothing in the plan, F2 says it better.
    if (!asset.lastTakesAll && balance != 0) {
      out.add(
        PlanIssue(
          IssueCode.l1,
          Severity.warn,
          title: 'Some money stays behind',
          body: leftoverSentence(asset),
          action: 'Make the last payout "Everything left"',
          mint: mint,
        ),
      );
    }
  }
  if (mint == null && creating && balance != null) {
    if (reserve > 0 &&
        wallet != null &&
        balance <= wallet &&
        balance > wallet - reserve) {
      out.add(
        PlanIssue(
          IssueCode.f5,
          Severity.warn,
          title: 'Keep some SOL for fees',
          body:
              'Leave about ${moneyText(reserve, null)} in your wallet to pay '
              "network fees${sponsored ? '' : " and fund this phone's check-ins"}.",
          action: 'Use ${moneyText(math.max(0, wallet - reserve), null)}',
          mint: mint,
        ),
      );
    }
    if (stipend > 0 && balance < stipend) {
      final first = payouts.firstWhere(
        (p) => p.mint != null && p.rail != Rail.solana,
      );
      out.add(
        PlanIssue(
          IssueCode.f6,
          Severity.warn,
          title: 'Add SOL for private delivery',
          body:
              'Private ${assetSymbol(first.mint)} payouts carry '
              '${moneyText(Limits.gasStipend(first.rail), null)} so ${first.who} '
              'can move them. Put at least ${moneyText(stipend, null)} in the plan.',
          action: 'Put in ${moneyText(stipend, null)}',
          mint: mint,
        ),
      );
    }
  }
  return bySeverity(out);
}

/// F3: an edit whose plan holds none of an asset its payouts use.
PlanIssue f3(String? mint) => PlanIssue(
  IssueCode.f3,
  Severity.info,
  body:
      'This plan holds no ${assetSymbol(mint)} yet. After saving, use Deposit '
      'on the plan card to add ${assetSymbol(mint)}.',
  mint: mint,
);

/// V1: a vesting deposit below the schedule totals.
PlanIssue? vestingShortfall(String? mint, int totals, int deposit) =>
    deposit >= totals
    ? null
    : PlanIssue(
        IssueCode.v1,
        Severity.warn,
        title: 'Not fully funded',
        body:
            'The deposit is ${moneyText(totals - deposit, mint)} short. '
            'Unlocking pauses when the plan runs dry, until you deposit more.',
        action: 'Put in ${moneyText(totals, mint)}',
        mint: mint,
      );

// Sentences.

/// "Everything left of your USDC", "25% of what's left", "10 USDC".
String payoutAmountLabel(PayoutDraft p) {
  final asset = assetSymbol(p.mint);
  if (p.mode == AmountMode.fixed) {
    return p.fixedAmount == null
        ? 'An amount of $asset'
        : moneyText(p.fixedAmount!, p.mint);
  }
  final bps = p.shareBps;
  if (bps == null) return 'A share of your $asset';
  if (bps == Limits.bpsDenominator) return 'Everything left of your $asset';
  return "${shareInput(bps)}% of what's left of your $asset";
}

/// "After 10 days of silence (3 days after a missed check-in)".
String payoutWhen(int afterSecs, int intervalSecs) =>
    'After ${delayText(afterSecs)} of silence'
    '${intervalSecs < afterSecs ? ' (${delayText(afterSecs - intervalSecs)} after a missed check-in)' : ''}';

String _how(PayoutDraft p) => switch (p.rail) {
  // Without a name, the sentence already starts with the address.
  Rail.solana when p.name.trim().isEmpty => 'as a normal transfer',
  Rail.solana => 'as a normal transfer to ${_short(p.beneficiary.trim())}',
  Rail.cloak => 'privately through Cloak, using their claim code',
  Rail.zcash => 'privately as Zcash, using their claim code',
};

/// "Ana gets everything left of your USDC (≈ 0.98 USDC) as a normal
/// transfer to 7xKX…9fGh." [capped]: a fixed amount the plan can't cover.
String payoutSentence(PayoutDraft p, {int? net, bool capped = false}) {
  final asset = assetSymbol(p.mint);
  final what = p.mode == AmountMode.fixed
      ? '${p.who} gets ${moneyText(p.fixedAmount ?? 0, p.mint)}'
      : p.takesAll
      ? '${p.who} gets everything left of your $asset'
      : '${p.who} gets ${shareInput(p.shareBps ?? 0)}% of the $asset left at that point';
  final approx = net == null
      ? ''
      : capped
      ? ' (only ≈\u00a0${moneyText(net, p.mint)} will be left for it)'
      : ' (≈\u00a0${moneyText(net, p.mint)})';
  return '$what$approx ${_how(p)}.';
}

/// What stays in the plan after the last payout of [a].
String leftoverSentence(AssetSummary a) {
  final asset = assetSymbol(a.mint);
  if (a.lastTakesAll) return 'Nothing of your $asset is left behind.';
  const gone = "Nobody can withdraw it once you're gone.";
  final left = a.leftover;
  final balance = a.balance;
  if (left == null) {
    return 'Part of your $asset stays locked in the plan after the last '
        'payout. $gone';
  }
  if (left == 0) {
    return 'Nothing is left over today, but the last $asset payout isn\'t '
        '"Everything left", so anything you add later stays locked in the '
        'plan. $gone';
  }
  final pct = balance == null || balance == 0
      ? ''
      : ' (${percentText(left / balance)} of what the plan holds)';
  return '${moneyText(left, a.mint)}$pct stays locked in the plan after the '
      'last payout. $gone';
}

/// "12 installments of 100 USDC every month, first on Nov 3, 2026"; after
/// a cliff, "…, the first 3 together on Jan 3, 2027". Null when [periodSecs]
/// is 0 (continuous) or does not fit the schedule.
String? installmentsText(
  ScheduleDraft s, {
  required int periodSecs,
  required int startAt,
  required String Function(int secs) date,
}) {
  final n = s.installments(periodSecs: periodSecs, startAt: startAt);
  if (n == null) return null;
  final every = vestPeriodWord(periodSecs);
  final amount = moneyText(n.amount, s.mint);
  final head = n.count == 1
      ? '1 installment of ${moneyText(s.total, s.mint)}'
      : '${n.count} installments of ${n.even ? '' : 'about '}$amount '
            'every $every${n.lastSmaller ? ' (the last one smaller)' : ''}';
  final first = n.firstCount > 1
      ? 'the first ${n.firstCount} together '
            '(${moneyText(n.firstAmount, s.mint)}) on ${date(n.firstAt)}'
      : '${n.count == 1 ? 'on' : 'first on'} ${date(n.firstAt)}';
  return '$head, $first';
}

/// Why [periodSecs] does not fit [schedules], or null. The program needs
/// every schedule to last at least one installment.
String? vestPeriodError(
  int periodSecs,
  List<ScheduleDraft> schedules, {
  required String Function(int secs) duration,
}) {
  if (periodSecs == 0) return null;
  if (periodSecs < minVestPeriodSecs) {
    return 'Installments can be at most once a minute.';
  }
  for (final (i, s) in schedules.indexed) {
    if (s.durationSecs < periodSecs) {
      return 'Schedule ${i + 1} is fully unlocked after '
          '${duration(s.durationSecs)}, before its first installment '
          '(one every ${vestPeriodWord(periodSecs)}). Release more often, or give '
          'it a longer duration.';
    }
  }
  return null;
}

/// "Starting today, Ana receives 1200 USDC over 12 months in 12
/// installments of 100 USDC every month, first on Nov 3, 2026, as a normal
/// transfer." With [periodSecs] 0 it unlocks gradually.
String vestingSentence(
  ScheduleDraft s, {
  required String start,
  required String Function(int secs) duration,
  int periodSecs = 0,
  int startAt = 0,
  String Function(int secs)? date,
}) {
  final total = moneyText(s.total, s.mint);
  final how = switch (s.rail) {
    Rail.solana => 'as a normal transfer',
    Rail.cloak => 'privately through Cloak, using their claim code',
    Rail.zcash => 'privately as Zcash, using their claim code',
  };
  final parts = date == null
      ? null
      : installmentsText(
          s,
          periodSecs: periodSecs,
          startAt: startAt,
          date: date,
        );
  if (parts != null) {
    final cliff = s.cliffSecs == 0
        ? ''
        : ' Nothing unlocks for the first ${duration(s.cliffSecs)}.';
    return 'Starting $start, ${s.who} receives $total over '
        '${duration(s.durationSecs)} in $parts, $how.$cliff';
  }
  final cliff = s.cliffSecs == 0
      ? ''
      : ': nothing for the first ${duration(s.cliffSecs)}, then '
            '${moneyText(s.atCliff, s.mint)} at once, then the rest evenly';
  return 'Starting $start, ${s.who} receives $total gradually over '
      '${duration(s.durationSecs)}$cliff, $how.';
}
