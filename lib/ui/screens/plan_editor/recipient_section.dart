import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../solana/deadman_api.dart';
import '../../../state/plan_draft.dart';
import '../../../state/vesting.dart';
import '../../theme.dart';
import '../../widgets/editor/plan_steps.dart';
import 'editor_providers.dart';

/// The recipient part of a payout or schedule editor: an address or claim
/// code, the address and rail state it drives, and a local name.
class Recipient {
  Recipient({String address = '', String name = '', this.rail = Rail.solana})
    : address = TextEditingController(text: address),
      name = TextEditingController(text: name);

  final TextEditingController address;
  final TextEditingController name;
  final focus = FocusNode();
  Rail rail;

  /// Rail picked by a pasted claim code.
  Rail? codeRail;

  /// Strips a claim-code prefix (`zcash:…`) and picks its rail.
  void applyClaimCode() {
    final (who, rail) = parseBeneficiary(address.text);
    if (rail == null) return;
    this.rail = rail;
    codeRail = rail;
    address.value = TextEditingValue(
      text: who,
      selection: TextSelection.collapsed(offset: who.length),
    );
  }

  String get value => address.text.trim();

  bool get valid => isAddress(value);

  void dispose() {
    address.dispose();
    name.dispose();
    focus.dispose();
  }
}

/// "1  Who gets it": address or claim code, local name, and rail tiles.
class RecipientSection extends StatelessWidget {
  const RecipientSection({
    super.key,
    required this.recipient,
    required this.onChanged,
    required this.fee,
    required this.privateLive,
    this.error,
    this.loading = false,
    this.notice,
  });

  final Recipient recipient;

  /// After an edit of the address, name or rail.
  final VoidCallback onChanged;
  final FeeInfo fee;
  final bool privateLive;
  final String? error;

  /// Beneficiary facts are loading.
  final bool loading;

  /// A warning about the recipient (B1).
  final PlanIssue? notice;

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim();
    if (text == null || text.isEmpty) return;
    recipient.address.text = text;
    recipient.applyClaimCode();
    onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final r = recipient;
    final private = r.rail != Rail.solana;
    return SectionCard(
      number: 1,
      title: 'Who gets it',
      children: [
        TextField(
          controller: r.address,
          focusNode: r.focus,
          onChanged: (_) {
            r.applyClaimCode();
            onChanged();
          },
          decoration: InputDecoration(
            labelText: private
                ? 'Their claim code'
                : 'Their wallet address or claim code',
            hintText: 'Solana address, or zcash:… / cloak:…',
            helperText: private
                ? 'Ask them to open Deadman → Security → Receive privately '
                      'and send you the code.'
                : null,
            helperMaxLines: 3,
            errorText: error,
            errorMaxLines: 2,
            suffixIcon: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (loading)
                  const SizedBox.square(
                    dimension: 12,
                    child: CircularProgressIndicator(strokeWidth: 1.5),
                  ),
                IconButton(
                  tooltip: 'Paste',
                  onPressed: _paste,
                  icon: const Icon(Icons.content_paste),
                ),
              ],
            ),
          ),
        ),
        if (r.codeRail != null && r.rail == r.codeRail)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.check_circle, size: 18, color: DmColors.alive),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    "Claim code recognised: they'll receive it privately via "
                    '${r.codeRail == Rail.cloak ? 'Cloak' : 'Zcash'}.',
                    style: const TextStyle(color: DmColors.alive, fontSize: 13),
                  ),
                ),
              ],
            ),
          ),
        if (notice != null) WarningTile.of(notice!),
        const SizedBox(height: 14),
        TextField(
          controller: r.name,
          maxLength: ContactNames.maxLength,
          onChanged: (_) => onChanged(),
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(
            labelText: 'Their name (optional)',
            helperText:
                'Only saved on this phone, to make your plan easier to read.',
            helperMaxLines: 4,
          ),
        ),
        const SizedBox(height: 10),
        const Text(
          'How it arrives',
          style: TextStyle(color: DmColors.muted, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        for (final rail in Rail.values)
          RailOptionTile(
            rail: rail,
            selected: r.rail == rail,
            feeLine: fee.railLine(rail),
            badge: rail != Rail.solana && !privateLive ? 'mainnet only' : null,
            onTap: () {
              r.rail = rail;
              onChanged();
            },
          ),
      ],
    );
  }
}
