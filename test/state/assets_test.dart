import 'package:deadman/core/config.dart';
import 'package:deadman/state/assets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

void main() {
  const usdc = AppConfig.usdcMint;

  group('parseUnits', () {
    test('USDC uses 6 decimals, exactly', () {
      expect(parseUnits('1', 6), 1000000);
      expect(parseUnits('1.5', 6), 1500000);
      expect(parseUnits('0,25', 6), 250000);
      expect(parseUnits('.000001', 6), 1);
      expect(parseUnits('100.10', 6), 100100000);
    });

    test('rejects junk, negatives and extra precision', () {
      expect(parseUnits('', 6), isNull);
      expect(parseUnits('.', 6), isNull);
      expect(parseUnits('-1', 6), isNull);
      expect(parseUnits('1e3', 6), isNull);
      expect(parseUnits('0.0000001', 6), isNull);
      expect(parseUnits('99999999999999999999', 6), isNull);
    });
  });

  test('formatUnits rounds and trims', () {
    expect(formatUnits(1500000, 6), '1.5');
    expect(formatUnits(1234567, 6, digits: 2), '1.23');
    expect(formatUnits(1995000, 6, digits: 2), '2');
    expect(formatUnits(0, 6), '0');
  });

  test('parseAmount follows the asset', () {
    expect(parseAmount('2.5', usdc), 2500000);
    expect(parseAmount('0.1', null), 100000000);
    expect(parseAmount('42', addr(7)), 42);
    expect(parseAmount('4.2', addr(7)), isNull);
  });

  test('amountText names known assets and keeps units for others', () {
    expect(amountText(100000000, usdc), '100 USDC');
    expect(amountText(12345678, usdc), '12.35 USDC');
    expect(amountText(1, usdc), '0.000001 USDC');
    expect(amountText(100000000, null), '0.100 SOL');
    expect(amountText(42, addr(7)), startsWith('42 units '));
    expect(amountInput(1500000, usdc), '1.5');
  });

  test('presets offer SOL and USDC', () {
    expect(presetAssets.map((a) => a.symbol), containsAll(['SOL', 'USDC']));
    expect(assetSymbol(usdc), 'USDC');
    expect(unitLabel(usdc), 'USDC');
    expect(unitLabel(addr(7)), 'units');
  });

  test("devnet: test USDC is 'USDC'; Circle's devnet mint reads clearly", () {
    expect(AppConfig.isMainnet, isFalse);
    expect(usdc, 'Ew8Z6hhRp7MFK8KJAxRqaBQvBEjtRj4Y4K4YhWsPMFGk');
    expect(assetSymbol(usdc), 'USDC');
    expect(assetSymbol(circleDevnetUsdcMint), 'USDC (Circle)');
    expect(amountText(1500000, circleDevnetUsdcMint), '1.5 USDC (Circle)');
    expect(parseAmount('2.5', circleDevnetUsdcMint), 2500000);
    expect(
      presetAssets.map((a) => a.mint),
      isNot(contains(circleDevnetUsdcMint)),
    );
    final other = addr(61);
    expect(assetInfo(other).decimals, 0);
    expect(assetInfo(other).symbol, assetSymbol(other));
    expect(assetInfo(null), solAsset);
  });
}
