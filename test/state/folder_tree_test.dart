import 'dart:io';
import 'dart:math' as math;

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loot_silo/core/library_index.dart';
import 'package:loot_silo/core/library_scanner.dart';
import 'package:loot_silo/core/sidecar.dart';
import 'package:loot_silo/state/dashboard.dart';
import 'package:loot_silo/state/favorites.dart';
import 'package:loot_silo/state/folder_tree.dart';
import 'package:path/path.dart' as p;

import '../core/sub_folders_test.dart' show writeFiles;

const bundle = 'Kenney/Game Assets All in One';

/// M98: the dashboard's folder tree and its node filter.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late Directory tmp;
  late LibraryIndex index;
  late List<PackRow> packs;

  setUpAll(() async {
    tmp = Directory.systemTemp.createTempSync('folder_tree');
    writeFiles(tmp.path, [
      // An author folder with two packs.
      'HeroMaker/Knight Pack/License.txt',
      'HeroMaker/Knight Pack/knight.png',
      'HeroMaker/Slimes/License.txt',
      'HeroMaker/Slimes/slime.png',
      // A Kenney-like bundle with sections.
      for (final pk in ['Tanks', 'Planes', 'Ships']) ...[
        '$bundle/2D assets/$pk (12 assets)/License.txt',
        '$bundle/2D assets/$pk (12 assets)/PNG/a.png',
      ],
      for (final pk in ['RPG sounds', 'UI sounds']) ...[
        '$bundle/Audio/$pk (5 sounds)/License.txt',
        '$bundle/Audio/$pk (5 sounds)/click.ogg',
      ],
      // A type-first folder.
      'Audio/Forest Music/License.txt',
      'Audio/Forest Music/forest.ogg',
      // PNG / Default merges; _itch is left out.
      'Pixel/Tiles/License.txt',
      'Pixel/Tiles/PNG/Default/a.png',
      'Pixel/Tiles/PNG/Default/b.png',
      'Pixel/Tiles/Vector/c.svg',
      'Pixel/Tiles/Vector/Big/d.svg',
      'Pixel/Tiles/_itch/cover.png',
    ]);
    AuthorInfo(user: 'HeroMaker').write(p.join(tmp.path, 'HeroMaker'));
    AuthorInfo(user: 'Kenney').write(p.join(tmp.path, 'Kenney'));
    AuthorInfo(user: 'Pixel').write(p.join(tmp.path, 'Pixel'));
    index = LibraryIndex(NativeDatabase.memory());
    await index.replaceScan(scanLibrary(tmp.path));
    packs = await index.allPacks();
  });
  tearDownAll(() async {
    await index.close();
    tmp.deleteSync(recursive: true);
  });

  /// Labels by depth, as `  label` lines, with every node open.
  List<String> outline(List<TreeNode> nodes, [int depth = 0]) => [
    for (final n in nodes) ...[
      '${'  ' * depth}${n.label} [${n.kind.name}]',
      ...outline(n.children, depth + 1),
    ],
  ];

  test('nodes and order: folders first, then packs, by name', () {
    final tree = buildLibraryTree(packs);
    expect(outline(tree), [
      'Audio [folder]',
      '  Forest Music [pack]',
      'HeroMaker [folder]',
      '  Knight Pack [pack]',
      '  Slimes [pack]',
      'Kenney [folder]',
      '  Game Assets All in One [bundle]',
      '    2D assets [section]',
      '      Planes (12 assets) [pack]',
      '      Ships (12 assets) [pack]',
      '      Tanks (12 assets) [pack]',
      '    Audio [section]',
      '      RPG sounds (5 sounds) [pack]',
      '      UI sounds (5 sounds) [pack]',
      'Pixel [folder]',
      '  Tiles [pack]',
    ]);
    final kenney = tree.firstWhere((n) => n.label == 'Kenney');
    expect(kenney.children.single.path, bundle);
    expect(kenney.children.single.packId, isNull, reason: 'a bundle');
  });

  test(
    "a pack's folders: chains merged, _itch left out, file counts",
    () async {
      final files = await index.filesOf('Pixel/Tiles');
      final folders = buildPackFolders('Pixel/Tiles', files);
      expect(outline(folders), [
        'PNG / Default [packFolder]',
        'Vector [packFolder]',
        '  Big [packFolder]',
      ]);
      expect(folders.first.path, 'Pixel/Tiles/PNG/Default');
      expect(folders.first.fileCount, 2);
      expect(folders[1].fileCount, 2, reason: 'Vector and Vector/Big');
      expect(await index.packsWithFolders(), contains('Pixel/Tiles'));
      expect(
        await index.packsWithFolders(),
        isNot(contains('HeroMaker/Slimes')),
      );
    },
  );

  test('counts: packs above packs (bundle packs, not the bundle), files in '
      'packs, following the filters', () {
    final tree = buildLibraryTree(packs);
    TreeNode at(String path) {
      TreeNode? find(List<TreeNode> ns) {
        for (final n in ns) {
          if (n.path == path) return n;
          if (find(n.children) case final f?) return f;
        }
        return null;
      }

      return find(tree)!;
    }

    var c = TreeCounts.of(packs, const DashboardQuery(), null);
    expect(c.of(at('Kenney')), 5);
    expect(c.of(at(bundle)), 5);
    expect(c.of(at('$bundle/2D assets')), 3);
    expect(c.of(at('HeroMaker')), 2);
    final tiles = at('Pixel/Tiles');
    expect(c.of(tiles), tiles.fileCount);

    // A type filter: only the audio packs are counted.
    c = TreeCounts.of(packs, const DashboardQuery(types: {'sfx'}), null);
    expect(c.of(at('$bundle/Audio')), 2);
    expect(c.of(at('$bundle/2D assets')), 0);
    expect(c.of(at('HeroMaker')), 0);
    expect(c.of(tiles), 0, reason: 'filtered out: shown as 0');
  });

  group('the node filter', () {
    List<String> ids(DashboardQuery q, {bool open = false}) =>
        [for (final pk in applyQuery(packs, q, null, openBundles: open)) pk.id]
          ..sort();

    test('an author folder shows its packs', () {
      expect(ids(const DashboardQuery(node: 'HeroMaker')), [
        'HeroMaker/Knight Pack',
        'HeroMaker/Slimes',
      ]);
    });

    test('above a bundle: the bundle tile; at a section: its packs', () {
      expect(ids(const DashboardQuery(node: 'Kenney')), [bundle]);
      final section = [
        for (final pk in ['Planes', 'Ships', 'Tanks'])
          '$bundle/2D assets/$pk (12 assets)',
      ];
      expect(ids(const DashboardQuery(node: '$bundle/2D assets')), section);
      expect(
        ids(const DashboardQuery(node: '$bundle/2D assets'), open: true),
        section,
        reason: 'Expanded',
      );
      expect(ids(const DashboardQuery(node: bundle)), hasLength(5));
    });

    test(
      'a folder inside a pack keeps that pack, and its files only',
      () async {
        const q = DashboardQuery(node: 'Pixel/Tiles/PNG');
        expect(ids(q), ['Pixel/Tiles']);
        final hits = (await index.searchFiles('a')).hits;
        final tiles = favoriteFileTiles(
          hits,
          packs,
          q.copyWith(text: 'a'),
          const Favorites(),
        );
        expect(tiles, isNotEmpty);
        expect(
          tiles.every((t) => t.relPath.startsWith('PNG/')),
          isTrue,
          reason: '${tiles.map((t) => t.relPath)}',
        );
        expect(nodeFolderIn('Pixel/Tiles', q.node), 'PNG');
        expect(nodeFolderIn('Pixel/Tiles', 'Pixel'), isNull);
      },
    );

    test('Expanded tiles inside a pack keep the folder holding the node', () {
      final pack = packs.firstWhere((pk) => pk.id == 'Pixel/Tiles');
      final tiles = [
        DashboardTile(pack, pack, 'PNG'),
        DashboardTile(pack, pack, 'Vector'),
        for (final pk in packs)
          if (pk.id != pack.id) DashboardTile(pk, pk),
      ];
      expect(
        [for (final t in nodeTiles(tiles, 'Pixel/Tiles/PNG/Default')) t.key],
        ['Pixel/Tiles/PNG'],
      );
    });

    test('facets count only what is under the node', () {
      final f = Facets.forQuery(
        packs,
        const DashboardQuery(node: 'HeroMaker'),
        null,
      );
      expect(f.authors, [('HeroMaker', 2)]);
    });

    test('the selected node again clears it; copyWith keeps it', () {
      const q = DashboardQuery(node: 'HeroMaker');
      expect(q.copyWith(text: 'x').node, 'HeroMaker');
      expect(q.copyWith(node: null).node, isNull);
      expect(q.isFiltered, isTrue);
      expect(q.isNarrowed, isFalse, reason: 'bundles stay tiles');
    });
  });

  test('the chip label: titles, › and a middle ellipsis', () {
    expect(
      nodeLabel('$bundle/2D assets', packs),
      'Kenney › Game Assets All in One › 2D assets',
    );
    final cut = middleEllipsis('a' * 30 + 'b' * 30, 21);
    expect(cut.length, 21);
    expect(cut, startsWith('aaaa'));
    expect(cut, endsWith('bbbb'));
    expect(cut, contains('…'));
  });

  test('visible rows: only open nodes; a pack expander before loading', () {
    final tree = buildLibraryTree(packs);
    var rows = visibleRows(tree, const {}, const {}, (_) => true);
    expect(rows.map((r) => r.node.label), [
      'Audio',
      'HeroMaker',
      'Kenney',
      'Pixel',
    ]);
    rows = visibleRows(
      tree,
      const {'Pixel', 'Pixel/Tiles'},
      const {},
      (id) => id == 'Pixel/Tiles',
    );
    final tiles = rows.firstWhere((r) => r.node.path == 'Pixel/Tiles');
    expect(tiles.expandable, isTrue);
    expect(rows.last.node.path, 'Pixel/Tiles', reason: 'not loaded yet');
  });

  test('scale: 50,000 files build and count fast', () {
    final rand = math.Random(1);
    final big = <PackRow>[];
    final files = <String>[];
    for (var i = 0; i < 50000; i++) {
      files.add(
        'set${rand.nextInt(40)}/sub${rand.nextInt(12)}/'
        'deep${rand.nextInt(6)}/f$i.png',
      );
    }
    for (var a = 0; a < 60; a++) {
      for (var k = 0; k < 20; k++) {
        big.add(
          packs.first.copyWith(
            id: 'Author $a/Pack $k',
            title: 'Pack $k',
            types: const ['sprite'],
          ),
        );
      }
    }
    final sw = Stopwatch()..start();
    final tree = buildLibraryTree(big);
    final treeMs = sw.elapsedMilliseconds;
    sw.reset();
    final folders = buildPackFolders('Author 0/Pack 0', files);
    final foldersMs = sw.elapsedMilliseconds;
    sw.reset();
    TreeCounts.of(big, const DashboardQuery(types: {'sprite'}), null);
    final countsMs = sw.elapsedMilliseconds;
    // ignore: avoid_print
    print(
      'M98 scale: tree of ${big.length} packs $treeMs ms, '
      '50,000-file pack folders $foldersMs ms, counts $countsMs ms',
    );
    expect(tree, hasLength(60));
    expect(folders, hasLength(40));
    expect(countsMs, lessThan(30));
  });
}
