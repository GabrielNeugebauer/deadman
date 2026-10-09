import 'dart:typed_data';

import 'package:deadman/solana/deadman_api.dart';
import 'package:deadman/state/actions.dart';
import 'package:deadman/state/decoy_wallet.dart';
import 'package:deadman/state/lockdown_retry.dart';
import 'package:deadman/state/providers.dart';
import 'package:deadman/state/secure_store.dart';
import 'package:deadman/ui/format.dart';
import 'package:deadman/ui/screens/plans_screen.dart';
import 'package:deadman/ui/screens/settings_tab.dart';
import 'package:deadman/ui/theme.dart';
import 'package:deadman/wallet/wallet_bridge.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../state/fakes.dart';

/// The chain: public reads only; anything else is recorded and fails.
class _Chain implements DeadmanApi {
  final calls = <Symbol>[];

  @override
  String? feeToken;

  @override
  Future<FeeSchedule> fetchFees() async =>
      FeeSchedule(treasury: addr(9), feeBpsPublic: 200, feeBpsPrivate: 200);

  @override
  dynamic noSuchMethod(Invocation invocation) {
    calls.add(invocation.memberName);
    throw StateError('chain call under duress: ${invocation.memberName}');
  }
}

class _Wallet implements WalletBridge {
  var calls = 0;

  @override
  Future<WalletSession> authorize() async {
    calls++;
    throw StateError('wallet under duress');
  }

  @override
  Future<List<Uint8List>> signTransactions(List<Uint8List> txs) async {
    calls++;
    throw StateError('wallet under duress');
  }

  @override
  Future<void> deauthorize(String authToken) async {}
}

/// Real receiving profiles, which must stay hidden.
class _Store extends FakeSecureStore {
  _Store(super.profiles);

  @override
  Future<bool> hasPins() async => true;
}

Future<(_Chain, _Wallet)> _pump(WidgetTester tester, Widget home) async {
  tester.view.physicalSize = const Size(900, 3600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues({'owner': addr(1)});
  final prefs = await SharedPreferences.getInstance();
  final chain = _Chain();
  final wallet = _Wallet();
  final real = ClaimProfile(
    rail: Rail.cloak,
    key: await keyPair(5),
    destination: addr(60),
  );
  final container = ProviderContainer(
    overrides: [
      prefsProvider.overrideWithValue(prefs),
      isWebProvider.overrideWithValue(false),
      apiProvider.overrideWithValue(chain),
      walletProvider.overrideWithValue(wallet),
      secureStoreProvider.overrideWithValue(_Store([real])),
      biometricProvider.overrideWithValue((_) async => true),
      decoyLatencyProvider.overrideWithValue(Duration.zero),
      boneyHostProvider.overrideWithValue(null),
      paymasterAvailableProvider.overrideWithValue(false),
      lockdownRetrierProvider.overrideWithValue(
        LockdownRetrier(pending: PendingLockdown(prefs), attempt: (_) async {}),
      ),
    ],
  );
  addTearDown(container.dispose);
  // Opened with the duress PIN: nothing has been read for the real wallet.
  container.read(sessionProvider.notifier).unlock(duress: true);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(),
        home: Scaffold(body: home),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (chain, wallet);
}

void main() {
  testWidgets('Security under duress: the decoy wallet and guard, no real '
      'address or receiving profile', (tester) async {
    final (chain, wallet) = await _pump(tester, const SettingsTab());
    expect(find.textContaining(short(addr(1))), findsNothing);
    expect(find.textContaining(short(decoyOwnerOf(addr(1)))), findsWidgets);
    expect(find.textContaining(short(addr(60))), findsNothing);
    final realKey = (await keyPair(5)).address;
    expect(find.textContaining(short(realKey)), findsNothing);
    expect(chain.calls, isEmpty);
    expect(wallet.calls, 0);
  });

  testWidgets('Plans under duress: plausible plans; a withdrawal goes '
      'through without a transaction, and says it was free', (tester) async {
    final (chain, wallet) = await _pump(tester, const PlansScreen());
    expect(find.text('Family'), findsOneWidget);
    expect(find.text('LOCKED'), findsNothing);
    await tester.tap(find.text('Family'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(OutlinedButton, 'Withdraw').first);
    await tester.pumpAndSettle();
    expect(
      find.text(
        'Withdrawals are free: Deadman takes no fee, only the network fee '
        'applies.',
      ),
      findsOneWidget,
    );
    await tester.enterText(find.byType(TextField), '0.01');
    await tester.tap(find.text('Confirm'));
    await tester.pumpAndSettle();
    expect(find.text('Withdrew 0.010 SOL'), findsOneWidget);
    expect(find.byIcon(Icons.error_outline), findsNothing);
    expect(chain.calls, isEmpty);
    expect(wallet.calls, 0);
  });
}
