// WebCrypto and IndexedDB behind WebSecrets, through dart:js_interop.
import 'dart:async';
import 'dart:js_interop';
import 'dart:math';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'secure_store_web.dart';

WebSecretBackend createWebSecretBackend() => IndexedDbSecretBackend();

extension type _AesGcm._(JSObject _) implements JSObject {
  external factory _AesGcm({
    String name,
    JSUint8Array iv,
    JSUint8Array additionalData,
  });
}

extension type _AesKeyGen._(JSObject _) implements JSObject {
  external factory _AesKeyGen({String name, int length});
}

extension type _Pbkdf2._(JSObject _) implements JSObject {
  external factory _Pbkdf2({
    String name,
    JSUint8Array salt,
    int iterations,
    String hash,
  });
}

/// Records in IndexedDB, each sealed with an AES-GCM device key that was
/// generated non-extractable: page scripts can use it but never read it.
class IndexedDbSecretBackend implements WebSecretBackend {
  static const _dbName = 'deadman_secrets';
  static const _keys = 'keys';
  static const _records = 'records';
  static const _deviceKeyId = 'device';
  static const _ivLength = 12;

  Future<web.IDBDatabase>? _db;
  Future<web.CryptoKey>? _device;

  web.SubtleCrypto get _subtle => web.window.crypto.subtle;

  Future<web.IDBDatabase> _database() => _db ??= _open();

  Future<web.IDBDatabase> _open() {
    final done = Completer<web.IDBDatabase>();
    final req = web.window.indexedDB.open(_dbName, 1);
    req.onupgradeneeded = ((web.Event _) {
      final db = req.result! as web.IDBDatabase;
      for (final name in [_keys, _records]) {
        if (!db.objectStoreNames.contains(name)) db.createObjectStore(name);
      }
    }).toJS;
    req.onsuccess = ((web.Event _) {
      done.complete(req.result! as web.IDBDatabase);
    }).toJS;
    req.onerror = ((web.Event _) {
      _db = null;
      done.completeError(_idbError(req.error));
    }).toJS;
    return done.future;
  }

  static StateError _idbError(web.DOMException? e) =>
      StateError('Browser storage failed: ${e?.name ?? 'unknown error'}');

  static Future<void> _completed(web.IDBTransaction tx) {
    final done = Completer<void>();
    void fail(web.Event _) {
      if (!done.isCompleted) done.completeError(_idbError(tx.error));
    }

    tx.oncomplete = ((web.Event _) {
      if (!done.isCompleted) done.complete();
    }).toJS;
    tx.onerror = fail.toJS;
    tx.onabort = fail.toJS;
    return done.future;
  }

  Future<web.CryptoKey> _deviceKey() async {
    try {
      return await (_device ??= _loadDeviceKey());
    } catch (_) {
      _device = null;
      rethrow;
    }
  }

  Future<web.CryptoKey> _loadDeviceKey() async {
    final existing = await _getDeviceKey();
    if (existing != null) return existing;
    final fresh =
        (await _subtle
                .generateKey(
                  _AesKeyGen(name: 'AES-GCM', length: 256),
                  false,
                  ['encrypt'.toJS, 'decrypt'.toJS].toJS,
                )
                .toDart)!
            as web.CryptoKey;
    final db = await _database();
    final tx = db.transaction(_keys.toJS, 'readwrite');
    // add, not put: another tab may have stored its key first.
    tx.objectStore(_keys).add(fresh, _deviceKeyId.toJS);
    try {
      await _completed(tx);
      return fresh;
    } on StateError {
      return (await _getDeviceKey()) ?? (throw _idbError(null));
    }
  }

  Future<web.CryptoKey?> _getDeviceKey() async {
    final db = await _database();
    final tx = db.transaction(_keys.toJS, 'readonly');
    final req = tx.objectStore(_keys).get(_deviceKeyId.toJS);
    await _completed(tx);
    final key = req.result;
    return key == null ? null : key as web.CryptoKey;
  }

  static Uint8List _iv() {
    final rnd = Random.secure();
    return Uint8List.fromList(
      List<int>.generate(_ivLength, (_) => rnd.nextInt(256)),
    );
  }

