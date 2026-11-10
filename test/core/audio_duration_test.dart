import 'dart:io';
import 'dart:typed_data';

import 'package:loot_silo/core/audio_duration.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  const fixtures = 'test/fixtures/audio';

  // Reference lengths from gst-discoverer (the engine the Linux player
  // uses). The fixtures are 1.5 s tones made with GStreamer encoders.
  const reference = {
    'tone.wav': 1.5,
    'tone.ogg': 1.5,
    'tone.opus': 1.5,
    'tone.flac': 1.5,
    'tone_cbr.mp3': 1.567,
    'tone_vbr.mp3': 1.593,
  };

  for (final MapEntry(key: name, value: seconds) in reference.entries) {
    test('$name matches the reference length', () {
      final d = audioDuration(p.join(fixtures, name));
      expect(d, isNotNull);
      expect(d!.inMicroseconds / 1e6, closeTo(seconds, 0.06));
    });
  }

  test('unknown formats and broken files give null', () {
    final tmp = Directory.systemTemp.createTempSync('dur');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final junk = File(p.join(tmp.path, 'x.wav'))
      ..writeAsBytesSync(Uint8List.fromList(List.filled(40, 7)));
    final cut = File(p.join(tmp.path, 'cut.ogg'))
      ..writeAsBytesSync(
        File(p.join(fixtures, 'tone.ogg')).readAsBytesSync().sublist(0, 30),
      );
    expect(audioDuration(junk.path), isNull);
    expect(audioDuration(cut.path), isNull);
    expect(audioDuration(p.join(fixtures, '..', 'nope.mp3')), isNull);
    expect(audioDuration(p.join(fixtures, 'tone.wav.mid')), isNull);
  });

  group('AudioInfo (M68)', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('info'));
    tearDown(() => tmp.deleteSync(recursive: true));

    String write(String name, List<int> bytes) {
      final f = File(p.join(tmp.path, name))..writeAsBytesSync(bytes);
      return f.path;
    }

    for (final bits in [8, 16, 24]) {
      for (final channels in [1, 2]) {
        test('WAV $bits-bit, $channels ch', () {
          final info = audioInfo(
            write('a.wav', _wav(rate: 44100, channels: channels, bits: bits)),
          )!;
          expect(info.sampleRate, 44100);
          expect(info.channels, channels);
          expect(info.bitDepth, bits);
          expect(info.duration, const Duration(milliseconds: 100));
          expect(
            info.details,
            '44.1 kHz · ${channels == 1 ? 'Mono' : 'Stereo'} · $bits-bit',
          );
        });
      }
    }

    test('WAV with more channels, other rates', () {
      expect(
        audioInfo(write('b.wav', _wav(rate: 48000, channels: 6, bits: 16)))!
            .details,
        '48 kHz · 6 ch · 16-bit',
      );
      expect(
        audioInfo(write('c.wav', _wav(rate: 22050, channels: 1, bits: 8)))!
            .details,
        '22.05 kHz · Mono · 8-bit',
      );
    });

    test('AIFF: COMM chunk with an 80-bit rate', () {
      final info = audioInfo(write('a.aiff', _aiff(channels: 2, bits: 24)))!;
      expect(info.details, '44.1 kHz · Stereo · 24-bit');
      expect(info.duration, const Duration(seconds: 1));
    });

    // The committed fixtures (gst-discoverer agrees on rate and channels).
    const fixtures = 'test/fixtures/audio';
    const expected = {
      'tone.wav': '22.05 kHz · Mono · 16-bit',
      'tone.flac': '22.05 kHz · Mono · 16-bit',
      'tone.ogg': '22.05 kHz · Mono · ~30 kbps',
      'stereo.ogg': '44.1 kHz · Stereo · ~80 kbps',
      'tone.opus': '48 kHz · Mono · ~20 kbps',
      'tone_cbr.mp3': '22.05 kHz · Mono · 32 kbps',
      'stereo.mp3': '24 kHz · Stereo · VBR ~64 kbps',
    };
    for (final MapEntry(key: name, value: details) in expected.entries) {
      test('$name: $details', () {
        expect(audioInfo(p.join(fixtures, name))!.details, details);
      });
    }

    test('VBR MP3: flagged, average bitrate', () {
      final info = audioInfo(p.join(fixtures, 'tone_vbr.mp3'))!;
      expect(info.vbr, isTrue);
      expect(info.details, startsWith('22.05 kHz · Mono · VBR ~'));
      expect(audioInfo(p.join(fixtures, 'tone_cbr.mp3'))!.vbr, isFalse);
    });

    test('unknown parts are left out', () {
      expect(const AudioInfo(sampleRate: 44100).details, '44.1 kHz');
      expect(
        const AudioInfo(channels: 2, kbps: 128).details,
        'Stereo · 128 kbps',
      );
      expect(const AudioInfo().details, '');
      expect(audioInfo(p.join(fixtures, 'nope.m4a')), isNull);
    });

    test('M72: the card line: channels, kHz, bit depth or ~ bitrate', () {
      expect(
        const AudioInfo(
          sampleRate: 44100,
          channels: 2,
          bitDepth: 16,
        ).shortDetails,
        'Stereo · 44.1 kHz · 16-bit',
      );
      expect(
        const AudioInfo(sampleRate: 44100, channels: 2, kbps: 320).shortDetails,
        'Stereo · 44.1 kHz · 320 kbps',
      );
      // VBR and nominal rates: `~`, no "VBR".
      expect(
        const AudioInfo(
          sampleRate: 48000,
          channels: 1,
          kbps: 245,
          vbr: true,
        ).shortDetails,
        'Mono · 48 kHz · ~245 kbps',
      );
      expect(
        const AudioInfo(channels: 1, kbps: 112, approximate: true).shortDetails,
        'Mono · ~112 kbps',
      );
      expect(const AudioInfo(channels: 6).shortDetails, '6 ch');
      expect(const AudioInfo().shortDetails, '');
      final mp3 = audioInfo(p.join(fixtures, 'tone_cbr.mp3'))!;
      expect(
        mp3.shortDetails,
        matches(RegExp(r'^Mono · 22\.05 kHz · \d+ kbps$')),
      );
    });

    test(
      'real library: 50 files per format read without errors (read-only)',
      () {
        final lib = Directory('../assets_library');
        final byFormat = <String, List<String>>{};
        for (final f in lib.listSync(recursive: true).whereType<File>()) {
          final ext = p.extension(f.path).toLowerCase();
          if (!const ['.wav', '.ogg', '.mp3', '.flac', '.opus'].contains(ext)) {
            continue;
          }
          final list = byFormat.putIfAbsent(ext, () => []);
          if (list.length < 50) list.add(f.path);
        }
        expect(byFormat, isNotEmpty);
        for (final MapEntry(key: ext, value: files) in byFormat.entries) {
          for (final path in files) {
            final info = audioInfo(path);
            expect(info, isNotNull, reason: path);
            expect(info!.sampleRate, greaterThan(0), reason: path);
            expect(info.channels, greaterThan(0), reason: path);
            expect(info.duration, isNotNull, reason: path);
            if (ext == '.wav' || ext == '.flac') {
              expect(info.bitDepth, greaterThan(0), reason: path);
            } else {
              expect(info.kbps, greaterThan(0), reason: path);
            }
          }
        }
      },
      skip: Directory('../assets_library').existsSync()
          ? false
          : 'no ../assets_library',
    );
  });

  test('formatDuration', () {
    expect(formatDuration(const Duration(milliseconds: 1500)), '0:01');
    expect(formatDuration(const Duration(seconds: 65)), '1:05');
    expect(formatDuration(const Duration(seconds: 3723)), '1:02:03');
  });
}

