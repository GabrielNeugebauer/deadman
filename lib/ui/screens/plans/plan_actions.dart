import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config.dart';
import '../../../solana/deadman_api.dart';
import '../../../state/actions.dart';
import '../../../state/assets.dart';
import '../../../state/plan_draft.dart' show assetOrder;
import '../../../state/plan_math.dart';
import '../../../state/providers.dart';
import '../../format.dart';
import '../../widgets/amount_dialog.dart';
import '../../widgets/brand/brand.dart';
import '../../widgets/feedback.dart';
import '../rules_editor.dart';
import '../vesting_editor.dart';

/// Re-reads plans and balances.
void refreshPlans(WidgetRef ref) {
  ref.invalidate(vaultsProvider);
  ref.invalidate(planUsdcProvider);
  ref.invalidate(planTokenBalancesProvider);
  ref.invalidate(planTokenProvider);
}

void openEditor(BuildContext context, {VaultState? vault}) => Navigator.push(
  context,
  MaterialPageRoute<void>(builder: (_) => RulesEditorPage(vault: vault)),
);

void openVestingEditor(BuildContext context) => Navigator.push(
  context,
  MaterialPageRoute<void>(builder: (_) => const VestingEditorPage()),
);

/// "New plan": inheritance (dead man's switch) or vesting.
Future<void> chooseNewPlan(BuildContext context) async {
  final kind = await showModalBottomSheet<PlanKind>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          DMSpace.gutter,
          0,
          DMSpace.gutter,
          DMSpace.gutter,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('New plan', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: DMSpace.lg),
            DMListGroup(
              children: [
                for (final (kind, icon, title, blurb) in [
                  (
                    PlanKind.inheritance,
                    DMIcons.heartbeat,
                    'Inheritance',
                    'Release when I go silent. Tiers pay out if you stop '
                        'checking in.',
                  ),
                  (
                    PlanKind.vesting,
                    DMIcons.calendar,
                    'Vesting',
                    'Release in installments over time, with an optional '
                        'cliff. No check-ins.',
                  ),
                ])
                  DMListRow(
                    leading: IconTile(child: DMIcon(icon)),
                    title: title,
                    subtitle: blurb,
                    monoSubtitle: false,
                    trailing: const DMIcon(DMIcons.chevronRight, color: DM.ash),
                    onTap: () => Navigator.pop(context, kind),
                  ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
  if (kind == null || !context.mounted) return;
  kind == PlanKind.vesting ? openVestingEditor(context) : openEditor(context);
}

/// Asks for an amount of SOL; returns lamports.
Future<int?> askAmount(BuildContext context, String title) {
  final controller = TextEditingController();
  return showDialog<int>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        style: DMType.mono(size: 20),
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: const InputDecoration(
          suffixText: 'SOL',
          labelText: 'Amount',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(minimumSize: const Size(96, 44)),
          onPressed: () => Navigator.pop(context, parseSol(controller.text)),
          child: const Text('Confirm'),
        ),
      ],
    ),
  );
}

/// Deposits from the wallet into plan [planId]: SOL, a preset token, any
/// other token or an NFT; only [asset] when given.
Future<void> depositToPlan(
  BuildContext context,
  WidgetRef ref,
  int planId, {
  AssetInfo? asset,
}) async {
  final wallet = <String?, int>{
    null: ?ref.read(walletBalanceProvider).value,
    AppConfig.usdcMint: ?ref.read(walletUsdcProvider).value,
  };
  final mints = [
    if (asset == null)
      for (final a in presetAssets) ?a.mint
    else
      ?asset.mint,
  ].where((m) => !wallet.containsKey(m)).toList();
  if (mints.isNotEmpty) {
    // The hints are optional; the deposit itself reports real failures.
    final got = await Future.wait([
      for (final m in mints)
        ref
            .read(walletTokenProvider(m).future)
            .then<int?>((v) => v, onError: (Object _) => null),
    ]);
    for (final (i, m) in mints.indexed) {
      if (got[i] case final v?) wallet[m] = v;
    }
    if (!context.mounted) return;
  }
  final pick = await askAssetAmount(
    context,
    asset == null ? 'Deposit' : 'Deposit ${asset.symbol}',
    assets: asset == null ? presetAssets : [asset],
    available: wallet,
    availableLabel: 'in your wallet',
    allowOther: asset == null,
    allowNft: asset == null,
  );
  if (pick == null || !context.mounted) return;
  final actions = ref.read(actionsProvider);
  await runGuarded(
    context,
    () => pick.mint == null
        ? actions.deposit(planId, pick.amount)
        : actions.depositToken(planId, pick.mint!, pick.amount),
    success: 'Deposited ${amountText(pick.amount, pick.mint)}',
  );
}

