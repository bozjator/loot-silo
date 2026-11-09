import 'dart:math' as math;
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

/// What an audio file's headers say: its length and how it is stored.
/// Each part is null when the header doesn't tell.
class AudioInfo {
  const AudioInfo({
    this.duration,
    this.sampleRate,
    this.channels,
    this.bitDepth,
    this.kbps,
    this.vbr = false,
    this.approximate = false,
  });

  final Duration? duration;

  /// Samples per second (44100).
  final int? sampleRate;
  final int? channels;

  /// Bits per sample, for uncompressed and lossless formats.
  final int? bitDepth;

  /// Bitrate in kbit/s, for lossy formats.
  final int? kbps;

  /// MP3: the bitrate changes from frame to frame ([kbps] is the average).
  final bool vbr;

  /// [kbps] is a nominal or average figure (Ogg), shown as `~112 kbps`.
  final bool approximate;

  /// `44.1 kHz · Stereo · 16-bit`, `48 kHz · Mono · ~112 kbps`,
  /// `44.1 kHz · Stereo · VBR ~245 kbps`; unknown parts are left out.
  String get details => [
    if (sampleRate case final r? when r > 0) formatSampleRate(r),
    if (channels case final c? when c > 0) channelWords(c),
    if (bitDepth case final b? when b > 0) '$b-bit',
    if (kbps case final k? when k > 0)
      '${vbr ? 'VBR ~' : (approximate ? '~' : '')}$k kbps',
  ].join(' · ');

  @override
  String toString() => 'AudioInfo($duration, $details)';
}

/// `44.1 kHz`, `48 kHz`, `22.05 kHz`.
String formatSampleRate(int hz) {
  var s = (hz / 1000).toStringAsFixed(3);
  s = s.replaceFirst(RegExp(r'\.?0+$'), '');
  return '$s kHz';
}

/// `Mono`, `Stereo`, `6 ch`.
String channelWords(int channels) => switch (channels) {
  1 => 'Mono',
  2 => 'Stereo',
  _ => '$channels ch',
};

/// Play length of an audio file, read from its headers ([audioInfo]).
Duration? audioDuration(String path) => audioInfo(path)?.duration;

