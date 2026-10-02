import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../solana/deadman_api.dart';
import '../../state/actions.dart';
import '../../state/providers.dart';
import '../format.dart';
import '../rules_format.dart';
import '../theme.dart';
import '../widgets/feedback.dart';
import '../widgets/pulse_ring.dart';
import 'rules_editor.dart';

class PulseTab extends ConsumerStatefulWidget {
  const PulseTab({super.key});

  @override
  ConsumerState<PulseTab> createState() => _PulseTabState();
}

class _PulseTabState extends ConsumerState<PulseTab> {
  late final Timer _tick;
  int _now = nowSecs();

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (t) {
      setState(() => _now = nowSecs());
      if (t.tick % 15 == 0) ref.invalidate(vaultProvider);
    });
  }

  @override
  void dispose() {
    _tick.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final vault = ref.watch(vaultProvider);
    return SafeArea(
      child: vault.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) =>
            _Retry(message: '$e', onRetry: () => ref.invalidate(vaultProvider)),
        data: (v) => v == null
            ? const _ArmIntro()
            : RefreshIndicator(
                onRefresh: () async => ref.invalidate(vaultProvider),
                child: _VaultView(vault: v, now: _now),
              ),
      ),
    );
  }
}

class _VaultView extends ConsumerWidget {
  const _VaultView({required this.vault, required this.now});

  final VaultState vault;
  final int now;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    final duress = ref.watch(sessionProvider.select((s) => s.duress));
    final next = vault.nextRuleDue;
    final released = vault.rules.where((r) => r.executed).length;
    final inGrace = now > vault.pulseDue;
    final firing = next != null && now > next;

