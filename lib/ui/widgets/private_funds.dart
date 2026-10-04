import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config.dart';
import '../../solana/deadman_api.dart';
import '../../state/actions.dart';
import '../../state/assets.dart';
import '../../state/private_rails.dart';
import '../../state/providers.dart';
import '../../state/secure_store.dart';
import '../format.dart';
import '../rules_format.dart';
import '../screens/shielded_inbox_screen.dart';
import '../theme.dart';
import '../web/web_ui.dart';
import 'feedback.dart';

const _small = TextStyle(color: DmColors.muted, fontSize: 12, height: 1.35);

/// Quote, confirm, send: moves all of [mint] on [rail]'s claim key to its
/// private destination.
Future<void> routePrivatelyFlow(
  BuildContext context,
  WidgetRef ref,
  Rail rail,
  String? mint,
) async {
  final actions = ref.read(actionsProvider);
  RoutePlan? plan;
  final quoted = await runGuarded(
    context,
    () async => plan = await actions.quotePrivateRoute(rail, mint),
  );
  if (!quoted || !context.mounted) return;
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => RoutePreviewDialog(plan: plan!),
  );
  if (ok != true || !context.mounted) return;
  await runGuarded(
    context,
    () => actions.executePrivateRoute(plan!),
    success: 'Sent. Follow it under Private transfers.',
  );
}

class RoutePreviewDialog extends StatelessWidget {
  const RoutePreviewDialog({super.key, required this.plan});

  final RoutePlan plan;

  @override
  Widget build(BuildContext context) {
    final q = plan.quote;
    final rail = plan.profile.rail;
    final left = q.expiresAt.difference(DateTime.now()).inSeconds;
    Widget line(String label, String value) => Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: _small),
          const SizedBox(height: 2),
          Text(value),
        ],
      ),
    );
    return AlertDialog(
      backgroundColor: DmColors.surface,
      title: Text('Route privately via ${rail.label}'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            line('You send', amountText(q.amountIn, q.inputMint)),
            line('Estimated to arrive', q.estimatedOut),
            line('To', short(plan.profile.destination)),
            line('Fees', quoteFeesText(q)),
            Text(
              left > 0
                  ? 'Quote valid for ${span(left)}'
                  : 'Quote expired; route again',
              style: TextStyle(
                color: left > 60 ? DmColors.muted : DmColors.warn,
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: left > 0 ? () => Navigator.pop(context, true) : null,
          child: const Text('Send'),
        ),
      ],
    );
  }
}

/// Funds sitting on this phone's claim keys, per asset, each with its
/// private route.
class PrivateFundsSection extends ConsumerStatefulWidget {
  const PrivateFundsSection({super.key});

  @override
  ConsumerState<PrivateFundsSection> createState() =>
      _PrivateFundsSectionState();
}

class _PrivateFundsSectionState extends ConsumerState<PrivateFundsSection> {
  String? _busy;

  Future<void> _route(Rail rail, String? mint) async {
    setState(() => _busy = '${rail.name}:$mint');
    await routePrivatelyFlow(context, ref, rail, mint);
    if (mounted) setState(() => _busy = null);
  }

  @override
  Widget build(BuildContext context) {
    final profiles = ref.watch(claimProfilesProvider).value ?? const [];
    final live = ref.watch(privateRailsLiveProvider);
    final web = ref.watch(isWebProvider);
    final cards = <Widget>[];
    for (final p in profiles) {
      final funds = ref.watch(claimFundsProvider(p.key.address)).value;
      final rows = funds == null ? const [] : routableAssets(p.rail, funds);
      if (rows.isEmpty) continue;
      cards.add(
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'Ready to route',
                          style: TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ),
                      RailBadge(p.rail),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'On claim key ${short(p.key.address)}'
                    '${p.destination.isEmpty ? '' : ' → ${short(p.destination)}'}',
                    style: _small,
                  ),
                  for (final a in rows) ...[
                    const Divider(height: 24, color: DmColors.line),
                    Text(amountText(a.amount, a.mint)),
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      onPressed: !live || _busy != null
                          ? null
                          : () => _route(p.rail, a.mint),
                      icon: _busy == '${p.rail.name}:${a.mint}'
                          ? const SizedBox.square(
                              dimension: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Icon(p.rail.icon),
                      label: Text(
                        live
                            ? 'Route privately via ${p.rail.label}'
                            : routeOffLabel(p.rail.label, web: web),
                      ),
                    ),
                  ],
                  if (!live)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        web
                            ? 'Private routing runs in the Deadman Android app. '
                                  'Your claim keys move there with your recovery phrase.'
                            : 'Cloak and NEAR Intents run on Solana mainnet only. '
                                  'This build is on ${AppConfig.cluster}.',
                        style: _small,
                      ),
                    ),
                  if (live && p.destination.isEmpty)
                    const Padding(
                      padding: EdgeInsets.only(top: 8),
                      child: Text(
                        'Set a destination first: Security → Receive privately.',
                        style: TextStyle(color: DmColors.warn, fontSize: 12),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: cards,
    );
  }
}

