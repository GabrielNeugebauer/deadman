import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config.dart';
import '../../solana/deadman_api.dart';
import '../../state/actions.dart';
import '../../state/providers.dart';
import '../format.dart';
import '../rules_format.dart';
import '../theme.dart';
import '../widgets/feedback.dart';

final _guardAddressProvider = FutureProvider<String?>(
  (ref) async => (await ref.watch(secureStoreProvider).loadGuard())?.address,
);

class SettingsTab extends ConsumerWidget {
  const SettingsTab({super.key});

  Future<bool> _confirm(
    BuildContext context,
    String title,
    String body,
    String action,
  ) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: DmColors.surface,
          title: Text(title),
          content: Text(body),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(action),
            ),
          ],
        ),
      ) ??
      false;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    final owner = ref.watch(sessionProvider.select((s) => s.owner)) ?? '';
    final guard = ref.watch(_guardAddressProvider).value;
    final actions = ref.read(actionsProvider);

    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
        children: [
          Text('Security', style: t.headlineMedium),
          const SizedBox(height: 20),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.account_balance_wallet_outlined),
                  title: const Text('Owner wallet'),
                  subtitle: Text(short(owner)),
                  onTap: () {
                    Clipboard.setData(ClipboardData(text: owner));
                    toast(context, 'Address copied');
                  },
                ),
                const Divider(height: 1, color: DmColors.line),
                ListTile(
                  leading: const Icon(Icons.key_outlined),
                  title: const Text('Guard key (this phone)'),
                  subtitle: Text(guard == null ? 'Not created' : short(guard)),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Card(
            child: ListTile(
              leading: const Icon(
                Icons.warning_amber_rounded,
                color: DmColors.danger,
              ),
              title: const Text('Panic lockdown'),
              subtitle: const Text('Freeze withdrawals and policy changes now'),
              onTap: () async {
                if (await _confirm(
                      context,
                      'Lock down vault?',
                      'Withdrawals and policy changes freeze for your lock period. Inheritance keeps working.',
                      'Lock down',
                    ) &&
                    context.mounted) {
                  await runGuarded(
                    context,
                    actions.lockdown,
                    success: 'Vault locked down',
                  );
                }
              },
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: ListTile(
              leading: const Icon(Icons.autorenew),
              title: const Text('Move guard to this phone'),
              subtitle: const Text('Use after a lost or replaced device'),
              onTap: () async {
                if (await _confirm(
                      context,
                      'Rotate guard key?',
                      'A new device key is created here and the old one stops working. Approve in your wallet.',
                      'Rotate',
                    ) &&
                    context.mounted) {
                  final ok = await runGuarded(
                    context,
                    actions.rotateGuard,
                    success: 'Guard key rotated',
                  );
                  if (ok) ref.invalidate(_guardAddressProvider);
                }
              },
            ),
          ),
          const SizedBox(height: 12),
          const _ReceivePrivatelyCard(),
          const SizedBox(height: 12),
          const _FeesCard(),
          const SizedBox(height: 12),
          const _GasCard(),
          const SizedBox(height: 12),
          Card(
            child: ListTile(
              leading: const Icon(Icons.lock_outline),
              title: const Text('Lock app'),
              onTap: () => ref.read(sessionProvider.notifier).lock(),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: ListTile(
              leading: const Icon(Icons.logout, color: DmColors.muted),
              title: const Text('Forget this device'),
              subtitle: const Text(
                'Deletes PINs and the guard key from this phone',
              ),
              onTap: () async {
                if (await _confirm(
                      context,
                      'Forget this device?',
                      'Your vault stays on-chain. You will need to rotate the guard key to pulse from a new device.',
                      'Forget',
                    ) &&
                    context.mounted) {
                  await ref.read(sessionProvider.notifier).reset();
                }
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _ReceivePrivatelyCard extends ConsumerWidget {
  const _ReceivePrivatelyCard();

  Future<void> _edit(
    BuildContext context,
    WidgetRef ref,
    Rail rail,
    String? current,
  ) async {
    final controller = TextEditingController(text: current ?? '');
    final dest = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: DmColors.surface,
        title: Text('Receive via ${rail.label}'),
        content: TextField(
          controller: controller,
          decoration: InputDecoration(
            labelText: rail == Rail.zcash
                ? 'Shielded-only Zcash unified address (u1…)'
                : 'Solana address to receive privately, or cloak:… address',
            helperText: rail == Rail.zcash
                ? 'Use a fresh address for each inheritance.'
                : 'Funds pass through the Cloak pool before reaching it.',
            helperMaxLines: 2,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (dest == null || dest.isEmpty || !context.mounted) return;
    await runGuarded(context, () async {
      final code = await ref.read(actionsProvider).saveClaimProfile(rail, dest);
      await Clipboard.setData(ClipboardData(text: code));
    }, success: 'Claim code copied. Send it to the vault owner.');
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profiles = ref.watch(claimProfilesProvider).value ?? const [];
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Receive privately',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            const Text(
              'Get a claim code to give someone who is naming you in their plan. Payouts land on a '
              'fresh key on this phone and are forwarded to your private address.',
              style: TextStyle(
                color: DmColors.muted,
                fontSize: 13,
                height: 1.35,
              ),
            ),
            for (final rail in [Rail.cloak, Rail.zcash])
              Builder(
                builder: (context) {
                  final p = profiles.where((p) => p.rail == rail).firstOrNull;
                  return ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(rail.icon, color: rail.color),
                    title: Text(rail.label),
                    subtitle: Text(
                      p == null
                          ? 'Not set up'
                          : 'Code ${short(p.key.address)} → ${short(p.destination)}',
                    ),
                    trailing: p == null
                        ? const Icon(Icons.add)
                        : IconButton(
                            icon: const Icon(Icons.copy, size: 20),
                            onPressed: () {
                              Clipboard.setData(
                                ClipboardData(text: p.claimCode),
                              );
                              toast(context, 'Claim code copied');
                            },
                          ),
                    onTap: () => _edit(context, ref, rail, p?.destination),
                  );
                },
              ),
          ],
        ),
      ),
    );
  }
}

class _FeesCard extends ConsumerWidget {
  const _FeesCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final fees = ref.watch(feesProvider).value;
    return Card(
      child: ListTile(
        leading: const Icon(Icons.receipt_long_outlined),
        title: const Text('Pricing'),
        subtitle: Text(
          fees == null
              ? 'Free to use. A fee applies only when a tier releases funds.'
              : 'Free to use. On release: ${fees.feeBpsPublic / 100}% via Solana, '
                    '${fees.feeBpsPrivate / 100}% via Cloak or Zcash.',
        ),
      ),
    );
  }
}

/// Owners pay their own fees in SOL; check-ins can be sponsored by Kora.
class _GasCard extends ConsumerWidget {
  const _GasCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    const sponsored = AppConfig.koraSponsorUrl != '';
    final lamports = ref.watch(walletBalanceProvider).value;
    return Card(
      child: ListTile(
        leading: const Icon(Icons.local_gas_station_outlined),
        title: const Text('Network fees'),
        subtitle: Text(
          'Your wallet pays its own fees in SOL: '
          '${lamports == null ? '…' : sol(lamports)} SOL available.\n'
          '${sponsored ? 'Check-ins and duress locks are free; this phone needs no SOL.' : 'Check-ins are paid by this phone\'s guard key (0.01 SOL at setup).'}',
        ),
        isThreeLine: true,
      ),
    );
  }
}
