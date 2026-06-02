import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:solana/solana.dart';

enum PinCheck { normal, duress, wrong }

/// Device-local secrets, encrypted by the Android Keystore.
///
/// The guard key can only pulse and lock down the vault on-chain, so keeping
/// it on the device (behind biometrics in the UI) never puts funds at risk.
class SecureStore {
  SecureStore([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  static const _guardKey = 'guard_private_key';
  static const _pinKey = 'pin_hash';
  static const _duressKey = 'duress_hash';
  static const _saltKey = 'pin_salt';

  Future<Ed25519HDKeyPair?> loadGuard() async {
    final encoded = await _storage.read(key: _guardKey);
    if (encoded == null) return null;
    return Ed25519HDKeyPair.fromPrivateKeyBytes(privateKey: base64Decode(encoded));
  }

  Future<Ed25519HDKeyPair> createGuard() async {
    final pair = await Ed25519HDKeyPair.random();
    final data = await pair.extract();
    await _storage.write(key: _guardKey, value: base64Encode(data.bytes));
    return pair;
  }

  Future<bool> hasPins() async => await _storage.read(key: _pinKey) != null;

  Future<void> setPins({required String pin, required String duressPin}) async {
    assert(pin != duressPin);
    final rnd = Random.secure();
    final salt = base64Encode(List<int>.generate(16, (_) => rnd.nextInt(256)));
    await _storage.write(key: _saltKey, value: salt);
    await _storage.write(key: _pinKey, value: _hash(salt, pin));
    await _storage.write(key: _duressKey, value: _hash(salt, duressPin));
  }

  Future<PinCheck> checkPin(String pin) async {
    final salt = await _storage.read(key: _saltKey);
    if (salt == null) return PinCheck.wrong;
    final h = _hash(salt, pin);
    if (h == await _storage.read(key: _duressKey)) return PinCheck.duress;
    if (h == await _storage.read(key: _pinKey)) return PinCheck.normal;
    return PinCheck.wrong;
  }

  Future<void> wipe() => _storage.deleteAll();

  static String _hash(String salt, String pin) =>
      sha256.convert(utf8.encode('$salt:$pin')).toString();
}
