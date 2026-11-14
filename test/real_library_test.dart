// Read-only checks against the user's real `assets_library_OLD`.
// Skipped automatically where that folder does not exist.
import 'dart:io';

import 'package:loot_silo/core/animation_detector.dart';
import 'package:loot_silo/core/library_index.dart';
import 'package:loot_silo/core/library_scanner.dart';
import 'package:loot_silo/core/library_service.dart';
import 'package:loot_silo/core/pack_editor.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

const oldLibrary = '../assets_library_OLD';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final skip = Directory(oldLibrary).existsSync() ? false : 'no $oldLibrary';

  group('assets_library_OLD', skip: skip, () {
    late ScanResult result;
    setUpAll(() => result = scanLibrary(oldLibrary));
    Iterable<ScannedPack> under(String prefix) =>
        result.packs.where((p) => p.id.startsWith(prefix));

    test('every ASSET_AUTHOR.txt resolves to a pack', () {
      final onDisk = Directory(oldLibrary)
          .listSync(recursive: true)
          .where((e) => e.path.endsWith('/ASSET_AUTHOR.txt'))
          .length;
      expect(onDisk, 18);
      expect(result.resolvedAuthorFiles, hasLength(18));
      expect(result.packs.where((p) => p.author == null), isEmpty);
    });

    test('Kenney all-in-ones are one pack each, with all their folders', () {
      for (final name in [
        'Kenney Game Assets 1 version 42',
        'Kenney Game Assets 2 version 22',
      ]) {
        final pack = result.packs.singleWhere((p) => p.title == name);
        expect(pack.author?.user, 'Kenney');
        expect(
          result.packs.where((p) => p.id.startsWith('${pack.id}/')),
          isEmpty,
          reason: name,
        );
        // One Expanded tile per theme folder, like any big pack.
        expect(pack.files.length, greaterThan(1000), reason: name);
      }
    });

    test('Zerie, RafaelMatos and OboroPixel packs are detected', () {
      expect(under('art/characters/Zerie/').map((p) => p.title), [
        'Tiny RPG Character Asset Pack 01 v2.0 -Full 22 Characters',
      ]);
      expect(under('art/environments/RafaelMatos/'), hasLength(5));
      expect(under('art/characters/OboroPixel/'), hasLength(2));
    });

    test('cold scan < 10 s and warm load < 1 s', () async {
      final service = LibraryService(LibraryIndex(NativeDatabase.memory()));
      addTearDown(service.index.close);
      final cold = await service.load(oldLibrary);
      expect(cold.scanned, isTrue);
      expect(cold.elapsed, lessThan(const Duration(seconds: 10)));
      final warm = await service.load(oldLibrary);
      expect(warm.scanned, isFalse);
      expect(warm.elapsed, lessThan(const Duration(seconds: 1)));
      // ignore: avoid_print
      print(
        'cold ${cold.elapsed.inMilliseconds} ms, warm ${warm.elapsed.inMilliseconds} ms, '
        '${cold.packs.length} packs',
      );
    });
  });

  const managed = '../assets_library';
  test(
    'Pixel-Banner splits into its 12 character folders (read-only)',
    skip: Directory(managed).existsSync() ? false : 'no $managed',
    () {
      final banner = scanLibrary(managed).packs
          .firstWhere((p) => p.id == 'Pixel Banner/Pixel-Banner');
      expect(banner.subFolders, hasLength(12));
      expect(banner.subFolders.map((s) => s.folder), contains('SkeletonMage'));
      expect(banner.subFolders.every((s) => s.preview != null), isTrue);
    },
  );

  test(
    'animation detection: props are images, Vol.03 has 5 grids (read-only)',
    skip: Directory(managed).existsSync() ? false : 'no $managed',
    () {
      final packs = scanLibrary(managed).packs;
      List<SpriteAnim> animsOf(String id) {
        final pack = packs.firstWhere((p) => p.id == id);
        return loadPackContents(pack.path, [
          for (final f in pack.files) (f, 0),
        ]).detected;
      }

      final village = animsOf('RafaelMatos/Epic RPG World - The Village V2.2');
      expect(
        village.where(
          (a) => a.path.contains('barrels') || a.path.contains('chimney-h_'),
        ),
        isEmpty,
      );
      // The real chimney smoke strips are still found.
      expect(
        village.where((a) => a.path.contains('chimney-smoke')),
        hasLength(4),
      );
      final fx = animsOf('ashishlko11/Special Effects Vol.03')
          .where((a) => a.path.startsWith('png/'))
          .toList();
      expect(fx, hasLength(5));
      expect(fx.every((a) => (a.cols, a.rows) == (4, 4)), isTrue);
    },
  );

  test(
    'one file, one animation; no consensus grids (M34, read-only)',
    skip: Directory(managed).existsSync() ? false : 'no $managed',
    () {
      final packs = scanLibrary(managed).packs;
      PackContents contentsOf(String id) {
        final pack = packs.firstWhere((p) => p.id == id);
        return loadPackContents(pack.path, [
          for (final f in pack.files) (f, 0),
        ]);
      }

      final sea = contentsOf(
        'RafaelMatos/ERW - Sea Adventures (GL 2.0 expansion) V1.5',
      );
      final seaAnims = {for (final a in sea.shownDetected) a.path: a};
      // The 128 px banner strips no longer make the shadow a 7×5 grid.
      expect(
        seaAnims.keys,
        isNot(contains('props/islands-update/islands-grass-shadow.png')),
      );
      expect(
        sea.images,
        contains('props/islands-update/islands-grass-shadow.png'),
      );
      // gems-1.png … gems-4.png are four 8-frame strips, not a sequence.
      for (var i = 1; i <= 4; i++) {
        final gems = seaAnims['props/animated/gems-$i.png']!;
        expect((gems.frameW, gems.cols, gems.rows), (32, 8, 1));
        // Listed under Animations only.
        expect(sea.images, isNot(contains('props/animated/gems-$i.png')));
      }
      // banner-only.png: 12 frames of 96×128, from its column gaps.
      final banner = seaAnims['props/animated/banner-only.png']!;
      expect(
        (banner.frameW, banner.frameH, banner.cols, banner.rows),
        (96, 128, 12, 1),
      );

      // Generic Items: the 52×13 strip (item 061) is a 4-frame strip, and
      // it doesn't cut the 130×130 items (since M91 the folder is part of
      // the all-in-one pack, so it is checked here at last).
      final items = contentsOf('Kenney/Kenney Game Assets 2 version 22')
          .shownDetected
          .map((a) => a.path);
      expect(
        items.where((a) => a.contains('genericItem_')).map(p.basename),
        unorderedEquals([
          'genericItem_color_061.png',
          'genericItem_white_061.png',
        ]),
      );
      // Kenney's trimmed explosion frames are plain images.
      final kenney1 = contentsOf('Kenney/Kenney Game Assets 1 version 42');
      expect(
        kenney1.shownDetected.where(
          (a) => a.path.startsWith('2D assets/Explosion Pack/PNG/'),
        ),
        isEmpty,
      );
      // Its two-frame-looking texture atlases (Spritesheets/*.png + .xml)
      // were detected before M91 too, out of this test's sight while the
      // pack was a sub-pack; recorded as an open question.
      expect(
        kenney1.shownDetected
            .where((a) => a.path.contains('Explosion Pack/'))
            .map((a) => p.basename(a.path)),
        unorderedEquals([
          'spritesheet_groundExplosion.png',
          'spritesheet_sonicExplosion.png',
        ]),
      );
    },
  );

  test(
    'M43: ship sheets, false strips, known good strips (read-only)',
    skip: Directory(managed).existsSync() ? false : 'no $managed',
    () {
      final packs = scanLibrary(managed).packs;
      PackContents contentsOf(String id) {
        final pack = packs.firstWhere((p) => p.id == id);
        return loadPackContents(pack.path, [
          for (final f in pack.files) (f, 0),
        ]);
      }

      final sea = contentsOf(
        'RafaelMatos/ERW - Sea Adventures (GL 2.0 expansion) V1.5',
      );
      final anims = {for (final a in sea.detected) a.path: a};
      const ship = 'props/animated/ship/ship-animations';
      (int, int, int, int, int) grid(String rel) {
        final a = anims[rel]!;
        return (a.frameW, a.frameH, a.cols, a.rows, a.frameCount);
      }

      for (final dir in [' - down', ' - up', '-sideways']) {
        expect(grid('$ship$dir-idle-baked.png'), (608, 640, 15, 1, 15));
        expect(grid('$ship$dir-idle-baked-packed.png'), (608, 640, 4, 4, 15));
        expect(grid('$ship$dir-sailing-baked.png'), (608, 640, 17, 1, 17));
        expect(grid('$ship$dir-sailing-baked-packed.png'), (
          608,
          640,
          5,
          4,
          17,
        ));
      }
      // The windFX files take the grid of the baked ones next to them.
      for (final f in [
        '$ship - down-sailing-windFX.png',
        '$ship - up-sailing-windFX.png',
        '$ship-sideways-sailing-windFX-baked.png',
      ]) {
        expect(grid(f), (608, 640, 17, 1, 17), reason: f);
      }
      for (final f in [
        '$ship - down-sailing-windFX-packed.png',
        '$ship - up-sailing-windFX-packed.png',
        '$ship-sideways-sailing-windFX-baked-packed.png',
      ]) {
        expect(grid(f), (608, 640, 5, 4, 17), reason: f);
      }

      // One wide prop, not a strip.
      expect(
        anims,
        isNot(contains('props/atlas-props-sprites/lighthouse cabin-grass.png')),
      );
      expect(
        sea.images,
        contains('props/atlas-props-sprites/lighthouse cabin-grass.png'),
      );
      final interiors = contentsOf(
        'RafaelMatos/Epic RPG World - Village(interiors) V1.3',
      );
      const bags = 'assets/furniture_and_props_sprites/supply_bags_1.png';
      expect(interiors.detected.map((a) => a.path), isNot(contains(bags)));
      expect(interiors.images, contains(bags));

      // Known good strips stay animations.
      for (var i = 1; i <= 4; i++) {
        expect(grid('props/animated/gems-$i.png'), (32, 32, 8, 1, 8));
      }
      expect(grid('props/animated/banner-only.png'), (96, 128, 12, 1, 12));
      expect(grid('props/islands-update/deck-storage-door-1-opening.png'), (
        96,
        96,
        11,
        1,
        11,
      ));
      final banner = {
        for (final a in contentsOf('Pixel Banner/Pixel-Banner').detected)
          a.path: a,
      };
      expect(banner['WarriorBandit/Block/Block.png']!.cols, 4);
      expect(banner['ArcherSkeleton/Attack2/Attack2.png']!.cols, 11);
      final village = {
        for (final a in contentsOf(
          'RafaelMatos/Epic RPG World - The Village V2.2',
        ).detected)
          a.path: a,
      };
      expect(
        village['NPCs/fisherman/beard/fisherman-beard-fishing-waiting.png']!
            .cols,
        10,
      );
      expect(village['tilesets and props/Water-fountain.png']!.cols, 4);
    },
  );

  test(
    'M47: fisherman grids take their folder\'s 192 px cells (read-only)',
    skip: Directory(managed).existsSync() ? false : 'no $managed',
    () {
      final pack = scanLibrary(managed).packs.firstWhere(
        (p) => p.id == 'RafaelMatos/Epic RPG World - The Village V2.2',
      );
      final contents = loadPackContents(pack.path, [
        for (final f in pack.files) (f, 0),
      ]);
      final anims = {for (final a in contents.detected) a.path: a};
      (int, int, int, int, int) grid(String rel) {
        final a = anims[rel]!;
        return (a.frameW, a.frameH, a.cols, a.rows, a.frameCount);
      }

      for (final (dir, stem) in [
        ('beard', 'fisherman-beard'),
        ('beard and headband', 'fisherman-beard-headband'),
        ('headband', 'fisherman-headband'),
      ]) {
        final f = 'NPCs/fisherman/$dir/$stem';
        expect(grid('$f-fishing-pulling-back.png'), (192, 192, 6, 6, 35));
        expect(grid('$f-fishing-throwing.png'), (192, 192, 4, 4, 14));
        // The siblings are unchanged.
        expect(grid('$f-death.png'), (192, 192, 5, 4, 19));
        expect(grid('$f-hurt.png'), (192, 192, 8, 1, 8));
        for (final s in ['idle', 'walk', 'fishing-waiting']) {
          expect(grid('$f-$s.png'), (192, 192, 10, 1, 10));
        }
      }
    },
  );

  test(
    'M55: crab, chimney smoke, villager parts, one-picture props (read-only)',
    skip: Directory(managed).existsSync() ? false : 'no $managed',
    () {
      final packs = scanLibrary(managed).packs;
      Map<String, SpriteAnim> animsOf(String id) {
        final pack = packs.firstWhere((p) => p.id == id);
        return {
          for (final a in loadPackContents(pack.path, [
            for (final f in pack.files) (f, 0),
          ]).detected)
            a.path: a,
        };
      }

      (int, int, int, int, int)? grid(Map<String, SpriteAnim> m, String rel) {
        final a = m[rel];
        return a == null
            ? null
            : (a.frameW, a.frameH, a.cols, a.rows, a.frameCount);
      }

      final sea = animsOf(
        'RafaelMatos/ERW - Sea Adventures (GL 2.0 expansion) V1.5',
      );
      const crab = 'Characters/crab-claw enemy/crab-claw enemy';
      expect(grid(sea, '$crab-idle2.png'), (160, 128, 8, 1, 8));
      expect(grid(sea, '$crab-atk2-finish.png'), (160, 128, 8, 1, 8));
      expect(grid(sea, '$crab-atk1.png'), (160, 128, 17, 1, 17));
      expect(grid(sea, '$crab-atk1-packed.png'), (160, 128, 5, 4, 17));

      final village = animsOf('RafaelMatos/Epic RPG World - The Village V2.2');
      for (final n in [1, 2]) {
        for (final tone in ['dark', 'white']) {
          expect(
            grid(
              village,
              'buildings/Animated stuff/chimney-smoke-chiminey $n - '
              '$tone smoke.png',
            ),
            (96, 64, 16, 1, 16),
          );
        }
      }
      expect(
        village['tilesets and props/props-sprites/pennant-bunting_2.png'],
        isNull,
      );
      const parts = 'NPCs/villager/female/by parts/villager';
      expect(grid(village, '$parts-R-Arm-skin2-death.png'), (
        160,
        160,
        12,
        2,
        17,
      ));
      for (final m in [
        for (final MapEntry(:key, :value) in village.entries)
          if (key.contains('/by parts/') && key.endsWith('.png')) value,
      ]) {
        expect((m.frameW, m.frameH), (160, 160), reason: m.path);
      }

      final interiors = animsOf(
        'RafaelMatos/Epic RPG World - Village(interiors) V1.3',
      );
      expect(
        interiors['assets/furniture_and_props_sprites/decor_shields_7.png'],
        isNull,
      );
    },
  );

  test(
    'M94: RafaelMatos packs open from the animation cache fast (read-only)',
    skip: Directory(managed).existsSync() ? false : 'no $managed',
    () {
      final packs = scanLibrary(managed).packs;
      for (final pack in packs.where((p) => p.id.startsWith('RafaelMatos/'))) {
        final files = [
          for (var i = 0; i < pack.files.length; i++)
            (pack.files[i], pack.sizes[i]),
        ];
        final cold = Stopwatch()..start();
        final first = loadPackContentsCached(pack.path, files);
        cold.stop();
        final warm = Stopwatch()..start();
        final again = loadPackContentsCached(
          pack.path,
          files,
          cached: first.fresh,
        );
        warm.stop();
        // ignore: avoid_print
        print(
          'M94 ${pack.title}: ${cold.elapsedMilliseconds} ms cold, '
          '${warm.elapsedMilliseconds} ms cached',
        );
        expect(again.fresh, isNull, reason: pack.title);
        expect(again.contents.detected, first.contents.detected);
        expect(warm.elapsedMilliseconds, lessThan(500), reason: pack.title);
      }
    },
  );
}
