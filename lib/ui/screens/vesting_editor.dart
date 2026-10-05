import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../solana/deadman_api.dart';
import '../../state/actions.dart';
import '../../state/assets.dart';
import '../../state/fee_settings.dart';
import '../../state/plan_draft.dart';
import '../../state/plan_math.dart';
import '../../state/providers.dart';
import '../../state/vesting.dart';
import '../rules_format.dart';
import '../theme.dart';
import '../widgets/editor/fund_asset_card.dart';
import '../widgets/editor/plan_steps.dart';
import '../widgets/feedback.dart';
import '../widgets/vesting_progress.dart';
import 'plan_editor/editor_providers.dart';
import 'plan_editor/payout_editor.dart' show confirmDiscard;
import 'plan_editor/schedule_editor.dart';

/// Creates a vesting plan: schedules that release gradually from a start
/// date whatever the owner does. No check-ins; panic lockdown covers it.
class VestingEditorPage extends ConsumerStatefulWidget {
  const VestingEditorPage({super.key});

  @override
  ConsumerState<VestingEditorPage> createState() => _VestingEditorPageState();
}

const _steps = ['Schedules', 'Fund', 'Review'];

class _VestingEditorPageState extends ConsumerState<VestingEditorPage> {
  final _label = TextEditingController();
  var _schedules = <ScheduleDraft>[];
  final _deposits = <String?, TextEditingController>{};
  final _depositFocus = <String?, FocusNode>{};
  final _depositKeys = <String?, GlobalKey>{};

  /// Deposits the user typed; the others follow the totals.
  final _edited = <String?>{};
  final _scroll = ScrollController();
  final _labelKey = GlobalKey();
  final _schedulesKey = GlobalKey();
  final _ackKey = GlobalKey();
  DateTime? _startDate;
  bool _revocable = true;
  bool _demo = false;
  int _step = 0;
  bool _check = false;
  bool _checkFund = false;
  bool _ack = false;
  bool _ackLocked = false;
  bool _ackError = false;
  int _shake = 0;
  bool _busy = false;

  @override
  void dispose() {
    _label.dispose();
    for (final c in _deposits.values) {
      c.dispose();
    }
    for (final f in _depositFocus.values) {
      f.dispose();
    }
    _scroll.dispose();
    super.dispose();
  }

  TextEditingController _depositCtrl(String? mint) =>
      _deposits.putIfAbsent(mint, TextEditingController.new);

  int? _depositOf(String? mint) {
    final text = _depositCtrl(mint).text.trim();
    return text.isEmpty ? 0 : parseAmount(text, mint);
  }

  Map<String?, int> get _totals {
    final out = <String?, int>{};
    for (final s in _schedules) {
      out[s.mint] = (out[s.mint] ?? 0) + s.total;
    }
    return out;
  }

  List<String?> get _assets => assetOrder(_schedules.map((s) => s.mint));

  AsyncValue<int> _wallet(String? mint) => mint == null
      ? ref.watch(walletBalanceProvider)
      : ref.watch(walletTokenProvider(mint));

  int _startAt(int now) {
    final d = _startDate;
    if (d == null) return now;
    final at = d.millisecondsSinceEpoch ~/ 1000;
    return at < now ? now : at;
  }

  /// Re-derives untouched deposits from the totals.
  void _applyDefaults() {
    final totals = _totals;
    for (final m in _assets) {
      if (_edited.contains(m)) continue;
      final t = totals[m] ?? 0;
      _depositCtrl(m).text = t == 0 ? '' : amountInput(t, m);
    }
  }

  void _setDemo(bool on) => setState(() {
    _demo = on;
    if (!on) _schedules = _schedules.map(_withoutDemoTimings).toList();
  });

  static ScheduleDraft _withoutDemoTimings(ScheduleDraft s) {
    if (!durationChoices(demo: false).any((c) => c.$1 == s.durationSecs)) {
      s = s.withDuration(12 * monthSecs);
    }
    if (!cliffChoices(demo: false).any((c) => c.$1 == s.cliffSecs)) {
      s = s.withCliff(0);
    }
    return s;
  }

  Future<void> _pickStart() async {
    final today = DateUtils.dateOnly(DateTime.now());
    final picked = await showDatePicker(
      context: context,
      initialDate: _startDate ?? today,
      firstDate: today,
      lastDate: today.add(const Duration(days: 365)),
      helpText: 'Vesting starts on',
    );
    if (picked == null) return;
    setState(
      () => _startDate = DateUtils.isSameDay(picked, today) ? null : picked,
    );
  }

