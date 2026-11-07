import 'package:loot_silo/core/fs_tree.dart';
import 'package:loot_silo/core/type_classifier.dart';
import 'package:flutter_test/flutter_test.dart';

(String, FileEntry) f(String rel, [int size = 1000]) =>
    (rel, FileEntry(rel.split('/').last, size));

void main() {
  test('pathWords splits separators and camelCase but keeps 3d', () {
    expect(pathWords('FreeCharactersPack/Human_Soldier-3D.png'), [
      'free',
      'characters',
      'pack',
      'human',
      'soldier',
      '3d',
      'png',
    ]);
  });

  group('classifyPack', () {
    test('3d models and fonts by extension', () {
      expect(classifyPack('Kit', [f('a.glb'), f('b.fbx'), f('c.png')]), [
        AssetType.threeD,
      ]);
      expect(classifyPack('Fonts', [f('a.ttf'), f('b.otf')]), [AssetType.font]);
    });

    test('audio: sfx words beat music words at the same level', () {
      expect(classifyPack('music/Pizza/Cozy FX v1', [f('a.ogg'), f('b.ogg')]), [
        AssetType.sfx,
      ]);
      expect(classifyPack('Tunes/Loop Bundle', [f('a.ogg', 5000000)]), [
        AssetType.music,
      ]);
    });

    test('audio without keywords falls back to file size', () {
      expect(classifyPack('X', [f('a.ogg', 3000000)]), [AssetType.music]);
      expect(classifyPack('X', [f('a.ogg', 20000)]), [AssetType.sfx]);
    });

    test('sound packs do not pick up visual types from their names', () {
      expect(
        classifyPack('Magic Sound Effects', [f('fire.wav'), f('spell.wav')]),
        [AssetType.sfx],
      );
    });

    test('images vote by path keywords, then pack keywords', () {
      expect(
        classifyPack('Pack', [f('Characters/hero.png'), f('Tiles/grass.png')]),
        containsAll([AssetType.character, AssetType.environment]),
      );
      expect(classifyPack('art/ui/Rpg-Ui', [f('a.png'), f('b.png')]), [
        AssetType.ui,
      ]);
    });

    test('unknown content is misc', () {
      expect(classifyPack('X', [f('a.txt')]), [AssetType.misc]);
      expect(classifyPack('X', [f('blob.png')]), [AssetType.misc]);
    });
  });

  test('suggestTags maps generic folder words', () {
    expect(suggestTags('art/characters/Zerie/Tiny RPG Pixel Art Pack'), [
      'character',
      'pixel-art',
      'rpg',
    ]);
    expect(suggestTags('sfx/Sci-Fi Sound Effects'), ['sci-fi', 'sfx']);
    expect(suggestTags('Top-Down 16-bit Tanks'), ['16-bit', 'top-down']);
  });
}
