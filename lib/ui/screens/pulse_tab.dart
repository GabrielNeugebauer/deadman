import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:solana/solana.dart';

import '../../solana/deadman_api.dart';
import '../../state/actions.dart';
import '../../state/providers.dart';
import '../format.dart';
import '../theme.dart';
import '../widgets/feedback.dart';
import '../widgets/pulse_ring.dart';
import 'policy_sheet.dart';

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
        error: (e, _) => _Retry(message: '$e', onRetry: () => ref.invalidate(vaultProvider)),
        data: (v) => v == null
            ? const CreateVaultView()
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
    final triggered = vault.status == VaultStatus.triggered;
    final inGrace = now > vault.pulseDue;
    final fireable = vault.canTrigger(now);

    final color = triggered || fireable
        ? DmColors.danger
        : inGrace
            ? DmColors.warn
            : DmColors.alive;
    final progress = triggered
        ? 0.0
        : inGrace
            ? (vault.deadline - now) / vault.graceSecs
            : (vault.pulseDue - now) / vault.intervalSecs;

    final (big, label) = triggered
        ? ('Fired', 'heirs can claim')
        : fireable
            ? (span(now - vault.deadline), 'past deadline')
            : inGrace
                ? (span(vault.deadline - now), 'grace left')
                : (span(vault.pulseDue - now), 'until next pulse');

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
      children: [
        Row(
          children: [
            Text('Pulse', style: t.headlineMedium),
            const Spacer(),
            if (vault.isPlus(now)) const _Chip(text: 'PLUS', color: DmColors.plus),
            if (vault.isLocked(now) && !duress) ...[
              const SizedBox(width: 8),
              const _Chip(text: 'LOCKED', color: DmColors.warn),
            ],
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
                Text(big, style: t.displayLarge?.copyWith(fontSize: 38, color: color)),
                const SizedBox(height: 4),
                Text(label, style: const TextStyle(color: DmColors.muted)),
              ],
            ),
          ),
        ),
        const SizedBox(height: 24),
        if (!triggered) _PulseButton(color: color),
        if (triggered)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Text(
                'Your switch fired ${ago(vault.triggeredAt, now)}. Heirs can now claim their shares.',
                style: const TextStyle(height: 1.4),
              ),
            ),
          ),
        const SizedBox(height: 16),
        _StreakCard(vault: vault),
        const SizedBox(height: 12),
        _BalanceCard(vault: vault, disabled: triggered),
        const SizedBox(height: 12),
        _HeirsCard(vault: vault, now: now, disabled: triggered),
        if (vault.isLocked(now) && !duress) ...[
          const SizedBox(height: 12),
          Card(
            child: ListTile(
              leading: const Icon(Icons.lock_clock, color: DmColors.warn),
              title: const Text('Lockdown active'),
              subtitle: Text('Withdrawals and changes frozen for ${span(vault.lockedUntil - now)}'),
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
    await runGuarded(context, () => ref.read(actionsProvider).pulse(),
        success: 'Pulse recorded on-chain');
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    return FilledButton.icon(
      style: FilledButton.styleFrom(
        backgroundColor: widget.color,
        minimumSize: const Size.fromHeight(64),
      ),
      onPressed: _busy ? null : _pulse,
      icon: _busy
          ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
          : const Icon(Icons.fingerprint, size: 28),
      label: const Text("I'm alive", style: TextStyle(fontSize: 18)),
    );
  }
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
              Text(label, style: const TextStyle(color: DmColors.muted, fontSize: 12)),
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
              child: Icon(Icons.local_fire_department, color: DmColors.warn, size: 30),
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
  const _BalanceCard({required this.vault, required this.disabled});

  final VaultState vault;
  final bool disabled;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    Future<void> move({required bool deposit}) async {
      final lamports = await askAmount(context, deposit ? 'Deposit SOL' : 'Withdraw SOL');
      if (lamports == null || !context.mounted) return;
      final actions = ref.read(actionsProvider);
      await runGuarded(
        context,
        () => deposit ? actions.deposit(lamports) : actions.withdraw(lamports),
        success: deposit ? 'Deposited' : 'Withdrawn',
      );
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Protected in vault', style: TextStyle(color: DmColors.muted)),
            const SizedBox(height: 6),
            Text('${sol(vault.withdrawableLamports)} SOL', style: t.headlineMedium),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: disabled ? null : () => move(deposit: true),
                    child: const Text('Deposit'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton(
                    onPressed: disabled ? null : () => move(deposit: false),
                    child: const Text('Withdraw'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _HeirsCard extends StatelessWidget {
  const _HeirsCard({required this.vault, required this.now, required this.disabled});

  final VaultState vault;
  final int now;
  final bool disabled;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 14, 8, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text('Heirs', style: TextStyle(color: DmColors.muted)),
                const Spacer(),
                TextButton(
                  onPressed: disabled ? null : () => showPolicySheet(context, vault),
                  child: const Text('Edit'),
                ),
              ],
            ),
            for (final h in vault.heirs)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    const Icon(Icons.person_outline, size: 18, color: DmColors.muted),
                    const SizedBox(width: 8),
                    Text(short(h.wallet), style: const TextStyle(fontFamily: 'monospace')),
                    const Spacer(),
                    Padding(
                      padding: const EdgeInsets.only(right: 10),
                      child: Text('${h.bps / 100}%'),
                    ),
                  ],
                ),
              ),
            if (vault.guardian != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    const Icon(Icons.shield_outlined, size: 18, color: DmColors.plus),
                    const SizedBox(width: 8),
                    Text(short(vault.guardian!), style: const TextStyle(fontFamily: 'monospace')),
                    const Spacer(),
                    const Padding(
                      padding: EdgeInsets.only(right: 10),
                      child: Text('guardian', style: TextStyle(color: DmColors.plus)),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 6),
            Text(
              'Check in every ${span(vault.intervalSecs)} · ${span(vault.graceSecs)} grace',
              style: const TextStyle(color: DmColors.muted, fontSize: 12),
            ),
            const SizedBox(height: 6),
          ],
        ),
      ),
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
        child: Text(text,
            style: TextStyle(color: color, fontWeight: FontWeight.w700, fontSize: 12, letterSpacing: 1)),
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
              Text(message, textAlign: TextAlign.center, style: const TextStyle(color: DmColors.muted)),
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
        decoration: const InputDecoration(suffixText: 'SOL', labelText: 'Amount'),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        TextButton(
          onPressed: () => Navigator.pop(context, parseSol(controller.text)),
          child: const Text('Confirm'),
        ),
      ],
    ),
  );
}

