import 'package:flutter/material.dart';

import '../../../solana/deadman_api.dart';
import '../../../state/plan_draft.dart';
import '../../rules_format.dart';
import '../brand/brand.dart';

/// Step progress: one track segment per step (signal up to the current
/// one), the step number in mono and its name. Done steps can be tapped to
/// go back.
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
      padding: const EdgeInsets.fromLTRB(
        DMSpace.gutter - DMSpace.xxs,
        DMSpace.xxs,
        DMSpace.gutter - DMSpace.xxs,
        DMSpace.sm,
      ),
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
                  borderRadius: BorderRadius.circular(DMRadius.tile),
                  onTap: i < current && onTap != null ? () => onTap!(i) : null,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 48),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: DMSpace.xxs,
                        vertical: DMSpace.sm,
                      ),
                      child: _StepCell(
                        number: i + 1,
                        label: labels[i],
                        done: i < current,
                        now: i == current,
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

class _StepCell extends StatelessWidget {
  const _StepCell({
    required this.number,
    required this.label,
    required this.done,
    required this.now,
  });

  final int number;
  final String label;
  final bool done;
  final bool now;

  @override
  Widget build(BuildContext context) {
    final reached = done || now;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: 3,
          width: double.infinity,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: reached ? DM.signal : DM.track,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
        const SizedBox(height: DMSpace.sm),
        Row(
          children: [
            SizedBox(
              width: 16,
              child: done
                  ? const Icon(Icons.check, size: 14, color: DM.signal)
                  : Text(
                      '$number',
                      // Fixed-size marker; the step name next to it scales.
                      textScaler: TextScaler.noScaling,
                      style: DMType.mono(
                        size: 12,
                        weight: FontWeight.w500,
                        color: now ? DM.signal : DM.mist,
                      ),
                    ),
            ),
            const SizedBox(width: DMSpace.xxs),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: DMType.outfit(
                  size: 14,
                  weight: now ? FontWeight.w600 : FontWeight.w500,
                  color: now
                      ? DM.bone
                      : done
                      ? DM.sub
                      : DM.mist,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// Bottom action bar of the editors: a 1px line above, void below.
class EditorBar extends StatelessWidget {
  const EditorBar({super.key, required this.child, this.color = DM.void_});

  final Widget child;
  final Color color;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: color,
      border: const Border(top: BorderSide(color: DM.line)),
    ),
    child: SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          DMSpace.gutter,
          DMSpace.md,
          DMSpace.gutter,
          DMSpace.lg,
        ),
        child: child,
      ),
    ),
  );
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
      appBar: AppBar(title: Text(title)),
      body: Column(
        children: [
          StepHeader(
            labels: steps,
            current: step,
            onTap: busy ? null : onStepTap,
          ),
          const Divider(height: 1),
          Expanded(
            // Not a lazy list: validation scrolls to fields and checkboxes
            // that may be far below the fold.
            child: SingleChildScrollView(
              key: ValueKey('step-$step'),
              controller: controller,
              padding: const EdgeInsets.fromLTRB(
                DMSpace.gutter,
                DMSpace.xl,
                DMSpace.gutter,
                DMSpace.xxxl,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: children,
              ),
            ),
          ),
        ],
      ),
      bottomNavigationBar: EditorBar(
        child: Row(
          children: [
            if (onBack != null) ...[
              Expanded(
                flex: 2,
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(56),
                  ),
                  onPressed: busy ? null : onBack,
                  child: const Text('Back'),
                ),
              ),
              const SizedBox(width: DMSpace.md),
            ],
            Expanded(
              flex: 3,
              child: FilledButton(
                onPressed: busy ? null : onPrimary,
                child: busy
                    ? const SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: DM.signal,
                        ),
                      )
                    : Text(primaryLabel, textAlign: TextAlign.center),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// The lead line under a step's header: one sentence in sub.
class StepLead extends StatelessWidget {
  const StepLead(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: DMSpace.lg),
    child: Text(
      text,
      style: DMType.outfit(size: 15, color: DM.sub, height: 1.45),
    ),
  );
}

/// The first-run block of a list: a title, one line and an add button.
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
  Widget build(BuildContext context) => DMCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: DMSpace.xs),
        Text(body, style: DMType.outfit(size: 15, color: DM.sub, height: 1.45)),
        const SizedBox(height: DMSpace.lg),
        FilledButton.icon(
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
          onPressed: onAdd,
          icon: const Icon(Icons.add),
          label: Text(addLabel),
        ),
      ],
    ),
  );
}

