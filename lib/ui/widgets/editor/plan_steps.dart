import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../solana/codec.dart' show Limits;
import '../../../solana/deadman_api.dart';
import '../../../state/plan_draft.dart';
import '../../rules_format.dart';
import '../brand/brand.dart';

/// Glyphs for the editors' sections, drawn on the pixel cast's 11-cell
/// grid (docs/brand/v2, page 9): the heart (from the cast) marks who gets
/// it, these mark what and when.
abstract final class EditorSprites {
  /// "What they get": a coin.
  static const coin = PixelSprite('coin', [
    '...#####...',
    '.#########.',
    '.##.....##.',
    '##.#####.##',
    '##.#####.##',
    '##.#####.##',
    '##.#####.##',
    '##.#####.##',
    '.##.....##.',
    '.#########.',
    '...#####...',
  ]);

  /// "Timing": an hourglass, sand still on top.
  static const hourglass = PixelSprite('hourglass', [
    '###########',
    '.#########.',
    '..#######..',
    '...#####...',
    '....###....',
    '.....#.....',
    '....#.#....',
    '...#...#...',
    '..#..#..#..',
    '.#..###..#.',
    '###########',
  ]);
}

/// "STEP 1/3": where an editor sits in its plan's steps, as a sticker.
class StepSticker extends StatelessWidget {
  const StepSticker({super.key, required this.step, required this.of});

  /// 1-based.
  final int step;
  final int of;

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Step $step of $of',
    excludeSemantics: true,
    // A sticker is a short pixel word; past 1.3x it would push the title
    // out of the app bar. The step is in the semantics label in full.
    child: MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.3,
      child: Sticker('Step $step/$of'),
    ),
  );
}

/// Step progress: one square-ended segment per step (pulse up to the
/// current one) over the step's name. Done steps carry a check and can be
/// tapped to go back.
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
  const _StepCell({required this.label, required this.done, required this.now});

  final String label;
  final bool done;
  final bool now;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      SizedBox(
        height: 4,
        width: double.infinity,
        child: ColoredBox(color: done || now ? DM.pulse : DM.line),
      ),
      const SizedBox(height: DMSpace.sm),
      Row(
        children: [
          if (done) ...[
            const Icon(Icons.check, size: 14, color: DM.pulse),
            const SizedBox(width: DMSpace.xxs),
          ],
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
                    ? DM.dust
                    : DM.ash,
              ),
            ),
          ),
        ],
      ),
    ],
  );
}

/// Bottom action bar of the editors: a 1px line above, void below.
class EditorBar extends StatelessWidget {
  const EditorBar({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: const BoxDecoration(
      color: DM.void_,
      border: Border(top: BorderSide(color: DM.line)),
    ),
    child: SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          DMSpace.gutter,
          DMSpace.lg,
          DMSpace.gutter,
          DMSpace.lg,
        ),
        child: child,
      ),
    ),
  );
}

/// The editors' app bar: close or back, the title, optional [actions] and
/// the step sticker, over a 1px line.
PreferredSizeWidget editorAppBar({
  required String title,
  required int step,
  required int steps,
  Widget? leading,
  List<Widget> actions = const [],
}) => AppBar(
  leading: leading,
  title: Text(title),
  titleSpacing: leading == null ? null : 0,
  actions: [
    ...actions,
    Padding(
      padding: const EdgeInsets.only(left: DMSpace.xs, right: DMSpace.gutter),
      child: Center(
        child: StepSticker(step: step, of: steps),
      ),
    ),
  ],
  bottom: const PreferredSize(
    preferredSize: Size.fromHeight(1),
    child: Divider(height: 1),
  ),
);

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
        title: Text(title),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: DMSpace.gutter),
            child: Center(
              child: StepSticker(step: step + 1, of: steps.length),
            ),
          ),
        ],
      ),
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
                          color: DM.ash,
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

/// One section of a payout or schedule editor, on the ground rather than in
/// a card: a pixel figure in pulse, the title, then its fields. Sections
/// after the first sit under a full-width line.
class EditorSection extends StatelessWidget {
  const EditorSection({
    super.key,
    required this.sprite,
    required this.title,
    required this.children,
    this.first = false,
  });

  final PixelSprite sprite;
  final String title;
  final List<Widget> children;
  final bool first;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (!first) ...[
        const SizedBox(height: DMSpace.xxxl),
        const Divider(height: 1),
        const SizedBox(height: DMSpace.xxl),
      ],
      Row(
        children: [
          // Two-point cells for every figure, so heart, coin and
          // tombstone share one pixel size whatever their row count.
          PixelArt(sprite, size: sprite.height * 2.0, color: DM.pulse),
          const SizedBox(width: DMSpace.md),
          Expanded(
            child: Semantics(
              header: true,
              child: Text(title, style: Theme.of(context).textTheme.titleLarge),
            ),
          ),
        ],
      ),
      const SizedBox(height: DMSpace.xl),
      ...children,
    ],
  );
}

