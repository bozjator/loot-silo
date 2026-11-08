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
}
