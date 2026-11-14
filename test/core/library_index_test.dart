import 'package:loot_silo/core/file_search.dart';
import 'package:loot_silo/core/library_index.dart';
import 'package:loot_silo/core/library_scanner.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late LibraryIndex index;
  final scan = scanLibrary('test/fixtures/library_src');

  setUp(() async {
    index = LibraryIndex(NativeDatabase.memory());
    await index.replaceScan(scan);
  });
  tearDown(() => index.close());

  test('stores every pack with its files and scan state', () async {
    final packs = await index.allPacks();
    expect(packs, hasLength(scan.packs.length));
    final knight = packs.firstWhere((p) => p.title == 'Knight Pack v1.0');
    expect(knight.author, 'HeroMaker');
    expect(knight.authorUrl, 'https://heromaker.itch.io/');
    expect(knight.types, ['character']);
    expect(knight.fileCount, 4);
    expect(knight.preview, 'Knight/Knight-sheet(32x32).png');
    expect(await index.filesOf(knight.id), contains('Knight/idle_0.png'));
    expect(
      (await index.scanStateFor(scan.root))!.fingerprint,
      scan.fingerprint,
    );
  });

  test('stores favorites and updates them without a rescan (M38)', () async {
    final knight = (await index.allPacks()).firstWhere(
      (p) => p.title == 'Knight Pack v1.0',
    );
    expect(knight.favorite, isFalse);
    expect(knight.favoriteFiles, isEmpty);
    await index.setFavorites(
      knight.id,
      favorite: true,
      files: ['Knight/idle_0.png'],
    );
    final after = (await index.allPacks()).firstWhere((p) => p.id == knight.id);
    expect(after.favorite, isTrue);
    expect(after.favoriteFiles, ['Knight/idle_0.png']);
  });

  test('replacing a scan does not duplicate rows', () async {
    await index.replaceScan(scan);
    expect(await index.allPacks(), hasLength(scan.packs.length));
    expect(await index.search('knight'), hasLength(1));
  });

  test('searches titles, authors, tags, types and file names', () async {
    expect(await index.search('forest'), [
      'art/environments/Forest Tiles 16x16',
    ]);
    expect(await index.search('bigco'), ['bundles/Mega Bundle v3']);
    expect(await index.search('pixel-art'), isEmpty);
    expect(
      await index.search('sfx'),
      containsAll(['sfx/Loose Sounds', 'bundles/Mega Bundle v3']),
    );
    expect(await index.search('barrel'), [
      'bundles/Mega Bundle v3',
    ], reason: 'camelCase file names are split');
  });

  test('words are prefix matched and all required', () async {
    expect(await index.search('kni'), [
      'art/characters/HeroMaker/Knight Pack v1.0',
    ]);
    expect(await index.search('knight slime'), isEmpty);
    expect(await index.search('hero sli'), [
      'art/characters/HeroMaker/Free Slime Pack',
    ]);
  });

  test('title matches rank above file-name matches', () async {
    final ids = await index.search('slime');
    expect(ids.first, 'art/characters/HeroMaker/Free Slime Pack');
  });

  test('ftsQuery escapes syntax', () async {
    expect(ftsQuery('  '), isNull);
    expect(ftsQuery('a "b" OR c*'), '"a"* AND "b"* AND "OR"* AND "c"*');
    expect(await index.search('"knight" (*'), hasLength(1));
  });

  group('searchFiles', () {
    List<String> paths(FileSearch r) => [for (final h in r.hits) h.relPath];

    test('prefix words, camelCase split, with the owning pack', () async {
      final r = await index.searchFiles('barr');
      expect(r.hits, [
        (
          packId: 'bundles/Mega Bundle v3',
          relPath: '2D assets/Tanks Pack/PNG/tankBarrel.png',
        ),
      ]);
      expect(r.infix, isFalse);
      expect(r.counts, {'bundles/Mega Bundle v3': 1});
      expect(paths(await index.searchFiles('idle')), [
        'Knight/idle_0.png',
        'Knight/idle_1.png',
      ]);
    });

    test('every word must match the same file (AND)', () async {
      expect(paths(await index.searchFiles('read water')), [
        'Tilesets/Water/Read me.txt',
      ]);
      expect(paths(await index.searchFiles('idle tank')), isEmpty);
    });

    test('caps hits but counts all of them', () async {
      final r = await index.searchFiles('click', limit: 2);
      expect(r.hits, hasLength(2));
      expect(r.total, 3);
      expect(r.capped, isTrue);
      expect((await index.searchFiles('click')).capped, isFalse);
    });

    test('falls back to substrings for 3+ letter words', () async {
      final r = await index.searchFiles('arrel');
      expect(paths(r), ['2D assets/Tanks Pack/PNG/tankBarrel.png']);
      expect(r.infix, isTrue);
      // Too short for trigrams, and no prefix match: nothing.
      expect((await index.searchFiles('rr')).hits, isEmpty);
      expect((await index.searchFiles('')).hits, isEmpty);
    });

    test('fileMatches agrees with the index', () async {
      final files = [for (final p in scan.packs) ...p.files];
      for (final q in ['barr', 'idle', 'read water', 'kn', 'arrel']) {
        final r = await index.searchFiles(q);
        final words = queryWords(q);
        expect(
          files.where((f) => fileMatches(f, words, infix: r.infix)).toSet(),
          paths(r).toSet(),
          reason: q,
        );
      }
    });
  });
}
