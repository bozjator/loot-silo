import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../core/animation_detector.dart';
import '../core/preview_picker.dart' show previewExts;
import '../core/type_classifier.dart' show audioExts;
import '../state/dashboard.dart';
import 'cursors.dart';
import 'format.dart';
import 'tabs.dart';
import 'widgets/animated_sprite.dart';
import 'widgets/pixel_image.dart';
import 'widgets/thumb_size.dart';
import 'widgets/own_semantics_node.dart';

/// The space between file result cards.
const fileResultsSpacing = 8.0;

/// The dashboard's Files view: one tile per file matching the search, an
/// image thumbnail or an icon, with the file's pack and folder below. A
/// file that is an animation (M97) plays, with an animation badge.
class FileResultsGrid extends StatelessWidget {
  const FileResultsGrid({
    super.key,
    required this.files,
    required this.tileSize,
    required this.onOpen,
    this.onOpenInNewTab,
    this.scale,
    this.animations = const {},
    this.playAll = false,
    this.onNearEnd,
  });

  final List<FileTile> files;

  /// Called when a tile among the last [nearEnd] is built: time to load
  /// more files (the listing without search text).
  final VoidCallback? onNearEnd;

  /// How close to the end a built tile asks for more.
  static const nearEnd = 100;

  /// The hits that are animations, by (pack id, relative path).
  final Map<(String, String), SpriteAnim> animations;

  /// Every animation plays ("All"); otherwise only the hovered one.
  final bool playAll;
  final double tileSize;

  /// The slider's stops: columns follow them.
  final ThumbScale? scale;
  final ValueChanged<FileTile> onOpen;

  /// Middle-click or the right-click menu: the file's pack in a new tab.
  final ValueChanged<FileTile>? onOpenInNewTab;

  @override
  Widget build(BuildContext context) => GridView.builder(
    physics: const CtrlWheelPhysics(),
    padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
    // A square thumbnail over a name and a pack · folder line.
    gridDelegate: ThumbGridDelegate(
      maxTileWidth: tileSize,
      imageAspect: 1,
      footer: (_) => 44,
      spacing: fileResultsSpacing,
      mainAxisPadding: 20,
      scale: scale,
    ),
    itemCount: files.length,
    itemBuilder: (context, i) {
      if (onNearEnd case final more? when i >= files.length - nearEnd) {
        // Not during the build: loading changes the list.
        Future.microtask(more);
      }
      return _tile(i);
    },
  );

  Widget _tile(int i) => OpenInNewTab(
    key: ValueKey('${files[i].pack.id}/${files[i].relPath}'),
    onOpenInNewTab: onOpenInNewTab == null
        ? null
        : () => onOpenInNewTab!(files[i]),
    child: _FileResultTile(
      file: files[i],
      anim: animations[(files[i].pack.id, files[i].relPath)],
      playAll: playAll,
      onTap: () => onOpen(files[i]),
    ),
  );
}

class _FileResultTile extends StatefulWidget {
  const _FileResultTile({
    required this.file,
    required this.onTap,
    this.anim,
    this.playAll = false,
  });

  final FileTile file;
  final VoidCallback onTap;

  /// Set when the file is an animation: the tile plays it.
  final SpriteAnim? anim;
  final bool playAll;

  @override
  State<_FileResultTile> createState() => _FileResultTileState();
}

class _FileResultTileState extends State<_FileResultTile> {
  var _hover = false;

  FileTile get file => widget.file;

  /// The thumbnail: the animation playing (cropped like the Animations
  /// tab's cards), the image, or an icon.
  Widget _stage(ColorScheme scheme, String ext) {
    final path = p.join(file.pack.path, file.relPath);
    if (widget.anim case final a?) {
      final playing = widget.playAll || _hover;
      return Stack(
        fit: StackFit.expand,
        children: [
          a.kind == AnimKind.gif
              ? PixelImage(File(path), animate: playing)
              : AnimatedSprite(
                  packPath: file.pack.path,
                  anim: a,
                  playing: playing,
                ),
          Align(
            alignment: Alignment.topLeft,
            // Its own node: the card's Tooltip is an OverlayPortal too.
            child: OwnSemanticsNode(
              child: Tooltip(
                message: 'Animation',
                child: Container(
                  key: const ValueKey('animation-badge'),
                  padding: const EdgeInsets.all(2),
                  decoration: BoxDecoration(
                    color: scheme.surface.withValues(alpha: 0.8),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Icon(Icons.animation, size: 16, color: scheme.primary),
                ),
              ),
            ),
          ),
        ],
      );
    }
    return previewExts.contains(ext)
        ? PixelImage(File(path))
        : Icon(
            audioExts.contains(ext)
                ? Icons.graphic_eq
                : Icons.description_outlined,
            size: 40,
            color: scheme.primary,
          );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final rel = file.relPath;
    final ext = p.extension(rel).toLowerCase().replaceFirst('.', '');
    final folder = p.dirname(rel);
    return Card(
      clipBehavior: Clip.antiAlias,
      margin: EdgeInsets.zero,
      child: InkWell(
        mouseCursor: clickCursor,
        onTap: widget.onTap,
        onHover: widget.anim == null
            ? null
            : (h) {
                if (h != _hover) setState(() => _hover = h);
              },
        child: Tooltip(
          message: '${file.pack.title}/$rel',
          waitDuration: const Duration(milliseconds: 600),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: ColoredBox(
                  color: scheme.surfaceContainerHighest,
                  child: Padding(
                    padding: const EdgeInsets.all(6),
                    child: _stage(scheme, ext),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      prettyName(p.basename(rel)),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelLarge,
                    ),
                    Text(
                      folder == '.'
                          ? file.pack.title
                          : '${file.pack.title} · $folder',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The tile line for a pack whose file names match the search:
/// "12 files match: barrels_0.png, barrels_1.png…". Null when none do.
String? fileMatchLine(int count, List<String> examples) {
  if (count == 0) return null;
  final noun = count == 1 ? 'file matches' : 'files match';
  if (examples.isEmpty) return '$count $noun';
  final names = examples.take(2).map(p.basename).join(', ');
  return '$count $noun: $names${count > 2 ? '…' : ''}';
}

/// The tooltip of [fileMatchLine]: the count, then every example name (one
/// per line) and how many more there are.
String fileMatchTooltip(int count, List<String> examples) {
  final noun = count == 1 ? 'file matches' : 'files match';
  final more = count - examples.length;
  return [
    '$count $noun:',
    for (final e in examples) p.basename(e),
    if (more > 0) '… and $more more',
  ].join('\n');
}
