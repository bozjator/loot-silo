import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';

/// The edge an image is decoded at in a small box; mockups can be 4k+
/// pixels. Bigger boxes decode at [decodeEdgeFor].
const maxDecodeEdge = 768;

/// Decode sizes go up in steps of this many physical pixels, so resizing
/// the window doesn't fill the image cache with one copy per pixel.
const decodeBucket = 256;

/// The long edge to decode an image at for a box [logical] px on its long
/// edge at [devicePixelRatio]: the box's physical size rounded up to a
/// [decodeBucket], never below [maxDecodeEdge] (small tiles decode as they
/// always did). The file's own size still caps it (no upscaling).
int decodeEdgeFor(double logical, double devicePixelRatio) {
  if (!logical.isFinite || logical <= 0) return maxDecodeEdge;
  final px = (logical * devicePixelRatio / decodeBucket).ceil() * decodeBucket;
  return math.max(maxDecodeEdge, px);
}

/// Shows an image file the way pixel art should look: scaled up in whole
/// steps with no smoothing, or scaled down to fit when it's too big.
///
/// Big images are decoded by the engine at the box's size ([decodeEdgeFor]:
/// [maxDecodeEdge] for tiles of today's size, more for big cards, in
/// [decodeBucket] steps), so a grid of mockups stays cheap and a card one
/// per row stays sharp. For animated
/// files only the first frame is shown unless [animate] is set.
class PixelImage extends StatefulWidget {
  const PixelImage(
    this.file, {
    super.key,
    this.animate = false,
    this.fit = BoxFit.contain,
    this.scale = integerScale,
    this.fullResolution = false,
    this.errorBuilder,
  });

  final File file;
  final bool animate;

  /// `contain` letterboxes; `cover` fills and crops (still in whole steps
  /// when upscaling).
  final BoxFit fit;

  /// Turns the exact fit scale into the one drawn; [integerScale] for
  /// tiles, the exact fit in the image viewer.
  final double Function(double fitScale) scale;

  /// Decodes at the file's own size instead of [maxDecodeEdge]; for the one
  /// image the viewer shows.
  final bool fullResolution;
  final WidgetBuilder? errorBuilder;

  /// [file] decoded to fit [edge] × [edge] pixels.
  static ImageProvider providerFor(File file, {int edge = maxDecodeEdge}) =>
      ResizeImage(
        FileImage(file),
        width: edge,
        height: edge,
        policy: ResizeImagePolicy.fit,
        allowUpscaling: false,
      );

  @override
  State<PixelImage> createState() => _PixelImageState();
}

class _PixelImageState extends State<PixelImage> {
  ImageStream? _stream;

  /// Whether [_listener] is on [_stream]. A stream with no listeners can be
  /// disposed by the image cache, and removing from it then throws.
  var _listening = false;
  ImageInfo? _info;
  Object? _error;

  /// The decode edge [_stream] uses; follows the box's size after layout.
  int _edge = maxDecodeEdge;
  var _edgePending = false;
  late final _listener = ImageStreamListener(_onImage, onError: _onError);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolve();
  }

  @override
  void didUpdateWidget(PixelImage old) {
    super.didUpdateWidget(old);
    if (old.file.path != widget.file.path ||
        old.fullResolution != widget.fullResolution) {
      _info = null;
      _error = null;
      _resolve();
    } else if (old.animate != widget.animate && widget.animate) {
      _resolve(force: true);
    }
  }

  void _resolve({bool force = false}) {
    final provider = widget.fullResolution
        ? FileImage(widget.file)
        : PixelImage.providerFor(widget.file, edge: _edge);
    final stream = provider.resolve(createLocalImageConfiguration(context));
    if (!force && stream.key == _stream?.key) return;
    _unlisten();
    _stream = stream..addListener(_listener);
    _listening = true;
  }

  void _unlisten() {
    if (_listening) _stream?.removeListener(_listener);
    _listening = false;
  }

  void _onImage(ImageInfo info, bool sync) {
    if (!mounted) return;
    setState(() {
      _info?.dispose();
      _info = info;
    });
    // Holding no listener pauses multi-frame codecs on their first frame.
    if (!widget.animate) _unlisten();
  }

  void _onError(Object error, StackTrace? stack) {
    // A later frame of a GIF that fails to decode keeps the last good one.
    if (mounted && _info == null) setState(() => _error = error);
  }

  @override
  void dispose() {
    _unlisten();
    _info?.dispose();
    super.dispose();
  }

  /// Re-decodes after the frame when the box needs another bucket; the old
  /// picture stays until the new one is ready.
  void _follow(BoxConstraints box) {
    if (widget.fullResolution) return;
    final edge = decodeEdgeFor(
      math.max(box.maxWidth, box.maxHeight),
      MediaQuery.devicePixelRatioOf(context),
    );
    if (edge == _edge || _edgePending) return;
    _edgePending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _edgePending = false;
      if (!mounted || edge == _edge) return;
      _edge = edge;
      _resolve();
    });
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      _follow(box);
      return _image(context);
    },
  );

  Widget _image(BuildContext context) {
    if (_error != null) {
      return widget.errorBuilder?.call(context) ??
          const Center(child: Icon(Icons.broken_image_outlined));
    }
    final info = _info;
    if (info == null) return const SizedBox.expand();
    final w = info.image.width.toDouble();
    final h = info.image.height.toDouble();
    return LayoutBuilder(
      builder: (context, box) {
        final fitScale = widget.fit == BoxFit.cover
            ? math.max(box.maxWidth / w, box.maxHeight / h)
            : math.min(box.maxWidth / w, box.maxHeight / h);
        final scale = widget.scale(fitScale);
        return ClipRect(
          // Min 0: under tight constraints (a stretched column, the
          // viewer) the image would otherwise be forced to the box size.
          child: OverflowBox(
            minWidth: 0,
            minHeight: 0,
            maxWidth: double.infinity,
            maxHeight: double.infinity,
            child: RawImage(
              image: info.image,
              width: w * scale,
              height: h * scale,
              fit: BoxFit.fill,
              filterQuality: scale >= 1
                  ? FilterQuality.none
                  : FilterQuality.medium,
            ),
          ),
        );
      },
    );
  }
}

/// Whole-number upscaling (crisp pixels); fractional when shrinking.
double integerScale(double fitScale) =>
    fitScale >= 1 ? fitScale.floorToDouble() : fitScale;
