import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/actions.dart';
import '../theme.dart';

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
          backgroundColor: DmColors.bg,
          automaticallyImplyLeading: !firstTime,
          title: const Text('Recovery phrase'),
        ),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
            children: [
              Text(
                firstTime
                    ? 'Write these 12 words down on paper, in order.'
                    : 'Your recovery phrase',
                style: t.titleLarge,
              ),
              const SizedBox(height: 8),
              const Text(
                'Payouts to your claim codes land on keys made from this phrase. If this phone '
                'is lost, reset or the app is removed, the phrase is the only way to get '
                'those funds back (Security → Restore receiving profiles). '
                'Anyone who sees it can take them: never share it or store it online.',
                style: TextStyle(color: DmColors.muted, height: 1.4),
              ),
              const SizedBox(height: 20),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: GridView.count(
                    crossAxisCount: 2,
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    childAspectRatio: 4,
                    children: [
                      for (final (i, w) in words.indexed)
                        Row(
                          children: [
                            SizedBox(
                              width: 28,
                              child: Text(
                                '${i + 1}.',
                                style: const TextStyle(color: DmColors.muted),
                              ),
                            ),
                            Text(
                              w,
                              style: const TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 16,
                              ),
                            ),
                          ],
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 24),
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
