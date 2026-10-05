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
            offset: Offset(
              sin(_shake.value * pi * 6) * 12 * (1 - _shake.value),
              0,
            ),
            child: child,
          ),
          child: Semantics(
            label: '${_pin.length} of ${widget.length} digits entered',
            liveRegion: true,
            excludeSemantics: true,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(widget.length, (i) {
                final filled = i < _pin.length;
                // Square cells, like the status dots on chips.
                return AnimatedContainer(
                  key: ValueKey('pin-cell-$i'),
                  duration: const Duration(milliseconds: 120),
                  curve: Curves.easeOutCubic,
                  margin: const EdgeInsets.symmetric(horizontal: 7),
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                    color: filled ? DM.signal : Colors.transparent,
                    borderRadius: BorderRadius.circular(2),
                    border: Border.all(
                      color: filled ? DM.signal : DM.mist,
                      width: 1.5,
                    ),
                  ),
                );
              }),
            ),
          ),
        ),
        const SizedBox(height: DMSpace.xxxl),
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
                  padding: const EdgeInsets.all(DMSpace.xs),
                  child: SizedBox(
                    width: 84,
                    height: 64,
                    child: k.isEmpty
                        ? null
                        : k == '<'
                        ? IconButton(
                            tooltip: 'Delete digit',
                            style: IconButton.styleFrom(
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(
                                  DMRadius.card,
                                ),
                              ),
                            ),
                            onPressed: _back,
                            icon: const Icon(
                              Icons.backspace_outlined,
                              color: DM.sub,
                            ),
                          )
                        : _Key(digit: k, onTap: () => _tap(k)),
                  ),
                ),
            ],
          ),
      ],
    );
  }
}

/// A graphite key with a 1px line, digit in mono.
class _Key extends StatelessWidget {
  const _Key({required this.digit, required this.onTap});

  final String digit;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => TextButton(
    style: TextButton.styleFrom(
      backgroundColor: DM.graphite,
      foregroundColor: DM.bone,
      overlayColor: DM.signal,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(DMRadius.card),
        side: const BorderSide(color: DM.line),
      ),
    ),
    onPressed: onTap,
    child: Text(digit, style: DMType.mono(size: 26)),
  );
}
