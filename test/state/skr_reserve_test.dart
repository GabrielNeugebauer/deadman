import 'dart:convert';

import 'package:deadman/core/config.dart';
import 'package:deadman/solana/codec.dart' show PythFeedIds;
import 'package:deadman/solana/deadman_api.dart';
import 'package:deadman/state/assets.dart';
import 'package:deadman/state/prices.dart';
import 'package:deadman/state/protocol_fees.dart';
import 'package:deadman/state/skr_reserve.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fakes.dart';

const skr = AppConfig.skrMint;
const usdc = AppConfig.usdcMint;

final fees = FeeSchedule(
  treasury: addr(9),
  feeBpsPublic: 200,
  feeBpsPrivate: 200,
  skrMint: skr,
  feeBpsSkr: 150,
  skrBurnBps: 1000,
);

/// SOL 150 USD, USDC 1, SKR 0.02.
const usd = <String?, double>{null: 150, usdc: 1, skr: 0.02};

VaultState withReserve(VaultState v, int reserve) => VaultState(
  address: v.address,
  owner: v.owner,
  planId: v.planId,
  label: v.label,
  guard: v.guard,
  guardian: v.guardian,
  lockSecs: v.lockSecs,
  skipGraceSecs: v.skipGraceSecs,
  lastPulse: v.lastPulse,
  ownerLastSeen: v.ownerLastSeen,
  lockedUntil: v.lockedUntil,
  guardianReadyAt: v.guardianReadyAt,
  totalPulses: v.totalPulses,
  streak: v.streak,
  bestStreak: v.bestStreak,
  rules: v.rules,
  lamports: v.lamports,
  withdrawableLamports: v.withdrawableLamports,
  kind: v.kind,
  startAt: v.startAt,
  skrFeeReserve: reserve,
  skrReserveMint: reserve > 0 ? skr : null,
);

