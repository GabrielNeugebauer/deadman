import 'dart:convert';

import 'package:solana/solana.dart';

import '../solana/deadman_api.dart';
import 'assets.dart';

/// Average calendar month (365.25 / 12 days).
const monthSecs = 2629800;

/// A plan holds at most this many schedules (same cap as tiers).
const maxSchedules = 8;

/// Latest start the editor allows, from now.
const maxStartAheadSecs = 365 * 86400;

/// Lock period for vesting plans (panic lockdown); shorter in demo mode.
int vestingLockSecs({required bool demo}) => demo ? 300 : 3 * 86400;

List<(int, String)> cliffChoices({required bool demo}) => [
  (0, 'None'),
  if (demo) (120, '2 minutes'),
  (monthSecs, '1 month'),
  (3 * monthSecs, '3 months'),
  (6 * monthSecs, '6 months'),
  (12 * monthSecs, '12 months'),
];

List<(int, String)> durationChoices({required bool demo}) => [
  if (demo) (600, '10 minutes'),
  (3 * monthSecs, '3 months'),
  (6 * monthSecs, '6 months'),
  (12 * monthSecs, '12 months'),
  (24 * monthSecs, '24 months'),
  (48 * monthSecs, '48 months'),
];

bool isAddress(String s) {
  try {
    Ed25519HDPublicKey.fromBase58(s.trim());
    return true;
  } catch (_) {
    return false;
  }
}

/// A plain address, or a claim code like `zcash:<address>` that also picks
/// the rail. Returns the address and the rail (null = keep the current one).
(String, Rail?) parseBeneficiary(String input) {
  final s = input.trim();
  final parts = s.split(':');
  if (parts.length == 2) {
    final rail = Rail.values.where((r) => r.name == parts[0]).firstOrNull;
    if (rail != null) return (parts[1], rail);
  }
  return (s, null);
}

/// Thrown by [parseSchedule] and [checkVestingPlan] with user-facing text.
class VestingInputError implements Exception {
  const VestingInputError(this.message);
  final String message;

  @override
  String toString() => message;
}

/// One schedule of the vesting editor, from what the user typed. [amount]
/// is in whole units of the asset (SOL, USDC), not base units.
VestingSpec parseSchedule({
  required String beneficiary,
  required Rail rail,
  required String? mint,
  required String amount,
  required int cliffSecs,
  required int durationSecs,
}) {
  final (who, codeRail) = parseBeneficiary(beneficiary);
  if (!isAddress(who)) {
    throw const VestingInputError('Check each beneficiary address');
  }
  final total = parseAmount(amount, mint);
  if (total == null || total <= 0) {
    throw VestingInputError(
      'Enter the total ${unitLabel(mint)} for each schedule',
    );
  }
  if (mint == null && total < 1000000) {
    throw const VestingInputError('SOL schedules must be at least 0.001 SOL');
  }
  if (durationSecs <= 0) {
    throw const VestingInputError('Pick a duration for each schedule');
  }
  if (cliffSecs < 0 || cliffSecs > durationSecs) {
    throw const VestingInputError(
      'A cliff cannot be longer than its vesting duration',
    );
  }
  return VestingSpec(
    beneficiary: who,
    rail: codeRail ?? rail,
    mint: mint,
    total: total,
    cliffSecs: cliffSecs,
    durationSecs: durationSecs,
  );
}

/// Plan-level checks; throws [VestingInputError].
void checkVestingPlan({
  required String label,
  required int startAt,
  required int now,
  required int schedules,
}) {
  if (schedules < 1 || schedules > maxSchedules) {
    throw const VestingInputError(
      'A vesting plan holds 1 to $maxSchedules schedules',
    );
  }
  if (utf8.encode(label.trim()).length > 32) {
    throw const VestingInputError('Plan name must be 32 characters or fewer');
  }
  if (startAt > now + maxStartAheadSecs) {
    throw const VestingInputError('Start within a year from today');
  }
}

/// Base units needed per asset (null = SOL) to fund every schedule.
Map<String?, int> totalsByAsset(Iterable<VestingSpec> schedules) {
  final out = <String?, int>{};
  for (final s in schedules) {
    out[s.mint] = (out[s.mint] ?? 0) + s.total;
  }
  return out;
}

/// Where one schedule of a vesting plan stands at [now].
class ScheduleProgress {
  const ScheduleProgress({
    required this.total,
    required this.cap,
    required this.vested,
    required this.released,
    required this.claimable,
    required this.startAt,
    required this.cliffAt,
    required this.endAt,
    required this.revokedAt,
  });

  final int total;

  /// The most it can ever release: [total], or what had vested at
  /// revocation.
  final int cap;
  final int vested;
  final int released;

  /// Vested and not yet released (before the vault balance cap and fees).
  final int claimable;
  final int startAt;
  final int cliffAt;
  final int endAt;
  final int revokedAt;

  bool get revoked => revokedAt != 0;
  bool get fullyVested => vested >= cap;
  bool get settled => released >= cap;

  double get vestedFraction => total == 0 ? 0 : vested / total;
  double get releasedFraction => total == 0 ? 0 : released / total;

  /// Owed to the beneficiary and not yet paid.
  int get owed => cap > released ? cap - released : 0;
}

ScheduleProgress scheduleProgress(VaultState v, int index, int now) {
  final r = v.rules[index];
  return ScheduleProgress(
    total: r.amount,
    cap: v.vestingCap(index),
    vested: v.vested(index, now),
    released: r.released,
    claimable: v.claimable(index, now),
    startAt: v.startAt,
    cliffAt: v.startAt + r.afterSecs,
    endAt: v.startAt + r.durationSecs,
    revokedAt: v.revokedAt,
  );
}

/// Every schedule has paid out all it ever can.
bool vestingSettled(VaultState v) => [
  for (var i = 0; i < v.rules.length; i++)
    v.vestingCap(i) <= v.rules[i].released,
].every((done) => done);

/// Base units of [mint] above what the plan owes its beneficiaries, given
/// the vault [balance] (withdrawable lamports for SOL).
int uncommitted(VaultState v, String? mint, int balance) {
  final free = balance - v.committed(mint);
  return free > 0 ? free : 0;
}

/// Base units of [mint] missing for every schedule to pay in full.
int shortfall(VaultState v, String? mint, int balance) {
  final gap = v.committed(mint) - balance;
  return gap > 0 ? gap : 0;
}
