import 'dart:typed_data';

import 'package:deadman/core/config.dart';
import 'package:deadman/solana/deadman_api.dart';
import 'package:deadman/solana/deadman_client.dart' show DeadmanException;
import 'package:deadman/state/actions.dart';
import 'package:deadman/state/assets.dart';
import 'package:deadman/state/private_rails.dart';
import 'package:deadman/state/providers.dart';
import 'package:deadman/ui/format.dart';
import 'package:deadman/ui/screens/circle_tab.dart';
import 'package:deadman/wallet/wallet_bridge.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../state/fakes.dart';
import '../state/installment_fakes.dart';

const usdc = AppConfig.usdcMint;

/// This wallet: the beneficiary of `rule(seed: 10)`.
final me = addr(10);

Future<FakeApi> _pump(
  WidgetTester tester,
  List<VaultState> watched, {
  Map<String, int> tokens = const {},
  FakeApi? fake,
  WalletBridge? wallet,
}) async {
  tester.view.physicalSize = const Size(1200, 4000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues({'owner': me});
  final prefs = await SharedPreferences.getInstance();
  final api = (fake ?? FakeApi(const []))..tokens.addAll(tokens);
  final zcash = FakeZcashRoute(live: false);
  final cloak = FakeCloakRoute(live: false);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        prefsProvider.overrideWithValue(prefs),
        apiProvider.overrideWithValue(api),
        secureStoreProvider.overrideWithValue(FakeSecureStore()),
        watchedVaultsProvider.overrideWith((ref) async => watched),
        zcashRouteProvider.overrideWithValue(zcash),
        cloakRouteProvider.overrideWith((ref) async => cloak),
        cloakStatusRouteProvider.overrideWithValue(cloak),
        privateRailsLiveProvider.overrideWithValue(false),
        biometricProvider.overrideWithValue((_) async => true),
        statusPollIntervalProvider.overrideWithValue(Duration.zero),
        if (wallet != null) walletProvider.overrideWithValue(wallet),
      ],
      child: const MaterialApp(home: Scaffold(body: CircleTab())),
    ),
  );
  await tester.pumpAndSettle();
  return api;
}

/// Quotes [quote] for every claim; [buildClaim] returns a marker byte per
/// call (1 sponsored, 2 wallet-paid) and [sendSigned] fails with each of
/// [sendErrors] first.
class _ClaimApi extends FakeApi {
  _ClaimApi(this.quote, {this.sendErrors = const []}) : super(const []);

  final ClaimQuote? quote;
  final List<Object> sendErrors;
  final builds = <bool>[];
  final sent = <List<int>>[];

  @override
  Future<ClaimQuote> quoteClaim({
    required String claimer,
    required String vaultOwner,
    required int planId,
    required int index,
  }) async => quote ?? (throw const DeadmanException('unknown'));

  @override
  Future<ClaimTx> buildClaim({
    required String claimer,
    required String vaultOwner,
    required int planId,
    required int index,
    bool sponsored = true,
  }) async {
    builds.add(sponsored);
    return sponsored
        ? ClaimTx(Uint8List.fromList([1]), ClaimPayer.sponsor)
        : ClaimTx(Uint8List.fromList([2]), ClaimPayer.wallet);
  }

  @override
  Future<List<String>> sendSigned(List<Uint8List> signedTransactions) async {
    final i = sent.length;
    sent.add(signedTransactions.single);
    if (i < sendErrors.length) throw sendErrors[i];
    return ['sig'];
  }
}

class _EchoWallet implements WalletBridge {
  int approvals = 0;

  @override
  Future<WalletSession> authorize() => throw UnimplementedError();

  @override
  Future<List<Uint8List>> signTransactions(List<Uint8List> txs) async {
    approvals++;
    return txs;
  }

  @override
  Future<void> deauthorize(String authToken) async {}
}

