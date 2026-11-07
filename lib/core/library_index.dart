import 'dart:convert';

import 'package:drift/drift.dart';

import 'animation_detector.dart';
import 'file_search.dart';
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

class SpriteAnimConverter extends TypeConverter<SpriteAnim, String> {
  const SpriteAnimConverter();

  @override
  SpriteAnim fromSql(String fromDb) =>
      SpriteAnim.fromJson(jsonDecode(fromDb) as Map<String, Object?>);

  @override
  String toSql(SpriteAnim value) => jsonEncode(value.toJson());
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

  /// itch.io game this pack came from or was linked to.
  IntColumn get itchGameId => integer().nullable()();
  TextColumn get itchUrl => text().nullable()();

  /// Games this pack is credited in (sidecar `used_in`).
  TextColumn get usedIn => text().map(const StringListConverter())();

  /// Starred pack (sidecar `favorite`).
  BoolColumn get favorite => boolean().withDefault(const Constant(false))();

  /// Starred files, relative to [path] (sidecar `favorite_files`).
  TextColumn get favoriteFiles =>
      text().map(const StringListConverter()).withDefault(const Constant(''))();

  /// Preview image relative to [path].
  TextColumn get preview => text().nullable()();

  /// [SpriteAnim] JSON when the preview is a sprite sheet.
  TextColumn get previewAnim =>
      text().map(const SpriteAnimConverter()).nullable()();
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

/// First-level folders a pack splits into in the dashboard's Expanded view.
@DataClassName('SubFolderRow')
class PackSubFolders extends Table {
  TextColumn get packId => text()();
  TextColumn get folder => text()();

  /// Preview image relative to the folder.
  TextColumn get preview => text().nullable()();
  TextColumn get previewAnim =>
      text().map(const SpriteAnimConverter()).nullable()();
  IntColumn get fileCount => integer()();
  IntColumn get totalBytes => integer()();

  @override
  Set<Column> get primaryKey => {packId, folder};
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
@DriftDatabase(tables: [Packs, PackFiles, PackSubFolders, ScanStates])
class LibraryIndex extends _$LibraryIndex {
  LibraryIndex(super.e);

  @override
  int get schemaVersion => 1;

  static const _ftsDdl =
      "CREATE VIRTUAL TABLE IF NOT EXISTS pack_fts USING fts5("
      "id UNINDEXED, title, author, tags, types, files, "
      "tokenize = 'unicode61 remove_diacritics 2', prefix = '2 3')";

  /// One row per file, for the dashboard's Files view.
  static const _fileFtsDdl =
      "CREATE VIRTUAL TABLE IF NOT EXISTS file_fts USING fts5("
      "pack_id UNINDEXED, rel_path UNINDEXED, words, "
      "tokenize = 'unicode61 remove_diacritics 2', prefix = '2 3')";

  /// The same files with a trigram tokenizer, for infix matches
  /// (`arrel` → `barrels_0.png`) when the prefix search finds nothing.
  static const _fileTriDdl =
      "CREATE VIRTUAL TABLE IF NOT EXISTS file_tri USING fts5("
      "pack_id UNINDEXED, rel_path UNINDEXED, path, tokenize = 'trigram')";

  /// Most file hits [searchFiles] returns.
  static const fileHitLimit = 500;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) async {
      await m.createAll();
      await customStatement(_ftsDdl);
      await customStatement(_fileFtsDdl);
      await customStatement(_fileTriDdl);
    },
    onUpgrade: (m, from, to) async {
      for (final t in allTables) {
        await m.deleteTable(t.actualTableName);
      }
      await customStatement('DROP TABLE IF EXISTS pack_fts');
      await customStatement('DROP TABLE IF EXISTS file_fts');
      await customStatement('DROP TABLE IF EXISTS file_tri');
      await m.createAll();
      await customStatement(_ftsDdl);
      await customStatement(_fileFtsDdl);
      await customStatement(_fileTriDdl);
    },
  );

  Future<ScanState?> scanStateFor(String root) =>
      (select(scanStates)..where((s) => s.root.equals(root))).getSingleOrNull();

