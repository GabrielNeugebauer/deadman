import 'package:flutter/material.dart';

import 'brand/brand.dart';

/// Shared frame of the PIN screens (lock, setup, duress): the skull lockup
/// at the top, the step sticker during setup, a heading block and the pad.
/// Scrolls on short windows. The lock screen looks the same whichever PIN
/// is entered; nothing here may hint at the duress path.
class PinScaffold extends StatelessWidget {
  const PinScaffold({
    super.key,
    required this.title,
    required this.pad,
    this.body,
    this.step,
    this.steps = 3,
  });

  final String title;
  final String? body;
  final Widget pad;

  /// 1-based position in a multi-step setup, or null for a single step.
  final int? step;
  final int steps;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final step = this.step;
    return Scaffold(
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, box) => SingleChildScrollView(
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: box.maxHeight),
              child: IntrinsicHeight(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(
                    DMSpace.gutter,
                    DMSpace.xl,
                    DMSpace.gutter,
                    DMSpace.xxl,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Align(
                        alignment: Alignment.centerLeft,
                        child: DeadmanLockup(height: 24),
                      ),
                      const Spacer(),
                      const SizedBox(height: DMSpace.xxl),
                      if (step != null) ...[
                        _Steps(step: step, steps: steps),
                        const SizedBox(height: DMSpace.xl),
                      ],
                      Semantics(
                        header: true,
                        child: Text(
                          title,
                          style: t.headlineMedium,
                          textAlign: TextAlign.center,
                        ),
                      ),
                      if (body != null) ...[
                        const SizedBox(height: DMSpace.sm),
                        Center(
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 340),
                            child: Text(
                              body!,
                              style: t.bodyMedium,
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ),
                      ],
                      const SizedBox(height: DMSpace.xxxl),
                      Center(child: pad),
                      const Spacer(),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Setup progress as the brand's step sticker ("STEP 1/3"), read out as
/// "Step 1 of 3".
class _Steps extends StatelessWidget {
  const _Steps({required this.step, required this.steps});

  final int step;
  final int steps;

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Step $step of $steps',
    excludeSemantics: true,
    child: Center(
      child: Sticker('Step $step/$steps', key: const ValueKey('pin-step')),
    ),
  );
}
