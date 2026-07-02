import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:solana/solana.dart';

import '../rails/rails.dart';

enum PinCheck { normal, duress, wrong }

/// A beneficiary-side receiving profile for a private rail: the claim key the
/// vault pays on Solana, and where this app forwards the funds privately.
class ClaimProfile {
  const ClaimProfile({
    required this.rail,
    required this.key,
    required this.destination,
  });

  final Rail rail;
  final Ed25519HDKeyPair key;

  /// Zcash unified/shielded address or Cloak address.
  final String destination;

  String get claimCode => '${rail.name}:${key.address}';
}

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
  static String _claimKey(Rail r) => 'claim_${r.name}';

  Future<Ed25519HDKeyPair?> loadGuard() async {
    final encoded = await _storage.read(key: _guardKey);
    if (encoded == null) return null;
    return Ed25519HDKeyPair.fromPrivateKeyBytes(
      privateKey: base64Decode(encoded),
    );
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

  Future<ClaimProfile?> loadClaim(Rail rail) async {
    final raw = await _storage.read(key: _claimKey(rail));
    if (raw == null) return null;
    final m = jsonDecode(raw) as Map<String, dynamic>;
    return ClaimProfile(
      rail: rail,
      key: await Ed25519HDKeyPair.fromPrivateKeyBytes(
        privateKey: base64Decode(m['sk'] as String),
      ),
      destination: m['dest'] as String,
    );
  }

  /// Keeps the existing key when only the destination changes, so codes
  /// already shared with vault owners stay valid.
  Future<ClaimProfile> saveClaim(Rail rail, String destination) async {
    final key = (await loadClaim(rail))?.key ?? await Ed25519HDKeyPair.random();
    final sk = (await key.extract()).bytes;
    await _storage.write(
      key: _claimKey(rail),
      value: jsonEncode({'sk': base64Encode(sk), 'dest': destination}),
    );
    return ClaimProfile(rail: rail, key: key, destination: destination);
  }

  Future<List<ClaimProfile>> loadClaims() async => [
    for (final r in [Rail.cloak, Rail.zcash]) ?await loadClaim(r),
  ];

  Future<void> wipe() => _storage.deleteAll();

  static String _hash(String salt, String pin) =>
      sha256.convert(utf8.encode('$salt:$pin')).toString();
}
