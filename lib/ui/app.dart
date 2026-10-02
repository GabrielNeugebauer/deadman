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

class DeadmanApp extends StatelessWidget {
  const DeadmanApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Deadman',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(),
        home: const _Gate(),
      );
}

final _hasPinsProvider = FutureProvider((ref) => ref.watch(secureStoreProvider).hasPins());

class _Gate extends ConsumerWidget {
  const _Gate();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider);
    if (session.owner == null) return const WelcomeScreen();
    final hasPins = ref.watch(_hasPinsProvider);
    return hasPins.when(
      loading: () => const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (e, _) => Scaffold(body: Center(child: Text('$e'))),
      data: (has) {
        if (!has) return PinSetupScreen(onDone: () => ref.invalidate(_hasPinsProvider));
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
        bottomNavigationBar: NavigationBar(
          selectedIndex: _index,
          onDestinationSelected: (i) => setState(() => _index = i),
          destinations: const [
            NavigationDestination(icon: Icon(Icons.monitor_heart_outlined), label: 'Pulse'),
            NavigationDestination(icon: Icon(Icons.diversity_3_outlined), label: 'Circle'),
            NavigationDestination(icon: Icon(Icons.shield_outlined), label: 'Security'),
          ],
        ),
      );
}
