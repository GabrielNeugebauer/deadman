import 'package:flutter/material.dart';

import '../theme.dart';

void toast(BuildContext context, String message, {bool error = false}) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: error ? DmColors.danger : DmColors.raised,
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
    if (context.mounted) toast(context, _clean(e), error: true);
    return false;
  }
}

/// Drops prefixes like `DeadmanException(Foo): ` so users see the message.
String _clean(Object e) =>
    '$e'.replaceFirst(RegExp(r'^\w*Exception(\([^)]*\))?: '), '');
