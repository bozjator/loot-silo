import 'dart:io';

import 'package:assets_explorer/core/library_index.dart';
import 'package:assets_explorer/state/dashboard.dart';
import 'package:assets_explorer/state/providers.dart';
import 'package:assets_explorer/state/settings.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../core/sub_folders_test.dart' show writeFiles;

PackRow pack(
  String id, {
  String? title,
  String? author,
  String? parent,
  bool container = false,
  List<String> types = const ['misc'],
  List<String> tags = const [],
  String? source,
  int files = 1,
  int bytes = 1,
}) => PackRow(
  id: id,
  path: '/lib/$id',
  title: title ?? id.split('/').last,
  author: author,
  parentId: parent,
  isContainer: container,
  types: types,
  tags: tags,
  source: source,
  usedIn: const [],
  fileCount: files,
  totalBytes: bytes,
);

void main() {
  final packs = [
    pack(
      'A/Knights',
      author: 'A',
      types: ['character'],
      tags: ['pixel-art'],
      source: 'imported',
      files: 5,
      bytes: 50,
    ),
    pack(
      'B/Bundle',
      author: 'B',
      container: true,
      types: ['3d', 'ui'],
      bytes: 900,
      files: 2,
    ),
    pack('B/Bundle/Tanks', author: 'B', parent: 'B/Bundle', types: ['3d']),
    pack(
      'B/Bundle/Buttons',
      author: 'B',
      parent: 'B/Bundle',
      types: ['ui'],
      tags: ['pixel-art'],
    ),
    pack(
      'c/zap',
      author: null,
      types: ['sfx'],
      source: 'manual',
      files: 9,
      bytes: 10,
    ),
  ];
  List<String> ids(DashboardQuery q, [List<String>? hits]) => [
    for (final p in applyQuery(packs, q, hits)) p.id,
  ];

  test('root view shows top-level packs by name', () {
    expect(ids(const DashboardQuery()), ['B/Bundle', 'A/Knights', 'c/zap']);
  });

  test('bundle view shows its sub-packs', () {
    expect(ids(const DashboardQuery(bundleId: 'B/Bundle')), [
      'B/Bundle/Buttons',
      'B/Bundle/Tanks',
    ]);
  });

  test('filters are flat (sub-packs included), OR within, AND across', () {
    expect(ids(const DashboardQuery(types: {'3d'})), [
      'B/Bundle',
      'B/Bundle/Tanks',
    ]);
    expect(ids(const DashboardQuery(types: {'3d', 'sfx'})), [
      'B/Bundle',
      'B/Bundle/Tanks',
      'c/zap',
    ]);
    expect(ids(const DashboardQuery(types: {'ui'}, tags: {'pixel-art'})), [
      'B/Bundle/Buttons',
    ]);
    expect(ids(const DashboardQuery(authors: {'A'})), ['A/Knights']);
    expect(ids(const DashboardQuery(sources: {noSource})), [
      'B/Bundle',
      'B/Bundle/Buttons',
      'B/Bundle/Tanks',
    ]);
    expect(ids(const DashboardQuery(sources: {'manual'})), ['c/zap']);
  });

  test('filters inside a bundle stay inside it', () {
    expect(ids(const DashboardQuery(bundleId: 'B/Bundle', types: {'ui'})), [
      'B/Bundle/Buttons',
    ]);
  });

  test('search hits keep FTS order under best match', () {
    const q = DashboardQuery(text: 'x');
    expect(ids(q, ['c/zap', 'B/Bundle/Tanks']), ['c/zap', 'B/Bundle/Tanks']);
    expect(ids(q.copyWith(sort: PackSort.title), ['c/zap', 'B/Bundle/Tanks']), [
      'B/Bundle/Tanks',
      'c/zap',
    ]);
  });

  test('sorts by author (unknown last), size and file count', () {
    expect(ids(const DashboardQuery(sort: PackSort.author)), [
      'A/Knights',
      'B/Bundle',
      'c/zap',
    ]);
    expect(ids(const DashboardQuery(sort: PackSort.size)), [
      'B/Bundle',
      'A/Knights',
      'c/zap',
    ]);
    expect(ids(const DashboardQuery(sort: PackSort.files)), [
      'c/zap',
      'A/Knights',
      'B/Bundle',
    ]);
  });

  test('facets count values, most common first', () {
    final f = Facets.of(packs);
    expect(f.authors.first, ('B', 3));
    expect(f.tags, [('pixel-art', 2)]);
    expect(f.sources.first, (noSource, 3));
  });

  group('faceted counts', () {
    final lib = [
      pack('r/a', author: 'Rafael', tags: ['pixel'], types: ['character']),
      pack(
        'r/b',
        author: 'Rafael',
        tags: ['ui'],
        types: ['ui'],
        source: 'itch',
      ),
      pack('k/c', author: 'Kenney', tags: ['pixel', '3d'], types: ['ui']),
      pack('k/d', author: 'Kenney', tags: ['pixel'], parent: 'k/b'),
    ];

    test('no filters: every pack counts, sub-packs too', () {
      final f = Facets.forQuery(lib, const DashboardQuery(), null);
      expect(f.tags, [('pixel', 3), ('3d', 1), ('ui', 1)]);
      expect(f.authors, [('Kenney', 2), ('Rafael', 2)]);
      expect(f.types.first, ('ui', 2));
    });

    test('an author narrows the other facets, not its own', () {
      final f = Facets.forQuery(
        lib,
        const DashboardQuery(authors: {'Rafael'}),
        null,
      );
      expect(f.tags, [('pixel', 1), ('ui', 1)]);
      expect(f.sources, [('itch', 1), (noSource, 1)]);
      expect(f.types, [('character', 1), ('ui', 1)]);
      // Its own menu still offers the other authors.
      expect(f.authors, [('Kenney', 2), ('Rafael', 2)]);
    });

    test('search hits and an open bundle limit the counts', () {
      final f = Facets.forQuery(lib, const DashboardQuery(), ['r/a', 'k/c']);
      expect(f.tags, [('pixel', 2), ('3d', 1)]);
      final b = Facets.forQuery(
        lib,
        const DashboardQuery(bundleId: 'k/b'),
        null,
      );
      expect(b.authors, [('Kenney', 1)]);
    });

    test('a selected value nothing matches stays, at 0', () {
      final f = Facets.forQuery(
        lib,
        const DashboardQuery(authors: {'Rafael'}, tags: {'3d'}),
        null,
      );
      // Tags ignore the tag selection: Rafael has no 3d pack.
      expect(f.tags, [('pixel', 1), ('ui', 1), ('3d', 0)]);
      // Authors with the 3d filter: only Kenney; Rafael kept at 0.
      expect(f.authors, [('Kenney', 1), ('Rafael', 0)]);
    });
  });

  testWidgets('debounce waits 200 ms after the last key press', (tester) async {
    expect(DashboardQueryNotifier.searchDebounce.inMilliseconds, 200);
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final texts = <String>[];
    c.listen(
      dashboardQueryProvider.select((q) => q.text),
      (_, t) => texts.add(t),
    );
    final n = c.read(dashboardQueryProvider.notifier);
    // Keys 190 ms apart: each one restarts the wait, so nothing runs
    // although 950 ms pass in all.
    for (final t in ['b', 'ba', 'bar', 'barr', 'barre']) {
      n.setText(t);
      await tester.pump(const Duration(milliseconds: 190));
    }
    expect(texts, isEmpty);
    // 199 ms after the last key: still waiting; at 200 ms it runs once.
    await tester.pump(const Duration(milliseconds: 9));
    expect(texts, isEmpty);
    await tester.pump(const Duration(milliseconds: 1));
    expect(texts, ['barre']);
  });

  testWidgets('search text is debounced; clearing applies at once', (
    tester,
  ) async {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final texts = <String>[];
    c.listen(
      dashboardQueryProvider.select((q) => q.text),
      (_, t) => texts.add(t),
    );
    final n = c.read(dashboardQueryProvider.notifier);
    for (final t in ['b', 'ba', 'bar', 'barr']) {
      n.setText(t);
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(texts, isEmpty);
    await tester.pump(DashboardQueryNotifier.searchDebounce);
    expect(texts, ['barr']);
    n.setText('barre');
    n.setText('');
    expect(texts, ['barr', '']);
    // The pending 'barre' never lands.
    await tester.pump(const Duration(seconds: 1));
    expect(texts, ['barr', '']);
    n.setText('x');
    n.clearFilters();
    await tester.pump(const Duration(seconds: 1));
    expect(texts, ['barr', '']);
  });

  testWidgets('showAuthor keeps only that author and the sort', (tester) async {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final n = c.read(dashboardQueryProvider.notifier)
      ..setSort(PackSort.title)
      ..toggleType('ui')
      ..toggleAuthor('Kenney')
      ..toggleTag('pixel')
      ..openBundle('b')
      ..setText('pending');
    n.showAuthor('Rafael');
    // The pending search never lands.
    await tester.pump(const Duration(seconds: 1));
    final q = c.read(dashboardQueryProvider);
    expect(q.authors, {'Rafael'});
    expect(q.text, isEmpty);
    expect(q.types, isEmpty);
    expect(q.tags, isEmpty);
    expect(q.bundleId, isNull);
    expect(q.sort, PackSort.title);
  });

  test('copyWith can clear the bundle', () {
    const q = DashboardQuery(bundleId: 'x');
    expect(q.copyWith(bundleId: () => null).bundleId, isNull);
    expect(q.copyWith(text: 'a').bundleId, 'x');
  });

  group('tag sort', () {
    final tagged = [
      pack('p/one', title: 'Zeta', tags: ['pixel', 'Animals']),
      pack('p/two', title: 'Alpha', tags: ['animals', 'pixel']),
      pack('p/three', title: 'Beta'),
      pack('p/four', title: 'Gamma', tags: ['UI']),
      pack('p/five', title: 'Aardvark'),
    ];
    List<String> sorted(List<PackRow> l) => [
      for (final x in applyQuery(
        l,
        const DashboardQuery(sort: PackSort.tags),
        null,
      ))
        x.title,
    ];

    test('orders by sorted tags, ties by title, untagged last', () {
      expect(sorted(tagged), ['Alpha', 'Zeta', 'Gamma', 'Aardvark', 'Beta']);
    });

    test('is stable whatever the input order', () {
      expect(sorted(tagged.reversed.toList()), sorted(tagged));
      expect(sorted([...tagged]..shuffle()), sorted(tagged));
    });

    test('keys are the case-insensitively sorted tags', () {
      expect(sortedTags(['pixel', 'Animals', 'cute']), [
        'Animals',
        'cute',
        'pixel',
      ]);
      expect(tagSortKey(['pixel', 'Animals']), 'animals, pixel');
      expect(tagSortKey(const []), isNull);
      expect(PackSort.tags.label, 'Tags');
    });
  });

  group('type sort', () {
    final typed = [
      pack('p/one', title: 'Zeta', types: ['vfx', 'character']),
      pack('p/two', title: 'Alpha', types: ['character', 'vfx']),
      pack('p/three', title: 'Beta', types: const []),
      pack('p/four', title: 'Gamma', types: ['ui']),
      pack('p/five', title: 'Aardvark', types: ['sfx']),
      pack('p/six', title: 'Delta', types: const []),
    ];
    List<String> sorted(
      List<PackRow> l, [
      DashboardQuery q = const DashboardQuery(sort: PackSort.type),
    ]) => [for (final x in applyQuery(l, q, null)) x.title];

    test('orders by sorted types, ties by title, untyped last', () {
      expect(sorted(typed), [
        'Alpha',
        'Zeta',
        'Aardvark',
        'Gamma',
        'Beta',
        'Delta',
      ]);
    });

    test('is stable whatever the input order', () {
      expect(sorted(typed.reversed.toList()), sorted(typed));
      expect(sorted([...typed]..shuffle()), sorted(typed));
    });

    test('works with the type filter', () {
      expect(
        sorted(
          typed,
          const DashboardQuery(sort: PackSort.type, types: {'vfx', 'sfx'}),
        ),
        ['Alpha', 'Zeta', 'Aardvark'],
      );
    });

    test('folder tiles keep their pack\'s place in the Expanded view', () {
      final subs = {
        'p/one': [
          for (final f in ['Hero', 'Slime'])
            SubFolderRow(
              packId: 'p/one',
              folder: f,
              preview: null,
              fileCount: 1,
              totalBytes: 1,
            ),
        ],
      };
      final tiles = expandPacks(
        applyQuery(typed, const DashboardQuery(sort: PackSort.type), null),
        subs,
      );
      expect(
        [for (final t in tiles.take(3)) t.key],
        ['p/two', 'p/one/Hero', 'p/one/Slime'],
      );
      expect(tiles[1].pack.types, ['vfx', 'character']);
    });

    test('keys are the alphabetically sorted types', () {
      expect(sortedTypes(['vfx', 'Character', 'sfx']), [
        'Character',
        'sfx',
        'vfx',
      ]);
      expect(typeSortKey(['vfx', 'character']), 'character, vfx');
      expect(typeSortKey(const []), isNull);
      expect(PackSort.type.label, 'Type');
    });
  });

  group('expanded view', () {
    SubFolderRow sub(String packId, String folder) => SubFolderRow(
      packId: packId,
      folder: folder,
      preview: 'idle.png',
      fileCount: 3,
      totalBytes: 30,
    );
    final list = [
      pack('A/Knights', author: 'A', tags: ['t']),
      pack('P/Banner', title: 'Pixel Banner'),
    ];
    final subs = {
      'P/Banner': [
        sub('P/Banner', 'ArcherSkeleton'),
        sub('P/Banner', 'Wolf_pack'),
      ],
    };

    test('replaces a splitting pack with one tile per folder in place', () {
      final tiles = expandPacks(list, subs);
      expect(
        [for (final t in tiles) t.key],
        ['A/Knights', 'P/Banner/ArcherSkeleton', 'P/Banner/Wolf_pack'],
      );
      final wolf = tiles.last;
      expect(wolf.tile.title, 'Wolf pack');
      expect(wolf.tile.author, 'Pixel Banner');
      expect(wolf.tile.path, '/lib/P/Banner/Wolf_pack');
      expect(wolf.tile.preview, 'idle.png');
      expect(wolf.tile.fileCount, 3);
      expect(wolf.pack.id, 'P/Banner');
      expect(wolf.folder, 'Wolf_pack');
      expect(tiles.first.folder, isNull);
    });

    test('search narrows to matching folders, or keeps them all', () {
      List<String?> folders(String text) => [
        for (final t in expandPacks(list, subs, searchText: text)) t.folder,
      ];
      expect(folders('skel'), [null, 'ArcherSkeleton']);
      expect(folders('archer skel'), [null, 'ArcherSkeleton']);
      expect(folders('banner'), [null, 'ArcherSkeleton', 'Wolf_pack']);
    });

    test(
      'view state: switching keeps search and filters; it persists',
      () async {
        final tmp = Directory.systemTemp.createTempSync('expanded');
        addTearDown(() => tmp.deleteSync(recursive: true));
        final root = p.join(tmp.path, 'lib');
        writeFiles(root, [
          'Heroes/Knight/idle.png',
          'Heroes/Mage/idle.png',
          'Other/a.png',
        ]);
        final store = SettingsStore(File(p.join(tmp.path, 'settings.json')))
          ..save(AppSettings(libraryPath: root));
        final index = LibraryIndex(NativeDatabase.memory());
        addTearDown(index.close);
        final c = ProviderContainer(
          overrides: [
            settingsStoreProvider.overrideWithValue(store),
            libraryIndexProvider.overrideWithValue(index),
          ],
        );
        addTearDown(c.dispose);
        final sub = c.listen(visibleTilesProvider, (_, _) {});
        Future<List<String>> keys() async {
          await c.read(subFoldersProvider.future);
          await c.read(searchHitsProvider.future);
          return [for (final t in sub.read().requireValue) t.key];
        }

        await c.read(libraryProvider.future);
        expect(await keys(), ['Heroes', 'Other']);

        c.read(dashboardQueryProvider.notifier).setText('mage');
        // Typing is debounced.
        await Future<void>.delayed(DashboardQueryNotifier.searchDebounce * 2);
        c
            .read(settingsProvider.notifier)
            .setDashboardView(DashboardView.expanded);
        expect(await keys(), ['Heroes/Mage']);
        expect(c.read(dashboardQueryProvider).text, 'mage');
        expect(store.load().dashboardView, DashboardView.expanded);

        c.read(dashboardQueryProvider.notifier).setText('');
        expect(await keys(), ['Heroes/Knight', 'Heroes/Mage', 'Other']);

        c.read(settingsProvider.notifier).setDashboardView(DashboardView.packs);
        expect(await keys(), ['Heroes', 'Other']);
      },
    );
  });

  test('dashboard_view round-trips and defaults to packs', () {
    final tmp = Directory.systemTemp.createTempSync('view');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final f = File(p.join(tmp.path, 'settings.json'));
    final store = SettingsStore(f);
    expect(store.load().dashboardView, DashboardView.packs);
    store.save(const AppSettings(dashboardView: DashboardView.expanded));
    expect(f.readAsStringSync(), contains('"dashboard_view": "expanded"'));
    expect(store.load().dashboardView, DashboardView.expanded);
    store.save(const AppSettings(dashboardView: DashboardView.files));
    expect(f.readAsStringSync(), contains('"dashboard_view": "files"'));
    expect(store.load().dashboardView, DashboardView.files);
    f.writeAsStringSync('{"dashboard_view": "bogus"}');
    expect(store.load().dashboardView, DashboardView.packs);
  });

  group('file hits', () {
    final packs = [
      pack('v/village', title: 'Village', types: ['environment']),
      pack('k/kenney', title: 'Tanks', types: ['vfx']),
      pack('o/other', title: 'Other', types: ['ui']),
    ];
    const hits = <FileHit>[
      (packId: 'k/kenney', relPath: 'PNG/barrelRed.png'),
      (packId: 'v/village', relPath: 'props/barrels_1.png'),
      (packId: 'gone/pack', relPath: 'barrel.png'),
      (packId: 'v/village', relPath: 'props/barrels_0.png'),
      (packId: 'k/kenney', relPath: 'PNG/barrelBlue.png'),
    ];
    List<String> names(List<FileTile> l) => [for (final t in l) t.relPath];

    test('best match keeps the index order; unknown packs are dropped', () {
      expect(names(filterFileHits(hits, packs, PackSort.relevance)), [
        'PNG/barrelRed.png',
        'props/barrels_1.png',
        'props/barrels_0.png',
        'PNG/barrelBlue.png',
      ]);
    });

    test('Name sorts by file name; others follow the pack order', () {
      expect(names(filterFileHits(hits, packs, PackSort.title)), [
        'PNG/barrelBlue.png',
        'PNG/barrelRed.png',
        'props/barrels_0.png',
        'props/barrels_1.png',
      ]);
      // The pack list arrives sorted by type: environment before vfx.
      final byType = applyQuery(
        packs,
        const DashboardQuery(text: 'barrel', sort: PackSort.type),
        null,
      );
      expect(names(filterFileHits(hits, byType, PackSort.type)), [
        'props/barrels_0.png',
        'props/barrels_1.png',
        'PNG/barrelBlue.png',
        'PNG/barrelRed.png',
      ]);
    });

    test('pack filters apply through the file\'s pack', () {
      final vfxOnly = applyQuery(
        packs,
        const DashboardQuery(text: 'barrel', types: {'vfx'}),
        null,
      );
      expect(
        filterFileHits(hits, vfxOnly, PackSort.relevance).map((t) => t.pack.id),
        everyElement('k/kenney'),
      );
    });
  });
}
