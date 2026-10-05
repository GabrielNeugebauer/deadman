import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../solana/deadman_api.dart';
import '../../../state/assets.dart';
import '../../../state/plan_draft.dart';
import '../../../state/plan_math.dart' show percentText;
import '../../../state/providers.dart';
import '../../../state/vesting.dart';
import '../../format.dart';
import '../../widgets/brand/brand.dart';
import '../../widgets/editor/asset_chips.dart';
import '../../widgets/editor/plan_steps.dart';
import '../../widgets/vesting_progress.dart';
import 'editor_providers.dart';
import 'payout_editor.dart' show confirmDiscard;
import 'recipient_section.dart';

const vestAssets = [solAsset, usdcAsset];

/// What the schedule editor returns: a saved draft, or a removal.
class ScheduleEdit {
  const ScheduleEdit.save(ScheduleDraft this.draft);
  const ScheduleEdit.remove() : draft = null;

  final ScheduleDraft? draft;
}

/// [s] as a fixed payout of its whole total, for the delivery checks.
PayoutDraft scheduleAsPayout(ScheduleDraft s) => PayoutDraft(
  beneficiary: s.beneficiary,
  rail: s.rail,
  mint: s.mint,
  mode: AmountMode.fixed,
  fixedAmount: s.total,
  afterSecs: 0,
  name: s.name,
);

/// A synthetic progress of [total] at [vested], for previews.
ScheduleProgress previewProgress({
  required int total,
  required int vested,
  required int startAt,
  required int cliffSecs,
  required int durationSecs,
}) => ScheduleProgress(
  total: total,
  cap: total,
  vested: vested,
  released: 0,
  claimable: 0,
  startAt: startAt,
  cliffAt: startAt + cliffSecs,
  endAt: startAt + durationSecs,
  revokedAt: 0,
);

/// Full-screen editor for one vesting schedule.
class ScheduleEditorPage extends ConsumerStatefulWidget {
  const ScheduleEditorPage({
    super.key,
    this.initial,
    required this.number,
    required this.demo,
    required this.startAt,
    this.periodSecs = 0,
    this.step = 1,
    this.steps = 3,
  });

  final ScheduleDraft? initial;
  final int number;
  final bool demo;

  /// The plan's installment interval (0 = continuous): durations shorter
  /// than one installment are not offered.
  final int periodSecs;

  /// When the plan starts (unix seconds), for the milestones.
  final int startAt;

  /// Where the plan editor that opened this is: "STEP 1/3".
  final int step;
  final int steps;

  @override
  ConsumerState<ScheduleEditorPage> createState() => _ScheduleEditorState();
}

class _ScheduleEditorState extends ConsumerState<ScheduleEditorPage> {
  late final ScheduleDraft? _init = widget.initial;
  late final _who = Recipient(
    address: _init?.beneficiary ?? '',
    name: _init?.name ?? '',
    rail: _init?.rail ?? Rail.solana,
  );
  late String? _mint = _init == null ? usdcAsset.mint : _init.mint;
  late final _total = TextEditingController(
    text: _init == null ? '' : amountInput(_init.total, _init.mint),
  );
  late int _cliff = _init?.cliffSecs ?? 0;
  late int _duration = _init?.durationSecs ?? _defaultDuration;
  late String? _factsAddress = _who.valid ? _who.value : null;
  final _totalFocus = FocusNode();
  final _whoKey = GlobalKey();
  final _whatKey = GlobalKey();
  Timer? _debounce;
  bool _showErrors = false;
  bool _dirty = false;

  @override
  void dispose() {
    _debounce?.cancel();
    _who.dispose();
    _total.dispose();
    _totalFocus.dispose();
    super.dispose();
  }

  int get _defaultDuration {
    final fits = durationChoices(demo: widget.demo)
        .map((c) => c.$1)
        .where((d) => d >= widget.periodSecs);
    return fits.contains(12 * monthSecs) ? 12 * monthSecs : fits.first;
  }

  int? get _totalValue {
    final v = parseAmount(_total.text, _mint);
    return v == null || v <= 0 ? null : v;
  }

  String? get _totalError {
    final v = _totalValue;
    if (v == null) return 'Enter the total in ${unitLabel(_mint)}.';
    if (_mint == null && v < 1000000) {
      return 'SOL schedules must be at least 0.001 SOL.';
    }
    return null;
  }