  /// Replaces the whole index with [result].
  Future<void> replaceScan(ScanResult result) => transaction(() async {
    await delete(packs).go();
    await delete(packFiles).go();
    await delete(packSubFolders).go();
    await customStatement('DELETE FROM pack_fts');
    await customStatement('DELETE FROM file_fts');
    await customStatement('DELETE FROM file_tri');
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
            usedIn: pk.sidecar?.usedIn ?? const [],
            favorite: Value(pk.sidecar?.favorite ?? false),
            favoriteFiles: Value(pk.sidecar?.favoriteFiles ?? const []),
            itchGameId: Value(pk.sidecar?.itchGameId),
            itchUrl: Value(pk.sidecar?.itchUrl),
            preview: Value(pk.preview),
            previewAnim: Value(pk.previewAnim),
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
        for (final rel in pk.files) {
          b.customStatement(
            'INSERT INTO file_fts (pack_id, rel_path, words) VALUES (?, ?, ?)',
            [pk.id, rel, fileSearchText(rel)],
          );
        }
        b.insertAll(packSubFolders, [
          for (final sf in pk.subFolders)
            PackSubFoldersCompanion.insert(
              packId: pk.id,
              folder: sf.folder,
              preview: Value(sf.preview),
              previewAnim: Value(sf.previewAnim),
              fileCount: sf.fileCount,
              totalBytes: sf.totalBytes,
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
    await customStatement(
      'INSERT INTO file_tri (pack_id, rel_path, path) '
      'SELECT pack_id, rel_path, rel_path FROM file_fts',
    );
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

  /// Stores a pack's stars after a toggle, so the next start (without a
  /// rescan) has them too.
  Future<void> setFavorites(
    String packId, {
    required bool favorite,
    required List<String> files,
  }) => (update(packs)..where((p) => p.id.equals(packId))).write(
    PacksCompanion(favorite: Value(favorite), favoriteFiles: Value(files)),
  );

  Future<List<PackRow>> allPacks() =>
      (select(packs)..orderBy([(p) => OrderingTerm.asc(p.title)])).get();

  /// Expanded-view folders of every pack that splits, by pack id, in
  /// folder order.
  Future<Map<String, List<SubFolderRow>>> allSubFolders() async {
    final rows = await (select(
      packSubFolders,
    )..orderBy([(f) => OrderingTerm.asc(f.folder)])).get();
    final out = <String, List<SubFolderRow>>{};
    for (final r in rows) {
      (out[r.packId] ??= []).add(r);
    }
    return out;
  }

  Future<List<String>> filesOf(String packId) {
    final q = select(packFiles)
      ..where((f) => f.packId.equals(packId))
      ..orderBy([(f) => OrderingTerm.asc(f.relPath)]);
    return q.map((f) => f.relPath).get();
  }

  /// (relative path, size) of every file that belongs to [packId].
  Future<List<(String, int)>> filesWithSizes(String packId) {
    final q = select(packFiles)
      ..where((f) => f.packId.equals(packId))
      ..orderBy([(f) => OrderingTerm.asc(f.relPath)]);
    return q.map((f) => (f.relPath, f.size)).get();
  }

  /// Folder names inside each pack (two levels deep), for spotting itch
  /// games that were merged into a bigger folder.
  Future<Map<String, Set<String>>> folderNames() async {
    final out = <String, Set<String>>{};
    final rows = await (selectOnly(
      packFiles,
    )..addColumns([packFiles.packId, packFiles.relPath])).get();
    for (final r in rows) {
      final String rel = r.read(packFiles.relPath)!;
      final String id = r.read(packFiles.packId)!;
      final parts = rel.split('/');
      if (parts.length < 2) continue;
      (out[id] ??= <String>{}).addAll(
        parts.sublist(0, parts.length - 1).take(2),
      );
    }
    return out;
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

  /// The table and MATCH expression for a file search: prefix words in
  /// `file_fts`, or substrings in `file_tri` when [infix] (every word must
  /// then have 3+ characters, the trigram minimum).
  (String, String)? _fileQuery(String query, {required bool infix}) {
    if (!infix) {
      final fts = ftsQuery(query);
      return fts == null ? null : ('file_fts', fts);
    }
    final words = queryWords(query);
    if (words.isEmpty || words.any((w) => w.length < 3)) return null;
    return ('file_tri', words.map((w) => '"$w"').join(' AND '));
  }

  /// Files whose path words match every word of [query] as a prefix, best
  /// match first, then by path; at most [limit]. When nothing matches that
  /// way, words of 3+ characters are tried as substrings of the path
  /// ([FileSearch.infix]).
  Future<FileSearch> searchFiles(
    String query, {
    int limit = fileHitLimit,
  }) async {
    for (final infix in [false, true]) {
      final q = _fileQuery(query, infix: infix);
      if (q == null) continue;
      final (table, match) = q;
      final rows = await customSelect(
        'SELECT pack_id, rel_path FROM $table WHERE $table MATCH ? '
        'ORDER BY rank, rel_path LIMIT ?',
        variables: [Variable.withString(match), Variable.withInt(limit)],
      ).get();
      if (rows.isEmpty) continue;
      final counts = await customSelect(
        'SELECT pack_id, count(*) AS n FROM $table WHERE $table MATCH ? '
        'GROUP BY pack_id',
        variables: [Variable.withString(match)],
      ).get();
      return FileSearch(
        hits: [
          for (final r in rows)
            (
              packId: r.read<String>('pack_id'),
              relPath: r.read<String>('rel_path'),
            ),
        ],
        counts: {
          for (final r in counts) r.read<String>('pack_id'): r.read<int>('n'),
        },
        infix: infix,
      );
    }
    return const FileSearch(hits: [], counts: {}, infix: false);
  }
}

/// One file found by [LibraryIndex.searchFiles].
typedef FileHit = ({String packId, String relPath});

/// Result of [LibraryIndex.searchFiles].
class FileSearch {
  const FileSearch({
    required this.hits,
    required this.counts,
    required this.infix,
  });

  /// Best match first, capped at [LibraryIndex.fileHitLimit].
  final List<FileHit> hits;

  /// Matching files per pack id, uncapped.
  final Map<String, int> counts;

  /// Found by substring rather than word prefix (see [fileMatches]).
  final bool infix;

  int get total => counts.values.fold(0, (a, b) => a + b);
  bool get capped => total > hits.length;
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
