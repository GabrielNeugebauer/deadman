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
import '../web/web_ui.dart';
import '../widgets/brand/brand.dart';
import '../widgets/feedback.dart';
import '../widgets/pack_icons.dart';
import '../widgets/private_funds.dart';
import '../widgets/vesting_progress.dart';

/// Family Circle: vaults naming this wallet (or this device's claim keys)
/// as a beneficiary or guardian.
class CircleTab extends ConsumerWidget {
  const CircleTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
          padding: const EdgeInsets.fromLTRB(
            DMSpace.gutter,
            DMSpace.md,
            DMSpace.gutter,
            DMSpace.xxxl,
          ),
          children: [
            PageHeader(
              title: 'Family Circle',
              subtitle:
                  'People who named you in their release or vesting plan.',
              // No pull-to-refresh with a mouse.
              trailing: ref.watch(isWebProvider)
                  ? DMSquareButton(
                      tooltip: 'Refresh',
                      onPressed: refresh,
                      child: const Icon(
                        Icons.refresh,
                        size: 20,
                        color: DM.bone,
                      ),
                    )
                  : null,
            ),
            const SizedBox(height: DMSpace.xxl),
            const PrivateFundsSection(),
            const ShieldedInboxTile(),
            const PrivateTransfersCard(),
            ...watched.when(
              loading: () => [
                const Padding(
                  padding: EdgeInsets.all(DMSpace.xxl),
                  child: Center(child: CircularProgressIndicator()),
                ),
              ],
              error: (e, _) => [
                _LoadError(error: e, web: ref.watch(isWebProvider)),
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

/// Where a plan stands: a sentence when the sticker alone does not say
/// it, the sticker's status and word, and whether the sticker wears the
/// status figure. Only the four moods and the lock wear one; vesting and
/// reserved states are words on their status color.
typedef _Standing = ({
  String? title,
  DMStatus status,
  String sticker,
  bool figure,
});

/// Inheritance plans are alive while the next release counts down, due
/// once a tier is past its time, released when every tier paid.
_Standing _standing(VaultState v, int now) {
  final next = v.nextReleaseAt;
  if (v.isVesting) {
    if (v.revokedAt != 0) {
      return (
        title: 'Vesting revoked; vested amounts stay claimable',
        status: DMStatus.released,
        sticker: 'Revoked',
        figure: false,
      );
    }
    if (vestingSettled(v)) {
      return (
        title: 'Fully paid out',
        status: DMStatus.released,
        sticker: 'Paid out',
        figure: true,
      );
    }
    if (now < v.startAt) {
      return (
        title: 'Vesting starts in ${span(v.startAt - now)}',
        status: DMStatus.released,
        sticker: 'Scheduled',
        figure: false,
      );
    }
    return (
      title: null,
      status: DMStatus.alive,
      sticker: 'Vesting',
      figure: false,
    );
  }
  if (next == null) {
    return v.completed
        ? (
            title: 'Plan fully released',
            status: DMStatus.released,
            sticker: DMStatus.released.label,
            figure: true,
          )
        : (
            title: 'No tier pending; reserved shares await claim',
            status: DMStatus.released,
            sticker: 'Reserved',
            figure: false,
          );
  }
  if (now > next) {
    return (
      title: 'Silent past a release tier',
      status: DMStatus.due,
      sticker: DMStatus.due.label,
      figure: true,
    );
  }
  if (v.isLocked(now)) {
    return (
      title: null,
      status: DMStatus.locked,
      sticker: DMStatus.locked.label,
      figure: true,
    );
  }
  return (
    title: null,
    status: DMStatus.alive,
    sticker: DMStatus.alive.label,
    figure: true,
  );
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
    // The owner's account-wide monthly plan waives the protocol fee.
    final waived = feeWaivedFor(
      v,
      ref.watch(watchedSubscriptionsProvider).value?[v.owner],
      now,
    );
    final standing = _standing(v, now);

    final tokens = ref
        .watch(watchedTokenBalancesProvider)
        .whenOrNull(data: (b) => b[v.address] ?? const <String, int>{});
    String forWhom(RuleState r) =>
        widget.keys.contains(r.beneficiary) ? 'you' : short(r.beneficiary);
    final live = ref.watch(privateRailsLiveProvider);
    final web = ref.watch(isWebProvider);
    return Padding(
      padding: const EdgeInsets.only(bottom: DMSpace.lg),
      child: DMCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: _PlanTitle(vault: v, guardian: isGuardian),
                ),
                const SizedBox(width: DMSpace.md),
                StatusSticker(
                  standing.status,
                  label: standing.sticker,
                  showSprite: standing.figure,
                ),
              ],
            ),
            if (standing.title case final title?) ...[
              const SizedBox(height: DMSpace.lg),
              Text(
                title,
                style: DMType.outfit(size: 16, weight: FontWeight.w600),
              ),
            ],
            const SizedBox(height: DMSpace.sm),
            if (v.isVesting)
              Text(
                'Vesting plan · ${v.revocable ? 'revocable by the owner' : 'irrevocable'}',
                style: DMType.data(),
              )
            else
              _LastCheckIn(
                text: 'Last check-in ${ago(v.lastPulse, now)}',
                alive:
                    standing.status == DMStatus.alive ||
                    standing.status == DMStatus.locked,
              ),
            if (v.isLocked(now))
              Text(
                'Vault locked for ${span(v.lockedUntil - now)} · releases still run',
                style: DMType.data(),
              ),
            if (v.isVesting)
              for (final (i, r) in mine) ...[
                const Divider(height: DMSpace.xxxl),
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
                const Divider(height: DMSpace.xxxl),
                _TierLine(
                  index: i,
                  amount: amountLabel(r),
                  rail: r.rail,
                  due: !r.executed && !r.skipped && v.ruleDueAt(i) <= now,
                  when: r.executed
                      ? 'Released ${ago(r.executedAt, now)} · ${amountText(r.paid, r.mint)}'
                      : r.skipped
                      ? skippedLabel(r)
                      : v.ruleDueAt(i) > now
                      ? 'Releases after ${span(v.ruleDueAt(i) - now)} more silence'
                      : 'Due now',
                ),
                if (v.canExecute(i, now)) ...[
                  const SizedBox(height: DMSpace.lg),
                  FilledButton(
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
                      r.skipped ? 'Claim reserved share' : 'Release this tier',
                    ),
                  ),
                  if (tierFunded(v, i, tokens) == false)
                    FinePrint(waitingForFunds(r.mint), problem: true)
                  else if (_quote(i, true) case final q?)
                    _ClaimCost(q)
                  else if (r.rail != Rail.solana)
                    const FinePrint(
                      'Releasing from your wallet links it to this payout. The Deadman keeper releases due tiers automatically.',
                    ),
                  if (waived) FinePrint(feeWaivedText(_quote(i, true))),
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
                  FinePrint(
                    '${j == i ? '' : 'Tier ${j + 1} could not pay and holds yours back. '}'
                    'Deadman skips it automatically after the grace period; '
                    'its share stays reserved for ${forWhom(v.rules[j])}',
                  ),
                if (r.executed &&
                    r.rail != Rail.solana &&
                    routableMint(r.mint)) ...[
                  const SizedBox(height: DMSpace.md),
                  _RouteButton(
                    rail: r.rail,
                    live: live,
                    web: web,
                    onPressed: _busy || !live ? null : () => _route(r),
                  ),
                ],
              ],
          ],
        ),
      ),
    );
  }
}

