import 'package:flutter/material.dart';

import '../solana/deadman_api.dart';
import '../state/assets.dart';
import '../state/plan_math.dart';
import 'format.dart';

extension RailUi on Rail {
  String get label => switch (this) {
    Rail.solana => 'Solana',
    Rail.cloak => 'Cloak',
    Rail.zcash => 'Zcash',
  };

  String get blurb => switch (this) {
    Rail.solana => 'Direct transfer to a Solana wallet',
    Rail.cloak => 'Shielded on Solana via Cloak',
    Rail.zcash => 'Delivered as shielded ZEC',
  };

  IconData get icon => switch (this) {
    Rail.solana => Icons.bolt,
    Rail.cloak => Icons.visibility_off_outlined,
    Rail.zcash => Icons.shield_moon_outlined,
  };
}

String assetName(String? mint) => assetSymbol(mint);

/// Percent tiers apply to what is left of the asset when the tier runs.
String amountLabel(RuleSpec r) => switch (r.mode) {
  AmountMode.percent =>
    '${percentText(r.amount / 10000)} of remaining ${assetName(r.mint)}',
  AmountMode.fixed => amountText(r.amount, r.mint),
};

/// History label for a tier that is no longer pending.
String doneLabel(RuleState r) =>
    r.executed ? 'Released' : 'Skipped (reserved, still claimable)';

/// The share set aside for a skipped tier.
String reservedText(RuleState r) =>
    r.reserved == 0 ? 'its share' : amountText(r.reserved, r.mint);

/// Status of a tier that was skipped but not yet claimed.
String skippedLabel(RuleState r) =>
    'Skipped: ${reservedText(r)} reserved, claimable by ${short(r.beneficiary)}';

/// Check-in cadence presets. Rules default to firing one grace period after
/// a missed check-in; "Demo" exists so the switch can fire on camera.
enum Cadence {
  demo('Demo', 120, 180, 300),
  week('7 days', 7 * 86400, 10 * 86400, 3 * 86400),
  month('30 days', 30 * 86400, 37 * 86400, 3 * 86400),
  quarter('90 days', 90 * 86400, 104 * 86400, 7 * 86400);

  const Cadence(this.label, this.interval, this.release, this.lock);

  final String label;
  final int interval;

  /// Default delay for a new rule.
  final int release;
  final int lock;

  static Cadence of(int interval) =>
      values.firstWhere((c) => c.interval == interval, orElse: () => week);
}
