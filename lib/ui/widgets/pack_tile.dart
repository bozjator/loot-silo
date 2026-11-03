import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../core/library_index.dart';
import '../format.dart';
import 'pixel_image.dart';

IconData iconForTypes(List<String> types) => switch (types.firstOrNull) {
  'music' => Icons.music_note,
  'sfx' => Icons.graphic_eq,
  'font' => Icons.font_download_outlined,
  '3d' => Icons.view_in_ar_outlined,
  'ui' => Icons.dashboard_outlined,
  'icons' => Icons.category_outlined,
  'vfx' => Icons.auto_awesome_outlined,
  'character' => Icons.person_outline,
  'environment' => Icons.landscape_outlined,
  _ => Icons.inventory_2_outlined,
};

/// One pack in the dashboard grid: preview, title, author and type chips.
class PackTile extends StatelessWidget {
  const PackTile({
    super.key,
    required this.pack,
    this.subPackCount = 0,
    this.onTap,
  });

  final PackRow pack;
  final int subPackCount;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final preview = pack.preview;
    return Card(
      clipBehavior: Clip.antiAlias,
      margin: EdgeInsets.zero,
      child: InkWell(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AspectRatio(
              aspectRatio: 4 / 3,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ColoredBox(
                    color: scheme.surfaceContainerHighest,
                    child: preview == null
                        ? _GeneratedPreview(pack: pack)
                        : Padding(
                            padding: const EdgeInsets.all(6),
                            child: PixelImage(
                              File(p.join(pack.path, preview)),
                              errorBuilder: (_) =>
                                  _GeneratedPreview(pack: pack),
                            ),
                          ),
                  ),
                  if (pack.isContainer)
                    Positioned(
                      left: 6,
                      top: 6,
                      child: _Pill(
                        icon: Icons.folder_copy_outlined,
                        text: 'Bundle · $subPackCount',
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    pack.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    pack.author ?? 'Unknown author',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 4,
                    runSpacing: 4,
                    children: [
                      for (final t in pack.types.take(3)) _TypeChip(t),
                      if (pack.types.length > 3)
                        _TypeChip('+${pack.types.length - 3}'),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// For packs without an image (audio, fonts …): a type icon and the count.
class _GeneratedPreview extends StatelessWidget {
  const _GeneratedPreview({required this.pack});

  final PackRow pack;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(
          iconForTypes(pack.types),
          size: 40,
          color: theme.colorScheme.primary,
        ),
        const SizedBox(height: 6),
        Text(
          '${formatCount(pack.fileCount)} files · ${formatBytes(pack.totalBytes)}',
          style: theme.textTheme.labelSmall,
        ),
      ],
    );
  }
}

class _TypeChip extends StatelessWidget {
  const _TypeChip(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: Theme.of(context).textTheme.labelSmall
            ?.copyWith(color: scheme.onSecondaryContainer),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: scheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: scheme.onTertiaryContainer),
          const SizedBox(width: 4),
          Text(
            text,
            style: Theme.of(context).textTheme.labelSmall
                ?.copyWith(color: scheme.onTertiaryContainer),
          ),
        ],
      ),
    );
  }
}
