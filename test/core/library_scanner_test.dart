import 'dart:convert';
import 'dart:io';

import 'package:loot_silo/core/library_scanner.dart';
import 'package:loot_silo/core/sidecar.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import 'sub_folders_test.dart' show writeFiles;

void main() {
  group('fixture source tree', () {
    final result = scanLibrary('test/fixtures/library_src');
    final byId = {for (final pk in result.packs) pk.id: pk};

    test('finds exactly the expected packs', () {
      expect(byId.keys.toSet(), {
        'art/characters/HeroMaker/Knight Pack v1.0',
        'art/characters/HeroMaker/Free Slime Pack',
        'art/environments/Forest Tiles 16x16',
        'bundles/Mega Bundle v3',
        'sfx/Loose Sounds',
        'music/SoloArtist',
        'misc',
      });
    });

    test('author folder children inherit the author', () {
      final knight = byId['art/characters/HeroMaker/Knight Pack v1.0']!;
      expect(knight.author!.user, 'HeroMaker');
      expect(knight.authorFile, endsWith('HeroMaker/ASSET_AUTHOR.txt'));
      expect(knight.types, ['character']);
      expect(knight.files, contains('Knight/Knight-sheet(32x32).png'));
    });

    test('a folder whose name is not the author is a pack', () {
      final forest = byId['art/environments/Forest Tiles 16x16']!;
      expect(forest.author!.user, 'Leafy Studio');
      expect(forest.author!.license, 'CC-BY 4.0');
      expect(forest.types, ['environment']);
    });

    test('a former bundle is one pack holding every folder', () {
      final mega = byId['bundles/Mega Bundle v3']!;
      expect(mega.author!.user, 'BigCo');
      expect(
        mega.files,
        containsAll([
          'Bundle.txt',
          'Fonts/BigCo.ttf',
          '2D assets/Planes Pack/plane.png',
          '2D assets/Tanks Pack/PNG/tank.png',
          'Audio/Clicks (3 sounds)/click1.ogg',
        ]),
      );
      expect(mega.files, hasLength(10));
    });

    test('previews: named file anywhere in the pack, audio none', () {
      expect(
        byId['bundles/Mega Bundle v3']!.preview,
        '2D assets/Tanks Pack/Preview.png',
      );
      expect(
        byId['art/environments/Forest Tiles 16x16']!.preview,
        'Mockups/mockup.png',
      );
      expect(byId['sfx/Loose Sounds']!.preview, isNull);
    });

    test('author guessed from an itch url in a readme', () {
      final loose = byId['sfx/Loose Sounds']!;
      expect(loose.author!.user, 'noisy');
      expect(loose.author!.url, 'https://noisy.itch.io/');
      expect(loose.authorFile, isNull);
      expect(loose.types, ['sfx']);
    });

    test('author folder without pack-like children is one pack', () {
      final solo = byId['music/SoloArtist']!;
      expect(solo.author!.user, 'Solo Artist');
      expect(solo.files, hasLength(2));
      expect(solo.types, ['music']);
    });

    test('loose assets become a pack at the top-most signal-free folder', () {
      expect(byId['misc']!.author, isNull);
      expect(byId['misc']!.files, ['random/stuff/thing.png']);
    });

    test('hidden folders are skipped and tags come from paths', () {
      expect(
        result.packs.expand((p) => p.files),
        isNot(contains(contains('secret'))),
      );
      expect(
        byId['art/characters/HeroMaker/Free Slime Pack']!.tags,
        contains('character'),
      );
      expect(result.resolvedAuthorFiles, hasLength(4));
    });
  });

  group('managed library', () {
    final result = scanLibrary('test/fixtures/managed');
    final byId = {for (final pk in result.packs) pk.id: pk};

    test('uses sidecars for title, types, tags and source', () {
      expect(byId.keys.toSet(), {'HeroMaker/Knight Pack', 'HeroMaker/Slimes'});
      final knight = byId['HeroMaker/Knight Pack']!;
      expect(knight.title, 'Knight Pack');
      expect(knight.tags, ['knight', 'pixel-art']);
      expect(knight.source, PackSource.imported);
      expect(knight.author!.itchSlug, 'heromaker');
      expect(knight.files, [
        'knight.png',
      ], reason: 'sidecars are not asset files');
    });

    test('an empty sidecar falls back to detection', () {
      final slimes = byId['HeroMaker/Slimes']!;
      expect(slimes.title, 'Slimes');
      expect(slimes.source, PackSource.manual);
      expect(slimes.types, isNotEmpty);
    });
  });

  test('a sidecar in a pack folder makes no pack of its own', () {
    final tmp = Directory.systemTemp.createTempSync('scan_source');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final src = Directory('test/fixtures/library_src/bundles/Mega Bundle v3');
    final bundle = p.join(tmp.path, 'BigCo', 'Mega Bundle v3');
    for (final f in src.listSync(recursive: true).whereType<File>()) {
      final to = File(p.join(bundle, p.relative(f.path, from: src.path)));
      to.parent.createSync(recursive: true);
      f.copySync(to.path);
    }
    File(p.join(bundle, 'asset_pack.json'))
        .writeAsStringSync('{"source": "imported"}');
    File(p.join(bundle, '2D assets', 'Planes Pack', 'asset_pack.json'))
        .writeAsStringSync('{"source": "itch"}');

    final byId = {for (final pk in scanLibrary(tmp.path).packs) pk.id: pk};
    const id = 'BigCo/Mega Bundle v3';
    expect(byId.keys, [id]);
    expect(byId[id]!.source, PackSource.imported);
    expect(byId[id]!.files, contains('2D assets/Planes Pack/plane.png'));
  });

  test('a file marked "not an animation" gets no animated preview', () {
    final tmp = Directory.systemTemp.createTempSync('scan_hidden');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final pack = p.join(tmp.path, 'Author', 'Fx Pack');
    File(p.join(pack, 'fx', 'Explosion-sheet.png'))
      ..parent.createSync(recursive: true)
      ..writeAsBytesSync(img.encodePng(img.Image(width: 128, height: 32)));
    // A sidecar makes the folder a pack either way.
    final sidecar = File(p.join(pack, 'asset_pack.json'))
      ..writeAsStringSync('{}');
    ScannedPack scan() =>
        scanLibrary(tmp.path).packs
            .singleWhere((x) => x.id == 'Author/Fx Pack');
    expect(scan().previewAnim, isNotNull);
    sidecar.writeAsStringSync(
      jsonEncode({
        'animations': {'fx/Explosion-sheet.png': false},
      }),
    );
    final hidden = scan();
    expect(hidden.preview, 'fx/Explosion-sheet.png');
    expect(hidden.previewAnim, isNull);
  });

  test(
    'M62: material maps are no preview or animation; the shipped one is',
    () {
      final tmp = Directory.systemTemp.createTempSync('scan_material');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final pack = p.join(tmp.path, 'Author', 'Stones');
      void png(String rel, int w, int h) => File(p.join(pack, rel))
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(img.encodePng(img.Image(width: w, height: h)));
      // A wide Color map would pass for a strip if it were an image.
      png('Stones_Color.png', 256, 64);
      png('Stones_Normal.png', 256, 64);
      png('Stones_Roughness.png', 256, 64);
      File(p.join(pack, 'asset_pack.json')).writeAsStringSync('{}');
      ScannedPack scan() =>
          scanLibrary(tmp.path).packs
              .singleWhere((x) => x.id == 'Author/Stones');
      var stones = scan();
      expect(stones.types, ['material']);
      expect(stones.preview, 'Stones_Color.png');
      expect(stones.previewAnim, isNull);
      png('Stones.png', 64, 64);
      stones = scan();
      expect(stones.preview, 'Stones.png');
      expect(stones.previewAnim, isNull);
    },
  );

  group('one pack per detected pack (M91)', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('scan_flat'));
    tearDown(() => tmp.deleteSync(recursive: true));

    /// The "Cozy Tunes + Cozy FX" layout from itch.io, inside an author
    /// folder.
    const cozy = 'Pizza Doggy/Cozy Tunes + Cozy FX';
    const cozyFiles = [
      '$cozy/License.txt',
      '$cozy/_itch/cover.png',
      '$cozy/_itch/screenshot_01.png',
      '$cozy/Cozy FX/License Agreement.pdf',
      '$cozy/Cozy FX/pop.ogg',
      '$cozy/Cozy FX/click.ogg',
      '$cozy/Cozy Tunes/Read Me.txt',
      '$cozy/Cozy Tunes/Audio/ogg/morning.ogg',
      '$cozy/Cozy Tunes/Audio/ogg/evening.ogg',
      '$cozy/Cozy Tunes - The Classics/waltz.ogg',
    ];
    void author(String dir, String name) =>
        AuthorInfo(user: name).write(p.join(tmp.path, dir));

    test('the Cozy layout is one pack with the itch cover', () {
      writeFiles(tmp.path, cozyFiles);
      author('Pizza Doggy', 'Pizza Doggy');
      final packs = scanLibrary(tmp.path).packs;
      expect(packs.map((x) => x.id), [cozy]);
      final pack = packs.single;
      expect(
        pack.files,
        containsAll([
          'Cozy FX/pop.ogg',
          'Cozy Tunes/Audio/ogg/morning.ogg',
          'Cozy Tunes - The Classics/waltz.ogg',
        ]),
      );
      expect(pack.files.where((f) => f.endsWith('.ogg')), hasLength(5));
      expect(pack.preview, '_itch/cover.png');
    });

    test("the user's previews still win over the itch cover", () {
      writeFiles(tmp.path, [...cozyFiles, '$cozy/Cozy FX/x.png']);
      author('Pizza Doggy', 'Pizza Doggy');
      File(p.join(tmp.path, cozy, packFileName)).writeAsStringSync(
        jsonEncode({
          'previews': ['Cozy FX/x.png'],
        }),
      );
      expect(scanLibrary(tmp.path).packs.single.preview, 'Cozy FX/x.png');
    });

    test('a Kenney-like all-in-one in an author folder is one pack', () {
      writeFiles(tmp.path, [
        for (final theme in ['Tanks', 'Planes', 'Ships']) ...[
          'Kenney/Game Assets All in One/$theme (12 assets)/License.txt',
          'Kenney/Game Assets All in One/$theme (12 assets)/PNG/a.png',
        ],
      ]);
      author('Kenney', 'Kenney');
      final packs = scanLibrary(tmp.path).packs;
      expect(packs.map((x) => x.id), ['Kenney/Game Assets All in One']);
      expect(packs.single.files, hasLength(6));
      expect(packs.single.author!.user, 'Kenney');
      // Its folders become Expanded tiles like any pack's.
      expect(packs.single.subFolders.map((s) => s.folder), [
        'Planes (12 assets)',
        'Ships (12 assets)',
        'Tanks (12 assets)',
      ]);
    });

    test('a folder with its own assets is one pack, signals below or not', () {
      writeFiles(tmp.path, [
        'loose/My Pack/a.png',
        'loose/My Pack/b.png',
        'loose/My Pack/Characters/preview.png',
        'loose/My Pack/Characters/hero.png',
        // Docs alone don't make a folder a pack.
        'gifts/A small gift.txt',
        'gifts/Trees/License.txt',
        'gifts/Trees/tree.png',
      ]);
      final byId = {for (final x in scanLibrary(tmp.path).packs) x.id: x};
      expect(byId.keys, unorderedEquals(['loose/My Pack', 'gifts/Trees']));
      expect(
        byId['loose/My Pack']!.files,
        unorderedEquals([
          'a.png',
          'b.png',
          'Characters/preview.png',
          'Characters/hero.png',
        ]),
      );
    });

    test('unchanged: author children with licenses, loose folders', () {
      writeFiles(tmp.path, [
        'Leafy/Forest/License.txt',
        'Leafy/Forest/tree.png',
        'Leafy/Desert/License.txt',
        'Leafy/Desert/cactus.png',
        'misc/random/stuff/thing.png',
      ]);
      author('Leafy', 'Leafy');
      expect(
        scanLibrary(tmp.path).packs.map((x) => x.id),
        unorderedEquals(['Leafy/Forest', 'Leafy/Desert', 'misc']),
      );
    });
  });
}