/// A field with its label above it, as on the payout mockup ("Wallet
/// address or claim code" over the input). Screen readers get the label
/// on the input itself, not as a separate line before it.
class LabeledField extends StatelessWidget {
  const LabeledField({super.key, required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    mainAxisSize: MainAxisSize.min,
    children: [
      Padding(
        padding: const EdgeInsets.only(bottom: DMSpace.sm),
        child: ExcludeSemantics(
          child: Text(
            label,
            style: DMType.outfit(
              size: 15,
              weight: FontWeight.w500,
              color: DM.dust,
            ),
          ),
        ),
      ),
      Semantics(label: label, child: child),
    ],
  );
}

/// The lead line under a step's header: one sentence in dust.
class StepLead extends StatelessWidget {
  const StepLead(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: DMSpace.lg),
    child: Text(
      text,
      style: DMType.outfit(size: 15, color: DM.dust, height: 1.45),
    ),
  );
}

/// The first-run block of a list: a pixel figure (a [sprite], or a pack
/// [icon] such as the heartbeat), a title, one line and an add button.
/// The add button is outlined: the screen's one filled button is Next in
/// the bar below.
class EmptyStateCard extends StatelessWidget {
  const EmptyStateCard({
    super.key,
    this.sprite,
    this.icon,
    required this.title,
    required this.body,
    required this.addLabel,
    required this.onAdd,
  }) : assert((sprite == null) != (icon == null));

  final PixelSprite? sprite;
  final DMIcons? icon;
  final String title;
  final String body;
  final String addLabel;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) => DMCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: switch (icon) {
            final icon? => DMIcon(icon, size: 48, color: DM.pulse),
            null => PixelArt(sprite!, size: 40, color: DM.pulse),
          },
        ),
        const SizedBox(height: DMSpace.lg),
        Text(title, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: DMSpace.xs),
        Text(
          body,
          style: DMType.outfit(size: 15, color: DM.dust, height: 1.45),
        ),
        const SizedBox(height: DMSpace.lg),
        AddRowButton(label: addLabel, onTap: onAdd),
      ],
    ),
  );
}

/// The "+ Add a payout" button under a list: outlined, pulse label.
class AddRowButton extends StatelessWidget {
  const AddRowButton({super.key, required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => OutlinedButton.icon(
    onPressed: onTap,
    style: OutlinedButton.styleFrom(foregroundColor: DM.pulse),
    icon: const DMIcon(DMIcons.plus),
    label: Text(label),
  );
}

/// A field-group label: "Which money", "How it arrives".
class FieldLabel extends StatelessWidget {
  const FieldLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: DMSpace.md),
    child: Text(
      text,
      style: DMType.outfit(size: 16, weight: FontWeight.w600, color: DM.haze),
    ),
  );
}

/// The number of a review row: mono digit on a raised square.
class StepNumber extends StatelessWidget {
  const StepNumber(this.number, {super.key});

  final int number;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: SizedBox.square(
      dimension: 26,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: DM.raise,
          borderRadius: BorderRadius.circular(DMRadius.chip),
        ),
        child: Center(
          child: Text(
            '$number',
            textScaler: TextScaler.noScaling,
            style: DMType.mono(
              size: 12,
              weight: FontWeight.w500,
              color: DM.dust,
            ),
          ),
        ),
      ),
    ),
  );
}

/// A card with an optional title ("Plan").
class SectionCard extends StatelessWidget {
  const SectionCard({
    super.key,
    this.title,
    this.trailing,
    required this.children,
  });

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

/// Amber for what may go wrong, flatline for what will: the book's
/// Missed ("Warning") and Flatline. Info stays neutral.
Color severityColor(Severity s) => switch (s) {
  Severity.error || Severity.danger => DM.flatline,
  Severity.warn => DM.missed,
  Severity.info => DM.dust,
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
                      color: title.isEmpty ? DM.bone : DM.dust,
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
              color: issue.severity == Severity.info ? DM.dust : color,
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

/// The fee line of a rail card for a payout of [mint], from the on-chain
/// FeeSchedule: "2% fee", or "1.5% fee · 10% burned" for SKR.
String railFeeLine(FeeInfo fee, Rail rail, [String? mint]) =>
    fee.railLine(rail, mint);

/// One radio card of the rail picker ("How it arrives"): the rail's icon,
/// name, what it means and its fee in mono.
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

  /// "mainnet only".
  final String? badge;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: DMSpace.md),
    child: SelectCard(
      selected: selected,
      title: railTitle(rail),
      icon: rail.icon,
      body: railHelper(rail),
      footnote: feeLine,
      tag: badge == null ? null : DMTag(label: badge!, mono: true),
      onTap: onTap,
    ),
  );
}

