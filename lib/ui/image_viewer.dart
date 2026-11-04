import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../core/animation_detector.dart' show readImageSize;
import '../state/providers.dart';
import 'format.dart';
import 'reveal.dart';
import 'widgets/pixel_image.dart';

/// Opens [images] (paths relative to [packPath]) in the [ImageViewer] at
/// [index], over a dark backdrop.
Future<void> showImageViewer(
  BuildContext context, {
  required String packPath,
  required List<String> images,
  required int index,
  Map<String, int> sizes = const {},
}) => showDialog<void>(
  context: context,
  barrierColor: Colors.black87,
  builder: (_) => ImageViewer(
    packPath: packPath,
    images: images,
    initialIndex: index,
    sizes: sizes,
  ),
);

/// Near full-window image viewer: fits the image keeping its proportions,
/// wheel zoom and drag to pan (double-click resets), prev/next by button or
/// ←/→ within the list it was opened from.
class ImageViewer extends ConsumerStatefulWidget {
  const ImageViewer({
    super.key,
    required this.packPath,
    required this.images,
    required this.initialIndex,
    this.sizes = const {},
  });

  final String packPath;
  final List<String> images;
  final int initialIndex;

  /// File sizes by relative path; missing ones are read from disk.
  final Map<String, int> sizes;

  @override
  ConsumerState<ImageViewer> createState() => _ImageViewerState();
}

class _ImageViewerState extends ConsumerState<ImageViewer> {
  late var _index = widget.initialIndex.clamp(0, widget.images.length - 1);
  final _transform = TransformationController();

  @override
  void dispose() {
    _transform.dispose();
    super.dispose();
  }

  bool get _hasPrev => _index > 0;
  bool get _hasNext => _index < widget.images.length - 1;

  /// Stops at the ends rather than wrapping around.
  void _go(int delta) {
    final next = _index + delta;
    if (next < 0 || next >= widget.images.length) return;
    setState(() {
      _index = next;
      _transform.value = Matrix4.identity();
    });
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      _go(-1);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
      _go(1);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  String _details(String rel, File file) {
    final dims = readImageSize(file.path);
    int? size = widget.sizes[rel];
    if (size == null) {
      try {
        size = file.lengthSync();
      } on FileSystemException {
        // Gone since the scan; show what we have.
      }
    }
    return [
      rel,
      if (dims != null) '${dims.$1} × ${dims.$2} px',
      if (size != null) formatBytes(size),
    ].join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final window = MediaQuery.sizeOf(context);
    final theme = Theme.of(context);
    final pixelPerfect = ref.watch(
      settingsProvider.select((s) => s.viewerPixelPerfect),
    );
    final rel = widget.images[_index];
    final file = File(p.join(widget.packPath, rel));
    return Dialog(
      insetPadding: EdgeInsets.symmetric(
        horizontal: window.width * 0.025,
        vertical: window.height * 0.025,
      ),
      clipBehavior: Clip.antiAlias,
      child: Focus(
        autofocus: true,
        onKeyEvent: _onKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
              child: Row(
                children: [
                  // Same width on both sides keeps the title centred.
                  SizedBox(
                    width: 168,
                    child: Text(
                      '${_index + 1} / ${widget.images.length}',
                      style: theme.textTheme.labelLarge,
                    ),
                  ),
                  Expanded(
                    child: Column(
                      children: [
                        Text(
                          prettyName(p.basename(rel)),
                          textAlign: TextAlign.center,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleMedium,
                        ),
                        Text(
                          _details(rel, file),
                          textAlign: TextAlign.center,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  SizedBox(
                    width: 168,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        IconButton(
                          tooltip: pixelPerfect
                              ? 'Pixel-perfect (whole steps)'
                              : 'Fit to window',
                          isSelected: pixelPerfect,
                          icon: const Icon(Icons.fit_screen_outlined),
                          selectedIcon: const Icon(Icons.grid_on),
                          onPressed: () => ref
                              .read(settingsProvider.notifier)
                              .setViewerPixelPerfect(!pixelPerfect),
                        ),
                        IconButton(
                          tooltip: 'Show in file manager',
                          icon: const Icon(Icons.drive_file_move_outline),
                          onPressed: () => ref.read(revealProvider)(file.path),
                        ),
                        IconButton(
                          tooltip: 'Close',
                          icon: const Icon(Icons.close),
                          onPressed: () => Navigator.of(context).pop(),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ColoredBox(
                color: theme.colorScheme.surfaceContainerHighest,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    GestureDetector(
                      onDoubleTap: () => _transform.value = Matrix4.identity(),
                      child: InteractiveViewer(
                        transformationController: _transform,
                        minScale: 0.5,
                        maxScale: 32,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 64,
                            vertical: 16,
                          ),
                          child: PixelImage(
                            file,
                            key: ValueKey(rel),
                            animate: true,
                            fullResolution: true,
                            scale: (fit) =>
                                viewerScale(fit, pixelPerfect: pixelPerfect),
                          ),
                        ),
                      ),
                    ),
                    if (widget.images.length > 1) ...[
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Padding(
                          padding: const EdgeInsets.all(8),
                          child: IconButton.filledTonal(
                            tooltip: 'Previous image (←)',
                            icon: const Icon(Icons.chevron_left),
                            onPressed: _hasPrev ? () => _go(-1) : null,
                          ),
                        ),
                      ),
                      Align(
                        alignment: Alignment.centerRight,
                        child: Padding(
                          padding: const EdgeInsets.all(8),
                          child: IconButton.filledTonal(
                            tooltip: 'Next image (→)',
                            icon: const Icon(Icons.chevron_right),
                            onPressed: _hasNext ? () => _go(1) : null,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
