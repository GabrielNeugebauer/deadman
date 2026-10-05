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
import '../../state/subscription.dart';
import '../format.dart';
import '../rules_format.dart';
import '../web/web_ui.dart';
import '../widgets/brand/brand.dart';
import '../widgets/feedback.dart';
import '../widgets/plan_pricing.dart';
import 'rails_check_screen.dart';
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
    if (ref.read(isWebProvider)) {
      // No guard-key path in the browser: one wallet approval locks all.
      List<VaultState>? locked;
      final ok = await runGuarded(
        context,
        () async => locked = await actions.lockdownWithWallet(),
      );
      if (ok && context.mounted) {
        toast(
          context,
          locked!.length == 1
              ? 'Locked ${planName(locked!.single)}.'
              : 'Locked ${locked!.length} plans.',
        );
      }
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
    final web = ref.read(isWebProvider);
    if (!await _confirm(
          context,
          web ? 'Forget this browser?' : 'Forget this device?',
          web
              ? 'Deletes your PINs and this browser\'s guard key. Your plans stay '
                    'on-chain and your wallet keeps working with them.'
              : 'Deletes your PINs and this phone\'s guard key. Your plans stay on-chain, '
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
              style: TextButton.styleFrom(foregroundColor: DM.due),
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

  /// Web: connect another browser wallet; its address becomes the owner.
  Future<void> _switchWallet(BuildContext context, WidgetRef ref) async {
    final kind = await showWalletPicker(context);
    if (kind == null || !context.mounted) return;
    await runGuarded(
      context,
      () => ref.read(actionsProvider).connectWeb(kind),
      success: 'Connected ${kind.label}',
    );
  }

  Future<void> _confirmPanic(BuildContext context, WidgetRef ref) async {
    final web = ref.read(isWebProvider);
    if (await _confirm(
          context,
          'Lock down vault?',
          'Withdrawals and policy changes freeze for your lock period. Inheritance keeps working.'
              '${web ? ' Approve in your wallet.' : ''}',
          'Lock down',
        ) &&
        context.mounted) {
      await _panic(context, ref);
    }
  }

  Future<void> _moveGuard(BuildContext context, WidgetRef ref) async {
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
        ref.read(actionsProvider).rotateGuard,
        success: 'Guard moved to this phone',
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final owner = ref.watch(sessionProvider.select((s) => s.owner)) ?? '';
    final guard = ref.watch(guardAddressProvider).value;
    final web = ref.watch(isWebProvider);
    final device = web ? 'this browser' : 'this phone';
    final walletName = web
        ? ref.read(webWalletProvider).lastKind?.label ?? 'Wallet'
        : 'Seed Vault';

    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(
          DMSpace.gutter,
          DMSpace.md,
          DMSpace.gutter,
          DMSpace.xxxl,
        ),
        children: [
          PageHeader(
            title: 'Security',
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (web) const WebBadge(),
                if (web) const SizedBox(width: DMSpace.sm),
                const _LockChip(),
              ],
            ),
          ),
          const SizedBox(height: DMSpace.xl),
          DMListGroup(
            children: [
              DMListRow(
                leading: const IconTile(
                  icon: Icons.account_balance_wallet_outlined,
                ),
                title: 'Owner wallet',
                subtitle: '${short(owner)} · $walletName',
                trailing: web
                    ? TextButton(
                        onPressed: () => _switchWallet(context, ref),
                        child: const Text('Switch'),
                      )
                    : null,
                onTap: () {
                  Clipboard.setData(ClipboardData(text: owner));
                  toast(context, 'Address copied');
                },
              ),
              DMListRow(
                leading: const IconTile(icon: Icons.key_outlined),
                title: 'Guard key',
                subtitle:
                    '${guard == null ? 'Not created' : short(guard)} · $device',
              ),
            ],
          ),
          if (web) ...[
            const SizedBox(height: DMSpace.md),
            const AndroidAppCard(),
          ],
          const SizedBox(height: DMSpace.md),
          // The one card allowed a status border: the fill stays graphite.
          DMCard(
            key: const ValueKey('panic-card'),
            padding: EdgeInsets.zero,
            borderColor: DM.due.withValues(alpha: 0.35),
            onTap: () => _confirmPanic(context, ref),
            child: const DMListRow(
              leading: IconTile(
                icon: Icons.warning_amber_rounded,
                tone: DM.due,
              ),
              title: 'Panic lockdown',
              subtitle: 'Freeze withdrawals, policy changes and vesting revocation now',
            ),
          ),
          // Moving the guard to a browser would take it off the phone.
          if (!web) ...[
            const SizedBox(height: DMSpace.md),
            DMCard(
              padding: EdgeInsets.zero,
              onTap: () => _moveGuard(context, ref),
              child: const DMListRow(
                leading: IconTile(icon: Icons.swap_horiz),
                title: 'Move guard to this phone',
                subtitle: 'After a lost or replaced device, or after Forget this device',
              ),
            ),
          ],
          const SizedBox(height: DMSpace.md),
          const _ReceivePrivatelyCard(),
          const SizedBox(height: DMSpace.xxl),
          const SectionHeader(title: 'Fees'),
          const SizedBox(height: DMSpace.xs),
          const PricingCard(),
          const MonthlyPlanCard(margin: EdgeInsets.only(top: DMSpace.md)),
          const SizedBox(height: DMSpace.md),
          const NetworkFeesCard(),
          const SizedBox(height: DMSpace.xxl),
          SectionHeader(title: web ? 'This browser' : 'This phone'),
          const SizedBox(height: DMSpace.xs),
          DMListGroup(
            children: [
              // The Cloak prover runs in the Android app's WebView.
              if (!web)
                DMListRow(
                  leading: const IconTile(
                    icon: Icons.health_and_safety_outlined,
                  ),
                  title: 'Private rails check',
                  subtitle: 'Test the Cloak prover and a Zcash quote. Moves no funds.',
                  monoSubtitle: false,
                  trailing: const Icon(Icons.chevron_right, color: DM.sub),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const RailsCheckScreen(),
                    ),
                  ),
                ),
              DMListRow(
                leading: const IconTile(icon: Icons.lock_outline),
                title: 'Lock app',
                subtitle: 'Asks for your PIN again',
                monoSubtitle: false,
                onTap: () => ref.read(sessionProvider.notifier).lock(),
              ),
              DMListRow(
                leading: const IconTile(icon: Icons.logout),
                title: web ? 'Forget this browser' : 'Forget this device',
                subtitle:
                    'Deletes PINs and the guard key. Receiving keys stay unless '
                    'you choose to delete them.',
                monoSubtitle: false,
                onTap: () => _forget(context, ref),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// UNLOCKED, or LOCKED while any plan is in lockdown. A duress session
/// always reads UNLOCKED: the lock it just sent must not show. Hidden with
/// no plans, where there is nothing to lock.
class _LockChip extends ConsumerWidget {
  const _LockChip();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final plans = ref.watch(vaultsProvider).value ?? const <VaultState>[];
    if (plans.isEmpty) return const SizedBox.shrink();
    final duress = ref.watch(sessionProvider.select((s) => s.duress));
    final now = nowSecs();
    final locked = !duress && plans.any((v) => v.isLocked(now));
    return StatusChip(
      locked ? DMStatus.locked : DMStatus.onTrack,
      key: const ValueKey('security-lock-chip'),
      label: locked ? 'Locked' : 'Unlocked',
    );
  }
}

class _ReceivePrivatelyCard extends ConsumerWidget {
  const _ReceivePrivatelyCard();

  static const _ownCloak = 'own-cloak-address';

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
          // Deriving it needs the Cloak SDK, which runs in the Android app.
          if (rail == Rail.cloak && !ref.read(isWebProvider))
            TextButton(
              onPressed: () => Navigator.pop(context, _ownCloak),
              child: const Text('Use this phone\'s shielded address'),
            ),
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
    final own = dest == _ownCloak;
    if (current != null && current.isNotEmpty && current != dest) {
      if (!await _confirm(
            context,
            'Change destination?',
            'Payouts routed from now on go to\n'
                '${own ? 'this phone\'s shielded address' : dest}\n'
                'instead of\n$current',
            'Change',
          ) ||
          !context.mounted) {
        return;
      }
    }
    SavedClaim? saved;
    final ok = await runGuarded(context, () async {
      final actions = ref.read(actionsProvider);
      saved = own
          ? await actions.useOwnCloakAddress()
          : await actions.saveClaimProfile(rail, dest);
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
    final t = Theme.of(context).textTheme;
    final profiles = ref.watch(claimProfilesProvider).value ?? const [];
    final web = ref.watch(isWebProvider);
    final device = web ? 'browser' : 'phone';
    return DMListGroup(
      header: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            header: true,
            child: Text('Receive privately', style: t.titleMedium),
          ),
          const SizedBox(height: DMSpace.xxs),
          Text(
            'Get a claim code to give someone who is naming you in their plan. Payouts land on a '
            'fresh key on this $device and are forwarded to your private address.',
            style: t.bodyMedium?.copyWith(fontSize: 14),
          ),
        ],
      ),
      children: [
        for (final rail in [Rail.cloak, Rail.zcash])
          Builder(
            builder: (context) {
              final p = profiles.where((p) => p.rail == rail).firstOrNull;
              return DMListRow(
                key: ValueKey('receive-${rail.name}'),
                leading: IconTile(icon: rail.icon),
                title: rail.label,
                subtitle: p == null
                    ? 'Not set up'
                    : p.destination.isEmpty
                    ? 'Code ${short(p.key.address)} · restored, tap to set a destination'
                    : 'Code ${short(p.key.address)} → ${short(p.destination)}'
                          '${p.recoverable ? '' : '\nOlder key, not covered by your recovery phrase'}',
                trailing: p == null
                    ? const Icon(Icons.add, color: DM.signal)
                    : IconButton(
                        tooltip: 'Copy claim code',
                        icon: const Icon(Icons.copy, size: 20, color: DM.sub),
                        onPressed: () {
                          Clipboard.setData(ClipboardData(text: p.claimCode));
                          toast(context, 'Claim code copied');
                        },
                      ),
                onTap: () => _edit(context, ref, rail, p?.destination),
              );
            },
          ),
        DMListRow(
          leading: const IconTile(icon: Icons.key),
          title: 'Show recovery phrase',
          subtitle: 'Backs up the keys behind your claim codes',
          onTap: () => _showPhrase(context, ref),
        ),
        DMListRow(
          leading: const IconTile(icon: Icons.restore),
          title: 'Restore receiving profiles from phrase',
          subtitle: web
              ? 'On a new browser or after clearing site data'
              : 'On a new or reset phone',
          onTap: () => _restore(context, ref),
        ),
      ],
    );
  }

  /// Backup of the receiving keys: show the recovery phrase.
  Future<void> _showPhrase(BuildContext context, WidgetRef ref) async {
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
          'Kept this ${ref.read(isWebProvider) ? 'browser' : 'phone'}\'s existing ${names(r.kept)} key (not from this phrase).',
      ].join(' ');
    });
    if (ok && context.mounted) toast(context, message!);
  }
}

