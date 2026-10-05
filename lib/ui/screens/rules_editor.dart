import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config.dart';
import '../../solana/codec.dart' show Limits;
import '../../solana/deadman_api.dart';
import '../../state/actions.dart';
import '../../state/assets.dart';
import '../../state/fee_settings.dart';
import '../../state/plan_draft.dart';
import '../../state/plan_math.dart';
import '../../state/providers.dart';
import '../../state/vesting.dart' show isAddress;
import '../format.dart';
import '../rules_format.dart';
import '../widgets/brand/brand.dart';
import '../widgets/editor/fund_asset_card.dart';
import '../widgets/editor/plan_steps.dart';
import '../widgets/feedback.dart';
import 'plan_editor/editor_providers.dart';
import 'plan_editor/payout_editor.dart';

export '../../state/vesting.dart' show isAddress;

enum _Step {
  payouts('Payouts'),
  fund('Fund'),
  review('Review');

  const _Step(this.label);
  final String label;
}

/// Creates the plan when [vault] is null. Otherwise edits it: payouts that
/// already released are shown read-only and only the pending ones are
/// sent; once every payout has released, saving starts a fresh set.
class RulesEditorPage extends ConsumerStatefulWidget {
  const RulesEditorPage({super.key, this.vault});

  final VaultState? vault;

  @override
  ConsumerState<RulesEditorPage> createState() => _RulesEditorPageState();
}

/// Everything derived from the drafts for one build.
class _Model {
  _Model({
    required this.fee,
    required this.reserve,
    required this.stipend,
    required this.preview,
    required this.basisPreview,
    required this.payoutIssues,
    required this.fundAssets,
    required this.assetIssues,
  });

  final FeeInfo fee;
  final int reserve;
  final int stipend;

  /// From the deposits (create) or the plan's balances (edit).
  final PlanPreview preview;

  /// From example balances while creating, for the payout cards.
  final PlanPreview basisPreview;
  final List<List<PlanIssue>> payoutIssues;
  final List<String?> fundAssets;
  final Map<String?, List<PlanIssue>> assetIssues;

  List<PlanIssue> get dangers => [
    for (final l in [...payoutIssues, ...assetIssues.values])
      for (final i in l)
        if (i.severity == Severity.danger) i,
  ];
}

class _RulesEditorPageState extends ConsumerState<RulesEditorPage> {
  VaultState? get _vault => widget.vault;
  bool get _creating => _vault == null;
  bool get _fresh => _vault?.completed ?? false;
  late final _split = _vault == null
      ? (history: const <RuleState>[], pending: const <RuleState>[])
      : splitRules(_vault!);
  List<RuleState> get _history => _split.history;
  late final _steps = _creating
      ? _Step.values
      : const [_Step.payouts, _Step.review];

  int _step = 0;
  late int _interval = _vault?.intervalSecs ?? Cadence.week.interval;
  bool get _demo => _interval == Cadence.demo.interval;
  late int _lock = _vault?.lockSecs ?? Cadence.of(_interval).lock;
  late bool _lockTouched =
      _vault != null && _vault!.lockSecs != Cadence.of(_interval).lock;
  late int _grace = _vault?.skipGraceSecs ?? AppConfig.defaultSkipGraceSecs;
  late final _label = TextEditingController(text: _vault?.label ?? '');
  late final _guardian = TextEditingController(text: _vault?.guardian ?? '');
  late List<PayoutDraft> _payouts;

  final _deposits = <String?, TextEditingController>{};
  final _depositFocus = <String?, FocusNode>{};
  final _depositKeys = <String?, GlobalKey>{};

  /// Deposits the user typed; the others follow the payouts.
  final _edited = <String?>{};

  final _scroll = ScrollController();
  final _labelKey = GlobalKey();
  final _payoutsKey = GlobalKey();
  final _guardianKey = GlobalKey();
  final _ackKey = GlobalKey();
  final _advanced = ExpansibleController();

  bool _ack = false;
  bool _ackError = false;
  int _shake = 0;
  bool _busy = false;
  bool _dirty = false;
  bool _checkPayouts = false;
  bool _checkFund = false;

