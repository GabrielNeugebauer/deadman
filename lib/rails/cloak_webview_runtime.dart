// Drop-in CloakJsRuntime for the app. Rename to lib/rails/cloak_webview_runtime.dart
// once `flutter_inappwebview: ^6.1.5` is in pubspec.yaml and `assets/cloak/` is
// declared as an asset folder. Kept as .example so analysis passes before that.
//
// Must run in the foreground isolate (WebView needs the UI engine), so start
// it when the beneficiary opens the claim screen, not from workmanager.
import 'dart:async';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'cloak_route.dart';

class CloakWebViewRuntime implements CloakJsRuntime {
  CloakWebViewRuntime._(this._webView, this._controller);

  // Served from the APK through WebViewAssetLoader, so the page is a secure
  // https context (WebCrypto, workers, wasm) without file:// access.
  static final pageUrl = WebUri(
    'https://appassets.androidplatform.net/assets/flutter_assets/assets/cloak/index.html',
  );

  final HeadlessInAppWebView _webView;
  final InAppWebViewController _controller;

  static Future<CloakWebViewRuntime> start() async {
    final ready = Completer<InAppWebViewController>();
    final webView = HeadlessInAppWebView(
      initialUrlRequest: URLRequest(url: pageUrl),
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        allowFileAccess: false,
        allowContentAccess: false,
        cacheEnabled: true,
        webViewAssetLoader: WebViewAssetLoader(
          pathHandlers: [AssetsPathHandler(path: '/assets/')],
        ),
      ),
      onLoadStop: (controller, _) {
        if (!ready.isCompleted) ready.complete(controller);
      },
      onReceivedError: (_, request, error) {
        if (request.isForMainFrame == true && !ready.isCompleted) {
          ready.completeError(CloakRouteException(error.description));
        }
      },
    );
    await webView.run();
    final controller = await ready.future.timeout(const Duration(seconds: 30));
    final runtime = CloakWebViewRuntime._(webView, controller);
    await runtime.run('ping', '{}');
    return runtime;
  }

  @override
  Future<String> run(String op, String payloadJson) =>
      CallAsyncCloakRuntime((body, args) async {
        final res = await _controller.callAsyncJavaScript(
          functionBody: body,
          arguments: args,
        );
        if (res?.error != null) throw CloakRouteException(res!.error!);
        return res?.value;
      }).run(op, payloadJson);

  Future<void> dispose() => _webView.dispose();
}
