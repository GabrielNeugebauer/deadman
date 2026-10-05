import 'package:flutter/material.dart';

import '../../../solana/deadman_api.dart';
import '../../../state/plan_draft.dart';
import '../../rules_format.dart';
import '../../theme.dart';

/// Labelled step dots. Done steps can be tapped to go back.
class StepHeader extends StatelessWidget {
  const StepHeader({
    super.key,
    required this.labels,
    required this.current,
    this.onTap,
  });

  final List<String> labels;
  final int current;
  final ValueChanged<int>? onTap;

  @override
  Widget build(BuildContext context) {
    final n = labels.length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < n; i++)
            Expanded(
              child: Semantics(
                label: 'Step ${i + 1} of $n, ${labels[i]}',
                selected: i == current,
                button: i < current,
                excludeSemantics: true,
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: i < current && onTap != null ? () => onTap!(i) : null,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 48),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              _Dot(index: i, current: current),
                              if (i < n - 1)
                                Expanded(
                                  child: Container(
                                    height: 2,
                                    margin: const EdgeInsets.symmetric(
                                      horizontal: 6,
                                    ),
                                    color: i < current
                                        ? DmColors.alive
                                        : DmColors.line,
                                  ),
                                ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(
                            labels[i],
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: i == current
                                  ? FontWeight.w600
                                  : FontWeight.w400,
                              color: i <= current
                                  ? DmColors.text
                                  : DmColors.muted,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot({required this.index, required this.current});

  final int index;
  final int current;

  @override
  Widget build(BuildContext context) {
    final done = index < current;
    final now = index == current;
    return Container(
      width: 22,
      height: 22,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: now ? DmColors.alive : Colors.transparent,
        border: Border.all(
          color: now || done ? DmColors.alive : DmColors.line,
          width: 2,
        ),
      ),
      child: done
          ? const Icon(Icons.check, size: 13, color: DmColors.alive)
          : Text(
              '${index + 1}',
              // Fixed-size dot; the step label next to it scales.
              textScaler: TextScaler.noScaling,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: now ? DmColors.bg : DmColors.muted,
              ),
            ),
    );
  }
}

/// AppBar, step header, scrollable body and a Back / primary bottom bar.
/// System back runs [onPopBlocked] while [canPop] is false.
class StepScaffold extends StatelessWidget {
  const StepScaffold({
    super.key,
    required this.title,
    required this.steps,
    required this.step,
    required this.children,
    required this.primaryLabel,
    required this.onPrimary,
    required this.canPop,
    required this.onPopBlocked,
    this.onStepTap,
    this.onBack,
    this.busy = false,
    this.controller,
  });

  final String title;
  final List<String> steps;
  final int step;
  final List<Widget> children;
  final String primaryLabel;
  final VoidCallback onPrimary;
  final bool canPop;
  final VoidCallback onPopBlocked;
  final ValueChanged<int>? onStepTap;

