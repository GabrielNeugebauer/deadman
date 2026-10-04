import 'package:deadman/core/config.dart';
import 'package:deadman/state/fee_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes.dart';

void main() {
  test('USDC mode is saved and applied as the fee token', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final api = FakeApi(const []);
    final settings = FeeSettings(prefs, paymasterAvailable: true);
    expect(settings.mode, FeeMode.sol);

    await settings.save(FeeMode.usdc);
    settings.apply(api, settings.mode);
    expect(api.feeToken, AppConfig.usdcMint);

    // A fresh start reads the saved choice.
    final again = FeeSettings(prefs, paymasterAvailable: true);
    expect(again.mode, FeeMode.usdc);

    await again.save(FeeMode.sol);
    again.apply(api, again.mode);
    expect(api.feeToken, isNull);
  });

  test('without a paymaster the mode is always SOL', () async {
    SharedPreferences.setMockInitialValues({FeeSettings.key: 'usdc'});
    final prefs = await SharedPreferences.getInstance();
    final api = FakeApi(const [])..feeToken = 'stale';
    final settings = FeeSettings(prefs, paymasterAvailable: false);
    expect(settings.mode, FeeMode.sol);
    settings.apply(api, settings.mode);
    expect(api.feeToken, isNull);
  });
}