/// A small outlined rail tag for cards: "Normal" with its icon.
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
          child: Text(label, style: DMType.outfit(size: 14, color: DM.dust)),
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
        child: Text.rich(
          text,
          style: DMType.outfit(size: 16, color: DM.haze, height: 1.45),
        ),
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
                const DMIcon(DMIcons.chevronRight, color: DM.ash),
              ],
            ),
          ),
        ),
    ],
  );
}

/// The payout's wait laid out as the Pulse ring's ticks, flat: pulse while
/// the clock runs from the last check-in, a tall flatline tick where this
/// payout is sent, dim after. The sent tick sits on a log scale from a
/// minute to 3 years. Decorative; the sentence under it says the same in
/// words.
class DelayStrip extends StatelessWidget {
  const DelayStrip({super.key, required this.delaySecs});

  final int delaySecs;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: SizedBox(
      height: 32,
      width: double.infinity,
      child: CustomPaint(
        painter: _StripPainter(
          delaySecs,
          MediaQuery.maybeDevicePixelRatioOf(context) ?? 1,
        ),
      ),
    ),
  );
}

class _StripPainter extends CustomPainter {
  _StripPainter(this.delay, this.dpr);

  final int delay;
  final double dpr;

  /// Snaps to whole device pixels, like the ring and the pixel figures.
  double _px(double v) => (v * dpr).roundToDouble() / dpr;

  @override
  void paint(Canvas canvas, Size size) {
    const slot = 8.0;
    final n = (size.width / slot).floor();
    if (n < 2) return;
    final step = size.width / n;
    final tick = _px(step * 0.62);
    final f =
        math.log(math.max(delay, 60) / 60) /
        math.log(Limits.maxRuleDelaySecs / 60);
    final sent = (f.clamp(0.0, 1.0) * (n - 1)).round().clamp(1, n - 1);
    final paint = Paint()..isAntiAlias = false;
    for (var i = 0; i < n; i++) {
      final x = _px(i * step);
      final isSent = i == sent;
      paint.color = isSent
          ? DM.flatline
          : i > sent
          ? DM.line
          : DM.pulse;
      final h = isSent ? size.height : 12.0;
      canvas.drawRect(
        Rect.fromLTWH(x, _px((size.height - h) / 2), tick, h),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_StripPainter old) => old.delay != delay || old.dpr != dpr;
}

/// One node of a vertical timeline; [label] is a time ("Sent 10 days after
/// your last check-in") and reads in mono. [marker] replaces the square dot, e.g. with
/// the pixel heart on "Last check-in".
class TimelineEntry extends StatelessWidget {
  const TimelineEntry({
    super.key,
    required this.label,
    this.child,
    this.dot = DM.line,
    this.marker,
    this.last = false,
  });

  final String label;
  final Widget? child;
  final Color dot;
  final Widget? marker;
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
              Text(label, style: DMType.mono(size: 12.5, color: DM.dust)),
            if (child != null) ...[
              if (label.isNotEmpty) const SizedBox(height: DMSpace.sm),
              child!,
            ],
          ],
        ),
      ),
      Positioned(
        left: marker == null ? 1 : 0,
        top: marker == null ? 4 : 2,
        child:
            marker ??
            SizedBox.square(dimension: 9, child: ColoredBox(color: dot)),
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
    // No shake with reduced motion; the error line below still shows.
    tween: Tween(
      begin: shake == 0 || MediaQuery.disableAnimationsOf(context) ? 1 : 0,
      end: 1,
    ),
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
              style: DMType.outfit(size: 13.5, color: DM.flatline),
            ),
          ),
      ],
    ),
  );

  static double _wave(double t) => (t * 6).floor().isEven ? 1 : -1;
}

/// A [ChoiceChip] in the editor's language: the selected chip sits on deep
/// with a pulse label and border. [mono] sets durations and amounts in
/// mono.
ChoiceChip pickChip({
  Key? key,
  required String label,
  required bool selected,
  required ValueChanged<bool>? onSelected,
  Widget? avatar,
  bool mono = false,
}) {
  final color = onSelected == null
      ? DM.ash
      : selected
      ? DM.pulse
      : DM.bone;
  return ChoiceChip(
    key: key,
    label: Text(label),
    selected: selected,
    onSelected: onSelected,
    avatar: avatar,
    showCheckmark: false,
    materialTapTargetSize: MaterialTapTargetSize.padded,
    side: BorderSide(color: selected ? DM.pulse : DM.line),
    labelStyle: mono
        ? DMType.mono(size: 13, weight: FontWeight.w500, color: color)
        : DMType.outfit(size: 14, weight: FontWeight.w500, color: color),
  );
}
