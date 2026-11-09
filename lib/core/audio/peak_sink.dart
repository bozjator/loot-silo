import 'dart:math' as math;
import 'dart:typed_data';

/// Collects the loudest |sample| of a mono signal in short blocks while a
/// decoder runs, then folds them into a fixed number of peaks.
class PeakSink {
  /// Samples per block: fine enough that a 0.1 s sound still fills a few
  /// dozen peaks.
  static const block = 32;

  var _maxes = Float32List(4096);
  var _count = 0;
  var _current = 0.0;
  var _inBlock = 0;

  /// Samples added so far.
  int samples = 0;

  /// One mono sample, any scale.
  void add(double v) {
    final a = v < 0 ? -v : v;
    if (a > _current) _current = a;
    samples++;
    if (++_inBlock == block) _flush();
  }

  /// [n] samples whose loudest |sample| is [peak].
  void addPeak(double peak, int n) {
    if (peak > _current) _current = peak;
    samples += n;
    _inBlock += n;
    if (_inBlock >= block) _flush();
  }

  /// The first [n] samples of [block].
  void addAll(Float64List block, int n) {
    for (var i = 0; i < n; i++) {
      final v = block[i];
      final a = v < 0 ? -v : v;
      if (a > _current) _current = a;
      if (++_inBlock == PeakSink.block) _flush();
    }
    samples += n;
  }

  void _flush() {
    if (_count == _maxes.length) {
      _maxes = Float32List(_count * 2)..setAll(0, _maxes);
    }
    _maxes[_count++] = _current;
    _current = 0;
    _inBlock = 0;
  }

  /// [buckets] peaks over the whole signal, scaled so the loudest is 1
  /// (all zero for silence); empty when nothing was added.
  Float32List finish(int buckets) {
    if (_inBlock > 0) _flush();
    if (_count == 0) return Float32List(0);
    final out = Float32List(buckets);
    var top = 0.0;
    for (var b = 0; b < buckets; b++) {
      final from = b * _count ~/ buckets;
      final to = math.max(from + 1, (b + 1) * _count ~/ buckets);
      var m = 0.0;
      for (var i = from; i < to; i++) {
        if (_maxes[i] > m) m = _maxes[i];
      }
      out[b] = m;
      if (m > top) top = m;
    }
    if (top > 0) {
      for (var b = 0; b < buckets; b++) {
        out[b] /= top;
      }
    }
    return out;
  }
}
