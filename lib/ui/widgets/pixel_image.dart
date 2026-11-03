import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Largest edge an image is decoded at; mockups can be 4k+ pixels.
const maxDecodeEdge = 768;

/// Shows an image file the way pixel art should look: scaled up in whole
/// steps with no smoothing, or scaled down to fit when it's too big.
///
/// Big images are decoded at most [maxDecodeEdge] pixels on their long
/// edge, by the engine, so a grid of mockups stays cheap. For animated
/// files only the first frame is shown unless [animate] is set.
class PixelImage extends StatefulWidget {
  const PixelImage(
    this.file, {
    super.key,
    this.animate = false,
    this.fit = BoxFit.contain,
    this.errorBuilder,
  });

  final File file;
  final bool animate;

  /// `contain` letterboxes; `cover` fills and crops (still in whole steps
  /// when upscaling).
  final BoxFit fit;
  final WidgetBuilder? errorBuilder;

  static ImageProvider providerFor(File file) => ResizeImage(
    FileImage(file),
    width: maxDecodeEdge,
    height: maxDecodeEdge,
    policy: ResizeImagePolicy.fit,
    allowUpscaling: false,
  );

  @override
  State<PixelImage> createState() => _PixelImageState();
}

class _PixelImageState extends State<PixelImage> {
  ImageStream? _stream;
  ImageInfo? _info;
  Object? _error;
  late final _listener = ImageStreamListener(_onImage, onError: _onError);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolve();
  }

  @override
  void didUpdateWidget(PixelImage old) {
    super.didUpdateWidget(old);
    if (old.file.path != widget.file.path) {
      _info = null;
      _error = null;
      _resolve();
    } else if (old.animate != widget.animate && widget.animate) {
      _resolve(force: true);
    }
  }

  void _resolve({bool force = false}) {
    final stream = PixelImage.providerFor(widget.file)
        .resolve(createLocalImageConfiguration(context));
    if (!force && stream.key == _stream?.key) return;
    _stream?.removeListener(_listener);
    _stream = stream..addListener(_listener);
  }

  void _onImage(ImageInfo info, bool sync) {
    if (!mounted) return;
    setState(() {
      _info?.dispose();
      _info = info;
    });
    // Holding no listener pauses multi-frame codecs on their first frame.
    if (!widget.animate) _stream?.removeListener(_listener);
  }

  void _onError(Object error, StackTrace? stack) {
    if (mounted) setState(() => _error = error);
  }

  @override
  void dispose() {
    _stream?.removeListener(_listener);
    _info?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
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
        final scale = integerScale(fitScale);
        return ClipRect(
          child: OverflowBox(
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
