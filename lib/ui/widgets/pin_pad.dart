import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme.dart';

class PinPad extends StatefulWidget {
  const PinPad({super.key, required this.onComplete, this.length = 6});

  final int length;

  /// Return false to shake and clear.
  final Future<bool> Function(String pin) onComplete;

  @override
  State<PinPad> createState() => _PinPadState();
}

class _PinPadState extends State<PinPad> with SingleTickerProviderStateMixin {
  String _pin = '';
  bool _busy = false;
  late final _shake = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 350),
  );

  @override
  void dispose() {
    _shake.dispose();
    super.dispose();
  }

  Future<void> _tap(String d) async {
    if (_busy || _pin.length >= widget.length) return;
    HapticFeedback.selectionClick();
    setState(() => _pin += d);
    if (_pin.length < widget.length) return;
    _busy = true;
    final ok = await widget.onComplete(_pin);
    if (!mounted) return;
    if (!ok) {
      HapticFeedback.vibrate();
      await _shake.forward(from: 0);
    }
    setState(() {
      _pin = '';
      _busy = false;
    });
  }

  void _back() {
    if (_pin.isEmpty || _busy) return;
    setState(() => _pin = _pin.substring(0, _pin.length - 1));
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        AnimatedBuilder(
          animation: _shake,
          builder: (context, child) => Transform.translate(
            offset: Offset(sin(_shake.value * pi * 6) * 12 * (1 - _shake.value), 0),
            child: child,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: List.generate(widget.length, (i) {
              final filled = i < _pin.length;
              return AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                margin: const EdgeInsets.symmetric(horizontal: 8),
                width: 14,
                height: 14,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: filled ? DmColors.alive : Colors.transparent,
                  border: Border.all(color: filled ? DmColors.alive : DmColors.muted, width: 1.5),
                ),
              );
            }),
          ),
        ),
        const SizedBox(height: 36),
        for (final row in const [
          ['1', '2', '3'],
          ['4', '5', '6'],
          ['7', '8', '9'],
          ['', '0', '<'],
        ])
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (final k in row)
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: SizedBox(
                    width: 76,
                    height: 76,
                    child: k.isEmpty
                        ? null
                        : TextButton(
                            style: TextButton.styleFrom(
                              shape: const CircleBorder(),
                              backgroundColor: k == '<' ? Colors.transparent : DmColors.surface,
                              foregroundColor: DmColors.text,
                            ),
                            onPressed: () => k == '<' ? _back() : _tap(k),
                            child: k == '<'
                                ? const Icon(Icons.backspace_outlined, color: DmColors.muted)
                                : Text(k, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w500)),
                          ),
                  ),
                ),
            ],
          ),
      ],
    );
  }
}
