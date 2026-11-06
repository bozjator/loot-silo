import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;

import '../../core/animation_detector.dart';
import 'pixel_image.dart';

/// Plays a [SpriteAnim]: slices sheet cells and draws them crisp, scaled up in whole steps.
///
/// Shows frame 0 while [playing] is false. For grids, the animation's
/// [SpriteAnim.rowToPlay] picks the row to play; `null` plays every cell.
///
/// Auto-trim: fully transparent cells (common at the end of grid rows) are
/// skipped, and every frame is cropped to the union of the frames' opaque
/// bounds, the same rectangle for all of them so nothing jitters. The
/// result is cached per sheet and slicing ([trimCache]), so a card shown
/// again draws trimmed from its first frame. [SpriteAnim.zoom] replaces the
/// fit with a fixed whole-number scale, centred and clipped.
class AnimatedSprite extends StatefulWidget {
  const AnimatedSprite({
    super.key,
    required this.packPath,
    required this.anim,
    this.playing = true,
    this.fps,
  });

  final String packPath;
  final SpriteAnim anim;
  final bool playing;

  /// Overrides [SpriteAnim.fps].
  final double? fps;

  @override
  State<AnimatedSprite> createState() => _AnimatedSpriteState();
}

/// Trim results: kept frame indices and the shared crop (relative to each
/// frame's origin), keyed by [trimKey]. Bounded; oldest entries go first.
@visibleForTesting
final trimCache = <String, (List<int>, Rect)>{};
const _trimCacheSize = 4000;

/// Cache key for [anim] in [packPath]: the file(s) and everything that
/// changes the slicing (not fps or zoom).
@visibleForTesting
String trimKey(String packPath, SpriteAnim anim, List<ui.Image> images) => [
  packPath,
  anim.path,
  anim.kind.name,
  anim.frameW,
  anim.frameH,
  anim.frameTotal,
  anim.rowToPlay,
  for (final i in images) '${i.width}x${i.height}',
].join('|');

