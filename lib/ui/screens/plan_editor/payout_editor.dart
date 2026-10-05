import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../solana/deadman_api.dart';
import '../../../state/assets.dart';
import '../../../state/plan_draft.dart';
import '../../../state/providers.dart';
import '../../theme.dart';
import '../../widgets/editor/amount_mode_field.dart';
import '../../widgets/editor/asset_chips.dart';
import '../../widgets/editor/plan_steps.dart';
import 'editor_providers.dart';
import 'recipient_section.dart';

/// The balance a preview pays from: the plan's own, or an example while it
/// isn't known yet.
typedef BalanceBasis = ({int amount, bool example});

/// What the payout editor returns: a saved draft, or a removal.
class PayoutEdit {
  const PayoutEdit.save(PayoutDraft this.draft);
  const PayoutEdit.remove() : draft = null;

  final PayoutDraft? draft;
}

/// Asks before throwing away edits.
Future<bool> confirmDiscard(
  BuildContext context, {
  required String title,
  required String body,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: DmColors.surface,
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep editing'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Discard'),
          ),
        ],
      ),
    ) ??
    false;

/// Full-screen editor for one payout: who, what and when, with a live
/// preview of what arrives.
class PayoutEditorPage extends ConsumerStatefulWidget {
  const PayoutEditorPage({
    super.key,
    this.initial,
    required this.number,
    required this.others,
    required this.intervalSecs,
    required this.demo,
    required this.basis,
    required this.defaultMint,
    required this.defaultAfterSecs,
  });

  /// Null for a new payout.
  final PayoutDraft? initial;

  /// Display number of this payout.
  final int number;

  /// The plan's other pending payouts with their display numbers.
  final List<(int, PayoutDraft)> others;
  final int intervalSecs;
  final bool demo;

  /// The balance of an asset given all payouts; null while unknown.
  final BalanceBasis? Function(String? mint, List<PayoutDraft> all) basis;
  final String? defaultMint;
  final int defaultAfterSecs;

  @override
  ConsumerState<PayoutEditorPage> createState() => _PayoutEditorPageState();
}

class _PayoutEditorPageState extends ConsumerState<PayoutEditorPage> {
  late final PayoutDraft? _init = widget.initial;
  late final _who = Recipient(
    address: _init?.beneficiary ?? '',
    name: _init?.name ?? '',
    rail: _init?.rail ?? Rail.solana,
  );
  late String? _mint = _init == null ? widget.defaultMint : _init.mint;
  late AmountMode _mode = _init?.mode ?? AmountMode.percent;
  late final _share = TextEditingController(
    text: _init == null
        ? '100'
        : _init.shareBps == null
        ? ''
        : shareInput(_init.shareBps!),
  );
  late final _fixed = TextEditingController(
    text: _init?.fixedAmount == null
        ? ''
        : amountInput(_init!.fixedAmount!, _init.mint),
  );
  late int _after = _init?.afterSecs ?? widget.defaultAfterSecs;
  late bool _custom = !delayChoices(widget.intervalSecs).contains(_after);
  late int _customUnit = widget.demo && _after % 86400 != 0 ? 60 : 86400;
  late final _customValue = TextEditingController(
    text: '${_after ~/ _customUnit}',
  );
  final _shareFocus = FocusNode();
  final _fixedFocus = FocusNode();
  final _scroll = ScrollController();
  final _whoKey = GlobalKey();
  final _whatKey = GlobalKey();
  final _whenKey = GlobalKey();

  /// The address the delivery checks look up (debounced).
  late String? _factsAddress = _who.valid ? _who.value : null;
  Timer? _debounce;
  bool _addressTouched = false;
  bool _showErrors = false;
  bool _dirty = false;