  @override
  void initState() {
    super.initState();
    final names = ref.read(contactNamesProvider);
    _payouts = [
      for (final r in _split.pending)
        PayoutDraft.fromRule(r, name: names.get(r.beneficiary)),
    ];
    if (_creating) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _edit(null);
      });
    }
  }

  @override
  void dispose() {
    _label.dispose();
    _guardian.dispose();
    for (final c in _deposits.values) {
      c.dispose();
    }
    for (final f in _depositFocus.values) {
      f.dispose();
    }
    _scroll.dispose();
    _advanced.dispose();
    super.dispose();
  }

  int _number(int index) => _history.length + index + 1;

  TextEditingController _depositCtrl(String? mint) =>
      _deposits.putIfAbsent(mint, TextEditingController.new);

  /// Typed deposit: 0 when empty, null when unparseable.
  int? _depositOf(String? mint) {
    final text = _depositCtrl(mint).text.trim();
    return text.isEmpty ? 0 : parseAmount(text, mint);
  }

  AsyncValue<int> _wallet(String? mint) => mint == null
      ? ref.watch(walletBalanceProvider)
      : ref.watch(walletTokenProvider(mint));

  int? _walletNow(String? mint) => mint == null
      ? ref.read(walletBalanceProvider).value
      : ref.read(walletTokenProvider(mint)).value;

  int _reserveNow() => feeReserveLamports(
    solFeeMode: ref.read(feeModeProvider) == FeeMode.sol,
    sponsored: AppConfig.koraSponsorUrl.isNotEmpty,
  );

  /// What the plan holds for payouts (edit): its balance less shares
  /// reserved for skipped payouts; null while unknown.
  int? _planBalance(String? mint) {
    final v = _vault!;
    final raw = mint == null
        ? v.withdrawableLamports
        : ref.read(planTokenProvider((vault: v.address, mint: mint))).value;
    return raw == null ? null : math.max(0, raw - v.reservedFor(mint));
  }

  int? _balanceFor(String? mint) =>
      _creating ? _depositOf(mint) : _planBalance(mint);

  /// The balance a payout preview pays from; an example while creating
  /// and no deposit is typed yet.
  BalanceBasis? _basisFor(String? mint, List<PayoutDraft> all) {
    if (!_creating) {
      final b = _planBalance(mint);
      return b == null ? null : (amount: b, example: false);
    }
    final typed = _depositOf(mint);
    if (typed != null && typed > 0) return (amount: typed, example: false);
    final fixed = all
        .where((p) => p.mint == mint && p.mode == AmountMode.fixed)
        .fold(0, (s, p) => s + (p.fixedAmount ?? 0));
    if (fixed > 0) return (amount: fixed, example: true);
    final wallet = _walletNow(mint);
    if (wallet != null && wallet > 0) return (amount: wallet, example: true);
    final decimals = knownAsset(mint)?.decimals ?? 0;
    return (amount: 100 * math.pow(10, decimals).toInt(), example: true);
  }

  /// USDC when the wallet holds USDC and no SOL beyond fees, else SOL.
  String? _defaultMint() {
    final sol = ref.read(walletBalanceProvider).value;
    final usdc = ref.read(walletTokenProvider(AppConfig.usdcMint)).value;
    return (usdc ?? 0) > 0 && sol != null && sol <= _reserveNow()
        ? AppConfig.usdcMint
        : null;
  }

  int _nextDelay() {
    final chips = delayChoices(_interval);
    if (_payouts.isEmpty) return chips.first;
    final latest = _payouts.map((p) => p.afterSecs).reduce(math.max);
    return chips.firstWhere((c) => c > latest, orElse: () => chips.last);
  }

  List<String?> _fundAssets(int stipend) =>
      assetOrder([for (final p in _payouts) p.mint, if (stipend > 0) null]);

  /// Re-derives untouched deposits from the payouts.
  void _applyDefaults() {
    final stipend = stipendNeed(_payouts);
    for (final m in _fundAssets(stipend)) {
      if (_edited.contains(m)) continue;
      final fixed = _payouts
          .where((p) => p.mint == m && p.mode == AmountMode.fixed)
          .fold(0, (s, p) => s + (p.fixedAmount ?? 0));
      final v = defaultDeposit(
        fixedSum: fixed,
        stipend: m == null ? stipend : 0,
        wallet: _walletNow(m),
        reserve: m == null ? _reserveNow() : 0,
      );
      _depositCtrl(m).text = v == null ? '' : amountInput(v, m);
    }
  }

  void _changed() => setState(() => _dirty = true);

  void _setPayouts(List<PayoutDraft> next) => setState(() {
    _payouts = sortedByDelay(next);
    _dirty = true;
    _applyDefaults();
  });

  void _setInterval(int secs) => setState(() {
    final wasDemo = _demo;
    _interval = secs;
    if (_demo && _grace == AppConfig.defaultSkipGraceSecs) {
      _grace = 120;
    } else if (wasDemo && !_demo && _grace < 86400) {
      _grace = AppConfig.defaultSkipGraceSecs;
    }
    if (!_lockTouched || (!_demo && _lock < 86400)) {
      _lock = Cadence.of(secs).lock;
      _lockTouched = false;
    }
    _dirty = true;
  });

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

  void _goTo(int step) {
    setState(() {
      _step = step;
      if (_steps[step] == _Step.fund) _applyDefaults();
    });
    if (_steps[step] != _Step.fund) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final empty = _fundAssets(stipendNeed(_payouts))
          .where((m) => _depositCtrl(m).text.isEmpty);
      if (empty.isNotEmpty) _depositFocus[empty.first]?.requestFocus();
    });
  }

  Future<void> _edit(int? index) async {
    final result = await Navigator.push<PayoutEdit>(
      context,
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => PayoutEditorPage(
          initial: index == null ? null : _payouts[index],
          number: index == null ? _number(_payouts.length) : _number(index),
          others: [
            for (final (j, p) in _payouts.indexed)
              if (j != index) (_number(j), p),
          ],
          intervalSecs: _interval,
          demo: _demo,
          basis: _basisFor,
          defaultMint: _defaultMint(),
          defaultAfterSecs: _nextDelay(),
        ),
      ),
    );
    if (result == null || !mounted) return;
    final next = [..._payouts];
    final draft = result.draft;
    if (draft == null) {
      next.removeAt(index!);
    } else if (index == null) {
      next.add(draft);
    } else {
      next[index] = draft;
    }
    _setPayouts(next);
  }

  /// One-tap fix of [issue], raised for payout [index] or an asset.
  void _fix(PlanIssue issue, {int? index}) {
    void takeAll(int i) =>
        _setPayouts([..._payouts]..[i] = _payouts[i].takeAll());
    void deposit(int base) => setState(() {
      _depositCtrl(issue.mint).text = amountInput(base, issue.mint);
      _edited.add(issue.mint);
    });
    switch (issue.code) {
      case IssueCode.a1:
        takeAll(index!);
      case IssueCode.d2 when issue.action == 'Use 100%':
        takeAll(index!);
      case IssueCode.d2 || IssueCode.d4:
        _edit(index);
      case IssueCode.l1:
        final last = sortedByDelay(_payouts)
            .lastWhere((p) => p.mint == issue.mint);
        takeAll(_payouts.indexOf(last));
      case IssueCode.f1:
        final w = _walletNow(issue.mint);
        if (w != null) {
          deposit(issue.mint == null ? math.max(0, w - _reserveNow()) : w);
        }
      case IssueCode.f2:
        _goTo(_steps.indexOf(_Step.fund));
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => _depositFocus[issue.mint]?.requestFocus(),
        );
      case IssueCode.f4:
        deposit(
          _payouts
              .where((p) => p.mint == issue.mint && p.mode == AmountMode.fixed)
              .fold(0, (s, p) => s + (p.fixedAmount ?? 0)),
        );
      case IssueCode.f5:
        deposit(math.max(0, (_walletNow(null) ?? 0) - _reserveNow()));
      case IssueCode.f6:
        deposit(stipendNeed(_payouts));
      default:
    }
  }

  _Model _model() {
    final fee = watchFeeInfo(ref);
    final reserve = _creating ? watchFeeReserve(ref) : 0;
    final owner = ref.watch(sessionProvider.select((s) => s.owner));
    final stipend = stipendNeed(_payouts);
    final fundAssets = _fundAssets(stipend);
    // _planBalance reads these; watch them so balances update the page.
    if (!_creating) {
      for (final m in fundAssets.nonNulls) {
        ref.watch(planTokenProvider((vault: _vault!.address, mint: m)));
      }
    }
    final preview = PlanPreview.of(
      _payouts,
      balanceOf: _balanceFor,
      feeBps: fee.bpsFor,
    );
    final basisPreview = _creating
        ? PlanPreview.of(
            _payouts,
            balanceOf: (m) => _basisFor(m, _payouts)?.amount,
            feeBps: fee.bpsFor,
          )
        : preview;
    final pastPayouts = _steps[_step] != _Step.payouts;
    final payoutIssues = [
      for (final (i, p) in _payouts.indexed)
        [
          ?delayError(p.afterSecs, _interval),
          ...payoutWarnings(
            payouts: _payouts,
            index: i,
            preview: pastPayouts ? preview : basisPreview,
            fee: fee,
            facts: ref
                .watch(beneficiaryFactsProvider((p.beneficiary, p.mint)))
                .value,
            owner: owner,
          ),
        ],
    ];
    return _Model(
      fee: fee,
      reserve: reserve,
      stipend: stipend,
      preview: preview,
      basisPreview: basisPreview,
      payoutIssues: payoutIssues,
      fundAssets: fundAssets,
      assetIssues: {
        for (final m in fundAssets)
          m: assetIssues(
            asset: preview.assets.where((a) => a.mint == m).firstOrNull,
            mint: m,
            payouts: _payouts,
            creating: _creating,
            balance: _balanceFor(m),
            numberOf: _number,
            wallet: _creating ? _wallet(m).value : null,
            reserve: m == null ? reserve : 0,
            sponsored: AppConfig.koraSponsorUrl.isNotEmpty,
            stipend: m == null ? stipend : 0,
          ),
      },
    );
  }

  String? _guardianError() {
    final g = _guardian.text.trim();
    return g.isNotEmpty && !isAddress(g) ? 'Guardian address is invalid' : null;
  }

  void _next(_Model m) {
    switch (_steps[_step]) {
      case _Step.payouts:
        final payoutsBad =
            _payouts.isEmpty ||
            _payouts.length + _history.length > Limits.maxRules ||
            m.payoutIssues.any((l) => l.any((i) => i.code == IssueCode.d1));
        final labelBad = labelError(_label.text) != null;
        final guardianBad = _guardianError() != null;
        if (payoutsBad || labelBad || guardianBad) {
          setState(() => _checkPayouts = true);
          if (guardianBad) _advanced.expand();
          WidgetsBinding.instance.addPostFrameCallback(
            (_) => _reveal(
              labelBad
                  ? _labelKey
                  : payoutsBad
                  ? _payoutsKey
                  : _guardianKey,
            ),
          );
          return;
        }
        _goTo(_step + 1);
      case _Step.fund:
        final bad = m.fundAssets.where(
          (a) =>
              _depositOf(a) == null ||
              m.assetIssues[a]!.any((i) => i.code == IssueCode.f1),
        );
        if (bad.isNotEmpty) {
          setState(() => _checkFund = true);
          _reveal(_depositKeys[bad.first]!);
          _depositFocus[bad.first]?.requestFocus();
          return;
        }
        _goTo(_step + 1);
      case _Step.review:
        _save(m);
    }
  }

  Future<void> _save(_Model m) async {
    if (m.dangers.isNotEmpty && !_ack) {
      setState(() {
        _ackError = true;
        _shake++;
      });
      _reveal(_ackKey);
      return;
    }
    final rules = [for (final p in sortedByDelay(_payouts)) p.toRuleSpec()];
    final g = _guardian.text.trim();
    final label = _label.text.trim();
    final tokens = <String, int>{
      for (final a in m.fundAssets)
        if (a != null && (_depositOf(a) ?? 0) > 0) a: _depositOf(a)!,
    };
    final lamports = m.fundAssets.contains(null) ? _depositOf(null) ?? 0 : 0;

    setState(() => _busy = true);
    final actions = ref.read(actionsProvider);
    var unguarded = const <VaultState>[];
    final ok = await runGuarded(
      context,
      () async => _creating
          ? unguarded = await actions.createVault(
              label: label,
              rules: rules,
              intervalSecs: _interval,
              lockSecs: _lock,
              skipGraceSecs: _grace,
              depositLamports: lamports,
              tokenDeposits: tokens,
            )
          : await actions.updatePolicy(
              planId: _vault!.planId,
              label: label,
              intervalSecs: _interval,
              lockSecs: _lock,
              skipGraceSecs: _grace,
              rules: rules,
              guardian: g.isEmpty ? null : g,
            ),
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (!ok) return;
    toast(
      context,
      unguarded.isEmpty
          ? (_creating ? 'Plan created' : 'Plan updated')
          : 'Plan created. ${unguarded.length == 1 ? '1 older plan is' : '${unguarded.length} older plans are'} '
                'still guarded by another device (${unguarded.map(planName).join(', ')}): '
                'use Security → Move guard to this phone.',
      error: unguarded.isNotEmpty,
    );
    Navigator.pop(context);
  }

  bool get _hasChanges =>
      _creating ? _payouts.isNotEmpty || _label.text.isNotEmpty : _dirty;

  Future<void> _back() async {
    if (_step > 0) return setState(() => _step--);
    if (await confirmDiscard(
          context,
          title: _creating ? 'Discard this plan?' : 'Discard your changes?',
          body: "Your payouts won't be saved.",
        ) &&
        mounted) {
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final m = _model();
    final step = _steps[_step];
    return StepScaffold(
      title: _creating
          ? 'New inheritance plan'
          : _fresh
          ? 'Start a new plan'
          : 'Edit plan',
      steps: [for (final s in _steps) s.label],
      step: _step,
      onStepTap: _goTo,
      controller: _scroll,
      busy: _busy,
      canPop: _step == 0 && !_hasChanges,
      onPopBlocked: _back,
      onBack: _step == 0 ? null : () => setState(() => _step--),
      primaryLabel: switch (step) {
        _Step.payouts => _creating ? 'Next: fund the plan' : 'Next: review',
        _Step.fund => 'Next: review',
        _Step.review =>
          _creating
              ? 'Create plan'
              : _fresh
              ? 'Start new plan'
              : 'Save changes',
      },
      onPrimary: () => _next(m),
      children: switch (step) {
        _Step.payouts => _payoutsStep(m),
        _Step.fund => _fundStep(m),
        _Step.review => _reviewStep(m),
      },
    );
  }

  // Step 1: payouts.

  List<Widget> _payoutsStep(_Model m) {
    final total = _payouts.length + _history.length;
    final names = ref.read(contactNamesProvider);
    return [
      const StepLead('Who gets what if you stop checking in.'),
      if (_fresh) ...[
        const WarningTile(
          severity: Severity.info,
          body:
              'Every payout of this plan has been sent. Saving starts a new '
              'set of payouts on the same plan.',
        ),
        const SizedBox(height: DMSpace.lg),
      ],
      SectionCard(
        title: 'Plan',
        children: [
          TextField(
            key: _labelKey,
            controller: _label,
            maxLength: Limits.maxLabelBytes,
            onChanged: (_) => _changed(),
            decoration: InputDecoration(
              labelText: 'Plan name',
              hintText: 'e.g. Family, Emergency fund',
              errorText: _checkPayouts ? labelError(_label.text)?.body : null,
            ),
          ),
          _IntervalRow(
            label: delayText(_interval),
            onTap: _demo ? null : _pickInterval,
          ),
        ],
      ),
      const SizedBox(height: DMSpace.xxl),
      const SectionHeader(title: 'Payouts'),
      const SizedBox(height: DMSpace.sm),
      const TimelineEntry(label: 'Last check-in', dot: DM.signal),
      for (final (i, r) in _history.indexed)
        TimelineEntry(
          label: 'After ${delayText(r.afterSecs)} of silence',
          child: _HistoryPayoutCard(
            number: i + 1,
            rule: r,
            who: whoText(names.get(r.beneficiary), r.beneficiary),
          ),
        ),
      for (final (i, p) in _payouts.indexed)
        TimelineEntry(
          label: 'After ${delayText(p.afterSecs)} of silence',
          dot: DM.tide,
          child: _PayoutSummaryCard(
            number: _number(i),
            payout: p,
            approx: _approx(m, i),
            issue: worstOf(m.payoutIssues[i]),
            onTap: () => _edit(i),
          ),
        ),
      TimelineEntry(
        key: _payoutsKey,
        label: '',
        last: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_payouts.isEmpty)
              EmptyStateCard(
                title: 'Add your first payout',
                body:
                    'Choose who receives money if you stop checking in, how '
                    'much, and when.',
                addLabel: 'Add a payout',
                onAdd: () => _edit(null),
              )
            else if (total < Limits.maxRules)
              AddRowButton(label: 'Add a payout', onTap: () => _edit(null))
            else
              Text(p2.body, style: _sub),
            if (_checkPayouts && _payouts.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: DMSpace.sm),
                child: Text(p1.body, style: _error),
              ),
            if (_checkPayouts &&
                m.payoutIssues.any((l) => l.any((i) => i.code == IssueCode.d1)))
              Padding(
                padding: const EdgeInsets.only(top: DMSpace.sm),
                child: Text('Fix the payouts marked in red.', style: _error),
              ),
            if (total > Limits.maxRules) Text(p2.body, style: _error),
          ],
        ),
      ),
      if (!_creating)
        for (final a in m.preview.assets)
          if (_balanceFor(a.mint) == 0) WarningTile.of(f3(a.mint)),
      const SizedBox(height: DMSpace.lg),
      _advancedCard(),
    ];
  }

  /// "≈ 98 USDC" for a payout card; while creating, "≈ 0.12 USDC if the
  /// plan holds 12 USDC" (the deposit, or the same example as the editor).
  String? _approx(_Model m, int i) {
    final mint = _payouts[i].mint;
    if (_creating) {
      final net = m.basisPreview.amounts[i].net;
      final basis = _basisFor(mint, _payouts);
      if (net == null || basis == null) return null;
      return '≈ ${moneyText(net, mint)} if the plan holds '
          '${moneyText(basis.amount, mint)}';
    }
    final net = m.preview.amounts[i].net;
    final balance = _balanceFor(mint);
    if (net == null || balance == null || balance == 0) return null;
    return '≈ ${moneyText(net, mint)}';
  }

  Future<void> _pickInterval() async {
    const options = [
      (Cadence.week, 'Good if you use your phone daily.'),
      (Cadence.month, 'A monthly check-in.'),
      (Cadence.quarter, 'Least effort; payouts start later.'),
    ];
    final picked = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(
            DMSpace.gutter,
            0,
            DMSpace.gutter,
            DMSpace.xl,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'How often will you check in?',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              RadioGroup<int>(
                groupValue: _interval,
                onChanged: (v) => Navigator.pop(context, v),
                child: Column(
                  children: [
                    for (final (c, helper) in options)
                      RadioListTile<int>(
                        value: c.interval,
                        contentPadding: EdgeInsets.zero,
                        title: Text(c.label),
                        subtitle: Text(helper),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Text(
                "A check-in is a fingerprint tap in Deadman. Missing one doesn't "
                'send anything by itself: each payout waits for its own delay.',
                style: _sub,
              ),
            ],
          ),
        ),
      ),
    );
    if (picked != null && picked != _interval) _setInterval(picked);
  }

  Widget _advancedCard() {
    List<Widget> chips(
      List<int> values,
      int current,
      ValueChanged<int> onPick,
    ) => [
      for (final s in values.contains(current) ? values : [...values, current])
        pickChip(
          label: delayText(s),
          mono: true,
          selected: current == s,
          onSelected: (_) => onPick(s),
        ),
    ];
    final helper = DMType.outfit(size: 13.5, color: DM.sub, height: 1.4);
    final heading = DMType.outfit(size: 15, weight: FontWeight.w600);
    final graces = [for (final (s, _) in graceChoices(demo: _demo)) s];
    return DMCard(
      padding: EdgeInsets.zero,
      child: ExpansionTile(
        controller: _advanced,
        tilePadding: const EdgeInsets.symmetric(
          horizontal: DMSpace.cardPadding,
        ),
        title: Text(
          'Advanced',
          style: DMType.outfit(size: 16, weight: FontWeight.w600),
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Text(
            [
              'Lock: ${delayText(_lock)}',
              'Skip after: ${delayText(_grace)}',
              if (_demo) 'Demo timings',
              if (_guardian.text.trim().isNotEmpty) 'Guardian set',
            ].join(' · '),
            style: DMType.data(size: 12),
          ),
        ),
        childrenPadding: const EdgeInsets.fromLTRB(
          DMSpace.cardPadding,
          DMSpace.xxs,
          DMSpace.cardPadding,
          DMSpace.cardPadding,
        ),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Duress lock lasts', style: heading),
          const SizedBox(height: DMSpace.sm),
          Wrap(
            spacing: DMSpace.sm,
            runSpacing: DMSpace.xxs,
            children: chips(
              lockChoices(demo: _demo),
              _lock,
              (s) => setState(() {
                _lock = s;
                _lockTouched = true;
                _dirty = true;
              }),
            ),
          ),
          const SizedBox(height: DMSpace.xs),
          Text(
            'When you use your duress PIN or Panic, withdrawals and plan '
            'changes are frozen for this long. Payouts are never frozen.',
            style: helper,
          ),
          const SizedBox(height: DMSpace.xl),
          Text("If a payout can't be delivered, move on after", style: heading),
          const SizedBox(height: DMSpace.sm),
          Wrap(
            spacing: DMSpace.sm,
            runSpacing: DMSpace.xxs,
            children: chips(
              graces,
              _grace,
              (s) => setState(() {
                _grace = s;
                _dirty = true;
              }),
            ),
          ),
          const SizedBox(height: DMSpace.xs),
          Text(
            "Deadman waits this long for a payout that can't be sent (for "
            "example, a wallet that can't receive it), then lets later payouts "
            "continue. The stuck payout's money stays set aside for that "
            'person to claim.',
            style: helper,
          ),
          const SizedBox(height: DMSpace.md),
          const Divider(height: 1),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _demo,
            onChanged: (on) => _setInterval(
              on ? Cadence.demo.interval : Cadence.week.interval,
            ),
            title: const Text('Demo timings'),
            subtitle: Text(
              'Check-ins every 2 minutes and payouts within minutes, so you '
              'can show it live.',
              style: helper,
            ),
          ),
          if (!_creating) ...[
            const SizedBox(height: DMSpace.md),
            TextField(
              key: _guardianKey,
              controller: _guardian,
              onChanged: (_) => _changed(),
              style: DMType.mono(size: 14),
              decoration: InputDecoration(
                labelText: 'Guardian wallet (optional)',
                helperText:
                    'A person you trust who can freeze this plan and co-sign an '
                    'early unlock. They can never move funds.',
                helperMaxLines: 3,
                errorText: _checkPayouts ? _guardianError() : null,
              ),
            ),
          ],
        ],
      ),
    );
  }

  // Step 2: fund.

  String _needs(AssetSummary? a, String? mint, int stipend) {
    if (a == null) {
      return 'Private token payouts need ${moneyText(stipend, null)} of SOL '
          'to move them.';
    }
    final sum = moneyText(a.fixedSum, mint);
    if (!a.hasShares) return 'Your payouts add up to $sum.';
    if (a.fixedSum == 0) {
      return 'Your payouts are shares, so they pay from whatever you put in.';
    }
    return 'Fixed payouts need $sum; shares pay from the rest.';
  }

  String _shortAmount(PayoutDraft p) => p.mode == AmountMode.fixed
      ? moneyText(p.fixedAmount ?? 0, p.mint)
      : p.takesAll
      ? 'Everything left'
      : "${shareInput(p.shareBps ?? 0)}% of what's left";

  List<Widget> _fundStep(_Model m) => [
    const StepLead('How much goes into the plan now.'),
    for (final mint in m.fundAssets) ...[
      _fundCard(m, mint),
      const SizedBox(height: DMSpace.md),
    ],
    const SizedBox(height: DMSpace.xxs),
    Text(
      'You can add more later from the plan card. Payouts that are shares '
      'grow with whatever you add.',
      style: _note,
    ),
  ];

  Widget _fundCard(_Model m, String? mint) {
    final a = m.preview.assets.where((x) => x.mint == mint).firstOrNull;
    final wallet = _wallet(mint);
    final deposit = _depositOf(mint);
    final issues = m.assetIssues[mint]!;
    final f1 = issues.where((i) => i.code == IssueCode.f1).firstOrNull;
    final delivery = <(int?, PlanIssue)>[
      if (a != null)
        for (final i in a.order)
          for (final issue in m.payoutIssues[i])
            if (issue.severity == Severity.danger ||
                issue.severity == Severity.warn)
              if (issue.code != IssueCode.a1) (i, issue),
    ];
    final w = wallet.value;
    return FundAssetCard(
      fieldKey: _depositKeys.putIfAbsent(mint, GlobalKey.new),
      focusNode: _depositFocus.putIfAbsent(mint, FocusNode.new),
      mint: mint,
      needs: _needs(a, mint, m.stipend),
      controller: _depositCtrl(mint),
      wallet: wallet,
      useAll: w == null
          ? null
          : (mint == null ? math.max(0, w - m.reserve) : w),
      onUseAll: (v) => setState(() {
        _depositCtrl(mint).text = amountInput(v, mint);
        _edited.add(mint);
      }),
      onChanged: () => setState(() {
        _edited.add(mint);
        _dirty = true;
      }),
      errorText: deposit == null
          ? 'Check this amount'
          : _checkFund || f1 != null
          ? f1?.body
          : null,
      breakdownTitle: 'What each payout gets',
      lines: [
        if (a != null)
          for (final i in a.order)
            FundLine(
              'Payout ${_number(i)} · ${_payouts[i].who} · after '
                  '${delayText(_payouts[i].afterSecs)}',
              '${_shortAmount(_payouts[i])} → '
                  '${m.preview.amounts[i].net == null
                      ? '?'
                      : m.preview.amounts[i].net == 0
                      ? 'nothing'
                      : '≈ ${moneyText(m.preview.amounts[i].net!, mint)}'}',
              issue: worstOf(
                m.payoutIssues[i].where((x) => x.severity != Severity.error),
              ),
            ),
      ],
      leftover: a?.leftover == null
          ? null
          : 'Left in the plan afterwards: ${moneyText(a!.leftover!, mint)}',
      leftoverWarn: (a?.leftover ?? 0) > 0,
      issues: [
        for (final (i, issue) in [
          for (final issue in issues)
            if (issue.code != IssueCode.f1) (null, issue),
          ...delivery,
        ]..sort((a, b) => a.$2.severity.index - b.$2.severity.index))
          WarningTile.of(
            issue,
            onAction: issue.action == null ? null : () => _fix(issue, index: i),
          ),
      ],
    );
  }

  // Step 3: review.

  List<Widget> _reviewStep(_Model m) {
    final t = Theme.of(context).textTheme;
    final fee = m.fee;
    final solMode = ref.watch(feeModeProvider) == FeeMode.sol;
    final web = ref.watch(isWebProvider);
    String held(String? mint) {
      final b = _balanceFor(mint);
      return b == null ? 'checking…' : moneyText(b, mint);
    }

    final feeSums = [
      for (final a in m.preview.assets)
        if (a.feeTotal != null && a.feeTotal! > 0)
          moneyText(a.feeTotal!, a.mint),
    ];
    final deposits = [
      for (final a in m.fundAssets)
        if ((_depositOf(a) ?? 0) > 0) moneyText(_depositOf(a)!, a),
    ];
    final dangers = m.dangers;
    return [
      ReviewSection(
        title: _label.text.trim().isEmpty ? 'Unnamed plan' : _label.text.trim(),
        onEdit: _busy ? null : () => _goTo(0),
        children: [
          Text.rich(
            TextSpan(
              children: [
                const TextSpan(text: 'You check in every '),
                TextSpan(
                  text: delayText(_interval),
                  style: DMType.mono(size: 14.5, weight: FontWeight.w500),
                ),
                const TextSpan(text: '.'),
              ],
            ),
            style: DMType.outfit(size: 15, color: DM.sub),
          ),
        ],
      ),
      const SizedBox(height: DMSpace.xxl),
      Semantics(
        header: true,
        child: Text('If you stop checking in', style: t.titleLarge),
      ),
      const SizedBox(height: DMSpace.md),
      for (final (i, p) in _payouts.indexed)
        _ReviewPayout(
          number: _number(i),
          when: payoutWhen(p.afterSecs, _interval),
          sentence: payoutSentence(
            p,
            net: (_balanceFor(p.mint) ?? 0) > 0
                ? m.preview.amounts[i].net
                : null,
            capped:
                p.mode == AmountMode.fixed &&
                (m.preview.amounts[i].gross ?? p.fixedAmount ?? 0) <
                    (p.fixedAmount ?? 0),
          ),
          issues: [
            for (final issue in m.payoutIssues[i])
              // A1's "did you mean 100%" is L1 below, with the amount.
              if ((issue.severity == Severity.danger ||
                      issue.severity == Severity.warn) &&
                  issue.code != IssueCode.a1)
                WarningTile.of(
                  issue,
                  onAction: issue.action == null
                      ? null
                      : () => _fix(issue, index: i),
                ),
          ],
          onEdit: _busy ? null : () => _edit(i),
        ),
      for (final mint in m.fundAssets) ...[
        for (final a in m.preview.assets)
          if (a.mint == mint && a.lastTakesAll && _balanceFor(mint) != 0)
            Padding(
              padding: const EdgeInsets.only(top: DMSpace.sm),
              child: Text(leftoverSentence(a), style: _sub),
            ),
        for (final issue in m.assetIssues[mint]!)
          if (issue.severity == Severity.danger ||
              issue.severity == Severity.warn)
            WarningTile.of(
              issue,
              onAction: issue.action == null ? null : () => _fix(issue),
            ),
      ],
      const SizedBox(height: DMSpace.xxl),
      ReviewSection(
        title: 'Costs',
        children: [
          if (_creating)
            CostRow(
              'Put in now',
              deposits.isEmpty ? 'Nothing' : deposits.join(' · '),
              mono: deposits.isNotEmpty,
            )
          else
            CostRow(
              'The plan holds',
              [for (final mint in m.fundAssets) held(mint)].join(' · '),
              mono: true,
            ),
          CostRow(
            'Release fee',
            fee.waived
                ? 'None: monthly plan active'
                : fee.fees == null
                ? 'fee loading…'
                : '${percentText(fee.fees!.feeBpsPublic / 10000)} of each normal '
                      'payout, ${percentText(fee.fees!.feeBpsPrivate / 10000)} of '
                      'each private one, taken when it runs.'
                      '${feeSums.isEmpty ? '' : ' If every payout runs: ≈ ${feeSums.join(' · ')}.'}',
          ),
          if (_creating) ...[
            CostRow(
              'Network & setup',
              solMode
                  ? 'A few thousandths of a SOL (plan storage comes back if '
                        'you close the plan)'
                  : '3.00 USDC, paid in USDC',
            ),
            if (AppConfig.koraSponsorUrl.isEmpty && solMode)
              CostRow(
                'Check-in key',
                '0.01 SOL so this ${web ? 'browser' : 'phone'} can check in',
              ),
          ] else
            CostRow(
              'Network fee',
              solMode ? 'A tiny SOL network fee' : '0.02 USDC, paid in USDC',
            ),
        ],
      ),
      if (!_creating)
        Padding(
          padding: const EdgeInsets.only(top: DMSpace.md),
          child: Text(
            "Saving also counts as a check-in: every payout's clock restarts.",
            style: _sub,
          ),
        ),
      if (dangers.isNotEmpty) ...[
        const SizedBox(height: DMSpace.md),
        AckBox(
          key: _ackKey,
          value: _ack,
          shake: _shake,
          onChanged: (v) => setState(() {
            _ack = v;
            _ackError = false;
          }),
          label:
              '${_creating ? 'Create' : 'Save'} it anyway. I understand the '
              'payouts marked with a red sign may never arrive.',
          error: _ackError && !_ack
              ? 'Tick the box, or fix the payouts marked with a red sign.'
              : null,
        ),
      ],
      const SizedBox(height: DMSpace.lg),
      Text(
        _creating
            ? 'One wallet approval creates the plan, sets up this '
                  "${web ? 'browser' : 'phone'}'s check-ins and makes your deposits."
            : 'One wallet approval saves these payouts.',
        style: _note,
      ),
    ];
  }
}

