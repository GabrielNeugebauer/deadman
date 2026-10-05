import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../solana/deadman_api.dart';
import '../../state/actions.dart';
import '../../state/assets.dart';
import '../../state/plan_math.dart';
import '../../state/private_rails.dart';
import '../../state/providers.dart';
import '../../state/vesting.dart';
import '../format.dart';
import '../rules_format.dart';
import '../theme.dart';
import '../web/web_ui.dart';
import '../widgets/feedback.dart';
import '../widgets/private_funds.dart';
import '../widgets/vesting_progress.dart';

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
    void refresh() {
      ref.invalidate(watchedVaultsProvider);
      ref.invalidate(watchedTokenBalancesProvider);
      ref.invalidate(claimFundsProvider);
      ref.invalidate(transferStatusProvider);
      ref.invalidate(claimQuoteProvider);
    }

    return SafeArea(
      child: RefreshIndicator(
        onRefresh: () async => refresh(),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
          children: [
            Row(
              children: [
                Text('Family Circle', style: t.headlineMedium),
                const Spacer(),
                // No pull-to-refresh with a mouse.
                if (ref.watch(isWebProvider))
                  IconButton(
                    tooltip: 'Refresh',
                    onPressed: refresh,
                    icon: const Icon(Icons.refresh),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            const Text(
              'People who named you in their release or vesting plan.',
              style: TextStyle(color: DmColors.muted),
            ),
            const SizedBox(height: 20),
            const PrivateFundsSection(),
            const ShieldedInboxTile(),
            const PrivateTransfersCard(),
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

  /// Claims rule or schedule [index]; the toast adds why it was not free
  /// as quoted, if so.
  Future<void> _claim(int index, String success) async {
    setState(() => _busy = true);
    String? note;
    final ok = await runGuarded(context, () async {
      note = await ref.read(actionsProvider).claim(widget.vault, index);
    });
    if (ok && mounted) {
      toast(context, note == null ? success : '$success. $note');
    }
    if (mounted) setState(() => _busy = false);
  }

  /// Quote for the connected wallet's own claim of [index]; null while
  /// unknown or when someone else (a claim key) is the beneficiary.
  ClaimQuote? _quote(int index, bool claimable) {
    final v = widget.vault;
    if (!claimable || v.rules[index].beneficiary != widget.me) return null;
    return ref
        .watch(
          claimQuoteProvider((
            vaultOwner: v.owner,
            planId: v.planId,
            index: index,
          )),
        )
        .value;
  }

  Future<void> _route(RuleState r) async {
    setState(() => _busy = true);
    await routePrivatelyFlow(context, ref, r.rail, r.mint);
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
    // The owner's account-wide monthly plan waives the protocol fee.
    final waived = feeWaivedFor(
      v,
      ref.watch(watchedSubscriptionsProvider).value?[v.owner],
      now,
    );

    final (status, color) = v.isVesting
        ? v.revokedAt != 0
              ? (
                  'Vesting revoked; vested amounts stay claimable',
                  DmColors.warn,
                )
              : vestingSettled(v)
              ? ('Fully paid out', DmColors.muted)
              : now < v.startAt
              ? ('Vesting starts in ${span(v.startAt - now)}', DmColors.muted)
              : ('Vesting', DmColors.plus)
        : next == null
        ? (
            v.completed
                ? 'Plan fully released'
                : 'No tier pending; reserved shares await claim',
            DmColors.muted,
          )
        : now > next
        ? ('Silent past a release tier', DmColors.danger)
        : now > v.pulseDue
        ? ('Missed a check-in', DmColors.warn)
        : v.isLocked(now)
        ? ('Locked down', DmColors.warn)
        : ('Alive', DmColors.alive);

    final tokens = ref
        .watch(watchedTokenBalancesProvider)
        .whenOrNull(data: (b) => b[v.address] ?? const <String, int>{});
    String forWhom(RuleState r) =>
        widget.keys.contains(r.beneficiary) ? 'you' : short(r.beneficiary);
    final live = ref.watch(privateRailsLiveProvider);
    final web = ref.watch(isWebProvider);
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
                    v.label.isEmpty
                        ? short(v.owner)
                        : '${v.label} · ${short(v.owner)}',
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
                v.isVesting
                    ? 'Vesting plan · ${v.revocable ? 'revocable by the owner' : 'irrevocable'}'
                    : 'Last pulse ${ago(v.lastPulse, now)} · ${v.streak}-day streak',
                style: const TextStyle(color: DmColors.muted),
              ),
              if (v.isVesting)
                for (final (i, r) in mine) ...[
                  const Divider(height: 24, color: DmColors.line),
                  _VestingClaim(
                    vault: v,
                    index: i,
                    rule: r,
                    now: now,
                    busy: _busy,
                    live: live,
                    web: web,
                    funded: tierFunded(v, i, tokens),
                    quote: _quote(
                      i,
                      v.claimable(i, now) > 0 &&
                          tierFunded(v, i, tokens) != false,
                    ),
                    waived: waived,
                    onClaim: () => _claim(i, 'Vested amount claimed'),
                    onRoute: () => _route(r),
                  ),
                ],
              if (!v.isVesting)
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
                        ? 'Released ${ago(r.executedAt, now)}: ${amountText(r.paid, r.mint)}'
                        : r.skipped
                        ? skippedLabel(r)
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
                      onPressed:
                          _busy ||
                              tierFunded(v, i, tokens) == false ||
                              _quote(i, true)?.problem != null
                          ? null
                          : () => _claim(
                              i,
                              r.skipped
                                  ? 'Reserved share claimed'
                                  : 'Tier released',
                            ),
                      child: Text(
                        r.skipped
                            ? 'Claim reserved share'
                            : 'Release this tier',
                      ),
                    ),
                    if (tierFunded(v, i, tokens) == false)
                      _Note(waitingForFunds(r.mint))
                    else if (_quote(i, true) case final q?)
                      _ClaimCost(q)
                    else if (r.rail != Rail.solana)
                      const _Note(
                        'Releasing from your wallet links it to this payout. The Deadman keeper releases due tiers automatically.',
                      ),
                    if (waived) _Note(feeWaivedText(_quote(i, true))),
                  ],
                  // Tiers past due and grace that cannot pay: the keeper
                  // skips them; nobody does it by hand.
                  for (final j in [
                    for (var j = 0; j <= i; j++)
                      if ((j == i || v.rules[j].mint == r.mint) &&
                          v.canSkip(j, now) &&
                          tierFunded(v, j, tokens) != true)
                        j,
                  ])
                    _Note(
                      '${j == i ? '' : 'Tier ${j + 1} could not pay and holds yours back. '}'
                      'Deadman skips it automatically after the grace period; '
                      'its share stays reserved for ${forWhom(v.rules[j])}',
                    ),
                  if (r.executed &&
                      r.rail != Rail.solana &&
                      routableMint(r.mint)) ...[
                    const SizedBox(height: 10),
                    OutlinedButton.icon(
                      onPressed: _busy || !live ? null : () => _route(r),
                      icon: Icon(r.rail.icon),
                      label: Text(
                        live
                            ? 'Route privately via ${r.rail.label}'
                            : routeOffLabel(r.rail.label, web: web),
                      ),
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

/// A schedule naming this wallet or one of its claim keys.
class _VestingClaim extends StatelessWidget {
  const _VestingClaim({
    required this.vault,
    required this.index,
    required this.rule,
    required this.now,
    required this.busy,
    required this.live,
    required this.web,
    required this.funded,
    required this.quote,
    required this.waived,
    required this.onClaim,
    required this.onRoute,
  });

  final VaultState vault;
  final int index;
  final RuleState rule;
  final int now;
  final bool busy;
  final bool live;
  final bool web;

  /// The plan holds some of the schedule's asset; null when unknown.
  final bool? funded;

  /// What claiming costs this wallet; null when unknown.
  final ClaimQuote? quote;

  /// The owner's monthly plan waives the protocol fee.
  final bool waived;
  final VoidCallback onClaim;
  final VoidCallback onRoute;

  @override
  Widget build(BuildContext context) {
    final p = scheduleProgress(vault, index, now);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        VestingScheduleView(
          rule: rule,
          progress: p,
          now: now,
          showBeneficiary: false,
        ),
        if (p.claimable > 0) ...[
          const SizedBox(height: 10),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: DmColors.plus),
            onPressed: busy || funded == false || quote?.problem != null
                ? null
                : onClaim,
            child: Text('Claim vested ${amountText(p.claimable, rule.mint)}'),
          ),
          if (funded == false)
            _Note(waitingForFunds(rule.mint))
          else if (quote case final q?)
            _ClaimCost(q)
          else if (rule.rail != Rail.solana)
            const _Note('Claiming from your wallet links it to this payout.'),
          if (waived) _Note(feeWaivedText(quote)),
        ],
        if (rule.paid > 0 &&
            rule.rail != Rail.solana &&
            routableMint(rule.mint)) ...[
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: busy || !live ? null : onRoute,
            icon: Icon(rule.rail.icon),
            label: Text(
              live
                  ? 'Route privately via ${rule.rail.label}'
                  : routeOffLabel(rule.rail.label, web: web),
            ),
          ),
        ],
      ],
    );
  }
}

/// Under a claim button: what claiming costs, or why it cannot go through.
class _ClaimCost extends StatelessWidget {
  const _ClaimCost(this.quote);

  final ClaimQuote quote;

  @override
  Widget build(BuildContext context) {
    final problem = quote.problem;
    final text =
        problem ??
        switch (quote.payer) {
          ClaimPayer.sponsor => 'Free: no SOL needed, Deadman pays the fee',
          ClaimPayer.payout when quote.feeAmount == 0 => 'Free',
          ClaimPayer.payout =>
            'Fee ${amountText(quote.feeAmount, quote.feeToken)}, taken '
                'from the prize',
          ClaimPayer.wallet => 'Your wallet pays the network fee',
        };
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Text(
        text,
        style: TextStyle(
          color: problem == null ? DmColors.muted : DmColors.warn,
          fontSize: 12,
          height: 1.35,
        ),
      ),
    );
  }
}

/// Next to a claim from a plan whose protocol fee the owner's monthly plan
/// waives; with [quote], what the claim pays.
String feeWaivedText(ClaimQuote? quote) {
  const text = "No protocol fee (owner's monthly plan)";
  if (quote == null || quote.problem != null) return text;
  return '$text · you receive ${amountText(quote.net, quote.mint)}';
}

String waitingForFunds(String? mint) =>
    'Waiting for funds: this plan holds no ${assetSymbol(mint)} yet';

class _Note extends StatelessWidget {
  const _Note(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 6),
    child: Text(
      text,
      style: const TextStyle(color: DmColors.muted, fontSize: 12, height: 1.35),
    ),
  );
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
