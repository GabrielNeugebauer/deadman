import 'package:flutter/material.dart';

import '../../../state/assets.dart';
import '../../../state/vesting.dart' show isAddress;
import '../../format.dart';
import '../brand/brand.dart';
import '../feedback.dart';
import 'plan_steps.dart' show pickChip;

/// "Which money": one chip per asset in [assets], plus "More…" for any other
/// token when [allowOther].
class AssetChips extends StatelessWidget {
  const AssetChips({
    super.key,
    required this.mint,
    required this.onChanged,
    this.assets = presetAssets,
    this.allowOther = true,
  });

  final String? mint;
  final ValueChanged<String?> onChanged;
  final List<AssetInfo> assets;
  final bool allowOther;

  bool get _custom => !assets.any((a) => a.mint == mint);

  Future<void> _pickOther(BuildContext context) async {
    final controller = TextEditingController(text: _custom ? mint : '');
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Other token'),
        content: TextField(
          controller: controller,
          style: DMType.mono(size: 14),
          decoration: const InputDecoration(
            labelText: 'Token mint address',
            helperText: 'Fixed amounts for other tokens are in base units.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('OK'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (result == null || result.isEmpty) return;
    if (!isAddress(result)) {
      if (context.mounted) toast(context, 'Invalid mint address', error: true);
      return;
    }
    onChanged(knownAsset(result)?.mint ?? result);
  }

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: DMSpace.sm,
    runSpacing: DMSpace.xxs,
    children: [
      for (final a in assets)
        pickChip(
          label: a.symbol,
          mono: true,
          selected: mint == a.mint,
          onSelected: (_) => onChanged(a.mint),
        ),
      if (allowOther)
        pickChip(
          label: _custom ? 'Other: ${short(mint!)}' : 'More…',
          selected: _custom,
          onSelected: (_) => _pickOther(context),
        ),
    ],
  );
}
