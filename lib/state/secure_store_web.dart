import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'secure_store.dart' show PinCheck;
import 'secure_store_web_stub.dart'
    if (dart.library.js_interop) 'secure_store_web_js.dart';

/// Browser primitives behind [WebSecrets]: a record store sealed with a
/// device key that never leaves WebCrypto (non-extractable, kept in
/// IndexedDB), plus PBKDF2 and AES-GCM.
abstract class WebSecretBackend {
  /// Every record, already opened with the device key.
  Future<Map<String, Uint8List>> readAll();

  /// Seals and stores [changes] in one transaction; a null value deletes.
  Future<void> writeAll(Map<String, Uint8List?> changes);

  /// PBKDF2-HMAC-SHA256, 32 bytes.
  Future<Uint8List> pbkdf2(List<int> secret, List<int> salt, int iterations);

  /// AES-256-GCM under [key] with a random IV; returns iv || ciphertext.
  Future<Uint8List> encrypt(List<int> key, List<int> plain, List<int> aad);

  /// Throws when [key] or [aad] is wrong or the data was altered.
  Future<Uint8List> decrypt(List<int> key, List<int> sealed, List<int> aad);
}

/// The web build's secret store.
///
/// Values are encrypted with random data keys. The PIN slot wraps both the
/// receiving key (claim keys, recovery phrase) and the guard key; the duress
/// slot wraps the guard key only, so a duress session can still lock the
/// vault but never sees receiving keys. Each slot key is PBKDF2 over the
/// salted SHA-256 of the PIN that older builds stored, so their data
/// migrates under both PINs without either being typed. No PIN hash is kept.
/// Everything is sealed again with the device key in IndexedDB.
///
/// Until PINs are set (first run, or after "Forget this device"), the data
/// keys sit in an open slot sealed by the device key only.
class WebSecrets {
  WebSecrets({
    WebSecretBackend? backend,
    FlutterSecureStorage? legacy,
    this.iterations = defaultIterations,
  }) : _backend = backend ?? createWebSecretBackend(),
       _legacy = legacy ?? const FlutterSecureStorage();

  /// One per page: every SecureStore on the web shares the unlocked keys.
  static WebSecrets get shared => _shared ??= WebSecrets();
  static WebSecrets? _shared;

  /// OWASP's 2023 figure for PBKDF2-HMAC-SHA256.
  static const defaultIterations = 600000;

  static const guardKey = 'guard_private_key';
  static const _legacyPin = 'pin_hash';
  static const _legacyDuress = 'duress_hash';
  static const _legacySalt = 'pin_salt';

  static const _meta = 'meta';
  static const _pinSlot = 'slot.pin';
  static const _duressSlot = 'slot.duress';
  static const _openSlot = 'slot.open';
  static String _value(String key) => 'v.$key';

  final WebSecretBackend _backend;
  final FlutterSecureStorage _legacy;

  /// PBKDF2 rounds for new slots; stored with them.
  final int iterations;

  Map<String, Uint8List>? _records;
  Future<void>? _loading;
  Uint8List? _main;
  Uint8List? _guard;

  /// The salted SHA-256 older builds stored for a PIN.
  static String pinDigest(String salt, String pin) =>
      sha256.convert(utf8.encode('$salt:$pin')).toString();

  Future<Map<String, Uint8List>> _load() async {
    try {
      await (_loading ??= _init());
    } catch (_) {
      _loading = null;
      rethrow;
    }
    return _records!;
  }

  Future<void> _init() async {
    final records = await _backend.readAll();
    final legacy = await _legacy.readAll();
    if (legacy.isNotEmpty) {
      // A copy left by an interrupted migration is stale: keep the records.
      if (!records.containsKey(_pinSlot) && !records.containsKey(_openSlot)) {
        final changes = await _importLegacy(legacy);
        await _backend.writeAll(changes);
        _apply(records, changes);
      }
      await _legacy.deleteAll();
    }
    _records = records;
    final open = records[_openSlot];
    if (open != null) _unwrap(open);
  }

  /// Re-encrypts what flutter_secure_storage_web kept in localStorage next
  /// to its raw AES key.
  Future<Map<String, Uint8List?>> _importLegacy(
    Map<String, String> legacy,
  ) async {
    final main = _random(32);
    final guard = _random(32);
    final salt = legacy[_legacySalt];
    final pin = legacy[_legacyPin];
    final duress = legacy[_legacyDuress];
    final changes = <String, Uint8List?>{
      if (salt != null && pin != null && duress != null)
        ...await _slots(salt, pin, duress, main, guard)
      else
        _openSlot: Uint8List.fromList([...main, ...guard]),
    };
    for (final MapEntry(:key, :value) in legacy.entries) {
      if (key == _legacyPin || key == _legacyDuress || key == _legacySalt) {
        continue;
      }
      changes[_value(key)] = await _seal(key, value, main, guard);
    }
    return changes;
  }

  Future<Map<String, Uint8List?>> _slots(
    String salt,
    String pinHash,
    String duressHash,
    Uint8List main,
    Uint8List guard,
  ) async {
    final kdfSalt = _random(16);
    final pinKek = await _backend.pbkdf2(
      utf8.encode(pinHash),
      kdfSalt,
      iterations,
    );
    final duressKek = await _backend.pbkdf2(
      utf8.encode(duressHash),
      kdfSalt,
      iterations,
    );
    return {
      _meta: utf8.encode(
        jsonEncode({
          'salt': salt,
          'kdf': base64Encode(kdfSalt),
          'iter': iterations,
        }),
      ),
      _pinSlot: await _backend.encrypt(pinKek, [
        ...main,
        ...guard,
      ], utf8.encode(_pinSlot)),
      _duressSlot: await _backend.encrypt(
        duressKek,
        guard,
        utf8.encode(_duressSlot),
      ),
      _openSlot: null,
    };
  }

