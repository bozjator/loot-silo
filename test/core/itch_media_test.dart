import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loot_silo/core/itch_media.dart';
import 'package:loot_silo/core/library_index.dart';
import 'package:loot_silo/core/library_scanner.dart';
import 'package:loot_silo/core/pack_editor.dart';
import 'package:loot_silo/core/sidecar.dart';
import 'package:loot_silo/core/type_classifier.dart';
import 'package:path/path.dart' as p;

import 'sub_folders_test.dart' show writeFiles;

/// M92: `_itch` is pack metadata — cover and carousel only.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('itch_media'));
  tearDown(() => tmp.deleteSync(recursive: true));

  const cozy = 'Pizza Doggy/Cozy Tunes + Cozy FX';
  const content = [
    'License.txt',
    'Cozy FX/License Agreement.pdf',
    'Cozy FX/pop.ogg',
    'Cozy FX/click.ogg',
    'Cozy Tunes/Read Me.txt',
    'Cozy Tunes/Audio/ogg/morning.ogg',
    'Cozy Tunes - The Classics/waltz.ogg',
  ];
  const itch = ['_itch/cover.png', '_itch/screenshot_01.png'];

  ScannedPack scanCozy({List<String> extra = const []}) {
    writeFiles(p.join(tmp.path, cozy), [...content, ...itch, ...extra]);
    AuthorInfo(user: 'Pizza Doggy').write(p.join(tmp.path, 'Pizza Doggy'));
    return scanLibrary(tmp.path).packs.single;
  }

  PackContents contentsOf(ScannedPack pk) => loadPackContents(pk.path, [
    for (var i = 0; i < pk.files.length; i++) (pk.files[i], pk.sizes[i]),
  ]);

  test('isItchMedia: the folder and what is under it, nothing else', () {
    expect(isItchMedia('_itch'), isTrue);
    expect(isItchMedia('_itch/cover.png'), isTrue);
    expect(isItchMedia('_itch/a/b.png'), isTrue);
    expect(isItchMedia('_itchy/cover.png'), isFalse);
    expect(isItchMedia('art/_itch/cover.png'), isFalse);
    expect(isItchMedia('cover.png'), isFalse);
  });

  test('the scan keeps _itch for the preview, out of counts and types', () {
    final pk = scanCozy();
    // Stored for the tile and the carousel…
    expect(pk.files, containsAll(itch));
    expect(pk.preview, '_itch/cover.png');
    // …but not counted, typed or tagged by.
    expect(pk.contentFiles, unorderedEquals(content));
    expect(
      pk.totalBytes,
      pk.files.indexed
          .where((e) => !isItchMedia(e.$2))
          .fold(0, (n, e) => n + pk.sizes[e.$1]),
    );
    expect(pk.types, unorderedEquals(['sfx', 'music']));
    expect(pk.tags, isNot(contains('vfx')));
    expect(pk.tags, contains('cozy'));
    expect(pk.subFolders.map((s) => s.folder), isNot(contains('_itch')));
  });

  test('the index counts and searches content only', () async {
    final pk = scanCozy();
    final index = LibraryIndex(NativeDatabase.memory());
    addTearDown(index.close);
    await index.replaceScan(scanLibrary(tmp.path));
    final row = (await index.allPacks()).single;
    expect(row.fileCount, content.length);
    expect(row.totalBytes, pk.totalBytes);
    expect(row.preview, '_itch/cover.png');
    // The file list still holds them (preview, carousel).
    expect(await index.filesOf(row.id), containsAll(itch));
    // Neither the pack search nor the file search finds them.
    expect(await index.search('screenshot_01'), isEmpty);
    expect((await index.searchFiles('screenshot_01')).hits, isEmpty);
    expect((await index.searchFiles('screenshot')).hits, isEmpty);
    expect((await index.searchFiles('waltz')).hits, hasLength(1));
  });

  test('contents: no _itch in any tab; the carousel starts with the cover', () {
    final c = contentsOf(scanCozy());
    expect(c.audio, hasLength(4));
    expect(c.images, isEmpty);
    expect(c.other.where(isItchMedia), isEmpty);
    expect(c.other, hasLength(3));
    expect(c.itchMedia, itch);
    final carousel = c.carousel('_itch/cover.png');
    expect(carousel.first, '_itch/cover.png');
    expect(carousel, contains('_itch/screenshot_01.png'));
    // Folder views (Images, Animations) group these lists only.
    expect(c.within('_itch').isEmpty, isTrue);
  });

  test("the user's previews still lead the carousel", () {
    final pk = scanCozy(extra: ['Cozy FX/x.png']);
    File(p.join(pk.path, packFileName)).writeAsStringSync(
      jsonEncode({
        'previews': ['Cozy FX/x.png', '_itch/screenshot_01.png'],
      }),
    );
    final c = contentsOf(pk);
    expect(c.carousel('_itch/cover.png'), [
      'Cozy FX/x.png',
      '_itch/screenshot_01.png',
    ]);
    // An `_itch` image can still be chosen as a preview.
    expect(c.previewable, containsAll(itch));
    expect(scanLibrary(tmp.path).packs.single.preview, 'Cozy FX/x.png');
  });

  test('a pack with images of its own: the Images tab leaves _itch out', () {
    final pk = scanCozy(extra: ['art/a.png', 'art/b.png']);
    final c = contentsOf(pk);
    expect(c.images, ['art/a.png', 'art/b.png']);
    expect(pk.contentFiles, hasLength(content.length + 2));
  });

  test('suggestTags drops vfx for audio-only packs', () {
    expect(suggestTags(cozy), contains('vfx'));
    expect(suggestTags(cozy, types: ['sfx', 'music']), isNot(contains('vfx')));
    expect(suggestTags(cozy, types: ['music']), isNot(contains('vfx')));
    // A pack with pictures keeps it.
    expect(suggestTags(cozy, types: ['sfx', 'vfx']), contains('vfx'));
  });
}
