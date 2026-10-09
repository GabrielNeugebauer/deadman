import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../solana/deadman_api.dart';
import '../../state/actions.dart';
import '../../state/boney.dart';
import '../../state/boney_widget_sync.dart';
import '../../state/plan_math.dart';
import '../../state/providers.dart';
import '../../state/protocol_fees.dart';
import '../format.dart';
import '../rules_format.dart';
import '../widgets/boney_skins.dart';
import '../widgets/brand/brand.dart';
import '../widgets/feedback.dart';
import '../widgets/pack_icons.dart';
import 'plans/legacy_plans_card.dart';
import 'plans/plan_actions.dart';
import 'plans_screen.dart';

/// The check-in, and nothing else: the ring takes every pixel of height
/// the screen has, the button sits under it, and release plans live on
/// their own screen behind the app-bar button.
class PulseTab extends ConsumerStatefulWidget {
  const PulseTab({super.key});

  @override
  ConsumerState<PulseTab> createState() => _PulseTabState();
}

class _PulseTabState extends ConsumerState<PulseTab> {
  late final Timer _tick;
  late final AppLifecycleListener _lifecycle;
  int _now = nowSecs();
  bool _foreground = true;

  @override
  void initState() {
    super.initState();
    // The countdown is local; the chain is re-read once a minute, and only
    // while the app is visible, to stay under public RPC rate limits.
    _tick = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!_foreground) return;
      setState(() => _now = nowSecs());
      if (t.tick % 60 == 0) ref.invalidate(vaultsProvider);
    });
    _lifecycle = AppLifecycleListener(
      onResume: () => _foreground = true,
      onPause: () => _foreground = false,
    );
  }

  @override
  void dispose() {
    _tick.cancel();
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final vaults = ref.watch(vaultsProvider);
    return SafeArea(
      child: vaults.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => _Retry(
          message: '$e',
          onRetry: () => ref.invalidate(vaultsProvider),
        ),
        data: (list) => list.isEmpty
            ? const _ArmIntro()
            : RefreshIndicator(
                onRefresh: () async => refreshPlans(ref),
                child: _Pulse(plans: list, now: _now),
              ),
      ),
    );
  }
}

/// Index of [v]'s pending tier that comes due first, or null.
int? _nextTier(VaultState v) {
  int? next;
  for (var i = 0; i < v.rules.length; i++) {
    if (v.rules[i].settled) continue;
    if (next == null || v.ruleDueAt(i) < v.ruleDueAt(next)) next = i;
  }
  return next;
}

/// What the ring says. [sprite] is false for states that are not a skull
/// mood ("NOT ARMED", "NOTHING PENDING").
typedef _Readout = ({
  DMStatus status,
  String sticker,
  bool sprite,
  String big,
  String caption,
  String? address,
  double progress,
});

/// The smallest the pulse area gets before the page scrolls instead
/// (landscape phones, large font scales).
const _minPulseHeight = 480.0;

/// One check-in covers every active plan, so the ring counts down to the
/// next release across all of them: alive while it counts, due once a tier
/// is past its time.
class _Pulse extends ConsumerWidget {
  const _Pulse({required this.plans, required this.now});

  final List<VaultState> plans;
  final int now;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final duress = ref.watch(sessionProvider.select((s) => s.duress));
    final guard = ref.watch(guardAddressProvider);
    // On the web a check-in is wallet-signed, so guard coverage is moot.
    final web = ref.watch(isWebProvider);
    // A check-in covers inheritance plans only; vesting runs on its own.
    final switches = switchPlans(plans);
    // Plans with a pending tier; skipped tiers only await their claim.
    final active = activeSwitchPlans(plans);
    final locked = plans.any((v) => v.isLocked(now)) && !duress;
    final cover = guard.hasValue && !web
        ? PlanCoverage.of(plans, guard.value, now)
        : null;

