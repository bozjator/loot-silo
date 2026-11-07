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

  test('formatDuration', () {
    expect(formatDuration(const Duration(milliseconds: 1500)), '0:01');
    expect(formatDuration(const Duration(seconds: 65)), '1:05');
    expect(formatDuration(const Duration(seconds: 3723)), '1:02:03');
  });
}