/// Length, sample rate, channels and bit depth or bitrate of an audio file,
/// read from its headers in pure Dart.
///
/// WAV (`fmt ` + `data` chunks), AIFF (`COMM`), Ogg Vorbis / Opus (id
/// header, granule position of the last page), MP3 (first frames, Xing/Info
/// or VBRI frame count, else a CBR estimate) and FLAC (STREAMINFO). Null for
/// other formats and for files it can't make sense of. Reads at most a few
/// hundred KB.
AudioInfo? audioInfo(String path) {
  final RandomAccessFile f;
  try {
    f = File(path).openSync();
  } on FileSystemException {
    return null;
  }
  try {
    return switch (p.extension(path).toLowerCase()) {
      '.wav' || '.wave' => _wav(f),
      '.aif' || '.aiff' || '.aifc' => _aiff(f),
      '.ogg' || '.oga' || '.opus' => _ogg(f),
      '.mp3' => _mp3(f),
      '.flac' => _flac(f),
      _ => null,
    };
  } on Object {
    // Truncated or odd files: nothing rather than an error.
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

AudioInfo? _wav(RandomAccessFile f) {
  final head = _read(f, 0, 12);
  if (head.length < 12 || _tag(head, 0) != 'RIFF' || _tag(head, 8) != 'WAVE') {
    return null;
  }
  final length = f.lengthSync();
  int? byteRate, rate, channels, bits;
  var at = 12;
  while (at + 8 <= length) {
    final h = _read(f, at, 8);
    final size = ByteData.sublistView(h).getUint32(4, Endian.little);
    final id = _tag(h, 0);
    if (id == 'fmt ') {
      final fmt = ByteData.sublistView(_read(f, at + 8, 16));
      channels = fmt.getUint16(2, Endian.little);
      rate = fmt.getUint32(4, Endian.little);
      byteRate = fmt.getUint32(8, Endian.little);
      bits = fmt.getUint16(14, Endian.little);
    } else if (id == 'data') {
      if (byteRate == null || byteRate == 0) return null;
      // A streamed WAV may claim more data than the file holds.
      final data = size.clamp(0, length - at - 8);
      return AudioInfo(
        duration: _seconds(data / byteRate),
        sampleRate: rate,
        channels: channels,
        bitDepth: bits,
      );
    }
    at += 8 + size + (size & 1);
  }
  return null;
}

/// AIFF / AIFF-C: big-endian chunks; `COMM` holds channels, frames, bits
/// and the rate as an 80-bit float.
AudioInfo? _aiff(RandomAccessFile f) {
  final head = _read(f, 0, 12);
  if (head.length < 12 ||
      _tag(head, 0) != 'FORM' ||
      (_tag(head, 8) != 'AIFF' && _tag(head, 8) != 'AIFC')) {
    return null;
  }
  final length = f.lengthSync();
  var at = 12;
  while (at + 8 <= length) {
    final h = _read(f, at, 8);
    final size = ByteData.sublistView(h).getUint32(4);
    if (_tag(h, 0) == 'COMM') {
      final c = _read(f, at + 8, 18);
      if (c.length < 18) return null;
      final d = ByteData.sublistView(c);
      final channels = d.getUint16(0);
      final frames = d.getUint32(2);
      final bits = d.getUint16(6);
      final rate = _extended(c, 8);
      if (rate <= 0) return null;
      return AudioInfo(
        duration: _seconds(frames / rate),
        sampleRate: rate.round(),
        channels: channels,
        bitDepth: bits,
      );
    }
    at += 8 + size + (size & 1);
  }
  return null;
}

/// An IEEE 754 80-bit extended float (AIFF sample rates).
double _extended(Uint8List b, int at) {
  final exponent = ((b[at] & 0x7F) << 8 | b[at + 1]) - 16383;
  var mantissa = 0.0;
  for (var i = 0; i < 8; i++) {
    mantissa = mantissa * 256 + b[at + 2 + i];
  }
  final v = mantissa * math.pow(2, exponent - 63);
  return (b[at] & 0x80) != 0 ? -v : v;
}

AudioInfo? _ogg(RandomAccessFile f) {
  final first = _read(f, 0, 512);
  if (first.length < 64 || _tag(first, 0) != 'OggS') return null;
  // The first page holds the codec id header right after its segment table.
  final segments = first[26];
  final body = 27 + segments;
  final d = ByteData.sublistView(first);
  double? rate;
  var preSkip = 0;
  int? channels, nominal;
  var opus = false;
  if (first.length > body + 28 &&
      first[body] == 1 &&
      String.fromCharCodes(first, body + 1, body + 7) == 'vorbis') {
    channels = first[body + 11];
    rate = d.getUint32(body + 12, Endian.little).toDouble();
    nominal = d.getInt32(body + 20, Endian.little);
  } else if (String.fromCharCodes(first, body, body + 8) == 'OpusHead') {
    // Opus always decodes at 48 kHz; the header's input rate is only a note.
    opus = true;
    rate = 48000;
    channels = first[body + 9];
    preSkip = d.getUint16(body + 10, Endian.little);
  }
  if (rate == null || rate == 0) return null;
  final length = f.lengthSync();
  final duration = _oggLength(f, length, rate, preSkip);
  // Vorbis' nominal bitrate, else (Opus, or no nominal) the file's average.
  int? kbps;
  if (!opus && nominal != null && nominal > 0) {
    kbps = (nominal / 1000).round();
  } else if (duration != null && duration > Duration.zero) {
    kbps = (length * 8 / (duration.inMicroseconds / 1e3)).round();
  }
  return AudioInfo(
    duration: duration,
    sampleRate: rate.round(),
    channels: channels,
    kbps: kbps,
    approximate: true,
  );
}

/// The last page's granule position counts the samples.
Duration? _oggLength(RandomAccessFile f, int length, double rate, int preSkip) {
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

AudioInfo? _flac(RandomAccessFile f) {
  final h = _read(f, 0, 42);
  if (h.length < 42 || _tag(h, 0) != 'fLaC') return null;
  // STREAMINFO is always the first block: 4-byte block header, then
  // min/max block (4), min/max frame (6), then 20-bit rate, 3-bit
  // channels - 1, 5-bit bits per sample - 1, 36-bit total samples.
  final s = 8 + 10;
  final rate = (h[s] << 12) | (h[s + 1] << 4) | (h[s + 2] >> 4);
  final channels = ((h[s + 2] >> 1) & 7) + 1;
  final bits = (((h[s + 2] & 1) << 4) | (h[s + 3] >> 4)) + 1;
  final total =
      ((h[s + 3] & 0x0F) << 32) |
      (h[s + 4] << 24) |
      (h[s + 5] << 16) |
      (h[s + 6] << 8) |
      h[s + 7];
  if (rate == 0 || total == 0) return null;
  return AudioInfo(
    duration: _seconds(total / rate),
    sampleRate: rate,
    channels: channels,
    bitDepth: bits,
  );
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

/// How many frames after the first are checked for a changing bitrate.
const _mp3ProbeFrames = 12;

AudioInfo? _mp3(RandomAccessFile f) {
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
    final first = _mp3Frame(buf, i);
    if (first == null) continue;
    final (:version, :rate, :kbps, :bytes, :mono) = first;
    final samplesPerFrame = version == 3 ? 1152 : 576;
    // A second frame header right after this one rules out false syncs.
    final next = i + bytes;
    if (next + 2 <= buf.length &&
        (buf[next] != 0xFF || (buf[next + 1] & 0xE0) != 0xE0)) {
      continue;
    }
    AudioInfo info(Duration? d, {required bool vbr, int? avg}) => AudioInfo(
      duration: d,
      sampleRate: rate,
      channels: mono ? 1 : 2,
      kbps: avg ?? kbps,
      vbr: vbr,
    );
    // The audio's byte count, minus a trailing ID3v1 tag.
    var audio = length - start - i;
    final tail = _read(f, length - 128, 3);
    if (length > 128 && String.fromCharCodes(tail) == 'TAG') audio -= 128;
    int? average(Duration d, int byteCount) => d > Duration.zero
        ? (byteCount * 8 / (d.inMicroseconds / 1e3)).round()
        : null;

    // Xing (VBR) / Info (CBR): after the side info, which depends on
    // version and mode.
    final side = version == 3 ? (mono ? 17 : 32) : (mono ? 9 : 17);
    final x = i + 4 + side;
    if (x + 16 <= buf.length) {
      final tag = _tag(buf, x);
      final flags = buf[x + 7];
      if ((tag == 'Xing' || tag == 'Info') && (flags & 1) != 0) {
        final frames = ByteData.sublistView(buf).getUint32(x + 8);
        if (frames > 0) {
          final d = _seconds(frames * samplesPerFrame / rate);
          final byteCount = (flags & 2) != 0
              ? ByteData.sublistView(buf).getUint32(x + 12)
              : audio;
          return tag == 'Xing'
              ? info(d, vbr: true, avg: average(d, byteCount))
              : info(d, vbr: false);
        }
      }
    }
    // VBRI sits 32 bytes after the frame header.
    final v = i + 4 + 32;
    if (v + 18 <= buf.length && _tag(buf, v) == 'VBRI') {
      final b = ByteData.sublistView(buf);
      final frames = b.getUint32(v + 14);
      if (frames > 0) {
        final d = _seconds(frames * samplesPerFrame / rate);
        return info(d, vbr: true, avg: average(d, b.getUint32(v + 10)));
      }
    }
    // No tag: a VBR file without one still shows it by frames of
    // differing bitrates.
    final seen = [kbps];
    var at = next;
    while (seen.length <= _mp3ProbeFrames && at + 4 <= buf.length) {
      final frame = _mp3Frame(buf, at);
      if (frame == null) break;
      seen.add(frame.kbps);
      at += frame.bytes;
    }
    if (seen.any((k) => k != kbps)) {
      final avg = seen.reduce((a, b) => a + b) / seen.length;
      final d = _seconds(audio * 8 / (avg * 1000));
      return info(d, vbr: true, avg: avg.round());
    }
    // CBR estimate.
    return info(_seconds(audio * 8 / (kbps * 1000)), vbr: false);
  }
  return null;
}

/// The layer III frame header at [i], if there is a valid one.
({int version, int rate, int kbps, int bytes, bool mono})? _mp3Frame(
  Uint8List buf,
  int i,
) {
  if (i + 4 > buf.length) return null;
  if (buf[i] != 0xFF || (buf[i + 1] & 0xE0) != 0xE0) return null;
  final version = (buf[i + 1] >> 3) & 3; // 3 = MPEG-1, 2 = 2, 0 = 2.5
  final layer = (buf[i + 1] >> 1) & 3; // 1 = layer III
  final bitIndex = buf[i + 2] >> 4;
  final rateIndex = (buf[i + 2] >> 2) & 3;
  if (version == 1 || layer != 1 || bitIndex == 0 || bitIndex == 15) {
    return null;
  }
  if (rateIndex == 3) return null;
  final rate = _mp3Rates[version]![rateIndex];
  final kbps = _mp3Bitrates[version == 3 ? 1 : 2]![bitIndex];
  final samplesPerFrame = version == 3 ? 1152 : 576;
  final bytes =
      (samplesPerFrame ~/ 8) * kbps * 1000 ~/ rate + ((buf[i + 2] >> 1) & 1);
  return (
    version: version,
    rate: rate,
    kbps: kbps,
    bytes: bytes,
    mono: (buf[i + 3] >> 6) == 3,
  );
}
