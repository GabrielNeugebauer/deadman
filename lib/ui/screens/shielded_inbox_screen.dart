import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config.dart';
import '../../rails/cloak_route.dart';
import '../../state/actions.dart';
import '../../state/assets.dart';
import '../../state/providers.dart';
import '../format.dart';
import '../widgets/brand/brand.dart';
import '../widgets/feedback.dart';

/// Shielded notes paid to this phone's Cloak address. Scans on open: the
/// Cloak SDK runs in a WebView, so only while this screen is in front.
class ShieldedInboxScreen extends ConsumerStatefulWidget {
  const ShieldedInboxScreen({super.key});

  @override
  ConsumerState<ShieldedInboxScreen> createState() =>
      _ShieldedInboxScreenState();
}

class _ShieldedInboxScreenState extends ConsumerState<ShieldedInboxScreen> {
  Future<List<CloakNote>>? _scan;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    if (ref.read(privateRailsLiveProvider)) _start();
  }

  void _start() {
    _scan = ref.read(actionsProvider).scanShieldedInbox();
  }

  void _rescan() => setState(_start);

  Future<void> _withdraw(List<CloakNote> notes) async {
    final owner = ref.read(sessionProvider).owner;
    if (owner == null) return;
    final mint = notes.first.mint;
    final total = notes.fold(0, (sum, n) => sum + n.amount);
    final pool = CloakRoute.pools[mint];
    final fee = pool == null ? null : CloakRoute.exitFee(total, pool);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Withdraw to your wallet?'),
        content: Text(
          '${amountText(total, mint)} leaves the shielded pool to ${short(owner)}.'
          '${fee == null ? '' : ' Cloak keeps about ${amountText(fee, mint)} (0.3% plus a fixed fee).'}'
          '\n\nThe withdrawal is public: waiting a while after the payout makes it '
          'harder to link to the plan.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Withdraw'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    final done = await runGuarded(
      context,
      () => ref.read(actionsProvider).withdrawShielded(notes),
      success: 'Withdrawal sent. Follow it under Private transfers.',
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (done) _rescan();
  }

  @override
  Widget build(BuildContext context) {
    final live = ref.watch(privateRailsLiveProvider);
    final hasWallet = ref.watch(sessionProvider.select((s) => s.owner)) != null;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Shielded inbox'),
        actions: [
          if (live)
            IconButton(
              tooltip: 'Scan again',
              onPressed: _busy ? null : _rescan,
              icon: const Icon(Icons.refresh),
            ),
        ],
      ),
      body: !live
          ? const _Message(
              'Cloak runs on Solana mainnet only. This build is on '
              '${AppConfig.cluster}, so there is nothing to scan.',
            )
          : FutureBuilder<List<CloakNote>>(
              future: _scan,
              builder: (context, snap) {
                if (snap.connectionState != ConnectionState.done) {
                  return const _Message(
                    'Scanning the Cloak pool for notes sent to you…',
                    busy: true,
                  );
                }
                if (snap.hasError) {
                  return _Message(errorText(snap.error!), error: true);
                }
                final notes = [
                  for (final n in snap.data ?? const <CloakNote>[])
                    if (!n.spent) n,
                ];
                if (notes.isEmpty) {
                  return const _Message('No shielded notes yet.');
                }
                final byMint = <String?, List<CloakNote>>{};
                for (final n in notes) {
                  (byMint[n.mint] ??= []).add(n);
                }
                // One filled button per screen: with several assets, each
                // withdrawal is an outlined action.
                final single = byMint.length == 1;
                return ListView(
                  padding: const EdgeInsets.fromLTRB(
                    DMSpace.gutter,
                    DMSpace.md,
                    DMSpace.gutter,
                    DMSpace.xxxl,
                  ),
                  children: [
                    for (final MapEntry(key: mint, value: group)
                        in byMint.entries) ...[
                      _NoteGroup(
                        mint: mint,
                        notes: group,
                        primary: single,
                        onWithdraw: _busy || !hasWallet
                            ? null
                            : () => _withdraw(group),
                      ),
                      const SizedBox(height: DMSpace.md),
                    ],
                  ],
                );
              },
            ),
    );
  }
}

/// Unspent notes of one asset: the total, each note when there are
/// several, and the withdraw action.
class _NoteGroup extends StatelessWidget {
  const _NoteGroup({
    required this.mint,
    required this.notes,
    required this.primary,
    required this.onWithdraw,
  });

  final String? mint;
  final List<CloakNote> notes;
  final bool primary;
  final VoidCallback? onWithdraw;

  @override
  Widget build(BuildContext context) {
    const icon = Icon(Icons.account_balance_wallet_outlined);
    const label = Text('Withdraw to my wallet');
    return DMCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            amountText(notes.fold(0, (sum, n) => sum + n.amount), mint),
            style: DMType.stat(),
          ),
          const SizedBox(height: DMSpace.xxs),
          Text(
            '${notes.length} shielded ${notes.length == 1 ? 'note' : 'notes'}',
            style: DMType.data(),
          ),
          if (notes.length > 1) ...[
            const SizedBox(height: DMSpace.sm),
            for (final n in notes)
              Padding(
                padding: const EdgeInsets.only(top: DMSpace.xxs),
                child: Text(
                  amountText(n.amount, n.mint),
                  style: DMType.data(color: DM.mist),
                ),
              ),
          ],
          const SizedBox(height: DMSpace.lg),
          if (primary)
            FilledButton.icon(onPressed: onWithdraw, icon: icon, label: label)
          else
            OutlinedButton.icon(
              onPressed: onWithdraw,
              icon: icon,
              label: label,
            ),
        ],
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message(this.text, {this.busy = false, this.error = false});

  final String text;
  final bool busy;
  final bool error;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(DMSpace.xxxl),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (busy) ...[
            const CircularProgressIndicator(),
            const SizedBox(height: DMSpace.lg),
          ],
          if (error) ...[
            const Icon(
              Icons.error_outline,
              color: DM.due,
              semanticLabel: 'Error',
            ),
            const SizedBox(height: DMSpace.md),
          ],
          Text(
            text,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium
                ?.copyWith(color: error ? DM.bone : DM.sub),
          ),
        ],
      ),
    ),
  );
}