    final urgent = active.isEmpty
        ? null
        : active.reduce((a, b) => a.nextReleaseAt! <= b.nextReleaseAt! ? a : b);
    final next = urgent?.nextReleaseAt;
    final firing = next != null && now > next;
    final tier = urgent == null ? null : _nextTier(urgent);
    final anyDue = switches.any(
      (v) => v.nextReleaseAt != null && now > v.nextReleaseAt!,
    );
    final boney = boneyFor(
      plans,
      now: now,
      lastCheckInAt: BoneyWidgetSync.lastCheckIn(ref.read(prefsProvider)),
      guard: guard.value,
    );

    final _Readout ring;
    if (urgent == null) {
      final allReleased = switches.every((v) => v.completed);
      ring = switches.isEmpty
          ? (
              status: DMStatus.released,
              sticker: 'Not armed',
              sprite: false,
              big: 'Off',
              caption: 'no release plan to check in',
              address: null,
              progress: 0.0,
            )
          : (
              status: DMStatus.released,
              sticker: allReleased ? 'All released' : 'Nothing pending',
              sprite: allReleased,
              big: 'Done',
              caption: allReleased
                  ? 'every plan released'
                  : 'no tier pending; reserved shares await claim',
              address: null,
              progress: 0.0,
            );
    } else if (firing) {
      ring = (
        status: DMStatus.due,
        sticker: DMStatus.due.label,
        sprite: true,
        big: span(now - next),
        caption: tier == null
            ? 'tier due, releasing'
            : 'past due, releasing to',
        address: tier == null ? null : short(urgent.rules[tier].beneficiary),
        progress: 0.0,
      );
    } else {
      // The share of this tier's wait still left since the last check-in.
      final wait = next! - urgent.lastPulse;
      ring = (
        status: DMStatus.alive,
        sticker: DMStatus.alive.label,
        sprite: true,
        big: span(next - now),
        caption: tier == null
            ? 'until the next release'
            : 'until tier ${tier + 1} releases',
        address: null,
        progress: wait <= 0 ? 0.0 : ((next - now) / wait).clamp(0.0, 1.0),
      );
    }

    final header = PageHeader(
      title: 'Pulse',
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (locked) ...[
            const StatusSticker(DMStatus.locked, dense: true),
            const SizedBox(width: DMSpace.xs),
          ],
          // No pull-to-refresh with a mouse.
          if (web)
            DMSquareButton(
              tooltip: 'Refresh',
              onPressed: () => refreshPlans(ref),
              child: const Icon(Icons.refresh, size: 22, color: DM.bone),
            ),
          DMSquareButton(
            key: const Key('open-plans'),
            tooltip: 'Release plans',
            badge: plans.length,
            onPressed: () => openPlans(context),
            // The tombstone means a tier is due, so it only stands in
            // for the list icon then.
            child: anyDue
                ? const PixelArt(
                    PixelSprites.tombstone,
                    size: 22,
                    color: DM.flatline,
                  )
                : const Icon(
                    Icons.view_list_outlined,
                    size: 22,
                    color: DM.bone,
                  ),
          ),
          _BoneyButton(boney),
        ],
      ),
    );

    final readout = ring.sprite
        ? PulseReadout(
            status: ring.status,
            statusLabel: ring.sticker.toUpperCase(),
            countdown: ring.big,
            countdownKey: const Key('pulse-countdown'),
            caption: ring.caption,
            address: ring.address,
            detail: urgent == null ? null : planName(urgent),
          )
        : _IdleReadout(
            sticker: ring.sticker,
            big: ring.big,
            caption: ring.caption,
          );

    return LayoutBuilder(
      builder: (context, box) => SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: SizedBox(
          height: math.max(box.maxHeight, _minPulseHeight),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              DMSpace.gutter,
              DMSpace.md,
              DMSpace.gutter,
              DMSpace.xl,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                header,
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: DMSpace.lg),
                    child: SegmentedRing(
                      progress: ring.progress,
                      status: ring.status,
                      phase: now,
                      child: readout,
                    ),
                  ),
                ),
                _PulseButton(
                  activePlans: active.length,
                  hasSwitch: switches.isNotEmpty,
                  firing: firing,
                  wallet: web,
                ),
                if (switches.isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: DMSpace.sm),
                    child: TextButton(
                      onPressed: () => openEditor(context),
                      child: const Text('Build a release plan'),
                    ),
                  ),
                if (web && active.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: DMSpace.md),
                    child: Text(
                      'On the web you check in with your wallet. Reminders '
                      'and one-tap check-ins are in the Android app.',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                if (cover != null && cover.otherGuard.isNotEmpty) ...[
                  const SizedBox(height: DMSpace.md),
                  _OtherGuardBanner(plans: cover.otherGuard),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The ring's readout for states that are not a skull mood: a plain
/// sticker, the word, the reason. Scales with the ring like
/// [PulseReadout].
class _IdleReadout extends StatelessWidget {
  const _IdleReadout({
    required this.sticker,
    required this.big,
    required this.caption,
  });

  final String sticker;
  final String big;
  final String caption;

  @override
  Widget build(BuildContext context) {
    final d = RingScope.of(context) ?? 240;
    double scaled(double share, double lo, double hi) =>
        (d * share).clamp(lo, hi).toDouble();
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Sticker(sticker, color: DM.ash, dense: d < 200),
        ),
        SizedBox(height: scaled(0.045, 8, 18)),
        Text(
          big,
          key: const Key('pulse-countdown'),
          maxLines: 1,
          style: DMType.countdown(DM.ash, size: scaled(0.165, 32, 104)),
        ),
        SizedBox(height: scaled(0.03, 4, 12)),
        Text(
          caption,
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: DMType.outfit(
            size: scaled(0.06, 14, 20),
            color: DM.haze,
            height: 1.3,
          ),
        ),
      ],
    );
  }
}

