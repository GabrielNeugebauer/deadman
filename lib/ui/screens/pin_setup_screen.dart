import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/providers.dart';
import '../theme.dart';
import '../widgets/feedback.dart';
import '../widgets/pin_pad.dart';

enum _Step { pin, confirm, duress }

class PinSetupScreen extends ConsumerStatefulWidget {
  const PinSetupScreen({super.key, required this.onDone});

  final VoidCallback onDone;

  @override
  ConsumerState<PinSetupScreen> createState() => _PinSetupScreenState();
}

class _PinSetupScreenState extends ConsumerState<PinSetupScreen> {
  _Step _step = _Step.pin;
  String _pin = '';

  Future<bool> _onPin(String value) async {
    switch (_step) {
      case _Step.pin:
        setState(() {
          _pin = value;
          _step = _Step.confirm;
        });
        return true;
      case _Step.confirm:
        if (value != _pin) {
          toast(context, 'PINs do not match', error: true);
          setState(() => _step = _Step.pin);
          return false;
        }
        setState(() => _step = _Step.duress);
        return true;
      case _Step.duress:
        if (value == _pin) {
          toast(context, 'Duress PIN must differ from your PIN', error: true);
          return false;
        }
        await ref
            .read(secureStoreProvider)
            .setPins(pin: _pin, duressPin: value);
        ref.read(sessionProvider.notifier).unlock(duress: false);
        widget.onDone();
        return true;
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final (title, body, color) = switch (_step) {
      _Step.pin => (
        'Choose your PIN',
        'Six digits to open Deadman.',
        DmColors.alive,
      ),
      _Step.confirm => (
        'Confirm your PIN',
        'Enter it once more.',
        DmColors.alive,
      ),
      _Step.duress => (
        'Choose a duress PIN',
        'If someone forces you to open the app, enter this instead. Everything looks normal, but your vault is silently locked down and withdrawals stall.',
        DmColors.warn,
      ),
    };
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              const Spacer(),
              Icon(
                _step == _Step.duress
                    ? Icons.front_hand_outlined
                    : Icons.pin_outlined,
                color: color,
                size: 36,
              ),
              const SizedBox(height: 16),
              Text(title, style: t.headlineMedium, textAlign: TextAlign.center),
              const SizedBox(height: 10),
              Text(
                body,
                textAlign: TextAlign.center,
                style: t.bodyMedium?.copyWith(
                  color: DmColors.muted,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 32),
              PinPad(key: ValueKey(_step), onComplete: _onPin),
              const Spacer(),
            ],
          ),
        ),
      ),
    );
  }
}
