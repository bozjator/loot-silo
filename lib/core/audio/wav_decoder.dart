import 'dart:typed_data';

import 'peak_sink.dart';

/// Feeds the samples of a RIFF WAVE file, mixed to mono, into [sink]:
/// integer PCM of 8, 16, 24 or 32 bits and 32 / 64-bit float, also inside
/// WAVE_FORMAT_EXTENSIBLE. False for anything else (ADPCM, µ-law, …).
bool decodeWav(Uint8List bytes, PeakSink sink) {
  if (bytes.length < 12) return false;
  final d = ByteData.sublistView(bytes);
  String tag(int at) => String.fromCharCodes(bytes, at, at + 4);
  if (tag(0) != 'RIFF' || tag(8) != 'WAVE') return false;
  int? format;
  var channels = 0;
  var bits = 0;
  var at = 12;
  while (at + 8 <= bytes.length) {
    final id = tag(at);
    final size = d.getUint32(at + 4, Endian.little);
    final body = at + 8;
    if (id == 'fmt ' && body + 16 <= bytes.length) {
      format = d.getUint16(body, Endian.little);
      channels = d.getUint16(body + 2, Endian.little);
      bits = d.getUint16(body + 14, Endian.little);
      // Extensible: the sub-format GUID starts with the real tag.
      if (format == 0xFFFE && size >= 26 && body + 26 <= bytes.length) {
        format = d.getUint16(body + 24, Endian.little);
      }
    } else if (id == 'data') {
      if (format == null || channels == 0) return false;
      // A streamed WAV may claim more data than the file holds.
      final end = (size == 0 || body + size > bytes.length)
          ? bytes.length
          : body + size;
      return _samples(d, body, end, format, channels, bits, sink);
    }
    at = body + size + (size & 1);
  }
  return false;
}

bool _samples(
  ByteData d,
  int from,
  int end,
  int format,
  int channels,
  int bits,
  PeakSink sink,
) {
  final width = bits ~/ 8;
  final frame = width * channels;
  if (frame == 0) return false;
  final double Function(int at) read;
  if (format == 1) {
    read = switch (bits) {
      8 => (at) => (d.getUint8(at) - 128) / 128,
      16 => (at) => d.getInt16(at, Endian.little) / 32768,
      24 =>
        (at) =>
            ((d.getUint8(at) |
                d.getUint8(at + 1) << 8 |
                d.getInt8(at + 2) << 16)) /
            8388608,
      32 => (at) => d.getInt32(at, Endian.little) / 2147483648,
      _ => (_) => double.nan,
    };
    if (bits != 8 && bits != 16 && bits != 24 && bits != 32) return false;
  } else if (format == 3 && (bits == 32 || bits == 64)) {
    read = bits == 32
        ? (at) => d.getFloat32(at, Endian.little)
        : (at) => d.getFloat64(at, Endian.little);
  } else {
    return false;
  }
  final scale = 1 / channels;
  for (var at = from; at + frame <= end; at += frame) {
    var sum = 0.0;
    for (var c = 0; c < channels; c++) {
      sum += read(at + c * width);
    }
    sink.add(sum * scale);
  }
  return true;
}