/// A PCM WAV of [frames] silent frames.
Uint8List _wav({
  required int rate,
  required int channels,
  required int bits,
  int frames = 4410,
}) {
  final block = channels * bits ~/ 8;
  final data = frames * block;
  final b = ByteData(44 + data);
  void tag(int at, String t) {
    for (var i = 0; i < 4; i++) {
      b.setUint8(at + i, t.codeUnitAt(i));
    }
  }

  tag(0, 'RIFF');
  b.setUint32(4, 36 + data, Endian.little);
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  b.setUint32(16, 16, Endian.little);
  b.setUint16(20, 1, Endian.little);
  b.setUint16(22, channels, Endian.little);
  b.setUint32(24, rate, Endian.little);
  b.setUint32(28, rate * block, Endian.little);
  b.setUint16(32, block, Endian.little);
  b.setUint16(34, bits, Endian.little);
  tag(36, 'data');
  b.setUint32(40, data, Endian.little);
  return b.buffer.asUint8List();
}

/// An AIFF with a `COMM` chunk only (44.1 kHz as an 80-bit float).
Uint8List _aiff({
  required int channels,
  required int bits,
  int frames = 44100,
}) {
  final b = ByteData(12 + 8 + 18);
  void tag(int at, String t) {
    for (var i = 0; i < 4; i++) {
      b.setUint8(at + i, t.codeUnitAt(i));
    }
  }

  tag(0, 'FORM');
  b.setUint32(4, 4 + 8 + 18);
  tag(8, 'AIFF');
  tag(12, 'COMM');
  b.setUint32(16, 18);
  b.setUint16(20, channels);
  b.setUint32(22, frames);
  b.setUint16(26, bits);
  // 44100 = 0x400E AC44 0000 0000 0000.
  const rate = [0x40, 0x0E, 0xAC, 0x44, 0, 0, 0, 0, 0, 0];
  for (var i = 0; i < rate.length; i++) {
    b.setUint8(28 + i, rate[i]);
  }
  return b.buffer.asUint8List();
}
