import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'state/providers.dart';
import 'state/reminders.dart';
import 'ui/app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  final container = ProviderContainer(
    overrides: [prefsProvider.overrideWithValue(prefs)],
  );
  runApp(
    UncontrolledProviderScope(container: container, child: const DeadmanApp()),
  );
  await initReminders().catchError((Object _) {});
  // A duress lockdown that had not gone through when the app was killed.
  await container
      .read(lockdownRetrierProvider)
      .resume()
      .catchError((Object _) {});
}
