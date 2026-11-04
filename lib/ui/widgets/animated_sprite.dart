import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;

import '../../core/animation_detector.dart';
import 'pixel_image.dart';

/// Plays a [SpriteAnim]: slices sheet cells (or loads sequence frames) and
/// draws them crisp, scaled up in whole steps.
///
/// Shows frame 0 while [playing] is false. For grids, [row] picks the row
/// to play; `null` plays every cell. Fully transparent cells (common at
/// the end of grid rows) are skipped once the image has been inspected.
class AnimatedSprite extends StatefulWidget {
  const AnimatedSprite({
    super.key,
    required this.packPath,
    required this.anim,
    this.playing = true,
    this.row = 0,
    this.fps,
  });

  final String packPath;
  final SpriteAnim anim;
  final bool playing;
  final int? row;

  /// Overrides [SpriteAnim.fps].
  final double? fps;

  @override
  State<AnimatedSprite> createState() => _AnimatedSpriteState();
}

class _AnimatedSpriteState extends State<AnimatedSprite>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_tick);
  final _images = <ui.Image>[];
  final _streams = <(ImageStream, ImageStreamListener)>[];

  /// (image index, source rect) per frame.
  List<(int, Rect)> _frames = const [];
  var _frame = 0;
  Object? _error;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_streams.isEmpty) _load();
  }

  @override
  void didUpdateWidget(AnimatedSprite old) {
    super.didUpdateWidget(old);
    if (old.anim != widget.anim || old.packPath != widget.packPath) {
      _release();
      _load();
    } else if (old.row != widget.row) {
      _frames = _computeFrames();
      _frame = 0;
      _trimEmpty();
    }
    _syncTicker();
  }

  void _load() {
    final anim = widget.anim;
    final paths = anim.kind == AnimKind.sequence ? anim.frames : [anim.path];
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
          if (--remaining == 0 && mounted) {
            setState(() {
              _images
                ..clear()
                ..addAll(pending.cast<ui.Image>());
              _frames = _computeFrames();
              _frame = 0;
            });
            _trimEmpty();
            _syncTicker();
          }
        },
        onError: (e, _) {
          if (mounted) setState(() => _error = e);
        },
      );
      stream.addListener(listener);
      _streams.add((stream, listener));
    }
  }

  List<(int, Rect)> _computeFrames() {
    final anim = widget.anim;
    if (anim.kind == AnimKind.sequence) {
      return [
        for (var i = 0; i < _images.length; i++)
          (
            i,
            Rect.fromLTWH(
              0,
              0,
              _images[i].width.toDouble(),
              _images[i].height.toDouble(),
            ),
          ),
      ];
    }
    if (_images.isEmpty) return const [];
    final image = _images.first;
    // The decoded image may differ from the recorded size (overrides,
    // edited files); slice by the real size.
    final cols = math.max(1, image.width ~/ math.max(1, anim.frameW));
    final rows = math.max(1, image.height ~/ math.max(1, anim.frameH));
    final fw = anim.frameW.toDouble();
    final fh = anim.frameH.toDouble();
    final row = widget.row;
    return [
      for (var r = 0; r < rows; r++)
        if (row == null || r == row.clamp(0, rows - 1))
          for (var c = 0; c < cols; c++)
            (0, Rect.fromLTWH(c * fw, r * fh, fw, fh)),
    ];
  }

  /// Drops fully transparent sheet cells and crops every frame to the
  /// union of their opaque bounds, so padded frames still scale up.
  Future<void> _trimEmpty() async {
    if (widget.anim.kind != AnimKind.sheet || _images.isEmpty) return;
    final image = _images.first;
    final frames = _frames;
    final data = await image.toByteData();
    if (data == null || !mounted || !identical(frames, _frames)) return;
    final w = image.width;
    // Opaque bounds of a cell relative to its origin, or null when empty.
    Rect? bounds(Rect r) {
      int? x0, y0, x1, y1;
      for (var y = r.top.toInt(); y < r.bottom.toInt(); y++) {
        for (var x = r.left.toInt(); x < r.right.toInt(); x++) {
          if (data.getUint8((y * w + x) * 4 + 3) == 0) continue;
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
    final kept = <(int, Rect)>[];
    for (final f in frames) {
      final b = bounds(f.$2);
      if (b == null) continue;
      kept.add(f);
      union = union == null ? b : union.expandToInclude(b);
    }
    if (kept.isEmpty) return;
    final crop = union!;
    setState(() {
      _frames = [
        for (final (i, r) in kept) (i, crop.shift(r.topLeft)),
      ];
      _frame = _frame % _frames.length;
    });
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
    if (_error != null || _frames.isEmpty) return const SizedBox.expand();
    final (index, src) = _frames[_frame % _frames.length];
    return CustomPaint(
      painter: SpriteFramePainter(_images[index], src),
      size: Size.infinite,
    );
  }
}

/// Paints one frame; public so tests can read [src].
class SpriteFramePainter extends CustomPainter {
  SpriteFramePainter(this.image, this.src);

  final ui.Image image;
  final Rect src;

  @override
  void paint(Canvas canvas, Size size) {
    final scale = integerScale(
      math.min(size.width / src.width, size.height / src.height),
    );
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
      old.image != image || old.src != src;
}
