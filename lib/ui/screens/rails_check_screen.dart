import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config.dart';
import '../../solana/deadman_api.dart';
import '../../state/private_rails.dart';
import '../../state/providers.dart';
import '../rules_format.dart';
import '../theme.dart';
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
    return Scaffold(
      appBar: AppBar(title: const Text('Private rails check')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
        children: [
          Text(
            'Runs the Cloak prover on this phone and asks NEAR Intents 1Click for a '
            'dry SOL → ZEC quote. Nothing is signed or sent.'
            '${live ? '' : ' Routing itself stays mainnet only; this build is on ${AppConfig.cluster}.'}',
            style: const TextStyle(color: DmColors.muted, height: 1.4),
          ),
          const SizedBox(height: 16),
          _CheckCard(
            rail: Rail.cloak,
            title: 'Cloak zero-knowledge proof',
            future: _cloak,
          ),
          const SizedBox(height: 12),
          _CheckCard(
            rail: Rail.zcash,
            title: 'Zcash quote (1Click)',
            future: _zcash,
          ),
          const SizedBox(height: 20),
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

class _CheckCard extends StatelessWidget {
  const _CheckCard({
    required this.rail,
    required this.title,
    required this.future,
  });

  final Rail rail;
  final String title;
  final Future<String>? future;

  @override
  Widget build(BuildContext context) => Card(
    child: FutureBuilder<String>(
      future: future,
      builder: (context, snap) {
        final done = snap.connectionState == ConnectionState.done;
        final (Widget icon, String status, Color color) = !done
            ? (
                const SizedBox.square(
                  dimension: 22,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                'Running…',
                DmColors.muted,
              )
            : snap.hasError
            ? (
                const Icon(Icons.cancel, color: DmColors.danger),
                'Fail: ${errorText(snap.error!)}',
                DmColors.danger,
              )
            : (
                const Icon(Icons.check_circle, color: DmColors.alive),
                'Pass: ${snap.data}',
                DmColors.alive,
              );
        return ListTile(
          leading: Icon(rail.icon, color: rail.color),
          title: Text(title),
          subtitle: Text(status, style: TextStyle(color: color, height: 1.35)),
          trailing: icon,
        );
      },
    ),
  );
}
