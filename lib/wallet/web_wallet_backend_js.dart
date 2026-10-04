// Browser wallet access through dart:js_interop. Phantom and Solflare are
// reached through the Wallet Standard first (raw transaction bytes), and
// through their legacy injected providers otherwise.
import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'wallet_bridge.dart';
import 'web_wallet_bridge.dart';

WebWalletBackend createWebWalletBackend() => JsWebWalletBackend();

/// @solana/web3.js, only for legacy providers that want transaction objects.
/// Pinned and checked with Subresource Integrity; loaded on first use.
const web3JsUrl =
    'https://cdn.jsdelivr.net/npm/@solana/web3.js@1.98.4/lib/index.iife.min.js';
const web3JsIntegrity =
    'sha384-I45YF+S0YGWIolUyTksLk9TNtTqaDgZg8e6T1OoBoJvvFmphqYNIPZw3Kl0TkZNN';

extension type _StandardWallet._(JSObject _) implements JSObject {
  external String get name;
  external String? get icon;
  external JSObject get features;
}

extension type _Account._(JSObject _) implements JSObject {
  external String get address;
}

extension type _ConnectOutput._(JSObject _) implements JSObject {
  external JSArray<_Account> get accounts;
}

extension type _SignOutput._(JSObject _) implements JSObject {
  external JSUint8Array get signedTransaction;
}

extension type _Injected._(JSObject _) implements JSObject {
  external JSPromise<JSAny?> connect();
  external JSPromise<JSAny?> disconnect();
  external JSObject? get publicKey;
  external JSPromise<JSObject> signTransaction(JSObject transaction);
  external JSPromise<JSArray<JSObject>> signAllTransactions(
    JSArray<JSObject> transactions,
  );
}

class JsWebWalletBackend implements WebWalletBackend {
  final _standard = <String, _StandardWallet>{};
  final _accounts = <WalletKind, _Account>{};
  Future<void>? _listening;
  Future<void>? _web3;

  @override
  Future<List<WebWallet>> discover() async {
    await (_listening ??= _listen());
    return mergeDiscovered(
      standard: [
        for (final w in _standard.values)
          StandardWalletInfo(
            name: w.name,
            icon: w.icon,
            features: _keys(w.features),
          ),
      ],
      injected: [
        for (final kind in WalletKind.values)
          if (_injected(kind) != null) kind,
      ],
    );
  }

  /// Wallet Standard handshake: wallets loaded before us answer
  /// `app-ready`; wallets loaded later announce `register-wallet`.
  Future<void> _listen() async {
    final api = JSObject();
    api['register'] = ((_StandardWallet wallet) {
      final name = wallet.getProperty<JSAny?>('name'.toJS);
      if (name.isA<JSString>()) _standard[(name as JSString).toDart] = wallet;
      return (() {}).toJS;
    }).toJS;
    web.window.addEventListener(
      'wallet-standard:register-wallet',
      ((web.CustomEvent event) {
        final callback = event.detail;
        if (!callback.isA<JSFunction>()) return;
        try {
          (callback as JSFunction).callAsFunction(null, api);
        } catch (_) {
          // A misbehaving wallet must not break discovery of the others.
        }
      }).toJS,
    );
    web.window.dispatchEvent(
      web.CustomEvent(
        'wallet-standard:app-ready',
        web.CustomEventInit(detail: api),
      ),
    );
    // Extensions inject at document start; give stragglers a moment.
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }

  @override
  Future<String> connect(WebWallet wallet, {required String chain}) =>
      _guard(wallet, () async {
        if (wallet.path == SigningPath.walletStandard) {
          final out = await _feature(
            wallet,
            'standard:connect',
          ).callMethod<JSPromise<_ConnectOutput>>('connect'.toJS).toDart;
          final account = out.accounts.toDart.firstOrNull;
          if (account == null) {
            throw WalletException(
              'DECLINED',
              '${wallet.name} did not share an account',
            );
          }
          _accounts[wallet.kind] = account;
          return account.address;
        }
        final provider = _provider(wallet);
        await provider.connect().toDart;
        final key = provider.publicKey;
        if (key == null) {
          throw WalletException(
            'DECLINED',
            '${wallet.name} did not share an account',
          );
        }
        return key.callMethod<JSString>('toString'.toJS).toDart;
      });

  @override
  Future<List<Uint8List>> sign(
    WebWallet wallet,
    List<Uint8List> transactions, {
    required String chain,
  }) => _guard(wallet, () async {
    if (wallet.path == SigningPath.walletStandard) {
      final account = _accounts[wallet.kind];
      if (account == null) {
        throw WalletException('NO_IDENTITY', '${wallet.name} is not connected');
      }
      // One call for all inputs, so the wallet asks for approval once.
      final out = await _feature(wallet, 'solana:signTransaction')
          .callMethodVarArgs<JSPromise<JSArray<_SignOutput>>>(
            'signTransaction'.toJS,
            [
              for (final tx in transactions)
                JSObject()
                  ..['account'] = account
                  ..['transaction'] = tx.toJS
                  ..['chain'] = chain.toJS,
            ],
          )
          .toDart;
      return [for (final o in out.toDart) o.signedTransaction.toDart];
    }
    final provider = _provider(wallet);
    await (_web3 ??= _loadWeb3().catchError((Object e) {
      _web3 = null;
      throw e;
    }));
    final versioned = globalContext
        .getProperty<JSObject>('solanaWeb3'.toJS)
        .getProperty<JSObject>('VersionedTransaction'.toJS);
    final unsigned = [
      for (final tx in transactions)
        versioned.callMethod<JSObject>('deserialize'.toJS, tx.toJS),
    ];
    final List<JSObject> signed;
    if (unsigned.length > 1 && provider.has('signAllTransactions')) {
      signed =
          (await provider.signAllTransactions(unsigned.toJS).toDart).toDart;
    } else {
      signed = [
        for (final tx in unsigned) await provider.signTransaction(tx).toDart,
      ];
    }
    return [
      for (final tx in signed)
        tx.callMethod<JSUint8Array>('serialize'.toJS).toDart,
    ];
  });

