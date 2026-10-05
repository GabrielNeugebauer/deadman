import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config.dart';
import '../../state/providers.dart';
import '../../wallet/web_wallet_bridge.dart';
import '../widgets/brand/brand.dart';
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
}

/// Lets the user pick Phantom or Solflare. Returns the installed wallet
/// chosen, or null when dismissed; missing wallets link to their download.
Future<WalletKind?> showWalletPicker(BuildContext context) =>
    showModalBottomSheet<WalletKind>(
      context: context,
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
    final t = Theme.of(context).textTheme;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          DMSpace.gutter,
          0,
          DMSpace.gutter,
          DMSpace.lg,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Connect a wallet', style: t.titleLarge),
            const SizedBox(height: DMSpace.xs),
            Text(
              'Your wallet owns your plans and approves every change. Deadman never sees its keys.',
              style: t.bodyMedium,
            ),
            const SizedBox(height: DMSpace.xl),
            FutureBuilder<List<WebWallet>>(
              future: _found,
              builder: (context, snap) {
                if (snap.connectionState != ConnectionState.done) {
                  return const Padding(
                    padding: EdgeInsets.symmetric(vertical: DMSpace.xxl),
                    child: Center(child: CircularProgressIndicator()),
                  );
                }
                final found = snap.data ?? const <WebWallet>[];
                return DMListGroup(
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
            const SizedBox(height: DMSpace.sm),
            TextButton.icon(
              onPressed: () => setState(() => _found = _discover()),
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('Just installed one? Check again'),
            ),
            if (!AppConfig.isMainnet) ...[
              const SizedBox(height: DMSpace.xs),
              Text(
                'This preview runs on Solana ${AppConfig.cluster}: switch your wallet to '
                '${AppConfig.cluster} (testnet mode) before approving.',
                textAlign: TextAlign.center,
                style: t.bodySmall,
              ),
            ],
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
    return DMListRow(
      leading: _WalletIcon(kind: kind, dataUri: wallet?.icon),
      title: kind.label,
      subtitle: !installed
          ? 'Not installed in this browser'
          : last
          ? 'Last used'
          : 'Detected',
      trailing: installed
          ? const Icon(Icons.chevron_right, color: DM.sub)
          : TextButton.icon(
              onPressed: install,
              icon: const Icon(Icons.open_in_new, size: 16),
              label: const Text('Install'),
            ),
      onTap: installed ? () => Navigator.pop(context, kind) : install,
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
    // Wallets' own brand colors stay out: purple means locked here.
    final letter = Container(
      width: 36,
      height: 36,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: DM.raise,
        borderRadius: BorderRadius.circular(9),
      ),
      child: Text(
        kind.label[0],
        style: DMType.outfit(size: 17, weight: FontWeight.w700),
      ),
    );
    final bytes = _bitmap(dataUri);
    if (bytes == null) return letter;
    return ClipRRect(
      borderRadius: BorderRadius.circular(9),
      child: Image.memory(
        bytes,
        width: 36,
        height: 36,
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
        color: DM.void_,
        child: Center(
          child: Container(
            width: maxWidth,
            foregroundDecoration: const BoxDecoration(
              border: Border.symmetric(vertical: BorderSide(color: DM.line)),
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
  Widget build(BuildContext context) =>
      const DMTag(label: 'Web', icon: Icons.language);
}

/// What the browser build leaves to the Android app, with a link to it.
class AndroidAppCard extends ConsumerWidget {
  const AndroidAppCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => DMCard(
    padding: EdgeInsets.zero,
    child: DMListRow(
      leading: const IconTile(icon: Icons.android),
      title: 'Get the Android app',
      subtitle:
          'Check-in reminders, one-tap check-ins without a wallet popup, the '
          'biometric lock, and private routing through Cloak and Zcash run in '
          'the Android app.',
      monoSubtitle: false,
      trailing: const Icon(Icons.open_in_new, size: 20, color: DM.sub),
      onTap: () => ref.read(openUrlProvider)(AppConfig.androidAppUrl),
    ),
  );
}

/// Label of a private-route button that can't run here.
String routeOffLabel(String rail, {required bool web}) =>
    'Route via $rail: ${web ? 'Android app' : 'mainnet only'}';
