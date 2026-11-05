// Read-only checks against the user's real `assets_library_OLD`.
// Skipped automatically where that folder does not exist.
import 'dart:io';

import 'package:assets_explorer/core/animation_detector.dart';
import 'package:assets_explorer/core/library_index.dart';
import 'package:assets_explorer/core/library_scanner.dart';
import 'package:assets_explorer/core/library_service.dart';
import 'package:assets_explorer/core/pack_editor.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

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

    test('Kenney bundles are containers with many sub-packs', () {
      for (final name in [
        'Kenney Game Assets 1 version 42',
        'Kenney Game Assets 2 version 22',
      ]) {
        final bundle = result.packs.singleWhere((p) => p.title == name);
        expect(bundle.isContainer, isTrue);
        final subs = result.packs.where((p) => p.parentId == bundle.id);
        expect(subs.length, greaterThan(40), reason: name);
        expect(subs.every((s) => s.author?.user == 'Kenney'), isTrue);
      }
    });

    test('Zerie, RafaelMatos and OboroPixel packs are detected', () {
      expect(under('art/characters/Zerie/').map((p) => p.title), [
        'Tiny RPG Character Asset Pack 01 v2.0 -Full 22 Characters',
      ]);
      expect(under('art/environments/RafaelMatos/'), hasLength(5));
      expect(
        under('art/environments/RafaelMatos/').every((p) => !p.isContainer),
        isTrue,
      );
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
}
