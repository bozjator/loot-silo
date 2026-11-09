import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/providers.dart';

/// A sound's waveform as mirrored bars, decoded once per file (off the UI
/// thread, [audioPeaksProvider]) when the widget is first built. The part
/// before [progress] (0..1, while playing) is drawn in `primary`, the rest
/// in `onSurfaceVariant`. Always takes its full size, so a file without a
/// waveform (unknown format) leaves the layout as it is.
class Waveform extends ConsumerStatefulWidget {
  const Waveform({
    super.key,
    required this.path,
    this.progress,
    this.width,
    required this.height,
    this.playhead = false,
  });

  final String path;
  final double? progress;

  /// A thin line at [progress] (the card's seek strip while playing).
  final bool playhead;

  /// Null: as wide as the parent allows.
  final double? width;
  final double height;

  @override
  ConsumerState<Waveform> createState() => _WaveformState();
}

class _WaveformState extends ConsumerState<Waveform> {
  Float32List? _peaks;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(Waveform old) {
    super.didUpdateWidget(old);
    if (old.path != widget.path) _load();
  }

  void _load() {
    final cache = ref.read(audioPeaksProvider);
    final path = widget.path;
    _peaks = cache.peek(path);
    if (_peaks != null) return;
    cache.load(path).then((peaks) {
      if (mounted && widget.path == path) setState(() => _peaks = peaks);
    });
  }

  /// No waveform (unknown format): the playhead alone, so seeking still
  /// shows where it is.
  Widget? _playhead(ColorScheme scheme) =>
      widget.playhead && widget.progress != null
      ? CustomPaint(painter: PlayheadPainter(widget.progress!, scheme.primary))
      : null;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final peaks = _peaks;
    return SizedBox(
      width: widget.width,
      height: widget.height,
      child: peaks == null || peaks.isEmpty
          ? _playhead(scheme)
          : CustomPaint(
              key: const ValueKey('waveform-bars'),
              painter: WaveformPainter(
                peaks: peaks,
                progress: widget.progress,
                played: scheme.primary,
                rest: scheme.onSurfaceVariant.withValues(alpha: 0.7),
              ),
              foregroundPainter: widget.playhead && widget.progress != null
                  ? PlayheadPainter(widget.progress!, scheme.primary)
                  : null,
            ),
    );
  }
}

/// A 1.5 px line across the full height at [progress] (0..1).
class PlayheadPainter extends CustomPainter {
  PlayheadPainter(this.progress, this.color);

  final double progress;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final x = progress.clamp(0.0, 1.0) * size.width;
    canvas.drawRect(
      Rect.fromLTWH(
        (x - 0.75).clamp(0.0, math.max(0.0, size.width - 1.5)),
        0,
        1.5,
        size.height,
      ),
      Paint()..color = color,
    );
  }

  @override
  bool shouldRepaint(PlayheadPainter old) =>
      old.progress != progress || old.color != color;
}

/// Bars of [bar] px with [gap] px between them, mirrored around the middle;
/// each bar is the loudest peak in its slice, at least 1 px tall.
class WaveformPainter extends CustomPainter {
  WaveformPainter({
    required this.peaks,
    required this.progress,
    required this.played,
    required this.rest,
    this.bar = 2,
    this.gap = 1,
  });

  final Float32List peaks;
  final double? progress;
  final Color played;
  final Color rest;
  final double bar;
  final double gap;

  @override
  void paint(Canvas canvas, Size size) {
    if (peaks.isEmpty || size.width <= 0) return;
    final bars = math.max(1, ((size.width + gap) / (bar + gap)).floor());
    final split = (progress ?? 0).clamp(0.0, 1.0) * size.width;
    final mid = size.height / 2;
    final playedPaint = Paint()..color = played;
    final restPaint = Paint()..color = rest;
    for (var i = 0; i < bars; i++) {
      final from = i * peaks.length ~/ bars;
      final to = math.max(from + 1, (i + 1) * peaks.length ~/ bars);
      var v = 0.0;
      for (var k = from; k < to && k < peaks.length; k++) {
        if (peaks[k] > v) v = peaks[k];
      }
      final h = math.max(1.0, v * size.height);
      final x = i * (bar + gap);
      canvas.drawRect(
        Rect.fromLTWH(x, mid - h / 2, bar, h),
        x + bar / 2 < split ? playedPaint : restPaint,
      );
    }
  }

  @override
  bool shouldRepaint(WaveformPainter old) =>
      !identical(old.peaks, peaks) ||
      old.progress != progress ||
      old.played != played ||
      old.rest != rest;
}