/// How Deadman charges: a percentage of each release, or, when offered, a
/// flat monthly plan covering all of the owner's plans that replaces it.
class PricingCard extends ConsumerWidget {
  const PricingCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    final small = t.bodyMedium?.copyWith(fontSize: 14);
    final fees = ref.watch(feesProvider).value;
    final terms = ref.watch(subscriptionTermsProvider).value;
    return DMCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Pricing', style: t.titleMedium),
          const SizedBox(height: DMSpace.xs),
          Text(
            fees == null
                ? 'Free to use. A fee applies only when a tier releases funds.'
                : 'Free to use. A fee is taken from each release:',
            style: small,
          ),
          if (fees != null) ...[
            const SizedBox(height: DMSpace.sm),
            _RateRow(
              rail: 'Via Solana',
              rate: percentText(fees.feeBpsPublic / 10000),
            ),
            const Divider(),
            _RateRow(
              rail: 'Via Cloak or Zcash',
              rate: percentText(fees.feeBpsPrivate / 10000),
            ),
          ],
          if (terms != null) ...[
            const SizedBox(height: DMSpace.md),
            Text(
              'Or pay ${amountText(terms.pricePerPeriod, terms.mint)} '
              '${terms.monthly ? 'a month' : 'per ${span(terms.periodSecs)}'} and '
              'releases carry no fee: one subscription covers all your plans, '
              'present and future. Better for larger holdings. A new or lapsed '
              'subscription starts with ${terms.minPeriods} '
              '${periodWord(terms, terms.minPeriods)} paid at once (up to '
              '${SubscriptionTerms.maxPeriods} per payment); while it runs, '
              'extend by any amount.',
              style: small,
            ),
          ],
        ],
      ),
    );
  }
}

