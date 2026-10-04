import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:solana/solana.dart';

import '../core/config.dart';
import '../rails/cloak_route.dart';
import '../rails/rails.dart';
import 'assets.dart';
import 'providers.dart';

/// SOL the program tops a Zcash claim key up with on a token payout
/// (`Limits.zcashGasStipend`), to pay for routing it. Kept on the key while
/// tokens remain. Cloak's stipend (0.012 SOL) covers [cloakTokenFeeReserve].
const tokenGasStipend = 3000000;

/// Smallest SOL balance worth offering to route, per rail.
const minRoutableLamports = {Rail.zcash: 2000000, Rail.cloak: 15000000};

enum TransferKind { route, withdraw }

enum TransferPhase { pending, done, refunded, failed }

/// One private transfer started from this phone: a claim key routed to its
/// private destination, or a shielded note withdrawn to the wallet.
class PrivateTransfer {
  const PrivateTransfer({
    required this.id,
    required this.rail,
    required this.mint,
    required this.amount,
    required this.trackingId,
    required this.status,
    required this.createdAt,
    this.estimatedOut = '',
    this.kind = TransferKind.route,
  });

  factory PrivateTransfer.fromJson(Map<String, dynamic> j) => PrivateTransfer(
    id: j['id'] as String,
    rail: Rail.values.byName(j['rail'] as String),
    mint: j['mint'] as String?,
    amount: j['amount'] as int,
    trackingId: j['tracking'] as String,
    status: j['status'] as String,
    createdAt: j['at'] as int,
    estimatedOut: j['out'] as String? ?? '',
    kind: TransferKind.values.byName(j['kind'] as String? ?? 'route'),
  );

  final String id;
  final Rail rail;

  /// `null` for SOL.
  final String? mint;

  /// Base units that left the claim key (or the shielded pool).
  final int amount;

  /// 1Click deposit address (Zcash) or transaction signature (Cloak).
  final String trackingId;
  final String status;

  /// Unix seconds.
  final int createdAt;
  final String estimatedOut;
  final TransferKind kind;

  TransferPhase get phase => transferPhase(status);

  PrivateTransfer withStatus(String s, {String? trackingId}) => PrivateTransfer(
    id: id,
    rail: rail,
    mint: mint,
    amount: amount,
    trackingId: trackingId ?? this.trackingId,
    status: s,
    createdAt: createdAt,
    estimatedOut: estimatedOut,
    kind: kind,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'rail': rail.name,
    'mint': mint,
    'amount': amount,
    'tracking': trackingId,
    'status': status,
    'at': createdAt,
    'out': estimatedOut,
    'kind': kind.name,
  };
}

TransferPhase transferPhase(String status) => switch (status) {
  'SUCCESS' => TransferPhase.done,
  'REFUNDED' => TransferPhase.refunded,
  'FAILED' || 'INTERRUPTED' => TransferPhase.failed,
  _ => TransferPhase.pending,
};

/// Saved before the claim key signs, so a crash or error mid-route still
/// leaves a record to track (Zcash) or resume (Cloak).
const sendingStatus = 'SENDING';

/// A Cloak route that stopped before its result was known. Routing again
/// resumes it: a deposit that already landed is sent on, not repeated.
const interruptedStatus = 'INTERRUPTED';

/// A Cloak route whose deposit may sit in the claim key's own Cloak note.
bool resumableCloak(PrivateTransfer t) =>
    t.rail == Rail.cloak &&
    t.kind == TransferKind.route &&
    (t.status == interruptedStatus || t.status == 'FAILED');

/// What the user should know (and do) about [t] in its current status.
String transferStatusText(PrivateTransfer t) {
  if (t.status == sendingStatus) return 'Sending…';
  if (t.kind == TransferKind.withdraw) {
    return switch (t.phase) {
      TransferPhase.done => 'Withdrawn to your wallet',
      TransferPhase.failed => 'Withdrawal failed. Your notes stay in the shielded inbox; try again there.',
      _ => 'Waiting for confirmation',
    };
  }
  if (t.rail == Rail.cloak) {
    if (t.status == interruptedStatus) {
      return 'Interrupted before delivery. The funds wait on your claim key or '
          'in its Cloak note; tap Resume to finish.';
    }
    return switch (t.phase) {
      TransferPhase.done => 'Delivered privately',
      TransferPhase.failed =>
        'Transaction failed. The funds stay on your claim key or in its Cloak note; '
            'tap Resume to finish.',
      _ => 'Waiting for confirmation',
    };
  }
  return switch (t.status) {
    'PENDING_DEPOSIT' => 'Waiting for 1Click to see the deposit',
    'KNOWN_DEPOSIT_TX' => 'Deposit seen, swapping to ZEC',
    'PROCESSING' => 'Swapping to ZEC (about 2–3 minutes)',
    'SUCCESS' => 'Delivered as shielded ZEC',
    'INCOMPLETE_DEPOSIT' =>
      'The deposit was short of the quote. 1Click refunds it to your claim key; '
          'route again once it is back.',
    'REFUNDED' => 'Refunded to your claim key. Route again to retry.',
    'FAILED' => 'The swap failed. 1Click refunds to your claim key; route again once it is back.',
    _ => t.status,
  };
}

