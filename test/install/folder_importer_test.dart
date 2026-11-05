import 'dart:io';

import 'package:assets_explorer/core/library_scanner.dart';
import 'package:assets_explorer/core/sidecar.dart';
import 'package:assets_explorer/install/folder_importer.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../helpers/fs.dart';

void main() {
  late Directory tmp;
  late String src;
  late String lib;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('import');
    src = p.join(tmp.path, 'src');
    lib = p.join(tmp.path, 'lib');
    copyTree('test/fixtures/library_src', src);
    Directory(lib).createSync();
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  ImportItem item(ImportPlan plan, String rel) =>
      plan.items.singleWhere((i) => i.sourceRel == rel);

  test('safeFolderName strips characters invalid on any desktop OS', () {
    expect(safeFolderName('a/b:c*?"<>|'), 'a_b_c______');
    expect(safeFolderName('Pack v1. '), 'Pack v1');
    expect(safeFolderName('...'), '_');
  });

  group('plan', () {
    test('one item per top-level pack with detected metadata', () {
      final plan = planFolderImport(src, lib);
      expect(
        plan.items.map((i) => i.sourceRel),
        unorderedEquals([
          'art/characters/HeroMaker/Knight Pack v1.0',
          'art/characters/HeroMaker/Free Slime Pack',
          'art/environments/Forest Tiles 16x16',
          'bundles/Mega Bundle v3',
          'sfx/Loose Sounds',
          'music/SoloArtist',
          'misc',
        ]),
      );
      final bundle = item(plan, 'bundles/Mega Bundle v3');
      expect(bundle.isContainer, isTrue);
      expect(bundle.subPackCount, 3);
      expect(bundle.fileCount, 10);
      expect(plan.items.every((i) => i.selected), isTrue);
    });

    test('targets are Author/Pack, unknown authors grouped', () {
      final targets = planFolderImport(src, lib).targets().values;
      expect(
        targets,
        containsAll([
          'HeroMaker/Knight Pack v1.0',
          'Leafy Studio/Forest Tiles 16x16',
          'noisy/Loose Sounds',
          'Unknown Author/misc',
        ]),
      );
    });

    test('name clashes get numbered instead of overwriting', () {
      Directory(p.join(lib, 'HeroMaker', 'Free Slime Pack'))
          .createSync(recursive: true);
      final plan = planFolderImport(src, lib);
      item(plan, 'art/characters/HeroMaker/Knight Pack v1.0').folderName =
          'Free Slime Pack';
      final t = plan.targets();
      expect(
        t[item(plan, 'art/characters/HeroMaker/Knight Pack v1.0')],
        'HeroMaker/Free Slime Pack (3)',
      );
      expect(
        t[item(plan, 'art/characters/HeroMaker/Free Slime Pack')],
        'HeroMaker/Free Slime Pack (2)',
      );
    });

    test('unselected items get no target', () {
      final plan = planFolderImport(src, lib);
      item(plan, 'misc').selected = false;
      expect(plan.targets().values, isNot(contains('Unknown Author/misc')));
    });

    test('overlapping source and library are refused', () {
      Matcher overlap({required bool inLibrary}) => throwsA(
        isA<OverlappingFoldersError>().having(
          (e) => e.sourceInLibrary,
          'sourceInLibrary',
          inLibrary,
        ),
      );
      // The library lies inside the picked folder.
      expect(
        () => planFolderImport(src, p.join(src, 'lib')),
        overlap(inLibrary: false),
      );
      expect(() => planFolderImport(src, src), overlap(inLibrary: true));
      // The picked folder lies inside the library.
      expect(() => planFolderImport(src, tmp.path), overlap(inLibrary: true));
      try {
        planFolderImport(src, tmp.path);
      } on OverlappingFoldersError catch (e) {
        expect(e.message, startsWith('This folder is inside your library ('));
        expect(e.message, contains(p.canonicalize(tmp.path)));
      }
    });
  });

  group('import', () {
    test(
      'copies every pack, verifies it and never touches the source',
      () async {
        final before = snapshot(src);
        final plan = planFolderImport(src, lib);
        final outcomes = await runImport(plan).toList();

        expect(outcomes, hasLength(7));
        for (final o in outcomes) {
          expect(o.verified, isTrue, reason: '${o.title}: ${o.error}');
        }
        expect(snapshot(src), before);
        expect(Directory(p.join(lib, '.staging')).existsSync(), isFalse);

        final bundle = outcomes.singleWhere((o) => o.title == 'Mega Bundle v3');
        expect(bundle.copiedFiles, 10);
        final copied = snapshot(p.join(lib, bundle.target));
        final original = snapshot(p.join(src, 'bundles/Mega Bundle v3'));
        for (final e in copied.entries) {
          if (e.key == packFileName) continue;
          expect(original[e.key], e.value, reason: e.key);
        }
      },
    );

    test('writes sidecars and author files in the library layout', () async {
      final plan = planFolderImport(src, lib);
      await runImport(plan).drain<void>();

      final forest = p.join(lib, 'Leafy Studio', 'Forest Tiles 16x16');
      expect(
        File(p.join(forest, authorFileName)).existsSync(),
        isFalse,
        reason: 'author file moves up to the author folder',
      );
      final author = AuthorInfo.read(
        p.join(lib, 'Leafy Studio', authorFileName),
      )!;
      expect(author.license, 'CC-BY 4.0');
      final sc = PackSidecar.read(forest)!;
      expect(sc.source, PackSource.imported);
      expect(
        sc.sourcePath,
        p.canonicalize(p.join(src, 'art/environments/Forest Tiles 16x16')),
      );
      expect(sc.types, ['environment']);
      expect(
        PackSidecar.read(p.join(lib, 'BigCo', 'Mega Bundle v3'))!.isContainer,
        isTrue,
      );
      expect(Directory(p.join(lib, 'Unknown Author')).existsSync(), isTrue);
      expect(
        File(p.join(lib, 'Unknown Author', authorFileName)).existsSync(),
        isFalse,
      );
    });

    test('the imported library scans to the same packs', () async {
      await runImport(planFolderImport(src, lib)).drain<void>();
      final scan = scanLibrary(lib);
      final top = scan.packs.where((x) => x.parentId == null).toList();
      expect(
        top.map((x) => x.title),
        unorderedEquals(
          planFolderImport(
            src,
            p.join(tmp.path, 'other'),
          ).items.map((i) => i.title),
        ),
      );
      final bundle = top.singleWhere((x) => x.title == 'Mega Bundle v3');
      expect(scan.packs.where((x) => x.parentId == bundle.id), hasLength(3));
      expect(
        top.singleWhere((x) => x.title == 'Knight Pack v1.0').author!.user,
        'HeroMaker',
      );
    });

    test('edits from the review table end up in the sidecar', () async {
      final plan = planFolderImport(src, lib);
      final misc = item(plan, 'misc')
        ..author = const AuthorInfo(user: 'Me', url: 'https://me.itch.io/')
        ..tags = ['props']
        ..types = ['environment'];
      plan.items.where((i) => i != misc).forEach((i) => i.selected = false);
      final [outcome] = await runImport(plan).toList();
      expect(outcome.target, 'Me/misc');
      final sc = PackSidecar.read(p.join(lib, 'Me', 'misc'))!;
      expect(sc.tags, ['props']);
      expect(sc.types, ['environment']);
      expect(
        AuthorInfo.read(p.join(lib, 'Me', authorFileName))!.url,
        'https://me.itch.io/',
      );
    });

    test('re-planning marks packs already imported and skips them', () async {
      await runImport(planFolderImport(src, lib)).drain<void>();
      final again = planFolderImport(src, lib);
      expect(
        again.items.every((i) => i.importedAs != null && !i.selected),
        isTrue,
      );
      expect(item(again, 'misc').importedAs, 'Unknown Author/misc');
      expect(again.targets(), isEmpty);
    });

    test(
      'an existing author file keeps its values and gains missing ones',
      () async {
        Directory(p.join(lib, 'HeroMaker')).createSync();
        File(p.join(lib, 'HeroMaker', authorFileName))
            .writeAsStringSync('user: HeroMaker\nnote: mine\n');
        await runImport(planFolderImport(src, lib)).drain<void>();
        final a = AuthorInfo.read(p.join(lib, 'HeroMaker', authorFileName))!;
        expect(a.url, 'https://heromaker.itch.io/');
        expect(a.extra, {'note': 'mine'});
      },
    );

    test('a target that appeared meanwhile fails cleanly', () {
      final plan = planFolderImport(src, lib);
      final knight = item(plan, 'art/characters/HeroMaker/Knight Pack v1.0');
      Directory(p.join(lib, 'HeroMaker', 'Knight Pack v1.0'))
          .createSync(recursive: true);
      final o = importItem(knight, lib, 'HeroMaker/Knight Pack v1.0');
      expect(o.verified, isFalse);
      expect(o.error, contains('already exists'));
      expect(Directory(p.join(lib, '.staging')).existsSync(), isFalse);
    });
  });
}