/// "Via Solana ......... 2%": the rate right-aligned in mono, as on the
/// rail picker.
class _RateRow extends StatelessWidget {
  const _RateRow({required this.rail, required this.rate});

  final String rail;
  final String rate;

  @override
  Widget build(BuildContext context) => Semantics(
    label: '$rail: $rate',
    excludeSemantics: true,
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: DMSpace.sm),
      child: Row(
        children: [
          Expanded(child: Text(rail, style: DMType.outfit(size: 15))),
          Text(rate, style: DMType.mono(size: 13)),
        ],
      ),
    ),
  );
}

/// Wallet balances and who pays network fees on owner transactions: SOL
/// from the wallet, or USDC through a Kora paymaster. Check-ins can be
/// sponsored by Kora either way.
class NetworkFeesCard extends ConsumerWidget {
  const NetworkFeesCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    const sponsored = AppConfig.koraSponsorUrl != '';
    final t = Theme.of(context).textTheme;
    final small = t.bodyMedium?.copyWith(fontSize: 14);
    final lamports = ref.watch(walletBalanceProvider).value;
    final usdc = ref.watch(walletUsdcProvider).value;
    final mode = ref.watch(feeModeProvider);
    final paymaster = ref.watch(paymasterAvailableProvider);
    final web = ref.watch(isWebProvider);
    return DMCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Network fees', style: t.titleMedium),
          const SizedBox(height: DMSpace.sm),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              const MonoLabel('Wallet'),
              const SizedBox(width: DMSpace.md),
              Expanded(
                child: Text(
                  '${lamports == null ? '…' : sol(lamports)} SOL · '
                  '${usdc == null ? '…' : amountNumber(usdc, AppConfig.usdcMint)} USDC',
                  style: DMType.data(color: DM.bone),
                ),
              ),
            ],
          ),
          // The browser build only offers USDC fees when a paymaster is set.
          if (paymaster || !web) ...[
            const SizedBox(height: DMSpace.lg),
            Text(
              'Pay network fees with',
              style: DMType.outfit(weight: FontWeight.w500),
            ),
            const SizedBox(height: DMSpace.sm),
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
            const SizedBox(height: DMSpace.sm),
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
            if (mode == FeeMode.usdc && usdc == 0) ...[
              const SizedBox(height: DMSpace.sm),
              Row(
                key: const ValueKey('no-usdc-warning'),
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Padding(
                    padding: EdgeInsets.only(top: 2),
                    child: Icon(
                      Icons.error_outline,
                      size: 16,
                      color: DM.attention,
                    ),
                  ),
                  const SizedBox(width: DMSpace.sm),
                  Expanded(
                    child: Text(
                      'Your wallet has no USDC. Add USDC or switch fees to SOL.',
                      style: DMType.outfit(size: 14),
                    ),
                  ),
                ],
              ),
            ],
          ],
          const Padding(
            padding: EdgeInsets.symmetric(vertical: DMSpace.md),
            child: Divider(),
          ),
          Text(
            web
                ? 'Check-ins and panic locks are approved in your wallet like any '
                      'other transaction.'
                : sponsored
                ? 'Check-ins and duress locks are free; this phone needs no SOL.'
                : 'Check-ins are paid by this phone\'s guard key (0.01 SOL at setup).',
            style: small,
          ),
        ],
      ),
    );
  }
}
