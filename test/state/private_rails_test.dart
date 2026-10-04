import 'dart:convert';

import 'package:deadman/core/config.dart';
import 'package:deadman/rails/cloak_route.dart';
import 'package:deadman/rails/rails.dart';
import 'package:deadman/rails/zcash_route.dart';
import 'package:deadman/state/actions.dart';
import 'package:deadman/state/private_rails.dart';
import 'package:deadman/state/providers.dart';
import 'package:deadman/state/secure_store.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes.dart';

const u1 = sampleZcashAddress;
final cloakAddress = 'cloak:${'1' * 64}:${'2' * 64}';

class Rig {
  Rig(this.c, this.api, this.zcash, this.cloak, this.prefs);

  final ProviderContainer c;
  final FakeApi api;
  final FakeZcashRoute zcash;
  final FakeCloakRoute cloak;
  final SharedPreferences prefs;

  VaultActions get actions => c.read(actionsProvider);
  List<PrivateTransfer> get history => c.read(transferHistoryProvider);
}

Future<Rig> rig({
  List<ClaimProfile> profiles = const [],
  bool live = true,
  bool biometric = true,
  Map<String, Object> saved = const {},
}) async {
  SharedPreferences.setMockInitialValues({'owner': addr(1), ...saved});
  final prefs = await SharedPreferences.getInstance();
  final api = FakeApi(const []);
  final zcash = FakeZcashRoute(live: live);
  final cloak = FakeCloakRoute(live: live);
  final c = ProviderContainer(
    overrides: [
      prefsProvider.overrideWithValue(prefs),
      apiProvider.overrideWithValue(api),
      secureStoreProvider.overrideWithValue(FakeSecureStore(profiles)),
      zcashRouteProvider.overrideWithValue(zcash),
      cloakRouteProvider.overrideWith((ref) async => cloak),
      cloakStatusRouteProvider.overrideWithValue(cloak),
      privateRailsLiveProvider.overrideWithValue(live),
      biometricProvider.overrideWithValue((_) async => biometric),
      statusPollIntervalProvider.overrideWithValue(Duration.zero),
      railsCheckZcashProvider.overrideWithValue(zcash),
    ],
  );
  addTearDown(c.dispose);
  return Rig(c, api, zcash, cloak, prefs);
}