  @override
  void initState() {
    super.initState();
    _who.focus.addListener(() {
      if (!_who.focus.hasFocus && _who.value.isNotEmpty) {
        setState(() => _addressTouched = true);
      }
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _who.dispose();
    _share.dispose();
    _fixed.dispose();
    _customValue.dispose();
    _shareFocus.dispose();
    _fixedFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  PayoutDraft get _draft => PayoutDraft(
    beneficiary: _who.value,
    rail: _who.rail,
    mint: _mint,
    mode: _mode,
    shareBps: parseShareBps(_share.text),
    fixedAmount: _fixed.text.trim().isEmpty
        ? null
        : parseAmount(_fixed.text, _mint),
    afterSecs: _after,
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

  void _setAfter(int secs) => setState(() {
    _after = secs;
    _dirty = true;
  });

  void _setCustom(String text) {
    final n = int.tryParse(text.trim());
    if (n != null && n > 0) _after = n * _customUnit;
    _changed();
  }

  void _useAll() => setState(() {
    _mode = AmountMode.percent;
    _share.text = '100';
    _dirty = true;
  });

  void _raise() =>
      (_mode == AmountMode.fixed ? _fixedFocus : _shareFocus).requestFocus();

  void _reveal(GlobalKey key) {
    final c = key.currentContext;
    if (c != null) {
      Scrollable.ensureVisible(
        c,
        duration: const Duration(milliseconds: 250),
        alignment: 0.05,
      );
    }
  }

  void _act(PlanIssue issue) => switch (issue.code) {
    IssueCode.a1 => _useAll(),
    IssueCode.d2 when issue.action == 'Use 100%' => _useAll(),
    IssueCode.d2 || IssueCode.d4 => _raise(),
    _ => null,
  };

  Future<void> _cancel() async {
    if (_dirty &&
        !await confirmDiscard(
          context,
          title: 'Discard your changes?',
          body: "This payout won't be saved.",
        )) {
      return;
    }
    if (mounted) Navigator.pop(context);
  }

  Future<void> _remove() async {
    final ok =
        await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            backgroundColor: DmColors.surface,
            title: const Text('Remove this payout?'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Keep'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Remove'),
              ),
            ],
          ),
        ) ??
        false;
    if (ok && mounted) Navigator.pop(context, const PayoutEdit.remove());
  }

  void _done() {
    final d = _draft;
    final errors = [
      ...d.validate(intervalSecs: widget.intervalSecs),
      if (d.beneficiary == ref.read(sessionProvider).owner)
        const PlanIssue(IssueCode.b1, Severity.error, body: ''),
    ];
    if (errors.isNotEmpty) {
      setState(() => _showErrors = true);
      _reveal(switch (errors.first.code) {
        IssueCode.b1 || IssueCode.b2 => _whoKey,
        IssueCode.d1 => _whenKey,
        _ => _whatKey,
      });
      return;
    }
    ref.read(contactNamesProvider).set(d.beneficiary, d.name);
    Navigator.pop(context, PayoutEdit.save(d));
  }