  ScheduleDraft get _draft => ScheduleDraft(
    beneficiary: _who.value,
    rail: _who.rail,
    mint: _mint,
    total: _totalValue ?? 0,
    cliffSecs: _cliff,
    durationSecs: _duration,
    name: _who.name.text.trim(),
  );

  void _changed() => setState(() => _dirty = true);

  void _addressChanged() {
    _debounce?.cancel();
    final address = _who.value;
    if (_who.valid) {
      if (_who.name.text.isEmpty) {
        _who.name.text = ref.read(contactNamesProvider).get(address);
      }
      _debounce = Timer(const Duration(milliseconds: 400), () {
        if (mounted) setState(() => _factsAddress = address);
      });
    } else {
      _factsAddress = null;
    }
    _changed();
  }

  Future<void> _cancel() async {
    if (_dirty &&
        !await confirmDiscard(
          context,
          title: 'Discard your changes?',
          body: "This schedule won't be saved.",
        )) {
      return;
    }
    if (mounted) Navigator.pop(context);
  }

  void _done() {
    final whoBad = !_who.valid || _who.value == ref.read(sessionProvider).owner;
    if (whoBad || _totalError != null) {
      setState(() => _showErrors = true);
      final c = (whoBad ? _whoKey : _whatKey).currentContext;
      if (c != null) Scrollable.ensureVisible(c, alignment: 0.05);
      return;
    }
    final d = _draft;
    ref.read(contactNamesProvider).set(d.beneficiary, d.name);
    Navigator.pop(context, ScheduleEdit.save(d));
  }

