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
import '../../rules_format.dart';
import '../../theme.dart';
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
  });

  final ScheduleDraft? initial;
  final int number;
  final bool demo;

  /// When the plan starts (unix seconds), for the milestones.
  final int startAt;

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
  late int _duration = _init?.durationSecs ?? 12 * monthSecs;
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
    const label = TextStyle(color: DmColors.muted, fontWeight: FontWeight.w600);
    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _cancel();
      },
      child: Scaffold(
        appBar: AppBar(
          backgroundColor: DmColors.bg,
          leading: IconButton(
            tooltip: 'Cancel',
            icon: const Icon(Icons.close),
            onPressed: _cancel,
          ),
          title: Text(
            _init == null ? 'New schedule' : 'Schedule ${widget.number}',
          ),
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
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
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
              const SizedBox(height: 12),
              SectionCard(
                key: _whatKey,
                number: 2,
                title: 'How much',
                children: [
                  const Text('Which money', style: label),
                  const SizedBox(height: 8),
                  AssetChips(
                    mint: _mint,
                    assets: vestAssets,
                    allowOther: false,
                    onChanged: (m) => setState(() {
                      _mint = m;
                      _dirty = true;
                    }),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    key: const ValueKey('vest-total'),
                    controller: _total,
                    focusNode: _totalFocus,
                    onChanged: (_) => _changed(),
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: InputDecoration(
                      labelText: 'Total',
                      suffixText: unitLabel(_mint),
                      errorText: _showErrors ? _totalError : null,
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
              const SizedBox(height: 12),
              SectionCard(
                number: 3,
                title: 'Timing',
                children: [
                  const Text('Nothing unlocks for', style: label),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      for (final (secs, text) in cliffs)
                        ChoiceChip(
                          label: Text(text),
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
                  const SizedBox(height: 14),
                  const Text('Fully unlocked after', style: label),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      for (final (secs, text) in durations)
                        ChoiceChip(
                          label: Text(text),
                          selected: _duration == secs,
                          onSelected: (_) => setState(() {
                            _duration = secs;
                            if (_cliff > secs) _cliff = 0;
                            _dirty = true;
                          }),
                        ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 12),
              SectionCard(
                number: 4,
                title: 'How it unlocks',
                children: [SchedulePreview(draft: d, startAt: widget.startAt)],
              ),
            ],
          ),
        ),
        bottomNavigationBar: SafeArea(
          child: Container(
            decoration: const BoxDecoration(
              color: DmColors.surface,
              border: Border(top: BorderSide(color: DmColors.line)),
            ),
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                LivePreview(
                  text: TextSpan(text: _previewLine(d, total, fee)),
                  issue: worstOf(warnings),
                  onIssue: () {
                    final c = _whatKey.currentContext;
                    if (c != null) Scrollable.ensureVisible(c);
                  },
                ),
                const SizedBox(height: 10),
                FilledButton(onPressed: _done, child: const Text('Done')),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _previewLine(ScheduleDraft d, int? total, FeeInfo fee) {
    if (total == null) return 'Enter a total to see what they get.';
    final (net, _) = splitFee(total, fee.bpsFor(d.rail));
    final over =
        '${moneyText(total, d.mint)} to ${d.who} over '
        '${durationLabel(d.durationSecs)}';
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
  });

  final ScheduleDraft draft;
  final int startAt;

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
    final perMonth = s.durationSecs >= monthSecs
        ? (BigInt.from(total) *
                  BigInt.from(monthSecs) ~/
                  BigInt.from(s.durationSecs))
              .toInt()
        : null;
    final milestones = <(String, double)>[
      ('${dateText(start)}: ${moneyText(0, s.mint)}', 0),
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
      (
        '${dateText(start + s.durationSecs)}: all ${moneyText(total, s.mint)}',
        1,
      ),
    ];
    final selected = _selected.clamp(0, milestones.length - 1);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TweenAnimationBuilder<double>(
          tween: Tween(end: milestones[selected].$2),
          duration: const Duration(milliseconds: 400),
          builder: (context, f, _) => VestingBar(
            color: s.rail.color,
            progress: previewProgress(
              total: 1000,
              vested: (f * 1000).round(),
              startAt: start,
              cliffSecs: s.cliffSecs,
              durationSecs: s.durationSecs,
            ),
          ),
        ),
        const SizedBox(height: 8),
        for (final (i, (text, _)) in milestones.indexed)
          InkWell(
            onTap: () => setState(() => _selected = i),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 40),
              child: Row(
                children: [
                  Icon(
                    i == selected ? Icons.circle : Icons.circle_outlined,
                    size: 12,
                    color: i == selected ? DmColors.alive : DmColors.muted,
                  ),
                  const SizedBox(width: 10),
                  Expanded(child: Text(text)),
                ],
              ),
            ),
          ),
        const SizedBox(height: 6),
        Text(
          'Deadman sends what has unlocked about once a day. ${s.who} can also '
          'claim it any time.',
          style: const TextStyle(color: DmColors.muted, height: 1.4),
        ),
      ],
    );
  }
}

/// Short date for vesting copy: "today" or "Oct 4, 2026".
String startText(int startAt, int now) =>
    startAt <= now + 60 ? 'today' : dateText(startAt);