  Future<void> _edit(int? index) async {
    final result = await Navigator.push<ScheduleEdit>(
      context,
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => ScheduleEditorPage(
          initial: index == null ? null : _schedules[index],
          number: (index ?? _schedules.length) + 1,
          demo: _demo,
          startAt: _startAt(nowSecs()),
        ),
      ),
    );
    if (result == null || !mounted) return;
    setState(() {
      final draft = result.draft;
      if (draft == null) {
        _schedules.removeAt(index!);
      } else if (index == null) {
        _schedules.add(draft);
      } else {
        _schedules[index] = draft;
      }
      _applyDefaults();
    });
  }

  void _reveal(GlobalKey key) {
    final c = key.currentContext;
    if (c != null) {
      Scrollable.ensureVisible(
        c,
        duration: const Duration(milliseconds: 250),
        alignment: 0.1,
      );
    }
  }

  void _goTo(int step) => setState(() {
    _step = step;
    if (step == 1) _applyDefaults();
  });

  List<PlanIssue> _scheduleIssues(int i, FeeInfo fee) {
    final s = _schedules[i];
    return deliveryIssues(
      p: scheduleAsPayout(s),
      gross: s.total,
      feeBps: fee.bpsFor(s.rail),
      facts: ref.watch(beneficiaryFactsProvider((s.beneficiary, s.mint))).value,
    );
  }

  /// F1 and V1 for one asset.
  List<PlanIssue> _fundIssues(String? mint, int reserve) {
    final deposit = _depositOf(mint);
    final wallet = _wallet(mint).value;
    if (deposit == null) return const [];
    return [
      if (wallet != null && deposit > wallet)
        PlanIssue(
          IssueCode.f1,
          Severity.error,
          body: 'Your wallet has only ${moneyText(wallet, mint)}.',
          action: 'Use all',
          mint: mint,
        ),
      ?vestingShortfall(mint, _totals[mint] ?? 0, deposit),
      if (mint == null &&
          reserve > 0 &&
          wallet != null &&
          deposit <= wallet &&
          deposit > wallet - reserve)
        PlanIssue(
          IssueCode.f5,
          Severity.warn,
          title: 'Keep some SOL for fees',
          body:
              'Leave about ${moneyText(reserve, null)} in your wallet to pay '
              'network fees.',
          action: 'Use ${moneyText(math.max(0, wallet - reserve), null)}',
          mint: mint,
        ),
    ];
  }

  void _fix(PlanIssue issue, int reserve) {
    final mint = issue.mint;
    final wallet = _wallet(mint).value ?? 0;
    final v = switch (issue.code) {
      IssueCode.v1 => _totals[mint] ?? 0,
      IssueCode.f1 ||
      IssueCode.f5 => mint == null ? math.max(0, wallet - reserve) : wallet,
      _ => null,
    };
    if (v == null) return;
    setState(() {
      _depositCtrl(mint).text = amountInput(v, mint);
      _edited.add(mint);
    });
  }

  void _next(FeeInfo fee, int reserve) {
    switch (_step) {
      case 0:
        final labelBad = labelError(_label.text) != null;
        if (_schedules.isEmpty || labelBad) {
          setState(() => _check = true);
          _reveal(labelBad ? _labelKey : _schedulesKey);
          return;
        }
        _goTo(1);
      case 1:
        final bad = _assets.where(
          (m) =>
              _depositOf(m) == null ||
              _fundIssues(m, reserve).any((i) => i.code == IssueCode.f1),
        );
        if (bad.isNotEmpty) {
          setState(() => _checkFund = true);
          _reveal(_depositKeys[bad.first]!);
          return;
        }
        _goTo(2);
      default:
        _save(fee);
    }
  }

  bool _hasDanger(FeeInfo fee) =>
      [for (var i = 0; i < _schedules.length; i++) ..._scheduleIssues(i, fee)]
          .any((x) => x.severity == Severity.danger);

  Future<void> _save(FeeInfo fee) async {
    if ((_hasDanger(fee) && !_ack) || (!_revocable && !_ackLocked)) {
      setState(() {
        _ackError = true;
        _shake++;
      });
      _reveal(_ackKey);
      return;
    }
    final now = nowSecs();
    final startAt = _startAt(now);
    try {
      checkVestingPlan(
        label: _label.text,
        startAt: startAt,
        now: now,
        schedules: _schedules.length,
      );
    } on VestingInputError catch (e) {
      toast(context, e.message, error: true);
      return;
    }
    final deposits = {for (final m in _assets) m: _depositOf(m) ?? 0};
    setState(() => _busy = true);
    var unguarded = const <VaultState>[];
    final ok = await runGuarded(
      context,
      () async => unguarded = await ref
          .read(actionsProvider)
          .createVesting(
            label: _label.text.trim(),
            startAt: startAt,
            revocable: _revocable,
            schedules: [for (final s in _schedules) s.toSpec()],
            lockSecs: vestingLockSecs(demo: _demo),
            depositLamports: deposits[null] ?? 0,
            tokenDeposits: {
              for (final e in deposits.entries)
                if (e.key != null && e.value > 0) e.key!: e.value,
            },
          ),
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (!ok) return;
    toast(
      context,
      unguarded.isEmpty
          ? 'Vesting plan created'
          : 'Vesting plan created. ${unguarded.map(planName).join(', ')} '
                'still ${unguarded.length == 1 ? 'is' : 'are'} guarded by another device: '
                'use Security → Move guard to this phone.',
      error: unguarded.isNotEmpty,
    );
    Navigator.pop(context);
  }

  Future<void> _back() async {
    if (_step > 0) return setState(() => _step--);
    if (await confirmDiscard(
          context,
          title: 'Discard this plan?',
          body: "Your schedules won't be saved.",
        ) &&
        mounted) {
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final fee = watchFeeInfo(ref);
    final reserve = watchFeeReserve(ref);
    return StepScaffold(
      title: 'New vesting plan',
      steps: _steps,
      step: _step,
      onStepTap: _goTo,
      controller: _scroll,
      busy: _busy,
      canPop: _step == 0 && _schedules.isEmpty && _label.text.trim().isEmpty,
      onPopBlocked: _back,
      onBack: _step == 0 ? null : () => setState(() => _step--),
      primaryLabel: switch (_step) {
        0 => 'Next: fund the plan',
        1 => 'Next: review',
        _ => 'Create vesting plan',
      },
      onPrimary: () => _next(fee, reserve),
      children: switch (_step) {
        0 => _schedulesStep(),
        1 => _fundStep(fee, reserve),
        _ => _reviewStep(fee, reserve),
      },
    );
  }

  List<Widget> _schedulesStep() {
    const muted = TextStyle(color: DmColors.muted, height: 1.4);
    final start = _startAt(nowSecs());
    return [
      const Text(
        'Each schedule unlocks money for someone gradually from the start '
        'date, whether or not you check in.',
        style: muted,
      ),
      const SizedBox(height: 12),
      SectionCard(
        title: 'Plan',
        children: [
          TextField(
            key: _labelKey,
            controller: _label,
            maxLength: 32,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              labelText: 'Plan name',
              hintText: 'e.g. Team grants, Allowance',
              errorText: _check ? labelError(_label.text)?.body : null,
            ),
          ),
          const Text('Starts', style: TextStyle(color: DmColors.muted)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              ChoiceChip(
                label: const Text('Today'),
                selected: _startDate == null,
                onSelected: (_) => setState(() => _startDate = null),
              ),
              ChoiceChip(
                avatar: const Icon(Icons.event, size: 16),
                label: Text(
                  _startDate == null
                      ? 'Pick a date'
                      : DateFormat.yMMMd().format(_startDate!),
                ),
                selected: _startDate != null,
                onSelected: (_) => _pickStart(),
              ),
            ],
          ),
          const SizedBox(height: 16),
          const Text(
            'Can you stop it later?',
            style: TextStyle(color: DmColors.muted),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<bool>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(
                  value: true,
                  label: Text(
                    'Yes, I can stop it',
                    textAlign: TextAlign.center,
                  ),
                ),
                ButtonSegment(
                  value: false,
                  label: Text(
                    "No, it's locked in",
                    textAlign: TextAlign.center,
                  ),
                ),
              ],
              selected: {_revocable},
              onSelectionChanged: (v) => setState(() => _revocable = v.first),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            _revocable
                ? 'You can stop future vesting at any time. Whatever has '
                      'vested by then stays theirs.'
                : 'Funds are committed: you can never stop the schedules or '
                      'take back what they owe.',
            style: muted,
          ),
        ],
      ),
      const SizedBox(height: 16),
      for (final (i, s) in _schedules.indexed) ...[
        _ScheduleSummaryCard(
          number: i + 1,
          schedule: s,
          startAt: start,
          onTap: () => _edit(i),
        ),
        const SizedBox(height: 12),
      ],
      KeyedSubtree(
        key: _schedulesKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_schedules.isEmpty)
              EmptyStateCard(
                title: 'Add your first schedule',
                body:
                    'Choose who receives money, how much, and how fast it '
                    'unlocks.',
                addLabel: 'Add a schedule',
                onAdd: () => _edit(null),
              )
            else if (_schedules.length < maxSchedules)
              OutlinedButton.icon(
                onPressed: () => _edit(null),
                icon: const Icon(Icons.add),
                label: const Text('Add a schedule'),
              ),
            if (_check && _schedules.isEmpty)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(
                  'Add at least one schedule.',
                  style: TextStyle(color: DmColors.danger),
                ),
              ),
          ],
        ),
      ),
      const SizedBox(height: 12),
      Card(
        clipBehavior: Clip.antiAlias,
        child: ExpansionTile(
          shape: const Border(),
          collapsedShape: const Border(),
          title: const Text('Advanced'),
          subtitle: _demo
              ? const Text(
                  'Demo timings',
                  style: TextStyle(color: DmColors.muted, fontSize: 13),
                )
              : null,
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _demo,
              onChanged: _setDemo,
              title: const Text('Demo timings'),
              subtitle: const Text(
                'Adds a 2-minute cliff and 10-minute vesting so it can be '
                'shown live.',
                style: muted,
              ),
            ),
          ],
        ),
      ),
    ];
  }

  List<Widget> _fundStep(FeeInfo fee, int reserve) {
    final totals = _totals;
    return [
      const Text(
        'How much goes into the plan now. You can add more later from the '
        'plan card.',
        style: TextStyle(color: DmColors.muted),
      ),
      const SizedBox(height: 12),
      for (final mint in _assets) ...[
        _fundCard(mint, totals[mint] ?? 0, fee, reserve),
        const SizedBox(height: 12),
      ],
    ];
  }

  Widget _fundCard(String? mint, int total, FeeInfo fee, int reserve) {
    final wallet = _wallet(mint);
    final w = wallet.value;
    final deposit = _depositOf(mint);
    final issues = _fundIssues(mint, reserve);
    final f1 = issues.where((i) => i.code == IssueCode.f1).firstOrNull;
    return FundAssetCard(
      fieldKey: _depositKeys.putIfAbsent(mint, GlobalKey.new),
      focusNode: _depositFocus.putIfAbsent(mint, FocusNode.new),
      mint: mint,
      needs: 'Your schedules add up to ${moneyText(total, mint)}.',
      controller: _depositCtrl(mint),
      wallet: wallet,
      useAll: w == null ? null : (mint == null ? math.max(0, w - reserve) : w),
      onUseAll: (v) => setState(() {
        _depositCtrl(mint).text = amountInput(v, mint);
        _edited.add(mint);
      }),
      onChanged: () => setState(() => _edited.add(mint)),
      errorText: deposit == null
          ? 'Check this amount'
          : _checkFund || f1 != null
          ? f1?.body
          : null,
      breakdownTitle: 'What the schedules need',
      lines: [
        for (final (i, s) in _schedules.indexed)
          if (s.mint == mint)
            FundLine(
              'Schedule ${i + 1} · ${s.who} · over '
              '${durationLabel(s.durationSecs)}',
              moneyText(s.total, mint),
              issue: worstOf(_scheduleIssues(i, fee)),
            ),
      ],
      issues: [
        for (final issue in issues)
          if (issue.code != IssueCode.f1)
            WarningTile.of(issue, onAction: () => _fix(issue, reserve)),
        for (final (i, s) in _schedules.indexed)
          if (s.mint == mint)
            for (final issue in _scheduleIssues(i, fee)) WarningTile.of(issue),
      ],
    );
  }

  List<Widget> _reviewStep(FeeInfo fee, int reserve) {
    final t = Theme.of(context).textTheme;
    final now = nowSecs();
    final start = startText(_startAt(now), now);
    final solMode = ref.watch(feeModeProvider) == FeeMode.sol;
    final deposits = [
      for (final m in _assets)
        if ((_depositOf(m) ?? 0) > 0) moneyText(_depositOf(m)!, m),
    ];
    final danger = _hasDanger(fee);
    return [
      ReviewSection(
        title: _label.text.trim().isEmpty ? 'Unnamed plan' : _label.text.trim(),
        onEdit: _busy ? null : () => _goTo(0),
        children: [
          Text(
            'Starts $start. You ${_revocable ? 'can stop future unlocking at any time' : 'can never stop these schedules or take back what they owe'}.',
          ),
        ],
      ),
      const SizedBox(height: 20),
      Text('What happens', style: t.titleLarge),
      const SizedBox(height: 8),
      for (final (i, s) in _schedules.indexed)
        Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Schedule ${i + 1}',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 2),
              Text(
                vestingSentence(s, start: start, duration: durationLabel),
                style: const TextStyle(height: 1.4),
              ),
              if (!_busy)
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: () => _edit(i),
                    child: Text('Edit schedule ${i + 1}'),
                  ),
                ),
              for (final issue in _scheduleIssues(i, fee))
                WarningTile.of(issue),
            ],
          ),
        ),
      for (final m in _assets)
        for (final issue in _fundIssues(m, reserve))
          if (issue.severity != Severity.error)
            WarningTile.of(issue, onAction: () => _fix(issue, reserve)),
      const SizedBox(height: 20),
      ReviewSection(
        title: 'Costs',
        children: [
          CostRow(
            'Put in now',
            deposits.isEmpty ? 'Nothing' : deposits.join(' · '),
          ),
          CostRow(
            'Release fee',
            fee.waived
                ? 'None: monthly plan active'
                : fee.fees == null
                ? 'fee loading…'
                : '${percentText(fee.fees!.feeBpsPublic / 10000)} of each normal '
                      'release, ${percentText(fee.fees!.feeBpsPrivate / 10000)} '
                      'of each private one, taken when it runs.',
          ),
          CostRow(
            'Network & setup',
            solMode
                ? 'A few thousandths of a SOL (plan storage comes back if you '
                      'close the plan)'
                : '3.00 USDC, paid in USDC',
          ),
        ],
      ),
      const SizedBox(height: 12),
      KeyedSubtree(
        key: _ackKey,
        child: Column(
          children: [
            if (danger)
              AckBox(
                value: _ack,
                shake: _shake,
                onChanged: (v) => setState(() => _ack = v),
                label:
                    'Create it anyway. I understand the schedules marked with '
                    'a red sign may never arrive.',
                error: _ackError && !_ack
                    ? 'Tick the box, or fix the schedules marked with a red '
                          'sign.'
                    : null,
              ),
            if (!_revocable)
              AckBox(
                value: _ackLocked,
                shake: _shake,
                onChanged: (v) => setState(() => _ackLocked = v),
                label:
                    'I understand I can never stop these schedules or '
                    'withdraw what they owe.',
                error: _ackError && !_ackLocked
                    ? 'Tick the box to create a plan you can never stop.'
                    : null,
              ),
          ],
        ),
      ),
      const SizedBox(height: 12),
      const Text(
        'One wallet approval creates the plan and makes your deposits. Anyone '
        'can trigger a release once an amount has unlocked; it always goes to '
        "the schedule's beneficiary.",
        style: TextStyle(color: DmColors.muted, fontSize: 13, height: 1.4),
      ),
    ];
  }
}

