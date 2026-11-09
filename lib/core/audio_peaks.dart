import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'audio/mp3_decoder.dart';
import 'audio/peak_sink.dart';
import 'audio/vorbis_decoder.dart';
import 'audio/wav_decoder.dart';

/// Peaks per file: enough for a card's width, small enough to keep 500.
const peakCount = 200;

/// Files larger than this get no waveform (a WAV of ~25 min).
const maxPeakFileBytes = 256 << 20;

/// Formats our own decoders read: WAV, MP3 and Ogg Vorbis.
bool hasWaveform(String path) => switch (p.extension(path).toLowerCase()) {
  '.wav' || '.wave' || '.mp3' || '.ogg' || '.oga' => true,
  _ => false,
};

/// [peakCount] peaks of [path]: the loudest |sample| of each slice, mixed
/// to mono, scaled so the loudest is 1. Empty when the format isn't one we
/// decode or the file can't be read (Opus in `.ogg`, ADPCM WAV, …).
Float32List readAudioPeaks(String path, {int buckets = peakCount}) {
  if (!hasWaveform(path)) return Float32List(0);
  try {
    final file = File(path);
    if (file.lengthSync() > maxPeakFileBytes) return Float32List(0);
    return decodePeaks(
      file.readAsBytesSync(),
      p.extension(path),
      buckets: buckets,
    );
  } on FileSystemException {
    return Float32List(0);
  }
}

/// [readAudioPeaks] for bytes already in memory; [extension] picks the
/// decoder (`.mp3`, `.ogg`, `.wav`).
Float32List decodePeaks(
  Uint8List bytes,
  String extension, {
  int buckets = peakCount,
}) {
  final sink = PeakSink();
  bool ok;
  try {
    ok = switch (extension.toLowerCase()) {
      '.wav' || '.wave' => decodeWav(bytes, sink),
      '.mp3' => decodeMp3(bytes, sink),
      '.ogg' || '.oga' => decodeVorbis(bytes, sink),
      _ => false,
    };
  } on Object {
    // A broken file: whatever was decoded before the damage still shows.
    ok = sink.samples > 0;
  }
  return ok ? sink.finish(buckets) : Float32List(0);
}

Float32List _readInIsolate(String path) => readAudioPeaks(path);

/// Peaks in memory, newest last, by path and modification time; failures
/// (empty peaks) are kept too. No disk cache. At most [parallel] files are
/// decoded at once, each in its own isolate, in the order asked.
class AudioPeaksCache {
  AudioPeaksCache({
    this.capacity = 500,
    int? parallel,
    Future<Float32List> Function(String path)? read,
  }) : parallel =
           parallel ??
           math.max(1, math.min(4, Platform.numberOfProcessors ~/ 2)),
       _read = read ?? ((path) => Isolate.run(() => _readInIsolate(path)));

  final int capacity;
  final int parallel;
  final Future<Float32List> Function(String path) _read;
  final _entries = <String, Future<Float32List>>{};
  final _done = <String, Float32List>{};
  final _queue = <(String, Completer<Float32List>)>[];
  var _running = 0;

  int get length => _entries.length;

  /// The peaks of [path] (empty when it has no waveform).
  Future<Float32List> load(String path) {
    if (!hasWaveform(path)) return Future.value(Float32List(0));
    final key = _key(path);
    if (key == null) return Future.value(Float32List(0));
    final hit = _entries.remove(key);
    if (hit != null) return _entries[key] = hit;
    final completer = Completer<Float32List>();
    final future = completer.future;
    _entries[key] = future;
    _queue.add((path, completer));
    _pump();
    future.then((peaks) {
      if (_entries.containsKey(key)) _done[key] = peaks;
    });
    while (_entries.length > capacity) {
      _done.remove(_entries.keys.first);
      _entries.remove(_entries.keys.first);
    }
    return future;
  }

  void _pump() {
    while (_running < parallel && _queue.isNotEmpty) {
      final (path, completer) = _queue.removeAt(0);
      _running++;
      _read(path)
          .then(
            completer.complete,
            onError: (Object _) {
              completer.complete(Float32List(0));
            },
          )
          .whenComplete(() {
            _running--;
            _pump();
          });
    }
  }

  /// What [load] gave for [path] if it has finished; null while decoding
  /// or before the first load.
  Float32List? peek(String path) => switch (_key(path)) {
    final key? => _done[key],
    null => null,
  };

  static String? _key(String path) {
    final stat = File(path).statSync();
    if (stat.type == FileSystemEntityType.notFound) return null;
    return '$path\u0000${stat.modified.microsecondsSinceEpoch}';
  }

  /// Forgets every file.
  void clear() {
    _entries.clear();
    _done.clear();
  }
}
