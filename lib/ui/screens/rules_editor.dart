import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../solana/deadman_api.dart';
import '../../core/config.dart';
import '../../state/actions.dart';
import '../../state/assets.dart';
import '../../state/plan_math.dart';
import '../../state/providers.dart';
import '../../state/vesting.dart' show isAddress, parseBeneficiary;
import '../format.dart';
import '../rules_format.dart';
import '../theme.dart';
import '../widgets/feedback.dart';

export '../../state/vesting.dart' show isAddress;

enum _Unit {
  minutes(60, 'min'),
  days(86400, 'days');

  const _Unit(this.secs, this.label);
  final int secs;
  final String label;
}

class _Draft {
  _Draft({
    String beneficiary = '',
    this.rail = Rail.solana,
    int afterSecs = 10 * 86400,
    this.mint,
    this.mode = AmountMode.percent,
    String amount = '100',
  }) : beneficiary = TextEditingController(text: beneficiary),
       amount = TextEditingController(text: amount),
       unit = afterSecs % 86400 == 0 ? _Unit.days : _Unit.minutes {
    after = TextEditingController(text: '${afterSecs ~/ unit.secs}');
  }

  factory _Draft.of(RuleSpec r) => _Draft(
    beneficiary: r.beneficiary,
    rail: r.rail,
    afterSecs: r.afterSecs,
    mint: r.mint,
    mode: r.mode,
    amount: r.mode == AmountMode.percent
        ? '${r.amount / 100}'
        : amountInput(r.amount, r.mint),
  );

  final TextEditingController beneficiary;
  final TextEditingController amount;
  late final TextEditingController after;
  Rail rail;
  String? mint;
  AmountMode mode;
  _Unit unit;

  /// Accepts a plain address or a claim code like `zcash:<address>`.
  void applyClaimCode() {
    final (who, rail) = parseBeneficiary(beneficiary.text);
    if (rail == null) return;
    this.rail = rail;
    beneficiary.text = who;
  }

  /// Lenient parse for the live share preview; null while incomplete.
  TierAmount? preview() {
    final after = int.tryParse(this.after.text.trim());
    if (after == null || after <= 0) return null;
    final int? amount;
    if (mode == AmountMode.percent) {
      final pct = double.tryParse(this.amount.text.replaceAll(',', '.'));
      amount = pct == null || pct <= 0 || pct > 100
          ? null
          : (pct * 100).round();
    } else {
      final v = parseAmount(this.amount.text, mint);
      amount = v == null || v <= 0 ? null : v;
    }
    if (amount == null) return null;
    return TierAmount(
      mint: mint,
      mode: mode,
      amount: amount,
      afterSecs: after * unit.secs,
    );
  }

  /// Returns null and reports via [error] when invalid.
  RuleSpec? build(void Function(String) error) {
    applyClaimCode();
    final who = beneficiary.text.trim();
    if (!isAddress(who)) {
      error('Check each beneficiary address');
      return null;
    }
    final after = int.tryParse(this.after.text.trim());
    if (after == null || after <= 0) {
      error('Check each delay');
      return null;
    }
    final int amount;
    if (mode == AmountMode.percent) {
      final pct = double.tryParse(this.amount.text.replaceAll(',', '.'));
      if (pct == null || pct <= 0 || pct > 100) {
        error('Percent must be 0-100');
        return null;
      }
      amount = (pct * 100).round();
    } else {
      final v = parseAmount(this.amount.text, mint);
      if (v == null || v <= 0) {
        error('Check each fixed amount (in ${unitLabel(mint)})');
        return null;
      }
      if (mint == null && v < 1000000) {
        error('Fixed SOL tiers must be at least 0.001 SOL');
        return null;
      }
      amount = v;
    }
    return RuleSpec(
      beneficiary: who,
      rail: rail,
      afterSecs: after * unit.secs,
      mint: mint,
      mode: mode,
      amount: amount,
    );
  }
}

/// Creates the vault when [vault] is null. Otherwise edits it: tiers that
/// already released are shown read-only and only the pending tiers are
/// sent; once every tier has released, saving starts a fresh plan.
class RulesEditorPage extends ConsumerStatefulWidget {
  const RulesEditorPage({super.key, this.vault});

  final VaultState? vault;