/// Routing history, newest first, kept in shared preferences.
class TransferHistory extends Notifier<List<PrivateTransfer>> {
  static const key = 'private_transfers';

  SharedPreferences get _prefs => ref.read(prefsProvider);

  @override
  List<PrivateTransfer> build() {
    final raw = _prefs.getString(key);
    if (raw == null) return const [];
    try {
      return [
        for (final j in jsonDecode(raw) as List)
          _afterRestart(PrivateTransfer.fromJson(j as Map<String, dynamic>)),
      ];
    } on Object {
      return const [];
    }
  }

  /// A route still marked sending was cut off (app killed): track the
  /// Zcash deposit address, offer to resume the Cloak route.
  static PrivateTransfer _afterRestart(PrivateTransfer t) =>
      t.status != sendingStatus
      ? t
      : t.withStatus(
          t.rail == Rail.zcash ? 'PENDING_DEPOSIT' : interruptedStatus,
        );

  Future<void> _save(List<PrivateTransfer> list) async {
    state = list;
    await _prefs.setString(key, jsonEncode([for (final t in list) t.toJson()]));
  }

  Future<void> add(PrivateTransfer t) => _save([t, ...state]);

  /// Replaces the record with [t]'s id, or adds it.
  Future<void> put(PrivateTransfer t) {
    final i = state.indexWhere((e) => e.id == t.id);
    return i < 0 ? add(t) : _save([...state]..[i] = t);
  }

  Future<void> setStatus(String id, String status) async {
    final i = state.indexWhere((t) => t.id == id);
    if (i < 0 || state[i].status == status) return;
    await _save([...state]..[i] = state[i].withStatus(status));
  }

  Future<void> remove(String id) => _save([...state.where((t) => t.id != id)]);
}

final transferHistoryProvider =
    NotifierProvider<TransferHistory, List<PrivateTransfer>>(
      TransferHistory.new,
    );

final statusPollIntervalProvider = Provider(
  (ref) => const Duration(seconds: 10),
);

/// Polls [route] until the status is final.
Stream<String> pollStatus(
  PrivateRoute route,
  String trackingId, {
  required Duration every,
}) async* {
  while (true) {
    final s = await route.status(trackingId);
    yield s;
    if (transferPhase(s) != TransferPhase.pending) return;
    await Future<void>.delayed(every);
  }
}

/// Live status of the transfer with this id, saved to the history as it
/// changes. Zcash follows 1Click's `track`; Cloak polls the signature.
final transferStatusProvider = StreamProvider.autoDispose
    .family<String, String>((ref, id) {
      final t = ref
          .read(transferHistoryProvider)
          .where((t) => t.id == id)
          .firstOrNull;
      if (t == null) return const Stream.empty();
      if (t.phase != TransferPhase.pending || t.status == sendingStatus) {
        return Stream.value(t.status);
      }
      final every = ref.read(statusPollIntervalProvider);
      final updates = t.rail == Rail.zcash
          ? ref.read(zcashRouteProvider).track(t.trackingId, every: every)
          : pollStatus(
              ref.read(cloakStatusRouteProvider),
              t.trackingId,
              every: every,
            );
      return updates.asyncMap((s) async {
        await ref.read(transferHistoryProvider.notifier).setStatus(id, s);
        return s;
      });
    });

/// What sits on a claim key, in base units.
class ClaimFunds {
  const ClaimFunds({required this.lamports, required this.usdc});

  final int lamports;
  final int usdc;
}

final claimFundsProvider = FutureProvider.family<ClaimFunds, String>((
  ref,
  address,
) async {
  final api = ref.watch(apiProvider);
  final (lamports, usdc) = await (
    api.balance(address),
    api.tokenBalance(address, AppConfig.usdcMint),
  ).wait;
  return ClaimFunds(lamports: lamports, usdc: usdc);
});

/// SOL kept on a claim key holding USDC, so the USDC can still be routed:
/// the program's stipend for Zcash, Cloak's larger token-deposit reserve.
int gasKeptForTokens(Rail rail) =>
    rail == Rail.cloak ? cloakTokenFeeReserve : tokenGasStipend;

