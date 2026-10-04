import 'package:shared_preferences/shared_preferences.dart';

import '../core/config.dart';
import '../solana/deadman_api.dart';

/// Who pays network fees on wallet-signed owner transactions.
enum FeeMode { sol, usdc }

/// Persisted fee-payment choice. USDC needs a Kora paymaster
/// ([paymasterAvailable]); without one the mode is always SOL.
class FeeSettings {
  FeeSettings(this._prefs, {required this.paymasterAvailable});

  final SharedPreferences _prefs;
  final bool paymasterAvailable;

  static const key = 'fee_mode';

  FeeMode get mode =>
      paymasterAvailable && _prefs.getString(key) == FeeMode.usdc.name
      ? FeeMode.usdc
      : FeeMode.sol;

  Future<void> save(FeeMode mode) => _prefs.setString(key, mode.name);

  static String? feeTokenFor(FeeMode mode) =>
      mode == FeeMode.usdc ? AppConfig.usdcMint : null;

  void apply(DeadmanApi api, FeeMode mode) => api.feeToken = feeTokenFor(mode);
}
