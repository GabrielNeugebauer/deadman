import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/providers.dart';
import '../widgets/feedback.dart';
import '../widgets/pin_pad.dart';
import '../widgets/pin_scaffold.dart';

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
    final (title, body) = switch (_step) {
      _Step.pin => ('Choose your PIN', 'Six digits to open Deadman.'),
      _Step.confirm => ('Confirm your PIN', 'Enter it once more.'),
      _Step.duress => (
        'Choose a duress PIN',
        ref.read(isWebProvider)
            ? 'If someone forces you to open the app, enter this instead. It opens a decoy wallet '
                  'whose actions send nothing, and plans guarded by this browser are silently locked '
                  'while the page stays open. Duress protection is strongest in the Android app.'
            : 'If someone forces you to open the app, enter this instead. It opens a decoy wallet with '
                  'made-up plans: anything done there seems to work but sends nothing, while your real '
                  'vault is silently locked down.',
      ),
    };
    return PinScaffold(
      title: title,
      body: body,
      step: _step.index + 1,
      steps: _Step.values.length,
      pad: PinPad(key: ValueKey(_step), onComplete: _onPin),
    );
  }
}
