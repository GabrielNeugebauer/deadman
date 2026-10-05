import 'package:flutter/material.dart';

import 'brand/brand.dart';

/// Shared frame of the PIN screens (lock, setup, duress): the lockup at
/// the top, a heading block and the pad. Scrolls on short windows.
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

/// Setup progress: one short bar per step, signal up to the current one.
class _Steps extends StatelessWidget {
  const _Steps({required this.step, required this.steps});

  final int step;
  final int steps;

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Step $step of $steps',
    excludeSemantics: true,
    child: Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (var i = 1; i <= steps; i++)
          Container(
            key: ValueKey('pin-step-$i'),
            width: 28,
            height: 3,
            margin: const EdgeInsets.symmetric(horizontal: 3),
            decoration: BoxDecoration(
              color: i <= step ? DM.signal : DM.track,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
      ],
    ),
  );
}
