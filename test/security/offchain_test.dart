// Off-chain re-check of the 10-05 Medium findings (M-1..M-4) and of the
// new decoy-wallet duress mode and Jupiter token picker.
//
// Tests that show a defect assert the correct behaviour and are skipped so
// the default suite stays green. Run them with:
//   flutter test test/security/offchain_test.dart --run-skipped
import 'dart:io';
import 'dart:typed_data';

import 'package:deadman/core/config.dart';
import 'package:deadman/rails/rails.dart';
import 'package:deadman/rails/zcash_route.dart';
import 'package:deadman/solana/codec.dart'
    show Disc, deadmanIx, tokenProgramId, vaultAccountSize, vaultPda;
import 'package:deadman/solana/deadman_api.dart';
import 'package:deadman/state/actions.dart';
import 'package:deadman/state/assets.dart';
import 'package:deadman/state/lockdown_retry.dart';
import 'package:deadman/state/private_rails.dart';
import 'package:deadman/state/providers.dart';
import 'package:deadman/state/secure_store.dart';
import 'package:deadman/state/secure_store_web.dart';
import 'package:deadman/state/token_list.dart';
import 'package:deadman/ui/screens/settings_tab.dart';
import 'package:deadman/wallet/wallet_bridge.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:solana/encoder.dart';
import 'package:solana/solana.dart';

import '../../tool/keeper.dart' as keeper;
import '../../tool/kora_gateway.dart' as gw;
import '../solana/helpers.dart';
import '../state/fakes.dart' show addr;
import 'memory_web_secret_backend.dart';

const _pin = '111111';
const _duressPin = '222222';

/// Any chain call fails: these tests never reach the network.
class _NoChain implements DeadmanApi {
  @override
  String? feeToken;

  @override
  dynamic noSuchMethod(Invocation i) =>
      throw StateError('chain call: ${i.memberName}');
}

class _NoWallet implements WalletBridge {
  @override
  dynamic noSuchMethod(Invocation i) =>
      throw StateError('wallet call: ${i.memberName}');
}

/// 1Click stand-in for the rails check: records the claim key it is given.
class _Zcash implements ZcashRoute {
  final claimKeys = <String>[];

  @override
  Future<RouteQuote> estimate({
    required String claimKey,
    required String? inputMint,
    required int amount,
    required String destination,
  }) async {
    claimKeys.add(claimKey);
    return RouteQuote(
      rail: Rail.zcash,
      amountIn: amount,
      inputMint: inputMint,
      estimatedOut: '0.1 ZEC',
      expiresAt: DateTime.now().add(const Duration(minutes: 5)),
    );
  }

  @override
  dynamic noSuchMethod(Invocation i) =>
      throw StateError('1Click call: ${i.memberName}');
}

/// The real SessionController, SecureStore (mock platform storage) and
/// VaultActions, with every network edge stubbed.
Future<({ProviderContainer c, SecureStore store, _Zcash zcash})> _rig({
  bool web = false,
}) async {
  SharedPreferences.setMockInitialValues({'owner': addr(1)});
  FlutterSecureStorage.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final store = SecureStore();
  final zcash = _Zcash();
  final c = ProviderContainer(
    overrides: [
      prefsProvider.overrideWithValue(prefs),
      apiProvider.overrideWithValue(_NoChain()),
      walletProvider.overrideWithValue(_NoWallet()),
      secureStoreProvider.overrideWithValue(store),
      isWebProvider.overrideWithValue(web),
      if (!web) biometricProvider.overrideWithValue((_) async => true),
      decoyLatencyProvider.overrideWithValue(Duration.zero),
      boneyHostProvider.overrideWithValue(null),
      privateRailsLiveProvider.overrideWithValue(false),
      railsCheckZcashProvider.overrideWithValue(zcash),
      lockdownRetrierProvider.overrideWithValue(
        LockdownRetrier(pending: PendingLockdown(prefs), attempt: (_) async {}),
      ),
    ],
  );
  addTearDown(c.dispose);
  return (c: c, store: store, zcash: zcash);
}