  @override
  Future<void> disconnect(WebWallet wallet) => _guard(wallet, () async {
    _accounts.remove(wallet.kind);
    if (wallet.path == SigningPath.walletStandard) {
      final feature = _standard[wallet.name]?.features.getProperty<JSObject?>(
        'standard:disconnect'.toJS,
      );
      await feature?.callMethod<JSPromise<JSAny?>>('disconnect'.toJS).toDart;
      return;
    }
    await _provider(wallet).disconnect().toDart;
  });

  JSObject _feature(WebWallet wallet, String name) {
    final feature = _standard[wallet.name]?.features.getProperty<JSObject?>(
      name.toJS,
    );
    if (feature == null) {
      throw WalletException('WALLET_ERROR', '${wallet.name} lacks $name');
    }
    return feature;
  }

  _Injected _provider(WebWallet wallet) =>
      _injected(wallet.kind) ??
      (throw WalletException('NO_WALLET', '${wallet.name} is not installed'));

  /// `window.phantom.solana` (or `window.solana` flagged `isPhantom`) and
  /// `window.solflare`.
  static _Injected? _injected(WalletKind kind) {
    JSObject? flagged(JSAny? candidate, String flag) {
      if (!candidate.isA<JSObject>()) return null;
      final object = candidate as JSObject;
      return _truthy(object.getProperty(flag.toJS)) ? object : null;
    }

    final window = globalContext;
    final provider = switch (kind) {
      WalletKind.phantom =>
        flagged(
              _get(window.getProperty('phantom'.toJS), 'solana'),
              'isPhantom',
            ) ??
            flagged(window.getProperty('solana'.toJS), 'isPhantom'),
      WalletKind.solflare => flagged(
        window.getProperty('solflare'.toJS),
        'isSolflare',
      ),
    };
    return provider == null ? null : _Injected._(provider);
  }

  static JSAny? _get(JSAny? object, String key) => object.isA<JSObject>()
      ? (object as JSObject).getProperty(key.toJS)
      : null;

  static bool _truthy(JSAny? value) => value != null && value.isTruthy.toDart;

  static Set<String> _keys(JSObject object) => {
    for (final k
        in globalContext
            .getProperty<JSObject>('Object'.toJS)
            .callMethod<JSArray<JSString>>('keys'.toJS, object)
            .toDart)
      k.toDart,
  };

  static Future<void> _loadWeb3() {
    if (globalContext.has('solanaWeb3')) return Future.value();
    final done = Completer<void>();
    final script = web.HTMLScriptElement()
      ..src = web3JsUrl
      ..integrity = web3JsIntegrity
      ..crossOrigin = 'anonymous';
    script
      ..addEventListener(
        'load',
        ((web.Event _) {
          if (!done.isCompleted) done.complete();
        }).toJS,
      )
      ..addEventListener(
        'error',
        ((web.Event _) {
          if (!done.isCompleted) {
            done.completeError(
              const WalletException(
                'WALLET_ERROR',
                'Could not load @solana/web3.js for this wallet',
              ),
            );
          }
        }).toJS,
      );
    web.document.head!.append(script);
    return done.future.timeout(const Duration(seconds: 30));
  }

  /// Maps wallet rejections (EIP-1193 style code 4001, or a "rejected"
  /// message) to `DECLINED`, everything else to `WALLET_ERROR`.
  static Future<T> _guard<T>(
    WebWallet wallet,
    Future<T> Function() call,
  ) async {
    try {
      return await call();
    } on WalletException {
      rethrow;
    } catch (e) {
      final (code, message) = _describe(e);
      final declined = code == 4001 || message.toLowerCase().contains('reject');
      throw WalletException(
        declined ? 'DECLINED' : 'WALLET_ERROR',
        declined
            ? '${wallet.name}: request declined'
            : '${wallet.name}: $message',
      );
    }
  }

  static (int?, String) _describe(Object e) {
    try {
      // ignore: invalid_runtime_check_with_js_interop_types
      final error = e as JSObject;
      final code = error.getProperty<JSAny?>('code'.toJS);
      final message = error.getProperty<JSAny?>('message'.toJS);
      return (
        code.isA<JSNumber>() ? (code as JSNumber).toDartInt : null,
        message.isA<JSString>() ? (message as JSString).toDart : '$e',
      );
    } catch (_) {
      return (null, '$e');
    }
  }
}