  @override
  Widget build(BuildContext context) {
    final fee = watchFeeInfo(ref);
    final owner = ref.watch(sessionProvider.select((s) => s.owner));
    final d = _draft;
    final facts = _factsAddress == null
        ? null
        : ref.watch(beneficiaryFactsProvider((_factsAddress!, _mint)));
    final total = _totalValue;
    final warnings = bySeverity([
      if (owner != null && _who.value == owner)
        const PlanIssue(
          IssueCode.b1,
          Severity.error,
          title: "That's your own wallet",
          body:
              "A plan can't pay its owner. Use the address of the person "
              'who should receive it.',
        ),
      ...deliveryIssues(
        p: scheduleAsPayout(d),
        gross: total,
        feeBps: fee.bpsFor(_who.rail),
        facts: facts?.value,
      ),
    ]);
    final cliffs = cliffChoices(demo: widget.demo);
    final durations = durationChoices(demo: widget.demo);
    final period = widget.periodSecs;
    final tooShort = durations.where((c) => c.$1 < period).isNotEmpty;
    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _cancel();
      },
      child: Scaffold(
        appBar: editorAppBar(
          leading: IconButton(
            tooltip: 'Cancel',
            icon: const Icon(Icons.close),
            onPressed: _cancel,
          ),
          title: _init == null ? 'New schedule' : 'Schedule ${widget.number}',
          step: widget.step,
          steps: widget.steps,
          actions: [
            if (_init != null)
              TextButton(
                onPressed: () =>
                    Navigator.pop(context, const ScheduleEdit.remove()),
                child: const Text('Remove'),
              ),
          ],
        ),
        body: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(
            DMSpace.gutter,
            DMSpace.xxl,
            DMSpace.gutter,
            DMSpace.xxxl,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              RecipientSection(
                key: _whoKey,
                recipient: _who,
                onChanged: _addressChanged,
                fee: fee,
                privateLive: ref.watch(privateRailsLiveProvider),
                error: _showErrors ? addressError(_who.value)?.body : null,
                loading: facts?.isLoading ?? false,
                notice: warnings
                    .where((w) => w.code == IssueCode.b1)
                    .firstOrNull,
              ),
              EditorSection(
                key: _whatKey,
                sprite: EditorSprites.coin,
                title: 'How much',
                children: [
                  const FieldLabel('Which money'),
                  AssetChips(
                    mint: _mint,
                    assets: vestAssets,
                    allowOther: false,
                    onChanged: (m) => setState(() {
                      _mint = m;
                      _dirty = true;
                    }),
                  ),
                  const SizedBox(height: DMSpace.xl),
                  LabeledField(
                    label: 'Total',
                    child: TextField(
                      key: const ValueKey('vest-total'),
                      controller: _total,
                      focusNode: _totalFocus,
                      onChanged: (_) => _changed(),
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      style: DMType.mono(size: 18, weight: FontWeight.w500),
                      decoration: InputDecoration(
                        hintText: '0',
                        hintStyle: DMType.mono(size: 18, color: DM.ash),
                        suffixText: unitLabel(_mint),
                        suffixStyle: DMType.mono(size: 14, color: DM.dust),
                        errorText: _showErrors ? _totalError : null,
                      ),
                    ),
                  ),
                  for (final w in warnings)
                    if (w.code != IssueCode.b1)
                      WarningTile.of(
                        w,
                        onAction: w.action == null
                            ? null
                            : _totalFocus.requestFocus,
                      ),
                ],
              ),
              EditorSection(
                sprite: EditorSprites.hourglass,
                title: 'Timing',
                children: [
                  const FieldLabel('Nothing unlocks for'),
                  Wrap(
                    spacing: DMSpace.sm,
                    runSpacing: DMSpace.xxs,
                    children: [
                      for (final (secs, text) in cliffs)
                        pickChip(
                          label: text,
                          mono: true,
                          selected: _cliff == secs,
                          onSelected: secs > _duration
                              ? null
                              : (_) => setState(() {
                                  _cliff = secs;
                                  _dirty = true;
                                }),
                        ),
                    ],
                  ),
                  const SizedBox(height: DMSpace.lg),
                  const FieldLabel('Fully unlocked after'),
                  Wrap(
                    spacing: DMSpace.sm,
                    runSpacing: DMSpace.xxs,
                    children: [
                      for (final (secs, text) in durations)
                        pickChip(
                          label: text,
                          mono: true,
                          selected: _duration == secs,
                          onSelected: secs < period
                              ? null
                              : (_) => setState(() {
                                  _duration = secs;
                                  if (_cliff > secs) _cliff = 0;
                                  _dirty = true;
                                }),
                        ),
                    ],
                  ),
                  if (tooShort) ...[
                    const SizedBox(height: DMSpace.sm),
                    Text(
                      'This plan releases one installment every '
                      '${vestPeriodWord(period)}, so a schedule must last at '
                      'least that long. For shorter ones, change "Release '
                      'every" on the plan.',
                      style: DMType.outfit(
                        size: 13.5,
                        color: DM.dust,
                        height: 1.4,
                      ),
                    ),
                  ],
                  const SizedBox(height: DMSpace.xxl),
                  const FieldLabel('How it unlocks'),
                  SchedulePreview(
                    draft: d,
                    startAt: widget.startAt,
                    periodSecs: period,
                  ),
                ],
              ),
            ],
          ),
        ),
        bottomNavigationBar: EditorBar(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              LivePreview(
                text: TextSpan(text: _previewLine(d, total, fee, period)),
                issue: worstOf(warnings),
                onIssue: () {
                  final c = _whatKey.currentContext;
                  if (c != null) Scrollable.ensureVisible(c);
                },
              ),
              const SizedBox(height: DMSpace.md),
              FilledButton(onPressed: _done, child: const Text('Done')),
            ],
          ),
        ),
      ),
    );
  }

  String _previewLine(ScheduleDraft d, int? total, FeeInfo fee, int period) {
    if (total == null) return 'Enter a total to see what they get.';
    final (net, _) = splitFee(total, fee.bpsFor(d.rail));
    final n = d.installments(periodSecs: period, startAt: widget.startAt);
    final over =
        '${moneyText(total, d.mint)} to ${d.who} over '
        '${durationLabel(d.durationSecs)}'
        '${n == null ? '' : ' in ${n.count} ${n.count == 1 ? 'installment' : 'installments'}'}';
    if (fee.waived) return '$over (no fee).';
    if (fee.fees == null) return '$over (before fees).';
    return '$over (after the ${percentText(fee.fees!.bpsFor(d.rail) / 10000)} '
        'fee: ≈ ${moneyText(net, d.mint)}).';
  }
}

/// How a schedule unlocks: a bar and its milestones; tapping a milestone
/// fills the bar to it.
class SchedulePreview extends StatefulWidget {
  const SchedulePreview({
    super.key,
    required this.draft,
    required this.startAt,
    this.periodSecs = 0,
  });

  final ScheduleDraft draft;
  final int startAt;

  /// The plan's installment interval; 0 = continuous.
  final int periodSecs;

  @override
  State<SchedulePreview> createState() => _SchedulePreviewState();
}

class _SchedulePreviewState extends State<SchedulePreview> {
  int _selected = 0;

