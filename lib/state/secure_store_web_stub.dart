import 'secure_store_web.dart';

/// Off the web, secrets live in the platform keystore instead.
WebSecretBackend createWebSecretBackend() =>
    throw UnsupportedError('Browser key storage is only available on the web');