final _sub = DMType.outfit(size: 15, color: DM.sub, height: 1.45);
final _note = DMType.outfit(size: 13.5, color: DM.sub, height: 1.4);
final _error = DMType.outfit(size: 14, color: DM.due, height: 1.4);

class _IntervalRow extends StatelessWidget {
  const _IntervalRow({required this.label, required this.onTap});

  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => InkWell(
    borderRadius: BorderRadius.circular(DMRadius.tile),
    onTap: onTap,
    child: ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 48),
      child: Row(
        children: [
          Expanded(
            child: Text(
              'You check in every',
              style: DMType.outfit(size: 15, color: DM.sub),
            ),
          ),
          const SizedBox(width: DMSpace.md),
          Text(label, style: DMType.mono(size: 15, weight: FontWeight.w600)),
          if (onTap != null) ...[
            const SizedBox(width: DMSpace.xxs),
            const Icon(Icons.expand_more, color: DM.sub, size: 20),
          ],
        ],
      ),
    ),
  );
}

/// "Ana · 7Hq2…mX1c": the name in Outfit, the address in mono.
InlineSpan _whoSpan(String name, String address) => TextSpan(
  children: [
    if (name.isNotEmpty)
      TextSpan(
        text: '$name · ',
        style: DMType.outfit(size: 15, weight: FontWeight.w600),
      ),
    TextSpan(
      text: address,
      style: DMType.mono(size: 13.5, color: name.isEmpty ? DM.bone : DM.sub),
    ),
  ],
);

