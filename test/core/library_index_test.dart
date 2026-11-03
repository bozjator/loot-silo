import 'package:assets_explorer/core/library_index.dart';
import 'package:assets_explorer/core/library_scanner.dart';
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

  test('replacing a scan does not duplicate rows', () async {
    await index.replaceScan(scan);
    expect(await index.allPacks(), hasLength(scan.packs.length));
    expect(await index.search('knight'), hasLength(1));
  });

  test('searches titles, authors, tags, types and file names', () async {
    expect(await index.search('forest'), [
      'art/environments/Forest Tiles 16x16',
    ]);
    expect(await index.search('bigco'), hasLength(4));
    expect(await index.search('pixel-art'), isEmpty);
    expect(
      await index.search('sfx'),
      containsAll([
        'sfx/Loose Sounds',
        'bundles/Mega Bundle v3/Audio/Clicks (3 sounds)',
      ]),
    );
    expect(await index.search('barrel'), [
      'bundles/Mega Bundle v3/2D assets/Tanks Pack',
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
}