const _noPlan = Boney(
  mood: BoneyMood.noPlan,
  title: 'Make a plan',
  caption: 'Build a release plan in Deadman.',
  sticker: 'NO PLAN',
  button: BoneyButton.openApp,
);

/// Boney on his tile, top right, in the plan's status colour; he idles
/// while the plans are alive. Opens who he is and what each skull means.
class _BoneyButton extends StatelessWidget {
  const _BoneyButton(this.boney);

  final Boney boney;

  @override
  Widget build(BuildContext context) {
    final mood = boney.mood;
    return Tooltip(
      message: 'Boney',
      child: Semantics(
        button: true,
        label: 'Boney: ${boney.title}',
        excludeSemantics: true,
        child: Material(
          key: const Key('skull-button'),
          color: mood.background,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(DMRadius.button),
            side: BorderSide(
              color: mood.status == DMStatus.alive
                  ? DM.pulse.withValues(alpha: 0.25)
                  : DM.line,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => showModalBottomSheet<void>(
              context: context,
              showDragHandle: true,
              isScrollControlled: true,
              builder: (_) => _MoodSheet(boney: boney),
            ),
            // Wider than tall: his hearts, "?" and "z" reach the drawing's
            // edge columns and would touch the rounded corner.
            child: SizedBox(
              width: 60,
              height: 56,
              child: Center(child: SkinnedBoney(mood: mood, size: 48)),
            ),
          ),
        ),
      ),
    );
  }
}

/// The skull's moods the ring shows (brand book page 3), as a legend.
class _MoodSheet extends StatelessWidget {
  const _MoodSheet({required this.boney});

  final Boney boney;

