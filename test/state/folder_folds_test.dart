import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:loot_silo/state/folder_folds.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tmp;
  late File file;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('folds_');
    file = File(p.join(tmp.path, 'ui_state.json'));
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  test('remembers collapsed folders per pack and tab across loads', () {
    FolderFolds(file)
      ..set('/lib/A', FoldTab.images, {'b', 'a'})
      ..set('/lib/A', FoldTab.animations, {'run'})
      ..set('/lib/B', FoldTab.images, {'x'});
    final again = FolderFolds(file);
    expect(again.of('/lib/A', FoldTab.images), {'a', 'b'});
    expect(again.of('/lib/A', FoldTab.animations), {'run'});
    expect(again.of('/lib/B', FoldTab.images), {'x'});
    expect(again.of('/lib/B', FoldTab.animations), isEmpty);
    expect(again.of('/lib/C', FoldTab.images), isEmpty);
  });

  test('of() hands out a copy', () {
    final folds = FolderFolds()..set('/lib/A', FoldTab.images, {'a'});
    folds.of('/lib/A', FoldTab.images).add('b');
    expect(folds.of('/lib/A', FoldTab.images), {'a'});
  });

  test('an empty set (Expand all) removes the entry', () {
    FolderFolds(file)
      ..set('/lib/A', FoldTab.images, {'a'})
      ..set('/lib/A', FoldTab.animations, {'run'})
      ..set('/lib/A', FoldTab.images, {});
    var json = jsonDecode(file.readAsStringSync()) as Map;
    expect(json['collapsed_folders'], {
      '/lib/A': {
        'animations': ['run'],
      },
    });
    FolderFolds(file).set('/lib/A', FoldTab.animations, {});
    json = jsonDecode(file.readAsStringSync()) as Map;
    expect(json['collapsed_folders'], isEmpty);
  });

  test('an unchanged set writes nothing', () {
    final folds = FolderFolds(file)..set('/lib/A', FoldTab.images, {});
    expect(file.existsSync(), isFalse);
    folds.set('/lib/A', FoldTab.images, {'a'});
    file.deleteSync();
    folds.set('/lib/A', FoldTab.images, {'a'});
    expect(file.existsSync(), isFalse);
  });

  test('prune drops gone packs of that library only', () {
    final root = p.join(tmp.path, 'lib');
    final kept = p.join(root, 'Kept');
    final gone = p.join(root, 'Gone');
    final other = p.join(tmp.path, 'other', 'Pack');
    FolderFolds(file)
      ..set(kept, FoldTab.images, {'a'})
      ..set(gone, FoldTab.images, {'a'})
      ..set(other, FoldTab.images, {'a'})
      ..prune(root, [kept]);
    final again = FolderFolds(file);
    expect(again.of(kept, FoldTab.images), {'a'});
    expect(again.of(gone, FoldTab.images), isEmpty);
    expect(again.of(other, FoldTab.images), {'a'});
  });

  test('a missing or corrupt file starts empty', () {
    expect(FolderFolds(file).of('/lib/A', FoldTab.images), isEmpty);
    file.writeAsStringSync('{not json');
    expect(FolderFolds(file).of('/lib/A', FoldTab.images), isEmpty);
    file.writeAsStringSync('{"collapsed_folders": {"/lib/A": {"x": ["a"]}}}');
    expect(FolderFolds(file).of('/lib/A', FoldTab.images), isEmpty);
  });
}