  /// Null hides Back (first step).
  final VoidCallback? onBack;
  final bool busy;
  final ScrollController? controller;

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: canPop && !busy,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop && !busy) onPopBlocked();
    },
    child: Scaffold(
      appBar: AppBar(
        backgroundColor: DmColors.bg,
        // The step header below stays flat; a tinted bar above it would
        // split the header in two.
        scrolledUnderElevation: 0,
        title: Text(title),
      ),
      body: Column(
        children: [
          StepHeader(
            labels: steps,
            current: step,
            onTap: busy ? null : onStepTap,
          ),
          const Divider(height: 1, color: DmColors.line),
          Expanded(
            // Not a lazy list: validation scrolls to fields and checkboxes
            // that may be far below the fold.
            child: SingleChildScrollView(
              key: ValueKey('step-$step'),
              controller: controller,
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: children,
              ),
            ),
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Container(
          decoration: const BoxDecoration(
            color: DmColors.bg,
            border: Border(top: BorderSide(color: DmColors.line)),
          ),
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              if (onBack != null) ...[
                Expanded(
                  flex: 2,
                  child: OutlinedButton(
                    onPressed: busy ? null : onBack,
                    child: const Text('Back'),
                  ),
                ),
                const SizedBox(width: 12),
              ],
              Expanded(
                flex: 3,
                child: FilledButton(
                  onPressed: busy ? null : onPrimary,
                  child: busy
                      ? const SizedBox.square(
                          dimension: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(primaryLabel, textAlign: TextAlign.center),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// The first-run card of a list: a title, one line and an add button.
class EmptyStateCard extends StatelessWidget {
  const EmptyStateCard({
    super.key,
    required this.title,
    required this.body,
    required this.addLabel,
    required this.onAdd,
  });

  final String title;
  final String body;
  final String addLabel;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(18),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: DmColors.muted.withValues(alpha: 0.5)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          title,
          style: Theme.of(context).textTheme.titleLarge?.copyWith(fontSize: 18),
        ),
        const SizedBox(height: 6),
        Text(body, style: const TextStyle(color: DmColors.muted, height: 1.4)),
        const SizedBox(height: 14),
        OutlinedButton.icon(
          onPressed: onAdd,
          icon: const Icon(Icons.add),
          label: Text(addLabel),
        ),
      ],
    ),
  );
}

/// A card with an optional numbered title ("1  Who gets it").
class SectionCard extends StatelessWidget {
  const SectionCard({
    super.key,
    this.number,
    this.title,
    this.trailing,
    required this.children,
  });

  final int? number;
  final String? title;
  final Widget? trailing;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title != null) ...[
            Row(
              children: [
                if (number != null) ...[
                  Container(
                    width: 24,
                    height: 24,
                    alignment: Alignment.center,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      color: Color(0x333DF5A7),
                    ),
                    child: Text(
                      '$number',
                      textScaler: TextScaler.noScaling,
                      style: const TextStyle(
                        color: DmColors.alive,
                        fontWeight: FontWeight.w700,
                        fontSize: 13,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                ],
                Expanded(
                  child: Text(
                    title!,
                    style: Theme.of(context).textTheme.titleLarge
                        ?.copyWith(fontSize: 18),
                  ),
                ),
                ?trailing,
              ],
            ),
            const SizedBox(height: 14),
          ],
          ...children,
        ],
      ),
    ),
  );
}

Color severityColor(Severity s) => switch (s) {
  Severity.error || Severity.danger => DmColors.danger,
  Severity.warn => DmColors.warn,
  Severity.info => DmColors.muted,
};

IconData severityIcon(Severity s) => switch (s) {
  Severity.error || Severity.danger => Icons.error_outline,
  Severity.warn => Icons.warning_amber_rounded,
  Severity.info => Icons.info_outline,
};

/// One warning: icon, title, body and an optional fix.
class WarningTile extends StatelessWidget {
  const WarningTile({
    super.key,
    required this.severity,
    this.title = '',
    required this.body,
    this.actionLabel,
    this.onAction,
  });

  WarningTile.of(PlanIssue issue, {Key? key, VoidCallback? onAction})
    : this(
        key: key,
        severity: issue.severity,
        title: issue.title,
        body: issue.body,
        actionLabel: onAction == null ? null : issue.action,
        onAction: onAction,
      );

