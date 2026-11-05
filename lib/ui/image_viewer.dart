import 'dart:io';
import 'dart:math' as math;

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
/// wheel zoom both ways (down to [minViewerZoom] actual pixels, below the
/// fit) and drag to pan, prev/next by button or ←/→ within the list it was
/// opened from. The toolbar shows the zoom ("4×") with **1:1** (actual
/// size, as in game) and **Fit** (also double-click).
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

/// Smallest zoom the viewer allows, in screen pixels per image pixel.
const minViewerZoom = 0.25;

/// The image area's padding inside the viewer.
const _imagePadding = EdgeInsets.symmetric(horizontal: 64, vertical: 16);

/// "4×", "0.5×", "0.25×", "2.4×": two decimals below 1×, one above.
String zoomLabel(double zoom) {
  final text = zoom.toStringAsFixed(zoom < 1 ? 2 : 1);
  return '${text.replaceFirst(RegExp(r'\.?0+$'), '')}×';
}

const _sideWidth = 340.0;

final _compact = TextButton.styleFrom(
  visualDensity: VisualDensity.compact,
  minimumSize: const Size(40, 36),
  padding: const EdgeInsets.symmetric(horizontal: 8),
);

class _ImageViewerState extends ConsumerState<ImageViewer> {
  late var _index = widget.initialIndex.clamp(0, widget.images.length - 1);
  final _transform = TransformationController();

  /// Scale the image is drawn at before any zoom (the fit), and the image
  /// area; from the last layout.
  var _fitScale = 1.0;
  var _viewport = Size.zero;
  final _dims = <String, (int, int)?>{};

  @override
  void initState() {
    super.initState();
    _transform.addListener(_zoomed);
  }

  void _zoomed() => setState(() {});

  @override
  void dispose() {
    _transform
      ..removeListener(_zoomed)
      ..dispose();
    super.dispose();
  }

  /// Screen pixels per image pixel right now.
  double get _zoom => _fitScale * _transform.value.getMaxScaleOnAxis();

  /// Zooms to [zoom] about the middle of the image area.
  void _zoomTo(double zoom) {
    final s = zoom / _fitScale;
    final c = _viewport.center(Offset.zero);
    _transform.value = Matrix4.identity()
      ..translateByDouble(c.dx, c.dy, 0, 1)
      // Uniform, z too, as InteractiveViewer scales (it reads the scale
      // back with getMaxScaleOnAxis).
      ..scaleByDouble(s, s, s, 1)
      ..translateByDouble(-c.dx, -c.dy, 0, 1);
  }

  void _fit() => _transform.value = Matrix4.identity();

  (int, int)? _sizeOf(String rel) =>
      _dims.putIfAbsent(rel, () => readImageSize(p.join(widget.packPath, rel)));

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
    final dims = _sizeOf(rel);
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
                    width: _sideWidth,
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
                    width: _sideWidth,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        Flexible(
                          child: Text(
                            zoomLabel(_zoom),
                            key: const ValueKey('zoom-label'),
                            maxLines: 1,
                            overflow: TextOverflow.fade,
                            softWrap: false,
                            style: theme.textTheme.labelLarge,
                          ),
                        ),
                        const SizedBox(width: 4),
                        TextButton(
                          style: _compact,
                          onPressed: () => _zoomTo(1),
                          child: const Text('1:1'),
                        ),
                        TextButton(
                          style: _compact,
                          onPressed: _fit,
                          child: const Text('Fit'),
                        ),
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
                    LayoutBuilder(
                      builder: (context, box) {
                        _viewport = box.biggest;
                        final dims = _sizeOf(rel);
                        final inner = _imagePadding.deflateSize(box.biggest);
                        if (dims != null && dims.$1 > 0 && dims.$2 > 0) {
                          final fit = viewerScale(
                            math.min(
                              inner.width / dims.$1,
                              inner.height / dims.$2,
                            ),
                            pixelPerfect: pixelPerfect,
                          );
                          if (fit != _fitScale) {
                            _fitScale = fit;
                            // The toolbar was built before this layout.
                            WidgetsBinding.instance.addPostFrameCallback((_) {
                              if (mounted) setState(() {});
                            });
                          }
                        }
                        return GestureDetector(
                          onDoubleTap: _fit,
                          child: InteractiveViewer(
                            transformationController: _transform,
                            // Below the fit, down to [minViewerZoom] actual
                            // pixels; free panning so a small image can sit
                            // anywhere.
                            minScale: math.min(0.5, minViewerZoom / _fitScale),
                            maxScale: math.max(32, 64 / _fitScale),
                            boundaryMargin: const EdgeInsets.all(
                              double.infinity,
                            ),
                            child: Padding(
                              padding: _imagePadding,
                              child: PixelImage(
                                file,
                                key: ValueKey(rel),
                                animate: true,
                                fullResolution: true,
                                scale: (fit) => viewerScale(
                                  fit,
                                  pixelPerfect: pixelPerfect,
                                ),
                              ),
                            ),
                          ),
                        );
                      },
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