/// The "+ Add a payout" row under a list: a text action in signal.
class AddRowButton extends StatelessWidget {
  const AddRowButton({super.key, required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => OutlinedButton.icon(
    onPressed: onTap,
    style: OutlinedButton.styleFrom(
      foregroundColor: DM.signal,
      backgroundColor: Colors.transparent,
    ),
    icon: const Icon(Icons.add),
    label: Text(label),
  );
}

/// A small field-group label: "Which money", "How it arrives".
class FieldLabel extends StatelessWidget {
  const FieldLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: DMSpace.sm),
    child: Text(
      text,
      style: DMType.outfit(size: 14, weight: FontWeight.w600, color: DM.sub),
    ),
  );
}

/// The step number of a section or review row: mono digit on a raised
/// square.
class StepNumber extends StatelessWidget {
  const StepNumber(this.number, {super.key, this.active = false});

  final int number;
  final bool active;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: SizedBox.square(
      dimension: 26,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: active ? DM.deep : DM.raise,
          borderRadius: BorderRadius.circular(DMRadius.chip),
        ),
        child: Center(
          child: Text(
            '$number',
            textScaler: TextScaler.noScaling,
            style: DMType.mono(
              size: 12,
              weight: FontWeight.w500,
              color: active ? DM.signal : DM.sub,
            ),
          ),
        ),
      ),
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
  Widget build(BuildContext context) => DMCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (title != null) ...[
          Row(
            children: [
              if (number != null) ...[
                StepNumber(number!),
                const SizedBox(width: DMSpace.md),
              ],
              Expanded(
                child: Semantics(
                  header: true,
                  child: Text(
                    title!,
                    style: Theme.of(context).textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
              ),
              ?trailing,
            ],
          ),
          const SizedBox(height: DMSpace.lg),
        ],
        ...children,
      ],
    ),
  );
}

Color severityColor(Severity s) => switch (s) {
  Severity.error || Severity.danger => DM.due,
  Severity.warn => DM.attention,
  Severity.info => DM.sub,
};

IconData severityIcon(Severity s) => switch (s) {
  Severity.error || Severity.danger => Icons.error_outline,
  Severity.warn => Icons.warning_amber_rounded,
  Severity.info => Icons.info_outline,
};