/// The plan's name over its owner's address; an unnamed plan is its
/// owner's address. "GUARDIAN" when this wallet guards it.
class _PlanTitle extends StatelessWidget {
  const _PlanTitle({required this.vault, required this.guardian});

  final VaultState vault;
  final bool guardian;

  @override
  Widget build(BuildContext context) {
    final owner = short(vault.owner);
    final named = vault.label.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          named ? vault.label : owner,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: named
              ? Theme.of(context).textTheme.titleLarge
              : DMType.mono(size: 17, weight: FontWeight.w500),
        ),
        if (named || guardian) ...[
          const SizedBox(height: DMSpace.xxs),
          Wrap(
            spacing: DMSpace.sm,
            runSpacing: DMSpace.xxs,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (named) Text('Owner $owner', style: DMType.data(size: 12.5)),
              if (guardian) const MonoLabel('Guardian', color: DM.haze),
            ],
          ),
        ],
      ],
    );
  }
}

/// "Last check-in 2h 4m ago" led by the pixel heart (check-ins): a pulse
/// heart while the next release still counts down (locked or not), a grey
/// one once a tier is due or the plan is done.
class _LastCheckIn extends StatelessWidget {
  const _LastCheckIn({required this.text, required this.alive});

  final String text;
  final bool alive;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      PixelArt(PixelSprites.heart, size: 11, color: alive ? DM.pulse : DM.ash),
      const SizedBox(width: DMSpace.sm),
      Flexible(child: Text(text, style: DMType.data())),
    ],
  );
}

/// One tier of a release plan: which tier, what it pays, when, and on
/// which rail. A due tier wears the tombstone.
class _TierLine extends StatelessWidget {
  const _TierLine({
    required this.index,
    required this.amount,
    required this.rail,
    required this.when,
    required this.due,
  });

  final int index;
  final String amount;
  final Rail rail;
  final String when;

  /// Past its time and not released: flatline, with the tombstone.
  final bool due;

