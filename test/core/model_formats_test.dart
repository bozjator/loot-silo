import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:loot_silo/core/model_formats.dart';
import 'package:loot_silo/core/pack_editor.dart';
import 'package:loot_silo/state/settings.dart';
import 'package:path/path.dart' as p;

import '../helpers/models.dart';

void main() {
  test('the Kenney layout: one model per name across format folders', () {
    final models = groupModelFormats([
      'Models/DAE format/tree.dae',
      'Models/FBX format/tree.fbx',
      'Models/GLTF format/tree.glb',
      'Models/OBJ format/tree.obj',
      'Models/STL format/tree.stl',
      'Models/GLTF format/Rock_Large.gltf',
      'Models/OBJ format/rock_large.obj',
      'Models/FBX format/fence.fbx',
    ]);
    expect(
      [for (final m in models) m.files],
      [
        [
          'Models/GLTF format/tree.glb',
          'Models/OBJ format/tree.obj',
          'Models/FBX format/tree.fbx',
          'Models/DAE format/tree.dae',
          'Models/STL format/tree.stl',
        ],
        [
          'Models/GLTF format/Rock_Large.gltf',
          'Models/OBJ format/rock_large.obj',
        ],
        ['Models/FBX format/fence.fbx'],
      ],
    );
    final tree = models.first;
    expect(tree.folder, 'Models');
    expect(tree.groupPath, 'Models/tree.glb');
    expect(tree.readable, [
      'Models/GLTF format/tree.glb',
      'Models/OBJ format/tree.obj',
    ]);
    expect(tree.shown, 'Models/GLTF format/tree.glb');
    expect(models.last.shown, isNull);
  });

  test('side by side, lower-case format folders, and two of one format', () {
    final models = groupModelFormats([
      'ship.obj',
      'ship.glb',
      'glb/boat.glb',
      'obj/boat.obj',
      'a.obj',
      'A.OBJ',
    ]);
    expect(
      [for (final m in models) m.files],
      [
        ['ship.glb', 'ship.obj'],
        ['glb/boat.glb', 'obj/boat.obj'],
        ['a.obj'],
        ['A.OBJ'],
      ],
    );
    expect(models[1].folder, '.');
    expect(models[1].groupPath, 'boat.glb');
  });

  group('loadPackContents', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('model-contents'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('models split out; unreadable-only models stay other files', () {
      writeCubeGlb(p.join(tmp.path, 'Models/GLTF format'), 'tree');
      final files = [
        ('Models/GLTF format/tree.glb', 1),
        ('Models/OBJ format/tree.obj', 1),
        ('Models/OBJ format/tree.mtl', 1),
        ('Models/FBX format/tree.fbx', 1),
        ('Models/STL format/tree.stl', 1),
        ('Models/FBX format/fence.fbx', 1),
        ('Models/GLTF format/fence.bin', 1),
        ('Preview.png', 1),
      ];
      final c = loadPackContents(tmp.path, files);
      expect(c.models, [
        'Models/FBX format/tree.fbx',
        'Models/GLTF format/tree.glb',
        'Models/OBJ format/tree.obj',
        'Models/STL format/tree.stl',
      ]);
      expect(c.other, [
        'Models/FBX format/fence.fbx',
        'Models/GLTF format/fence.bin',
        'Models/OBJ format/tree.mtl',
      ]);
      expect(c.images, ['Preview.png']);
      expect(c.matching(['tree']).models, hasLength(4));
      expect(c.matching(['fence']).models, isEmpty);
      expect(c.within('Models/OBJ format').models, [
        'Models/OBJ format/tree.obj',
      ]);
      expect(c.only({'Models/GLTF format/tree.glb'}).models, [
        'Models/GLTF format/tree.glb',
      ]);
      expect(c.only({}).isEmpty, isTrue);
    });
  });

  test('models_view and model_thumb_size round-trip; defaults', () {
    const fresh = AppSettings();
    expect(fresh.modelsView, ItemsView.flat);
    expect(fresh.modelThumbSize, 200);
    final json = fresh
        .copyWith(modelsView: ItemsView.folders, modelThumbSize: 320)
        .toJson();
    expect(json['models_view'], 'folders');
    expect(json['model_thumb_size'], 320);
    final back = AppSettings.fromJson(json);
    expect(back.modelsView, ItemsView.folders);
    expect(back.modelThumbSize, 320);
    expect(AppSettings.fromJson(const {}).modelsView, ItemsView.flat);
  });
}
