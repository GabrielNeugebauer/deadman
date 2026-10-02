import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/actions.dart';
import '../../state/providers.dart';
import '../format.dart';
import '../theme.dart';
import '../widgets/feedback.dart';

final _guardAddressProvider = FutureProvider<String?>(
  (ref) async => (await ref.watch(secureStoreProvider).loadGuard())?.address,
);

class SettingsTab extends ConsumerWidget {
  const SettingsTab({super.key});

  Future<bool> _confirm(BuildContext context, String title, String body, String action) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: DmColors.surface,
          title: Text(title),
          content: Text(body),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            TextButton(onPressed: () => Navigator.pop(context, true), child: Text(action)),
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
              leading: const Icon(Icons.warning_amber_rounded, color: DmColors.danger),
              title: const Text('Panic lockdown'),
              subtitle: const Text('Freeze withdrawals and policy changes now'),
              onTap: () async {
                if (await _confirm(context, 'Lock down vault?',
                        'Withdrawals and policy changes freeze for your lock period. Inheritance keeps working.',
                        'Lock down') &&
                    context.mounted) {
                  await runGuarded(context, actions.lockdown, success: 'Vault locked down');
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
                if (await _confirm(context, 'Rotate guard key?',
                        'A new device key is created here and the old one stops working. Approve in your wallet.',
                        'Rotate') &&
                    context.mounted) {
                  final ok = await runGuarded(context, actions.rotateGuard, success: 'Guard key rotated');
                  if (ok) ref.invalidate(_guardAddressProvider);
                }
              },
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: ListTile(
              leading: const Icon(Icons.workspace_premium_outlined, color: DmColors.plus),
              title: const Text('Deadman Plus'),
              subtitle: const Text('Up to 4 heirs and a guardian. Paid in SKR.'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () async {
                if (await _confirm(context, 'Get Deadman Plus',
                        'Pay one month of Plus in SKR from your wallet.', 'Pay with SKR') &&
                    context.mounted) {
                  await runGuarded(context, () => actions.subscribe(1), success: 'Plus active');
                }
              },
            ),
          ),
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
              subtitle: const Text('Deletes PINs and the guard key from this phone'),
              onTap: () async {
                if (await _confirm(context, 'Forget this device?',
                        'Your vault stays on-chain. You will need to rotate the guard key to pulse from a new device.',
                        'Forget') &&
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
