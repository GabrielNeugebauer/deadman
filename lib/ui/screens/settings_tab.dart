import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config.dart';
import '../../solana/deadman_api.dart';
import '../../state/actions.dart';
import '../../state/assets.dart';
import '../../state/fee_settings.dart';
import '../../state/plan_math.dart';
import '../../state/providers.dart';
import '../format.dart';
import '../rules_format.dart';
import '../theme.dart';
import '../widgets/feedback.dart';
import 'recovery_phrase_screen.dart';

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

class SettingsTab extends ConsumerWidget {
  const SettingsTab({super.key});

  Future<void> _panic(BuildContext context, WidgetRef ref) async {
    final actions = ref.read(actionsProvider);
    if (ref.read(sessionProvider).duress) {
      // Retried in the background until it goes through; look normal.
      await actions.duressLockdown().catchError((Object _) {});
      if (context.mounted) toast(context, 'Vault locked down');
      return;
    }
    LockReport? report;
    String? unavailable;
    try {
      report = await actions.lockdown();
    } on ActionError catch (e) {
      unavailable = e.message;
    } catch (e) {
      if (context.mounted) toast(context, '$e', error: true);
      return;
    }
    if (!context.mounted) return;
    if (report != null && report.complete) {
      toast(context, report.text);
      return;
    }
    // Plans the guard key could not lock: offer the owner's wallet instead.
    final remaining =
        report?.uncovered ??
        (ref.read(vaultsProvider).value ?? const <VaultState>[]);
    if (remaining.isEmpty) {
      toast(context, unavailable ?? report!.text, error: true);
      return;
    }
    final names = remaining.map(planName).join(', ');
    if (await _confirm(
          context,
          'Lock with your wallet?',
          '${report == null ? unavailable! : report.text}\n\n'
              'Lock $names by approving in your wallet?',
          'Lock with wallet',
        ) &&
        context.mounted) {
      await runGuarded(
        context,
        () => actions.lockdownByOwner([for (final v in remaining) v.planId]),
        success: 'Locked $names with your wallet',
      );
    }
  }

  /// Two steps: PINs and guard by default; receiving keys only on an
  /// explicit second confirmation.
  Future<void> _forget(BuildContext context, WidgetRef ref) async {
    if (!await _confirm(
          context,
          'Forget this device?',
          'Deletes your PINs and this phone\'s guard key. Your plans stay on-chain, '
              'but they keep the old guard key: after setting up again, use '
              '"Move guard to this phone" or check-ins will not reach them.',
          'Forget',
        ) ||
        !context.mounted) {
      return;
    }
    var deleteKeys = false;
    if (await ref.read(secureStoreProvider).hasReceivingKeys()) {
      if (!context.mounted) return;
      final choice = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: DmColors.surface,
          title: const Text('Keep receiving keys?'),
          content: const Text(
            'This phone holds the keys behind your claim codes. They are kept unless you '
            'delete them here.\n\nIf you delete them, funds sent to your claim codes will be '
            'lost unless you saved your recovery phrase.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Keep them'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              style: TextButton.styleFrom(foregroundColor: DmColors.danger),
              child: const Text('Also delete receiving keys'),
            ),
          ],
        ),
      );
      if (choice == null) return;
      if (choice) {
        if (!context.mounted) return;
        deleteKeys = await _confirm(
          context,
          'Delete receiving keys?',
          'Funds sent to your claim codes will be lost unless you saved your recovery phrase. '
              'Older profiles not covered by the phrase cannot be recovered at all.',
          'Delete',
        );
        if (!deleteKeys) return;
      }
    }
    await ref
        .read(sessionProvider.notifier)
        .reset(deleteReceivingKeys: deleteKeys);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    final owner = ref.watch(sessionProvider.select((s) => s.owner)) ?? '';
    final guard = ref.watch(guardAddressProvider).value;
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
              subtitle: const Text(
                'Freeze withdrawals, policy changes and vesting revocation now',
              ),
              onTap: () async {
                if (await _confirm(
                      context,
                      'Lock down vault?',
                      'Withdrawals and policy changes freeze for your lock period. Inheritance keeps working.',
                      'Lock down',
                    ) &&
                    context.mounted) {
                  await _panic(context, ref);
                }
              },
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: ListTile(
              leading: const Icon(Icons.autorenew),
              title: const Text('Move guard to this phone'),
              subtitle: const Text(
                'Use after a lost or replaced device, or after Forget this device',
              ),
              onTap: () async {
                if (await _confirm(
                      context,
                      'Move guard to this phone?',
                      'Every plan guarded by another key moves to this phone\'s guard key, and the old key '
                          'stops working. Approve in your wallet.',
                      'Move',
                    ) &&
                    context.mounted) {
                  await runGuarded(
                    context,
                    actions.rotateGuard,
                    success: 'Guard moved to this phone',
                  );
                }
              },
            ),
          ),
          const SizedBox(height: 12),
          const _ReceivePrivatelyCard(),
          const SizedBox(height: 12),
          const _RecoveryCard(),
          const SizedBox(height: 12),
          const _FeesCard(),
          const SizedBox(height: 12),
          const NetworkFeesCard(),
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
                'Deletes PINs and the guard key. Receiving keys stay unless you choose to delete them.',
              ),
              onTap: () => _forget(context, ref),
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
    if (current != null && current.isNotEmpty && current != dest) {
      if (!await _confirm(
            context,
            'Change destination?',
            'Payouts routed from now on go to\n$dest\ninstead of\n$current',
            'Change',
          ) ||
          !context.mounted) {
        return;
      }
    }
    SavedClaim? saved;
    final ok = await runGuarded(context, () async {
      saved = await ref.read(actionsProvider).saveClaimProfile(rail, dest);
      await Clipboard.setData(ClipboardData(text: saved!.profile.claimCode));
    });
    if (!ok || !context.mounted) return;
    final phrase = saved!.unconfirmedPhrase;
    if (phrase != null) {
      await RecoveryPhrasePage.show(context, phrase, firstTime: true);
    }
    if (context.mounted) {
      toast(context, 'Claim code copied. Send it to the vault owner.');
    }
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
                          : p.destination.isEmpty
                          ? 'Code ${short(p.key.address)} · restored, tap to set a destination'
                          : 'Code ${short(p.key.address)} → ${short(p.destination)}'
                                '${p.recoverable ? '' : '\nOlder key, not covered by your recovery phrase'}',
                    ),
                    isThreeLine: p != null && !p.recoverable,
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

