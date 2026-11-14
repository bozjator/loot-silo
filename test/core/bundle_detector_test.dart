import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:loot_silo/core/bundle_detector.dart';
import 'package:loot_silo/core/fs_tree.dart';
import 'package:loot_silo/core/library_scanner.dart';
import 'package:loot_silo/core/pack_editor.dart';
import 'package:loot_silo/core/sidecar.dart';
import 'package:path/path.dart' as p;

import 'sub_folders_test.dart' show writeFiles;

/// M95: a folder of packs is a bundle.
void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('bundles'));
  tearDown(() => tmp.deleteSync(recursive: true));

  void author(String dir, String name) =>
      AuthorInfo(user: name).write(p.join(tmp.path, dir));

  Map<String, ScannedPack> scan() => {
    for (final pk in scanLibrary(tmp.path).packs) pk.id: pk,
  };

  const kenney = 'Kenney/Game Assets 1 version 42';

  /// Sections of packs with previews and licenses, sounds by count, loose
  /// fonts and a readme at the top.
  void writeKenney() {
    writeFiles(tmp.path, [
      '$kenney/Readme.txt',
      for (final pack in ['Tanks', 'Planes', 'Ships', 'Space Shooter']) ...[
        '$kenney/2D assets/$pack/Preview.png',
        '$kenney/2D assets/$pack/License.txt',
        '$kenney/2D assets/$pack/PNG/a.png',
        '$kenney/2D assets/$pack/PNG/b.png',
      ],
      for (final pack in [
        'Impact Sounds (50 sounds)',
        'RPG sounds (40 sounds)',
      ])
        '$kenney/Audio/$pack/click.ogg',
      '$kenney/Fonts/Kenney Mini.ttf',
      '$kenney/Fonts/Kenney Blocks.ttf',
    ]);
    author('Kenney', 'Kenney');
  }

  group('guessed', () {
    test('a Kenney-like all-in-one: sections, and loose fonts a pack', () {
      writeKenney();
      final packs = scan();
      final bundle = packs[kenney]!;
      expect(bundle.isBundle, isTrue);
      expect(bundle.files, ['Readme.txt']);
      expect(bundle.fileTotal, 21);
      expect(bundle.author!.user, 'Kenney');
      // The bundle's cover is its first pack's preview.
      expect(bundle.preview, isNotNull);
      final children = {
        for (final pk in packs.values)
          if (pk.bundleId == kenney) p.relative(pk.id, from: kenney): pk,
      };
      expect(children.keys, {
        '2D assets/Planes',
        '2D assets/Ships',
        '2D assets/Space Shooter',
        '2D assets/Tanks',
        'Audio/Impact Sounds (50 sounds)',
        'Audio/RPG sounds (40 sounds)',
        'Fonts',
      });
      expect(children['2D assets/Tanks']!.section, '2D assets');
      expect(children['Audio/RPG sounds (40 sounds)']!.section, 'Audio');
      expect(children['Fonts']!.section, 'Fonts');
      expect(children['Fonts']!.files, hasLength(2));
      for (final c in children.values) {
        expect(c.author!.user, 'Kenney');
      }
      expect(packs.length, children.length + 1);
    });

    test('editions of one pack (Zerie) are one pack', () {
      const z = 'Zerie/Tiny RPG Character Asset Pack v1.03';
      writeFiles(tmp.path, [
        for (final ed in ['-Free Soldier&Orc', '-Full 20 Characters', 'Demo'])
          for (final f in ['License.txt', 'Soldier/Idle.png'])
            '$z/Tiny RPG Character Asset Pack v1.03 $ed/$f',
      ]);
      author('Zerie', 'Zerie');
      final packs = scan();
      expect(packs.keys, [z]);
      expect(packs[z]!.isBundle, isFalse);
    });

    test('character folders without pack signs (Pixel-Banner) stay one', () {
      writeFiles(tmp.path, [
        for (final c in ['Knight', 'SkeletonMage', 'Archer', 'Orc'])
          for (final a in ['Idle', 'Run', 'Attack1'])
            'Pixel Banner/Pixel-Banner/$c/$a.png',
      ]);
      author('Pixel Banner', 'Pixel Banner');
      // One pack (here the author folder itself), never a bundle.
      final packs = scan();
      expect(packs, hasLength(1));
      expect(packs.values.single.isBundle, isFalse);
      expect(packs.values.single.files, hasLength(12));
    });

    test('"Bundle" in a name with kind-named folders is one pack', () {
      writeFiles(tmp.path, [
        for (final kind in ['Idle', 'Walk', 'Attack', 'Death'])
          for (final f in ['License.txt', 'sheet.png'])
            'Studio/Enemy Bundle #4/$kind/$f',
      ]);
      author('Studio', 'Studio');
      final packs = scan();
      expect(packs.keys, ['Studio/Enemy Bundle #4']);
      expect(packs.values.single.isBundle, isFalse);
    });

    test('a folder with its own asset files is one pack', () {
      writeFiles(tmp.path, [
        'Studio/Big Pack/tileset_main.png',
        for (final pack in ['Forest v1', 'Desert v2', 'Snow v1'])
          for (final f in ['License.txt', 'tile.png'])
            'Studio/Big Pack/$pack/$f',
      ]);
      author('Studio', 'Studio');
      expect(
        BundleDetector().guess(readTree(p.join(tmp.path, 'Studio/Big Pack'))),
        isNull,
      );
    });

    test('a type-first library: Audio is a folder of packs, no author', () {
      writeFiles(tmp.path, [
        for (final pack in ['Rain Loops', 'Footsteps', 'Swords'])
          for (final f in ['License.txt', 'a.ogg']) 'Library/Audio/$pack/$f',
        for (final pack in ['Forest Tiles', 'Cave Tiles'])
          for (final f in ['License.txt', 'a.png']) 'Library/Tiles/$pack/$f',
      ]);
      final packs = scan();
      expect(
        packs.keys,
        unorderedEquals([
          'Library/Audio/Rain Loops',
          'Library/Audio/Footsteps',
          'Library/Audio/Swords',
          'Library/Tiles/Forest Tiles',
          'Library/Tiles/Cave Tiles',
        ]),
      );
      for (final pk in packs.values) {
        expect(pk.isBundle, isFalse);
        expect(pk.bundleId, isNull);
        expect(pk.author?.user, isNot('Audio'));
      }
    });
  });

  group('layout in asset_pack.json', () {
    test('"pack" keeps a guessed bundle one pack', () {
      writeKenney();
      setPackLayout(p.join(tmp.path, kenney), PackLayout.pack);
      final packs = scan();
      expect(packs.keys, [kenney]);
      expect(packs[kenney]!.isBundle, isFalse);
      expect(packs[kenney]!.files, hasLength(21));
    });

    test('"bundle" splits a folder the guess keeps whole', () {
      const banner = 'Pixel Banner/Pixel-Banner';
      writeFiles(tmp.path, [
        for (final c in ['Knight', 'Archer'])
          for (final a in ['Idle', 'Run']) '$banner/$c/$a.png',
      ]);
      author('Pixel Banner', 'Pixel Banner');
      setPackLayout(p.join(tmp.path, banner), PackLayout.bundle);
      final packs = scan();
      expect(packs[banner]!.isBundle, isTrue);
      expect([
        for (final pk in packs.values)
          if (pk.bundleId == banner) pk.id,
      ], unorderedEquals(['$banner/Archer', '$banner/Knight']));
    });

    test('split → merge → split keeps each pack\'s tags and stars', () {
      writeKenney();
      final tanks = p.join(tmp.path, kenney, '2D assets', 'Tanks');
      const PackSidecar(tags: ['war'], favorite: true).write(tanks);
      final top = p.join(tmp.path, kenney);
      updatePackSidecar(top, tags: ['kenney']);

      ScannedPack tanksPack() => scan()['$kenney/2D assets/Tanks']!;
      expect(tanksPack().tags, contains('war'));
      expect(tanksPack().sidecar?.favorite, isTrue);

      setPackLayout(top, PackLayout.pack);
      final merged = scan();
      expect(merged.keys, [kenney]);
      expect(merged[kenney]!.tags, contains('kenney'));

      setPackLayout(top, PackLayout.bundle);
      expect(tanksPack().tags, contains('war'));
      expect(tanksPack().sidecar?.favorite, isTrue);
      expect(scan()[kenney]!.tags, contains('kenney'));
    });

    test('round trip, and an unknown value reads as no choice', () {
      for (final layout in [...PackLayout.values, null]) {
        final s = PackSidecar(layout: layout, tags: const ['x']);
        final back = PackSidecar.fromJson(s.toJson());
        expect(back.layout, layout);
        expect(back.tags, ['x']);
      }
      expect(
        PackSidecar(layout: PackLayout.bundle).toJson()['layout'],
        'bundle',
      );
      expect(PackSidecar.fromJson({'layout': 'tree'}).layout, isNull);
    });
  });

  test('force: every child folder with files, fewer than two is null', () {
    writeFiles(tmp.path, [
      'x/One/a.png',
      'y/One/a.png',
      'y/Two/b.png',
      'y/_itch/cover.png',
    ]);
    final d = BundleDetector();
    expect(d.force(readTree(p.join(tmp.path, 'x'))), isNull);
    expect(
      d.force(readTree(p.join(tmp.path, 'y')))!.packs.map((c) => c.dir.name),
      unorderedEquals(['One', 'Two']),
    );
  });
}
