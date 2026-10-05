import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/actions.dart';
import '../../state/providers.dart';
import '../web/web_ui.dart';
import '../widgets/brand/brand.dart';
import '../widgets/feedback.dart';

class WelcomeScreen extends ConsumerStatefulWidget {
  const WelcomeScreen({super.key});

  @override
  ConsumerState<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends ConsumerState<WelcomeScreen> {
  bool _busy = false;

  Future<void> _connect() async {
    final actions = ref.read(actionsProvider);
    if (ref.read(isWebProvider)) {
      final kind = await showWalletPicker(context);
      if (kind == null || !mounted) return;
      setState(() => _busy = true);
      await runGuarded(context, () => actions.connectWeb(kind));
    } else {
      setState(() => _busy = true);
      await runGuarded(context, actions.connect);
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final web = ref.watch(isWebProvider);
    return Scaffold(
      body: SafeArea(
        // Scrolls when the window is shorter than the content (browsers).
        child: LayoutBuilder(
          builder: (context, box) => SingleChildScrollView(
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: box.maxHeight),
              child: IntrinsicHeight(child: _content(t, web)),
            ),
          ),
        ),
      ),
    );
  }

  Widget _content(TextTheme t, bool web) => Padding(
    padding: const EdgeInsets.fromLTRB(
      DMSpace.gutter,
      DMSpace.xxl,
      DMSpace.gutter,
      DMSpace.xxl,
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const DeadmanLockup(height: 28),
            const Spacer(),
            if (web) const WebBadge(),
          ],
        ),
        const SizedBox(height: 56),
        Semantics(
          header: true,
          child: Text(
            'The safety net for your self-custody.',
            style: t.displaySmall,
          ),
        ),
        const SizedBox(height: DMSpace.md),
        Text(
          'If you go silent, get coerced, or lose your phone, your crypto '
          'still ends up where you decided.',
          style: t.bodyLarge?.copyWith(color: DM.sub),
        ),
        const SizedBox(height: DMSpace.xxxl),
        const DMListGroup(
          children: [
            DMListRow(
              leading: IconTile(icon: Icons.hourglass_bottom),
              title: 'Silence',
              monoSubtitle: false,
              subtitle:
                  'Miss your check-ins and your vault passes to your heirs.',
            ),
            DMListRow(
              leading: IconTile(icon: Icons.front_hand_outlined),
              title: 'Coercion',
              monoSubtitle: false,
              subtitle: 'A duress PIN silently freezes your vault while the app looks normal.',
            ),
            DMListRow(
              leading: IconTile(icon: Icons.phonelink_erase),
              title: 'Loss',
              monoSubtitle: false,
              subtitle: 'Your device key can only check in or lock. It can never move funds.',
            ),
          ],
        ),
        const Spacer(),
        const SizedBox(height: DMSpace.xxl),
        FilledButton(
          onPressed: _busy ? null : _connect,
          child: _busy
              ? const SizedBox.square(
                  key: ValueKey('connect-busy'),
                  dimension: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: DM.sub,
                  ),
                )
              : Text(
                  web
                      ? 'Connect Phantom or Solflare'
                      : 'Connect Seed Vault wallet',
                ),
        ),
        const SizedBox(height: DMSpace.md),
        MonoLabel(
          web
              ? 'Web preview · devnet · unaudited'
              : 'Devnet preview · unaudited',
          textAlign: TextAlign.center,
        ),
      ],
    ),
  );
}