/// A pending payout on the timeline; tap to edit.
class _PayoutSummaryCard extends StatelessWidget {
  const _PayoutSummaryCard({
    required this.number,
    required this.payout,
    required this.approx,
    required this.issue,
    required this.onTap,
  });

  final int number;
  final PayoutDraft payout;
  final String? approx;
  final PlanIssue? issue;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = payout;
    return Semantics(
      button: true,
      label: 'Payout $number, edit',
      child: DMCard(
        onTap: onTap,
        padding: const EdgeInsets.fromLTRB(
          DMSpace.lg,
          DMSpace.md,
          DMSpace.sm,
          DMSpace.lg,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Payout $number',
                    style: DMType.outfit(size: 17, weight: FontWeight.w700),
                  ),
                ),
                RailChip(p.rail),
                const Icon(Icons.chevron_right, color: DM.mist),
              ],
            ),
            const SizedBox(height: DMSpace.xs),
            Text.rich(_whoSpan(p.name, short(p.beneficiary))),
            const SizedBox(height: DMSpace.xxs),
            Padding(
              padding: const EdgeInsets.only(right: DMSpace.sm),
              child: Text(
                payoutAmountLabel(p),
                style: DMType.outfit(size: 15, color: DM.bone, height: 1.35),
              ),
            ),
            if (approx != null) Text(approx!, style: DMType.data(size: 12.5)),
            if (issue != null)
              Padding(
                padding: const EdgeInsets.only(
                  top: DMSpace.sm,
                  right: DMSpace.sm,
                ),
                child: IssueLine(issue!),
              ),
          ],
        ),
      ),
    );
  }
}

