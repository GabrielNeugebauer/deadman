import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../solana/deadman_api.dart';
import '../../../state/plan_draft.dart';
import '../../../state/vesting.dart';
import '../../widgets/brand/brand.dart';
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

/// "Who gets it": address or claim code, a local name and the rail cards,
/// as on the brand book's "New payout" mockup.
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
    return EditorSection(
      first: true,
      sprite: PixelSprites.heart,
      title: 'Who gets it',
      children: [
        LabeledField(
          label: private ? 'Their claim code' : 'Wallet address or claim code',
          child: TextField(
            key: const ValueKey('recipient-address'),
            controller: r.address,
            focusNode: r.focus,
            onChanged: (_) {
              r.applyClaimCode();
              onChanged();
            },
            style: DMType.mono(size: 14),
            decoration: InputDecoration(
              hintText: private ? 'zcash:… or cloak:…' : 'Paste an address',
              hintStyle: DMType.mono(size: 14, color: DM.ash),
              helperText: private
                  ? 'Ask them to open Deadman → Security → Receive privately '
                        'and send you the code.'
                  : null,
              helperMaxLines: 3,
              errorText: error,
              errorMaxLines: 2,
              suffixIcon: Padding(
                padding: const EdgeInsets.only(right: DMSpace.xs),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (loading)
                      const Padding(
                        padding: EdgeInsets.only(right: DMSpace.sm),
                        child: SizedBox.square(
                          dimension: 12,
                          child: CircularProgressIndicator(strokeWidth: 1.5),
                        ),
                      ),
                    _PasteButton(onPressed: _paste),
                  ],
                ),
              ),
            ),
          ),
        ),
        if (r.codeRail != null && r.rail == r.codeRail)
          Padding(
            padding: const EdgeInsets.only(top: DMSpace.sm),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.check_circle, size: 18, color: DM.pulse),
                const SizedBox(width: DMSpace.sm),
                Expanded(
                  child: Text(
                    "Claim code recognised: they'll receive it privately via "
                    '${r.codeRail == Rail.cloak ? 'Cloak' : 'Zcash'}.',
                    style: DMType.outfit(
                      size: 14,
                      color: DM.bone,
                      height: 1.35,
                    ),
                  ),
                ),
              ],
            ),
          ),
        if (notice != null) WarningTile.of(notice!),
        const SizedBox(height: DMSpace.xl),
        LabeledField(
          label: 'Their name (optional)',
          child: TextField(
            key: const ValueKey('recipient-name'),
            controller: r.name,
            maxLength: ContactNames.maxLength,
            onChanged: (_) => onChanged(),
            textCapitalization: TextCapitalization.words,
            decoration: InputDecoration(
              hintText: 'e.g. Mom',
              helperText:
                  'Only saved on this phone, to make your plan easier to read.',
              helperMaxLines: 4,
              counterStyle: DMType.mono(size: 12, color: DM.ash),
            ),
          ),
        ),
        const SizedBox(height: DMSpace.xl),
        const FieldLabel('How it arrives'),
        for (final rail in Rail.values)
          RailOptionTile(
            rail: rail,
            selected: r.rail == rail,
            feeLine: railFeeLine(fee, rail),
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

/// The square paste button inside the address field.
class _PasteButton extends StatelessWidget {
  const _PasteButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: 'Paste',
    onPressed: onPressed,
    style: IconButton.styleFrom(
      backgroundColor: DM.grave,
      foregroundColor: DM.bone,
      fixedSize: const Size.square(44),
      minimumSize: const Size.square(44),
      tapTargetSize: MaterialTapTargetSize.padded,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(DMRadius.tile),
      ),
    ),
    icon: const Icon(Icons.content_paste_rounded, size: 20),
  );
}