FilledButton _button(WidgetTester tester, String text) =>
    tester.widget<FilledButton>(find.widgetWithText(FilledButton, text));

void main() {
  // lastPulse 1000: every tier is long due and past its grace period.
  testWidgets('a due USDC tier the plan cannot pay: waiting for funds, no '
      'manual skip', (tester) async {
    final v = vault(rules: [rule(seed: 10, mint: usdc)]);
    final api = await _pump(tester, [v]);

    expect(_button(tester, 'Release this tier').onPressed, isNull);
    expect(
      find.text('Waiting for funds: this plan holds no USDC yet'),
      findsOneWidget,
    );
    expect(
      find.text(
        'Deadman skips it automatically after the grace period; '
        'its share stays reserved for you',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('Skip'), findsNothing);
    expect(find.byType(OutlinedButton), findsNothing);
    expect(api.balanceBatches.single, [(v.address, usdc)]);
  });

  testWidgets('a funded USDC tier can be released; no skip note', (
    tester,
  ) async {
    final v = vault(rules: [rule(seed: 10, mint: usdc)]);
    await _pump(tester, [v], tokens: {'${v.address}:$usdc': 5000000});

    expect(_button(tester, 'Release this tier').onPressed, isNotNull);
    expect(find.textContaining('Waiting for funds'), findsNothing);
    expect(find.textContaining('skips it automatically'), findsNothing);
  });

  testWidgets('an empty SOL plan waits for SOL; one batched lookup for '
      'several plans', (tester) async {
    final empty = vault(planId: 0, rules: [rule(seed: 10)]);
    final circle = vault(
      planId: 1,
      withdrawableLamports: 1000000000,
      rules: [rule(seed: 10, mint: circleDevnetUsdcMint)],
    );
    final api = await _pump(tester, [empty, circle]);

    expect(
      find.text('Waiting for funds: this plan holds no SOL yet'),
      findsOneWidget,
    );
    expect(
      find.text('Waiting for funds: this plan holds no USDC (Circle) yet'),
      findsOneWidget,
    );
    expect(api.balanceBatches.single, [(circle.address, circleDevnetUsdcMint)]);
  });

  testWidgets('a blocking tier of someone else: the keeper skips it, its '
      'share stays theirs', (tester) async {
    final other = addr(11);
    final v = vault(
      rules: [
        rule(seed: 11, mint: usdc),
        rule(seed: 10, mint: usdc, afterSecs: 20 * 86400),
      ],
    );
    await _pump(tester, [v]);

    expect(find.text('Release this tier'), findsNothing);
    expect(
      find.text(
        'Tier 1 could not pay and holds yours back. Deadman skips it '
        'automatically after the grace period; its share stays reserved '
        'for ${short(other)}',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('Skip'), findsNothing);
  });

  testWidgets('vesting: nothing to claim from an empty plan', (tester) async {
    final v = vestingVault(schedules: [schedule(seed: 10, mint: usdc)]);
    await _pump(tester, [v]);

    final claim = find.byWidgetPredicate(
      (w) =>
          w is FilledButton &&
          w.child is Text &&
          (w.child! as Text).data!.startsWith('Claim vested'),
    );
    expect(tester.widget<FilledButton>(claim).onPressed, isNull);
    expect(
      find.text('Waiting for funds: this plan holds no USDC yet'),
      findsOneWidget,
    );
  });

  group('installments', () {
    // 1 SOL in 10 one-minute installments, started 150 s ago: 2 unlocked.
    VaultState plan({required int released}) {
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      return withPeriod(
        vestingVault(
          startAt: now - 150,
          withdrawableLamports: 1000000000,
          schedules: [schedule(seed: 10, duration: 600, released: released)],
        ),
        60,
      );
    }

    final claimVested = find.textContaining('Claim vested');

    testWidgets('between installments there is nothing to claim', (
      tester,
    ) async {
      await _pump(tester, [plan(released: 200000000)]);
      expect(find.text('2 of 10 installments unlocked'), findsOneWidget);
      expect(
        find.textContaining('Next installment: 0.100 SOL on '),
        findsOneWidget,
      );
      expect(claimVested, findsNothing);
    });

    testWidgets('an unclaimed installment can be claimed', (tester) async {
      await _pump(
        tester,
        [plan(released: 100000000)],
        fake: _ClaimApi(
          const ClaimQuote(payer: ClaimPayer.sponsor, mint: null, net: 1),
        ),
      );
      expect(find.text('2 of 10 installments unlocked'), findsOneWidget);
      expect(_button(tester, 'Claim vested 0.100 SOL').onPressed, isNotNull);
    });
  });

  group('claim cost', () {
    final solTier = vault(withdrawableLamports: 1000000000, rules: [rule()]);
    final usdcTier = vault(rules: [rule(mint: usdc)]);
    final funded = {'${usdcTier.address}:$usdc': 5000000};

    testWidgets('a SOL tier of this wallet is free', (tester) async {
      await _pump(
        tester,
        [solTier],
        fake: _ClaimApi(
          const ClaimQuote(payer: ClaimPayer.sponsor, mint: null, net: 1),
        ),
      );
      expect(_button(tester, 'Release this tier').onPressed, isNotNull);
      expect(
        find.text('Free: no SOL needed, Deadman pays the fee'),
        findsOneWidget,
      );
    });

    testWidgets('a USDC tier shows the fee taken from the prize', (
      tester,
    ) async {
      await _pump(
        tester,
        [usdcTier],
        tokens: funded,
        fake: _ClaimApi(
          const ClaimQuote(
            payer: ClaimPayer.payout,
            mint: usdc,
            net: 4900000,
            feeToken: usdc,
            feeAmount: 20000,
          ),
        ),
      );
      expect(find.text('Fee 0.02 USDC, taken from the prize'), findsOneWidget);
    });

    testWidgets('vesting: the quote sits under Claim vested', (tester) async {
      final v = vestingVault(
        withdrawableLamports: 1000000000,
        schedules: [schedule(seed: 10)],
      );
      await _pump(
        tester,
        [v],
        fake: _ClaimApi(
          const ClaimQuote(payer: ClaimPayer.sponsor, mint: null, net: 1),
        ),
      );
      expect(
        find.text('Free: no SOL needed, Deadman pays the fee'),
        findsOneWidget,
      );
    });

    testWidgets('a claim that cannot go through is explained and disabled', (
      tester,
    ) async {
      const why = 'This payout is too small to open your account';
      await _pump(
        tester,
        [solTier],
        fake: _ClaimApi(
          const ClaimQuote(
            payer: ClaimPayer.sponsor,
            mint: null,
            net: 1,
            problem: why,
          ),
        ),
      );
      expect(_button(tester, 'Release this tier').onPressed, isNull);
      expect(find.text(why), findsOneWidget);
    });

    testWidgets('waiting for funds wins over the quote', (tester) async {
      await _pump(
        tester,
        [usdcTier],
        fake: _ClaimApi(
          const ClaimQuote(
            payer: ClaimPayer.payout,
            mint: usdc,
            net: 1,
            feeToken: usdc,
            feeAmount: 20000,
          ),
        ),
      );
      expect(
        find.text('Waiting for funds: this plan holds no USDC yet'),
        findsOneWidget,
      );
      expect(find.textContaining('taken from the prize'), findsNothing);
    });

    testWidgets('no quote: the button still works, nothing extra shown', (
      tester,
    ) async {
      await _pump(tester, [solTier], fake: _ClaimApi(null));
      expect(_button(tester, 'Release this tier').onPressed, isNotNull);
      expect(find.textContaining('Free'), findsNothing);
    });

    testWidgets('the sponsor refuses the signed claim: the wallet is asked '
        'once more and the toast says it paid', (tester) async {
      final wallet = _EchoWallet();
      final api = _ClaimApi(
        const ClaimQuote(payer: ClaimPayer.sponsor, mint: null, net: 1),
        sendErrors: [
          const DeadmanException(
            'Fee sponsor error: Rate limit: claimer reached 12 sponsored '
            'claims per 24h',
            name: 'KoraError',
          ),
        ],
      );
      await _pump(tester, [solTier], fake: api, wallet: wallet);
      await tester.tap(find.text('Release this tier'));
      await tester.pumpAndSettle();

      expect(api.builds, [true, false]);
      expect(api.sent, [
        [1],
        [2],
      ]);
      expect(wallet.approvals, 2);
      expect(
        find.text(
          'Tier released. The free claim service turned this claim down '
          '(Rate limit: claimer reached 12 sponsored claims per 24h), so '
          'your wallet paid the network fee.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('a program error is not retried from the wallet', (
      tester,
    ) async {
      final wallet = _EchoWallet();
      final api = _ClaimApi(
        const ClaimQuote(payer: ClaimPayer.sponsor, mint: null, net: 1),
        sendErrors: [DeadmanException.program(6019)],
      );
      await _pump(tester, [solTier], fake: api, wallet: wallet);
      await tester.tap(find.text('Release this tier'));
      await tester.pumpAndSettle();

      expect(api.builds, [true]);
      expect(wallet.approvals, 1);
      expect(
        find.textContaining("account cannot receive this payout"),
        findsOneWidget,
      );
    });
  });

  group("owner's monthly plan", () {
    const waived = "No protocol fee (owner's monthly plan)";

    /// [fake], with the owner's account subscription paid until [until].
    T subscribed<T extends FakeApi>(T fake, int until) => fake
      ..subscription = AccountSubscription(owner: addr(1), paidUntil: until);

    testWidgets('a covered tier says so, with the full payout', (tester) async {
      // Paid through the last check-in (lastPulse 1000).
      final v = vault(withdrawableLamports: 1000000000, rules: [rule()]);
      await _pump(
        tester,
        [v],
        fake: subscribed(
          _ClaimApi(
            const ClaimQuote(
              payer: ClaimPayer.sponsor,
              mint: null,
              net: 1000000000,
            ),
          ),
          2000,
        ),
      );
      expect(find.text('$waived · you receive 1.000 SOL'), findsOneWidget);
    });

    testWidgets('a lapse before the last check-in: the fee applies', (
      tester,
    ) async {
      final v = vault(withdrawableLamports: 1000000000, rules: [rule()]);
      await _pump(tester, [v], fake: subscribed(_ClaimApi(null), 999));
      expect(find.textContaining('No protocol fee'), findsNothing);
    });

    testWidgets('another owner subscribed: the fee applies', (tester) async {
      final v = vault(withdrawableLamports: 1000000000, rules: [rule()]);
      await _pump(
        tester,
        [v],
        fake: _ClaimApi(null)
          ..subscription = AccountSubscription(
            owner: addr(7),
            paidUntil: nowSecs() + 86400,
          ),
      );
      expect(find.textContaining('No protocol fee'), findsNothing);
    });

    testWidgets('vesting while subscribed, without a quote', (tester) async {
      final v = vestingVault(
        withdrawableLamports: 1000000000,
        schedules: [schedule(seed: 10)],
      );
      await _pump(tester, [
        v,
      ], fake: subscribed(_ClaimApi(null), nowSecs() + 86400));
      expect(find.text(waived), findsOneWidget);
    });

    testWidgets('vesting after the subscription ended: no note', (
      tester,
    ) async {
      final v = vestingVault(
        withdrawableLamports: 1000000000,
        schedules: [schedule(seed: 10)],
      );
      await _pump(tester, [
        v,
      ], fake: subscribed(_ClaimApi(null), nowSecs() - 86400));
      expect(find.textContaining('No protocol fee'), findsNothing);
    });
  });
}
