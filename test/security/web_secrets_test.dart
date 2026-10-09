// M-2: the web build keeps claim keys, the recovery phrase and the guard
// key wrapped under a PIN-derived key (PBKDF2) inside records sealed by a
// non-extractable WebCrypto key, never next to their key in localStorage.
import 'dart:convert';

import 'package:deadman/rails/rails.dart';
import 'package:deadman/state/lockdown_retry.dart';
import 'package:deadman/state/secure_store.dart';
import 'package:deadman/state/secure_store_web.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../state/fakes.dart' show addr;
import 'memory_web_secret_backend.dart';

const _pin = '111111';
const _duressPin = '222222';
const _zcash = 'u1destination';

/// A browser profile: IndexedDB survives page reloads, the unlocked keys do
/// not.
class _Browser {
  final idb = MemoryWebSecretBackend();

  /// A fresh page load.
  SecureStore page() =>
      SecureStore(null, WebSecrets(backend: idb, iterations: 1000));
}

/// What a page or a disk dump can read without the PIN.
String _dump(MemoryWebSecretBackend idb) =>
    idb.records.values.map(latin1.decode).join('|');

bool _containsBytes(MemoryWebSecretBackend idb, List<int> needle) =>
    idb.records.values.any((v) {
      outer:
      for (var i = 0; i + needle.length <= v.length; i++) {
        for (var j = 0; j < needle.length; j++) {
          if (v[i + j] != needle[j]) continue outer;
        }
        return true;
      }
      return false;
    });

