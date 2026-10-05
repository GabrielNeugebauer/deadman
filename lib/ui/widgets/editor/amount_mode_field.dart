import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../solana/deadman_api.dart';
import '../../../state/assets.dart';
import '../../../state/plan_draft.dart';
import '../../theme.dart';

final _numberChars = FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'));

/// "Share of what's left" or "Fixed amount", each with its own value: the
/// share as a large percent field with a words line and quick chips.
class AmountModeField extends StatelessWidget {
  const AmountModeField({
    super.key,
    required this.mode,
    required this.onMode,
    required this.share,
    required this.fixed,
    required this.mint,
    required this.onChanged,
    this.fixedError,
    this.shareFocus,
    this.fixedFocus,
  });

  final AmountMode mode;
  final ValueChanged<AmountMode> onMode;
  final TextEditingController share;
  final TextEditingController fixed;
  final String? mint;
  final VoidCallback onChanged;

  /// Shown once the user tried to finish with a bad fixed amount.
  final String? fixedError;
  final FocusNode? shareFocus;
  final FocusNode? fixedFocus;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      SegmentedButton<AmountMode>(
        showSelectedIcon: false,
        segments: const [
          ButtonSegment(
            value: AmountMode.percent,
            label: Text("Share of what's left", textAlign: TextAlign.center),
          ),
          ButtonSegment(
            value: AmountMode.fixed,
            label: Text('Fixed amount', textAlign: TextAlign.center),
          ),
        ],
        selected: {mode},
        onSelectionChanged: (s) => onMode(s.first),
      ),
      const SizedBox(height: 16),
      if (mode == AmountMode.percent) _share(context) else _fixed(),
    ],
  );

  Widget _share(BuildContext context) {
    final asset = assetSymbol(mint);
    final bps = parseShareBps(share.text);
    final words = shareWords(bps, asset);
    final big = Theme.of(context).textTheme.headlineMedium;
    void pick(String v) {
      share.text = v;
      onChanged();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          label:
              "Share of what's left, ${share.text} percent, "
              '${words ?? 'not valid'}',
          excludeSemantics: false,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Flexible(
                child: SizedBox(
                  width: 170,
                  child: TextField(
                    key: const ValueKey('share-field'),
                    controller: share,
                    focusNode: shareFocus,
                    onChanged: (_) => onChanged(),
                    textAlign: TextAlign.right,
                    style: big,
                    inputFormatters: [_numberChars],
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: const InputDecoration(hintText: '100'),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text('%', style: big),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Text(
          words ?? 'Enter a share from 0.01 to 100',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: words == null ? DmColors.danger : DmColors.text,
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 8,
          runSpacing: 4,
          children: [
            ChoiceChip(
              label: const Text('25%'),
              selected: bps == 2500,
              onSelected: (_) => pick('25'),
            ),
            ChoiceChip(
              label: const Text('50%'),
              selected: bps == 5000,
              onSelected: (_) => pick('50'),
            ),
            ChoiceChip(
              label: const Text('Everything left'),
              selected: bps == 10000,
              onSelected: (_) => pick('100'),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Text(
          'Shares are taken from what is left of this $asset when the payout '
          'runs, after earlier payouts.',
          style: const TextStyle(color: DmColors.muted, fontSize: 13),
        ),
      ],
    );
  }

  Widget _fixed() {
    final known = knownAsset(mint) != null;
    return TextField(
      key: const ValueKey('fixed-field'),
      controller: fixed,
      focusNode: fixedFocus,
      onChanged: (_) => onChanged(),
      inputFormatters: [_numberChars],
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      decoration: InputDecoration(
        labelText: 'Amount',
        hintText: known ? '0.00' : '0',
        suffixText: unitLabel(mint),
        helperText:
            "If the plan holds less when this payout runs, they get what's "
            "there.${known ? '' : ' Other tokens are entered in base units.'}",
        helperMaxLines: 3,
        errorText: fixedError,
        errorMaxLines: 3,
      ),
    );
  }
}
