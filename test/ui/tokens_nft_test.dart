import 'dart:typed_data';

import 'package:deadman/core/config.dart';
import 'package:deadman/solana/deadman_api.dart';
import 'package:deadman/state/actions.dart';
import 'package:deadman/state/assets.dart';
import 'package:deadman/state/providers.dart';
import 'package:deadman/ui/screens/plans/plan_card_shell.dart';
import 'package:deadman/ui/screens/plans_screen.dart';
import 'package:deadman/ui/screens/rules_editor.dart';
import 'package:deadman/ui/theme.dart';
import 'package:deadman/ui/widgets/nft.dart';
import 'package:deadman/wallet/wallet_bridge.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../state/fakes.dart';

const skr = AppConfig.skrMint;
const ore = AppConfig.oreMint;
const usdc = AppConfig.usdcMint;
final owner = addr(1);
final classic = WalletNft(
  mint: addr(81),
  name: 'Saga Genesis #7',
  symbol: 'SAGA',
  imageUrl: 'https://example.com/7.png',
);
final pnft = WalletNft(
  mint: addr(82),
  name: 'Locked Lad',
  symbol: 'LAD',
  programmable: true,
);

class _Api extends FakeApi {
  _Api() : super(const []);

  final sent = <Uint8List>[];

  @override
  Future<List<String>> sendSigned(List<Uint8List> signed) async {
    sent.addAll(signed);
    return ['sig'];
  }
}

class _EchoWallet implements WalletBridge {
  @override
  Future<WalletSession> authorize() => throw UnimplementedError();

  @override
  Future<List<Uint8List>> signTransactions(List<Uint8List> txs) async => txs;

  @override
  Future<void> deauthorize(String authToken) async {}
}

int _now() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

final _fees = FeeSchedule(
  treasury: addr(9),
  feeBpsPublic: 200,
  feeBpsPrivate: 300,
  skrMint: skr,
  feeBpsSkr: 150,
  skrBurnBps: 1000,
);

Future<SharedPreferences> _prefs() async {
  SharedPreferences.setMockInitialValues({'owner': owner});
  return SharedPreferences.getInstance();
}