  final Severity severity;
  final String title;
  final String body;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final color = severityColor(severity);
    return Semantics(
      liveRegion: true,
      child: Container(
        width: double.infinity,
        margin: const EdgeInsets.only(top: 10),
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(severityIcon(severity), color: color, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (title.isNotEmpty)
                    Text(
                      title,
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: severity == Severity.info
                            ? DmColors.text
                            : color,
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.only(top: 2, bottom: 8),
                    child: Text(
                      body,
                      style: const TextStyle(height: 1.35, fontSize: 13),
                    ),
                  ),
                  if (actionLabel != null && onAction != null)
                    TextButton(
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        minimumSize: const Size(48, 40),
                        foregroundColor: color == DmColors.muted
                            ? DmColors.alive
                            : color,
                      ),
                      onPressed: onAction,
                      child: Text(actionLabel!),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A one-line warning: icon and title.
class IssueLine extends StatelessWidget {
  const IssueLine(this.issue, {super.key});

  final PlanIssue issue;

  @override
  Widget build(BuildContext context) {
    final color = severityColor(issue.severity);
    return Row(
      children: [
        Icon(severityIcon(issue.severity), size: 16, color: color),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            issue.headline,
            style: TextStyle(color: color, fontSize: 13),
          ),
        ),
      ],
    );
  }
}

String railTitle(Rail r) => switch (r) {
  Rail.solana => 'Normal transfer',
  Rail.cloak => 'Private (Cloak)',
  Rail.zcash => 'Private as Zcash',
};

String railHelper(Rail r) => switch (r) {
  Rail.solana =>
    'Straight to their Solana wallet. Anyone can see it on the blockchain.',
  Rail.cloak => 'Hidden on Solana. They need the Deadman app and must send you a claim code.',
  Rail.zcash => 'Arrives as private Zcash. They need the Deadman app and must send you a claim code.',
};

/// Short rail name for cards: "Normal", "Cloak", "Zcash".
String railShort(Rail r) => switch (r) {
  Rail.solana => 'Normal',
  Rail.cloak => 'Cloak',
  Rail.zcash => 'Zcash',
};

/// A radio card for a delivery rail.
class RailOptionTile extends StatelessWidget {
  const RailOptionTile({
    super.key,
    required this.rail,
    required this.selected,
    required this.onTap,
    required this.feeLine,
    this.badge,
  });

  final Rail rail;
  final bool selected;
  final VoidCallback onTap;
  final String feeLine;
  final String? badge;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Semantics(
      inMutuallyExclusiveGroup: true,
      checked: selected,
      button: true,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 64),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            color: selected
                ? rail.color.withValues(alpha: 0.08)
                : Colors.transparent,
            border: Border.all(
              color: selected ? rail.color : DmColors.line,
              width: selected ? 1.5 : 1,
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                selected ? Icons.radio_button_checked : Icons.radio_button_off,
                color: selected ? rail.color : DmColors.muted,
                size: 22,
              ),
              const SizedBox(width: 10),
              Icon(rail.icon, color: rail.color, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          railTitle(rail),
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        if (badge != null)
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: DmColors.raised,
                              borderRadius: BorderRadius.circular(99),
                            ),
                            child: Text(
                              badge!,
                              style: const TextStyle(
                                color: DmColors.muted,
                                fontSize: 11,
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      railHelper(rail),
                      style: const TextStyle(
                        color: DmColors.muted,
                        fontSize: 13,
                        height: 1.3,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      feeLine,
                      style: const TextStyle(
                        color: DmColors.muted,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// A small rail chip for cards: "⚡ Normal".
class RailChip extends StatelessWidget {
  const RailChip(this.rail, {super.key});

  final Rail rail;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(
      color: rail.color.withValues(alpha: 0.14),
      borderRadius: BorderRadius.circular(99),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(rail.icon, size: 13, color: rail.color),
        const SizedBox(width: 4),
        Text(
          railShort(rail),
          style: TextStyle(
            color: rail.color,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    ),
  );
}

/// A Review block: a title with an Edit button, then its content.
class ReviewSection extends StatelessWidget {
  const ReviewSection({
    super.key,
    required this.title,
    this.onEdit,
    required this.children,
  });

  final String title;
  final VoidCallback? onEdit;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleLarge
                      ?.copyWith(fontSize: 18),
                ),
              ),
              if (onEdit != null)
                TextButton(onPressed: onEdit, child: const Text('Edit')),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: children,
            ),
          ),
        ],
      ),
    ),
  );
}

/// A label on the left, its value on the right; both wrap at large text.
class CostRow extends StatelessWidget {
  const CostRow(this.label, this.value, {super.key});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          flex: 2,
          child: Text(label, style: const TextStyle(color: DmColors.muted)),
        ),
        const SizedBox(width: 12),
        Expanded(flex: 3, child: Text(value, textAlign: TextAlign.end)),
      ],
    ),
  );
}

/// The sticky money line of an editor, with its most severe warning.
class LivePreview extends StatelessWidget {
  const LivePreview({super.key, required this.text, this.issue, this.onIssue});

  final InlineSpan text;
  final PlanIssue? issue;
  final VoidCallback? onIssue;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    mainAxisSize: MainAxisSize.min,
    children: [
      Semantics(
        liveRegion: true,
        child: Text.rich(text, style: const TextStyle(height: 1.35)),
      ),
      if (issue != null)
        InkWell(
          onTap: onIssue,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 40),
            child: Row(
              children: [
                Expanded(child: IssueLine(issue!)),
                const Icon(Icons.chevron_right, color: DmColors.muted),
              ],
            ),
          ),
        ),
    ],
  );
}

