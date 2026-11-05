import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

/// Play length of an audio file, read from its headers in pure Dart.
///
/// WAV (`fmt ` + `data` chunks), Ogg Vorbis / Opus (granule position of the
/// last page), MP3 (Xing/Info or VBRI frame count, else a CBR estimate from
/// the first frame) and FLAC (STREAMINFO). Null for other formats and for
/// files it can't make sense of. Reads at most a few hundred KB.
Duration? audioDuration(String path) {
  final RandomAccessFile f;
  try {
    f = File(path).openSync();
  } on FileSystemException {
    return null;
  }
  try {
    return switch (p.extension(path).toLowerCase()) {
      '.wav' || '.wave' => _wav(f),
      '.ogg' || '.oga' || '.opus' => _ogg(f),
      '.mp3' => _mp3(f),
      '.flac' => _flac(f),
      _ => null,
    };
  } on Object {
    // Truncated or odd files: no duration rather than an error.
    return null;
  } finally {
    f.closeSync();
  }
}

/// `1:05`, or `1:02:03` past an hour.
String formatDuration(Duration d) {
  final s = d.inSeconds;
  final h = s ~/ 3600;
  final m = (s % 3600) ~/ 60;
  final ss = (s % 60).toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$ss' : '$m:$ss';
}

Duration _seconds(double s) =>
    Duration(microseconds: (s * Duration.microsecondsPerSecond).round());

Uint8List _read(RandomAccessFile f, int at, int n) {
  f.setPositionSync(at);
  return f.readSync(n);
}

String _tag(Uint8List b, int at) => String.fromCharCodes(b, at, at + 4);

Duration? _wav(RandomAccessFile f) {
  final head = _read(f, 0, 12);
  if (head.length < 12 || _tag(head, 0) != 'RIFF' || _tag(head, 8) != 'WAVE') {
    return null;
  }
  final length = f.lengthSync();
  int? byteRate;
  var at = 12;
  while (at + 8 <= length) {
    final h = _read(f, at, 8);
    final size = ByteData.sublistView(h).getUint32(4, Endian.little);
    final id = _tag(h, 0);
    if (id == 'fmt ') {
      final fmt = _read(f, at + 8, 16);
      byteRate = ByteData.sublistView(fmt).getUint32(8, Endian.little);
    } else if (id == 'data') {
      if (byteRate == null || byteRate == 0) return null;
      // A streamed WAV may claim more data than the file holds.
      final data = size.clamp(0, length - at - 8);
      return _seconds(data / byteRate);
    }
    at += 8 + size + (size & 1);
  }
  return null;
}

Duration? _ogg(RandomAccessFile f) {
  final first = _read(f, 0, 512);
  if (first.length < 64 || _tag(first, 0) != 'OggS') return null;
  // The first page holds the codec id header right after its segment table.
  final segments = first[26];
  final body = 27 + segments;
  final d = ByteData.sublistView(first);
  double? rate;
  var preSkip = 0;
  if (first.length > body + 16 &&
      first[body] == 1 &&
      String.fromCharCodes(first, body + 1, body + 7) == 'vorbis') {
    rate = d.getUint32(body + 12, Endian.little).toDouble();
  } else if (String.fromCharCodes(first, body, body + 8) == 'OpusHead') {
    rate = 48000;
    preSkip = d.getUint16(body + 10, Endian.little);
  }
  if (rate == null || rate == 0) return null;

  // The last page's granule position counts the samples.
  final length = f.lengthSync();
  for (var window = 65536; ; window *= 4) {
    final start = (length - window).clamp(0, length);
    final tail = _read(f, start, length - start);
    for (var i = tail.length - 27; i >= 0; i--) {
      if (tail[i] == 0x4F &&
          tail[i + 1] == 0x67 &&
          tail[i + 2] == 0x67 &&
          tail[i + 3] == 0x53) {
        final granule = ByteData.sublistView(tail)
            .getInt64(i + 6, Endian.little);
        if (granule <= 0) continue;
        return _seconds((granule - preSkip).clamp(0, granule) / rate);
      }
    }
    if (start == 0 || window > 4 << 20) return null;
  }
}

