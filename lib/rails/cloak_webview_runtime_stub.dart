import 'cloak_route.dart';

/// The Cloak SDK runs in an Android headless WebView; the web build has none.
class CloakWebViewRuntime implements CloakJsRuntime {
  static const _unsupported = CloakRouteException(
    'Cloak private routing runs in the Android app',
  );

  static Future<CloakWebViewRuntime> start() => Future.error(_unsupported);

  @override
  Future<String> run(String op, String payloadJson) =>
      Future.error(_unsupported);

  Future<void> dispose() async {}
}
