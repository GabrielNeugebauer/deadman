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
import '../web/web_ui.dart';
import 'brand/brand.dart';
import 'feedback.dart';
import 'pack_icons.dart';

/// Fine print under a button, a tier or a card: ash. A [problem] (why
/// an action cannot go through, or what to do first) reads in bone with an
/// info mark, never in a status color: amber and red mean plan states.
class FinePrint extends StatelessWidget {
  const FinePrint(this.text, {super.key, this.problem = false});

  final String text;
  final bool problem;

  @override
  Widget build(BuildContext context) {
    final body = Text(
      text,
      style: DMType.outfit(
        size: 13,
        color: problem ? DM.bone : DM.ash,
        height: 1.4,
      ),
    );
    return Padding(
      padding: const EdgeInsets.only(top: DMSpace.sm),
      child: problem
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.only(top: 1),
                  child: Icon(Icons.info_outline, size: 16, color: DM.bone),
                ),
                const SizedBox(width: DMSpace.sm),
                Expanded(child: body),
              ],
            )
          : body,
    );
  }
}

/// Outlined rail tag: "Solana", "Cloak", "Zcash" with the rail's icon.
class RailTag extends StatelessWidget {
  const RailTag(this.rail, {super.key});

  final Rail rail;

  @override
  Widget build(BuildContext context) =>
      DMTag(label: rail.label, icon: rail.icon);
}

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
      padding: const EdgeInsets.only(bottom: DMSpace.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          MonoLabel(label),
          const SizedBox(height: DMSpace.xxs),
          Text(value, style: DMType.mono(size: 14, height: 1.4)),
        ],
      ),
    );
    return AlertDialog(
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
              style: DMType.data(
                // The clock running out is the one status here.
                color: left > 60 ? DM.dust : DM.missed,
                size: 12.5,
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
          padding: const EdgeInsets.only(bottom: DMSpace.lg),
          child: DMCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Ready to route',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    const SizedBox(width: DMSpace.md),
                    RailTag(p.rail),
                  ],
                ),
                const SizedBox(height: DMSpace.xxs),
                Text(
                  'On claim key ${short(p.key.address)}'
                  '${p.destination.isEmpty ? '' : ' → ${short(p.destination)}'}',
                  style: DMType.data(),
                ),
                for (final a in rows) ...[
                  const Divider(height: DMSpace.xxxl),
                  Text(
                    amountText(a.amount, a.mint),
                    style: DMType.mono(size: 17),
                  ),
                  const SizedBox(height: DMSpace.md),
                  OutlinedButton.icon(
                    onPressed: !live || _busy != null
                        ? null
                        : () => _route(p.rail, a.mint),
                    icon: _busy == '${p.rail.name}:${a.mint}'
                        ? const SizedBox.square(
                            dimension: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : RailIcon(p.rail),
                    label: Text(
                      live
                          ? 'Route privately via ${p.rail.label}'
                          : routeOffLabel(p.rail.label, web: web),
                    ),
                  ),
                ],
                if (!live)
                  FinePrint(
                    web
                        ? 'Private routing runs in the Deadman Android app. '
                              'Your claim keys move there with your recovery phrase.'
                        : 'Cloak and NEAR Intents run on Solana mainnet only. '
                              'This build is on ${AppConfig.cluster}.',
                  ),
                if (live && p.destination.isEmpty)
                  const FinePrint(
                    'Set a destination first: Security → Receive privately.',
                    problem: true,
                  ),
              ],
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
      padding: const EdgeInsets.only(bottom: DMSpace.lg),
      child: DMListGroup(
        header: Text(
          'Private transfers',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        children: [
          for (final t in list) _TransferTile(key: ValueKey(t.id), t: t),
        ],
      ),
    );
  }
}

/// Sticker for a transfer's phase. Outcomes, not plan states, so the
/// stickers carry no figure. An interrupted Cloak route can resume, so it
/// reads amber rather than failed.
(DMStatus, String) _phaseSticker(PrivateTransfer t) {
  if (t.status == interruptedStatus) {
    return (DMStatus.missed, 'Interrupted');
  }
  return switch (t.phase) {
    TransferPhase.done => (DMStatus.alive, 'Done'),
    TransferPhase.pending => (DMStatus.released, 'Pending'),
    TransferPhase.refunded => (DMStatus.missed, 'Refunded'),
    TransferPhase.failed => (DMStatus.due, 'Failed'),
  };
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
    final (status, word) = _phaseSticker(shown);
    final amount = amountText(t.amount, t.mint);
    final Widget? trailing = resumableCloak(t)
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
          );
    return Padding(
      padding: EdgeInsets.fromLTRB(
        DMSpace.lg,
        14,
        trailing == null ? DMSpace.lg : DMSpace.xs,
        14,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          RailTile(t.rail),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  t.kind == TransferKind.withdraw
                      ? 'Withdraw $amount to wallet'
                      : t.estimatedOut.isEmpty
                      ? '$amount via ${t.rail.label}'
                      : '$amount → ${t.estimatedOut}',
                  style: DMType.mono(size: 14, height: 1.4),
                ),
                const SizedBox(height: DMSpace.xs),
                Wrap(
                  spacing: DMSpace.sm,
                  runSpacing: DMSpace.xxs,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    StatusSticker(
                      status,
                      label: word,
                      dense: true,
                      showSprite: false,
                    ),
                    Text(
                      ago(t.createdAt, nowSecs()),
                      style: DMType.data(color: DM.ash, size: 12),
                    ),
                  ],
                ),
                const SizedBox(height: DMSpace.xs),
                Text(
                  '${transferStatusText(shown)}'
                  '${live?.hasError == true ? ' (status check failed; pull to refresh)' : ''}',
                  style: DMType.outfit(size: 13, color: DM.ash, height: 1.4),
                ),
              ],
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: DMSpace.xs),
            trailing,
          ],
        ],
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
      padding: const EdgeInsets.only(bottom: DMSpace.lg),
      child: DMCard(
        padding: EdgeInsets.zero,
        child: DMListRow(
          leading: const RailTile(Rail.cloak),
          title: 'Shielded inbox',
          subtitle: 'Payouts held privately at your Cloak address',
          monoSubtitle: false,
          trailing: const DMIcon(DMIcons.chevronRight, color: DM.ash),
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
