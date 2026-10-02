import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../solana/deadman_api.dart';
import '../../state/actions.dart';
import '../../state/providers.dart';
import '../theme.dart';
import '../widgets/feedback.dart';
import 'pulse_tab.dart';

Future<void> showPolicySheet(BuildContext context, VaultState vault) => showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: DmColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => _PolicySheet(vault: vault),
    );

class _HeirRow {
  _HeirRow(String wallet, int bps)
      : address = TextEditingController(text: wallet),
        percent = TextEditingController(text: bps == 0 ? '' : '${bps / 100}');

  final TextEditingController address;
  final TextEditingController percent;
}

class _PolicySheet extends ConsumerStatefulWidget {
  const _PolicySheet({required this.vault});

  final VaultState vault;

  @override
  ConsumerState<_PolicySheet> createState() => _PolicySheetState();
}

class _PolicySheetState extends ConsumerState<_PolicySheet> {
  late final List<_HeirRow> _rows =
      widget.vault.heirs.map((h) => _HeirRow(h.wallet, h.bps)).toList();
  late final _guardian = TextEditingController(text: widget.vault.guardian ?? '');
  late Cadence _cadence = Cadence.of(widget.vault.intervalSecs);
  bool _busy = false;

  bool get _plus => widget.vault.isPlus(nowSecs());

  Future<void> _save() async {
    final heirs = <Heir>[];
    for (final r in _rows) {
      final pct = double.tryParse(r.percent.text.replaceAll(',', '.'));
      if (!isAddress(r.address.text) || pct == null || pct <= 0) {
        toast(context, 'Check each heir address and percentage', error: true);
        return;
      }
      heirs.add(Heir(wallet: r.address.text.trim(), bps: (pct * 100).round()));
    }
    if (heirs.fold<int>(0, (s, h) => s + h.bps) != 10000) {
      toast(context, 'Shares must add up to 100%', error: true);
      return;
    }
    final g = _guardian.text.trim();
    if (g.isNotEmpty && !isAddress(g)) {
      toast(context, 'Guardian address is invalid', error: true);
      return;
    }
    setState(() => _busy = true);
    final ok = await runGuarded(
      context,
      () => ref.read(actionsProvider).updatePolicy(
            intervalSecs: _cadence.interval,
            graceSecs: _cadence.grace,
            lockSecs: _cadence.lock,
            heirs: heirs,
            guardian: g.isEmpty ? null : g,
          ),
      success: 'Policy updated',
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 20, 20, 20 + MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Inheritance policy', style: t.titleLarge),
            const SizedBox(height: 16),
            for (final (i, r) in _rows.indexed)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Row(
                  children: [
                    Expanded(
                      flex: 3,
                      child: TextField(
                        controller: r.address,
                        decoration: InputDecoration(labelText: 'Heir ${i + 1}'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 84,
                      child: TextField(
                        controller: r.percent,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        decoration: const InputDecoration(suffixText: '%'),
                      ),
                    ),
                    if (_rows.length > 1)
                      IconButton(
                        onPressed: () => setState(() => _rows.removeAt(i)),
                        icon: const Icon(Icons.close, color: DmColors.muted),
                      ),
                  ],
                ),
              ),
            if (_plus && _rows.length < 4)
              TextButton.icon(
                onPressed: () => setState(() => _rows.add(_HeirRow('', 0))),
                icon: const Icon(Icons.add),
                label: const Text('Add heir'),
              ),
            if (_plus) ...[
              const SizedBox(height: 8),
              TextField(
                controller: _guardian,
                decoration: const InputDecoration(
                  labelText: 'Guardian (optional)',
                  helperText: 'Can freeze your vault and co-sign an early unlock. Never moves funds.',
                  prefixIcon: Icon(Icons.shield_outlined),
                ),
              ),
            ] else
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 6),
                child: Text('Deadman Plus adds up to 4 heirs and a guardian.',
                    style: TextStyle(color: DmColors.plus)),
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
            const SizedBox(height: 22),
            FilledButton(
              onPressed: _busy ? null : _save,
              child: _busy
                  ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Save with wallet'),
            ),
          ],
        ),
      ),
    );
  }
}