  @override
  ConsumerState<RulesEditorPage> createState() => _RulesEditorPageState();
}

const _maxTiers = 8;

class _RulesEditorPageState extends ConsumerState<RulesEditorPage> {
  late Cadence _cadence = Cadence.of(
    widget.vault?.intervalSecs ?? Cadence.week.interval,
  );
  late final _split = widget.vault == null
      ? (history: const <RuleState>[], pending: const <RuleState>[])
      : splitRules(widget.vault!);
  late final List<_Draft> _drafts = _split.pending.isEmpty
      ? [_Draft(afterSecs: _cadence.release)]
      : _split.pending.map(_Draft.of).toList();
  late int _grace =
      widget.vault?.skipGraceSecs ?? AppConfig.defaultSkipGraceSecs;
  late final _guardian = TextEditingController(
    text: widget.vault?.guardian ?? '',
  );
  late final _label = TextEditingController(text: widget.vault?.label ?? '');
  final _deposit = TextEditingController(text: '0.1');
  bool _busy = false;

  bool get _creating => widget.vault == null;
  bool get _fresh => widget.vault?.completed ?? false;
  List<RuleState> get _history => _split.history;

  void _setCadence(Cadence c) => setState(() {
    final wasDemo = _cadence == Cadence.demo;
    _cadence = c;
    if (c == Cadence.demo && _grace == AppConfig.defaultSkipGraceSecs) {
      _grace = 120;
    } else if (wasDemo && c != Cadence.demo && _grace < 86400) {
      _grace = AppConfig.defaultSkipGraceSecs;
    }
  });

  /// Today's balance of an asset, for turning fixed tiers into shares.
  int? _balanceOf(String? mint) {
    if (mint == null) {
      return _creating
          ? parseSol(_deposit.text)
          : widget.vault!.withdrawableLamports;
    }
    if (_creating || mint != AppConfig.usdcMint) return null;
    return ref.read(planUsdcProvider(widget.vault!.address)).value;
  }

