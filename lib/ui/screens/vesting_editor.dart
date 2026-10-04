import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/config.dart';
import '../../solana/deadman_api.dart';
import '../../state/actions.dart';
import '../../state/assets.dart';
import '../../state/plan_math.dart';
import '../../state/providers.dart';
import '../../state/vesting.dart';
import '../rules_format.dart';
import '../theme.dart';
import '../widgets/feedback.dart';
import '../widgets/vesting_progress.dart';

const _vestAssets = [solAsset, usdcAsset];

class _Schedule {
  _Schedule()
    : beneficiary = TextEditingController(),
      amount = TextEditingController();

  final TextEditingController beneficiary;
  final TextEditingController amount;
  Rail rail = Rail.solana;
  String? mint = AppConfig.usdcMint;
  int cliffSecs = 0;
  int durationSecs = 12 * monthSecs;

  /// Lenient total for the live funding sums; 0 while incomplete.
  int get totalOrZero {
    final v = parseAmount(amount.text, mint);
    return v == null || v < 0 ? 0 : v;
  }

  VestingSpec build() => parseSchedule(
    beneficiary: beneficiary.text,
    rail: rail,
    mint: mint,
    amount: amount.text,
    cliffSecs: cliffSecs,
    durationSecs: durationSecs,
  );

  void applyClaimCode() {
    final (who, rail) = parseBeneficiary(beneficiary.text);
    if (rail == null) return;
    this.rail = rail;
    beneficiary.text = who;
  }

  void dispose() {
    beneficiary.dispose();
    amount.dispose();
  }
}

/// Creates a vesting plan: schedules that release gradually from a start
/// date whatever the owner does. No check-ins; panic lockdown covers it.
class VestingEditorPage extends ConsumerStatefulWidget {
  const VestingEditorPage({super.key});

  @override
  ConsumerState<VestingEditorPage> createState() => _VestingEditorPageState();
}

class _VestingEditorPageState extends ConsumerState<VestingEditorPage> {
  final _label = TextEditingController();
  final _schedules = [_Schedule()];
  final _deposits = <String?, TextEditingController>{
    for (final a in _vestAssets) a.mint: TextEditingController(),
  };

  /// Deposits the user typed; the others follow the totals.
  final _edited = <String?>{};
  DateTime? _startDate;
  bool _revocable = true;
  bool _demo = false;
  bool _busy = false;

  @override
  void dispose() {
    _label.dispose();
    for (final s in _schedules) {
      s.dispose();
    }
    for (final c in _deposits.values) {
      c.dispose();
    }
    super.dispose();
  }

  Map<String?, int> get _totals {
    final out = <String?, int>{};
    for (final s in _schedules) {
      out[s.mint] = (out[s.mint] ?? 0) + s.totalOrZero;
    }
    return out;
  }

  /// Re-derives untouched deposit fields from the schedule totals.
  void _changed() => setState(() {
    final totals = _totals;
    for (final a in _vestAssets) {
      if (_edited.contains(a.mint)) continue;
      final t = totals[a.mint] ?? 0;
      _deposits[a.mint]!.text = t == 0 ? '' : amountInput(t, a.mint);
    }
  });

  void _setDemo(bool on) => setState(() {
    _demo = on;
    if (on) return;
    for (final s in _schedules) {
      if (!cliffChoices(demo: false).any((c) => c.$1 == s.cliffSecs)) {
        s.cliffSecs = 0;
      }
      if (!durationChoices(demo: false).any((c) => c.$1 == s.durationSecs)) {
        s.durationSecs = 12 * monthSecs;
      }
    }
  });

  Future<void> _pickStart() async {
    final today = DateUtils.dateOnly(DateTime.now());
    final picked = await showDatePicker(
      context: context,
      initialDate: _startDate ?? today,
      firstDate: today,
      lastDate: today.add(const Duration(days: 365)),
      helpText: 'Vesting starts on',
    );
    if (picked == null) return;
    setState(
      () => _startDate = DateUtils.isSameDay(picked, today) ? null : picked,
    );
  }

  int _startAt(int now) {
    final d = _startDate;
    if (d == null) return now;
    final at = d.millisecondsSinceEpoch ~/ 1000;
    return at < now ? now : at;
  }

  int? _deposit(String? mint) {
    final text = _deposits[mint]!.text.trim();
    return text.isEmpty ? 0 : parseAmount(text, mint);
  }

