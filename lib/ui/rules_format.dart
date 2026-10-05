import 'package:flutter/material.dart';

import '../solana/deadman_api.dart';
import '../state/assets.dart';
import '../state/plan_math.dart';
import 'format.dart';
import 'widgets/brand/dm_icons.g.dart';

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

  /// Pack icon (docs/brand/icons); Solana has none. [icon] stays for
  /// widgets that only take [IconData].
  DMIcons? get dmIcon => switch (this) {
    Rail.solana => null,
    Rail.cloak => DMIcons.cloak,
    Rail.zcash => DMIcons.shieldZ,
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