void main() {
  tearDown(forgetNfts);

  group('suggested reserve', () {
    test('plan value x 1.5% / SKR price x 1.3', () {
      // 1 SOL (150 USD) + 100 USDC = 250 USD; 1.5% = 3.75 USD = 187.5 SKR;
      // x 1.3 = 243.75 SKR.
      expect(
        suggestedSkrReserve(
          deposits: {null: 1000000000, usdc: 100000000},
          usd: usd,
          fees: fees,
        ),
        243750000,
      );
    });

    test('SKR deposits and NFTs need no reserve', () {
      rememberNft(addr(40), 'Boney');
      expect(
        suggestedSkrReserve(
          deposits: {skr: 5000000000, addr(40): 1},
          usd: usd,
          fees: fees,
        ),
        0,
      );
    });

    test('unknown without the SKR price or a counted asset price', () {
      expect(
        suggestedSkrReserve(
          deposits: {null: 1},
          usd: const {null: 150},
          fees: fees,
        ),
        isNull,
      );
      expect(
        suggestedSkrReserve(
          deposits: {usdc: 1},
          usd: const {skr: 0.02},
          fees: fees,
        ),
        isNull,
      );
      expect(
        suggestedSkrReserve(deposits: {addr(41): 5}, usd: usd, fees: fees),
        isNull,
        reason: 'an unknown token has no decimals',
      );
    });
  });

  group('reserve need of a plan', () {
    test('the remaining payouts at today prices, rounded up per payout', () {
      final v = vault(
        withdrawableLamports: 1000000000,
        rules: [
          rule(seed: 10, mode: AmountMode.percent, amount: 5000),
          rule(seed: 11, afterSecs: 20 * 86400, amount: 10000),
          rule(seed: 12, mint: usdc, mode: AmountMode.fixed, amount: 50000000),
          rule(seed: 13, mint: skr, mode: AmountMode.fixed, amount: 1000000),
        ],
      );
      // SOL: 0.5 + 0.5 SOL = 150 USD -> 2 x 1.125 USD = 2 x 56.25 SKR;
      // USDC: 50 -> 0.75 USD = 37.5 SKR; SKR pays in kind.
      expect(
        skrReserveNeed(v, {usdc: 50000000, skr: 1000000}, fees, usd),
        56250000 * 2 + 37500000,
      );
      expect(skrReserveNeed(v, null, fees, usd), isNull);
      expect(skrReserveNeed(v, {usdc: 1}, fees, const {null: 150}), isNull);
    });

    test('paid tiers need nothing; the reserve is not a tier balance', () {
      final paid = vault(
        withdrawableLamports: 1000000000,
        rules: [rule(executedAt: 5)],
      );
      expect(skrReserveNeed(paid, const {}, fees, usd), 0);
      final skrTier = withReserve(vault(rules: [rule(mint: skr)]), 700);
      expect(pendingPayouts(skrTier, skr, 1000), [(0, 300)]);
      expect(reservePricedAssets(skrTier, fees), {skr});
    });
  });

  group('the editor amount', () {
    test('typed wins, an empty field takes the suggestion', () {
      expect(chosenSkrReserve('', 5, skr), 5);
      expect(chosenSkrReserve(' 12.5 ', 5, skr), 12500000);
      expect(chosenSkrReserve('1.2345678', 5, skr), isNull);
      expect(chosenSkrReserve('', null, skr), isNull);
    });

    test('must be positive and in the wallet, with SKR deposits', () {
      expect(skrReserveError(amount: null, wallet: 1, skrMint: skr), isNotNull);
      expect(
        skrReserveError(amount: 0, wallet: 1, skrMint: skr),
        contains('turn this off'),
      );
      expect(skrReserveError(amount: 5, wallet: 5, skrMint: skr), isNull);
      expect(skrReserveError(amount: 5, wallet: null, skrMint: skr), isNull);
      expect(
        skrReserveError(amount: 6, wallet: 5, skrMint: skr),
        'Your wallet holds 0.000005 SKR.',
      );
      expect(
        skrReserveError(amount: 3, wallet: 5, skrMint: skr, alsoSpent: 3),
        contains('goes into the plan'),
      );
    });
  });

  group('fee texts', () {
    test('a plan card says when the reserve pays', () {
      final v = withReserve(vault(rules: [rule()]), 100);
      expect(
        planFeeText(v, fees),
        'Release fee: 1.5% · paid in SKR from the reserve · SKR fees 10% '
        'burned',
      );
      expect(planFeeText(vault(rules: [rule()]), fees), 'Release fee: 2%');
      expect(skrOptionTitle(fees), r'Pay fees in $SKR (1.5% instead of 2%)');
    });
  });

  group('USD prices', () {
    const now = 1790000000;

    Map<String, dynamic> hermesEntry(String id, int price, {int age = 5}) => {
      'id': id,
      'price': {
        'price': '$price',
        'conf': '1',
        'expo': -8,
        'publish_time': now - age,
      },
    };

    test('Hermes first; Jupiter for the rest, by mainnet mint', () async {
      final asked = <Uri>[];
      final prices = UsdPrices(
        clock: () => now,
        client: MockClient((req) async {
          asked.add(req.url);
          if (req.url.host == 'hermes.test') {
            expect(req.url.queryParametersAll['ids[]'], hasLength(2));
            return http.Response(
              jsonEncode({
                'parsed': [
                  hermesEntry(PythFeedIds.solUsd, 15000000000),
                  // Stale: Jupiter answers for SKR instead.
                  hermesEntry(PythFeedIds.skrUsd, 2000000, age: 3600),
                ],
              }),
              200,
            );
          }
          return http.Response(
            jsonEncode({
              'SKRbvo6Gf7GondiT3BbTfuRDPqLWei4j2Qy2NPGZhW3': {
                'usdPrice': 0.016,
              },
              addr(42): {'usdPrice': 3.5},
            }),
            200,
          );
        }),
        hermes: Uri.parse('https://hermes.test'),
        jupiter: Uri.parse('https://jup.test/price/v3'),
      );
      final got = await prices.fetch([null, skr, addr(42)]);
      expect(got, {null: 150.0, skr: 0.016, addr(42): 3.5});
      expect(asked.last.queryParameters['ids']!.split(','), {
        'SKRbvo6Gf7GondiT3BbTfuRDPqLWei4j2Qy2NPGZhW3',
        addr(42),
      });
    });

    test('Hermes refusing (401) falls back to Jupiter; failures price '
        'nothing', () async {
      final prices = UsdPrices(
        clock: () => now,
        client: MockClient(
          (req) async => req.url.host == 'hermes.test'
              ? http.Response('unauthorized', 401)
              : http.Response(
                  jsonEncode({
                    'So11111111111111111111111111111111111111112': {
                      'usdPrice': 110.5,
                    },
                  }),
                  200,
                ),
        ),
        hermes: Uri.parse('https://hermes.test'),
        jupiter: Uri.parse('https://jup.test/price/v3'),
      );
      expect(await prices.fetch([null, usdc]), {null: 110.5});
      final down = UsdPrices(
        client: MockClient((_) async => http.Response('', 500)),
        hermes: Uri.parse('https://hermes.test'),
        jupiter: Uri.parse('https://jup.test/price/v3'),
      );
      expect(await down.fetch([null]), isEmpty);
    });

    test('price keys are stable whatever the order', () {
      expect(priceKey([skr, null, usdc]), priceKey([usdc, skr, null]));
      expect(priceKey([null]), '');
    });
  });
}