  @override
  Widget build(BuildContext context) {
    final s = widget.draft;
    final start = widget.startAt;
    final total = s.total;
    final period = widget.periodSecs;
    final n = s.installments(periodSecs: period, startAt: start);
    final perMonth = n == null && s.durationSecs >= monthSecs
        ? (BigInt.from(total) *
                  BigInt.from(monthSecs) ~/
                  BigInt.from(s.durationSecs))
              .toInt()
        : null;
    String date(int at) => installmentDate(at, period);
    double at(int secs) => ((secs - start) / s.durationSecs).clamp(0.0, 1.0);
    final milestones = <(String, double)>[
      ('${date(start)}: ${moneyText(0, s.mint)}', 0),
      if (n != null) ...[
        if (n.firstAt < start + s.durationSecs)
          (
            n.firstCount > 1
                ? '${date(n.firstAt)}: the first ${n.firstCount} '
                      'installments unlock together, '
                      '${moneyText(n.firstAmount, s.mint)}'
                : '${date(n.firstAt)}: first installment, '
                      '${moneyText(n.firstAmount, s.mint)}',
            at(n.firstAt),
          ),
        if (n.firstAt + period < start + s.durationSecs)
          (
            'Then ${moneyText(n.amount, s.mint)} every '
                '${vestPeriodWord(period)}',
            at(n.firstAt + period),
          ),
      ] else ...[
        if (s.cliffSecs > 0)
          (
            '${dateText(start + s.cliffSecs)}: ${moneyText(s.atCliff, s.mint)} '
                'unlocks at once',
            s.cliffSecs / s.durationSecs,
          ),
        if (perMonth != null)
          (
            'Each month after: about ${moneyText(perMonth, s.mint)}',
            (s.cliffSecs + monthSecs).clamp(0, s.durationSecs) / s.durationSecs,
          ),
      ],
      ('${date(start + s.durationSecs)}: all ${moneyText(total, s.mint)}', 1),
    ];
    final selected = _selected.clamp(0, milestones.length - 1);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TweenAnimationBuilder<double>(
          tween: Tween(end: milestones[selected].$2),
          duration: MediaQuery.disableAnimationsOf(context)
              ? Duration.zero
              : const Duration(milliseconds: 400),
          builder: (context, f, _) => VestingBar(
            color: DM.pulse,
            progress: previewProgress(
              total: 1000,
              vested: (f * 1000).round(),
              startAt: start,
              cliffSecs: s.cliffSecs,
              durationSecs: s.durationSecs,
            ),
          ),
        ),
        const SizedBox(height: DMSpace.sm),
        for (final (i, (text, _)) in milestones.indexed)
          _Milestone(
            text: text,
            selected: i == selected,
            onTap: () => setState(() => _selected = i),
          ),
        const SizedBox(height: DMSpace.sm),
        Text(
          n == null
              ? 'Deadman sends what has unlocked about once a day. ${s.who} '
                    'can also claim it any time.'
              : 'Nothing can be claimed between installments. Deadman sends '
                    'each one within about a day of unlocking; ${s.who} can '
                    'also claim it as soon as it unlocks.',
          style: DMType.outfit(size: 14, color: DM.dust, height: 1.45),
        ),
      ],
    );
  }
}

/// One milestone of [SchedulePreview]: a square marker, the date in mono
/// and what unlocks then.
class _Milestone extends StatelessWidget {
  const _Milestone({
    required this.text,
    required this.selected,
    required this.onTap,
  });

  final String text;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // "Oct 4, 2026: first installment, 300 USDC" splits at the date.
    final cut = text.indexOf(': ');
    final color = selected ? DM.bone : DM.dust;
    final body = DMType.outfit(
      size: 14.5,
      color: color,
      weight: selected ? FontWeight.w600 : FontWeight.w400,
      height: 1.35,
    );
    return Semantics(
      selected: selected,
      button: true,
      child: InkWell(
        borderRadius: BorderRadius.circular(DMRadius.chip),
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 44),
          child: Row(
            children: [
              SizedBox.square(
                dimension: 8,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: selected ? DM.pulse : Colors.transparent,
                    border: Border.all(color: selected ? DM.pulse : DM.ash),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(width: DMSpace.md),
              Expanded(
                child: cut < 0
                    ? Text(text, style: body)
                    : Text.rich(
                        TextSpan(
                          children: [
                            TextSpan(
                              text: text.substring(0, cut + 1),
                              style: DMType.mono(size: 13, color: color),
                            ),
                            TextSpan(text: text.substring(cut + 1)),
                          ],
                        ),
                        style: body,
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Short date for vesting copy: "today" or "Oct 4, 2026".
String startText(int startAt, int now) =>
    startAt <= now + 60 ? 'today' : dateText(startAt);
