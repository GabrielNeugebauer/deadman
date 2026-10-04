import 'package:flutter/material.dart';

import '../../solana/deadman_client.dart';
import '../theme.dart';

void toast(BuildContext context, String message, {bool error = false}) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: error ? DmColors.danger : DmColors.raised,
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
  'NothingToPay': 'This tier has nothing to pay yet. If it still cannot pay after the plan\'s grace period, it can be skipped.',
  'BeneficiaryCannotReceive': 'The beneficiary\'s account cannot receive this payout. After the plan\'s grace period anyone can skip the tier so later tiers continue; its share stays reserved for the beneficiary to claim.',
  'SkipTooEarly': 'Too early to skip: this tier still has time to pay within the plan\'s grace period.',
};

/// User-facing text for an error: drops prefixes like
/// `DeadmanException(Foo): ` and maps known program errors.
String errorText(Object e) {
  if (e is DeadmanException) {
    final friendly = friendlyErrors[e.name];
    if (friendly != null) return friendly;
  }
  return '$e'.replaceFirst(RegExp(r'^\w*Exception(\([^)]*\))?: '), '');
}
