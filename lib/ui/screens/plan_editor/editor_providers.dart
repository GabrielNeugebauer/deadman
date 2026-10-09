import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/config.dart';
import '../../../state/fee_settings.dart';
import '../../../state/plan_draft.dart';
import '../../../state/providers.dart';

/// What a beneficiary already holds, for the delivery checks. Errors give
/// unknown.
final beneficiaryFactsProvider = FutureProvider.autoDispose
    .family<DeliveryFacts, (String, String?)>((ref, key) async {
      final (address, mint) = key;
      final api = ref.read(apiProvider);
      Future<int?> read(Future<int> Function() f) async {
        try {
          return await f();
        } on Object {
          return null;
        }
      }

      return DeliveryFacts(
        walletLamports: await read(() => api.balance(address)),
        tokenUnits: mint == null
            ? null
            : await read(() => api.tokenBalance(address, mint)),
      );
    });

/// The release fee for payouts saved now.
FeeInfo watchFeeInfo(WidgetRef ref) {
  final fees = ref.watch(feesProvider);
  return FeeInfo(fees: fees.value, failed: fees.hasError);
}

/// SOL the owner should keep for fees when funding a plan.
int watchFeeReserve(WidgetRef ref) => feeReserveLamports(
  solFeeMode: ref.watch(feeModeProvider) == FeeMode.sol,
  sponsored: AppConfig.koraSponsorUrl.isNotEmpty,
);

/// Beneficiary names, kept only on this phone.
class ContactNames {
  ContactNames(this._prefs);

  final SharedPreferences _prefs;

  static const maxLength = 24;

  String _key(String address) => 'contact_name.$address';

  String get(String address) => _prefs.getString(_key(address.trim())) ?? '';

  Future<void> set(String address, String name) {
    final n = name.trim();
    return n.isEmpty
        ? _prefs.remove(_key(address.trim()))
        : _prefs.setString(_key(address.trim()), n);
  }
}

final contactNamesProvider = Provider(
  (ref) => ContactNames(ref.watch(prefsProvider)),
);
