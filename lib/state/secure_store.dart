import 'dart:convert';
import 'dart:math';

import 'package:bip39/bip39.dart' as bip39;
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
    this.recoverable = false,
  });

  final Rail rail;
  final Ed25519HDKeyPair key;

  /// Zcash unified/shielded address or Cloak address. Empty after a restore
  /// from the recovery phrase until the user sets it again.
  final String destination;

  /// Derived from this device's recovery phrase. Older profiles hold a
  /// random key that only exists on this phone.
  final bool recoverable;

  String get claimCode => '${rail.name}:${key.address}';
}

/// Result of restoring receiving profiles from a recovery phrase.
class RestoreResult {
  const RestoreResult({required this.restored, required this.kept});

  /// Rails whose phrase-derived claim key is now on this device.
  final List<Rail> restored;

  /// Rails that already hold a different (older, random) key here, which
  /// was kept because funds may have been sent to it.
  final List<Rail> kept;
}

/// Device-local secrets, encrypted by the Android Keystore.
///
/// The guard key can only pulse and lock down the vault on-chain, so keeping
/// it on the device (behind biometrics in the UI) never puts funds at risk.
/// Claim keys do receive funds, so they derive from a 12-word recovery
/// phrase the beneficiary writes down.
class SecureStore {
  SecureStore([FlutterSecureStorage? storage])
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  static const _guardKey = 'guard_private_key';
  static const _pinKey = 'pin_hash';
  static const _duressKey = 'duress_hash';
  static const _saltKey = 'pin_salt';
  static const _phraseKey = 'recovery_phrase';
  static const _phraseConfirmedKey = 'recovery_phrase_confirmed';
  static String _claimKey(Rail r) => 'claim_${r.name}';

  /// BIP44 account per rail: `m/44'/501'/<account>'/0'`.
  static const claimAccounts = {Rail.cloak: 1, Rail.zcash: 2};

  static Future<Ed25519HDKeyPair> deriveClaimKey(String phrase, Rail rail) =>
      Ed25519HDKeyPair.fromMnemonic(
        normalizePhrase(phrase),
        account: claimAccounts[rail]!,
        change: 0,
      );

  static String normalizePhrase(String phrase) =>
      phrase.trim().toLowerCase().split(RegExp(r'\s+')).join(' ');

  static bool isValidPhrase(String phrase) {
    final p = normalizePhrase(phrase);
    return p.split(' ').length == 12 && bip39.validateMnemonic(p);
  }

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

  Future<String?> loadPhrase() => _storage.read(key: _phraseKey);

  /// The user confirmed writing the phrase down.
  Future<bool> phraseConfirmed() async =>
      await _storage.read(key: _phraseConfirmedKey) != null;

  Future<void> markPhraseConfirmed() =>
      _storage.write(key: _phraseConfirmedKey, value: '1');

  Future<String> _ensurePhrase() async {
    final existing = await loadPhrase();
    if (existing != null) return existing;
    final phrase = bip39.generateMnemonic();
    await _storage.write(key: _phraseKey, value: phrase);
    return phrase;
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
      recoverable: m['src'] == 'phrase',
    );
  }

  Future<void> _writeClaim(
    Rail rail,
    Ed25519HDKeyPair key,
    String destination, {
    required bool recoverable,
  }) async {
    final sk = (await key.extract()).bytes;
    await _storage.write(
      key: _claimKey(rail),
      value: jsonEncode({
        'sk': base64Encode(sk),
        'dest': destination,
        if (recoverable) 'src': 'phrase',
      }),
    );
  }

  /// Keeps the existing key when only the destination changes, so codes
  /// already shared with vault owners stay valid. A new profile derives its
  /// key from the recovery phrase (created on first use).
  Future<ClaimProfile> saveClaim(Rail rail, String destination) async {
    final existing = await loadClaim(rail);
    final key =
        existing?.key ?? await deriveClaimKey(await _ensurePhrase(), rail);
    final recoverable = existing?.recoverable ?? true;
    await _writeClaim(rail, key, destination, recoverable: recoverable);
    return ClaimProfile(
      rail: rail,
      key: key,
      destination: destination,
      recoverable: recoverable,
    );
  }

  Future<List<ClaimProfile>> loadClaims() async => [
    for (final r in [Rail.cloak, Rail.zcash]) ?await loadClaim(r),
  ];

  /// Re-creates every rail's phrase-derived claim key on this device. Rails
  /// that already hold a different key keep it. Throws [FormatException]
  /// for an invalid phrase and [StateError] when this device already uses
  /// a different phrase.
  Future<RestoreResult> restoreFromPhrase(String phrase) async {
    final p = normalizePhrase(phrase);
    if (!isValidPhrase(p)) {
      throw const FormatException('That is not a valid 12-word phrase');
    }
    final current = await loadPhrase();
    if (current != null && current != p) {
      final inUse = (await loadClaims()).any((c) => c.recoverable);
      if (inUse) {
        throw StateError(
          'This phone already uses a different recovery phrase for its receiving profiles',
        );
      }
    }
    await _storage.write(key: _phraseKey, value: p);
    await markPhraseConfirmed();
    final restored = <Rail>[];
    final kept = <Rail>[];
    for (final rail in claimAccounts.keys) {
      final key = await deriveClaimKey(p, rail);
      final existing = await loadClaim(rail);
      if (existing == null) {
        await _writeClaim(rail, key, '', recoverable: true);
        restored.add(rail);
      } else if (existing.key.address == key.address) {
        restored.add(rail);
      } else {
        kept.add(rail);
      }
    }
    return RestoreResult(restored: restored, kept: kept);
  }

  /// Receiving keys or a recovery phrase live on this device.
  Future<bool> hasReceivingKeys() async =>
      (await loadClaims()).isNotEmpty || await loadPhrase() != null;

  /// "Forget this device": PINs and the guard key only. Receiving keys stay.
  Future<void> wipeDevice() async {
    for (final k in [_pinKey, _duressKey, _saltKey, _guardKey]) {
      await _storage.delete(key: k);
    }
  }

  /// Everything, including receiving keys and the recovery phrase.
  Future<void> wipeAll() => _storage.deleteAll();

  static String _hash(String salt, String pin) =>
      sha256.convert(utf8.encode('$salt:$pin')).toString();
}