  static const _moods = [
    (
      DMStatus.alive,
      'Alive',
      'The next release counts down from your last check-in. Check in '
          'before it ends and nothing moves.',
    ),
    (
      DMStatus.due,
      'Silent past a release tier',
      'A tier is due. Funds go to the beneficiary.',
    ),
    (
      DMStatus.released,
      'Plan fully released',
      'Every tier has paid out. Rest easy.',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(
          DMSpace.gutter,
          0,
          DMSpace.gutter,
          DMSpace.xxl,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                SkinnedBoney(mood: boney.mood, size: 72),
                const SizedBox(width: DMSpace.lg),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('MEET BONEY', style: DMType.label(color: DM.pulse)),
                      const SizedBox(height: 2),
                      Text(
                        boney.title,
                        key: const Key('boney-title'),
                        style: DMType.outfit(
                          size: 17,
                          weight: FontWeight.w700,
                          color: boney.mood.status.color,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Your skeleton on the Pulse screen and the home '
                        'screen. He wears the colour of your plans.',
                        style: DMType.outfit(
                          size: 14.5,
                          color: DM.dust,
                          height: 1.4,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: DMSpace.xl),
            BoneySkinPicker(mood: boney.mood),
            const SizedBox(height: DMSpace.xxl),
            Text('One skull, three moods', style: t.titleLarge),
            const SizedBox(height: DMSpace.xs),
            Text(
              'The ring, its sticker and the skull always agree.',
              style: t.bodyMedium,
            ),
            const SizedBox(height: DMSpace.xl),
            for (final (status, title, body) in _moods)
              Padding(
                padding: const EdgeInsets.only(bottom: DMSpace.xl),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    PixelSkull.status(status, size: 33),
                    const SizedBox(width: DMSpace.lg),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            style: DMType.outfit(
                              size: 17,
                              weight: FontWeight.w700,
                              color: status.color,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            body,
                            style: DMType.outfit(
                              size: 14.5,
                              color: DM.dust,
                              height: 1.4,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            Center(
              child: Text('CHECK IN, OR CHECK OUT.', style: DMType.tagline()),
            ),
          ],
        ),
      ),
    );
  }
}

class _PulseButton extends ConsumerStatefulWidget {
  const _PulseButton({
    required this.activePlans,
    required this.hasSwitch,
    this.firing = false,
    this.wallet = false,
  });

  final int activePlans;

  /// Check in with the owner's wallet (web) instead of the guard key.
  final bool wallet;

  /// The owner has at least one inheritance plan.
  final bool hasSwitch;

  /// A tier is due; checking in now stops it.
  final bool firing;

  @override
  ConsumerState<_PulseButton> createState() => _PulseButtonState();
}

class _PulseButtonState extends ConsumerState<_PulseButton> {
  bool _busy = false;

  Future<void> _pulse() async {
    if (widget.wallet) return _pulseWithWallet();
    setState(() => _busy = true);
    PlanCoverage? cover;
    final prefs = ref.read(prefsProvider);
    final ok = await runGuarded(context, () async {
      cover = await ref.read(actionsProvider).pulse();
      await BoneyWidgetSync.markCheckedIn(prefs, nowSecs());
    });
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok && cover != null) {
      toast(
        context,
        cover!.reportText(pulsed: true),
        error: !cover!.complete,
        sprite: cover!.complete ? PixelSprites.heart : null,
      );
    }
  }

  Future<void> _pulseWithWallet() async {
    setState(() => _busy = true);
    List<VaultState>? done;
    final prefs = ref.read(prefsProvider);
    await runGuarded(context, () async {
      done = await ref.read(actionsProvider).pulseWithWallet();
      await BoneyWidgetSync.markCheckedIn(prefs, nowSecs());
    });
    if (!mounted) return;
    setState(() => _busy = false);
    if (done != null) {
      toast(
        context,
        done!.length == 1
            ? 'Pulse recorded on ${planName(done!.single)}.'
            : 'Pulse recorded on ${done!.length} plans.',
        sprite: PixelSprites.heart,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final closed = widget.activePlans == 0;
    return FilledButton.icon(
      key: const Key('check-in'),
      style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(64)),
      onPressed: _busy || closed ? null : _pulse,
      icon: _busy
          ? const SizedBox.square(
              dimension: 20,
              child: CircularProgressIndicator(strokeWidth: 2, color: DM.ash),
            )
          : DMIcon(widget.wallet ? DMIcons.wallet : DMIcons.fingerprint),
      label: Text(
        !widget.hasSwitch
            ? 'No plan to check in'
            : closed
            ? 'All plans released'
            : widget.firing
            ? 'Check in to stop'
            : 'Check in',
      ),
    );
  }
}

/// Plans this phone's guard key can't check in (e.g. after "Forget this
/// device"): they would release while the owner is alive.
class _OtherGuardBanner extends ConsumerStatefulWidget {
  const _OtherGuardBanner({required this.plans});

  final List<VaultState> plans;

  @override
  ConsumerState<_OtherGuardBanner> createState() => _OtherGuardBannerState();
}

class _OtherGuardBannerState extends ConsumerState<_OtherGuardBanner> {
  bool _busy = false;

  Future<void> _move() async {
    setState(() => _busy = true);
    await runGuarded(
      context,
      ref.read(actionsProvider).rotateGuard,
      success: 'Guard moved to this phone',
    );
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final n = widget.plans.length;
    return DMCard(
      padding: const EdgeInsets.fromLTRB(
        DMSpace.lg,
        DMSpace.md,
        DMSpace.sm,
        DMSpace.xxs,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const DMIcon(DMIcons.key, color: DM.missed),
              const SizedBox(width: DMSpace.md),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(right: DMSpace.sm),
                  child: Text(
                    '${n == 1 ? '1 plan is' : '$n plans are'} guarded by '
                    'another device (${widget.plans.map(planName).join(', ')}). '
                    'Check in on this phone can\'t reach '
                    '${n == 1 ? 'it' : 'them'}.',
                    style: DMType.outfit(size: 14, height: 1.4),
                  ),
                ),
              ),
            ],
          ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: _busy ? null : _move,
              child: const Text('Move guard to this phone'),
            ),
          ),
        ],
      ),
    );
  }
}

