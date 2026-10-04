import 'dart:typed_data';

import 'package:deadman/solana/codec.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // The codec splits 64-bit ints into 32-bit halves so it also runs compiled
  // to JavaScript; it must match ByteData's native 64-bit accessors.
  test('i64/u64 match ByteData little-endian encoding', () {
    const signed = [0, 1, -1, 86400, -86400, 1 << 40, -(1 << 40), 1 << 53];
    const unsigned = [0, 1, 0xffffffff, 0x100000000, 1000000000000000000];
    for (final v in signed) {
      final w = BorshWriter()..i64(v);
      final expected = ByteData(8)..setInt64(0, v, Endian.little);
      expect(w.toBytes(), expected.buffer.asUint8List(), reason: '$v');
      expect(BorshReader(w.toBytes()).i64(), v);
    }
    for (final v in unsigned) {
      final w = BorshWriter()..u64(v);
      final expected = ByteData(8)..setUint64(0, v, Endian.little);
      expect(w.toBytes(), expected.buffer.asUint8List(), reason: '$v');
      expect(BorshReader(w.toBytes()).u64(), v);
    }
  });

  test('extremes round-trip on native platforms', () {
    const min = -0x8000000000000000;
    const max = 0x7fffffffffffffff;
    for (final v in [min, max]) {
      expect(BorshReader((BorshWriter()..i64(v)).toBytes()).i64(), v);
    }
    expect(BorshReader((BorshWriter()..u64(max)).toBytes()).u64(), max);
    expect(() => BorshWriter().u64(-1), throwsArgumentError);
  });
}
