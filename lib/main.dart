import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'state/boney_widget_host_stub.dart'
    if (dart.library.io) 'state/boney_widget_host.dart';
import 'state/providers.dart';
import 'state/token_list.dart';
import 'state/reminders_stub.dart' if (dart.library.io) 'state/reminders.dart';
import 'ui/app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  // Names of the Jupiter-listed tokens picked before.
  restoreListedTokens(prefs);
  final container = ProviderContainer(
    overrides: [prefsProvider.overrideWithValue(prefs)],
  );
  // Applies the saved "Pay network fees with" choice to the client.
  container.read(feeModeProvider);
  runApp(
    UncontrolledProviderScope(container: container, child: const DeadmanApp()),
  );
  await initReminders().catchError((Object _) {});
  // The Boney widget's check-in button, and his first sync: reading the
  // plans pushes them to the widget.
  if (container.read(boneyHostProvider) != null) {
    await registerBoneyCallback().catchError((Object _) {});
    container.read(vaultsProvider.future).ignore();
  }
  // A duress lockdown that had not gone through when the app was killed.
  await container
      .read(lockdownRetrierProvider)
      .resume()
      .catchError((Object _) {});
}
