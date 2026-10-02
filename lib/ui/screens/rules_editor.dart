import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:solana/solana.dart';

import '../../solana/deadman_api.dart';
import '../../state/actions.dart';
import '../../state/providers.dart';
import '../format.dart';
import '../rules_format.dart';
import '../theme.dart';
import '../widgets/feedback.dart';

bool isAddress(String s) {
  try {
    Ed25519HDPublicKey.fromBase58(s.trim());
    return true;
  } catch (_) {
    return false;
  }
}

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
        : r.mint == null
        ? sol(r.amount, digits: 4)
        : '${r.amount}',
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
    final parts = beneficiary.text.trim().split(':');
    if (parts.length != 2) return;
    final rail = Rail.values.where((r) => r.name == parts[0]).firstOrNull;
    if (rail == null) return;
    this.rail = rail;
    beneficiary.text = parts[1];
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
      final v = mint == null
          ? parseSol(this.amount.text)
          : int.tryParse(this.amount.text.trim());
      if (v == null || v <= 0) {
        error('Check each fixed amount');
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

/// Creates the vault when [vault] is null, otherwise replaces its rules.
class RulesEditorPage extends ConsumerStatefulWidget {
  const RulesEditorPage({super.key, this.vault});

  final VaultState? vault;

  @override
  ConsumerState<RulesEditorPage> createState() => _RulesEditorPageState();
}

class _RulesEditorPageState extends ConsumerState<RulesEditorPage> {
  late Cadence _cadence = Cadence.of(
    widget.vault?.intervalSecs ?? Cadence.week.interval,
  );
  late final List<_Draft> _drafts = widget.vault == null
      ? [_Draft(afterSecs: _cadence.release)]
      : widget.vault!.rules.map(_Draft.of).toList();
  late final _guardian = TextEditingController(
    text: widget.vault?.guardian ?? '',
  );
  final _deposit = TextEditingController(text: '0.1');
  bool _busy = false;

  bool get _creating => widget.vault == null;

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
    final g = _guardian.text.trim();
    if (g.isNotEmpty && !isAddress(g)) {
      return err('Guardian address is invalid');
    }

    setState(() => _busy = true);
    final actions = ref.read(actionsProvider);
    final ok = await runGuarded(
      context,
      () => _creating
          ? actions.createVault(
              rules: rules,
              intervalSecs: _cadence.interval,
              lockSecs: _cadence.lock,
              depositLamports: parseSol(_deposit.text) ?? 0,
            )
          : actions.updatePolicy(
              intervalSecs: _cadence.interval,
              lockSecs: _cadence.lock,
              rules: rules,
              guardian: g.isEmpty ? null : g,
            ),
      success: _creating ? 'Deadman armed' : 'Release plan updated',
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final fees = ref.watch(feesProvider).value;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: DmColors.bg,
        title: Text(_creating ? 'Arm your switch' : 'Release plan'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
        children: [
          Text(
            'Each tier releases an amount to someone after you have been silent for a while. '
            'Tiers run in order; a single check-in resets every pending tier.',
            style: t.bodyMedium?.copyWith(color: DmColors.muted, height: 1.4),
          ),
          const SizedBox(height: 18),
          const Text('Check in every', style: TextStyle(color: DmColors.muted)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              for (final c in Cadence.values)
                ChoiceChip(
                  label: Text(c.label),
                  selected: _cadence == c,
                  onSelected: (_) => setState(() => _cadence = c),
                ),
            ],
          ),
          const SizedBox(height: 18),
          for (final (i, d) in _drafts.indexed)
            _TierCard(
              index: i,
              draft: d,
              fees: fees,
              onRemove: _drafts.length > 1
                  ? () => setState(() => _drafts.removeAt(i))
                  : null,
              onChanged: () => setState(() {}),
            ),
          if (_drafts.length < 8)
            OutlinedButton.icon(
              onPressed: () => setState(
                () => _drafts.add(_Draft(afterSecs: _cadence.release * 2)),
              ),
              icon: const Icon(Icons.add),
              label: const Text('Add tier'),
            ),
          const SizedBox(height: 18),
          if (_creating)
            TextField(
              controller: _deposit,
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

class _TierCard extends StatelessWidget {
  const _TierCard({
    required this.index,
    required this.draft,
    required this.fees,
    required this.onRemove,
    required this.onChanged,
  });

  final int index;
  final _Draft draft;
  final FeeSchedule? fees;
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
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            decoration: InputDecoration(
                              suffixText: d.mode == AmountMode.percent
                                  ? '%'
                                  : d.mint == null
                                  ? 'SOL'
                                  : 'units',
                            ),
                          ),
                        ),
                      ],
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

/// SOL by default; any SPL mint (e.g. USDC, JitoSOL) the vault holds.
class _AssetPicker extends StatelessWidget {
  const _AssetPicker({required this.mint, required this.onChanged});

  final String? mint;
  final ValueChanged<String?> onChanged;

  Future<void> _pick(BuildContext context) async {
    final controller = TextEditingController(text: mint ?? '');
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: DmColors.surface,
        title: const Text('Asset'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            labelText: 'Token mint (empty = SOL)',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, ''),
            child: const Text('Use SOL'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('OK'),
          ),
        ],
      ),
    );
    if (result == null) return;
    if (result.isEmpty) return onChanged(null);
    if (!isAddress(result)) {
      if (context.mounted) toast(context, 'Invalid mint address', error: true);
      return;
    }
    onChanged(result);
  }

  @override
  Widget build(BuildContext context) => TextButton.icon(
    onPressed: () => _pick(context),
    icon: const Icon(Icons.token_outlined, size: 18),
    label: Text(mint == null ? 'Asset: SOL' : 'Asset: ${short(mint!)}'),
  );
}