/// A decorative line from the last check-in: a tick where the next
/// check-in is due and a dot where this payout runs.
class DelayStrip extends StatelessWidget {
  const DelayStrip({
    super.key,
    required this.intervalSecs,
    required this.delaySecs,
  });

  final int intervalSecs;
  final int delaySecs;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: SizedBox(
      height: 40,
      width: double.infinity,
      child: CustomPaint(painter: _StripPainter(intervalSecs, delaySecs)),
    ),
  );
}

class _StripPainter extends CustomPainter {
  _StripPainter(this.interval, this.delay);

  final int interval;
  final int delay;

  @override
  void paint(Canvas canvas, Size size) {
    const y = 20.0;
    const pad = 8.0;
    final span = (delay > interval ? delay : interval) * 1.1;
    double x(int secs) => pad + (size.width - 2 * pad) * secs / span;
    final line = Paint()
      ..color = DmColors.line
      ..strokeWidth = 2;
    canvas.drawLine(const Offset(pad, y), Offset(size.width - pad, y), line);
    canvas.drawLine(
      const Offset(pad, y),
      Offset(x(delay), y),
      Paint()
        ..color = DmColors.alive.withValues(alpha: 0.4)
        ..strokeWidth = 2,
    );
    canvas.drawCircle(const Offset(pad, y), 5, Paint()..color = DmColors.muted);
    final tick = x(interval);
    canvas.drawLine(
      Offset(tick, y - 7),
      Offset(tick, y + 7),
      Paint()
        ..color = DmColors.warn
        ..strokeWidth = 2,
    );
    canvas.drawCircle(Offset(x(delay), y), 7, Paint()..color = DmColors.alive);
  }

  @override
  bool shouldRepaint(_StripPainter old) =>
      old.interval != interval || old.delay != delay;
}

/// One node of a vertical timeline.
class TimelineEntry extends StatelessWidget {
  const TimelineEntry({
    super.key,
    required this.label,
    this.child,
    this.dot = DmColors.line,
    this.last = false,
  });

  final String label;
  final Widget? child;
  final Color dot;
  final bool last;

  @override
  Widget build(BuildContext context) => Stack(
    clipBehavior: Clip.none,
    children: [
      Container(
        margin: const EdgeInsets.only(left: 7),
        padding: const EdgeInsets.fromLTRB(18, 0, 0, 16),
        decoration: last
            ? null
            : const BoxDecoration(
                border: Border(
                  left: BorderSide(color: DmColors.line, width: 2),
                ),
              ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (label.isNotEmpty)
              Text(
                label,
                style: const TextStyle(
                  color: DmColors.muted,
                  fontWeight: FontWeight.w600,
                ),
              ),
            if (child != null) ...[
              if (label.isNotEmpty) const SizedBox(height: 8),
              child!,
            ],
          ],
        ),
      ),
      Positioned(
        left: 2,
        top: 3,
        child: Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(shape: BoxShape.circle, color: dot),
        ),
      ),
    ],
  );
}

/// A danger acknowledgement checkbox that shakes when [shake] changes.
class AckBox extends StatelessWidget {
  const AckBox({
    super.key,
    required this.value,
    required this.onChanged,
    required this.label,
    required this.shake,
    this.error,
  });

  final bool value;
  final ValueChanged<bool> onChanged;
  final String label;
  final int shake;
  final String? error;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    key: ValueKey(shake),
    tween: Tween(begin: shake == 0 ? 1 : 0, end: 1),
    duration: const Duration(milliseconds: 400),
    builder: (context, t, child) => Transform.translate(
      offset: Offset(8 * (1 - t) * _wave(t), 0),
      child: child,
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CheckboxListTile(
          value: value,
          onChanged: (v) => onChanged(v ?? false),
          controlAffinity: ListTileControlAffinity.leading,
          contentPadding: EdgeInsets.zero,
          title: Text(label, style: const TextStyle(height: 1.35)),
        ),
        if (error != null)
          Text(
            error!,
            style: const TextStyle(color: DmColors.danger, fontSize: 13),
          ),
      ],
    ),
  );

  static double _wave(double t) => (t * 6).floor().isEven ? 1 : -1;
}