  @override
  Widget build(BuildContext context) {
    final whenColor = due ? DM.flatline : DM.dust;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              MonoLabel('Tier ${index + 1}'),
              const SizedBox(height: DMSpace.xs),
              Text(amount, style: Theme.of(context).textTheme.bodyLarge),
              const SizedBox(height: DMSpace.xxs),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (due) ...[
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: PixelArt(
                        PixelSprites.tombstone,
                        size: 12,
                        color: DM.flatline,
                      ),
                    ),
                    const SizedBox(width: DMSpace.sm),
                  ],
                  Flexible(
                    child: Text(when, style: DMType.data(color: whenColor)),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(width: DMSpace.md),
        RailTag(rail),
      ],
    );
  }
}

/// Outlined "Route privately via …", or why routing is off here.
class _RouteButton extends StatelessWidget {
  const _RouteButton({
    required this.rail,
    required this.live,
    required this.web,
    required this.onPressed,
  });

  final Rail rail;
  final bool live;
  final bool web;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => OutlinedButton.icon(
    onPressed: onPressed,
    icon: RailIcon(rail),
    label: Text(
      live
          ? 'Route privately via ${rail.label}'
          : routeOffLabel(rail.label, web: web),
    ),
  );
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
    final next = nextInstallmentText(p, rule.mint);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  MonoLabel('Schedule ${index + 1}'),
                  const SizedBox(height: DMSpace.xs),
                  Text(
                    scheduleLabel(rule),
                    style: Theme.of(context).textTheme.bodyLarge,
                  ),
                ],
              ),
            ),
            const SizedBox(width: DMSpace.md),
            RailTag(rule.rail),
          ],
        ),
        const SizedBox(height: DMSpace.md),
        VestingBar(progress: p, color: p.revoked ? DM.ash : DM.pulse),
        const SizedBox(height: DMSpace.sm),
        Text(vestingAmounts(p, rule.mint), style: DMType.data()),
        // Revoked is not a missed check-in: bone for weight, never amber.
        Text(
          vestingStatus(p, rule.mint, now),
          style: DMType.data(color: p.revoked ? DM.bone : DM.dust),
        ),
        if (next != null) Text(next, style: DMType.data()),
        if (p.claimable > 0) ...[
          const SizedBox(height: DMSpace.lg),
          FilledButton(
            onPressed: busy || funded == false || quote?.problem != null
                ? null
                : onClaim,
            child: Text('Claim vested ${amountText(p.claimable, rule.mint)}'),
          ),
          if (funded == false)
            FinePrint(waitingForFunds(rule.mint), problem: true)
          else if (quote case final q?)
            _ClaimCost(q)
          else if (rule.rail != Rail.solana)
            const FinePrint(
              'Claiming from your wallet links it to this payout.',
            ),
          if (waived) FinePrint(feeWaivedText(quote)),
        ],
        if (rule.paid > 0 &&
            rule.rail != Rail.solana &&
            routableMint(rule.mint)) ...[
          const SizedBox(height: DMSpace.md),
          _RouteButton(
            rail: rule.rail,
            live: live,
            web: web,
            onPressed: busy || !live ? null : onRoute,
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
    return FinePrint(text, problem: problem != null);
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

/// Nobody has named this wallet: the mark skull and the address to
/// share.
class _Empty extends StatelessWidget {
  const _Empty({required this.address});

  final String address;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return DMCard(
      padding: const EdgeInsets.fromLTRB(
        DMSpace.cardPadding,
        DMSpace.xxl,
        DMSpace.cardPadding,
        DMSpace.cardPadding,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Align(
            alignment: Alignment.centerLeft,
            child: PixelSkull(size: 44),
          ),
          const SizedBox(height: DMSpace.xl),
          Text('Nobody has named you yet.', style: t.titleMedium),
          const SizedBox(height: DMSpace.xs),
          Text(
            'Share your wallet address for plain Solana payouts, or a private claim code from '
            'Security → Receive privately.',
            style: t.bodyMedium,
          ),
          const SizedBox(height: DMSpace.xl),
          OutlinedButton.icon(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: address));
              toast(context, 'Address copied');
            },
            icon: const Icon(Icons.copy, size: 18),
            label: Text(short(address), style: DMType.mono(size: 15)),
          ),
        ],
      ),
    );
  }
}

/// The plan lookup failed: what happened, and that pulling down retries.
class _LoadError extends StatelessWidget {
  const _LoadError({required this.error, required this.web});

  final Object error;

  /// No pull-to-refresh with a mouse: point at the Refresh button.
  final bool web;

  @override
  Widget build(BuildContext context) => DMCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Could not load the plans naming you',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: DMSpace.xs),
        Text('$error', style: DMType.data()),
        FinePrint(web ? 'Refresh to try again.' : 'Pull down to try again.'),
      ],
    ),
  );
}
