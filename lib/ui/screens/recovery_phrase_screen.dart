import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/actions.dart';
import '../widgets/brand/brand.dart';

/// Shows the 12-word phrase that backs this device's receiving profiles.
/// With [firstTime], the user must confirm writing it down.
class RecoveryPhrasePage extends ConsumerWidget {
  const RecoveryPhrasePage({
    super.key,
    required this.phrase,
    this.firstTime = false,
  });

  final String phrase;
  final bool firstTime;

  static Future<void> show(
    BuildContext context,
    String phrase, {
    bool firstTime = false,
  }) => Navigator.push(
    context,
    MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => RecoveryPhrasePage(phrase: phrase, firstTime: firstTime),
    ),
  );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    final words = phrase.split(' ');
    return PopScope(
      canPop: !firstTime,
      child: Scaffold(
        appBar: AppBar(
          automaticallyImplyLeading: !firstTime,
          title: const Text('Recovery phrase'),
        ),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(
              DMSpace.gutter,
              DMSpace.xs,
              DMSpace.gutter,
              DMSpace.xxxl,
            ),
            children: [
              // The app bar already names the page; only the first-time
              // instruction needs its own heading.
              if (firstTime) ...[
                Text(
                  'Write these 12 words down on paper, in order.',
                  style: t.titleLarge,
                ),
                const SizedBox(height: DMSpace.sm),
              ],
              Text(
                'Payouts to your claim codes land on keys made from this phrase. If this phone '
                'is lost, reset or the app is removed, the phrase is the only way to get '
                'those funds back (Security → Restore receiving profiles). '
                'Anyone who sees it can take them: never share it or store it online.',
                style: t.bodyMedium,
              ),
              const SizedBox(height: DMSpace.xl),
              DMCard(
                padding: const EdgeInsets.symmetric(
                  horizontal: DMSpace.lg,
                  vertical: DMSpace.sm,
                ),
                child: _WordGrid(words: words),
              ),
              const SizedBox(height: DMSpace.xxl),
              FilledButton(
                onPressed: () async {
                  if (firstTime) {
                    await ref.read(actionsProvider).confirmPhraseSaved();
                  }
                  if (context.mounted) Navigator.pop(context);
                },
                child: Text(firstTime ? 'I wrote it down' : 'Done'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Two columns read top to bottom (1–6, then 7–12), as on a paper backup
/// card; index in ash mono, word in bone mono.
class _WordGrid extends StatelessWidget {
  const _WordGrid({required this.words});

  final List<String> words;

  @override
  Widget build(BuildContext context) {
    final half = (words.length + 1) ~/ 2;
    Widget column(int from, int to) => Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = from; i < to; i++)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: DMSpace.sm),
              child: Row(
                children: [
                  SizedBox(
                    width: 28,
                    child: Text(
                      (i + 1).toString().padLeft(2, '0'),
                      style: DMType.mono(size: 12, color: DM.ash),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      words[i],
                      key: ValueKey('phrase-word-${i + 1}'),
                      style: DMType.mono(size: 16),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
    return Semantics(
      label: [for (final (i, w) in words.indexed) '${i + 1} $w'].join(', '),
      excludeSemantics: true,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          column(0, half),
          const SizedBox(width: DMSpace.lg),
          column(half, words.length),
        ],
      ),
    );
  }
}