/// One warning: a status icon, title, body and an optional fix. The block
/// is a flat raised fill (no border, so it never reads as a nested card);
/// only the icon and title carry the status color.
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
    final hasAction = actionLabel != null && onAction != null;
    return Semantics(
      liveRegion: true,
      child: Container(
        width: double.infinity,
        margin: const EdgeInsets.only(top: DMSpace.md),
        padding: EdgeInsets.fromLTRB(
          DMSpace.md,
          DMSpace.md,
          DMSpace.md,
          hasAction ? DMSpace.xxs : DMSpace.md,
        ),
        decoration: BoxDecoration(
          color: DM.raise,
          borderRadius: BorderRadius.circular(DMRadius.tile),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child: Icon(severityIcon(severity), color: color, size: 18),
            ),
            const SizedBox(width: DMSpace.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (title.isNotEmpty) ...[
                    Text(
                      title,
                      style: DMType.outfit(
                        size: 15,
                        weight: FontWeight.w600,
                        color: severity == Severity.info ? DM.bone : color,
                      ),
                    ),
                    const SizedBox(height: 2),
                  ],
                  Text(
                    body,
                    style: DMType.outfit(
                      size: 14,
                      color: title.isEmpty ? DM.bone : DM.sub,
                      height: 1.4,
                    ),
                  ),
                  if (hasAction)
                    TextButton(
                      style: TextButton.styleFrom(
                        padding: EdgeInsets.zero,
                        minimumSize: const Size(48, 44),
                        tapTargetSize: MaterialTapTargetSize.padded,
                        textStyle: DMType.outfit(
                          size: 14,
                          weight: FontWeight.w600,
                        ),
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

/// A one-line warning: status icon and its headline.
class IssueLine extends StatelessWidget {
  const IssueLine(this.issue, {super.key});

  final PlanIssue issue;

  @override
  Widget build(BuildContext context) {
    final color = severityColor(issue.severity);
    return Row(
      children: [
        Icon(severityIcon(issue.severity), size: 16, color: color),
        const SizedBox(width: DMSpace.sm),
        Expanded(
          child: Text(
            issue.headline,
            style: DMType.outfit(
              size: 14,
              weight: FontWeight.w500,
              color: issue.severity == Severity.info ? DM.sub : color,
            ),
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

/// One row of the rail picker: icon tile, name, what it means, its fee in
/// mono on the right. The selected row sits on deep with a signal radio.
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
    padding: const EdgeInsets.only(bottom: DMSpace.sm),
    child: Semantics(
      inMutuallyExclusiveGroup: true,
      checked: selected,
      button: true,
      child: Material(
        color: selected ? DM.deep : DM.graphite,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(DMRadius.button),
          side: BorderSide(color: selected ? DM.tide : DM.line),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 64),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                DMSpace.md,
                DMSpace.md,
                DMSpace.md,
                DMSpace.md,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  IconTile(icon: rail.icon, size: 34),
                  const SizedBox(width: DMSpace.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Wrap(
                          spacing: DMSpace.sm,
                          runSpacing: DMSpace.xxs,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Text(
                              railTitle(rail),
                              style: DMType.outfit(
                                size: 16,
                                weight: FontWeight.w600,
                              ),
                            ),
                            if (badge != null)
                              DecoratedBox(
                                decoration: BoxDecoration(
                                  border: Border.all(color: DM.line),
                                  borderRadius: BorderRadius.circular(
                                    DMRadius.chip,
                                  ),
                                ),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: DMSpace.xs,
                                    vertical: 2,
                                  ),
                                  child: Text(
                                    badge!,
                                    style: DMType.mono(
                                      size: 11,
                                      color: DM.sub,
                                      spacing: 0.4,
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: DMSpace.xxs),
                        Text(
                          railHelper(rail),
                          style: DMType.outfit(
                            size: 13.5,
                            color: DM.sub,
                            height: 1.35,
                          ),
                        ),
                        const SizedBox(height: DMSpace.xs),
                        Text(
                          feeLine,
                          style: DMType.mono(
                            size: 12,
                            color: selected ? DM.bone : DM.sub,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: DMSpace.sm),
                  Icon(
                    selected
                        ? Icons.radio_button_checked
                        : Icons.radio_button_off,
                    color: selected ? DM.signal : DM.mist,
                    size: 22,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

/// A small outlined rail tag for cards: "⚡ Normal".
class RailChip extends StatelessWidget {
  const RailChip(this.rail, {super.key});

  final Rail rail;

  @override
  Widget build(BuildContext context) =>
      DMTag(label: railShort(rail), icon: rail.icon);
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
  Widget build(BuildContext context) => DMCard(
    padding: const EdgeInsets.fromLTRB(
      DMSpace.cardPadding,
      DMSpace.md,
      DMSpace.sm,
      DMSpace.cardPadding,
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 44),
          child: Row(
            children: [
              Expanded(
                child: Semantics(
                  header: true,
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
              ),
              if (onEdit != null)
                TextButton(onPressed: onEdit, child: const Text('Edit')),
            ],
          ),
        ),
        const SizedBox(height: DMSpace.xs),
        Padding(
          padding: const EdgeInsets.only(right: DMSpace.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: children,
          ),
        ),
      ],
    ),
  );
}

/// A label on the left, its value on the right; both wrap at large text.
/// [mono] sets the value in JetBrains Mono (amounts and balances).
class CostRow extends StatelessWidget {
  const CostRow(this.label, this.value, {super.key, this.mono = false});

  final String label;
  final String value;
  final bool mono;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: DMSpace.sm),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          flex: 2,
          child: Text(label, style: DMType.outfit(size: 14, color: DM.sub)),
        ),
        const SizedBox(width: DMSpace.md),
        Expanded(
          flex: 3,
          child: Text(
            value,
            textAlign: TextAlign.end,
            style: mono
                ? DMType.mono(size: 13.5, height: 1.45)
                : DMType.outfit(size: 14, height: 1.4),
          ),
        ),
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
        child: Text.rich(text, style: DMType.outfit(size: 15, height: 1.4)),
      ),
      if (issue != null)
        InkWell(
          borderRadius: BorderRadius.circular(DMRadius.chip),
          onTap: onIssue,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 44),
            child: Row(
              children: [
                Expanded(child: IssueLine(issue!)),
                const Icon(Icons.chevron_right, color: DM.mist, size: 20),
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
    final stroke = Paint()
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(
      const Offset(pad, y),
      Offset(size.width - pad, y),
      stroke..color = DM.track,
    );
    canvas.drawLine(
      const Offset(pad, y),
      Offset(x(delay), y),
      stroke..color = DM.tide,
    );
    canvas.drawCircle(const Offset(pad, y), 4, Paint()..color = DM.sub);
    final tick = x(interval);
    canvas.drawLine(
      Offset(tick, y - 7),
      Offset(tick, y + 7),
      Paint()
        ..color = DM.attention
        ..strokeWidth = 2,
    );
    canvas.drawCircle(Offset(x(delay), y), 6, Paint()..color = DM.signal);
    canvas.drawCircle(Offset(x(delay), y), 2.5, Paint()..color = DM.void_);
  }

  @override
  bool shouldRepaint(_StripPainter old) =>
      old.interval != interval || old.delay != delay;
}

/// One node of a vertical timeline; [label] is a time ("After 10 days of
/// silence") and reads in mono.
class TimelineEntry extends StatelessWidget {
  const TimelineEntry({
    super.key,
    required this.label,
    this.child,
    this.dot = DM.line,
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
        margin: const EdgeInsets.only(left: 5),
        padding: const EdgeInsets.fromLTRB(DMSpace.lg + 2, 0, 0, DMSpace.lg),
        decoration: last
            ? null
            : const BoxDecoration(
                border: Border(left: BorderSide(color: DM.line)),
              ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (label.isNotEmpty)
              Text(label, style: DMType.mono(size: 12.5, color: DM.sub)),
            if (child != null) ...[
              if (label.isNotEmpty) const SizedBox(height: DMSpace.sm),
              child!,
            ],
          ],
        ),
      ),
      Positioned(
        left: 1,
        top: 4,
        child: SizedBox.square(
          dimension: 9,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: dot,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
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
          title: Text(label, style: DMType.outfit(size: 15, height: 1.4)),
        ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.only(left: DMSpace.xxs),
            child: Text(
              error!,
              style: DMType.outfit(size: 13.5, color: DM.due),
            ),
          ),
      ],
    ),
  );

  static double _wave(double t) => (t * 6).floor().isEven ? 1 : -1;
}

/// A [ChoiceChip] in the editor's language: the selected chip sits on deep
/// with a signal label. [mono] sets durations and amounts in mono.
ChoiceChip pickChip({
  Key? key,
  required String label,
  required bool selected,
  required ValueChanged<bool>? onSelected,
  Widget? avatar,
  bool mono = false,
}) {
  final color = onSelected == null
      ? DM.mist
      : selected
      ? DM.signal
      : DM.bone;
  return ChoiceChip(
    key: key,
    label: Text(label),
    selected: selected,
    onSelected: onSelected,
    avatar: avatar,
    showCheckmark: false,
    materialTapTargetSize: MaterialTapTargetSize.padded,
    side: BorderSide(color: selected ? DM.tide : DM.line),
    labelStyle: mono
        ? DMType.mono(size: 13, weight: FontWeight.w500, color: color)
        : DMType.outfit(size: 14, weight: FontWeight.w500, color: color),
  );
}