/// Backup of the receiving keys: show or restore the recovery phrase.
class _RecoveryCard extends ConsumerWidget {
  const _RecoveryCard();

  Future<void> _show(BuildContext context, WidgetRef ref) async {
    String? phrase;
    final ok = await runGuarded(
      context,
      () async =>
          phrase = await ref.read(actionsProvider).revealRecoveryPhrase(),
    );
    if (ok && context.mounted) await RecoveryPhrasePage.show(context, phrase!);
  }

  Future<void> _restore(BuildContext context, WidgetRef ref) async {
    final controller = TextEditingController();
    final phrase = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: DmColors.surface,
        title: const Text('Restore receiving profiles'),
        content: TextField(
          controller: controller,
          minLines: 3,
          maxLines: 4,
          autocorrect: false,
          enableSuggestions: false,
          decoration: const InputDecoration(
            labelText: 'Your 12-word recovery phrase',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Restore'),
          ),
        ],
      ),
    );
    if (phrase == null || phrase.trim().isEmpty || !context.mounted) return;
    String? message;
    final ok = await runGuarded(context, () async {
      final r = await ref.read(actionsProvider).restoreFromPhrase(phrase);
      String names(List<Rail> rails) => rails.map((r) => r.label).join(', ');
      message = [
        if (r.restored.isNotEmpty)
          'Restored ${names(r.restored)}. Set a destination before routing.',
        if (r.kept.isNotEmpty)
          'Kept this phone\'s existing ${names(r.kept)} key (not from this phrase).',
      ].join(' ');
    });
    if (ok && context.mounted) toast(context, message!);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) => Card(
    child: Column(
      children: [
        ListTile(
          leading: const Icon(Icons.key),
          title: const Text('Show recovery phrase'),
          subtitle: const Text('Backs up the keys behind your claim codes'),
          onTap: () => _show(context, ref),
        ),
        const Divider(height: 1, color: DmColors.line),
        ListTile(
          leading: const Icon(Icons.restore),
          title: const Text('Restore receiving profiles from phrase'),
          subtitle: const Text('On a new or reset phone'),
          onTap: () => _restore(context, ref),
        ),
      ],
    ),
  );
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

/// Wallet balances and who pays network fees on owner transactions: SOL
/// from the wallet, or USDC through a Kora paymaster. Check-ins can be
/// sponsored by Kora either way.
class NetworkFeesCard extends ConsumerWidget {
  const NetworkFeesCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    const sponsored = AppConfig.koraSponsorUrl != '';
    final lamports = ref.watch(walletBalanceProvider).value;
    final usdc = ref.watch(walletUsdcProvider).value;
    final mode = ref.watch(feeModeProvider);
    final paymaster = ref.watch(paymasterAvailableProvider);
    const small = TextStyle(color: DmColors.muted, fontSize: 13, height: 1.35);
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.local_gas_station_outlined),
                SizedBox(width: 12),
                Text(
                  'Network fees',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'Wallet: ${lamports == null ? '…' : sol(lamports)} SOL · '
              '${usdc == null ? '…' : amountNumber(usdc, AppConfig.usdcMint)} USDC',
              style: small,
            ),
            const SizedBox(height: 12),
            const Text('Pay network fees with'),
            const SizedBox(height: 8),
            SegmentedButton<FeeMode>(
              showSelectedIcon: false,
              segments: [
                const ButtonSegment(value: FeeMode.sol, label: Text('SOL')),
                ButtonSegment(
                  value: FeeMode.usdc,
                  label: const Text('USDC'),
                  enabled: paymaster,
                ),
              ],
              selected: {mode},
              onSelectionChanged: (s) =>
                  ref.read(feeModeProvider.notifier).set(s.first),
            ),
            const SizedBox(height: 8),
            Text(
              !paymaster
                  ? 'Your wallet pays its fees in SOL. Paying in USDC needs a Kora '
                        'paymaster, which this build does not have configured.'
                  : mode == FeeMode.usdc
                  ? 'A Kora paymaster pays the SOL fee and account rent for your wallet '
                        'transactions and charges you the equivalent in USDC.'
                  : 'Your wallet pays its fees in SOL. Switch to USDC to need no SOL at all.',
              style: small,
            ),
            if (mode == FeeMode.usdc && usdc == 0)
              const Padding(
                padding: EdgeInsets.only(top: 6),
                child: Text(
                  'Your wallet has no USDC. Add USDC or switch fees to SOL.',
                  style: TextStyle(color: DmColors.warn, fontSize: 13),
                ),
              ),
            const SizedBox(height: 6),
            Text(
              sponsored
                  ? 'Check-ins and duress locks are free; this phone needs no SOL.'
                  : 'Check-ins are paid by this phone\'s guard key (0.01 SOL at setup).',
              style: small,
            ),
          ],
        ),
      ),
    );
  }
}
