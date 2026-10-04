import '../core/config.dart';
import '../solana/deadman_api.dart';

String planName(VaultState v) =>
    v.label.isEmpty ? 'Plan ${v.planId + 1}' : v.label;

String _plans(int n) => n == 1 ? '1 plan' : '$n plans';

String _names(List<VaultState> plans) => plans.map(planName).join(', ');

/// The amount part of a tier, enough to preview what it pays.
class TierAmount {
  const TierAmount({
    required this.mint,
    required this.mode,
    required this.amount,
    required this.afterSecs,
  });

  factory TierAmount.of(RuleSpec r) => TierAmount(
    mint: r.mint,
    mode: r.mode,
    amount: r.amount,
    afterSecs: r.afterSecs,
  );

  final String? mint;
  final AmountMode mode;

  /// Basis points for percent tiers, base units for fixed ones.
  final int amount;
  final int afterSecs;

  bool get takesAll => mode == AmountMode.percent && amount == 10000;
}

class TierShare {
  const TierShare(this.index, this.share);

  /// Position in the list given to [previewShares].
  final int index;

  /// Fraction of today's balance; null when it depends on an unknown
  /// balance (a fixed tier on an asset whose balance isn't known).
  final double? share;
}

/// What the tiers of one asset take from today's balance, in release order.
class AssetPreview {
  const AssetPreview({
    required this.mint,
    required this.tiers,
    required this.leftover,
    required this.lastTakesAll,
  });

  final String? mint;
  final List<TierShare> tiers;

  /// Fraction of today's balance still in the vault after the last tier;
  /// null when unknown.
  final double? leftover;

  /// The last tier is 100% of what remains, so nothing is stranded.
  final bool lastTakesAll;
}

/// The program applies a percent tier to what is left of that asset when
/// the tier executes, so percentages compound: 50% then 50% pays 50% and
/// 25% of today's balance and leaves 25% in the vault. Tiers of one asset
/// run in delay order. [balanceOf] gives today's balance in base units,
/// which turns fixed tiers into shares; null or 0 = unknown.
List<AssetPreview> previewShares(
  List<TierAmount?> tiers, {
  int? Function(String? mint)? balanceOf,
}) {
  final mints = <String?>[];
  for (final t in tiers) {
    if (t != null && !mints.contains(t.mint)) mints.add(t.mint);
  }
  return [
    for (final mint in mints) _previewAsset(tiers, mint, balanceOf?.call(mint)),
  ];
}

AssetPreview _previewAsset(List<TierAmount?> tiers, String? mint, int? bal) {
  final order = [
    for (final (i, t) in tiers.indexed)
      if (t != null && t.mint == mint) i,
  ]..sort((a, b) => tiers[a]!.afterSecs.compareTo(tiers[b]!.afterSecs));
  double? remaining = 1;
  final shares = <TierShare>[];
  for (final i in order) {
    final t = tiers[i]!;
    double? share;
    if (remaining != null) {
      if (t.mode == AmountMode.percent) {
        share = remaining * t.amount / 10000;
      } else if (bal != null && bal > 0) {
        final left = remaining * bal;
        share = (t.amount < left ? t.amount : left) / bal;
      }
    }
    shares.add(TierShare(i, share));
    remaining = share == null ? null : remaining! - share;
  }
  final last = tiers[order.last]!;
  return AssetPreview(
    mint: mint,
    tiers: shares,
    leftover: remaining == null ? null : (remaining < 1e-9 ? 0 : remaining),
    lastTakesAll: last.takesAll,
  );
}

/// "50%", "12.5%", "33.33%".
String percentText(double fraction) {
  final p = (fraction * 10000).round() / 100;
  final s = p.toStringAsFixed(2).replaceFirst(RegExp(r'\.?0+$'), '');
  return '$s%';
}

/// Tiers that already released or were skipped stay on-chain as history (a
/// skipped tier stays claimable); the editor only edits and resends the
/// pending ones. Once every tier has released, the program discards the
/// history and an edit starts a fresh plan.
({List<RuleState> history, List<RuleState> pending}) splitRules(VaultState v) =>
    v.completed
    ? (history: const [], pending: const [])
    : (
        history: [
          for (final r in v.rules)
            if (r.settled) r,
        ],
        pending: [
          for (final r in v.rules)
            if (!r.settled) r,
        ],
      );