  Future<bool> _confirm(
    List<VestingSpec> specs,
    Map<String?, int> deposits,
  ) async {
    final totals = totalsByAsset(specs);
    final gaps = [
      for (final e in totals.entries)
        if ((deposits[e.key] ?? 0) < e.value)
          '${amountText(e.value - (deposits[e.key] ?? 0), e.key)} short',
    ];
    if (gaps.isEmpty && _revocable) return true;
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            backgroundColor: DmColors.surface,
            title: Text(
              gaps.isEmpty ? 'Irrevocable plan' : 'Plan is underfunded',
            ),
            content: Text(
              [
                if (gaps.isNotEmpty)
                  'Your deposit does not cover every schedule (${gaps.join(', ')}). '
                      'Releases stop when the plan runs dry until you deposit more.',
                if (!_revocable)
                  'Irrevocable: once created you can never stop these schedules or '
                      'withdraw what they owe. Only funds above the totals stay yours.',
              ].join('\n\n'),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Go back'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Create plan'),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<void> _save() async {
    final now = nowSecs();
    final startAt = _startAt(now);
    final List<VestingSpec> specs;
    final deposits = <String?, int>{};
    try {
      checkVestingPlan(
        label: _label.text,
        startAt: startAt,
        now: now,
        schedules: _schedules.length,
      );
      specs = [for (final s in _schedules) s.build()];
      for (final mint in totalsByAsset(specs).keys) {
        final v = _deposit(mint);
        if (v == null) {
          throw VestingInputError('Check the ${unitLabel(mint)} deposit');
        }
        deposits[mint] = v;
      }
    } on VestingInputError catch (e) {
      toast(context, e.message, error: true);
      return;
    }
    if (!await _confirm(specs, deposits) || !mounted) return;

    setState(() => _busy = true);
    var unguarded = const <VaultState>[];
    final ok = await runGuarded(
      context,
      () async => unguarded = await ref
          .read(actionsProvider)
          .createVesting(
            label: _label.text.trim(),
            startAt: startAt,
            revocable: _revocable,
            schedules: specs,
            lockSecs: vestingLockSecs(demo: _demo),
            depositLamports: deposits[null] ?? 0,
            tokenDeposits: {
              for (final e in deposits.entries)
                if (e.key != null && e.value > 0) e.key!: e.value,
            },
          ),
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (!ok) return;
    toast(
      context,
      unguarded.isEmpty
          ? 'Vesting plan created'
          : 'Vesting plan created. ${unguarded.map(planName).join(', ')} '
                'still ${unguarded.length == 1 ? 'is' : 'are'} guarded by another device: '
                'use Security → Move guard to this phone.',
      error: unguarded.isNotEmpty,
    );
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final fees = ref.watch(feesProvider).value;
    final walletSol = ref.watch(walletBalanceProvider).value;
    final walletUsdc = ref.watch(walletUsdcProvider).value;
    final totals = _totals;
    final used = [
      for (final a in _vestAssets)
        if (_schedules.any((s) => s.mint == a.mint)) a,
    ];
    return Scaffold(
      appBar: AppBar(
        backgroundColor: DmColors.bg,
        title: const Text('New vesting plan'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
        children: [
          Text(
            'Each schedule releases an amount to someone gradually from the start date, '
            'whether or not you check in. Nothing unlocks before the cliff; after it, '
            'the vested amount grows every second until the end.',
            style: t.bodyMedium?.copyWith(color: DmColors.muted, height: 1.4),
          ),
          const SizedBox(height: 18),
          TextField(
            controller: _label,
            maxLength: 32,
            decoration: const InputDecoration(
              labelText: 'Plan name',
              hintText: 'e.g. Team grants, Allowance',
              prefixIcon: Icon(Icons.label_outline),
            ),
          ),
          const SizedBox(height: 6),
          const Text('Starts', style: TextStyle(color: DmColors.muted)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              ChoiceChip(
                label: const Text('Now'),
                selected: _startDate == null,
                onSelected: (_) => setState(() => _startDate = null),
              ),
              ChoiceChip(
                avatar: const Icon(Icons.event, size: 16),
                label: Text(
                  _startDate == null
                      ? 'Pick a date'
                      : DateFormat.yMMMd().format(_startDate!),
                ),
                selected: _startDate != null,
                onSelected: (_) => _pickStart(),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Card(
            child: Column(
              children: [
                SwitchListTile(
                  value: _revocable,
                  onChanged: (v) => setState(() => _revocable = v),
                  title: Text(_revocable ? 'Revocable' : 'Irrevocable'),
                  subtitle: Text(
                    _revocable
                        ? 'You can stop future vesting at any time. Whatever has vested by then stays theirs.'
                        : 'Funds are committed: you can never stop the schedules or take back what they owe.',
                    style: const TextStyle(color: DmColors.muted, height: 1.35),
                  ),
                ),
                const Divider(height: 1, color: DmColors.line),
                SwitchListTile(
                  value: _demo,
                  onChanged: _setDemo,
                  title: const Text('Demo timings'),
                  subtitle: const Text(
                    'Adds a 2-minute cliff and 10-minute vesting so it can be shown live.',
                    style: TextStyle(color: DmColors.muted, height: 1.35),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          for (final (i, s) in _schedules.indexed)
            _ScheduleCard(
              index: i,
              schedule: s,
              demo: _demo,
              fees: fees,
              onRemove: _schedules.length > 1
                  ? () {
                      final removed = _schedules.removeAt(i);
                      _changed();
                      removed.dispose();
                    }
                  : null,
              onChanged: _changed,
            ),
          if (_schedules.length < maxSchedules)
            OutlinedButton.icon(
              onPressed: () {
                _schedules.add(_Schedule());
                _changed();
              },
              icon: const Icon(Icons.add),
              label: const Text('Add schedule'),
            ),
          const SizedBox(height: 18),
          Text('Initial deposit', style: t.titleLarge),
          const SizedBox(height: 4),
          const Text(
            'Defaults to the schedule totals so the plan is fully funded.',
            style: TextStyle(color: DmColors.muted, fontSize: 12),
          ),
          for (final a in used) ...[
            const SizedBox(height: 10),
            _DepositField(
              asset: a,
              controller: _deposits[a.mint]!,
              total: totals[a.mint] ?? 0,
              wallet: a.mint == null ? walletSol : walletUsdc,
              onChanged: () => setState(() => _edited.add(a.mint)),
            ),
          ],
          const SizedBox(height: 24),
          FilledButton(
            onPressed: _busy ? null : _save,
            child: _busy
                ? const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Create vesting plan'),
          ),
          const SizedBox(height: 12),
          const Text(
            'One wallet approval creates the plan and makes your deposit. Anyone can trigger a '
            'release once an amount has vested; it always goes to the schedule\'s beneficiary.',
            style: TextStyle(color: DmColors.muted, fontSize: 12, height: 1.4),
          ),
        ],
      ),
    );
  }
}

class _DepositField extends StatelessWidget {
  const _DepositField({
    required this.asset,
    required this.controller,
    required this.total,
    required this.wallet,
    required this.onChanged,
  });

  final AssetInfo asset;
  final TextEditingController controller;
  final int total;
  final int? wallet;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final deposit = controller.text.trim().isEmpty
        ? 0
        : parseAmount(controller.text, asset.mint);
    final short = deposit != null && deposit < total;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: controller,
          onChanged: (_) => onChanged(),
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(
            labelText: '${asset.symbol} deposit',
            suffixText: asset.symbol,
            prefixIcon: const Icon(Icons.savings_outlined),
            helperText: [
              'Schedules need ${amountText(total, asset.mint)}',
              if (wallet != null)
                'wallet has ${amountText(wallet!, asset.mint)}',
            ].join(' · '),
          ),
        ),
        if (deposit == null)
          const Padding(
            padding: EdgeInsets.only(top: 4),
            child: Text(
              'Check this amount',
              style: TextStyle(color: DmColors.danger, fontSize: 12),
            ),
          )
        else if (short)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              'Underfunded by ${amountText(total - deposit, asset.mint)}: '
              'releases stop when the plan runs dry until you deposit more.',
              style: const TextStyle(
                color: DmColors.warn,
                fontSize: 12,
                height: 1.35,
              ),
            ),
          ),
      ],
    );
  }
}

class _ScheduleCard extends StatelessWidget {
  const _ScheduleCard({
    required this.index,
    required this.schedule,
    required this.demo,
    required this.fees,
    required this.onRemove,
    required this.onChanged,
  });

  final int index;
  final _Schedule schedule;
  final bool demo;
  final FeeSchedule? fees;
  final VoidCallback? onRemove;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final s = schedule;
    final feePct = fees == null ? null : fees!.bpsFor(s.rail) / 100;
    final cliffs = cliffChoices(demo: demo);
    final durations = durationChoices(demo: demo);
    Widget label(String text) => Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 6),
      child: Text(text, style: const TextStyle(color: DmColors.muted)),
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 6, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    'Schedule ${index + 1}',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const Spacer(),
                  if (onRemove != null)
                    IconButton(
                      tooltip: 'Remove schedule',
                      onPressed: onRemove,
                      icon: const Icon(
                        Icons.close,
                        color: DmColors.muted,
                        size: 20,
                      ),
                    ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextField(
                      controller: s.beneficiary,
                      onChanged: (_) {
                        final before = s.rail;
                        s.applyClaimCode();
                        if (s.rail != before) onChanged();
                      },
                      decoration: InputDecoration(
                        labelText: s.rail == Rail.solana
                            ? 'Beneficiary wallet'
                            : 'Beneficiary claim code',
                        helperText: s.rail == Rail.solana ? null : 'Paste the code from their Deadman app (Security → Receive privately)',
                        helperMaxLines: 2,
                      ),
                    ),
                    const SizedBox(height: 10),
                    SegmentedButton<Rail>(
                      showSelectedIcon: false,
                      segments: [
                        for (final r in Rail.values)
                          ButtonSegment(
                            value: r,
                            label: Text(r.label),
                            icon: Icon(r.icon, size: 16),
                          ),
                      ],
                      selected: {s.rail},
                      onSelectionChanged: (v) {
                        s.rail = v.first;
                        onChanged();
                      },
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '${s.rail.blurb}${feePct == null ? '' : ' · $feePct% fee on each release'}',
                      style: const TextStyle(
                        color: DmColors.muted,
                        fontSize: 12,
                      ),
                    ),
                    label('Asset and total'),
                    Row(
                      children: [
                        SegmentedButton<String?>(
                          showSelectedIcon: false,
                          segments: [
                            for (final a in _vestAssets)
                              ButtonSegment(
                                value: a.mint,
                                label: Text(a.symbol),
                              ),
                          ],
                          selected: {s.mint},
                          onSelectionChanged: (v) {
                            s.mint = v.first;
                            onChanged();
                          },
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: TextField(
                            key: ValueKey('vest-amount-$index'),
                            controller: s.amount,
                            onChanged: (_) => onChanged(),
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            decoration: InputDecoration(
                              labelText: 'Total',
                              suffixText: unitLabel(s.mint),
                            ),
                          ),
                        ),
                      ],
                    ),
                    label('Cliff'),
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      children: [
                        for (final (secs, text) in cliffs)
                          ChoiceChip(
                            label: Text(text),
                            selected: s.cliffSecs == secs,
                            onSelected: secs > s.durationSecs
                                ? null
                                : (_) {
                                    s.cliffSecs = secs;
                                    onChanged();
                                  },
                          ),
                      ],
                    ),
                    label('Vests over'),
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      children: [
                        for (final (secs, text) in durations)
                          ChoiceChip(
                            label: Text(text),
                            selected: s.durationSecs == secs,
                            onSelected: (_) {
                              s.durationSecs = secs;
                              if (s.cliffSecs > secs) s.cliffSecs = 0;
                              onChanged();
                            },
                          ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Text(
                      _summary(s),
                      style: const TextStyle(
                        color: DmColors.muted,
                        fontSize: 12,
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _summary(_Schedule s) {
    final total = s.totalOrZero;
    final what = total == 0 ? 'The total' : amountText(total, s.mint);
    final over = durationLabel(s.durationSecs);
    if (s.cliffSecs == 0) {
      return '$what unlocks evenly over $over from the start.';
    }
    final atCliff =
        (BigInt.from(total) *
                BigInt.from(s.cliffSecs) ~/
                BigInt.from(s.durationSecs))
            .toInt();
    return '$what vests over $over. Nothing unlocks for ${durationLabel(s.cliffSecs)}; '
        'then ${total == 0 ? 'the part vested so far' : amountText(atCliff, s.mint)} '
        'unlocks at once and the rest evenly until the end.';
  }
}
