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

  group('SKR and ORE', () {
    const skr = AppConfig.skrMint;
    const ore = AppConfig.oreMint;

    test('are presets after USDC, with their own decimals', () {
      expect(presetAssets.map((a) => a.symbol).take(4), [
        'SOL',
        'USDC',
        'SKR',
        'ORE',
      ]);
      expect(skr, '4JX81qZWhPPT38Tn4ZswaS2DyH3PffdrFqbYgsoZCuHc');
      expect(ore, '6KdRjrWYouFLmEcNeDpJkc9AUgzvmE7cn3DbAx2KfSyt');
      expect(knownAsset(skr)!.decimals, 6);
      expect(knownAsset(ore)!.decimals, 11);
      expect(presetAssets.map((a) => a.symbol), isNot(contains('JitoSOL')));
    });

    test('ORE amounts use 11 decimals', () {
      expect(parseAmount('1.5', ore), 150000000000);
      expect(parseAmount('0.00000000001', ore), 1);
      expect(amountText(150000000000, ore), '1.5 ORE');
      expect(amountText(123456789, ore), '0.0012 ORE');
      expect(amountText(1, ore), '0.00000000001 ORE');
      expect(amountInput(150000000000, ore), '1.5');
    });

    test('SKR amounts use 6 decimals', () {
      expect(amountText(1200000000, skr), '1200 SKR');
      expect(parseAmount('12.25', skr), 12250000);
      expect(unitLabel(skr), 'SKR');
    });
  });

  group('NFTs', () {
    setUp(forgetNfts);
    tearDown(forgetNfts);

    test('a remembered NFT reads by its name and moves whole', () {
      final mint = addr(70);
      expect(isNft(mint), isFalse);
      expect(amountText(1, mint), startsWith('1 units '));
      rememberNft(mint, ' Mad Lad #42 ', imageUrl: 'https://x/img.png');
      expect(isNft(mint), isTrue);
      expect(knownAsset(mint)!.nft, isTrue);
      expect(knownAsset(mint)!.imageUrl, 'https://x/img.png');
      expect(amountText(1, mint), 'Mad Lad #42');
      expect(amountText(2, mint), '2 × Mad Lad #42');
      expect(assetSymbol(mint), 'Mad Lad #42');
      expect(unitLabel(mint), 'NFT');
      expect(parseAmount('1', mint), 1);
      expect(amountInput(1, mint), '1');
    });

    test('an unnamed NFT gets a short name', () {
      final mint = addr(71);
      rememberNft(mint, '');
      expect(assetSymbol(mint), startsWith('NFT '));
    });

    test('forgetNfts clears them', () {
      final mint = addr(72);
      rememberNft(mint, 'X');
      forgetNfts();
      expect(isNft(mint), isFalse);
    });
  });
}
