import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:deadman/state/secure_store_web.dart';

/// [WebSecretBackend] in memory for VM tests. PBKDF2 is the real one; the
/// cipher is an HMAC-SHA256 keystream with an HMAC tag over iv, aad and
/// ciphertext, so a wrong key, wrong aad or altered byte fails to decrypt
/// as AES-GCM would.
class MemoryWebSecretBackend implements WebSecretBackend {
  /// What IndexedDB would hold (before the device-key layer).
  final records = <String, Uint8List>{};
  int writes = 0;

  @override
  Future<Map<String, Uint8List>> readAll() async => Map.of(records);

  @override
  Future<void> writeAll(Map<String, Uint8List?> changes) async {
    writes++;
    changes.forEach((k, v) => v == null ? records.remove(k) : records[k] = v);
  }

  @override
  Future<Uint8List> pbkdf2(
    List<int> secret,
    List<int> salt,
    int iterations,
  ) async {
    final hmac = Hmac(sha256, secret);
    var u = hmac.convert([...salt, 0, 0, 0, 1]).bytes;
    final out = List<int>.of(u);
    for (var i = 1; i < iterations; i++) {
      u = hmac.convert(u).bytes;
      for (var j = 0; j < out.length; j++) {
        out[j] ^= u[j];
      }
    }
    return Uint8List.fromList(out);
  }

  static List<int> _stream(List<int> key, List<int> iv, int length) {
    final hmac = Hmac(sha256, key);
    final out = <int>[];
    for (var block = 0; out.length < length; block++) {
      out.addAll(hmac.convert([...iv, block >> 8, block & 0xff]).bytes);
    }
    return out.sublist(0, length);
  }

  static List<int> _tag(
    List<int> key,
    List<int> iv,
    List<int> aad,
    List<int> ct,
  ) => Hmac(sha256, [...key, 1])
      .convert([...iv, ...utf8.encode('${aad.length}:'), ...aad, ...ct])
      .bytes
      .sublist(0, 16);

  @override
  Future<Uint8List> encrypt(
    List<int> key,
    List<int> plain,
    List<int> aad,
  ) async {
    final rnd = Random.secure();
    final iv = List<int>.generate(12, (_) => rnd.nextInt(256));
    final ks = _stream(key, iv, plain.length);
    final ct = [for (var i = 0; i < plain.length; i++) plain[i] ^ ks[i]];
    return Uint8List.fromList([...iv, ...ct, ..._tag(key, iv, aad, ct)]);
  }

  @override
  Future<Uint8List> decrypt(
    List<int> key,
    List<int> sealed,
    List<int> aad,
  ) async {
    if (sealed.length < 28) throw const FormatException('Too short');
    final iv = sealed.sublist(0, 12);
    final ct = sealed.sublist(12, sealed.length - 16);
    final tag = sealed.sublist(sealed.length - 16);
    final want = _tag(key, iv, aad, ct);
    for (var i = 0; i < 16; i++) {
      if (tag[i] != want[i]) throw StateError('OperationError');
    }
    final ks = _stream(key, iv, ct.length);
    return Uint8List.fromList([
      for (var i = 0; i < ct.length; i++) ct[i] ^ ks[i],
    ]);
  }
}
