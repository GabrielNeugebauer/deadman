import 'package:flutter/services.dart';

import '../core/config.dart';
import 'wallet_bridge.dart';

/// [WalletBridge] backed by the native `deadman/mwa` channel
/// (Solana Mobile clientlib-ktx, MWA 2.0).
class MwaWalletBridge implements WalletBridge {
  MwaWalletBridge({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('deadman/mwa');

  final MethodChannel _channel;
  String? _authToken;

  String? get authToken => _authToken;

  Map<String, Object?> get _identity => const {
    'identityUri': AppConfig.appIdentityUri,
    'iconUri': AppConfig.appIconPath,
    'identityName': AppConfig.appIdentityName,
    'cluster': AppConfig.cluster,
  };

  @override
  Future<WalletSession> authorize() async {
    final result = await _invoke<Map<Object?, Object?>>('authorize', _identity);
    final session = WalletSession(
      publicKey: result['publicKey']! as String,
      authToken: result['authToken']! as String,
      walletLabel: result['walletLabel'] as String?,
    );
    _authToken = session.authToken;
    return session;
  }

  @override
  Future<List<Uint8List>> signTransactions(List<Uint8List> transactions) async {
    try {
      final signed = await _invoke<List<Object?>>('signTransactions', {
        ..._identity,
        'authToken': _authToken,
        'transactions': transactions,
      });
      return signed.cast<Uint8List>();
    } on WalletException catch (e) {
      // A stale token surfaces as an authorization failure; force a fresh
      // authorize on the next attempt.
      if (e.declined) _authToken = null;
      rethrow;
    }
  }

  @override
  Future<void> deauthorize(String authToken) async {
    try {
      await _invoke<void>('deauthorize', {
        ..._identity,
        'authToken': authToken,
      });
    } finally {
      if (_authToken == authToken) _authToken = null;
    }
  }

  Future<T> _invoke<T>(String method, Map<String, Object?> args) async {
    try {
      final result = await _channel.invokeMethod<T>(method, args);
      return result as T;
    } on PlatformException catch (e) {
      throw WalletException(e.code, e.message ?? e.code);
    }
  }
}