/// A payout that already released, or was skipped (its share reserved and
/// still claimable): history, read only.
class _HistoryPayoutCard extends StatelessWidget {
  const _HistoryPayoutCard({
    required this.number,
    required this.rule,
    required this.who,
  });

  final int number;
  final RuleState rule;
  final String who;

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'read only',
    child: DMCard(
      padding: const EdgeInsets.all(DMSpace.lg),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          IconTile(
            icon: rule.executed ? Icons.check : Icons.lock_outline,
            size: 32,
          ),
          const SizedBox(width: DMSpace.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Payout $number · ${doneLabel(rule)}',
                  style: DMType.outfit(
                    size: 15,
                    weight: FontWeight.w600,
                    color: DM.sub,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${payoutAmountLabel(PayoutDraft.fromRule(rule))} → $who',
                  style: DMType.outfit(size: 14, color: DM.sub, height: 1.35),
                ),
                const SizedBox(height: 2),
                Text(
                  rule.executed
                      ? "Already paid. It won't pay again."
                      : 'Its money is set aside until $who claims it.',
                  style: DMType.outfit(size: 13.5, color: DM.mist),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

/// One numbered payout sentence in Review.
class _ReviewPayout extends StatelessWidget {
  const _ReviewPayout({
    required this.number,
    required this.when,
    required this.sentence,
    required this.issues,
    required this.onEdit,
  });

  final int number;
  final String when;
  final String sentence;
  final List<Widget> issues;
  final VoidCallback? onEdit;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: DMSpace.lg),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        StepNumber(number),
        const SizedBox(width: DMSpace.md),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  when,
                  style: DMType.mono(size: 12.5, color: DM.sub, height: 1.4),
                ),
              ),
              const SizedBox(height: DMSpace.xxs),
              Text(sentence, style: DMType.outfit(size: 15.5, height: 1.45)),
              if (onEdit != null)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    style: TextButton.styleFrom(
                      padding: EdgeInsets.zero,
                      minimumSize: const Size(48, 44),
                    ),
                    onPressed: onEdit,
                    child: Text('Edit payout $number'),
                  ),
                ),
              ...issues,
            ],
          ),
        ),
      ],
    ),
  );
}
