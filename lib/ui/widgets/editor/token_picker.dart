import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config.dart';
import '../../../state/assets.dart';
import '../../../state/providers.dart';
import '../../../state/token_list.dart';
import '../../../state/vesting.dart' show isAddress;
import '../../format.dart';
import '../brand/brand.dart';
import '../nft.dart' show NftImage;

/// Picks a token from Jupiter's list, or any mint pasted in the search
/// field; null when cancelled. A picked listed token is remembered, so its
/// amounts read in whole units.
Future<String?> pickToken(BuildContext context, {String? initial}) =>
    showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => TokenPickerSheet(initial: initial),
    );

class TokenPickerSheet extends ConsumerStatefulWidget {
  const TokenPickerSheet({super.key, this.initial});

  final String? initial;

  @override
  ConsumerState<TokenPickerSheet> createState() => _TokenPickerSheetState();
}

class _TokenPickerSheetState extends ConsumerState<TokenPickerSheet> {
  late final _controller = TextEditingController(text: widget.initial ?? '');
  late String _query = _controller.text.trim();
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _changed(String text) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      if (mounted) setState(() => _query = text.trim());
    });
  }

  Future<void> _pick(ListedToken token) async {
    final warning = _warning(token);
    if (warning != null && !await _confirm(token, warning)) return;
    if (!mounted) return;
    rememberListedToken(ref.read(prefsProvider), token);
    Navigator.pop(context, token.mint);
  }

  Future<bool> _confirm(ListedToken token, String warning) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('Use ${displaySymbol(token.symbol)}?'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(warning, style: DMType.outfit(size: 14.5, height: 1.4)),
              const SizedBox(height: DMSpace.md),
              Text('Mint', style: DMType.label()),
              SelectableText(token.mint, style: DMType.data(color: DM.bone)),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Use it'),
            ),
          ],
        ),
      ) ??
      false;

  @override
  Widget build(BuildContext context) {
    final muted = DMType.outfit(size: 14, color: DM.dust, height: 1.4);
    final searching = _query.length >= 2;
    final results = searching
        ? ref.watch(tokenSearchProvider(_query))
        : ref.watch(topTokensProvider);
    final pasted = isAddress(_query) ? _query : null;
    final listed = results.value ?? const <ListedToken>[];
    final pastedListed = pasted != null && listed.any((t) => t.mint == pasted);
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.85,
        ),
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            DMSpace.gutter,
            0,
            DMSpace.gutter,
            DMSpace.gutter + MediaQuery.viewInsetsOf(context).bottom,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Other token',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: DMSpace.xs),
              Text(
                AppConfig.isMainnet
                    ? 'From the Jupiter token list. Anyone can make a token '
                          'with any name: check the mint before you fund.'
                    : 'Jupiter lists mainnet tokens, which don\'t exist on '
                          'devnet. Paste a devnet mint address to test.',
                style: muted,
              ),
              const SizedBox(height: DMSpace.md),
              TextField(
                key: const ValueKey('token-search'),
                controller: _controller,
                onChanged: _changed,
                autocorrect: false,
                style: DMType.mono(size: 14),
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search),
                  hintText: 'Name, symbol or mint address',
                ),
              ),
              const SizedBox(height: DMSpace.sm),
              if (pasted != null && !pastedListed)
                _TokenRow(
                  key: const ValueKey('token-pasted'),
                  title: 'Use ${short(pasted)}',
                  subtitle: 'Not on the list: amounts in base units',
                  onTap: () => Navigator.pop(
                    context,
                    knownAsset(pasted)?.mint ?? pasted,
                  ),
                ),
              Flexible(
                child: switch (results) {
                  AsyncData(:final value) when value.isEmpty => Padding(
                    padding: const EdgeInsets.symmetric(vertical: DMSpace.xl),
                    child: Text(
                      searching ? 'No token matches.' : 'No tokens listed.',
                      textAlign: TextAlign.center,
                      style: muted,
                    ),
                  ),
                  AsyncData(:final value) => ListView.builder(
                    shrinkWrap: true,
                    itemCount: value.length,
                    itemBuilder: (context, i) => _ListedRow(
                      value[i],
                      onTap: value[i].supported ? () => _pick(value[i]) : null,
                    ),
                  ),
                  AsyncError() => Padding(
                    padding: const EdgeInsets.symmetric(vertical: DMSpace.lg),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          "Couldn't load the token list. You can still paste "
                          'a mint address.',
                          textAlign: TextAlign.center,
                          style: muted,
                        ),
                        TextButton(
                          onPressed: () => searching
                              ? ref.invalidate(tokenSearchProvider(_query))
                              : ref.invalidate(topTokensProvider),
                          child: const Text('Retry'),
                        ),
                      ],
                    ),
                  ),
                  _ => const Padding(
                    padding: EdgeInsets.symmetric(vertical: DMSpace.xl),
                    child: Center(child: CircularProgressIndicator()),
                  ),
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// What to tell someone before they pick [token]; null when it is a
/// verified, unflagged token with a symbol of its own.
String? _warning(ListedToken token) {
  final real = lookalikeOf(token.mint, token.symbol);
  if (real != null) {
    return 'This is not the ${real.symbol} Deadman uses: it only looks like '
        'the same symbol. Choose ${real.symbol} from the chips instead, '
        'unless you are sure.';
  }
  if (token.suspicious) {
    return "Jupiter's audit flags this token as suspicious.";
  }
  if (!token.verified) {
    return "Jupiter hasn't verified this token. Anyone can make a token with "
        'any name and logo.';
  }
  return null;
}

class _ListedRow extends StatelessWidget {
  const _ListedRow(this.token, {this.onTap});

  final ListedToken token;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final tags = [
      if (token.unsupportedReason != null)
        (token.unsupportedReason!, DM.ash)
      else ...[
        if (token.lookalike) ('LOOKALIKE', DM.flatline),
        if (token.suspicious) ('SUSPICIOUS', DM.flatline),
        if (!token.verified) ('UNVERIFIED', DM.missed),
      ],
    ];
    return _TokenRow(
      key: ValueKey('token-${token.mint}'),
      icon: token.icon,
      title: displaySymbol(token.symbol),
      verified: token.trusted && !token.lookalike,
      subtitle: '${token.name} · ${short(token.mint)}',
      tags: tags,
      onTap: onTap,
    );
  }
}

class _TokenRow extends StatelessWidget {
  const _TokenRow({
    super.key,
    required this.title,
    required this.subtitle,
    this.icon,
    this.verified = false,
    this.tags = const [],
    this.onTap,
  });

  final String title;
  final String subtitle;
  final String? icon;
  final bool verified;
  final List<(String, Color)> tags;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Opacity(
    opacity: onTap == null ? 0.45 : 1,
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(DMRadius.tile),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: DMSpace.sm),
        child: Row(
          children: [
            ClipOval(child: NftImage(url: icon, size: 36)),
            const SizedBox(width: DMSpace.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: DMType.mono(
                            size: 14.5,
                            weight: FontWeight.w600,
                          ),
                        ),
                      ),
                      if (verified) ...[
                        const SizedBox(width: DMSpace.xxs),
                        const Icon(Icons.verified, size: 15, color: DM.pulse),
                      ],
                    ],
                  ),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: DMType.data(size: 12),
                  ),
                  if (tags.isNotEmpty)
                    Wrap(
                      spacing: DMSpace.sm,
                      children: [
                        for (final (text, color) in tags)
                          Text(text, style: DMType.chip(color)),
                      ],
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
