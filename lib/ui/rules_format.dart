import 'package:flutter/material.dart';

import '../solana/deadman_api.dart';
import 'format.dart';
import 'theme.dart';

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

  Color get color => switch (this) {
    Rail.solana => DmColors.alive,
    Rail.cloak => DmColors.plus,
    Rail.zcash => DmColors.warn,
  };

  IconData get icon => switch (this) {
    Rail.solana => Icons.bolt,
    Rail.cloak => Icons.visibility_off_outlined,
    Rail.zcash => Icons.shield_moon_outlined,
  };
}

String amountLabel(RuleSpec r) => switch (r.mode) {
  AmountMode.percent =>
    '${r.amount / 100}%${r.mint == null ? ' of SOL' : ' of ${short(r.mint!)}'}',
  AmountMode.fixed =>
    r.mint == null
        ? '${sol(r.amount)} SOL'
        : '${r.amount} units ${short(r.mint!)}',
};

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

class RailBadge extends StatelessWidget {
  const RailBadge(this.rail, {super.key});

  final Rail rail;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(
      color: rail.color.withValues(alpha: 0.14),
      borderRadius: BorderRadius.circular(99),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(rail.icon, size: 13, color: rail.color),
        const SizedBox(width: 4),
        Text(
          rail.label,
          style: TextStyle(
            color: rail.color,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    ),
  );
}