Future<ClaimProfile> profile(
  Rail rail,
  String destination, {
  int seed = 5,
}) async => ClaimProfile(
  rail: rail,
  key: await keyPair(seed),
  destination: destination,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const usdc = AppConfig.usdcMint;

  group('history', () {
    PrivateTransfer transfer({String status = 'PENDING_DEPOSIT'}) =>
        PrivateTransfer(
          id: 't1',
          rail: Rail.zcash,
          mint: usdc,
          amount: 5000000,
          trackingId: addr(77),
          status: status,
          createdAt: 1000,
          estimatedOut: '0.0034 ZEC',
        );

    test('round-trips through shared preferences', () async {
      final r = await rig();
      await r.c.read(transferHistoryProvider.notifier).add(transfer());
      await r.c
          .read(transferHistoryProvider.notifier)
          .setStatus('t1', 'REFUNDED');

      final again = ProviderContainer(
        overrides: [prefsProvider.overrideWithValue(r.prefs)],
      );
      addTearDown(again.dispose);
      final t = again.read(transferHistoryProvider).single;
      expect(t.rail, Rail.zcash);
      expect(t.mint, usdc);
      expect(t.amount, 5000000);
      expect(t.trackingId, addr(77));
      expect(t.status, 'REFUNDED');
      expect(t.phase, TransferPhase.refunded);
      expect(t.estimatedOut, '0.0034 ZEC');
      expect(t.kind, TransferKind.route);
    });

    test('a corrupt record reads as empty history', () async {
      final r = await rig(saved: {TransferHistory.key: 'not json'});
      expect(r.history, isEmpty);
    });

    test('status text tells the user about refunds and retries', () {
      expect(
        transferStatusText(transfer(status: 'REFUNDED')),
        contains('Route again'),
      );
      expect(
        transferStatusText(transfer(status: 'INCOMPLETE_DEPOSIT')),
        contains('refunds it to your claim key'),
      );
      expect(
        transferStatusText(transfer(status: 'SUCCESS')),
        'Delivered as shielded ZEC',
      );
      final cloak = PrivateTransfer(
        id: 'c',
        rail: Rail.cloak,
        mint: null,
        amount: 1,
        trackingId: 'sig',
        status: 'FAILED',
        createdAt: 1,
      );
      expect(transferStatusText(cloak), contains('tap Resume'));
      expect(cloak.phase, TransferPhase.failed);
    });

    test(
      'a route cut off mid-send is tracked or resumable after a restart',
      () async {
        PrivateTransfer sending(Rail rail) => PrivateTransfer(
          id: rail.name,
          rail: rail,
          mint: null,
          amount: 20000000,
          trackingId: rail == Rail.zcash ? addr(77) : '',
          status: sendingStatus,
          createdAt: 1,
        );
        final r = await rig(
          saved: {
            TransferHistory.key: jsonEncode([
              sending(Rail.zcash).toJson(),
              sending(Rail.cloak).toJson(),
            ]),
          },
        );
        expect(r.history.map((t) => t.status), [
          'PENDING_DEPOSIT',
          interruptedStatus,
        ]);
        expect(resumableCloak(r.history.last), isTrue);
        expect(transferStatusText(r.history.last), contains('tap Resume'));
      },
    );

    test('Zcash status follows track() and is saved', () async {
      final r = await rig();
      await r.c.read(transferHistoryProvider.notifier).add(transfer());
      final seen = <String>[];
      final sub = r.c.listen(
        transferStatusProvider('t1'),
        (_, next) => next.whenData(seen.add),
      );
      addTearDown(sub.close);
      await pumpEventQueue();
      expect(r.zcash.tracked, [addr(77)]);
      expect(seen, ['PROCESSING', 'SUCCESS']);
      expect(r.history.single.status, 'SUCCESS');
      expect(
        r.prefs.getString(TransferHistory.key),
        contains('"status":"SUCCESS"'),
      );
    });

    test('Cloak status polls the signature until final', () async {
      final r = await rig();
      await r.c
          .read(transferHistoryProvider.notifier)
          .add(
            const PrivateTransfer(
              id: 'c1',
              rail: Rail.cloak,
              mint: null,
              amount: 1,
              trackingId: 'sig',
              status: 'PENDING',
              createdAt: 1,
            ),
          );
      final sub = r.c.listen(transferStatusProvider('c1'), (_, _) {});
      addTearDown(sub.close);
      await pumpEventQueue();
      expect(r.cloak.statusCalls, ['sig', 'sig']);
      expect(r.history.single.status, 'SUCCESS');
    });

    test('final transfers are not polled again', () async {
      final r = await rig();
      await r.c
          .read(transferHistoryProvider.notifier)
          .add(transfer(status: 'SUCCESS'));
      final sub = r.c.listen(transferStatusProvider('t1'), (_, _) {});
      addTearDown(sub.close);
      await pumpEventQueue();
      expect(r.zcash.tracked, isEmpty);
    });
  });

  group('routable assets', () {
    test('USDC keeps the gas stipend in SOL', () {
      final rows = routableAssets(
        Rail.zcash,
        const ClaimFunds(lamports: tokenGasStipend, usdc: 5000000),
      );
      expect(rows, [(mint: usdc, amount: 5000000)]);
    });

    test('SOL beyond the stipend and the rail minimum', () {
      expect(
        routableAssets(
          Rail.zcash,
          const ClaimFunds(lamports: 500000000, usdc: 1),
        ).first,
        (mint: null, amount: 500000000 - tokenGasStipend),
      );
      expect(
        routableAssets(
          Rail.cloak,
          const ClaimFunds(lamports: 10000000, usdc: 0),
        ),
        isEmpty,
      );
    });
  });

  test('fee text for each rail', () {
    final z = RouteQuote(
      rail: Rail.zcash,
      amountIn: 5000000,
      inputMint: usdc,
      estimatedOut: '0.0034 ZEC',
      expiresAt: DateTime(2030),
      raw: {
        'quote': {
          'amountInUsd': '5.00',
          'amountOutUsd': '4.50',
          'withdrawFee': '32000',
        },
      },
    );
    expect(quoteFeesText(z), contains('\$0.50 (10.0%)'));
    expect(quoteFeesText(z), contains('0.00032 ZEC'));

    final c = RouteQuote(
      rail: Rail.cloak,
      amountIn: 1000000000,
      inputMint: null,
      estimatedOut: '0.992 SOL',
      expiresAt: DateTime(2030),
      raw: CloakQuoteData(claimKey: addr(5), publicRecipient: addr(6)),
    );
    expect(quoteFeesText(c), contains('Cloak exit fee 0.008 SOL'));
  });

  group('routing', () {
    test(
      'USDC via Zcash routes the spendable balance and records it',
      () async {
        final p = await profile(Rail.zcash, u1);
        final r = await rig(profiles: [p]);
        r.api.balances[p.key.address] = tokenGasStipend;
        r.api.tokens['${p.key.address}:$usdc'] = 5000000;
        r.zcash.spendableBy[usdc] = 5000000;

        final plan = await r.actions.quotePrivateRoute(Rail.zcash, usdc);
        expect(r.zcash.quotes.single, (
          claimKey: p.key.address,
          mint: usdc,
          amount: 5000000,
          to: u1,
        ));
        final t = await r.actions.executePrivateRoute(plan);
        expect(r.zcash.executed.single.inputMint, usdc);
        expect(t.trackingId, FakeZcashRoute.depositAddress);
        expect(t.status, 'PENDING_DEPOSIT');
        expect(r.history.single.mint, usdc);
        expect(r.history.single.estimatedOut, '0.0034 ZEC');
      },
    );

    test('SOL leaves the USDC gas stipend behind', () async {
      final p = await profile(Rail.zcash, u1);
      final r = await rig(profiles: [p]);
      r.api.tokens['${p.key.address}:$usdc'] = 1;
      r.zcash.spendableBy[null] = 100000000;
      await r.actions.quotePrivateRoute(Rail.zcash, null);
      expect(r.zcash.quotes.single.amount, 100000000 - tokenGasStipend);
    });

    test(
      'Cloak SOL quotes the whole balance; the route keeps its reserve',
      () async {
        final p = await profile(Rail.cloak, addr(6));
        final r = await rig(profiles: [p]);
        r.api.balances[p.key.address] = 50000000;
        final plan = await r.actions.quotePrivateRoute(Rail.cloak, null);
        expect(plan.quote.amountIn, 50000000);
        final t = await r.actions.executePrivateRoute(plan);
        expect(t.trackingId, 'cloakSig');
        expect(t.status, 'PENDING');
      },
    );

    test('devnet builds refuse before starting any route', () async {
      final p = await profile(Rail.zcash, u1);
      final r = await rig(profiles: [p], live: false);
      await expectLater(
        r.actions.quotePrivateRoute(Rail.zcash, null),
        throwsA(
          isA<ActionError>().having(
            (e) => e.message,
            'message',
            contains('mainnet'),
          ),
        ),
      );
      expect(r.zcash.quotes, isEmpty);
    });

    test('a restored profile needs a destination first', () async {
      final p = await profile(Rail.zcash, '');
      final r = await rig(profiles: [p]);
      await expectLater(
        r.actions.quotePrivateRoute(Rail.zcash, null),
        throwsA(isA<ActionError>()),
      );
    });

    test('nothing to route', () async {
      final p = await profile(Rail.zcash, u1);
      final r = await rig(profiles: [p]);
      await expectLater(
        r.actions.quotePrivateRoute(Rail.zcash, usdc),
        throwsA(
          isA<ActionError>().having(
            (e) => e.message,
            'message',
            'Nothing to route yet',
          ),
        ),
      );
    });

    test('Cloak SOL keeps the Cloak token reserve while USDC waits', () async {
      final p = await profile(Rail.cloak, addr(6));
      final r = await rig(profiles: [p]);
      r.api.balances[p.key.address] = 50000000;
      r.api.tokens['${p.key.address}:$usdc'] = 5000000;
      await r.actions.quotePrivateRoute(Rail.cloak, null);
      expect(r.cloak.quoted.single, 50000000 - cloakTokenFeeReserve);
      expect(
        routableAssets(
          Rail.cloak,
          const ClaimFunds(lamports: 50000000, usdc: 5000000),
        ).first.amount,
        40000000,
      );
    });

    test(
      'Cloak USDC with only the program stipend asks for more SOL first',
      () async {
        final p = await profile(Rail.cloak, addr(6));
        final r = await rig(profiles: [p]);
        r.api.balances[p.key.address] = tokenGasStipend;
        r.api.tokens['${p.key.address}:$usdc'] = 5000000;
        await expectLater(
          r.actions.quotePrivateRoute(Rail.cloak, usdc),
          throwsA(
            isA<ActionError>().having(
              (e) => e.message,
              'message',
              allOf(contains('Cloak needs'), contains(p.key.address)),
            ),
          ),
        );
        expect(r.cloak.quoted, isEmpty);
      },
    );

    test('a failed Cloak route is kept and resumed with its amount', () async {
      final p = await profile(Rail.cloak, cloakAddress);
      final r = await rig(profiles: [p]);
      r.api.balances[p.key.address] = 50000000;
      r.cloak.executeFail = const CloakRouteException('relay timeout');
      final plan = await r.actions.quotePrivateRoute(Rail.cloak, null);
      await expectLater(
        r.actions.executePrivateRoute(plan),
        throwsA(isA<CloakRouteException>()),
      );
      final stuck = r.history.single;
      expect(stuck.status, interruptedStatus);
      expect(stuck.amount, 50000000);

      // The deposit landed: the claim key is nearly empty now.
      r.api.balances[p.key.address] = 4000;
      r.cloak.executeFail = null;
      final resume = await r.actions.quotePrivateRoute(Rail.cloak, null);
      expect(resume.resumes, stuck.id);
      expect(r.cloak.quoted.last, 50000000);
      final t = await r.actions.executePrivateRoute(resume);
      expect(r.history.single.id, stuck.id);
      expect(t.trackingId, 'cloakSig');
      expect(t.status, 'PENDING');
    });

    test('an interrupted Cloak route whose funds are still on the key routes '
        'the balance and replaces the record', () async {
      final p = await profile(Rail.cloak, cloakAddress);
      final r = await rig(profiles: [p]);
      await r.c
          .read(transferHistoryProvider.notifier)
          .add(
            const PrivateTransfer(
              id: 'old',
              rail: Rail.cloak,
              mint: null,
              amount: 30000000,
              trackingId: '',
              status: interruptedStatus,
              createdAt: 1,
            ),
          );
      r.api.balances[p.key.address] = 60000000;
      final plan = await r.actions.quotePrivateRoute(Rail.cloak, null);
      expect(r.cloak.quoted.single, 60000000);
      await r.actions.executePrivateRoute(plan);
      expect(r.history.single.id, 'old');
      expect(r.history.single.status, 'PENDING');
    });

    test('a refused Zcash payout leaves no record; an unknown outcome is '
        'tracked', () async {
      final p = await profile(Rail.zcash, u1);
      final r = await rig(profiles: [p]);
      r.zcash.spendableBy[null] = 100000000;
      r.zcash.executeFail = const ZcashRouteException('Claim key lacks SOL');
      var plan = await r.actions.quotePrivateRoute(Rail.zcash, null);
      await expectLater(
        r.actions.executePrivateRoute(plan),
        throwsA(isA<ZcashRouteException>()),
      );
      expect(r.history, isEmpty);

      r.zcash.executeFail = http.ClientException('connection reset');
      plan = await r.actions.quotePrivateRoute(Rail.zcash, null);
      await expectLater(
        r.actions.executePrivateRoute(plan),
        throwsA(isA<http.ClientException>()),
      );
      expect(r.history.single.status, 'PENDING_DEPOSIT');
      expect(r.history.single.trackingId, FakeZcashRoute.depositAddress);
    });

    test('a second send while one is still sending is refused', () async {
      final p = await profile(Rail.zcash, u1);
      final r = await rig(profiles: [p]);
      r.zcash.spendableBy[null] = 100000000;
      final plan = await r.actions.quotePrivateRoute(Rail.zcash, null);
      await r.c
          .read(transferHistoryProvider.notifier)
          .add(
            const PrivateTransfer(
              id: 'busy',
              rail: Rail.zcash,
              mint: null,
              amount: 1,
              trackingId: 'x',
              status: sendingStatus,
              createdAt: 1,
            ),
          );
      await expectLater(
        r.actions.executePrivateRoute(plan),
        throwsA(isA<ActionError>()),
      );
      expect(r.zcash.executed, isEmpty);
    });

    test('a failed biometric check sends nothing', () async {
      final p = await profile(Rail.zcash, u1);
      final r = await rig(profiles: [p], biometric: false);
      r.zcash.spendableBy[null] = 100000000;
      final plan = await r.actions.quotePrivateRoute(Rail.zcash, null);
      await expectLater(
        r.actions.executePrivateRoute(plan),
        throwsA(isA<ActionError>()),
      );
      expect(r.zcash.executed, isEmpty);
      expect(r.history, isEmpty);
    });
  });

  group('destinations', () {
    Future<String> save(Rail rail, String d) async {
      final r = await rig();
      final saved = await r.actions.saveClaimProfile(rail, d);
      return saved.profile.destination;
    }

    Matcher refused(String text) => throwsA(
      isA<ActionError>().having((e) => e.message, 'message', contains(text)),
    );

    test('Zcash needs a valid shielded-only unified address', () async {
      expect(await save(Rail.zcash, ' $u1 '), u1);
      expect(await save(Rail.zcash, u1.toUpperCase()), u1);
      await expectLater(save(Rail.zcash, '${u1}x'), refused('unified'));
      await expectLater(
        save(Rail.zcash, 't1Rv4exT7bqhZqi2j7xz8bUHDMxwosrjADU'),
        refused('unified'),
      );
      await expectLater(
        save(
          Rail.zcash,
          'u1snf9yr883aj2hm8pksp9aymnqdwzy42rpzuffevj35hhxeckays5pcpeq7vy2mtgzlcuc4mnh9443qnuyje0yx6h59angywka4v2ap6kchh2j96ezf9w0c0auyz3wwts2lx5gmk2sk9',
        ),
        refused('transparent receiver'),
      );
    });

    test('Cloak needs a Solana or cloak: address', () async {
      expect(await save(Rail.cloak, addr(6)), addr(6));
      expect(await save(Rail.cloak, cloakAddress), cloakAddress);
      await expectLater(save(Rail.cloak, 'cloak:abc'), refused('cloak:'));
      await expectLater(save(Rail.cloak, 'not an address'), refused('Solana'));
    });

    test(
      "this phone's own Cloak address is derived from the claim key",
      () async {
        final r = await rig();
        final saved = await r.actions.useOwnCloakAddress();
        expect(saved.profile.rail, Rail.cloak);
        expect(saved.profile.destination, FakeCloakRoute.ownAddress);
      },
    );
  });

  group('shielded inbox', () {
    test(
      'scans with the Cloak claim key and withdraws to the wallet',
      () async {
        final p = await profile(Rail.cloak, cloakAddress);
        final r = await rig(profiles: [p]);
        r.cloak.notes = [note(400000000), note(100000000)];
        final notes = await r.actions.scanShieldedInbox();
        expect(notes, hasLength(2));
        final t = await r.actions.withdrawShielded(notes);
        expect(r.cloak.withdrawals.single.destination, addr(1));
        expect(t.kind, TransferKind.withdraw);
        expect(t.amount, 500000000);
        expect(t.trackingId, 'withdrawSig');
        expect(r.history.single.kind, TransferKind.withdraw);
      },
    );

    test("refuses another wallet's cloak: address", () async {
      final p = await profile(Rail.cloak, 'cloak:${'3' * 64}:${'4' * 64}');
      final r = await rig(profiles: [p]);
      await expectLater(
        r.actions.scanShieldedInbox(),
        throwsA(
          isA<ActionError>().having(
            (e) => e.message,
            'message',
            contains('another wallet'),
          ),
        ),
      );
      expect(r.cloak.scans, 0);
    });

    test('needs a cloak: address profile', () async {
      final p = await profile(Rail.cloak, addr(6));
      final r = await rig(profiles: [p]);
      await expectLater(
        r.actions.scanShieldedInbox(),
        throwsA(isA<ActionError>()),
      );
    });

    test('looks empty under duress', () async {
      final p = await profile(Rail.cloak, cloakAddress);
      final r = await rig(profiles: [p]);
      r.cloak.notes = [note(1)];
      r.c.read(sessionProvider.notifier).unlock(duress: true);
      expect(await r.actions.scanShieldedInbox(), isEmpty);
      expect(r.cloak.scans, 0);
    });
  });

  group('rails check', () {
    test('reports prover timings', () async {
      final r = await rig(live: false);
      expect(
        await r.c.read(railsCheckProvider).cloak(),
        'Proving files 1200 ms · proof 5600 ms · total 6900 ms',
      );
    });

    test('dry-quotes the beneficiary u1, or a sample address', () async {
      final mine = 'u1${'q' * 100}';
      final p = await profile(Rail.zcash, mine);
      final r = await rig(profiles: [p], live: false);
      expect(await r.c.read(railsCheckProvider).zcash(), contains('your u1'));
      expect(r.zcash.estimates.single.to, mine);
      expect(r.zcash.estimates.single.claimKey, p.key.address);
      expect(r.zcash.quotes, isEmpty);

      final none = await rig(live: false);
      expect(
        await none.c.read(railsCheckProvider).zcash(),
        contains('a sample u1'),
      );
      expect(none.zcash.estimates.single.to, sampleZcashAddress);
    });

    test('a failure surfaces', () async {
      final r = await rig();
      r.cloak.fail = Exception('wasm failed');
      await expectLater(r.c.read(railsCheckProvider).cloak(), throwsException);
    });
  });
}
