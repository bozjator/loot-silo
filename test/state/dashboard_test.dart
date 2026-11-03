import 'package:assets_explorer/core/library_index.dart';
import 'package:assets_explorer/state/dashboard.dart';
import 'package:flutter_test/flutter_test.dart';

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

  test('copyWith can clear the bundle', () {
    const q = DashboardQuery(bundleId: 'x');
    expect(q.copyWith(bundleId: () => null).bundleId, isNull);
    expect(q.copyWith(text: 'a').bundleId, 'x');
  });
}
