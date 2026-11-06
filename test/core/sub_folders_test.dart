import 'dart:io';

import 'package:assets_explorer/core/fs_tree.dart';
import 'package:assets_explorer/core/library_index.dart';
import 'package:assets_explorer/core/library_scanner.dart';
import 'package:assets_explorer/core/sub_folders.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

/// Writes [rels] under [root] as tiny PNGs (or empty files).
void writeFiles(String root, List<String> rels) {
  final png = img.encodePng(img.Image(width: 4, height: 4));
  for (final rel in rels) {
    final f = File(p.join(root, rel))..parent.createSync(recursive: true);
    rel.endsWith('.png') ? f.writeAsBytesSync(png) : f.writeAsStringSync('x');
  }
}

List<(String, FileEntry)> entries(List<String> rels) => [
  for (final r in rels) (r, FileEntry(p.basename(r), 10)),
];

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('subfolders'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('splits a collection by first-level folder', () {
    final rels = [
      'Wolf/Wolf-Idle.png',
      'Wolf/Wolf-Run.png',
      'ArcherSkeleton/Idle.png',
      'ArcherSkeleton/notes.txt',
      'readme.txt',
    ];
    writeFiles(tmp.path, rels);
    final subs = splitSubFolders(tmp.path, entries(rels));
    expect([for (final s in subs) s.folder], ['ArcherSkeleton', 'Wolf']);
    final archer = subs.first;
    expect(archer.preview, 'Idle.png', reason: 'relative to the folder');
    expect(archer.fileCount, 2);
    expect(archer.totalBytes, 20);
  });

  test('format, preview and engine folders never split a pack', () {
    final cases = [
      ['PNG/a.png', 'Spritesheets/b.png'],
      ['32x32/a.png', '16x16/b.png'],
      ['Knight/a.png', 'Previews/b.png', '_itch/c.png'],
      ['Godot/a.png', 'RPG Maker/b.png'],
      ['Knight/a.png', 'Sounds/b.wav'],
      ['a.png', 'b.png'],
    ];
    for (final rels in cases) {
      expect(
        splitSubFolders(tmp.path, entries(rels)),
        isEmpty,
        reason: '$rels',
      );
    }
  });

  test(
    'the scanner splits non-container packs and the index stores it',
    () async {
      final root = p.join(tmp.path, 'lib');
      writeFiles(root, [
        'Heroes/Knight/idle.png',
        'Heroes/Mage/idle.png',
        'Heroes/Mage/cast.png',
        'Single/a.png',
        'Single/b.png',
      ]);
      final scan = scanLibrary(root);
      final heroes = scan.packs.firstWhere((x) => x.id == 'Heroes');
      expect([for (final s in heroes.subFolders) s.folder], ['Knight', 'Mage']);
      expect(
        scan.packs.firstWhere((x) => x.id.startsWith('Single')).subFolders,
        isEmpty,
      );

      final index = LibraryIndex(NativeDatabase.memory());
      addTearDown(index.close);
      expect(index.schemaVersion, 9);
      await index.replaceScan(scan);
      await index.replaceScan(scan);
      final stored = await index.allSubFolders();
      expect(stored.keys, ['Heroes']);
      expect([for (final r in stored['Heroes']!) r.folder], ['Knight', 'Mage']);
      expect(stored['Heroes']![1].fileCount, 2);
      expect(stored['Heroes']![0].preview, 'idle.png');
    },
  );
}