Duration? _flac(RandomAccessFile f) {
  final h = _read(f, 0, 42);
  if (h.length < 42 || _tag(h, 0) != 'fLaC') return null;
  // STREAMINFO is always the first block: 4-byte block header, then
  // min/max block (4), min/max frame (6), then 20-bit rate, 3+5 bits,
  // 36-bit total samples.
  final s = 8 + 10;
  final rate = (h[s] << 12) | (h[s + 1] << 4) | (h[s + 2] >> 4);
  final total =
      ((h[s + 3] & 0x0F) << 32) |
      (h[s + 4] << 24) |
      (h[s + 5] << 16) |
      (h[s + 6] << 8) |
      h[s + 7];
  if (rate == 0 || total == 0) return null;
  return _seconds(total / rate);
}

const _mp3Bitrates = {
  // (MPEG-1, layer III) and (MPEG-2/2.5, layer III), kbit/s.
  1: [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320],
  2: [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160],
};
const _mp3Rates = {
  3: [44100, 48000, 32000], // MPEG-1
  2: [22050, 24000, 16000], // MPEG-2
  0: [11025, 12000, 8000], // MPEG-2.5
};

Duration? _mp3(RandomAccessFile f) {
  final length = f.lengthSync();
  var start = 0;
  final id3 = _read(f, 0, 10);
  if (id3.length == 10 && String.fromCharCodes(id3, 0, 3) == 'ID3') {
    // Syncsafe size, plus the header (and a footer when flagged).
    final size = (id3[6] << 21) | (id3[7] << 14) | (id3[8] << 7) | id3[9];
    start = 10 + size + ((id3[5] & 0x10) != 0 ? 10 : 0);
  }
  final buf = _read(f, start, 64 * 1024);
  for (var i = 0; i + 4 <= buf.length; i++) {
    if (buf[i] != 0xFF || (buf[i + 1] & 0xE0) != 0xE0) continue;
    final version = (buf[i + 1] >> 3) & 3; // 3 = MPEG-1, 2 = 2, 0 = 2.5
    final layer = (buf[i + 1] >> 1) & 3; // 1 = layer III
    final bitIndex = buf[i + 2] >> 4;
    final rateIndex = (buf[i + 2] >> 2) & 3;
    if (version == 1 || layer != 1 || bitIndex == 0 || bitIndex == 15) {
      continue;
    }
    if (rateIndex == 3) continue;
    final mono = (buf[i + 3] >> 6) == 3;
    final rate = _mp3Rates[version]![rateIndex];
    final kbps = _mp3Bitrates[version == 3 ? 1 : 2]![bitIndex];
    final samplesPerFrame = version == 3 ? 1152 : 576;
    final frameBytes =
        (samplesPerFrame ~/ 8) * kbps * 1000 ~/ rate + ((buf[i + 2] >> 1) & 1);
    // A second frame header right after this one rules out false syncs.
    final next = i + frameBytes;
    if (next + 2 <= buf.length &&
        (buf[next] != 0xFF || (buf[next + 1] & 0xE0) != 0xE0)) {
      continue;
    }

    // Xing / Info: after the side info, which depends on version and mode.
    final side = version == 3 ? (mono ? 17 : 32) : (mono ? 9 : 17);
    final x = i + 4 + side;
    if (x + 12 <= buf.length) {
      final tag = _tag(buf, x);
      if ((tag == 'Xing' || tag == 'Info') && (buf[x + 7] & 1) != 0) {
        final frames = ByteData.sublistView(buf).getUint32(x + 8);
        if (frames > 0) return _seconds(frames * samplesPerFrame / rate);
      }
    }
    // VBRI sits 32 bytes after the frame header.
    final v = i + 4 + 32;
    if (v + 18 <= buf.length && _tag(buf, v) == 'VBRI') {
      final frames = ByteData.sublistView(buf).getUint32(v + 14);
      if (frames > 0) return _seconds(frames * samplesPerFrame / rate);
    }
    // CBR estimate, minus a trailing ID3v1 tag.
    var audio = length - start - i;
    final tail = _read(f, length - 128, 3);
    if (length > 128 && String.fromCharCodes(tail) == 'TAG') audio -= 128;
    return _seconds(audio * 8 / (kbps * 1000));
  }
  return null;
}
