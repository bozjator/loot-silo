import 'package:loot_silo/core/audio_duration.dart';
import 'package:loot_silo/core/audio_formats.dart';
import 'package:loot_silo/state/settings.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  List<List<String>> files(List<String> audio) => [
    for (final t in groupAudioFormats(audio)) t.files,
  ];

  test('one name in several formats is one track, formats in order', () {
    expect(
      files([
        'Cute BGM - Snow.mp3',
        'Cute BGM - Snow.ogg',
        'Cute BGM - Snow (Loopable).wav',
        'Cute BGM - Snow.wav',
      ]),
      [
        ['Cute BGM - Snow.ogg', 'Cute BGM - Snow.wav', 'Cute BGM - Snow.mp3'],
        ['Cute BGM - Snow (Loopable).wav'],
      ],
    );
  });

  test('format folders, at any depth and in any case, are left out', () {
    final tracks = groupAudioFormats([
      'MP3/Attack Spells/Fire - 1.mp3',
      'MP3/Crossbow - 1.mp3',
      'OGG/Attack Spells/Fire - 1.ogg',
      'OGG/CrossBow - 1.ogg',
      'Audio/wav files/Crossbow - 1.wav',
      'sfx/Crossbow - 1.wav',
    ]);
    expect(
      [for (final t in tracks) t.files],
      [
        ['OGG/Attack Spells/Fire - 1.ogg', 'MP3/Attack Spells/Fire - 1.mp3'],
        ['OGG/CrossBow - 1.ogg', 'MP3/Crossbow - 1.mp3'],
        ['Audio/wav files/Crossbow - 1.wav'],
        ['sfx/Crossbow - 1.wav'],
      ],
    );
    expect(tracks.map((t) => t.folder), ['Attack Spells', '.', 'Audio', 'sfx']);
  });

  test('two files of one format stay two tracks', () {
    expect(files(['a.ogg', 'A.OGG', 'a.wav']), [
      ['a.ogg', 'a.wav'],
      ['A.OGG'],
    ]);
  });

  test('a folder named like a format only counts as one for folders', () {
    // `ogg.wav` is a file name, not a folder.
    expect(files(['ogg.wav', 'ogg.mp3']), [
      ['ogg.wav', 'ogg.mp3'],
    ]);
  });

  test('pick: the preferred format, else the first in order', () {
    final t = groupAudioFormats(['a.mp3', 'a.wav']).single;
    expect(t.pick('mp3'), 'a.mp3');
    expect(t.pick('ogg'), 'a.wav');
  });

  test('the preferred format is saved; unknown ones fall back to ogg', () {
    expect(const AppSettings().audioFormat, 'ogg');
    final saved = const AppSettings().copyWith(audioFormat: 'mp3').toJson();
    expect(AppSettings.fromJson(saved).audioFormat, 'mp3');
    expect(AppSettings.fromJson({'audio_format': 'xyz'}).audioFormat, 'ogg');
  });

  group('M73: sortAudioTracks', () {
    // a: long, big, 48 kHz stereo 16-bit; b: short, small, 22 kHz mono
    // 128 kbps; c: nothing read; d: 44.1 kHz stereo 24-bit, as long as a.
    final tracks = groupAudioFormats(['a.wav', 'b.ogg', 'c.m4a', 'd.flac']);
    const infos = {
      'a.wav': AudioInfo(
        duration: Duration(seconds: 9),
        sampleRate: 48000,
        channels: 2,
        bitDepth: 16,
      ),
      'b.ogg': AudioInfo(
        duration: Duration(seconds: 1),
        sampleRate: 22050,
        channels: 1,
        kbps: 128,
      ),
      'd.flac': AudioInfo(
        duration: Duration(seconds: 9),
        sampleRate: 44100,
        channels: 2,
        bitDepth: 24,
      ),
    };
    const sizes = {'a.wav': 900, 'b.ogg': 100, 'd.flac': 500};
    List<String> order(AudioSort key, {bool desc = false}) => [
      for (final t in sortAudioTracks(
        tracks,
        key,
        descending: desc,
        fileOf: (t) => t.files.first,
        sizeOf: (rel) => sizes[rel],
        infoOf: (rel) => infos[rel],
      ))
        t.files.first,
    ];

    test('name keeps the pack order, reversed when descending', () {
      expect(order(AudioSort.name), ['a.wav', 'b.ogg', 'c.m4a', 'd.flac']);
      expect(order(AudioSort.name, desc: true), [
        'd.flac',
        'c.m4a',
        'b.ogg',
        'a.wav',
      ]);
    });

    test('each key, both ways; missing values last; ties keep order', () {
      final expected = {
        // a and d tie on 9 s: pack order both ways.
        AudioSort.duration: (
          ['b.ogg', 'a.wav', 'd.flac', 'c.m4a'],
          ['a.wav', 'd.flac', 'b.ogg', 'c.m4a'],
        ),
        AudioSort.size: (
          ['b.ogg', 'd.flac', 'a.wav', 'c.m4a'],
          ['a.wav', 'd.flac', 'b.ogg', 'c.m4a'],
        ),
        AudioSort.sampleRate: (
          ['b.ogg', 'd.flac', 'a.wav', 'c.m4a'],
          ['a.wav', 'd.flac', 'b.ogg', 'c.m4a'],
        ),
        AudioSort.channels: (
          ['b.ogg', 'a.wav', 'd.flac', 'c.m4a'],
          ['a.wav', 'd.flac', 'b.ogg', 'c.m4a'],
        ),
        // Only b has a bitrate; the rest go last in pack order.
        AudioSort.bitrate: (
          ['b.ogg', 'a.wav', 'c.m4a', 'd.flac'],
          ['b.ogg', 'a.wav', 'c.m4a', 'd.flac'],
        ),
        AudioSort.bitDepth: (
          ['a.wav', 'd.flac', 'b.ogg', 'c.m4a'],
          ['d.flac', 'a.wav', 'b.ogg', 'c.m4a'],
        ),
      };
      for (final MapEntry(key: key, value: (up, down)) in expected.entries) {
        expect(order(key), up, reason: '$key ascending');
        expect(order(key, desc: true), down, reason: '$key descending');
      }
    });

    test('sorts by the file each track shows', () {
      final both = groupAudioFormats(['x.ogg', 'x.wav', 'y.ogg']);
      List<String> by(String Function(AudioTrack) fileOf) => [
        for (final t in sortAudioTracks(
          both,
          AudioSort.size,
          descending: false,
          fileOf: fileOf,
          sizeOf: (rel) => const {'x.ogg': 10, 'x.wav': 99, 'y.ogg': 50}[rel],
          infoOf: (_) => null,
        ))
          t.key,
      ];
      expect(by((t) => t.files.first), ['x', 'y']);
      expect(by((t) => t.files.last), ['y', 'x']);
    });

    test('settings: audio_sort and audio_sort_desc round-trip', () {
      expect(const AppSettings().audioSort, AudioSort.name);
      expect(const AppSettings().audioSortDesc, isFalse);
      final saved = const AppSettings()
          .copyWith(audioSort: AudioSort.bitDepth, audioSortDesc: true)
          .toJson();
      expect(saved['audio_sort'], 'bitDepth');
      expect(saved['audio_sort_desc'], true);
      final back = AppSettings.fromJson(saved);
      expect(back.audioSort, AudioSort.bitDepth);
      expect(back.audioSortDesc, isTrue);
      expect(
        AppSettings.fromJson({'audio_sort': 'nope'}).audioSort,
        AudioSort.name,
      );
    });
  });
}
