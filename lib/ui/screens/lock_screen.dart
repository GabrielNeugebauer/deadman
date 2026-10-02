import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/actions.dart';
import '../../state/providers.dart';
import '../../state/secure_store.dart';
import '../theme.dart';
import '../widgets/pin_pad.dart';

class LockScreen extends ConsumerWidget {
  const LockScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;

    Future<bool> onPin(String pin) async {
      final result = await ref.read(secureStoreProvider).checkPin(pin);
      switch (result) {
        case PinCheck.wrong:
          return false;
        case PinCheck.normal:
          ref.read(sessionProvider.notifier).unlock(duress: false);
          return true;
        case PinCheck.duress:
          // Unlock first so the UI responds instantly; lockdown runs behind it.
          ref.read(sessionProvider.notifier).unlock(duress: true);
          unawaited(ref.read(actionsProvider).lockdown().catchError((_) {}));
          return true;
      }
    }

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            const Spacer(),
            const Icon(Icons.monitor_heart_outlined, color: DmColors.alive, size: 36),
            const SizedBox(height: 16),
            Text('Enter PIN', style: t.headlineMedium),
            const SizedBox(height: 32),
            PinPad(onComplete: onPin),
            const Spacer(),
          ],
        ),
      ),
    );
  }
}