  @override
  Widget build(BuildContext context) {
    final fee = watchFeeInfo(ref);
    final owner = ref.watch(sessionProvider.select((s) => s.owner));
    final draft = _draft;
    final all = [for (final (_, p) in widget.others) p, draft];
    final index = all.length - 1;
    final preview = PlanPreview.of(
      all,
      balanceOf: (m) => widget.basis(m, all)?.amount,
      feeBps: fee.bpsFor,
    );
    final facts = _factsAddress == null
        ? null
        : ref.watch(beneficiaryFactsProvider((_factsAddress!, _mint)));
    final warnings = payoutWarnings(
      payouts: all,
      index: index,
      preview: preview,
      fee: fee,
      facts: facts?.value,
      owner: owner,
    );
    final a1 = warnings.where((w) => w.code == IssueCode.a1);
    final b1 = warnings.where((w) => w.code == IssueCode.b1).firstOrNull;
    final delivery = warnings.where(
      (w) => w.code != IssueCode.a1 && w.code != IssueCode.b1,
    );
    final top = worstOf(warnings);
    final whoError = _showErrors || _addressTouched
        ? addressError(_who.value)?.body
        : null;
    final fixedError = _showErrors && _mode == AmountMode.fixed
        ? amountErrors(
            mode: _mode,
            shareBps: null,
            fixedAmount: draft.fixedAmount,
            mint: _mint,
          ).firstOrNull?.body
        : null;

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
          title: Text(_init == null ? 'New payout' : 'Payout ${widget.number}'),
          actions: [
            if (_init != null)
              TextButton(onPressed: _remove, child: const Text('Remove')),
          ],
        ),
        body: SingleChildScrollView(
          controller: _scroll,
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
                error: whoError,
                loading: facts?.isLoading ?? false,
                notice: b1,
              ),
              const SizedBox(height: 12),
              SectionCard(
                key: _whatKey,
                number: 2,
                title: 'What they get',
                children: [
                  const Text(
                    'Which money',
                    style: TextStyle(
                      color: DmColors.muted,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 8),
                  AssetChips(
                    mint: _mint,
                    onChanged: (m) => setState(() {
                      _mint = m;
                      _dirty = true;
                    }),
                  ),
                  const SizedBox(height: 16),
                  AmountModeField(
                    mode: _mode,
                    onMode: (m) => setState(() {
                      _mode = m;
                      _dirty = true;
                    }),
                    share: _share,
                    fixed: _fixed,
                    mint: _mint,
                    onChanged: _changed,
                    fixedError: fixedError,
                    shareFocus: _shareFocus,
                    fixedFocus: _fixedFocus,
                  ),
                  for (final w in [...a1, ...delivery])
                    WarningTile.of(
                      w,
                      // A1 above already offers "Use 100%".
                      onAction:
                          w.action == null ||
                              (w.code == IssueCode.d2 &&
                                  a1.isNotEmpty &&
                                  w.action == a1.first.action)
                          ? null
                          : () => _act(w),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              _whenSection(draft),
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
                  text: _previewText(
                    draft,
                    preview.amounts[index],
                    widget.basis(_mint, all),
                    fee,
                  ),
                  issue: top,
                  onIssue: () => _reveal(
                    top?.code == IssueCode.b1
                        ? _whoKey
                        : top?.code == IssueCode.d1
                        ? _whenKey
                        : _whatKey,
                  ),
                ),
                if (fee.failed)
                  const Padding(
                    padding: EdgeInsets.only(top: 4),
                    child: Text(
                      "Couldn't load fees. Amounts shown before fees.",
                      style: TextStyle(color: DmColors.muted, fontSize: 12),
                    ),
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

  InlineSpan _previewText(
    PayoutDraft d,
    PayoutAmount amount,
    BalanceBasis? basis,
    FeeInfo fee,
  ) {
    final tail = ' to ${d.who} after ${delayText(d.afterSecs)} of silence';
    if (d.amount == null) {
      return const TextSpan(text: 'Enter an amount to see what they get.');
    }
    final net = amount.net;
    if (net == null || basis == null) {
      return TextSpan(text: '${payoutAmountLabel(d)}$tail.');
    }
    return TextSpan(
      children: [
        TextSpan(
          text: basis.example
              ? 'If the plan holds ${moneyText(basis.amount, d.mint)}: ≈\u00a0'
              : '≈\u00a0',
        ),
        TextSpan(
          text: moneyText(net, d.mint),
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        TextSpan(text: '$tail ${fee.note(d.rail)}'),
      ],
    );
  }

  Widget _whenSection(PayoutDraft d) {
    final interval = widget.intervalSecs;
    final chips = delayChoices(interval);
    final error = delayError(_after, interval);
    final earlier = [
      for (final (n, p) in widget.others)
        if (p.mint == _mint && p.afterSecs < _after)
          'Payout $n (${p.who}, ${delayText(p.afterSecs)})',
    ];
    const muted = TextStyle(color: DmColors.muted, height: 1.4);
    return SectionCard(
      key: _whenKey,
      number: 3,
      title: 'When',
      children: [
        const Text(
          'Send it after this long without a check-in',
          style: TextStyle(color: DmColors.muted, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            for (final s in chips)
              ChoiceChip(
                label: Text(delayText(s)),
                selected: !_custom && _after == s,
                onSelected: (_) {
                  _custom = false;
                  _setAfter(s);
                },
              ),
            ChoiceChip(
              label: const Text('Custom'),
              selected: _custom,
              onSelected: (_) => setState(() {
                _custom = true;
                _customValue.text = '${_after ~/ _customUnit}';
              }),
            ),
          ],
        ),
        if (_custom) ...[
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: TextField(
                  controller: _customValue,
                  onChanged: _setCustom,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Number'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: DropdownButtonFormField<int>(
                  initialValue: _customUnit,
                  items: [
                    const DropdownMenuItem(value: 86400, child: Text('days')),
                    if (widget.demo)
                      const DropdownMenuItem(value: 60, child: Text('minutes')),
                  ],
                  onChanged: (u) {
                    _customUnit = u!;
                    _setCustom(_customValue.text);
                  },
                ),
              ),
            ],
          ),
        ],
        if (error != null)
          WarningTile.of(
            error,
            onAction: error.action == null
                ? null
                : () => setState(() {
                    _custom = false;
                    _after = chips.first;
                    _dirty = true;
                  }),
          ),
        const SizedBox(height: 8),
        DelayStrip(intervalSecs: interval, delaySecs: _after),
        Text(
          'You check in every ${delayText(interval)}. If you stop, this is sent '
          '${delayText(_after)} after your last check-in'
          '${_after > interval ? ' (${delayText(_after - interval)} after you miss one)' : ''}.',
          style: muted,
        ),
        const SizedBox(height: 4),
        const Text(
          'Any check-in before then restarts the clock.',
          style: muted,
        ),
        if (earlier.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text('Runs after: ${earlier.join(', ')}.', style: muted),
        ],
      ],
    );
  }
}