/// SOL a Cloak USDC deposit needs on the claim key.
const cloakTokenFeeReserve = CloakRoute.defaultSplFeeReserveLamports;

/// Assets on a claim key worth offering to route through [rail]: USDC when
/// there is any, SOL beyond the gas kept for that USDC.
List<({String? mint, int amount})> routableAssets(Rail rail, ClaimFunds f) {
  final spareSol = f.lamports - (f.usdc > 0 ? gasKeptForTokens(rail) : 0);
  return [
    if (spareSol >= (minRoutableLamports[rail] ?? 0))
      (mint: null, amount: spareSol),
    if (f.usdc > 0) (mint: AppConfig.usdcMint, amount: f.usdc),
  ];
}

/// SOL and USDC are the assets the app routes privately.
bool routableMint(String? mint) => mint == null || mint == AppConfig.usdcMint;

/// Fee breakdown for a quote, for the confirm step.
String quoteFeesText(RouteQuote q) {
  final raw = q.raw;
  if (q.rail == Rail.zcash && raw is Map && raw['quote'] is Map) {
    final quote = raw['quote'] as Map;
    final usdIn = double.tryParse('${quote['amountInUsd']}');
    final usdOut = double.tryParse('${quote['amountOutUsd']}');
    final withdraw = int.tryParse('${quote['withdrawFee']}');
    return [
      if (usdIn != null && usdOut != null && usdIn > 0)
        'about \$${(usdIn - usdOut).toStringAsFixed(2)} '
            '(${((usdIn - usdOut) / usdIn * 100).toStringAsFixed(1)}%) in swap and app fees',
      if (withdraw != null) '${formatUnits(withdraw, 8)} ZEC Zcash network fee',
    ].join(' + ');
  }
  if (q.rail == Rail.cloak && raw is CloakQuoteData) {
    final pool = CloakRoute.pools[q.inputMint];
    final kept = q.inputMint == null
        ? ' A little SOL stays on the claim key for network fees.'
        : '';
    if (raw.shielded != null || pool == null) {
      return 'No protocol fee now; Cloak charges 0.3% plus a fixed fee when you unshield.$kept';
    }
    return 'Cloak exit fee ${amountText(CloakRoute.exitFee(q.amountIn, pool), q.inputMint)} '
        '(0.3% plus a fixed fee).$kept';
  }
  return 'Network fees only';
}

/// A `cloak:` shielded address rather than a Solana wallet.
bool isCloakAddress(String destination) => destination.startsWith('cloak:');

/// A public shielded-only unified address, used by the rails check when
/// this phone has no Zcash destination yet. Only ever dry-quoted.
const sampleZcashAddress =
    'u1cv7rewjqmj395gla0zzfz669ntf6cr5hx9n983ct5t4dv0gphgyg5qjqe5re6ue5menlw94876wp0q90uf2cskh75rfvfejr564x8heq9zrs5p40n0fhqvehy8sjgxy0eu58l87w2mk48y3j07ggvgw5z5lncusl6y2a03rqau44ha2g';

/// "Private rails check": proves a Cloak note on the phone and asks 1Click
/// for a dry SOL -> ZEC quote. Neither moves funds. Each throws on failure.
class RailsCheck {
  RailsCheck(this.ref);

  final Ref ref;

  static const zcashProbeLamports = 100000000;

  Future<String> cloak() async {
    try {
      final route = await ref.read(cloakRouteProvider.future);
      final t = await route.selfTest();
      return 'Proving files ${t.download.inMilliseconds} ms · '
          'proof ${t.prove == null ? 'n/a' : '${t.prove!.inMilliseconds} ms'} · '
          'total ${t.total.inMilliseconds} ms';
    } catch (_) {
      ref.invalidate(cloakRuntimeProvider);
      rethrow;
    }
  }

  Future<String> zcash() async {
    final profile = await ref.read(secureStoreProvider).loadClaim(Rail.zcash);
    final own = profile != null && profile.destination.startsWith('u1');
    final refundTo =
        profile?.key.address ?? (await Ed25519HDKeyPair.random()).address;
    final q = await ref
        .read(railsCheckZcashProvider)
        .estimate(
          claimKey: refundTo,
          inputMint: null,
          amount: zcashProbeLamports,
          destination: own ? profile.destination : sampleZcashAddress,
        );
    return '${amountText(zcashProbeLamports, null)} ≈ ${q.estimatedOut} to '
        '${own ? 'your u1 address' : 'a sample u1 address'} '
        '(dry quote, nothing reserved)';
  }
}

final railsCheckProvider = Provider(RailsCheck.new);
