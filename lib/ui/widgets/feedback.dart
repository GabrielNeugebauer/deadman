import 'package:flutter/material.dart';

import '../../solana/deadman_client.dart';
import 'brand/brand.dart';

/// A snackbar on raise. Errors keep the raise fill and carry a flatline
/// icon: status color marks the message, it never floods the bar.
///
/// [sprite] leads a success message with a pixel figure in pulse, as in
/// the Pulse mockup ("Pulse recorded on 4 plans." with the heart). Use the
/// cast figure for the thing the message names; errors ignore it.
void toast(
  BuildContext context,
  String message, {
  bool error = false,
  PixelSprite? sprite,
}) {
  final Widget? lead = error
      ? const Icon(
          Icons.error_outline,
          size: 18,
          color: DM.flatline,
          semanticLabel: 'Error',
        )
      : sprite == null
      ? null
      : PixelArt(sprite, size: 22, color: DM.pulse);
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        key: error ? const ValueKey('toast-error') : null,
        content: lead == null
            ? Text(message)
            : Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(padding: const EdgeInsets.only(top: 1), child: lead),
                  const SizedBox(width: DMSpace.md),
                  Expanded(child: Text(message)),
                ],
              ),
        duration: Duration(seconds: message.length > 90 ? 8 : 4),
      ),
    );
}

/// Runs [action], reporting failures as a snackbar. Returns true on success.
Future<bool> runGuarded(
  BuildContext context,
  Future<void> Function() action, {
  String? success,
}) async {
  try {
    await action();
    if (context.mounted && success != null) toast(context, success);
    return true;
  } catch (e) {
    if (context.mounted) toast(context, errorText(e), error: true);
    return false;
  }
}

/// Program errors whose raw message doesn't tell the user what to do.
const friendlyErrors = {
  'OwnerConfirmationRequired': 'This phone can no longer check in for this plan. Tap Confirm with wallet on it.',
  'NothingToPay': 'This tier has nothing to pay yet: the plan holds none of its asset. If it still cannot pay after the plan\'s grace period, Deadman skips it automatically and keeps its share reserved.',
  'BeneficiaryCannotReceive': 'The beneficiary\'s account cannot receive this payout. After the plan\'s grace period Deadman skips the tier automatically so later tiers continue; its share stays reserved for the beneficiary to claim.',
  'SkipTooEarly': 'Too early to skip: this tier still has time to pay within the plan\'s grace period.',
  'WrongPlanKind': 'That action does not apply to this kind of plan: vesting plans have no check-ins or tiers, and inheritance plans have no schedules.',
  'InvalidVesting': 'Check each schedule: it needs a total, a cliff no longer than its duration, and a start within a year.',
  'NotRevocable': 'This vesting plan was created irrevocable: its schedules cannot be stopped.',
  'AlreadyRevoked': 'Vesting on this plan was already revoked.',
  'FundsCommitted': 'Those funds are committed to vesting beneficiaries. You can only withdraw what is not owed to them.',
  'NoFeeToken': noFeeTokenText,
};

const noFeeTokenText =
    'Not enough USDC to pay the network fee. Add USDC or switch fees to SOL (Security → Network fees).';

/// User-facing text for an error: drops prefixes like
/// `DeadmanException(Foo): ` and maps known program errors.
String errorText(Object e) {
  if (e is DeadmanException) {
    final friendly = friendlyErrors[e.name];
    if (friendly != null) return friendly;
  }
  if ('$e'.contains('NoFeeToken')) return noFeeTokenText;
  return '$e'.replaceFirst(RegExp(r'^\w*Exception(\([^)]*\))?: '), '');
}
