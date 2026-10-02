import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/actions.dart';
import '../theme.dart';
import '../widgets/feedback.dart';

class WelcomeScreen extends ConsumerStatefulWidget {
  const WelcomeScreen({super.key});

  @override
  ConsumerState<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends ConsumerState<WelcomeScreen> {
  bool _busy = false;

  Future<void> _connect() async {
    setState(() => _busy = true);
    await runGuarded(context, () => ref.read(actionsProvider).connect());
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 32, 24, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(
                Icons.monitor_heart_outlined,
                color: DmColors.alive,
                size: 40,
              ),
              const SizedBox(height: 28),
              Text('Deadman', style: t.displayLarge),
              const SizedBox(height: 12),
              Text(
                'The safety net for your self-custody. If you go silent, get coerced, or lose your phone, your crypto still ends up where you decided.',
                style: t.bodyLarge?.copyWith(
                  color: DmColors.muted,
                  height: 1.45,
                ),
              ),
              const SizedBox(height: 36),
              const _Threat(
                icon: Icons.hourglass_bottom,
                title: 'Silence',
                body:
                    'Miss your check-ins and your vault passes to your heirs.',
                color: DmColors.alive,
              ),
              const _Threat(
                icon: Icons.front_hand_outlined,
                title: 'Coercion',
                body: 'A duress PIN silently freezes your vault while the app looks normal.',
                color: DmColors.warn,
              ),
              const _Threat(
                icon: Icons.phonelink_erase,
                title: 'Loss',
                body: 'Your device key can only check in or lock. It can never move funds.',
                color: DmColors.plus,
              ),
              const Spacer(),
              FilledButton.icon(
                onPressed: _busy ? null : _connect,
                icon: _busy
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.lock_outline),
                label: const Text('Connect Seed Vault wallet'),
              ),
              const SizedBox(height: 12),
              Center(
                child: Text(
                  'Devnet preview · unaudited',
                  style: t.bodySmall?.copyWith(color: DmColors.muted),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Threat extends StatelessWidget {
  const _Threat({
    required this.icon,
    required this.title,
    required this.body,
    required this.color,
  });

  final IconData icon;
  final String title;
  final String body;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: color, size: 22),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 16,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  body,
                  style: const TextStyle(color: DmColors.muted, height: 1.35),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