bool isAddress(String s) {
  try {
    Ed25519HDPublicKey.fromBase58(s.trim());
    return true;
  } catch (_) {
    return false;
  }
}

/// Preset check-in cadences. "Demo" exists so the switch can fire on camera.
enum Cadence {
  demo('Demo', 120, 60, 300),
  week('7 days', 7 * 86400, 3 * 86400, 3 * 86400),
  month('30 days', 30 * 86400, 7 * 86400, 3 * 86400),
  quarter('90 days', 90 * 86400, 14 * 86400, 7 * 86400);

  const Cadence(this.label, this.interval, this.grace, this.lock);

  final String label;
  final int interval;
  final int grace;
  final int lock;

  static Cadence of(int interval) =>
      values.firstWhere((c) => c.interval == interval, orElse: () => week);
}

class CreateVaultView extends ConsumerStatefulWidget {
  const CreateVaultView({super.key});

  @override
  ConsumerState<CreateVaultView> createState() => _CreateVaultViewState();
}

class _CreateVaultViewState extends ConsumerState<CreateVaultView> {
  final _heir = TextEditingController();
  final _deposit = TextEditingController(text: '0.1');
  Cadence _cadence = Cadence.week;
  bool _busy = false;

  Future<void> _create() async {
    if (!isAddress(_heir.text)) {
      toast(context, 'Enter a valid Solana address for your heir', error: true);
      return;
    }
    final deposit = parseSol(_deposit.text) ?? 0;
    setState(() => _busy = true);
    await runGuarded(
      context,
      () => ref.read(actionsProvider).createVault(
            heirs: [Heir(wallet: _heir.text.trim(), bps: 10000)],
            intervalSecs: _cadence.interval,
            graceSecs: _cadence.grace,
            lockSecs: _cadence.lock,
            depositLamports: deposit,
          ),
      success: 'Deadman armed',
    );
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final balance = ref.watch(walletBalanceProvider).value;
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text('Arm your switch', style: t.headlineMedium),
        const SizedBox(height: 8),
        Text(
          'Pick who inherits and how often you check in. You can change this any time while you are alive and not locked down.',
          style: t.bodyMedium?.copyWith(color: DmColors.muted, height: 1.4),
        ),
        const SizedBox(height: 28),
        TextField(
          controller: _heir,
          decoration: const InputDecoration(
            labelText: 'Heir wallet address',
            prefixIcon: Icon(Icons.person_outline),
          ),
        ),
        const SizedBox(height: 20),
        const Text('Check in every', style: TextStyle(color: DmColors.muted)),
        const SizedBox(height: 10),
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
        const SizedBox(height: 20),
        TextField(
          controller: _deposit,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(
            labelText: 'Initial deposit',
            suffixText: 'SOL',
            helperText: balance == null ? null : 'Wallet: ${sol(balance)} SOL',
            prefixIcon: const Icon(Icons.savings_outlined),
          ),
        ),
        const SizedBox(height: 28),
        FilledButton(
          onPressed: _busy ? null : _create,
          child: _busy
              ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Arm Deadman'),
        ),
        const SizedBox(height: 12),
        const Text(
          'One wallet approval creates the vault, funds this phone\'s guard key with 0.01 SOL for check-in fees, and makes your deposit.',
          style: TextStyle(color: DmColors.muted, fontSize: 12, height: 1.4),
        ),
      ],
    );
  }
}
