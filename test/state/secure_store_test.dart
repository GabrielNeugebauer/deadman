import 'dart:convert';

import 'package:deadman/rails/rails.dart';
import 'package:deadman/state/secure_store.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:solana/solana.dart';

const phrase =
    'legal winner thank year wave sausage worth useful legal winner thank yellow';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test('claim keys derive deterministically, one account per rail', () async {
    final cloak = await SecureStore.deriveClaimKey(phrase, Rail.cloak);
    final again = await SecureStore.deriveClaimKey(
      '  LEGAL winner thank year wave sausage worth useful legal winner thank yellow ',
      Rail.cloak,
    );
    final zcash = await SecureStore.deriveClaimKey(phrase, Rail.zcash);
    final path = await Ed25519HDKeyPair.fromMnemonic(
      phrase,
      account: 1,
      change: 0,
    );
    expect(again.address, cloak.address);
    expect(path.address, cloak.address);
    expect(zcash.address, isNot(cloak.address));
  });

  test('validates 12-word phrases', () {
    expect(SecureStore.isValidPhrase(phrase), isTrue);
    expect(SecureStore.isValidPhrase('legal winner thank'), isFalse);
    expect(
      SecureStore.isValidPhrase(phrase.replaceFirst('yellow', 'legal')),
      isFalse,
    );
  });

  test('a new profile derives from a generated phrase and restores', () async {
    final store = SecureStore();
    final p = await store.saveClaim(Rail.zcash, 'u1abc');
    expect(p.recoverable, isTrue);
    final words = await store.loadPhrase();
    expect(words!.split(' '), hasLength(12));
    expect(await store.phraseConfirmed(), isFalse);
    expect(
      p.key.address,
      (await SecureStore.deriveClaimKey(words, Rail.zcash)).address,
    );

    // Same key when only the destination changes.
    final moved = await store.saveClaim(Rail.zcash, 'u1def');
    expect(moved.key.address, p.key.address);

    // A new phone: everything gone, restored from the phrase.
    FlutterSecureStorage.setMockInitialValues({});
    final fresh = SecureStore();
    final r = await fresh.restoreFromPhrase(words);
    expect(r.restored, [Rail.cloak, Rail.zcash]);
    final back = await fresh.loadClaim(Rail.zcash);
    expect(back!.key.address, p.key.address);
    expect(back.destination, isEmpty);
    expect(await fresh.phraseConfirmed(), isTrue);
  });

  test('older random keys keep loading and are not overwritten', () async {
    final legacy = await Ed25519HDKeyPair.random();
    final sk = (await legacy.extract()).bytes;
    FlutterSecureStorage.setMockInitialValues({
      'claim_cloak': jsonEncode({'sk': base64Encode(sk), 'dest': 'dest1'}),
    });
    final store = SecureStore();
    final p = await store.loadClaim(Rail.cloak);
    expect(p!.key.address, legacy.address);
    expect(p.recoverable, isFalse);

    final updated = await store.saveClaim(Rail.cloak, 'dest2');
    expect(updated.key.address, legacy.address);
    expect(updated.recoverable, isFalse);

    final r = await store.restoreFromPhrase(phrase);
    expect(r.kept, [Rail.cloak]);
    expect(r.restored, [Rail.zcash]);
    expect((await store.loadClaim(Rail.cloak))!.key.address, legacy.address);
  });

  test('restoring a different phrase over one in use is refused', () async {
    final store = SecureStore();
    await store.saveClaim(Rail.zcash, 'u1abc');
    expect(() => store.restoreFromPhrase(phrase), throwsA(isA<StateError>()));
  });

  test('Forget this device keeps receiving keys unless asked', () async {
    final store = SecureStore();
    await store.setPins(pin: '111111', duressPin: '222222');
    await store.createGuard();
    await store.saveClaim(Rail.zcash, 'u1abc');

    await store.wipeDevice();
    expect(await store.hasPins(), isFalse);
    expect(await store.loadGuard(), isNull);
    expect(await store.loadClaim(Rail.zcash), isNotNull);
    expect(await store.loadPhrase(), isNotNull);

    await store.wipeAll();
    expect(await store.hasReceivingKeys(), isFalse);
  });
}
