import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:loot_silo/core/audio/mp3_decoder.dart';
import 'package:loot_silo/core/audio/peak_sink.dart';
import 'package:loot_silo/core/audio/vorbis_decoder.dart';
import 'package:loot_silo/core/audio/wav_decoder.dart';
import 'package:loot_silo/core/audio_peaks.dart';
import 'package:path/path.dart' as p;

// The OGG / MP3 fixtures were encoded once from WAVs made by a script
// (CC0, our own): `steps` is a 440 Hz tone, 0.5 s each at 0.225, 0.45, 0.9
// and 0.45; `click` is 2 s of silence with a 10 ms burst at 1.0 s; `stereo`
// is loud on the left for 1 s, then loud on the right. Encoded with
// GStreamer's vorbisenc (q 0.1) and lamemp3enc (64 kbit/s; the stereo file
// came out as MPEG-2 at 24 kHz).
const fixtures = 'test/fixtures/audio';

Float32List peaksOf(String name) =>
    readAudioPeaks(p.join(fixtures, name), buckets: 200);

/// The loudest peak in buckets [from, to).
double top(Float32List v, int from, int to) =>
    v.sublist(from, to).reduce(math.max);

double bottom(Float32List v, int from, int to) =>
    v.sublist(from, to).reduce(math.min);

/// A RIFF WAVE file around [data] with the given format chunk fields.
Uint8List wav(
  Uint8List data, {
  int format = 1,
  int channels = 1,
  int rate = 8000,
  int bits = 16,
  bool extensible = false,
  bool junkFirst = false,
  int? dataSize,
}) {
  final b = BytesBuilder();
  void u16(int v) => b.add([v & 255, v >> 8]);
  void u32(int v) => b.add([v & 255, v >> 8 & 255, v >> 16 & 255, v >> 24]);
  b.add('RIFF'.codeUnits);
  u32(0);
  b.add('WAVE'.codeUnits);
  if (junkFirst) {
    // An odd-sized chunk before fmt: padded to an even size.
    b.add('LIST'.codeUnits);
    u32(3);
    b.add([1, 2, 3, 0]);
  }
  b.add('fmt '.codeUnits);
  u32(extensible ? 40 : 16);
  u16(extensible ? 0xFFFE : format);
  u16(channels);
  u32(rate);
  u32(rate * channels * bits ~/ 8);
  u16(channels * bits ~/ 8);
  u16(bits);
  if (extensible) {
    u16(22);
    u16(bits);
    u32(0);
    u16(format);
    b.add(List.filled(14, 0));
  }
  b.add('data'.codeUnits);
  u32(dataSize ?? data.length);
  b.add(data);
  return b.toBytes();
}

/// Mono 16-bit samples: [first] then [second], [n] each.
Uint8List pcm16(double first, double second, int n) {
  final d = ByteData(n * 4);
  for (var i = 0; i < 2 * n; i++) {
    final a = i < n ? first : second;
    d.setInt16(i * 2, (a * 32767 * (i.isEven ? 1 : -1)).round(), Endian.little);
  }
  return d.buffer.asUint8List();
}

