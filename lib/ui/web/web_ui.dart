import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config.dart';
import '../../state/providers.dart';
import '../../wallet/web_wallet_bridge.dart';
import '../theme.dart';
import 'open_url_stub.dart' if (dart.library.js_interop) 'open_url_web.dart';

/// Opens a link in a new browser tab. Overridden in tests.
final openUrlProvider = Provider<void Function(String url)>(
  (ref) => openExternalUrl,
);

extension WalletKindUi on WalletKind {
  String get downloadUrl => switch (this) {
    WalletKind.phantom => 'https://phantom.app/download',
    WalletKind.solflare => 'https://solflare.com/download',
  };

  Color get color => switch (this) {
    WalletKind.phantom => const Color(0xFFAB9FF2),
    WalletKind.solflare => const Color(0xFFFC7227),
  };
}

/// Lets the user pick Phantom or Solflare. Returns the installed wallet
/// chosen, or null when dismissed; missing wallets link to their download.
Future<WalletKind?> showWalletPicker(BuildContext context) =>
    showModalBottomSheet<WalletKind>(
      context: context,
      backgroundColor: DmColors.surface,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => const WalletPickerSheet(),
    );

class WalletPickerSheet extends ConsumerStatefulWidget {
  const WalletPickerSheet({super.key});

  @override
  ConsumerState<WalletPickerSheet> createState() => _WalletPickerSheetState();
}

class _WalletPickerSheetState extends ConsumerState<WalletPickerSheet> {
  late Future<List<WebWallet>> _found = _discover();

  Future<List<WebWallet>> _discover() =>
      ref.read(webWalletProvider).available();

  @override
  Widget build(BuildContext context) {
    final last = ref.read(webWalletProvider).lastKind;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Connect a wallet',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 4),
            const Text(
              'Your wallet owns your plans and approves every change. Deadman never sees its keys.',
              style: TextStyle(color: DmColors.muted, height: 1.35),
            ),
            const SizedBox(height: 16),
            FutureBuilder<List<WebWallet>>(
              future: _found,
              builder: (context, snap) {
                if (snap.connectionState != ConnectionState.done) {
                  return const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Center(child: CircularProgressIndicator()),
                  );
                }
                final found = snap.data ?? const <WebWallet>[];
                return Column(
                  children: [
                    for (final kind in WalletKind.values)
                      _WalletRow(
                        kind: kind,
                        wallet: found.where((w) => w.kind == kind).firstOrNull,
                        last: kind == last,
                      ),
                  ],
                );
              },
            ),
            TextButton.icon(
              onPressed: () => setState(() => _found = _discover()),
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('Just installed one? Check again'),
            ),
            if (!AppConfig.isMainnet)
              const Text(
                'This preview runs on Solana ${AppConfig.cluster}: switch your wallet to '
                '${AppConfig.cluster} (testnet mode) before approving.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: DmColors.muted,
                  fontSize: 12,
                  height: 1.35,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _WalletRow extends ConsumerWidget {
  const _WalletRow({
    required this.kind,
    required this.wallet,
    required this.last,
  });

  final WalletKind kind;

  /// Null when not installed in this browser.
  final WebWallet? wallet;
  final bool last;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final installed = wallet != null;
    void install() => ref.read(openUrlProvider)(kind.downloadUrl);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Card(
        color: DmColors.raised,
        child: ListTile(
          contentPadding: const EdgeInsets.fromLTRB(14, 6, 10, 6),
          leading: _WalletIcon(kind: kind, dataUri: wallet?.icon),
          title: Text(kind.label),
          subtitle: Text(
            !installed
                ? 'Not installed in this browser'
                : last
                ? 'Last used'
                : 'Detected',
            style: TextStyle(
              color: installed ? DmColors.alive : DmColors.muted,
              fontSize: 13,
            ),
          ),
          trailing: installed
              ? const Icon(Icons.chevron_right)
              : TextButton.icon(
                  onPressed: install,
                  icon: const Icon(Icons.open_in_new, size: 16),
                  label: const Text('Install'),
                ),
          onTap: installed ? () => Navigator.pop(context, kind) : install,
        ),
      ),
    );
  }
}

/// The wallet's own bitmap icon when it announced one, else its initial.
class _WalletIcon extends StatelessWidget {
  const _WalletIcon({required this.kind, this.dataUri});

  final WalletKind kind;
  final String? dataUri;

  static Uint8List? _bitmap(String? uri) {
    if (uri == null) return null;
    try {
      final data = UriData.parse(uri);
      // SVG icons can't go through Image.memory.
      if (!RegExp(r'^image/(png|jpe?g|webp|gif)$').hasMatch(data.mimeType)) {
        return null;
      }
      return data.contentAsBytes();
    } on FormatException {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final letter = Container(
      width: 40,
      height: 40,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: kind.color.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        kind.label[0],
        style: TextStyle(
          color: kind.color,
          fontWeight: FontWeight.w700,
          fontSize: 18,
        ),
      ),
    );
    final bytes = _bitmap(dataUri);
    if (bytes == null) return letter;
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Image.memory(
        bytes,
        width: 40,
        height: 40,
        errorBuilder: (_, _, _) => letter,
      ),
    );
  }
}

/// On a wide browser window, keeps the phone-shaped app in a centered
/// column instead of stretching it edge to edge.
class WebFrame extends StatelessWidget {
  const WebFrame({super.key, required this.child});

  static const maxWidth = 520.0;

  final Widget child;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      if (box.maxWidth <= maxWidth + 48) return child;
      final mq = MediaQuery.of(context);
      return ColoredBox(
        color: DmColors.bg,
        child: Center(
          child: Container(
            width: maxWidth,
            foregroundDecoration: const BoxDecoration(
              border: Border.symmetric(
                vertical: BorderSide(color: DmColors.line),
              ),
            ),
            child: ClipRect(
              child: MediaQuery(
                data: mq.copyWith(size: Size(maxWidth, mq.size.height)),
                child: child,
              ),
            ),
          ),
        ),
      );
    },
  );
}

/// Marks the browser build in headers.
class WebBadge extends StatelessWidget {
  const WebBadge({super.key});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
    decoration: BoxDecoration(
      color: DmColors.plus.withValues(alpha: 0.14),
      borderRadius: BorderRadius.circular(20),
    ),
    child: const Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.language, size: 14, color: DmColors.plus),
        SizedBox(width: 5),
        Text(
          'Web',
          style: TextStyle(
            color: DmColors.plus,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    ),
  );
}

/// What the browser build leaves to the Android app, with a link to it.
class AndroidAppCard extends ConsumerWidget {
  const AndroidAppCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => Card(
    child: ListTile(
      leading: const Icon(Icons.android, color: DmColors.alive),
      title: const Text('Get the Android app'),
      subtitle: const Text(
        'Check-in reminders, one-tap check-ins without a wallet popup, the '
        'biometric lock, and private routing through Cloak and Zcash run in '
        'the Android app.',
      ),
      isThreeLine: true,
      trailing: const Icon(Icons.open_in_new, size: 20),
      onTap: () => ref.read(openUrlProvider)(AppConfig.androidAppUrl),
    ),
  );
}

/// Label of a private-route button that can't run here.
String routeOffLabel(String rail, {required bool web}) =>
    'Route via $rail: ${web ? 'Android app' : 'mainnet only'}';