    final color = firing
        ? DmColors.danger
        : inGrace
        ? DmColors.warn
        : DmColors.alive;
    final (big, label, progress) = next == null
        ? ('Done', 'every tier released', 0.0)
        : firing
        ? (span(now - next), 'tier due, releasing', 0.0)
        : inGrace
        ? (
            span(next - now),
            'until next tier',
            (next - now) / (next - vault.pulseDue),
          )
        : (
            span(vault.pulseDue - now),
            'until next check-in',
            (vault.pulseDue - now) / vault.intervalSecs,
          );

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
      children: [
        Row(
          children: [
            Text('Pulse', style: t.headlineMedium),
            const Spacer(),
            if (vault.isLocked(now) && !duress)
              const _Chip(text: 'LOCKED', color: DmColors.warn),
          ],
        ),
        const SizedBox(height: 20),
        Center(
          child: PulseRing(
            progress: progress,
            color: color,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  big,
                  style: t.displayLarge?.copyWith(fontSize: 38, color: color),
                ),
                const SizedBox(height: 4),
                Text(label, style: const TextStyle(color: DmColors.muted)),
              ],
            ),
          ),
        ),
        const SizedBox(height: 24),
        _PulseButton(color: color),
        if (released > 0) ...[
          const SizedBox(height: 12),
          Text(
            '$released of ${vault.rules.length} tiers already released. Checking in stops the rest.',
            textAlign: TextAlign.center,
            style: const TextStyle(color: DmColors.warn),
          ),
        ],
        const SizedBox(height: 16),
        _StreakCard(vault: vault),
        const SizedBox(height: 12),
        _BalanceCard(vault: vault),
        const SizedBox(height: 12),
        _PlanCard(vault: vault, now: now),
        if (vault.isLocked(now) && !duress) ...[
          const SizedBox(height: 12),
          Card(
            child: ListTile(
              leading: const Icon(Icons.lock_clock, color: DmColors.warn),
              title: const Text('Lockdown active'),
              subtitle: Text(
                'Withdrawals and changes frozen for ${span(vault.lockedUntil - now)}',
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _PulseButton extends ConsumerStatefulWidget {
  const _PulseButton({required this.color});

  final Color color;

  @override
  ConsumerState<_PulseButton> createState() => _PulseButtonState();
}

class _PulseButtonState extends ConsumerState<_PulseButton> {
  bool _busy = false;

  Future<void> _pulse() async {
    setState(() => _busy = true);
    await runGuarded(
      context,
      () => ref.read(actionsProvider).pulse(),
      success: 'Pulse recorded on-chain',
    );
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) => FilledButton.icon(
    style: FilledButton.styleFrom(
      backgroundColor: widget.color,
      minimumSize: const Size.fromHeight(64),
    ),
    onPressed: _busy ? null : _pulse,
    icon: _busy
        ? const SizedBox.square(
            dimension: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : const Icon(Icons.fingerprint, size: 28),
    label: const Text("I'm alive", style: TextStyle(fontSize: 18)),
  );
}

class _StreakCard extends StatelessWidget {
  const _StreakCard({required this.vault});

  final VaultState vault;

  @override
  Widget build(BuildContext context) {
    Widget stat(String value, String label) => Expanded(
      child: Column(
        children: [
          Text(value, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 2),
          Text(
            label,
            style: const TextStyle(color: DmColors.muted, fontSize: 12),
          ),
        ],
      ),
    );
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 8),
        child: Row(
          children: [
            const Padding(
              padding: EdgeInsets.only(left: 10),
              child: Icon(
                Icons.local_fire_department,
                color: DmColors.warn,
                size: 30,
              ),
            ),
            stat('${vault.streak}', 'day streak'),
            stat('${vault.bestStreak}', 'best'),
            stat('${vault.totalPulses}', 'pulses'),
          ],
        ),
      ),
    );
  }
}

class _BalanceCard extends ConsumerWidget {
  const _BalanceCard({required this.vault});

  final VaultState vault;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    final earn = ref.watch(earnProvider);
    final actions = ref.read(actionsProvider);

    Future<void> run(
      String title,
      Future<void> Function(int) action,
      String done,
    ) async {
      final lamports = await askAmount(context, title);
      if (lamports == null || !context.mounted) return;
      await runGuarded(context, () => action(lamports), success: done);
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Protected in vault',
              style: TextStyle(color: DmColors.muted),
            ),
            const SizedBox(height: 6),
            Text(
              '${sol(vault.withdrawableLamports)} SOL',
              style: t.headlineMedium,
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () =>
                        run('Deposit SOL', actions.deposit, 'Deposited'),
                    child: const Text('Deposit'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton(
                    onPressed: () =>
                        run('Withdraw SOL', actions.withdraw, 'Withdrawn'),
                    child: const Text('Withdraw'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(foregroundColor: DmColors.alive),
              onPressed: earn.available
                  ? () => run(
                      'Earn with SOL',
                      actions.earn,
                      'Earning in your vault',
                    )
                  : null,
              icon: const Icon(Icons.trending_up),
              label: Text(
                earn.available
                    ? 'Earn staking yield (JitoSOL)'
                    : 'Earn · mainnet only',
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PlanCard extends StatelessWidget {
  const _PlanCard({required this.vault, required this.now});

  final VaultState vault;
  final int now;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 14, 8, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text(
                  'Release plan',
                  style: TextStyle(color: DmColors.muted),
                ),
                const Spacer(),
                TextButton(
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => RulesEditorPage(vault: vault),
                    ),
                  ),
                  child: const Text('Edit'),
                ),
              ],
            ),
            for (final (i, r) in vault.rules.indexed)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: [
                    Icon(
                      r.executed ? Icons.check_circle : Icons.schedule,
                      size: 18,
                      color: r.executed ? DmColors.muted : r.rail.color,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('${amountLabel(r)} → ${short(r.beneficiary)}'),
                          const SizedBox(height: 2),
                          Text(
                            r.executed
                                ? 'Released ${ago(r.executedAt, now)}'
                                : 'After ${span(r.afterSecs)} silent · ${vault.ruleDueAt(i) > now ? 'in ${span(vault.ruleDueAt(i) - now)}' : 'due now'}',
                            style: const TextStyle(
                              color: DmColors.muted,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: RailBadge(r.rail),
                    ),
                  ],
                ),
              ),
            if (vault.guardian != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Row(
                  children: [
                    const Icon(
                      Icons.shield_outlined,
                      size: 18,
                      color: DmColors.plus,
                    ),
                    const SizedBox(width: 10),
                    Text('Guardian ${short(vault.guardian!)}'),
                  ],
                ),
              ),
            const SizedBox(height: 6),
            Text(
              'Check in every ${span(vault.intervalSecs)}',
              style: const TextStyle(color: DmColors.muted, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}

class _ArmIntro extends ConsumerWidget {
  const _ArmIntro();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    final fees = ref.watch(feesProvider).value;
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text('Arm your switch', style: t.headlineMedium),
        const SizedBox(height: 10),
        Text(
          'Build a release plan: who receives what, after how long without a check-in, '
          'and how it gets there: a plain Solana transfer, privately through Cloak, or as shielded Zcash.',
          style: t.bodyMedium?.copyWith(color: DmColors.muted, height: 1.45),
        ),
        const SizedBox(height: 22),
        for (final r in Rail.values)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Card(
              child: ListTile(
                leading: Icon(r.icon, color: r.color),
                title: Text(r.label),
                subtitle: Text(r.blurb),
              ),
            ),
          ),
        const SizedBox(height: 14),
        FilledButton(
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute<void>(builder: (_) => const RulesEditorPage()),
          ),
          child: const Text('Build release plan'),
        ),
        const SizedBox(height: 10),
        Text(
          fees == null
              ? 'No subscription. Deadman only charges when a tier releases funds.'
              : 'No subscription. Deadman only charges when a tier releases funds: '
                    '${fees.feeBpsPublic / 100}% on Solana transfers, ${fees.feeBpsPrivate / 100}% on private rails.',
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: DmColors.muted,
            fontSize: 12,
            height: 1.4,
          ),
        ),
      ],
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.14),
      borderRadius: BorderRadius.circular(99),
    ),
    child: Text(
      text,
      style: TextStyle(
        color: color,
        fontWeight: FontWeight.w700,
        fontSize: 12,
        letterSpacing: 1,
      ),
    ),
  );
}

class _Retry extends StatelessWidget {
  const _Retry({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.cloud_off, color: DmColors.muted, size: 36),
          const SizedBox(height: 12),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(color: DmColors.muted),
          ),
          const SizedBox(height: 12),
          TextButton(onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
    ),
  );
}

Future<int?> askAmount(BuildContext context, String title) {
  final controller = TextEditingController();
  return showDialog<int>(
    context: context,
    builder: (context) => AlertDialog(
      backgroundColor: DmColors.surface,
      title: Text(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: const InputDecoration(
          suffixText: 'SOL',
          labelText: 'Amount',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, parseSol(controller.text)),
          child: const Text('Confirm'),
        ),
      ],
    ),
  );
}
