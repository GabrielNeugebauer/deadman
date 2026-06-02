import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../solana/deadman_api.dart';
import '../../state/actions.dart';
import '../../state/providers.dart';
import '../format.dart';
import '../theme.dart';
import '../widgets/feedback.dart';

/// Family Circle: vaults where this wallet is an heir or the guardian.
class CircleTab extends ConsumerWidget {
  const CircleTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    final me = ref.watch(sessionProvider.select((s) => s.owner)) ?? '';
    final watched = ref.watch(watchedVaultsProvider);
    return SafeArea(
      child: RefreshIndicator(
        onRefresh: () async => ref.invalidate(watchedVaultsProvider),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
          children: [
            Text('Family Circle', style: t.headlineMedium),
            const SizedBox(height: 6),
            const Text('People who named you as heir or guardian.',
                style: TextStyle(color: DmColors.muted)),
            const SizedBox(height: 20),
            ...watched.when(
              loading: () => [const Center(child: CircularProgressIndicator())],
              error: (e, _) => [Text('$e', style: const TextStyle(color: DmColors.danger))],
              data: (list) => list.isEmpty
                  ? [_Empty(address: me)]
                  : [for (final v in list) _PersonCard(vault: v, me: me)],
            ),
          ],
        ),
      ),
    );
  }
}

class _PersonCard extends ConsumerStatefulWidget {
  const _PersonCard({required this.vault, required this.me});

  final VaultState vault;
  final String me;

  @override
  ConsumerState<_PersonCard> createState() => _PersonCardState();
}

class _PersonCardState extends ConsumerState<_PersonCard> {
  bool _busy = false;

  Future<void> _run(Future<void> Function() action, String success) async {
    setState(() => _busy = true);
    await runGuarded(context, action, success: success);
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final v = widget.vault;
    final now = nowSecs();
    final heir = v.heirs.where((h) => h.wallet == widget.me).firstOrNull;
    final isGuardian = v.guardian == widget.me;
    final triggered = v.status == VaultStatus.triggered;

    final (status, color) = triggered
        ? ('Switch fired', DmColors.danger)
        : v.canTrigger(now)
            ? ('Silent past deadline', DmColors.danger)
            : now > v.pulseDue
                ? ('In grace period', DmColors.warn)
                : v.isLocked(now)
                    ? ('Locked down', DmColors.warn)
                    : ('Alive', DmColors.alive);

    final actions = ref.read(actionsProvider);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                  ),
                  const SizedBox(width: 10),
                  Text(short(v.owner),
                      style: const TextStyle(fontFamily: 'monospace', fontSize: 16)),
                  const Spacer(),
                  Text(
                    [if (heir != null) 'heir ${heir.bps / 100}%', if (isGuardian) 'guardian']
                        .join(' · '),
                    style: const TextStyle(color: DmColors.muted),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(status, style: TextStyle(color: color, fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              Text(
                'Last pulse ${ago(v.lastPulse, now)} · ${v.streak}-day streak',
                style: const TextStyle(color: DmColors.muted),
              ),
              if (triggered && heir != null && !heir.claimedSol) ...[
                const SizedBox(height: 14),
                FilledButton(
                  onPressed: _busy ? null : () => _run(() => actions.claim(v.owner), 'Share claimed'),
                  child: Text('Claim ${sol(v.solAtTrigger * heir.bps ~/ 10000)} SOL'),
                ),
              ],
              if (!triggered && v.canTrigger(now)) ...[
                const SizedBox(height: 14),
                FilledButton(
                  style: FilledButton.styleFrom(backgroundColor: DmColors.danger),
                  onPressed: _busy ? null : () => _run(() => actions.trigger(v.owner), 'Switch triggered'),
                  child: const Text('Trigger switch'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.address});

  final String address;

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.diversity_3, color: DmColors.plus, size: 30),
              const SizedBox(height: 12),
              const Text('Nobody has named you yet.', style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              const Text('Share your address with family so they can add you as heir or guardian.',
                  style: TextStyle(color: DmColors.muted, height: 1.4)),
              const SizedBox(height: 14),
              OutlinedButton.icon(
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: address));
                  toast(context, 'Address copied');
                },
                icon: const Icon(Icons.copy, size: 18),
                label: Text(short(address)),
              ),
            ],
          ),
        ),
      );
}
