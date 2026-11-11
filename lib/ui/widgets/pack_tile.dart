import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../core/library_index.dart';
import '../../state/dashboard.dart';
import '../format.dart';
import 'animated_sprite.dart';
import 'favorite_star.dart';
import 'pixel_image.dart';
import '../cursors.dart';

/// The tallest a pack tile [width] px wide gets: its 4 : 3 preview plus
/// the footer with every optional line (two title lines, author, type
/// chips, file matches, tags) at the default text size, rounded up. The
/// dashboard's size stops keep this within the grid's height.
double packTileMaxHeight(double width) => width * 3 / 4 + packTileFooterMax;

/// See [packTileMaxHeight]: 18 padding + 40 title + 2 + 16 author + 6 +
/// 2 × 18 + 4 chips (they wrap on narrow tiles) + 2 × (6 + 16) optional
/// lines = 166, plus a little room.
const packTileFooterMax = 172.0;

IconData iconForTypes(List<String> types) => switch (types.firstOrNull) {
  'music' => Icons.music_note,
  'sfx' => Icons.graphic_eq,
  'font' => Icons.font_download_outlined,
  '3d' => Icons.view_in_ar_outlined,
  'material' => Icons.texture,
  'ui' => Icons.dashboard_outlined,
  'icons' => Icons.category_outlined,
  'vfx' => Icons.auto_awesome_outlined,
  'character' => Icons.person_outline,
  'environment' => Icons.landscape_outlined,
  _ => Icons.inventory_2_outlined,
};

/// One pack in the dashboard grid: preview, title, author and type chips.
///
/// Sprite-sheet previews show their first frame and play while hovered
/// (always, with [alwaysAnimate]); GIF previews do the same.
class PackTile extends StatefulWidget {
  const PackTile({
    super.key,
    required this.pack,
    this.subPackCount = 0,
    this.onTap,
    this.alwaysAnimate = false,
    this.showTags = false,
    this.fileMatches,
    this.fileMatchesTooltip,
    this.onFileMatchesTap,
    this.starred = false,
    this.onToggleStar,
  });

  final PackRow pack;
  final int subPackCount;
  final VoidCallback? onTap;
  final bool alwaysAnimate;

  /// Adds a line with the pack's tags, sorted, under the type chips (when
  /// the dashboard sorts by tag).
  final bool showTags;

  /// "12 files match: barrels_0.png, …" while searching, when file names
  /// match; clicking it calls [onFileMatchesTap].
  final String? fileMatches;

  /// The full list behind [fileMatches], shown on hover.
  final String? fileMatchesTooltip;
  final VoidCallback? onFileMatchesTap;

  /// The favorites star in the preview's top-right corner: shown on hover,
  /// always when [starred]; none without [onToggleStar].
  final bool starred;
  final VoidCallback? onToggleStar;

  @override
  State<PackTile> createState() => _PackTileState();
}

class _PackTileState extends State<PackTile> {
  var _hover = false;

  @override
  Widget build(BuildContext context) {
    final pack = widget.pack;
    final subPackCount = widget.subPackCount;
    final animate = _hover || widget.alwaysAnimate;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final preview = pack.preview;
    // MouseRegion, not InkWell.onHover: a disabled InkWell gets no hover.
    final card = Card(
      clipBehavior: Clip.antiAlias,
      margin: EdgeInsets.zero,
      child: InkWell(
        mouseCursor: clickCursor,
        onTap: widget.onTap,
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
                            child: pack.previewAnim != null
                                ? AnimatedSprite(
                                    packPath: pack.path,
                                    anim: pack.previewAnim!,
                                    playing: animate,
                                  )
                                : PixelImage(
                                    File(p.join(pack.path, preview)),
                                    animate: animate,
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
                  if (widget.onToggleStar case final toggle?
                      when _hover || widget.starred)
                    Positioned(
                      right: 4,
                      top: 4,
                      child: Material(
                        color: scheme.surface.withValues(alpha: 0.85),
                        shape: const CircleBorder(),
                        child: FavoriteStar(
                          key: const ValueKey('pack-star'),
                          starred: widget.starred,
                          onPressed: toggle,
                        ),
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
                      // Sorted, matching the Type sort's order.
                      for (final t in sortedTypes(pack.types).take(3))
                        _TypeChip(t),
                      if (pack.types.length > 3)
                        _TypeChip('+${pack.types.length - 3}'),
                    ],
                  ),
                  if (widget.fileMatches case final line?) ...[
                    const SizedBox(height: 6),
                    Tooltip(
                      message: widget.fileMatchesTooltip ?? line,
                      waitDuration: const Duration(milliseconds: 400),
                      child: MouseRegion(
                        cursor: SystemMouseCursors.click,
                        child: GestureDetector(
                          key: const ValueKey('file-matches'),
                          onTap: widget.onFileMatchesTap,
                          child: Row(
                            children: [
                              Icon(
                                Icons.manage_search,
                                size: 14,
                                color: scheme.primary,
                              ),
                              const SizedBox(width: 4),
                              Expanded(
                                child: Text(
                                  line,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    color: scheme.primary,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                  if (widget.showTags) ...[
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Icon(
                          Icons.sell_outlined,
                          size: 14,
                          color: scheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            pack.tags.isEmpty
                                ? 'No tags'
                                : sortedTags(pack.tags).join(', '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: card,
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