/// A schedule on the Schedules step; tap to edit.
class _ScheduleSummaryCard extends StatelessWidget {
  const _ScheduleSummaryCard({
    required this.number,
    required this.schedule,
    required this.startAt,
    required this.onTap,
  });

  final int number;
  final ScheduleDraft schedule;
  final int startAt;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final s = schedule;
    final cliffAt = s.durationSecs == 0 ? 0.0 : s.cliffSecs / s.durationSecs;
    const small = TextStyle(color: DmColors.muted, fontSize: 12);
    return Semantics(
      button: true,
      label: 'Schedule $number, edit',
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 8, 14),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Schedule $number', style: small),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              '${s.who} · ${moneyText(s.total, s.mint)}',
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          RailChip(s.rail),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'over ${durationLabel(s.durationSecs)}'
                        '${s.cliffSecs == 0 ? '' : ', nothing for the first ${durationLabel(s.cliffSecs)}'}',
                      ),
                      const SizedBox(height: 10),
                      VestingBar(
                        color: s.rail.color,
                        progress: previewProgress(
                          total: s.total,
                          vested: 0,
                          startAt: startAt,
                          cliffSecs: s.cliffSecs,
                          durationSecs: s.durationSecs,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          const Text('Start', style: small),
                          Expanded(
                            child: s.cliffSecs == 0
                                ? const SizedBox.shrink()
                                : Align(
                                    alignment: Alignment(cliffAt * 2 - 1, 0),
                                    child: const Text('Cliff', style: small),
                                  ),
                          ),
                          const Text('End', style: small),
                        ],
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right, color: DmColors.muted),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
