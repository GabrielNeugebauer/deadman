import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/providers.dart';
import 'screens/circle_tab.dart';
import 'screens/lock_screen.dart';
import 'screens/pin_setup_screen.dart';
import 'screens/pulse_tab.dart';
import 'screens/settings_tab.dart';
import 'screens/welcome_screen.dart';
import 'theme.dart';
import 'web/web_ui.dart';

class DeadmanApp extends StatelessWidget {
  const DeadmanApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Deadman',
    debugShowCheckedModeBanner: false,
    theme: buildTheme(),
    // Browser windows can be desktop-wide; the app stays phone-shaped.
    builder: kIsWeb ? (context, child) => WebFrame(child: child!) : null,
    home: const _Gate(),
  );
}

final _hasPinsProvider = FutureProvider(
  (ref) => ref.watch(secureStoreProvider).hasPins(),
);

class _Gate extends ConsumerWidget {
  const _Gate();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider);
    if (session.owner == null) return const WelcomeScreen();
    final hasPins = ref.watch(_hasPinsProvider);
    return hasPins.when(
      loading: () =>
          const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (e, _) => Scaffold(body: Center(child: Text('$e'))),
      data: (has) {
        if (!has) {
          return PinSetupScreen(onDone: () => ref.invalidate(_hasPinsProvider));
        }
        if (!session.unlocked) return const LockScreen();
        return const _Shell();
      },
    );
  }
}

class _Shell extends StatefulWidget {
  const _Shell();

  @override
  State<_Shell> createState() => _ShellState();
}

class _ShellState extends State<_Shell> {
  int _index = 0;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: IndexedStack(
      index: _index,
      children: const [PulseTab(), CircleTab(), SettingsTab()],
    ),
    // The mockups draw a 1px line above the bar; the theme leaves it off.
    bottomNavigationBar: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Divider(height: 1, thickness: 1, color: DM.line),
        NavigationBar(
          selectedIndex: _index,
          onDestinationSelected: (i) => setState(() => _index = i),
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.radio_button_unchecked),
              label: 'Pulse',
            ),
            NavigationDestination(
              icon: Icon(Icons.people_outline),
              label: 'Circle',
            ),
            NavigationDestination(
              icon: Icon(Icons.shield_outlined),
              label: 'Security',
            ),
          ],
        ),
      ],
    ),
  );
}
