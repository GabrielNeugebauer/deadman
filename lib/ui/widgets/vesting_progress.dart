import 'package:flutter/material.dart';

import '../../solana/deadman_api.dart';
import '../../state/assets.dart';
import '../../state/vesting.dart';
import '../format.dart';
import '../rules_format.dart';
import '../theme/tokens.dart';
import 'brand/labels.dart';

/// "12 months", "10 minutes", "3 days".
String durationLabel(int secs) {
  if (secs >= monthSecs && secs % monthSecs == 0) {
    final n = secs ~/ monthSecs;
    return n == 1 ? '1 month' : '$n months';
  }
  if (secs >= 86400 && secs % 86400 == 0) {
    final n = secs ~/ 86400;
    return n == 1 ? '1 day' : '$n days';
  }
  if (secs >= 60 && secs % 60 == 0) {
    final n = secs ~/ 60;
    return n == 1 ? '1 minute' : '$n minutes';
  }
  return span(secs);
}

/// "1000 USDC over 12 months after a 3-month cliff".
String scheduleLabel(RuleState r) =>
    '${amountText(r.amount, r.mint)} over ${durationLabel(r.durationSecs)}'
    '${r.afterSecs == 0 ? '' : ', ${durationLabel(r.afterSecs)} cliff'}';

/// Where a schedule stands, in one line.
String vestingStatus(ScheduleProgress p, String? mint, int now) {
  if (p.revoked) {
    return p.settled
        ? 'Revoked · everything vested was released'
        : 'Revoked · capped at ${amountText(p.cap, mint)}';
  }
  final count = p.installmentCount;
  if (p.installments && count != null && !p.fullyVested) {
    final unlocked = p.installmentsUnlocked ?? 0;
    final head = '$unlocked of $count installments unlocked';
    return now < p.startAt
        ? '$head · starts in ${span(p.startAt - now)}'
        : head;
  }
  if (now < p.startAt) return 'Starts in ${span(p.startAt - now)}';
  if (now < p.cliffAt) {
    return 'First unlock at the cliff, in ${span(p.cliffAt - now)}';
  }
  if (!p.fullyVested) {
    return 'Unlocking continuously · fully vested in ${span(p.endAt - now)}';
  }
  return p.settled ? 'Fully vested and released' : 'Fully vested';
}

/// "Next installment: 100 USDC on Nov 3, 2026"; null when none is coming.
String? nextInstallmentText(ScheduleProgress p, String? mint) {
  final at = p.nextInstallmentAt;
  if (!p.installments || at == null || p.nextInstallmentAmount <= 0) {
    return null;
  }
  return 'Next installment: ${amountText(p.nextInstallmentAmount, mint)} on '
      '${installmentDate(at, p.periodSecs)}';
}

/// "Vested 250 of 1000 USDC · released 100 USDC".
String vestingAmounts(ScheduleProgress p, String? mint) =>
    'Vested ${amountNumber(p.vested, mint)} of ${amountText(p.total, mint)}'
    ' · released ${amountText(p.released, mint)}';

/// Released (solid) over vested (tinted) over the total (track). Flat,
/// like the pulse ring: the bar measures, it does not decorate.
class VestingBar extends StatelessWidget {
  const VestingBar({super.key, required this.progress, this.color = DM.pulse});

  final ScheduleProgress progress;
  final Color color;

  @override
  Widget build(BuildContext context) {
    Widget part(double f, Color c) => FractionallySizedBox(
      alignment: Alignment.centerLeft,
      widthFactor: f.clamp(0.0, 1.0),
      child: ColoredBox(color: c),
    );
    return Semantics(
      label: 'Vested ${percent(progress.vestedFraction)}',
      child: ClipRRect(
        borderRadius: BorderRadius.circular(2),
        child: SizedBox(
          height: 6,
          child: Stack(
            fit: StackFit.expand,
            children: [
              part(1, DM.line),
              part(progress.vestedFraction, color.withValues(alpha: 0.35)),
              part(progress.releasedFraction, color),
            ],
          ),
        ),
      ),
    );
  }

  static String percent(double f) => '${(f * 100).round()}%';
}

/// One vesting schedule: label, rail, bar, amounts and status.
class VestingScheduleView extends StatelessWidget {
  const VestingScheduleView({
    super.key,
    required this.rule,
    required this.progress,
    required this.now,
    this.showBeneficiary = true,
  });

  final RuleState rule;
  final ScheduleProgress progress;
  final int now;
  final bool showBeneficiary;

  @override
  Widget build(BuildContext context) {
    final data = DMType.data(size: 12.5);
    final next = nextInstallmentText(progress, rule.mint);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Text(
                showBeneficiary
                    ? '${scheduleLabel(rule)} → ${short(rule.beneficiary)}'
                    : scheduleLabel(rule),
                style: DMType.outfit(size: 15, weight: FontWeight.w500),
              ),
            ),
            const SizedBox(width: DMSpace.sm),
            DMTag(label: rule.rail.label, icon: rule.rail.icon),
          ],
        ),
        const SizedBox(height: DMSpace.md),
        VestingBar(progress: progress),
        const SizedBox(height: DMSpace.sm),
        Text(vestingAmounts(progress, rule.mint), style: data),
        Text(
          vestingStatus(progress, rule.mint, now),
          style: progress.revoked ? data.copyWith(color: DM.bone) : data,
        ),
        if (next != null) Text(next, style: data),
      ],
    );
  }
}