void _bigView(WidgetTester tester) {
  tester.view.physicalSize = const Size(1200, 6000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

/// Records what the plan editor would create.
class _Actions extends VaultActions {
  _Actions(super.ref, this.created);

  final List<(List<RuleSpec>, Map<String, int>)> created;

  @override
  Future<List<VaultState>> createVault({
    required String label,
    required List<RuleSpec> rules,
    required int lockSecs,
    required int skipGraceSecs,
    required int depositLamports,
    Map<String, int> tokenDeposits = const {},
  }) async {
    created.add((rules, tokenDeposits));
    return const [];
  }
}

Future<void> _scrollTo(WidgetTester tester, Finder f) async {
  await tester.scrollUntilVisible(
    f,
    200,
    scrollable: find
        .byWidgetPredicate(
          (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
        )
        .first,
  );
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, String text) async {
  await _scrollTo(tester, find.text(text).first);
  await tester.tap(find.text(text).first);
  await tester.pumpAndSettle();
}

void main() {
  setUp(forgetNfts);
  tearDown(forgetNfts);

  group('plans screen', () {
    Future<_Api> pump(WidgetTester tester, VaultState plan) async {
      _bigView(tester);
      final prefs = await _prefs();
      final api = _Api()..walletNfts = [classic, pnft];
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            prefsProvider.overrideWithValue(prefs),
            apiProvider.overrideWithValue(api),
            walletProvider.overrideWithValue(_EchoWallet()),
            vaultsProvider.overrideWith((ref) async => [plan]),
            legacyPlansProvider.overrideWith((ref) async => const []),
            guardAddressProvider.overrideWith((ref) async => addr(2)),
            planUsdcProvider.overrideWith((ref, address) async => 0),
            planTokenBalancesProvider.overrideWith(
              (ref) async => {
                plan.address: {
                  classic.mint: 1,
                  skr: 1200000000,
                  ore: 150000000000,
                },
              },
            ),
            walletTokenProvider.overrideWith((ref, mint) async => 7000000),
            feesProvider.overrideWith((ref) async => _fees),
          ],
          child: MaterialApp(theme: buildTheme(), home: const PlansScreen()),
        ),
      );
      await tester.pumpAndSettle();
      final toggle = find.byWidgetPredicate(
        (w) =>
            w is ExpandToggle &&
            !w.open &&
            w.key is ValueKey<String> &&
            (w.key! as ValueKey<String>).value.startsWith('plan-'),
      );
      await tester.tap(toggle.first);
      await tester.pumpAndSettle();
      return api;
    }

    VaultState plan() {
      final now = _now();
      return vault(
        guard: addr(2),
        lastPulse: now,
        ownerLastSeen: now,
        withdrawableLamports: 500000000,
        rules: [
          rule(seed: 11, mint: classic.mint, mode: AmountMode.fixed, amount: 1),
          rule(seed: 12, mint: skr, afterSecs: 20 * 86400),
        ],
      );
    }

    testWidgets('an NFT tier shows its name and thumbnail; SKR and ORE '
        'holdings read in mono', (tester) async {
      await pump(tester, plan());

      final summary = find.textContaining('protected');
      expect(
        tester.widget<Text>(summary).data,
        '0.500 SOL · 0 USDC · 1200 SKR · 1.5 ORE · Saga Genesis #7 protected',
      );
      expect(tester.widget<Text>(summary).style!.fontFamily, contains('Mono'));
      expect(
        find.textContaining('Saga Genesis #7 → ${short4(addr(11))}'),
        findsOneWidget,
      );
      expect(find.textContaining('100% of remaining SKR'), findsOneWidget);
      // The NFT tier pays 2%, the SKR one 1.5% (10% of it burned).
      expect(
        find.text('Release fee: 1.5% / 2% · SKR fees 10% burned'),
        findsOneWidget,
      );
      expect(find.byType(NftImage), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Deposit → NFT: pNFTs are listed but disabled; a classic NFT '
        'goes in whole', (tester) async {
      final api = await pump(tester, plan());
      await tester.tap(find.text('Deposit').first);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('deposit-nft')));
      await tester.pumpAndSettle();

      expect(find.text('Choose an NFT'), findsOneWidget);
      expect(find.textContaining('Programmable NFTs, compressed'), findsOne);
      expect(find.text('Saga Genesis #7'), findsOneWidget);
      expect(find.text('Locked Lad'), findsOneWidget);
      expect(find.text('Programmable NFT: not supported yet'), findsOneWidget);

      await tester.tap(find.text('Locked Lad'));
      await tester.pumpAndSettle();
      expect(find.text('Choose an NFT'), findsOneWidget);
      expect(api.tokenDeposits, isEmpty);

      await tester.tap(find.text('Saga Genesis #7'));
      await tester.pumpAndSettle();
      expect(api.tokenDeposits, [(classic.mint, 1)]);
      expect(find.text('Deposited Saga Genesis #7'), findsOneWidget);
    });

    testWidgets('Deposit SKR in SKR units', (tester) async {
      final api = await pump(tester, plan());
      await tester.tap(find.text('Deposit').first);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ChoiceChip, 'SKR'));
      await tester.pumpAndSettle();
      expect(find.text('7 SKR in your wallet'), findsOneWidget);
      await tester.enterText(find.byType(TextField), '2.5');
      await tester.tap(find.text('Confirm'));
      await tester.pumpAndSettle();
      expect(api.tokenDeposits, [(skr, 2500000)]);
    });
  });

  testWidgets('create: an NFT payout is "Send <name>", funded whole', (
    tester,
  ) async {
    _bigView(tester);
    final prefs = await _prefs();
    final created = <(List<RuleSpec>, Map<String, int>)>[];
    final api = _Api()..walletNfts = [classic, pnft];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          prefsProvider.overrideWithValue(prefs),
          actionsProvider.overrideWith((ref) => _Actions(ref, created)),
          apiProvider.overrideWithValue(api),
          walletTokenProvider.overrideWith(
            (ref, mint) async => mint == classic.mint ? 1 : 12000000,
          ),
          walletBalanceProvider.overrideWith((ref) async => 2000000000),
          feesProvider.overrideWith((ref) async => _fees),
        ],
        child: MaterialApp(
          theme: buildTheme(),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => const RulesEditorPage(),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey('recipient-address')),
      addr(12),
    );
    await tester.enterText(find.byKey(const ValueKey('recipient-name')), 'Ana');
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    for (final label in ['SOL', 'USDC', 'SKR', 'ORE', 'Other token', 'NFT']) {
      expect(find.widgetWithText(ChoiceChip, label), findsOneWidget);
    }
    final chip = find.byKey(const ValueKey('asset-nft'));
    await _scrollTo(tester, chip);
    await tester.tap(chip);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Saga Genesis #7'));
    await tester.pumpAndSettle();

    expect(find.text('Send Saga Genesis #7 to Ana'), findsOneWidget);
    expect(find.byKey(const ValueKey('share-field')), findsNothing);
    expect(find.byKey(const ValueKey('fixed-field')), findsNothing);
    expect(find.widgetWithText(ChoiceChip, 'Saga Genesis #7'), findsOneWidget);
    expect(
      find.textContaining('Sends Saga Genesis #7 to Ana 30 days after'),
      findsOneWidget,
    );

    // Private rails can't carry an NFT.
    await _tap(tester, 'Private (Cloak)');
    expect(find.textContaining('NFTs are sent as a normal transfer'), findsOne);
    await _tap(tester, 'Done');
    expect(find.text('New payout'), findsOneWidget);
    await _tap(tester, 'Normal transfer');

    await _tap(tester, 'Done');
    expect(find.text('The NFT Saga Genesis #7'), findsOneWidget);
    await _tap(tester, 'Next: fund the plan');

    final toggle = find.byType(SwitchListTile);
    expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
    expect(find.text('In your wallet'), findsOneWidget);
    expect(find.text('Payout 1 sends this NFT.'), findsOneWidget);
    expect(find.textContaining('The NFT → sent whole'), findsOneWidget);
    expect(find.text('Some money stays behind'), findsNothing);

    await _tap(tester, 'Next: review');
    expect(
      find.textContaining('Ana gets the NFT Saga Genesis #7 as a normal'),
      findsOneWidget,
    );
    await _tap(tester, 'Create plan');
    final (rules, tokens) = created.single;
    expect(rules.single.mint, classic.mint);
    expect(rules.single.mode, AmountMode.fixed);
    expect(rules.single.amount, 1);
    expect(tokens, {classic.mint: 1});
  });
}

/// The first four characters of [a] (short addresses start with them).
String short4(String a) => a.substring(0, 4);
