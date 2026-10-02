import 'package:flutter/material.dart';

import '../theme.dart';

void toast(BuildContext context, String message, {bool error = false}) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Text(message),
      backgroundColor: error ? DmColors.danger : DmColors.raised,
    ));
}

/// Runs [action], reporting failures as a snackbar. Returns true on success.
Future<bool> runGuarded(BuildContext context, Future<void> Function() action,
    {String? success}) async {
  try {
    await action();
    if (context.mounted && success != null) toast(context, success);
    return true;
  } catch (e) {
    if (context.mounted) toast(context, _clean(e), error: true);
    return false;
  }
}

String _clean(Object e) {
  final s = e.toString();
  return s.startsWith('Exception: ') ? s.substring(11) : s;
}
