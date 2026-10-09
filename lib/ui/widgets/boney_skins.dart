import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/boney.dart';
import '../../state/boney_skin.dart';
import '../../state/boney_skins.dart';
import 'brand/brand.dart';

/// [BoneyFigure] wearing the skin the owner picked.
class SkinnedBoney extends ConsumerWidget {
  const SkinnedBoney({super.key, required this.mood, this.size = 48});

  final BoneyMood mood;
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) =>
      BoneyFigure(mood: mood, size: size, skin: ref.watch(activeSkinProvider));
}

/// Picks Boney's skin: none, or one the wallet holds the Boney NFT of.
/// Locked skins say which NFT unlocks them.
class BoneySkinPicker extends ConsumerWidget {
  const BoneySkinPicker({super.key, required this.mood});

  /// Boney's mood now, so each choice previews as he is.
  final BoneyMood mood;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final owned = ref.watch(ownedSkinsProvider);
    final have = owned.value ?? const <BoneySkin>{};
    final worn = ref.watch(activeSkinProvider);
    final picker = ref.read(boneySkinProvider.notifier);
    final locked = [
      for (final s in BoneySkin.values)
        if (!have.contains(s)) s.label,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('SKINS', style: DMType.label()),
        const SizedBox(height: DMSpace.sm),
        Wrap(
          spacing: DMSpace.sm,
          runSpacing: DMSpace.sm,
          children: [
            _SkinTile(
              label: 'None',
              mood: mood,
              selected: worn == null,
              onTap: () => picker.choose(null),
            ),
            for (final s in BoneySkin.values)
              _SkinTile(
                key: ValueKey('skin-${s.id}'),
                label: s.label,
                mood: mood,
                skin: s,
                selected: worn == s,
                onTap: have.contains(s) ? () => picker.choose(s) : null,
              ),
          ],
        ),
        const SizedBox(height: DMSpace.sm),
        Text(
          owned.isLoading
              ? 'Checking your wallet for Boney NFTs…'
              : locked.isEmpty
              ? 'Every skin unlocked. Boney wears it on the home-screen widget '
                    'too.'
              : 'Hold a Boney ${locked.join(', ')} NFT to unlock '
                    '${locked.length == 1 ? 'it' : 'them'}. Boney wears your '
                    'skin on the home-screen widget too.',
          style: DMType.outfit(size: 13.5, color: DM.dust, height: 1.4),
        ),
      ],
    );
  }
}

class _SkinTile extends StatelessWidget {
  const _SkinTile({
    super.key,
    required this.label,
    required this.mood,
    required this.selected,
    required this.onTap,
    this.skin,
  });

  final String label;
  final BoneyMood mood;
  final BoneySkin? skin;
  final bool selected;

  /// Null: locked.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final locked = onTap == null;
    return Semantics(
      button: true,
      selected: selected,
      enabled: !locked,
      label: locked ? '$label, locked' : label,
      excludeSemantics: true,
      child: Material(
        color: selected ? mood.status.tint : DM.pit,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(DMRadius.button),
          side: BorderSide(color: selected ? mood.status.color : DM.line),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 72),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: DMSpace.sm,
                vertical: DMSpace.sm,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Opacity(
                    opacity: locked ? 0.35 : 1,
                    child: BoneyFigure(
                      mood: mood,
                      size: 40,
                      animate: false,
                      skin: skin,
                    ),
                  ),
                  const SizedBox(height: DMSpace.xs),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (locked) ...[
                        const PixelArt(
                          PixelSprites.lock,
                          size: 10,
                          color: DM.ash,
                        ),
                        const SizedBox(width: 4),
                      ],
                      Text(
                        label,
                        style: DMType.outfit(
                          size: 12.5,
                          color: locked ? DM.ash : DM.bone,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