void main() {
  group('PeakSink', () {
    test('folds blocks into buckets and scales the loudest to 1', () {
      final sink = PeakSink();
      for (var i = 0; i < PeakSink.block * 4; i++) {
        sink.add(i < PeakSink.block * 2 ? 0.25 : -0.5);
      }
      expect(sink.samples, PeakSink.block * 4);
      expect(sink.finish(2), [0.5, 1.0]);
    });

    test('fewer blocks than buckets repeat; silence stays zero', () {
      final short = PeakSink()..add(0.3);
      expect(short.finish(4), [1, 1, 1, 1]);
      final silent = PeakSink();
      for (var i = 0; i < 100; i++) {
        silent.add(0);
      }
      expect(silent.finish(3), [0, 0, 0]);
      expect(PeakSink().finish(3), isEmpty);
    });

    test('addPeak and addAll count like single samples', () {
      final sink = PeakSink()
        ..addPeak(0.5, PeakSink.block)
        ..addAll(Float64List.fromList(List.filled(PeakSink.block, -1)), 32);
      expect(sink.samples, 64);
      expect(sink.finish(2), [0.5, 1.0]);
    });
  });

  group('WAV', () {
    Float32List decode(Uint8List bytes) =>
        decodePeaks(bytes, '.wav', buckets: 2);

    test('16-bit PCM, also after an odd chunk and as extensible', () {
      final data = pcm16(0.25, 1, 4000);
      expect(decode(wav(data))[0], closeTo(0.25, 0.001));
      expect(decode(wav(data, junkFirst: true))[0], closeTo(0.25, 0.001));
      expect(decode(wav(data, extensible: true))[0], closeTo(0.25, 0.001));
    });

    test('8, 24 and 32-bit integers, 32 and 64-bit floats', () {
      Uint8List samples(int bits, void Function(ByteData, int, double) put) {
        final width = bits ~/ 8;
        final d = ByteData(8000 * width);
        for (var i = 0; i < 8000; i++) {
          put(d, i * width, (i < 4000 ? 0.25 : 1.0) * (i.isEven ? 1 : -1));
        }
        return d.buffer.asUint8List();
      }

      final eight = samples(
        8,
        (d, at, v) => d.setUint8(at, (128 + v * 127).round()),
      );
      final s24 = samples(24, (d, at, v) {
        final x = (v * 8388607).round();
        d
          ..setUint8(at, x & 255)
          ..setUint8(at + 1, x >> 8 & 255)
          ..setInt8(at + 2, x >> 16);
      });
      final s32 = samples(
        32,
        (d, at, v) => d.setInt32(at, (v * 2147483647).round(), Endian.little),
      );
      final f32 = samples(32, (d, at, v) => d.setFloat32(at, v, Endian.little));
      final f64 = samples(64, (d, at, v) => d.setFloat64(at, v, Endian.little));
      expect(decode(wav(eight, bits: 8))[0], closeTo(0.25, 0.01));
      expect(decode(wav(s24, bits: 24))[0], closeTo(0.25, 0.001));
      expect(decode(wav(s32, bits: 32))[0], closeTo(0.25, 0.001));
      expect(decode(wav(f32, format: 3, bits: 32))[0], closeTo(0.25, 0.001));
      expect(decode(wav(f64, format: 3, bits: 64))[0], closeTo(0.25, 0.001));
    });

    test('stereo is mixed to mono', () {
      // Left full scale, right silent, then both at half.
      final d = ByteData(8000 * 4);
      for (var i = 0; i < 8000; i++) {
        d
          ..setInt16(i * 4, i < 4000 ? 32767 : 16384, Endian.little)
          ..setInt16(i * 4 + 2, i < 4000 ? 0 : 16384, Endian.little);
      }
      final v = decode(wav(d.buffer.asUint8List(), channels: 2));
      expect(v[0], closeTo(1.0, 0.001));
      expect(v[1], closeTo(1.0, 0.001));
    });

    test('a streamed size (0) reads to the end; ADPCM has no waveform', () {
      final data = pcm16(0.5, 1, 4000);
      expect(decode(wav(data, dataSize: 0))[0], closeTo(0.5, 0.001));
      expect(decode(wav(data, dataSize: 1 << 30))[0], closeTo(0.5, 0.001));
      expect(decode(wav(data, format: 2, bits: 4)), isEmpty);
      expect(decode(Uint8List.fromList('RIFF....WAVE'.codeUnits)), isEmpty);
    });
  });

  group('MP3 and Ogg Vorbis', () {
    for (final ext in ['ogg', 'mp3']) {
      test('$ext: a stepped tone keeps its steps', () {
        final v = peaksOf('steps.$ext');
        expect(v, hasLength(200));
        // Clear of the edges (the MP3 starts ~25 ms late: encoder delay).
        for (final (from, to, level) in [
          (10, 40, 0.25),
          (60, 90, 0.5),
          (110, 140, 1.0),
          (160, 190, 0.5),
        ]) {
          expect(top(v, from, to), closeTo(level, 0.06), reason: '$from');
          expect(bottom(v, from, to), closeTo(level, 0.08), reason: '$from');
        }
      });

      test('$ext: a click sits in the middle of the silence', () {
        final v = peaksOf('click.$ext');
        final loudest = v.indexOf(1.0);
        expect(loudest, inInclusiveRange(98, 104));
        expect(top(v, 0, 95), lessThan(0.05));
        expect(top(v, 110, 200), lessThan(0.05));
      });

      test('$ext: both stereo channels are mixed in', () {
        final v = peaksOf('stereo.$ext');
        final first = top(v, 20, 80);
        final second = top(v, 120, 180);
        // Left only would be 0.8 vs 0.1.
        expect(second / first, inInclusiveRange(0.8, 1.25));
      });

      test('$ext: a truncated file shows what it has; junk shows nothing', () {
        final bytes = File(p.join(fixtures, 'steps.$ext')).readAsBytesSync();
        final half = decodePeaks(bytes.sublist(0, bytes.length ~/ 2), '.$ext');
        expect(half, hasLength(peakCount));
        expect(half.reduce(math.max), 1.0);
        final junk = Uint8List.fromList([
          for (var i = 0; i < 5000; i++) (i * 7919 + 13) % 256,
        ]);
        expect(decodePeaks(junk, '.$ext'), isEmpty);
        expect(decodePeaks(Uint8List(0), '.$ext'), isEmpty);
      });
    }

    test('the 1.5 s tones decode to their full length', () {
      // MPEG-1 22.05 kHz CBR and VBR (with a LAME tag), Vorbis.
      for (final (name, samples) in [
        ('tone_cbr.mp3', 34560),
        ('tone_vbr.mp3', 34560),
        ('tone.ogg', 33075),
      ]) {
        final sink = PeakSink();
        final bytes = File(p.join(fixtures, name)).readAsBytesSync();
        expect(
          name.endsWith('mp3')
              ? decodeMp3(bytes, sink)
              : decodeVorbis(bytes, sink),
          isTrue,
        );
        expect(sink.samples, samples, reason: name);
      }
    });

    test('WAV source and decoders agree on the same tone', () {
      final wavSink = PeakSink();
      decodeWav(File(p.join(fixtures, 'tone.wav')).readAsBytesSync(), wavSink);
      final reference = wavSink.finish(50);
      final ogg = readAudioPeaks(p.join(fixtures, 'tone.ogg'), buckets: 50);
      for (var i = 5; i < 45; i++) {
        expect(ogg[i], closeTo(reference[i], 0.05), reason: '$i');
      }
    });

    test('Opus, FLAC and unknown files have no waveform', () {
      final tmp = Directory.systemTemp.createTempSync('peaks');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final opus = File(p.join(tmp.path, 'opus.ogg'))
        ..writeAsBytesSync(
          File(p.join(fixtures, 'tone.opus')).readAsBytesSync(),
        );
      expect(readAudioPeaks(opus.path), isEmpty);
      expect(readAudioPeaks(p.join(fixtures, 'tone.flac')), isEmpty);
      expect(hasWaveform('a.flac'), isFalse);
      expect(hasWaveform('a.OGG'), isTrue);
      expect(readAudioPeaks(p.join(tmp.path, 'missing.wav')), isEmpty);
    });
  });

  group('AudioPeaksCache', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('peaks_cache'));
    tearDown(() => tmp.deleteSync(recursive: true));

    String file(String name) =>
        (File(p.join(tmp.path, name))..writeAsBytesSync([1])).path;

    test(
      'reads once per file, keeps failures, skips unknown formats',
      () async {
        final reads = <String>[];
        final cache = AudioPeaksCache(
          read: (path) async {
            reads.add(p.basename(path));
            if (path.endsWith('bad.ogg')) throw StateError('broken');
            return Float32List.fromList([0.5, 1]);
          },
        );
        final a = file('a.ogg');
        expect(cache.peek(a), isNull);
        expect(await cache.load(a), [0.5, 1]);
        expect(await cache.load(a), [0.5, 1]);
        expect(cache.peek(a), [0.5, 1]);
        // Written once: writing it again would change its date.
        final bad = file('bad.ogg');
        expect(await cache.load(bad), isEmpty);
        expect(await cache.load(bad), isEmpty);
        expect(await cache.load(file('c.flac')), isEmpty);
        expect(await cache.load(p.join(tmp.path, 'gone.wav')), isEmpty);
        expect(reads, ['a.ogg', 'bad.ogg']);
      },
    );

    test(
      'forgets the oldest past capacity; a changed file is read again',
      () async {
        var reads = 0;
        final cache = AudioPeaksCache(
          capacity: 2,
          read: (_) async {
            reads++;
            return Float32List(1);
          },
        );
        final a = file('a.wav');
        await cache.load(a);
        await cache.load(file('b.wav'));
        await cache.load(file('c.wav'));
        expect(cache.length, 2);
        await cache.load(a);
        expect(reads, 4);
        File(a).setLastModifiedSync(DateTime(2001));
        await cache.load(a);
        expect(reads, 5);
      },
    );

    test('decodes at most [parallel] files at once, in order', () async {
      var running = 0;
      var most = 0;
      final order = <String>[];
      final gates = <Completer<void>>[];
      final cache = AudioPeaksCache(
        parallel: 2,
        read: (path) async {
          order.add(p.basename(path));
          running++;
          most = math.max(most, running);
          final gate = Completer<void>();
          gates.add(gate);
          await gate.future;
          running--;
          return Float32List(1);
        },
      );
      final all = [
        for (final n in ['1.mp3', '2.mp3', '3.mp3', '4.mp3'])
          cache.load(file(n)),
      ];
      await Future<void>.delayed(Duration.zero);
      expect(order, ['1.mp3', '2.mp3']);
      while (gates.isNotEmpty) {
        gates.removeAt(0).complete();
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);
      }
      await Future.wait(all);
      expect(order, ['1.mp3', '2.mp3', '3.mp3', '4.mp3']);
      expect(most, 2);
    });

    test('the real decoder runs in an isolate', () async {
      final cache = AudioPeaksCache();
      final peaks = await cache.load(p.join(fixtures, 'steps.ogg'));
      expect(peaks, hasLength(peakCount));
    });
  });
}