  Future<Uint8List> _seal(
    String key,
    String value,
    Uint8List main,
    Uint8List guard,
  ) => _backend.encrypt(
    key == guardKey ? guard : main,
    utf8.encode(value),
    utf8.encode(_value(key)),
  );

  void _unwrap(Uint8List both) {
    _main = Uint8List.fromList(both.sublist(0, 32));
    _guard = Uint8List.fromList(both.sublist(32, 64));
  }

  Future<void> _commit(Map<String, Uint8List?> changes) async {
    final records = await _load();
    await _backend.writeAll(changes);
    _apply(records, changes);
  }

  static void _apply(
    Map<String, Uint8List> records,
    Map<String, Uint8List?> changes,
  ) {
    changes.forEach((k, v) => v == null ? records.remove(k) : records[k] = v);
  }

  static Uint8List _random(int n) {
    final rnd = Random.secure();
    return Uint8List.fromList(List<int>.generate(n, (_) => rnd.nextInt(256)));
  }

  static StateError _locked() =>
      StateError('Enter your PIN to unlock the keys kept in this browser');

  Future<bool> hasPins() async => (await _load()).containsKey(_pinSlot);

  /// Opens the slot [pin] belongs to. Any earlier unlock is dropped first.
  Future<PinCheck> checkPin(String pin) async {
    final r = await _load();
    final meta = r[_meta];
    final pinSlot = r[_pinSlot];
    if (meta == null || pinSlot == null) return PinCheck.wrong;
    _main = null;
    _guard = null;
    final m = jsonDecode(utf8.decode(meta)) as Map<String, dynamic>;
    final kek = await _backend.pbkdf2(
      utf8.encode(pinDigest(m['salt'] as String, pin)),
      base64Decode(m['kdf'] as String),
      m['iter'] as int,
    );
    final both = await _tryDecrypt(kek, pinSlot, _pinSlot);
    if (both != null) {
      _unwrap(both);
      return PinCheck.normal;
    }
    final duressSlot = r[_duressSlot];
    final guard = duressSlot == null
        ? null
        : await _tryDecrypt(kek, duressSlot, _duressSlot);
    if (guard != null) {
      _guard = guard;
      return PinCheck.duress;
    }
    return PinCheck.wrong;
  }

  Future<Uint8List?> _tryDecrypt(
    List<int> key,
    Uint8List sealed,
    String name,
  ) async {
    try {
      return await _backend.decrypt(key, sealed, utf8.encode(name));
    } catch (_) {
      return null;
    }
  }

  /// Wraps the data keys under new PINs. The keys must be open: a fresh
  /// browser, the open slot, or a normal unlock.
  Future<void> setPins({required String pin, required String duressPin}) async {
    final r = await _load();
    var main = _main;
    var guard = _guard;
    final changes = <String, Uint8List?>{};
    if (main == null || guard == null) {
      if (r.containsKey(_pinSlot)) throw _locked();
      main = _random(32);
      guard = _random(32);
      // Values no slot can open any more.
      for (final k in r.keys) {
        if (k.startsWith('v.')) changes[k] = null;
      }
    }
    final salt = base64Encode(_random(16));
    changes.addAll(
      await _slots(
        salt,
        pinDigest(salt, pin),
        pinDigest(salt, duressPin),
        main,
        guard,
      ),
    );
    await _commit(changes);
    _main = main;
    _guard = guard;
  }

  /// The data key for [key]; null when a duress session asks for a
  /// receiving secret.
  Future<Uint8List?> _keyFor(String key, {required bool write}) async {
    final r = await _load();
    if (_main == null && _guard == null && !r.containsKey(_pinSlot)) {
      if (!write) return null;
      // Nothing stored yet and no PINs: start the open slot.
      final main = _random(32);
      final guard = _random(32);
      await _commit({
        _openSlot: Uint8List.fromList([...main, ...guard]),
      });
      _main = main;
      _guard = guard;
    }
    if (key == guardKey) return _guard ?? (throw _locked());
    if (_main != null) return _main;
    if (_guard == null) throw _locked();
    if (write) {
      throw StateError('Receiving keys are not available in this session');
    }
    return null;
  }

  Future<String?> read(String key) async {
    final dek = await _keyFor(key, write: false);
    final sealed = (await _load())[_value(key)];
    if (dek == null || sealed == null) return null;
    return utf8.decode(
      await _backend.decrypt(dek, sealed, utf8.encode(_value(key))),
    );
  }

  Future<void> write(String key, String value) async {
    final dek = (await _keyFor(key, write: true))!;
    await _commit({
      _value(key): await _backend.encrypt(
        dek,
        utf8.encode(value),
        utf8.encode(_value(key)),
      ),
    });
  }

  Future<void> delete(String key) async {
    await _keyFor(key, write: true);
    await _commit({_value(key): null});
  }

  /// "Forget this device": drops the PINs and the guard key. Receiving keys
  /// move to the open slot until new PINs wrap them again.
  Future<void> wipeDevice() async {
    await _load();
    final main = _main;
    if (main == null) throw _locked();
    final guard = _random(32);
    await _commit({
      _meta: null,
      _pinSlot: null,
      _duressSlot: null,
      _openSlot: Uint8List.fromList([...main, ...guard]),
      _value(guardKey): null,
    });
    _guard = guard;
  }

  Future<void> wipeAll() async {
    final r = await _load();
    await _commit({for (final k in r.keys) k: null});
    await _legacy.deleteAll();
    _main = null;
    _guard = null;
  }
}