Future<({String phrase, String guard, List<int> guardSk})> _setUp(
  SecureStore store,
) async {
  await store.setPins(pin: _pin, duressPin: _duressPin);
  final guard = await store.createGuard();
  await store.saveClaim(Rail.cloak, addr(5));
  await store.saveClaim(Rail.zcash, _zcash);
  return (
    phrase: (await store.loadPhrase())!,
    guard: guard.address,
    guardSk: (await guard.extract()).bytes,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test('the PBKDF2 used in tests matches RFC 7914', () async {
    final out = await MemoryWebSecretBackend().pbkdf2(
      utf8.encode('password'),
      utf8.encode('salt'),
      1,
    );
    expect(
      out.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
      '120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b',
    );
  });

  test('the default PBKDF2 cost is at least 600k rounds', () {
    expect(WebSecrets.defaultIterations, greaterThanOrEqualTo(600000));
  });

  test('no secret, PIN or PIN hash is stored in the clear', () async {
    final browser = _Browser();
    final store = browser.page();
    final s = await _setUp(store);

    expect(await const FlutterSecureStorage().readAll(), isEmpty);
    final dump = _dump(browser.idb);
    expect(dump, isNot(contains(s.phrase.split(' ').first)));
    expect(dump, isNot(contains(_zcash)));
    expect(dump, isNot(contains(_pin)));
    expect(dump, isNot(contains('pin_hash')));
    expect(_containsBytes(browser.idb, s.guardSk), isFalse);
    final cloak = await store.loadClaim(Rail.cloak);
    final sk = (await cloak!.key.extract()).bytes;
    expect(_containsBytes(browser.idb, sk), isFalse);
    expect(dump, isNot(contains(base64Encode(sk))));
  });

  test('after a reload nothing opens until the PIN is entered', () async {
    final browser = _Browser();
    final s = await _setUp(browser.page());

    final page = browser.page();
    expect(await page.hasPins(), isTrue);
    await expectLater(page.loadGuard(), throwsStateError);
    await expectLater(page.loadPhrase(), throwsStateError);
    await expectLater(page.loadClaims(), throwsStateError);
    await expectLater(page.createGuard(), throwsStateError);

    expect(await page.checkPin('123456'), PinCheck.wrong);
    await expectLater(page.loadPhrase(), throwsStateError);

    expect(await page.checkPin(_pin), PinCheck.normal);
    expect(await page.loadPhrase(), s.phrase);
    expect((await page.loadGuard())!.address, s.guard);
    expect((await page.loadClaim(Rail.zcash))!.destination, _zcash);
    expect(await page.phraseConfirmed(), isFalse);
  });

  test('the duress PIN opens the guard key but no receiving keys', () async {
    final browser = _Browser();
    final s = await _setUp(browser.page());

    final page = browser.page();
    expect(await page.checkPin(_duressPin), PinCheck.duress);
    expect((await page.loadGuard())!.address, s.guard);
    expect(await page.loadPhrase(), isNull);
    expect(await page.loadClaims(), isEmpty);
    expect(await page.hasReceivingKeys(), isFalse);
    await expectLater(page.saveClaim(Rail.cloak, addr(6)), throwsStateError);
    await expectLater(page.wipeDevice(), throwsStateError);

    // A later normal unlock drops nothing.
    expect(await page.checkPin(_pin), PinCheck.normal);
    expect(await page.loadPhrase(), s.phrase);
    // And a duress unlock after a normal one closes the receiving keys.
    expect(await page.checkPin(_duressPin), PinCheck.duress);
    expect(await page.loadPhrase(), isNull);
  });

  test('records cannot be swapped between names', () async {
    final browser = _Browser();
    await _setUp(browser.page());
    final idb = browser.idb.records;
    final cloak = idb['v.claim_cloak']!;
    idb['v.claim_cloak'] = idb['v.claim_zcash']!;
    idb['v.claim_zcash'] = cloak;

    final page = browser.page();
    expect(await page.checkPin(_pin), PinCheck.normal);
    await expectLater(page.loadClaim(Rail.cloak), throwsA(anything));
  });

  test('a tampered PIN slot fails closed', () async {
    final browser = _Browser();
    await _setUp(browser.page());
    final slot = browser.idb.records['slot.pin']!;
    slot[slot.length - 1] ^= 1;

    final page = browser.page();
    expect(await page.checkPin(_pin), PinCheck.wrong);
    expect(await page.checkPin(_duressPin), PinCheck.duress);
  });

  group('migration from flutter_secure_storage_web', () {
    /// What an older web build left in localStorage: the same keys the
    /// Android store writes.
    Future<({Map<String, String> legacy, String phrase, String guard})>
    legacyDevice({bool pins = true}) async {
      final old = SecureStore();
      if (pins) await old.setPins(pin: _pin, duressPin: _duressPin);
      final guard = pins ? (await old.createGuard()).address : '';
      await old.saveClaim(Rail.zcash, _zcash);
      await old.markPhraseConfirmed();
      final legacy = Map.of(await const FlutterSecureStorage().readAll());
      expect(legacy, contains('recovery_phrase'));
      return (legacy: legacy, phrase: (await old.loadPhrase())!, guard: guard);
    }

    test('moves everything behind both PINs on first use', () async {
      final old = await legacyDevice();
      final browser = _Browser();

      final page = browser.page();
      expect(await page.hasPins(), isTrue);
      expect(await const FlutterSecureStorage().readAll(), isEmpty);
      expect(_dump(browser.idb), isNot(contains(old.legacy['pin_hash']!)));
      expect(_dump(browser.idb), isNot(contains(old.legacy['duress_hash']!)));
      expect(_dump(browser.idb), isNot(contains(_zcash)));
      await expectLater(page.loadPhrase(), throwsStateError);

      expect(await page.checkPin('999999'), PinCheck.wrong);
      expect(await page.checkPin(_duressPin), PinCheck.duress);
      expect((await page.loadGuard())!.address, old.guard);
      expect(await page.loadPhrase(), isNull);

      expect(await page.checkPin(_pin), PinCheck.normal);
      expect(await page.loadPhrase(), old.phrase);
      expect(await page.phraseConfirmed(), isTrue);
      expect((await page.loadGuard())!.address, old.guard);
      final zcash = await page.loadClaim(Rail.zcash);
      expect(zcash!.destination, _zcash);
      expect(
        zcash.key.address,
        (await SecureStore.deriveClaimKey(old.phrase, Rail.zcash)).address,
      );

      // Survives the next reload.
      final again = browser.page();
      expect(await again.checkPin(_pin), PinCheck.normal);
      expect(await again.loadPhrase(), old.phrase);
    });

    test('a profile saved before any PIN migrates to the open slot', () async {
      final old = await legacyDevice(pins: false);
      final browser = _Browser();

      final page = browser.page();
      expect(await page.hasPins(), isFalse);
      expect(await page.loadPhrase(), old.phrase);
      expect(_dump(browser.idb), isNot(contains(_zcash)));

      await page.setPins(pin: _pin, duressPin: _duressPin);
      final next = browser.page();
      await expectLater(next.loadPhrase(), throwsStateError);
      expect(await next.checkPin(_pin), PinCheck.normal);
      expect(await next.loadPhrase(), old.phrase);
    });

    test('a stale copy left by an interrupted run is dropped', () async {
      final old = await legacyDevice();
      final browser = _Browser();
      final page = browser.page();
      expect(await page.checkPin(_pin), PinCheck.normal);
      await page.saveClaim(Rail.zcash, 'u1moved');

      // localStorage still holds the old copy (deleteAll never ran).
      FlutterSecureStorage.setMockInitialValues(Map.of(old.legacy));
      final next = browser.page();
      expect(await next.checkPin(_pin), PinCheck.normal);
      expect((await next.loadClaim(Rail.zcash))!.destination, 'u1moved');
      expect(await const FlutterSecureStorage().readAll(), isEmpty);
    });
  });

  test('Forget this device keeps receiving keys for the next PINs', () async {
    final browser = _Browser();
    final s = await _setUp(browser.page());
    final page = browser.page();
    expect(await page.checkPin(_pin), PinCheck.normal);

    await page.wipeDevice();
    expect(await page.hasPins(), isFalse);
    expect(await page.loadGuard(), isNull);
    expect(await page.loadPhrase(), s.phrase);

    const newPin = '333333';
    await page.setPins(pin: newPin, duressPin: '444444');
    final next = browser.page();
    expect(await next.checkPin(_pin), PinCheck.wrong);
    expect(await next.checkPin(newPin), PinCheck.normal);
    expect(await next.loadPhrase(), s.phrase);
    expect(await next.loadGuard(), isNull);

    await next.wipeAll();
    expect(browser.idb.records, isEmpty);
    expect(await browser.page().hasReceivingKeys(), isFalse);
  });

  test('new PINs cannot replace locked ones', () async {
    final browser = _Browser();
    await _setUp(browser.page());
    await expectLater(
      browser.page().setPins(pin: '333333', duressPin: '444444'),
      throwsStateError,
    );
  });

  test('a pending duress lockdown waits for the unlock, not dropped', () async {
    final browser = _Browser();
    await _setUp(browser.page());
    SharedPreferences.setMockInitialValues({'pending_lockdown_owner': addr(1)});
    final pending = PendingLockdown(await SharedPreferences.getInstance());
    final page = browser.page();
    final retries = <void Function()>[];
    final retrier = LockdownRetrier(
      pending: pending,
      attempt: (owner) async {
        if (await page.loadGuard() == null) {
          throw const LockdownUnavailable('no guard');
        }
      },
      schedule: (_, run) => retries.add(run),
    );

    // App start, before any PIN: the guard key is still sealed.
    await retrier.resume();
    expect(pending.owner, addr(1));
    expect(retries, hasLength(1));

    expect(await page.checkPin(_duressPin), PinCheck.duress);
    retries.removeAt(0)();
    await pumpEventQueue();
    expect(pending.owner, isNull);
  });

  test('Android keeps the platform keystore', () async {
    final store = SecureStore();
    await store.setPins(pin: _pin, duressPin: _duressPin);
    await store.saveClaim(Rail.zcash, _zcash);
    final stored = await const FlutterSecureStorage().readAll();
    expect(stored.keys, containsAll(['pin_hash', 'claim_zcash']));
    expect(await store.checkPin(_pin), PinCheck.normal);
  });

  test('once PINs are set no data key is left in the open slot', () async {
    final browser = _Browser();
    await _setUp(browser.page());
    expect(
      browser.idb.records.keys,
      unorderedEquals([
        'meta',
        'slot.pin',
        'slot.duress',
        'v.guard_private_key',
        'v.recovery_phrase',
        'v.claim_cloak',
        'v.claim_zcash',
      ]),
    );
  });
}
