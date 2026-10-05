import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config.dart';
import '../../solana/deadman_api.dart';
import '../../state/private_rails.dart';
import '../../state/providers.dart';
import '../rules_format.dart';
import '../widgets/brand/brand.dart';
import '../widgets/feedback.dart';

/// Diagnostics for the private rails that move no funds, so they run on
/// devnet builds too: a Cloak proof on this phone and a dry 1Click quote.
class RailsCheckScreen extends ConsumerStatefulWidget {
  const RailsCheckScreen({super.key});

  @override
  ConsumerState<RailsCheckScreen> createState() => _RailsCheckScreenState();
}

class _RailsCheckScreenState extends ConsumerState<RailsCheckScreen> {
  Future<String>? _cloak;
  Future<String>? _zcash;

  @override
  void initState() {
    super.initState();
    _start();
  }

  void _start() {
    final check = ref.read(railsCheckProvider);
    _cloak = check.cloak();
    _zcash = check.zcash();
  }

  @override
  Widget build(BuildContext context) {
    final live = ref.watch(privateRailsLiveProvider);
    final t = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Private rails check')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
          DMSpace.gutter,
          DMSpace.md,
          DMSpace.gutter,
          DMSpace.xxxl,
        ),
        children: [
          Text(
            'Runs the Cloak prover on this phone and asks NEAR Intents 1Click for a '
            'dry SOL → ZEC quote. Nothing is signed or sent.'
            '${live ? '' : ' Routing itself stays mainnet only; this build is on ${AppConfig.cluster}.'}',
            style: t.bodyMedium,
          ),
          const SizedBox(height: DMSpace.xl),
          DMListGroup(
            children: [
              _CheckRow(
                rail: Rail.cloak,
                title: 'Cloak zero-knowledge proof',
                future: _cloak,
              ),
              _CheckRow(
                rail: Rail.zcash,
                title: 'Zcash quote (1Click)',
                future: _zcash,
              ),
            ],
          ),
          const SizedBox(height: DMSpace.xl),
          OutlinedButton.icon(
            onPressed: () => setState(_start),
            icon: const Icon(Icons.refresh),
            label: const Text('Run again'),
          ),
        ],
      ),
    );
  }
}

/// One check: the rail, its PASS / FAIL chip, and the measured detail or
/// the error in mono.
class _CheckRow extends StatelessWidget {
  const _CheckRow({
    required this.rail,
    required this.title,
    required this.future,
  });

  final Rail rail;
  final String title;
  final Future<String>? future;

  @override
  Widget build(BuildContext context) => FutureBuilder<String>(
    future: future,
    builder: (context, snap) {
      final done = snap.connectionState == ConnectionState.done;
      final (Widget status, String detail) = !done
          ? (
              const SizedBox.square(
                dimension: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              'Running…',
            )
          : snap.hasError
          ? (
              const StatusChip(DMStatus.due, label: 'Fail', dense: true),
              errorText(snap.error!),
            )
          : (
              const StatusChip(DMStatus.onTrack, label: 'Pass', dense: true),
              snap.data ?? '',
            );
      return Padding(
        padding: const EdgeInsets.all(DMSpace.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                IconTile(icon: rail.icon),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    title,
                    style: DMType.outfit(size: 16, weight: FontWeight.w600),
                  ),
                ),
                const SizedBox(width: DMSpace.md),
                status,
              ],
            ),
            const SizedBox(height: DMSpace.md),
            Text(detail, style: DMType.data()),
          ],
        ),
      );
    },
  );
}