/// Under the Withdraw amount: Deadman takes nothing on the way out.
const withdrawFreeNote =
    'Withdrawals are free: Deadman takes no fee, only the network fee '
    'applies.';

/// Under Cancel and Close: Deadman takes nothing on the way out.
const closeFreeNote = 'No Deadman fee: cancelling a plan is free.';

/// Withdraws up to [available] (base units per mint; for vesting plans
/// only what is not committed to beneficiaries).
Future<void> withdrawFromPlan(
  BuildContext context,
  WidgetRef ref,
  VaultState vault,
  Map<String?, int> available,
) async {
  final pick = await askAssetAmount(
    context,
    'Withdraw',
    assets: [for (final m in assetOrder(available.keys)) assetInfo(m)],
    available: available,
    availableLabel: vault.isVesting ? 'not committed' : 'withdrawable',
    capped: true,
    note: withdrawFreeNote,
  );
  if (pick == null || !context.mounted) return;
  final actions = ref.read(actionsProvider);
  await runGuarded(
    context,
    () => pick.mint == null
        ? actions.withdraw(vault.planId, pick.amount)
        : actions.withdrawToken(vault.planId, pick.mint!, pick.amount),
    success: 'Withdrew ${amountText(pick.amount, pick.mint)}',
  );
}

/// "0.500 SOL · 250 USDC · 1200 SKR": what a plan holds, SOL first, empty
/// assets left out; [tokens] maps mint -> base units.
String holdingsText(VaultState vault, Map<String, int> tokens) => [
  if (vault.withdrawableLamports > 0) '${sol(vault.withdrawableLamports)} SOL',
  for (final mint in assetOrder(tokens.keys).nonNulls)
    if (tokens[mint]! > 0) amountText(tokens[mint]!, mint),
].join(' · ');

/// A plan card's summary amounts: SOL always, USDC when read, other tokens
/// and NFTs while held; [tokens] maps mint -> base units.
String balancesText(VaultState vault, Map<String, int> tokens) => [
  '${sol(vault.withdrawableLamports)} SOL',
  for (final mint in assetOrder(tokens.keys).nonNulls)
    if (mint == AppConfig.usdcMint || tokens[mint]! > 0)
      amountText(tokens[mint]!, mint),
].join(' · ');

/// A plan under panic lockdown cannot move funds, so it cannot be
/// cancelled or closed until the lock ends.
Future<void> explainLocked(BuildContext context, VaultState vault, int now) =>
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Plan is locked down'),
        content: Text(
          'Panic lockdown froze ${planName(vault)} for '
          '${span(vault.lockedUntil - now)}. Nothing can leave it until then, '
          'so it can\'t be cancelled or closed yet.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          ),
        ],
      ),
    );

/// Asks before a destructive plan action; true when the owner confirms
/// with [confirm]. [keep] dismisses.
Future<bool> confirmPlanAction(
  BuildContext context, {
  required String title,
  required String body,
  required String confirm,
  String keep = 'Keep plan',
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(keep),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: DM.flatline),
            onPressed: () => Navigator.pop(context, true),
            child: Text(confirm),
          ),
        ],
      ),
    ) ==
    true;

/// Closes [vault] after asking: [cancel] for a plan that has not released
/// (its tiers will never pay), otherwise clearing out a released one.
/// [held] is what it holds besides SOL (mint -> base units).
Future<void> closePlanFlow(
  BuildContext context,
  WidgetRef ref,
  VaultState vault, {
  required bool cancel,
  Map<String, int> held = const {},
  int? now,
}) async {
  final at = now ?? nowSecs();
  final duress = ref.read(sessionProvider).duress;
  if (vault.isLocked(at) && !duress) return explainLocked(context, vault, at);
  final what = holdingsText(vault, held);
  final back = what.isEmpty
      ? 'Its account rent comes back to your wallet.'
      : 'Everything in it comes back to your wallet: $what, plus the '
            'account rent.';
  final paid = vault.rules.any((r) => r.executed);
  final ok = await confirmPlanAction(
    context,
    title: cancel ? 'Cancel ${planName(vault)}?' : 'Close ${planName(vault)}?',
    body: cancel
        ? '$back Its tiers will never release to anyone.'
              '${paid ? ' Tiers that already released stay with their beneficiaries.' : ''}'
              ' This can\'t be undone.\n\n$closeFreeNote'
        : '$back The plan and its history leave the app. This can\'t be '
              'undone.\n\nNo Deadman fee: closing a plan is free.',
    confirm: cancel ? 'Cancel plan' : 'Close plan',
  );
  if (!ok || !context.mounted) return;
  await runGuarded(
    context,
    () => ref.read(actionsProvider).closePlan(vault.planId),
    success: cancel
        ? 'Plan cancelled; its funds are back in your wallet'
        : 'Plan closed; what was left is back in your wallet',
  );
}
