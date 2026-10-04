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
          // Unlock first so the UI responds instantly. The lockdown is
          // persisted and retried with backoff (foreground and Workmanager)
          // until it goes through; nothing is shown to the person watching.
          ref.read(sessionProvider.notifier).unlock(duress: true);
          unawaited(
            ref
                .read(actionsProvider)
                .duressLockdown()
                .catchError((Object _) {}),
          );
          return true;
      }
    }

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            const Spacer(),
            const Icon(
              Icons.monitor_heart_outlined,
              color: DmColors.alive,
              size: 36,
            ),
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
