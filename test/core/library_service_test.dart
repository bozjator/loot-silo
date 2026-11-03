import 'dart:io';

import 'package:assets_explorer/core/library_index.dart';
import 'package:assets_explorer/core/library_service.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../helpers/fs.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late Directory tmp;
  late LibraryService service;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('lib');
    copyTree('test/fixtures/managed', tmp.path);
    service = LibraryService(LibraryIndex(NativeDatabase.memory()));
  });
  tearDown(() async {
    await service.index.close();
    tmp.deleteSync(recursive: true);
  });

  test('cold load scans, warm load reuses the index', () async {
    final cold = await service.load(tmp.path);
    expect(cold.scanned, isTrue);
    expect(cold.packs, hasLength(2));

    final warm = await service.load(tmp.path);
    expect(warm.scanned, isFalse);
    expect(warm.packs.map((p) => p.id), cold.packs.map((p) => p.id));
  });

  test('a new pack folder triggers a rescan', () async {
    await service.load(tmp.path);
    final dir = Directory(p.join(tmp.path, 'HeroMaker', 'Bats'))..createSync();
    File(p.join(dir.path, 'bat.png')).writeAsBytesSync([0]);
    File(p.join(dir.path, 'License.txt')).writeAsStringSync('CC0');

    final again = await service.load(tmp.path);
    expect(again.scanned, isTrue);
    expect(again.packs.map((p) => p.id), contains('HeroMaker/Bats'));
  });

  test('force rescans even when nothing changed', () async {
    await service.load(tmp.path);
    expect((await service.load(tmp.path, force: true)).scanned, isTrue);
  });
}