/// Owner-chosen time a due tier gets to pay before anyone may skip it.
List<(int, String)> graceChoices({required bool demo}) => [
  if (demo) (120, '2 minutes'),
  (86400, '1 day'),
  (7 * 86400, '7 days'),
  (AppConfig.defaultSkipGraceSecs, '30 days'),
  (90 * 86400, '90 days'),
];

int clampGrace(int secs) => secs < AppConfig.minSkipGraceSecs
    ? AppConfig.minSkipGraceSecs
    : secs > AppConfig.maxSkipGraceSecs
    ? AppConfig.maxSkipGraceSecs
    : secs;

/// Inheritance plans: the ones "I'm alive" keeps from releasing. Vesting
/// plans release on their own schedule (lockdown still covers them).
List<VaultState> switchPlans(Iterable<VaultState> plans) => [
  for (final v in plans)
    if (!v.isVesting) v,
];

/// Inheritance plans with a tier still pending (skipped tiers only await
/// their claim): what check-ins, the pulse ring and reminders follow.
List<VaultState> activeSwitchPlans(Iterable<VaultState> plans) => [
  for (final v in plans)
    if (!v.isVesting && v.nextRuleDue != null) v,
];

/// Guard-key check-ins have stopped for this plan, or stop within
/// [AppConfig.guardWindowWarnSecs]: the owner's wallet must confirm.
bool needsWalletCheckIn(VaultState v, int now) =>
    !v.isVesting &&
    !v.completed &&
    (!v.guardCanPulse(now) ||
        now >= v.guardWindowEnd - AppConfig.guardWindowWarnSecs);

/// How each plan of an owner can be checked in from this device.
class PlanCoverage {
  const PlanCoverage({
    required this.guarded,
    required this.needsWallet,
    required this.otherGuard,
  });

  /// [guard] is this device's guard address (null when it has none).
  factory PlanCoverage.of(List<VaultState> plans, String? guard, int now) {
    final guarded = <VaultState>[];
    final wallet = <VaultState>[];
    final other = <VaultState>[];
    for (final v in plans) {
      // Vesting runs on its own clock: no check-ins.
      if (v.completed || v.isVesting) continue;
      if (guard == null || v.guard != guard) {
        other.add(v);
      } else if (!v.guardCanPulse(now)) {
        wallet.add(v);
      } else {
        guarded.add(v);
      }
    }
    return PlanCoverage(
      guarded: guarded,
      needsWallet: wallet,
      otherGuard: other,
    );
  }

  /// Active plans this device's guard key can check in now.
  final List<VaultState> guarded;

  /// Active plans whose guard check-ins have stopped.
  final List<VaultState> needsWallet;

  /// Active plans guarded by another key (or this phone has none).
  final List<VaultState> otherGuard;

  bool get isEmpty =>
      guarded.isEmpty && needsWallet.isEmpty && otherGuard.isEmpty;

  /// Outcome of an "I'm alive" that pulsed exactly [guarded].
  String reportText({required bool pulsed}) {
    final parts = <String>[
      if (pulsed && guarded.isNotEmpty)
        guarded.length == 1
            ? 'Pulse recorded on ${planName(guarded.single)}.'
            : 'Pulse recorded on ${_plans(guarded.length)}.'
      else
        'Nothing was checked in.',
      if (needsWallet.isNotEmpty)
        '${_plans(needsWallet.length)} ${needsWallet.length == 1 ? 'needs' : 'need'} '
            'a wallet check-in (${_names(needsWallet)}): tap Confirm with wallet.',
      if (otherGuard.isNotEmpty)
        '${_plans(otherGuard.length)} ${otherGuard.length == 1 ? 'is' : 'are'} '
            'guarded by another device (${_names(otherGuard)}): Move guard to this phone.',
    ];
    return parts.join(' ');
  }

  bool get complete => needsWallet.isEmpty && otherGuard.isEmpty;
}

/// Outcome of a guard-key lockdown.
class LockReport {
  const LockReport({required this.locked, required this.uncovered});

  final List<VaultState> locked;

  /// Plans this device's guard key cannot lock.
  final List<VaultState> uncovered;

  bool get complete => uncovered.isEmpty;

  String get text {
    final done = locked.length == 1
        ? 'Locked ${planName(locked.single)}.'
        : 'Locked ${_plans(locked.length)}.';
    if (complete) return done;
    return '$done NOT locked, guarded by another device: ${_names(uncovered)}. '
        'Move guard to this phone, then lock again.';
  }
}