class _AnimatedSpriteState extends State<AnimatedSprite>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_tick);
  final _images = <ui.Image>[];

  /// Streams still being listened to; a listener detaches itself once its
  /// image has arrived.
  final _streams = <(ImageStream, ImageStreamListener)>[];
  var _loading = false;

  /// (image index, source rect) per frame.
  List<(int, Rect)> _frames = const [];
  var _frame = 0;
  Object? _error;

  /// False until [_trimEmpty] has run, so the untrimmed frame never flashes.
  var _trimmed = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_loading) _load();
  }

  @override
  void didUpdateWidget(AnimatedSprite old) {
    super.didUpdateWidget(old);
    // Only the row changed: re-slice the loaded image, no reload. Zoom and
    // fps only change the drawing.
    final sameSheet =
        old.anim.copyWith(
          playRow: widget.anim.playRow,
          zoom: widget.anim.zoom,
          fps: widget.anim.fps,
        ) ==
        widget.anim;
    if (!sameSheet || old.packPath != widget.packPath) {
      _release();
      _load();
    } else if (old.anim.playRow != widget.anim.playRow) {
      _frames = _computeFrames();
      _frame = 0;
      _trimmed = false;
      _trimEmpty();
    }
    _syncTicker();
  }

  void _load() {
    _loading = true;
    final anim = widget.anim;
    final paths = [anim.path];
    final pending = List<ui.Image?>.filled(paths.length, null);
    var remaining = paths.length;
    for (var i = 0; i < paths.length; i++) {
      final provider = FileImage(File(p.join(widget.packPath, paths[i])));
      final stream = provider.resolve(createLocalImageConfiguration(context));
      late final ImageStreamListener listener;
      listener = ImageStreamListener(
        (info, _) {
          if (pending[i] != null) return;
          pending[i] = info.image.clone();
          info.dispose();
          stream.removeListener(listener);
          // Detached: once the image cache lets go, the stream is disposed
          // and removing the listener again in [_release] would throw.
          _streams.removeWhere((e) => identical(e.$2, listener));
          if (--remaining == 0 && mounted) {
            setState(() {
              _images
                ..clear()
                ..addAll(pending.cast<ui.Image>());
              _frames = _computeFrames();
              _frame = 0;
              _trimmed = false;
            });
            _trimEmpty();
            _syncTicker();
          }
        },
        onError: (e, _) {
          if (mounted) setState(() => _error = e);
        },
      );
      // Recorded first: a cached image calls the listener right away.
      _streams.add((stream, listener));
      stream.addListener(listener);
    }
  }

  List<(int, Rect)> _computeFrames() {
    final anim = widget.anim;
    if (_images.isEmpty) return const [];
    final image = _images.first;
    // The decoded image may differ from the recorded size (overrides,
    // edited files); slice by the real size.
    final cols = math.max(1, image.width ~/ math.max(1, anim.frameW));
    final rows = math.max(1, image.height ~/ math.max(1, anim.frameH));
    final fw = anim.frameW.toDouble();
    final fh = anim.frameH.toDouble();
    final row = anim.rowToPlay;
    // A total-frames override leaves the last row partly filled.
    final total = anim.frameTotal ?? cols * rows;
    return [
      for (var r = 0; r < rows; r++)
        if (row == null || r == row.clamp(0, rows - 1))
          for (var c = 0; c < cols; c++)
            if (r * cols + c < total)
              (0, Rect.fromLTWH(c * fw, r * fh, fw, fh)),
    ];
  }

  /// Drops fully transparent frames and crops every frame to the union of
  /// their opaque bounds, so padded frames still scale up. Sheets only;
  /// GIFs play as they are.
  Future<void> _trimEmpty() async {
    final frames = _frames;
    if (widget.anim.kind == AnimKind.gif || _images.isEmpty) {
      _trimmed = true;
      return;
    }
    final key = trimKey(widget.packPath, widget.anim, _images);
    final cached = trimCache[key];
    if (cached != null) {
      _applyTrim(cached);
      return;
    }
    // Read from clones taken now: the sprite can be removed or reloaded
    // between two reads, which disposes [_images].
    final sources = {for (final (index, _) in frames) _images[index]};
    final clones = {for (final i in sources) i: i.clone()};
    final data = <ui.Image, ByteData?>{};
    try {
      for (final MapEntry(key: image, value: clone) in clones.entries) {
        if (!mounted || !identical(frames, _frames)) return;
        try {
          data[image] = await clone.toByteData();
        } catch (_) {
          data[image] = null; // unreadable: the frame is kept whole
        }
      }
    } finally {
      for (final c in clones.values) {
        c.dispose();
      }
    }
    if (!mounted || !identical(frames, _frames)) return;
    // Opaque bounds of a frame relative to its origin, or null when empty.
    // A cell can reach past the image (frame size larger than the sheet),
    // so the scan stays inside it.
    Rect? bounds(ui.Image image, ByteData bytes, Rect r) {
      final w = image.width;
      int? x0, y0, x1, y1;
      final xEnd = math.min(r.right.toInt(), w);
      final yEnd = math.min(r.bottom.toInt(), image.height);
      for (var y = r.top.toInt(); y < yEnd; y++) {
        for (var x = r.left.toInt(); x < xEnd; x++) {
          if (bytes.getUint8((y * w + x) * 4 + 3) == 0) continue;
          x0 = x0 == null ? x : math.min(x0, x);
          x1 = x1 == null ? x : math.max(x1, x);
          y0 ??= y;
          y1 = y;
        }
      }
      if (x0 == null) return null;
      return Rect.fromLTRB(
        x0 - r.left,
        y0! - r.top,
        x1! + 1 - r.left,
        y1! + 1 - r.top,
      );
    }

    Rect? union;
    final kept = <int>[];
    for (var i = 0; i < frames.length; i++) {
      final (index, rect) = frames[i];
      final image = _images[index];
      final bytes = data[image];
      if (bytes == null) {
        // Unreadable: keep the frame whole.
        kept.add(i);
        union = (union ?? rect.shift(-rect.topLeft)).expandToInclude(
          rect.shift(-rect.topLeft),
        );
        continue;
      }
      final b = bounds(image, bytes, rect);
      if (b == null) continue;
      kept.add(i);
      union = union == null ? b : union.expandToInclude(b);
    }
    if (kept.isEmpty) {
      setState(() => _trimmed = true);
      return;
    }
    final result = (kept, union!);
    if (trimCache.length >= _trimCacheSize) {
      trimCache.remove(trimCache.keys.first);
    }
    trimCache[key] = result;
    _applyTrim(result);
  }

  void _applyTrim((List<int>, Rect) trim) {
    final (kept, crop) = trim;
    final frames = _frames;
    setState(() {
      _frames = [
        for (final i in kept)
          if (i < frames.length)
            (frames[i].$1, crop.shift(frames[i].$2.topLeft)),
      ];
      if (_frames.isEmpty) _frames = frames;
      _frame = _frame % _frames.length;
      _trimmed = true;
    });
    _syncTicker();
  }

  void _syncTicker() {
    final shouldRun = widget.playing && _frames.length > 1;
    if (shouldRun && !_ticker.isActive) {
      _ticker.start();
    } else if (!shouldRun && _ticker.isActive) {
      _ticker.stop();
      if (_frame != 0) setState(() => _frame = 0);
    }
  }

  void _tick(Duration elapsed) {
    final fps = widget.fps ?? widget.anim.fps;
    final next =
        (elapsed.inMicroseconds * fps / Duration.microsecondsPerSecond)
            .floor() %
        _frames.length;
    if (next != _frame) setState(() => _frame = next);
  }

  void _release() {
    for (final (stream, listener) in _streams) {
      stream.removeListener(listener);
    }
    _streams.clear();
    for (final i in _images) {
      i.dispose();
    }
    _images.clear();
    _frames = const [];
  }

  @override
  void dispose() {
    _ticker.dispose();
    _release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null || _frames.isEmpty || !_trimmed) {
      return const SizedBox.expand();
    }
    final (index, src) = _frames[_frame % _frames.length];
    return CustomPaint(
      painter: SpriteFramePainter(_images[index], src, zoom: widget.anim.zoom),
      size: Size.infinite,
    );
  }
}

/// Paints one frame; public so tests can read [src].
class SpriteFramePainter extends CustomPainter {
  SpriteFramePainter(this.image, this.src, {this.zoom});

  final ui.Image image;
  final Rect src;

  /// A fixed scale (centred, clipped to the box); null fits in whole steps.
  final int? zoom;

  /// The scale [paint] draws [src] at in a box of [size].
  double scaleFor(Size size) =>
      zoom?.toDouble() ??
      integerScale(math.min(size.width / src.width, size.height / src.height));

  @override
  void paint(Canvas canvas, Size size) {
    final scale = scaleFor(size);
    if (zoom != null) canvas.clipRect(Offset.zero & size);
    final w = src.width * scale;
    final h = src.height * scale;
    final dst = Rect.fromLTWH(
      ((size.width - w) / 2).roundToDouble(),
      ((size.height - h) / 2).roundToDouble(),
      w,
      h,
    );
    canvas.drawImageRect(
      image,
      src,
      dst,
      Paint()
        ..filterQuality = scale >= 1
            ? FilterQuality.none
            : FilterQuality.medium,
    );
  }

  @override
  bool shouldRepaint(SpriteFramePainter old) =>
      old.image != image || old.src != src || old.zoom != zoom;
}
