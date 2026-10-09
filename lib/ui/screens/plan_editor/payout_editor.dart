import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../solana/deadman_api.dart';
import '../../../state/assets.dart';
import '../../../state/nfts.dart';
import '../../../state/plan_draft.dart';
import '../../../state/providers.dart';
import '../../widgets/brand/brand.dart';
import '../../widgets/editor/amount_mode_field.dart';
import '../../widgets/editor/asset_chips.dart';
import '../../widgets/editor/plan_steps.dart';
import '../../widgets/nft.dart';
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
    required this.demo,
    required this.basis,
    required this.defaultMint,
    required this.defaultAfterSecs,
    this.step = 1,
    this.steps = 3,
  });

  /// Null for a new payout.
  final PayoutDraft? initial;

  /// Display number of this payout.
  final int number;

  /// The plan's other pending payouts with their display numbers.
  final List<(int, PayoutDraft)> others;

  /// Demo timings: minute presets and units.
  final bool demo;

  /// The balance of an asset given all payouts; null while unknown.
  final BalanceBasis? Function(String? mint, List<PayoutDraft> all) basis;
  final String? defaultMint;
  final int defaultAfterSecs;

  /// Where the plan editor that opened this is: "STEP 1/3".
  final int step;
  final int steps;

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
  late bool _custom = !delayChoices(demo: widget.demo).contains(_after);
  late int _customUnit = _after % 86400 == 0
      ? 86400
      : _after % 3600 == 0
      ? 3600
      : 60;
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

  /// An NFT is sent whole: a fixed amount of one.
  PayoutDraft get _draft {
    final nft = isNft(_mint);
    return PayoutDraft(
      beneficiary: _who.value,
      rail: _who.rail,
      mint: _mint,
      mode: nft ? AmountMode.fixed : _mode,
      shareBps: parseShareBps(_share.text),
      fixedAmount: nft
          ? 1
          : _fixed.text.trim().isEmpty
          ? null
          : parseAmount(_fixed.text, _mint),
      afterSecs: _after,
      name: _who.name.text.trim(),
    );
  }

  void _setMint(String? m) => setState(() {
    if (isNft(_mint) && !isNft(m)) {
      // Leaving an NFT: start the token amount afresh.
      _mode = AmountMode.percent;
      _share.text = '100';
      _fixed.text = '';
    }
    _mint = m;
    _dirty = true;
  });

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
      ...d.validate(),
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
    watchNftNames(ref, [_mint]);
    final fee = watchFeeInfo(ref);
    final owner = ref.watch(sessionProvider.select((s) => s.owner));
    final draft = _draft;
    final nft = draft.nft;
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
    final railError = nft && draft.rail != Rail.solana ? a5 : null;
    final fixedError = _showErrors && _mode == AmountMode.fixed && !nft
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
        appBar: editorAppBar(
          leading: IconButton(
            tooltip: 'Cancel',
            icon: const Icon(Icons.close),
            onPressed: _cancel,
          ),
          title: _init == null ? 'New payout' : 'Payout ${widget.number}',
          step: widget.step,
          steps: widget.steps,
          actions: [
            if (_init != null)
              TextButton(onPressed: _remove, child: const Text('Remove')),
          ],
        ),
        body: SingleChildScrollView(
          controller: _scroll,
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
                mint: _mint,
                error: whoError,
                loading: facts?.isLoading ?? false,
                notice: b1,
              ),
              EditorSection(
                key: _whatKey,
                sprite: EditorSprites.coin,
                title: 'What they get',
                children: [
                  const FieldLabel('Which money'),
                  AssetChips(mint: _mint, allowNft: true, onChanged: _setMint),
                  const SizedBox(height: DMSpace.xl),
                  if (nft)
                    _NftPayout(mint: _mint!, who: draft.who)
                  else
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
                  if (railError != null) WarningTile.of(railError),
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
              _whenSection(draft),
            ],
          ),
        ),
        bottomNavigationBar: EditorBar(
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
                Padding(
                  padding: const EdgeInsets.only(top: DMSpace.xxs),
                  child: Text(
                    "Couldn't load fees. Amounts shown before fees.",
                    style: DMType.outfit(size: 13, color: DM.ash),
                  ),
                ),
              const SizedBox(height: DMSpace.md),
              FilledButton(onPressed: _done, child: const Text('Done')),
            ],
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
    final tail =
        ' to ${d.who} ${delayText(d.afterSecs)} after your last check-in';
    if (d.nft) return TextSpan(text: 'Sends ${assetSymbol(d.mint)}$tail.');
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
          style: DMType.mono(size: 17, weight: FontWeight.w700, color: DM.bone),
        ),
        TextSpan(text: '$tail ${fee.note(d.rail, d.mint)}'),
      ],
    );
  }

  Widget _whenSection(PayoutDraft d) {
    final chips = delayChoices(demo: widget.demo);
    final error = delayError(_after);
    final earlier = [
      for (final (n, p) in widget.others)
        if (p.mint == _mint && p.afterSecs <= _after)
          'Payout $n (${p.who}, ${delayText(p.afterSecs)})',
    ];
    final muted = DMType.outfit(size: 14, color: DM.dust, height: 1.45);
    return EditorSection(
      key: _whenKey,
      sprite: PixelSprites.tombstone,
      title: 'When',
      children: [
        const FieldLabel('Send after this long since your last check-in'),
        Wrap(
          spacing: DMSpace.sm,
          runSpacing: DMSpace.xxs,
          children: [
            for (final s in chips)
              pickChip(
                label: delayText(s),
                mono: true,
                selected: !_custom && _after == s,
                onSelected: (_) {
                  _custom = false;
                  _setAfter(s);
                },
              ),
            pickChip(
              label: 'Custom',
              selected: _custom,
              onSelected: (_) => setState(() {
                _custom = true;
                _customValue.text = '${_after ~/ _customUnit}';
              }),
            ),
          ],
        ),
        if (_custom) ...[
          const SizedBox(height: DMSpace.md),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: LabeledField(
                  label: 'Number',
                  child: TextField(
                    controller: _customValue,
                    onChanged: _setCustom,
                    keyboardType: TextInputType.number,
                    style: DMType.mono(size: 16),
                  ),
                ),
              ),
              const SizedBox(width: DMSpace.md),
              Expanded(
                child: LabeledField(
                  label: 'Unit',
                  child: DropdownButtonFormField<int>(
                    initialValue: _customUnit,
                    items: [
                      const DropdownMenuItem(value: 86400, child: Text('days')),
                      const DropdownMenuItem(value: 3600, child: Text('hours')),
                      const DropdownMenuItem(value: 60, child: Text('minutes')),
                    ],
                    onChanged: (u) {
                      _customUnit = u!;
                      _setCustom(_customValue.text);
                    },
                  ),
                ),
              ),
            ],
          ),
        ],
        if (error != null) WarningTile.of(error),
        const SizedBox(height: DMSpace.lg),
        DelayStrip(delaySecs: _after),
        const SizedBox(height: DMSpace.md),
        Text(
          'If you stop checking in, this is sent ${delayText(_after)} after '
          'your last check-in. Any check-in before then restarts the clock.',
          style: muted,
        ),
        const SizedBox(height: DMSpace.xxs),
        Text(
          'Payouts are sent in order of their wait, shortest first, so a '
          "share is taken from what's left after the earlier ones.",
          style: muted,
        ),
        if (earlier.isNotEmpty) ...[
          const SizedBox(height: DMSpace.xxs),
          Text('Runs after: ${earlier.join(', ')}.', style: muted),
        ],
      ],
    );
  }
}

/// What an NFT payout sends: the NFT itself, whole.
class _NftPayout extends StatelessWidget {
  const _NftPayout({required this.mint, required this.who});

  final String mint;
  final String who;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      NftThumb(mint, size: 56),
      const SizedBox(width: DMSpace.md),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Send ${assetSymbol(mint)} to $who',
              style: DMType.outfit(size: 16, weight: FontWeight.w600),
            ),
            const SizedBox(height: 2),
            Text(
              'An NFT goes to one person, whole. The plan must hold it when '
              'this payout runs.',
              style: DMType.outfit(size: 13.5, color: DM.dust, height: 1.4),
            ),
          ],
        ),
      ),
    ],
  );
}
