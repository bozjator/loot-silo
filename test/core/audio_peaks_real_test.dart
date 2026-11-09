// Read-only: decodes a sample of the user's real `assets_library`.
// Skipped where that folder does not exist.
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:loot_silo/core/audio/mp3_decoder.dart';
import 'package:loot_silo/core/audio/peak_sink.dart';
import 'package:loot_silo/core/audio_peaks.dart';
import 'package:path/path.dart' as p;

const library = '../assets_library';

void main() {
  final skip = Directory(library).existsSync() ? false : 'no $library';

  group('real library waveforms', skip: skip, () {
    late Map<String, List<String>> byFormat;
    setUpAll(() {
      byFormat = {};
      for (final e in Directory(library).listSync(recursive: true)) {
        if (e is! File) continue;
        final ext = p.extension(e.path).toLowerCase();
        if (ext == '.ogg' || ext == '.wav' || ext == '.mp3') {
          byFormat.putIfAbsent(ext, () => []).add(e.path);
        }
      }
      for (final list in byFormat.values) {
        list.sort();
      }
    });

    for (final ext in ['.ogg', '.wav', '.mp3']) {
      test('50 $ext files spread over the library decode', () {
        final all = byFormat[ext]!;
        expect(all.length, greaterThan(50));
        final failed = <String>[];
        for (var i = 0; i < 50; i++) {
          final path = all[i * all.length ~/ 50];
          final peaks = readAudioPeaks(path);
          if (peaks.length != peakCount) {
            failed.add(path);
            continue;
          }
          final top = peaks.reduce(math.max);
          // Scaled to the loudest, or all silence.
          expect(top == 1 || top == 0, isTrue, reason: path);
          expect(peaks.every((v) => v >= 0 && v <= 1), isTrue, reason: path);
        }
        expect(failed, isEmpty);
      });
    }

    test('a LAME tag trims the encoder delay and padding', () {
      final file = File(
        p.join(
          library,
          'ElvGames & Pegonthetrack',
          'Footsteps Sound Effects 1 - Universal Sound Effects',
          'MP3',
          'Footsteps_Metal_1.mp3',
        ),
      );
      if (!file.existsSync()) return markTestSkipped('file moved');
      final sink = PeakSink();
      expect(decodeMp3(file.readAsBytesSync(), sink), isTrue);
      // What GStreamer's decoder gives for it.
      expect(sink.samples, 36120);
    });
  });
}
