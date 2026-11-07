import 'dart:convert';
import 'dart:io';

import 'package:loot_silo/core/library_scanner.dart';
import 'package:loot_silo/core/sidecar.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

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
        'bundles/Mega Bundle v3/2D assets/Tanks Pack',
        'bundles/Mega Bundle v3/2D assets/Planes Pack',
        'bundles/Mega Bundle v3/Audio/Clicks (3 sounds)',
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
      expect(
        forest.isContainer,
        isFalse,
        reason: 'readme notes are not sub-packs',
      );
      expect(forest.types, ['environment']);
    });

    test('bundles hold sub-packs and keep only their own loose files', () {
      final bundle = byId['bundles/Mega Bundle v3']!;
      expect(bundle.isContainer, isTrue);
      expect(bundle.files, unorderedEquals(['Bundle.txt', 'Fonts/BigCo.ttf']));
      expect(bundle.types, unorderedEquals(['misc', 'sfx']));
      final tanks = byId['bundles/Mega Bundle v3/2D assets/Tanks Pack']!;
      expect(tanks.parentId, 'bundles/Mega Bundle v3');
      expect(tanks.author!.user, 'BigCo');
      expect(tanks.files, hasLength(3));
      expect(byId['bundles/Mega Bundle v3/Audio/Clicks (3 sounds)']!.types, [
        'sfx',
      ]);
    });

    test(
      'previews: named file, bundle falls back to a sub-pack, audio none',
      () {
        expect(
          byId['bundles/Mega Bundle v3/2D assets/Tanks Pack']!.preview,
          'Preview.png',
        );
        expect(
          byId['bundles/Mega Bundle v3']!.preview,
          startsWith('2D assets/'),
        );
        expect(
          byId['art/environments/Forest Tiles 16x16']!.preview,
          'Mockups/mockup.png',
        );
        expect(byId['sfx/Loose Sounds']!.preview, isNull);
      },
    );

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

  test("sub-packs take the bundle's source unless they have their own", () {
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
        .writeAsStringSync('{"source": "imported", "is_container": true}');
    File(p.join(bundle, '2D assets', 'Planes Pack', 'asset_pack.json'))
        .writeAsStringSync('{"source": "itch"}');

    final byId = {for (final pk in scanLibrary(tmp.path).packs) pk.id: pk};
    const id = 'BigCo/Mega Bundle v3';
    expect(byId[id]!.source, PackSource.imported);
    expect(byId['$id/2D assets/Tanks Pack']!.source, PackSource.imported);
    expect(byId['$id/Audio/Clicks (3 sounds)']!.source, PackSource.imported);
    expect(byId['$id/2D assets/Planes Pack']!.source, PackSource.itch);
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
}
