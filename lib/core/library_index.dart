import 'package:drift/drift.dart';

import 'library_scanner.dart';
import 'type_classifier.dart';

part 'library_index.g.dart';

/// Lists are stored as `\n`-joined text; tags and types never contain one.
class StringListConverter extends TypeConverter<List<String>, String> {
  const StringListConverter();

  @override
  List<String> fromSql(String fromDb) =>
      fromDb.isEmpty ? const [] : fromDb.split('\n');

  @override
  String toSql(List<String> value) => value.join('\n');
}

@DataClassName('PackRow')
class Packs extends Table {
  TextColumn get id => text()();
  TextColumn get path => text()();
  TextColumn get title => text()();
  TextColumn get author => text().nullable()();
  TextColumn get authorUrl => text().nullable()();
  TextColumn get parentId => text().nullable()();
  BoolColumn get isContainer => boolean()();
  TextColumn get types => text().map(const StringListConverter())();
  TextColumn get tags => text().map(const StringListConverter())();
  TextColumn get source => text().nullable()();

  /// Preview image relative to [path].
  TextColumn get preview => text().nullable()();
  IntColumn get fileCount => integer()();
  IntColumn get totalBytes => integer()();

  @override
  Set<Column> get primaryKey => {id};
}

class PackFiles extends Table {
  TextColumn get packId => text()();
  TextColumn get relPath => text()();
  IntColumn get size => integer()();

  @override
  Set<Column> get primaryKey => {packId, relPath};
}

class ScanStates extends Table {
  TextColumn get root => text()();
  TextColumn get fingerprint => text()();
  DateTimeColumn get scannedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {root};
}

/// The disposable scan index: packs, their files and an FTS5 table over
/// titles, authors, tags, types and file names.
///
/// It can always be rebuilt from the library folder, so schema changes
/// simply drop and recreate everything.
@DriftDatabase(tables: [Packs, PackFiles, ScanStates])
class LibraryIndex extends _$LibraryIndex {
  LibraryIndex(super.e);

  @override
  int get schemaVersion => 2;

  static const _ftsDdl =
      "CREATE VIRTUAL TABLE IF NOT EXISTS pack_fts USING fts5("
      "id UNINDEXED, title, author, tags, types, files, "
      "tokenize = 'unicode61 remove_diacritics 2', prefix = '2 3')";

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) async {
      await m.createAll();
      await customStatement(_ftsDdl);
    },
    onUpgrade: (m, from, to) async {
      for (final t in allTables) {
        await m.deleteTable(t.actualTableName);
      }
      await customStatement('DROP TABLE IF EXISTS pack_fts');
      await m.createAll();
      await customStatement(_ftsDdl);
    },
  );

  Future<ScanState?> scanStateFor(String root) =>
      (select(scanStates)..where((s) => s.root.equals(root))).getSingleOrNull();

  /// Replaces the whole index with [result].
  Future<void> replaceScan(ScanResult result) => transaction(() async {
    await delete(packs).go();
    await delete(packFiles).go();
    await customStatement('DELETE FROM pack_fts');
    await batch((b) {
      for (final pk in result.packs) {
        b.insert(
          packs,
          PacksCompanion.insert(
            id: pk.id,
            path: pk.path,
            title: pk.title,
            author: Value(pk.author?.user),
            authorUrl: Value(pk.author?.url),
            parentId: Value(pk.parentId),
            isContainer: pk.isContainer,
            types: pk.types,
            tags: pk.tags,
            source: Value(pk.source?.name),
            preview: Value(pk.preview),
            fileCount: pk.files.length,
            totalBytes: pk.totalBytes,
          ),
        );
        b.insertAll(packFiles, [
          for (var i = 0; i < pk.files.length; i++)
            PackFilesCompanion.insert(
              packId: pk.id,
              relPath: pk.files[i],
              size: pk.sizes[i],
            ),
        ]);
      }
    });
    for (final pk in result.packs) {
      await customStatement(
        'INSERT INTO pack_fts (id, title, author, tags, types, files) '
        'VALUES (?, ?, ?, ?, ?, ?)',
        [
          pk.id,
          pk.title,
          pk.author?.user ?? '',
          pk.tags.join(' '),
          pk.types.join(' '),
          _fileText(pk.files),
        ],
      );
    }
    await into(scanStates).insertOnConflictUpdate(
      ScanStatesCompanion.insert(
        root: result.root,
        fingerprint: result.fingerprint,
        scannedAt: DateTime.now(),
      ),
    );
  });

  /// File paths plus their camelCase-split words, so `HumanSoldier.png`
  /// matches "soldier".
  static String _fileText(List<String> files) {
    final words = <String>{};
    for (final f in files) {
      words.add(f);
      words.addAll(pathWords(f));
    }
    return words.join(' ');
  }

  Future<List<PackRow>> allPacks() =>
      (select(packs)..orderBy([(p) => OrderingTerm.asc(p.title)])).get();

  Future<List<String>> filesOf(String packId) {
    final q = select(packFiles)
      ..where((f) => f.packId.equals(packId))
      ..orderBy([(f) => OrderingTerm.asc(f.relPath)]);
    return q.map((f) => f.relPath).get();
  }

  /// Pack ids matching [query], best match first. Every word must match
  /// as a prefix in any column.
  Future<List<String>> search(String query) async {
    final fts = ftsQuery(query);
    if (fts == null) return const [];
    final rows = await customSelect(
      'SELECT id FROM pack_fts WHERE pack_fts MATCH ? '
      'ORDER BY bm25(pack_fts, 0, 10, 5, 5, 3, 1)',
      variables: [Variable.withString(fts)],
    ).get();
    return [for (final r in rows) r.read<String>('id')];
  }
}

/// Turns free text into a safe FTS5 query: each word quoted and
/// prefix-matched, all words required.
String? ftsQuery(String input) {
  final words = input
      .split(RegExp(r'[^\p{L}\p{N}]+', unicode: true))
      .where((w) => w.isNotEmpty)
      .map((w) => '"${w.replaceAll('"', '')}"*');
  return words.isEmpty ? null : words.join(' AND ');
}