  /// Assets whose last tier leaves something in the vault.
  Future<bool> _confirmLeftovers(List<RuleSpec> rules) async {
    final open = previewShares(
      rules.map(TierAmount.of).toList(),
      balanceOf: _balanceOf,
    ).where((a) => !a.lastTakesAll).toList();
    if (open.isEmpty) return true;
    final lines = [
      for (final a in open)
        '• ${assetName(a.mint)}: ${a.leftover == null ? 'part of the balance' : '${percentText(a.leftover!)} of today\'s balance'} stays in the vault',
    ];
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            backgroundColor: DmColors.surface,
            title: const Text('Funds will be left behind'),
            content: Text(
              '${lines.join('\n')}\n\n'
              'The last tier for an asset should be 100% of what remains. '
              'Anything left after it, and anything that arrives later, stays in the vault '
              'once you are gone: nobody else can withdraw it.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Go back'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Save anyway'),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<void> _save() async {
    void err(String m) => toast(context, m, error: true);
    final rules = <RuleSpec>[];
    for (final d in _drafts) {
      final r = d.build(err);
      if (r == null) return;
      if (r.afterSecs < _cadence.interval + 60) {
        return err('Each delay must be longer than your check-in cadence');
      }
      rules.add(r);
    }
    rules.sort((a, b) => a.afterSecs.compareTo(b.afterSecs));
    if (rules.length + _history.length > _maxTiers) {
      return err(
        'A plan holds at most $_maxTiers tiers, released ones included',
      );
    }
    final g = _guardian.text.trim();
    if (g.isNotEmpty && !isAddress(g)) {
      return err('Guardian address is invalid');
    }
    final label = _label.text.trim();
    if (utf8.encode(label).length > 32) {
      return err('Plan name must be 32 characters or fewer');
    }
    if (!await _confirmLeftovers(rules) || !mounted) return;

    setState(() => _busy = true);
    final actions = ref.read(actionsProvider);
    var unguarded = const <VaultState>[];
    final ok = await runGuarded(
      context,
      () async => _creating
          ? unguarded = await actions.createVault(
              label: label,
              rules: rules,
              intervalSecs: _cadence.interval,
              lockSecs: _cadence.lock,
              skipGraceSecs: _grace,
              depositLamports: parseSol(_deposit.text) ?? 0,
            )
          : await actions.updatePolicy(
              planId: widget.vault!.planId,
              label: label,
              intervalSecs: _cadence.interval,
              lockSecs: _cadence.lock,
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
          ? (_creating ? 'Deadman armed' : 'Release plan updated')
          : 'Deadman armed. ${unguarded.length == 1 ? '1 older plan is' : '${unguarded.length} older plans are'} '
                'still guarded by another device (${unguarded.map(planName).join(', ')}): '
                'use Security → Move guard to this phone.',
      error: unguarded.isNotEmpty,
    );
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final fees = ref.watch(feesProvider).value;
    final previews = previewShares([
      for (final d in _drafts) d.preview(),
    ], balanceOf: _balanceOf);
    final shareOf = <int, double?>{
      for (final a in previews)
        for (final s in a.tiers) s.index: s.share,
    };
    final choices = graceChoices(demo: _cadence == Cadence.demo);
    if (!choices.any((c) => c.$1 == _grace)) {
      choices.add((_grace, span(_grace)));
    }
    return Scaffold(
      appBar: AppBar(
        backgroundColor: DmColors.bg,
        title: Text(
          _creating
              ? 'New release plan'
              : _fresh
              ? 'Start a new plan'
              : 'Edit release plan',
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
        children: [
          Text(
            'Each tier releases an amount to someone after you have been silent for a while. '
            'Tiers run in order; a single check-in resets every pending tier. '
            'A percentage is taken from what is left of that asset when the tier runs.',
            style: t.bodyMedium?.copyWith(color: DmColors.muted, height: 1.4),
          ),
          if (_fresh) ...[
            const SizedBox(height: 10),
            const Text(
              'Every tier of this plan has released. Saving starts a fresh plan with new tiers.',
              style: TextStyle(color: DmColors.warn, height: 1.4),
            ),
          ],
          const SizedBox(height: 18),
          TextField(
            controller: _label,
            maxLength: 32,
            decoration: const InputDecoration(
              labelText: 'Plan name',
              hintText: 'e.g. Kids, Emergency fund',
              prefixIcon: Icon(Icons.label_outline),
            ),
          ),
          const SizedBox(height: 10),
          const Text('Check in every', style: TextStyle(color: DmColors.muted)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              for (final c in Cadence.values)
                ChoiceChip(
                  label: Text(c.label),
                  selected: _cadence == c,
                  onSelected: (_) => _setCadence(c),
                ),
            ],
          ),
          const SizedBox(height: 14),
          const Text(
            "If a tier can't pay, others continue after",
            style: TextStyle(color: DmColors.muted),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              for (final (secs, label) in choices)
                ChoiceChip(
                  label: Text(label),
                  selected: _grace == secs,
                  onSelected: (_) => setState(() => _grace = secs),
                ),
            ],
          ),
          const SizedBox(height: 4),
          const Text(
            'A due tier that still cannot pay this long after it fell due can be skipped, '
            'so one broken destination never blocks the rest. Its share stays reserved '
            'for its beneficiary to claim.',
            style: TextStyle(color: DmColors.muted, fontSize: 12, height: 1.35),
          ),
          const SizedBox(height: 18),
          for (final (i, r) in _history.indexed)
            _HistoryTile(index: i, rule: r),
          for (final (i, d) in _drafts.indexed)
            _TierCard(
              index: _history.length + i,
              draft: d,
              fees: fees,
              share: shareOf[i],
              onRemove: _drafts.length > 1
                  ? () => setState(() => _drafts.removeAt(i))
                  : null,
              onChanged: () => setState(() {}),
            ),
          if (_drafts.length + _history.length < _maxTiers)
            OutlinedButton.icon(
              onPressed: () => setState(
                () => _drafts.add(_Draft(afterSecs: _cadence.release * 2)),
              ),
              icon: const Icon(Icons.add),
              label: const Text('Add tier'),
            ),
          if (previews.isNotEmpty) ...[
            const SizedBox(height: 12),
            _SharePreview(
              previews: previews,
              drafts: _drafts,
              offset: _history.length,
            ),
          ],
          const SizedBox(height: 18),
          if (_creating)
            TextField(
              controller: _deposit,
              onChanged: (_) => setState(() {}),
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const InputDecoration(
                labelText: 'Initial deposit',
                suffixText: 'SOL',
                prefixIcon: Icon(Icons.savings_outlined),
              ),
            )
          else
            TextField(
              controller: _guardian,
              decoration: const InputDecoration(
                labelText: 'Guardian (optional)',
                helperText: 'Can freeze your vault and co-sign an early unlock. Never moves funds.',
                helperMaxLines: 2,
                prefixIcon: Icon(Icons.shield_outlined),
              ),
            ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: _busy ? null : _save,
            child: _busy
                ? const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(_creating ? 'Arm Deadman' : 'Save with wallet'),
          ),
          if (_creating) ...[
            const SizedBox(height: 12),
            const Text(
              "One wallet approval creates the vault, funds this phone's guard key with 0.01 SOL "
              'for check-in fees, and makes your deposit.',
              style: TextStyle(
                color: DmColors.muted,
                fontSize: 12,
                height: 1.4,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// A tier that already released, or was skipped (its share reserved and
/// still claimable): history, not editable.
class _HistoryTile extends StatelessWidget {
  const _HistoryTile({required this.index, required this.rule});

  final int index;
  final RuleState rule;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Opacity(
      opacity: 0.55,
      child: Card(
        child: ListTile(
          leading: Icon(
            rule.executed ? Icons.check_circle : Icons.savings_outlined,
            color: DmColors.muted,
          ),
          title: Text('Tier ${index + 1} · ${doneLabel(rule)}'),
          subtitle: Text(
            '${amountLabel(rule)} → ${short(rule.beneficiary)}\n'
            '${rule.executed ? 'Kept as history; it will not pay again.' : 'Its share stays reserved until its beneficiary claims it.'}',
          ),
          isThreeLine: true,
          trailing: RailBadge(rule.rail),
        ),
      ),
    ),
  );
}

/// Effective share of today's balance per asset: percentages compound.
class _SharePreview extends StatelessWidget {
  const _SharePreview({
    required this.previews,
    required this.drafts,
    required this.offset,
  });

  final List<AssetPreview> previews;
  final List<_Draft> drafts;

  /// Number of history tiers shown before the drafts.
  final int offset;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            "Effective share of today's balance",
            style: TextStyle(fontWeight: FontWeight.w600),
          ),
          for (final a in previews) ...[
            const SizedBox(height: 8),
            Text(
              '${assetName(a.mint)}: ${[for (final s in a.tiers) 'Tier ${offset + s.index + 1} ${s.share == null ? '?' : percentText(s.share!)}', if (a.leftover == null) '? left in vault' else '${percentText(a.leftover!)} left in vault'].join(' · ')}',
              style: TextStyle(
                color: a.lastTakesAll ? DmColors.muted : DmColors.warn,
                height: 1.35,
              ),
            ),
            if (!a.lastTakesAll)
              const Padding(
                padding: EdgeInsets.only(top: 2),
                child: Text(
                  'Make the last tier 100% of what remains, or the rest stays in the vault after you are gone.',
                  style: TextStyle(
                    color: DmColors.warn,
                    fontSize: 12,
                    height: 1.35,
                  ),
                ),
              ),
          ],
        ],
      ),
    ),
  );
}

class _TierCard extends StatelessWidget {
  const _TierCard({
    required this.index,
    required this.draft,
    required this.fees,
    required this.share,
    required this.onRemove,
    required this.onChanged,
  });

  final int index;
  final _Draft draft;
  final FeeSchedule? fees;

  /// Fraction of today's balance this tier pays, when known.
  final double? share;
  final VoidCallback? onRemove;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final d = draft;
    final feePct = fees == null ? null : fees!.bpsFor(d.rail) / 100;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 6, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    'Tier ${index + 1}',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const Spacer(),
                  if (onRemove != null)
                    IconButton(
                      onPressed: onRemove,
                      icon: const Icon(
                        Icons.close,
                        color: DmColors.muted,
                        size: 20,
                      ),
                    ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextField(
                      controller: d.beneficiary,
                      onChanged: (_) {
                        final before = d.rail;
                        d.applyClaimCode();
                        if (d.rail != before) onChanged();
                      },
                      decoration: InputDecoration(
                        labelText: d.rail == Rail.solana
                            ? 'Beneficiary wallet'
                            : 'Beneficiary claim code',
                        helperText: d.rail == Rail.solana ? null : 'Paste the code from their Deadman app (Security → Receive privately)',
                        helperMaxLines: 2,
                      ),
                    ),
                    const SizedBox(height: 10),
                    SegmentedButton<Rail>(
                      showSelectedIcon: false,
                      segments: [
                        for (final r in Rail.values)
                          ButtonSegment(
                            value: r,
                            label: Text(r.label),
                            icon: Icon(r.icon, size: 16),
                          ),
                      ],
                      selected: {d.rail},
                      onSelectionChanged: (s) {
                        d.rail = s.first;
                        onChanged();
                      },
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '${d.rail.blurb}${feePct == null ? '' : ' · $feePct% fee on release'}',
                      style: const TextStyle(
                        color: DmColors.muted,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        const Text('After'),
                        const SizedBox(width: 10),
                        SizedBox(
                          width: 72,
                          child: TextField(
                            controller: d.after,
                            onChanged: (_) => onChanged(),
                            keyboardType: TextInputType.number,
                            textAlign: TextAlign.center,
                          ),
                        ),
                        const SizedBox(width: 8),
                        DropdownButton<_Unit>(
                          value: d.unit,
                          underline: const SizedBox(),
                          items: [
                            for (final u in _Unit.values)
                              DropdownMenuItem(value: u, child: Text(u.label)),
                          ],
                          onChanged: (u) {
                            d.unit = u!;
                            onChanged();
                          },
                        ),
                        const SizedBox(width: 6),
                        const Expanded(
                          child: Text(
                            'of silence',
                            style: TextStyle(color: DmColors.muted),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        SegmentedButton<AmountMode>(
                          showSelectedIcon: false,
                          segments: const [
                            ButtonSegment(
                              value: AmountMode.percent,
                              label: Text('%'),
                            ),
                            ButtonSegment(
                              value: AmountMode.fixed,
                              label: Text('Fixed'),
                            ),
                          ],
                          selected: {d.mode},
                          onSelectionChanged: (s) {
                            d.mode = s.first;
                            onChanged();
                          },
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: TextField(
                            controller: d.amount,
                            onChanged: (_) => onChanged(),
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            decoration: InputDecoration(
                              suffixText: d.mode == AmountMode.percent
                                  ? '% of remaining'
                                  : unitLabel(d.mint),
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (share != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          "≈ ${percentText(share!)} of today's ${assetName(d.mint)} balance",
                          style: const TextStyle(
                            color: DmColors.muted,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    const SizedBox(height: 8),
                    _AssetPicker(
                      mint: d.mint,
                      onChanged: (m) {
                        d.mint = m;
                        onChanged();
                      },
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Presets (SOL, USDC, JitoSOL on mainnet) plus any other SPL mint the
/// vault holds.
class _AssetPicker extends StatelessWidget {
  const _AssetPicker({required this.mint, required this.onChanged});

  final String? mint;
  final ValueChanged<String?> onChanged;

  bool get _custom => !presetAssets.any((a) => a.mint == mint);

  Future<void> _pickOther(BuildContext context) async {
    final controller = TextEditingController(text: _custom ? mint : '');
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: DmColors.surface,
        title: const Text('Other token'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            labelText: 'Token mint address',
            helperText: 'Fixed amounts for other tokens are in base units.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('OK'),
          ),
        ],
      ),
    );
    if (result == null || result.isEmpty) return;
    if (!isAddress(result)) {
      if (context.mounted) toast(context, 'Invalid mint address', error: true);
      return;
    }
    onChanged(knownAsset(result)?.mint ?? result);
  }

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 8,
    runSpacing: 4,
    crossAxisAlignment: WrapCrossAlignment.center,
    children: [
      const Icon(Icons.token_outlined, size: 18, color: DmColors.muted),
      for (final a in presetAssets)
        ChoiceChip(
          label: Text(a.symbol),
          selected: mint == a.mint,
          onSelected: (_) => onChanged(a.mint),
        ),
      ChoiceChip(
        label: Text(_custom ? 'Other: ${short(mint!)}' : 'Other token'),
        selected: _custom,
        onSelected: (_) => _pickOther(context),
      ),
    ],
  );
}
