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
/// Every frame is drawn whole (no cropping), so all animations of one
/// character keep the same size. Fully transparent cells (common at the end
/// of grid rows) are skipped once the pixels are read. [SpriteAnim.zoom]
/// replaces the fit with a fixed whole-number scale, centred and clipped.
class AnimatedSprite extends StatefulWidget {
  const AnimatedSprite({
    super.key,
    required this.packPath,
    required this.anim,
    this.playing = true,
    this.fps,
    this.bytes,
  });

  final String packPath;
  final SpriteAnim anim;
  final bool playing;

  /// Overrides [SpriteAnim.fps].
  final double? fps;

  /// An encoded image to play instead of the file at [SpriteAnim.path]
  /// (e.g. a combined strip not saved yet).
  final Uint8List? bytes;

  @override
  State<AnimatedSprite> createState() => _AnimatedSpriteState();
}

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
    if (!sameSheet ||
        old.packPath != widget.packPath ||
        !identical(old.bytes, widget.bytes)) {
      _release();
      _load();
    } else if (old.anim.playRow != widget.anim.playRow) {
      _frames = _computeFrames();
      _frame = 0;
      _skipEmpty();
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
      final bytes = widget.bytes;
      final ImageProvider provider = bytes != null
          ? MemoryImage(bytes)
          : FileImage(File(p.join(widget.packPath, paths[i])));
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
            });
            _skipEmpty();
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
    return [
      for (final (x, y, w, h) in anim.frameCells(image.width, image.height))
        (
          0,
          Rect.fromLTWH(x.toDouble(), y.toDouble(), w.toDouble(), h.toDouble()),
        ),
    ];
  }

  /// Drops fully transparent frames; the rest are drawn whole. Sheets
  /// only; GIFs play as they are.
  Future<void> _skipEmpty() async {
    final frames = _frames;
    if (widget.anim.kind == AnimKind.gif || _images.isEmpty) return;
    // Read from a clone taken now: the sprite can be removed or reloaded
    // during the read, which disposes [_images].
    final image = _images.first;
    final clone = image.clone();
    ByteData? bytes;
    try {
      bytes = await clone.toByteData();
    } catch (_) {
      return; // unreadable: every frame is kept
    } finally {
      clone.dispose();
    }
    if (bytes == null || !mounted || !identical(frames, _frames)) return;
    bool opaque(Rect r) {
      final w = image.width;
      final xEnd = math.min(r.right.toInt(), w);
      final yEnd = math.min(r.bottom.toInt(), image.height);
      for (var y = r.top.toInt(); y < yEnd; y++) {
        for (var x = r.left.toInt(); x < xEnd; x++) {
          if (bytes!.getUint8((y * w + x) * 4 + 3) != 0) return true;
        }
      }
      return false;
    }

    final kept = [
      for (final f in frames)
        if (opaque(f.$2)) f,
    ];
    if (kept.isEmpty || kept.length == frames.length) return;
    setState(() {
      _frames = kept;
      _frame = _frame % kept.length;
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
    if (_error != null || _frames.isEmpty) {
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