/// Routing history with live status.
class PrivateTransfersCard extends ConsumerWidget {
  const PrivateTransfersCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = ref.watch(transferHistoryProvider);
    if (list.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 8, 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Private transfers',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              for (final t in list) _TransferTile(key: ValueKey(t.id), t: t),
            ],
          ),
        ),
      ),
    );
  }
}

class _TransferTile extends ConsumerStatefulWidget {
  const _TransferTile({super.key, required this.t});

  final PrivateTransfer t;

  @override
  ConsumerState<_TransferTile> createState() => _TransferTileState();
}

class _TransferTileState extends ConsumerState<_TransferTile> {
  bool _busy = false;

  Future<void> _resume() async {
    setState(() => _busy = true);
    await routePrivatelyFlow(context, ref, Rail.cloak, widget.t.mint);
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.t;
    final pending = t.phase == TransferPhase.pending;
    final live = pending ? ref.watch(transferStatusProvider(t.id)) : null;
    final shown = t.withStatus(live?.value ?? t.status);
    final color = switch (shown.phase) {
      TransferPhase.done => DmColors.alive,
      TransferPhase.pending => DmColors.muted,
      TransferPhase.refunded => DmColors.warn,
      TransferPhase.failed => DmColors.danger,
    };
    final amount = amountText(t.amount, t.mint);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(t.rail.icon, color: t.rail.color),
      title: Text(
        t.kind == TransferKind.withdraw
            ? 'Withdraw $amount to wallet'
            : t.estimatedOut.isEmpty
            ? '$amount via ${t.rail.label}'
            : '$amount → ${t.estimatedOut}',
      ),
      subtitle: Text(
        '${transferStatusText(shown)}'
        '${live?.hasError == true ? ' (status check failed; pull to refresh)' : ''}'
        '\n${ago(t.createdAt, nowSecs())}',
        style: TextStyle(color: color, fontSize: 12, height: 1.35),
      ),
      isThreeLine: true,
      trailing: resumableCloak(t)
          ? TextButton(
              onPressed: _busy || !ref.watch(privateRailsLiveProvider)
                  ? null
                  : _resume,
              child: const Text('Resume'),
            )
          : t.trackingId.isEmpty
          ? null
          : IconButton(
              tooltip: t.rail == Rail.zcash
                  ? 'Copy deposit address'
                  : 'Copy signature',
              icon: const Icon(Icons.copy, size: 18),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: t.trackingId));
                toast(context, 'Tracking id copied');
              },
            ),
    );
  }
}

/// Entry to the shielded inbox, for a Cloak profile with a `cloak:` address.
class ShieldedInboxTile extends ConsumerWidget {
  const ShieldedInboxTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profiles = ref.watch(claimProfilesProvider).value ?? const [];
    final has = profiles.any(
      (ClaimProfile p) => p.rail == Rail.cloak && isCloakAddress(p.destination),
    );
    // Scanning notes needs the Cloak SDK, which runs in the Android app.
    if (!has || ref.watch(isWebProvider)) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Card(
        child: ListTile(
          leading: Icon(Rail.cloak.icon, color: Rail.cloak.color),
          title: const Text('Shielded inbox'),
          subtitle: const Text('Payouts held privately at your Cloak address'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => const ShieldedInboxScreen(),
            ),
          ),
        ),
      ),
    );
  }
}