  Future<Uint8List> _encryptWith(
    web.CryptoKey key,
    List<int> plain,
    List<int> aad,
  ) async {
    final iv = _iv();
    final ct =
        (await _subtle
                .encrypt(
                  _AesGcm(
                    name: 'AES-GCM',
                    iv: iv.toJS,
                    additionalData: Uint8List.fromList(aad).toJS,
                  ),
                  key,
                  Uint8List.fromList(plain).toJS,
                )
                .toDart)!
            as JSArrayBuffer;
    return Uint8List.fromList([...iv, ...ct.toDart.asUint8List()]);
  }

  Future<Uint8List> _decryptWith(
    web.CryptoKey key,
    List<int> sealed,
    List<int> aad,
  ) async {
    if (sealed.length <= _ivLength) throw const FormatException('Too short');
    final data = Uint8List.fromList(sealed);
    final plain =
        (await _subtle
                .decrypt(
                  _AesGcm(
                    name: 'AES-GCM',
                    iv: data.sublist(0, _ivLength).toJS,
                    additionalData: Uint8List.fromList(aad).toJS,
                  ),
                  key,
                  data.sublist(_ivLength).toJS,
                )
                .toDart)!
            as JSArrayBuffer;
    return plain.toDart.asUint8List();
  }

  Future<web.CryptoKey> _importAes(List<int> raw) => _subtle
      .importKey(
        'raw',
        Uint8List.fromList(raw).toJS,
        'AES-GCM'.toJS,
        false,
        ['encrypt'.toJS, 'decrypt'.toJS].toJS,
      )
      .toDart;

  static List<int> _recordAad(String name) => 'record:$name'.codeUnits;

  @override
  Future<Map<String, Uint8List>> readAll() async {
    final db = await _database();
    final tx = db.transaction(_records.toJS, 'readonly');
    final store = tx.objectStore(_records);
    final keysReq = store.getAllKeys();
    final valuesReq = store.getAll();
    await _completed(tx);
    final names = (keysReq.result! as JSArray<JSString>).toDart;
    final values = (valuesReq.result! as JSArray<JSUint8Array>).toDart;
    final device = await _deviceKey();
    return {
      for (var i = 0; i < names.length; i++)
        names[i].toDart: await _decryptWith(
          device,
          values[i].toDart,
          _recordAad(names[i].toDart),
        ),
    };
  }

  @override
  Future<void> writeAll(Map<String, Uint8List?> changes) async {
    final device = await _deviceKey();
    final sealed = <String, Uint8List?>{
      for (final MapEntry(:key, :value) in changes.entries)
        key: value == null
            ? null
            : await _encryptWith(device, value, _recordAad(key)),
    };
    final db = await _database();
    final tx = db.transaction(_records.toJS, 'readwrite');
    final store = tx.objectStore(_records);
    for (final MapEntry(:key, :value) in sealed.entries) {
      if (value == null) {
        store.delete(key.toJS);
      } else {
        store.put(value.toJS, key.toJS);
      }
    }
    await _completed(tx);
  }

  @override
  Future<Uint8List> pbkdf2(
    List<int> secret,
    List<int> salt,
    int iterations,
  ) async {
    final base = await _subtle
        .importKey(
          'raw',
          Uint8List.fromList(secret).toJS,
          'PBKDF2'.toJS,
          false,
          ['deriveBits'.toJS].toJS,
        )
        .toDart;
    final bits = await _subtle
        .deriveBits(
          _Pbkdf2(
            name: 'PBKDF2',
            salt: Uint8List.fromList(salt).toJS,
            iterations: iterations,
            hash: 'SHA-256',
          ),
          base,
          256,
        )
        .toDart;
    return bits.toDart.asUint8List();
  }

  @override
  Future<Uint8List> encrypt(
    List<int> key,
    List<int> plain,
    List<int> aad,
  ) async => _encryptWith(await _importAes(key), plain, aad);

  @override
  Future<Uint8List> decrypt(
    List<int> key,
    List<int> sealed,
    List<int> aad,
  ) async => _decryptWith(await _importAes(key), sealed, aad);
}