/// A device that set up PINs, a guard key and a Cloak + Zcash receiving
/// profile (which creates the recovery phrase).
Future<String> _setUpDevice(SecureStore store) async {
  await store.setPins(pin: _pin, duressPin: _duressPin);
  await store.createGuard();
  await store.saveClaim(Rail.cloak, addr(5));
  await store.saveClaim(Rail.zcash, sampleZcashAddress);
  return (await store.loadPhrase())!;
}

Instruction _ix(String signer, String owner, int planId, List<int> disc) =>
    deadmanIx([
      AccountMeta.readonly(
        pubKey: Ed25519HDPublicKey.fromBase58(signer),
        isSigner: true,
      ),
      AccountMeta.writeable(
        pubKey: Ed25519HDPublicKey.fromBase58(vaultPda(owner, planId).address),
        isSigner: false,
      ),
    ], disc);

/// A guard-signed sponsor transaction, Kora's fee-payer slot left zeroed.
Future<Uint8List> _wire(
  String kora,
  Ed25519HDKeyPair guard,
  Instruction ix,
) async {
  final compiled = Message(instructions: [ix]).compile(
    recentBlockhash: key(9),
    feePayer: Ed25519HDPublicKey.fromBase58(kora),
  );
  final bytes = compiled.toByteArray().toList();
  final sigs = <Signature>[];
  for (final k in compiled.accountKeys.take(compiled.requiredSignatureCount)) {
    sigs.add(
      k == guard.publicKey
          ? await guard.sign(bytes)
          : Signature(List.filled(64, 0), publicKey: k),
    );
  }
  return Uint8List.fromList(
    SignedTx(
      compiledMessage: compiled,
      signatures: sigs,
    ).toByteArray().toList(),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('M-1 Forget this device under duress', () {
    test('fixed (M-1, OFF-N3): reset under duress deletes nothing and '
        'lands on Welcome; the duress PIN still opens the decoy, never the '
        'real phrase', () async {
      final r = await _rig();
      final phrase = await _setUpDevice(r.store);
      final prefs = r.c.read(prefsProvider);
      final session = r.c.read(sessionProvider.notifier);
      expect(await r.store.checkPin(_duressPin), PinCheck.duress);
      session.unlock(duress: true);

      await expectLater(
        r.c.read(actionsProvider).revealRecoveryPhrase(),
        throwsA(isA<ActionError>()),
      );

      await session.reset(deleteReceivingKeys: true);
      final s = r.c.read(sessionProvider);
      expect(s.unlocked, isFalse);
      expect(s.owner, isNull, reason: 'Welcome, as after a real reset');
      expect(s.realOwner, isNull);
      expect(s.duress, isTrue, reason: 'still faked until a PIN');
      expect(r.c.read(decoyWalletProvider), isNull);
      expect(prefs.getString('owner'), addr(1), reason: 'nothing deleted');
      expect(await r.store.hasPins(), isTrue);
      expect(await r.store.loadGuard(), isNotNull);
      expect(await r.store.loadPhrase(), phrase);
      expect(await r.store.loadClaims(), hasLength(2));

      // Reconnecting reaches the PIN gate; the duress PIN still opens the
      // decoy.
      await session.setOwner(addr(1));
      expect(r.c.read(sessionProvider).unlocked, isFalse);
      expect(await r.store.checkPin(_duressPin), PinCheck.duress);
      session.unlock(duress: true);
      String? shown;
      try {
        shown = await r.c.read(actionsProvider).revealRecoveryPhrase();
      } on ActionError {
        shown = null;
      }
      expect(shown, isNot(phrase));
    });

    test('OFF-N2: the Private rails check reads the real Zcash receiving '
        'profile under duress', () async {
      final r = await _rig();
      await _setUpDevice(r.store);
      final real = (await r.store.loadClaim(Rail.zcash))!;
      r.c.read(sessionProvider.notifier).unlock(duress: true);
      // The decoy shows no receiving profile...
      expect(await r.c.read(claimProfilesProvider.future), isEmpty);

      final text = await r.c.read(railsCheckProvider).zcash();

      // ...so the rails check must not use (or reveal) the real one.
      expect(r.zcash.claimKeys.single, isNot(real.key.address));
      expect(text, contains('a sample u1 address'));
    });

    test('OFF-N2: under duress the rails check uses the decoy\'s own Zcash '
        'profile once the coercer sets one up', () async {
      final r = await _rig();
      await _setUpDevice(r.store);
      final real = (await r.store.loadClaim(Rail.zcash))!;
      r.c.read(sessionProvider.notifier).unlock(duress: true);
      final fake = await r.c
          .read(decoyWalletProvider)!
          .saveClaim(Rail.zcash, sampleZcashAddress);

      final text = await r.c.read(railsCheckProvider).zcash();

      expect(r.zcash.claimKeys.single, fake.key.address);
      expect(r.zcash.claimKeys.single, isNot(real.key.address));
      expect(text, contains('your u1 address'));
    });

    test('OFF-N2 control: outside duress the rails check uses the real '
        'profile', () async {
      final r = await _rig();
      await _setUpDevice(r.store);
      final real = (await r.store.loadClaim(Rail.zcash))!;
      r.c.read(sessionProvider.notifier).unlock(duress: false);

      final text = await r.c.read(railsCheckProvider).zcash();

      expect(r.zcash.claimKeys.single, real.key.address);
      expect(text, contains('your u1 address'));
    });

    testWidgets('OFF-N3: Forget this device under duress asks about the '
        'decoy\'s receiving keys only and ends on Welcome', (tester) async {
      final r = await tester.runAsync(_rig);
      final phrase = await tester.runAsync(() => _setUpDevice(r!.store));
      final c = r!.c;
      tester.view.physicalSize = const Size(800, 6000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      c.read(sessionProvider.notifier).unlock(duress: true);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(
            home: Consumer(
              builder: (context, ref, _) =>
                  ref.watch(sessionProvider.select((s) => s.owner)) == null
                  ? const Text('Welcome')
                  : const Scaffold(body: SettingsTab()),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      Future<void> tap(Finder f) async {
        await tester.ensureVisible(f);
        await tester.tap(f);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
      }

      await tap(find.text('Forget this device'));
      expect(find.text('Forget this device?'), findsOneWidget);
      await tap(find.widgetWithText(TextButton, 'Forget'));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // The real phone holds receiving keys; the decoy has none, so the
      // second step never shows.
      expect(find.text('Keep receiving keys?'), findsNothing);
      expect(find.text('Welcome'), findsOneWidget);
      final s = c.read(sessionProvider);
      expect(s.owner, isNull);
      expect(s.duress, isTrue);
      await tester.runAsync(() async {
        expect(await r.store.hasPins(), isTrue);
        expect(await r.store.loadGuard(), isNotNull);
        expect(await r.store.loadPhrase(), phrase);
        expect(await r.store.loadClaims(), hasLength(2));
      });
    });
  });

  group('M-2 web key storage', () {
    test('the web build keeps receiving keys and the phrase behind the PIN, '
        'not next to their AES key in localStorage', () async {
      FlutterSecureStorage.setMockInitialValues({});
      final idb = MemoryWebSecretBackend();
      SecureStore page() =>
          SecureStore(null, WebSecrets(backend: idb, iterations: 1000));
      final phrase = await _setUpDevice(page());
      expect(await const FlutterSecureStorage().readAll(), isEmpty);

      // A reload, or a copy of the browser profile, opens nothing.
      final reloaded = page();
      await expectLater(reloaded.loadPhrase(), throwsStateError);
      await expectLater(reloaded.loadGuard(), throwsStateError);
      expect(await reloaded.checkPin(_duressPin), PinCheck.duress);
      expect(await reloaded.loadPhrase(), isNull);
      expect(await reloaded.loadClaims(), isEmpty);
      expect(await reloaded.checkPin(_pin), PinCheck.normal);
      expect(await reloaded.loadPhrase(), phrase);
    });

    test('web/index.html sets a Content-Security-Policy', () {
      final html = File('web/index.html').readAsStringSync();
      expect(html, contains('Content-Security-Policy'));
      expect(html, contains("object-src 'none'"));
      expect(html, isNot(contains("'unsafe-eval'")));
    });
  });

  group('M-3 sponsor global quota', () {
    test(
      'Sybil pulses cannot use up the budget a duress lockdown needs',
      () async {
        final kora = key(1);
        final policy = gw.SponsorPolicy(koraPayer: kora);
        // Genuine vaults of [owner] guarded by [guard], each with a pending
        // 1 SOL tier and 1 SOL above its rent.
        final chain = <String, gw.VaultAccount>{};
        gw.VaultAccount vault(String owner, String guard) => (
          owner: AppConfig.programId,
          data: Uint8List.fromList(
            vaultBytes(
              owner: owner,
              guard: guard,
              rules: [
                RuleState(
                  beneficiary: key(90),
                  rail: Rail.solana,
                  afterSecs: 3600,
                  mode: AmountMode.fixed,
                  amount: 1000000000,
                  executedAt: 0,
                  paid: 0,
                ),
              ],
            ),
          ),
          lamports: gw.rentExemptLamports(vaultAccountSize) + 1000000000,
        );
        final route = gw.SponsorRoute(
          policy: policy,
          limiter: gw.UsageLimiter(global: 5),
          fetchAccounts: (vaults) async => [for (final v in vaults) chain[v]],
        );

        // Five attacker guards, each on a vault of its own, pulse once.
        for (var i = 0; i < 5; i++) {
          final sybil = await Ed25519HDKeyPair.fromPrivateKeyBytes(
            privateKey: List.filled(32, 40 + i),
          );
          final owner = key(60 + i);
          chain[vaultPda(owner, 0).address] = vault(owner, sybil.address);
          await route.admit(
            await _wire(kora, sybil, _ix(sybil.address, owner, 0, Disc.pulse)),
          );
        }

        // A victim's guard sends its duress lockdown.
        final victim = await Ed25519HDKeyPair.fromPrivateKeyBytes(
          privateKey: List.filled(32, 77),
        );
        final owner = key(70);
        chain[vaultPda(owner, 0).address] = vault(owner, victim.address);
        final lockdown = await _wire(
          kora,
          victim,
          _ix(victim.address, owner, 0, Disc.lockdown),
        );
        await expectLater(route.admit(lockdown), completes);
      },
    );
  });

  group('M-4 keeper dust releases', () {
    final schedule = RuleSpec(
      beneficiary: addr(3),
      rail: Rail.solana,
      afterSecs: 0,
      mode: AmountMode.fixed,
      amount: 10512000,
    );
    const now = 1800000000;

    test('a 1-lamport installment is not released again a minute later', () {
      expect(
        keeper.vestingReleaseDue(
          claimable: 1,
          fullyVested: false,
          now: now,
          interval: 86400,
          lastRelease: now - 60,
        ),
        isFalse,
      );
    });

    test('the keeper does not pay 5000+ lamports to move 1 lamport', () {
      final d = keeper.decideSol(
        keeper.vestingAsTier(schedule, 1),
        const keeper.SolFacts(
          available: 5000000,
          feeBps: 200,
          beneficiaryLamports: 1000000000,
          beneficiaryRentMin: 890880,
          treasuryLamports: 1000000000,
          treasuryRentMin: 890880,
        ),
        canSkip: false,
      );
      expect(d.action, isNot(keeper.KeeperAction.execute));
    });

    test(
      'a token picked from Jupiter (no --price) is not released as dust',
      () {
        final d = keeper.decideToken(
          keeper.vestingAsTier(
            RuleSpec(
              beneficiary: addr(3),
              rail: Rail.solana,
              afterSecs: 0,
              mode: AmountMode.fixed,
              amount: 1000000,
              mint: addr(30),
            ),
            1,
          ),
          addr(9),
          const keeper.TokenFacts(
            classicMint: true,
            vaultBalance: 1000000,
            feeBps: 200,
            beneficiaryAta: keeper.AtaStatus.usable,
            treasuryAta: keeper.AtaStatus.usable,
            ataRent: 2039280,
          ),
          canSkip: false,
        );
        expect(d.action, isNot(keeper.KeeperAction.execute));
      },
    );
  });

  group('Jupiter token picker', () {
    tearDown(() {
      forgetTokens();
      forgetNfts();
    });

    test('OFF-N1: a homoglyph or zero-width USDC symbol is marked as a '
        'lookalike', () {
      const cyrillic = 'USDС'; // Cyrillic Es
      const zeroWidth = 'USDC​';
      expect(isLookalike(addr(31), cyrillic), isTrue);
      expect(isLookalike(addr(32), zeroWidth), isTrue);
      expect(rememberToken(addr(31), cyrillic, 6).symbol, contains('·'));
      expect(rememberToken(addr(32), zeroWidth, 6).symbol, contains('·'));
    });

    test('OFF-N1: other disguises of a preset symbol are lookalikes', () {
      const disguises = {
        'ＵＳＤＣ': 'USDC', // full-width
        '𝐔𝐒𝐃𝐂': 'USDC', // mathematical bold
        'ⓊⓈⒹⒸ': 'USDC', // circled
        'USDĆ': 'USDC', // precomposed accent
        'USDC\u0301': 'USDC', // combining accent
        'U\u00A0S\u2009D C': 'USDC', // spaces
        'U\u2060SDC\uFEFF': 'USDC', // word joiner, BOM
        '\u202EUSDC': 'USDC', // bidi override
        'ꓴꓢꓓꓚ': 'USDC', // Lisu
        'ЅОL': 'SOL', // Cyrillic Dze, O
        'ѕοl': 'SOL', // lower-case Cyrillic and Greek
        'ꜱᴋʀ': 'SKR', // small capitals
        'ᏚᏦᏒ': 'SKR', // Cherokee
        'ΟRΕ': 'ORE', // Greek Omicron, Epsilon
        'JіtoЅOL': 'JitoSOL',
      };
      for (final MapEntry(key: s, value: real) in disguises.entries) {
        expect(lookalikeOf(addr(34), s)?.symbol, real, reason: s);
        expect(rememberToken(addr(34), s, 6).symbol, contains('·'), reason: s);
      }
    });

    test('OFF-N1: distinct symbols and the real mints are not lookalikes', () {
      for (final s in ['USDT', 'JUP', 'BONK', 'USDCX', 'SOLX', 'Ѕ', 'ДС']) {
        expect(isLookalike(addr(35), s), isFalse, reason: s);
      }
      expect(isLookalike(AppConfig.usdcMint, 'USDС'), isFalse);
      expect(isLookalike(AppConfig.skrMint, 'ꜱᴋʀ'), isFalse);
      expect(rememberToken(addr(35), 'JUP', 6).symbol, 'JUP');
    });

    test('OFF-N1: invisible characters never reach the label', () {
      final info = rememberToken(addr(36), 'AB\u202EC\u200BD', 6);
      expect(info.symbol, 'ABCD');
      expect(displaySymbol(' \u2066X\u2069 '), 'X');
      expect(rememberToken(addr(37), '\u200B', 6).symbol, isNot(contains('·')));
    });

    test('OFF-N1: an NFT named like a preset token keeps its mint', () {
      expect(rememberNft(addr(38), 'USDС').symbol, contains('·'));
      expect(amountText(1, addr(38)), isNot('USDC'));
      expect(rememberNft(addr(39), 'Mad Lad #1').symbol, 'Mad Lad #1');
    });

    test('OFF-N1: an unverified or flagged listed token keeps its mint, '
        'also after a restart', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      ListedToken listed(
        String mint, {
        bool verified = true,
        bool sus = false,
      }) => ListedToken(
        mint: mint,
        symbol: 'FOO',
        name: 'Foo',
        decimals: 6,
        tokenProgram: tokenProgramId,
        verified: verified,
        suspicious: sus,
      );
      rememberListedToken(prefs, listed(addr(40)));
      rememberListedToken(prefs, listed(addr(41), verified: false));
      rememberListedToken(prefs, listed(addr(42), sus: true));
      expect(assetSymbol(addr(40)), 'FOO');
      expect(assetSymbol(addr(41)), 'FOO·${addr(41).substring(0, 4)}');
      expect(assetSymbol(addr(42)), 'FOO·${addr(42).substring(0, 4)}');

      forgetTokens();
      restoreListedTokens(prefs);
      expect(assetSymbol(addr(40)), 'FOO');
      expect(assetSymbol(addr(41)), contains('·'));
      expect(assetSymbol(addr(42)), contains('·'));
    });

    test('a plain-ASCII lookalike is still caught', () {
      expect(rememberToken(addr(33), ' usdc ', 6).symbol, startsWith('usdc·'));
    });
  });
}
