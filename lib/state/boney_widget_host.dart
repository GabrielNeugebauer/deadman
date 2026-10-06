import 'package:flutter/widgets.dart';
import 'package:home_widget/home_widget.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../solana/deadman_client.dart';
import 'boney.dart';
import 'boney_widget_sync.dart';
import 'secure_store.dart';

/// The Android widget provider the `boney_*` data is for.
const boneyAndroidName = 'BoneyWidgetProvider';
const boneyQualifiedAndroidName = 'app.deadman.seeker.BoneyWidgetProvider';

/// home_widget: data goes to the plugin's SharedPreferences, read by
/// [boneyQualifiedAndroidName].
class HomeWidgetHost implements BoneyWidgetHost {
  const HomeWidgetHost();

  @override
  Future<void> save(Map<String, Object?> data) async {
    for (final MapEntry(:key, :value) in data.entries) {
      await HomeWidget.saveWidgetData<Object>(key, value);
    }
  }

  @override
  Future<Object?> read(String key) => HomeWidget.getWidgetData<Object>(key);

  @override
  Future<void> update() => HomeWidget.updateWidget(
    androidName: boneyAndroidName,
    qualifiedAndroidName: boneyQualifiedAndroidName,
  );
}

BoneyWidgetHost? platformBoneyHost() => const HomeWidgetHost();

/// Lets the widget's check-in button reach [boneyWidgetCallback].
Future<void> registerBoneyCallback() async {
  await HomeWidget.registerInteractivityCallback(boneyWidgetCallback);
}

/// Background entry point for widget taps ([boneyCheckInUri]).
@pragma('vm:entry-point')
Future<void> boneyWidgetCallback(Uri? uri) async {
  if (!isBoneyCheckIn(uri)) return;
  WidgetsFlutterBinding.ensureInitialized();
  final store = SecureStore();
  await BoneyCheckIn(
    prefs: await SharedPreferences.getInstance(),
    api: DeadmanClient(),
    loadGuard: store.loadGuard,
    sync: BoneyWidgetSync(const HomeWidgetHost()),
  ).run();
}

/// Background refresh (the hourly Workmanager task): re-reads the plans
/// and pushes Boney. No owner: Boney shows "Make a plan". Skips the RPC
/// read when no Boney widget is on the home screen.
Future<void> refreshBoneyInBackground() async {
  final placed = await HomeWidget.getInstalledWidgets();
  // ComponentName.shortClassName: ".BoneyWidgetProvider".
  if (!placed.any(
    (w) => w.androidClassName?.endsWith(boneyAndroidName) ?? false,
  )) {
    return;
  }
  final prefs = await SharedPreferences.getInstance();
  await prefs.reload();
  final sync = BoneyWidgetSync(const HomeWidgetHost());
  final owner = prefs.getString('owner');
  if (owner == null) {
    await sync.push(
      boneyFor(const [], now: DateTime.now().millisecondsSinceEpoch ~/ 1000),
    );
    return;
  }
  final plans = await DeadmanClient().fetchVaults(owner);
  final guard = await SecureStore().loadGuard();
  await sync.syncPlans(plans, prefs: prefs, guard: guard?.address);
}
