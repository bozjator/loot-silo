import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../core/preview_picker.dart' show previewExts;
import '../core/type_classifier.dart' show audioExts;
import '../state/dashboard.dart';
import 'cursors.dart';
import 'format.dart';
import 'tabs.dart';
import 'widgets/pixel_image.dart';
import 'widgets/thumb_size.dart';

/// The space between file result cards.
const fileResultsSpacing = 8.0;

/// The dashboard's Files view: one tile per file matching the search, an
/// image thumbnail or an icon, with the file's pack and folder below.
class FileResultsGrid extends StatelessWidget {
  const FileResultsGrid({
    super.key,
    required this.files,
    required this.tileSize,
    required this.onOpen,
    this.onOpenInNewTab,
    this.scale,
  });

  final List<FileTile> files;
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
    itemBuilder: (context, i) => OpenInNewTab(
      key: ValueKey('${files[i].pack.id}/${files[i].relPath}'),
      onOpenInNewTab: onOpenInNewTab == null
          ? null
          : () => onOpenInNewTab!(files[i]),
      child: _FileResultTile(file: files[i], onTap: () => onOpen(files[i])),
    ),
  );
}

class _FileResultTile extends StatelessWidget {
  const _FileResultTile({required this.file, required this.onTap});

  final FileTile file;
  final VoidCallback onTap;

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
        onTap: onTap,
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
                    child: previewExts.contains(ext)
                        ? PixelImage(File(p.join(file.pack.path, rel)))
                        : Icon(
                            audioExts.contains(ext)
                                ? Icons.graphic_eq
                                : Icons.description_outlined,
                            size: 40,
                            color: scheme.primary,
                          ),
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