/// No plans yet: what a release plan is, what each rail costs, and the
/// way in.
class _ArmIntro extends ConsumerWidget {
  const _ArmIntro();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    final fees = ref.watch(feesProvider).value;
    String? fee(Rail r) =>
        fees == null ? null : percentText(fees.bpsFor(r) / 10000);
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        DMSpace.gutter,
        DMSpace.md,
        DMSpace.gutter,
        DMSpace.xxxl,
      ),
      children: [
        PageHeader(
          title: 'Arm your switch',
          subtitle:
              'Build a release plan: who receives what, after how long without '
              'a check-in, and how it gets there. Create as many plans as you '
              'like; one check-in keeps them all alive.',
          trailing: _BoneyButton(_noPlan),
        ),
        const LegacyPlansCard(margin: EdgeInsets.only(top: DMSpace.xl)),
        const SizedBox(height: DMSpace.xxl),
        Text('How it arrives', style: t.titleSmall),
        const SizedBox(height: DMSpace.md),
        DMListGroup(
          children: [
            for (final r in Rail.values)
              DMListRow(
                leading: RailTile(r),
                title: r.label,
                subtitle: r.blurb,
                monoSubtitle: false,
                trailing: switch (fee(r)) {
                  final f? => Text(f, style: DMType.data(color: DM.haze)),
                  null => null,
                },
              ),
          ],
        ),
        const SizedBox(height: DMSpace.xxl),
        FilledButton.icon(
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
          onPressed: () => openEditor(context),
          icon: const DMIcon(DMIcons.plus),
          label: const Text('Build release plan'),
        ),
        const SizedBox(height: DMSpace.md),
        OutlinedButton(
          style: OutlinedButton.styleFrom(
            minimumSize: const Size.fromHeight(48),
            padding: const EdgeInsets.symmetric(
              horizontal: DMSpace.lg,
              vertical: DMSpace.md,
            ),
          ),
          onPressed: () => openVestingEditor(context),
          child: const Text(
            'Or set up vesting: release in installments over time',
            textAlign: TextAlign.center,
          ),
        ),
        const SizedBox(height: DMSpace.xl),
        Text(
          'Deadman only charges when a tier releases funds '
          '(${feeSummaryText(fees)}).',
          textAlign: TextAlign.center,
          style: t.bodySmall?.copyWith(height: 1.45),
        ),
        const SizedBox(height: DMSpace.xxxl),
        Center(child: Text('CHECK IN, OR CHECK OUT.', style: DMType.tagline())),
      ],
    );
  }
}

class _Retry extends StatelessWidget {
  const _Retry({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(DMSpace.xxl),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.cloud_off, color: DM.ash, size: 32),
          const SizedBox(height: DMSpace.md),
          Text(
            message,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: DMSpace.md),
          TextButton(onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
    ),
  );
}
