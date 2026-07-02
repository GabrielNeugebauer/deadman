import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../solana/deadman_api.dart';
import '../../state/actions.dart';
import '../../state/providers.dart';
import '../format.dart';
import '../rules_format.dart';
import '../theme.dart';
import '../widgets/feedback.dart';

/// Family Circle: vaults naming this wallet (or this device's claim keys)
/// as a beneficiary or guardian.
class CircleTab extends ConsumerWidget {
  const CircleTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    final me = ref.watch(sessionProvider.select((s) => s.owner)) ?? '';
    final watched = ref.watch(watchedVaultsProvider);
    final keys = ref.watch(myBeneficiaryKeysProvider).value ?? {me};
    return SafeArea(
      child: RefreshIndicator(
        onRefresh: () async => ref.invalidate(watchedVaultsProvider),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
          children: [
            Text('Family Circle', style: t.headlineMedium),
            const SizedBox(height: 6),
            const Text(
              'People who named you in their release plan.',
              style: TextStyle(color: DmColors.muted),
            ),
            const SizedBox(height: 20),
            ...watched.when(
              loading: () => [const Center(child: CircularProgressIndicator())],
              error: (e, _) => [
                Text('$e', style: const TextStyle(color: DmColors.danger)),
              ],
              data: (list) => list.isEmpty
                  ? [_Empty(address: me)]
                  : [
                      for (final v in list)
                        _PersonCard(vault: v, me: me, keys: keys),
                    ],
            ),
          ],
        ),
      ),
    );
  }
}

class _PersonCard extends ConsumerStatefulWidget {
  const _PersonCard({
    required this.vault,
    required this.me,
    required this.keys,
  });

  final VaultState vault;
  final String me;
  final Set<String> keys;

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
    final isGuardian = v.guardian == widget.me;
    final mine = [
      for (final (i, r) in v.rules.indexed)
        if (widget.keys.contains(r.beneficiary)) (i, r),
    ];
    final next = v.nextRuleDue;

    final (status, color) = next == null
        ? ('Plan fully released', DmColors.muted)
        : now > next
        ? ('Silent past a release tier', DmColors.danger)
        : now > v.pulseDue
        ? ('Missed a check-in', DmColors.warn)
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
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    short(v.owner),
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 16,
                    ),
                  ),
                  const Spacer(),
                  if (isGuardian)
                    const Text(
                      'guardian',
                      style: TextStyle(color: DmColors.plus),
                    ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                status,
                style: TextStyle(color: color, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 4),
              Text(
                'Last pulse ${ago(v.lastPulse, now)} · ${v.streak}-day streak',
                style: const TextStyle(color: DmColors.muted),
              ),
              for (final (i, r) in mine) ...[
                const Divider(height: 24, color: DmColors.line),
                Row(
                  children: [
                    Expanded(child: Text(amountLabel(r))),
                    RailBadge(r.rail),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  r.executed
                      ? 'Released ${ago(r.executedAt, now)}: ${r.mint == null ? '${sol(r.paid)} SOL' : '${r.paid} units'}'
                      : v.ruleDueAt(i) > now
                      ? 'Releases after ${span(v.ruleDueAt(i) - now)} more silence'
                      : 'Due now',
                  style: const TextStyle(color: DmColors.muted, fontSize: 13),
                ),
                if (v.canExecute(i, now)) ...[
                  const SizedBox(height: 10),
                  FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: DmColors.danger,
                    ),
                    onPressed: _busy
                        ? null
                        : () => _run(
                            () => actions.executeRule(v.owner, i),
                            'Tier released',
                          ),
                    child: const Text('Release this tier'),
                  ),
                  if (r.rail != Rail.solana)
                    const Padding(
                      padding: EdgeInsets.only(top: 6),
                      child: Text(
                        'Releasing from your wallet links it to this payout. The Deadman keeper releases due tiers automatically.',
                        style: TextStyle(
                          color: DmColors.muted,
                          fontSize: 12,
                          height: 1.35,
                        ),
                      ),
                    ),
                ],
                if (r.executed && r.rail != Rail.solana && r.mint == null) ...[
                  const SizedBox(height: 10),
                  OutlinedButton.icon(
                    onPressed: _busy
                        ? null
                        : () => _run(
                            () async => actions.routePrivately(r.rail),
                            'Routing to your ${r.rail.label} address',
                          ),
                    icon: Icon(r.rail.icon),
                    label: Text('Route privately via ${r.rail.label}'),
                  ),
                ],
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
          const Text(
            'Nobody has named you yet.',
            style: TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          const Text(
            'Share your wallet address for plain Solana payouts, or a private claim code from '
            'Security → Receive privately.',
            style: TextStyle(color: DmColors.muted, height: 1.4),
          ),
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
