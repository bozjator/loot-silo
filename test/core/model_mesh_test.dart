import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:loot_silo/core/model_cache.dart';
import 'package:loot_silo/core/model_mesh.dart';
import 'package:path/path.dart' as p;

import '../helpers/models.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('models'));
  tearDown(() => tmp.deleteSync(recursive: true));

  void expectCube(ModelMesh m, {double scale = 1, double dx = 0}) {
    expect(m.triangleCount, 12);
    expect(m.bounds[0], closeTo(-scale + dx, 1e-6));
    expect(m.bounds[3], closeTo(scale + dx, 1e-6));
    expect(m.bounds[1], closeTo(-scale, 1e-6));
    expect(m.bounds[4], closeTo(scale, 1e-6));
    // Normals filled in (the fixtures have none) and of unit length.
    for (var v = 0; v < m.vertexCount; v++) {
      final x = m.normals[v * 3], y = m.normals[v * 3 + 1];
      final z = m.normals[v * 3 + 2];
      expect(x * x + y * y + z * z, closeTo(1, 1e-5));
    }
  }

  group('readGltf', () {
    test('GLB: BIN chunk, two primitives with their materials', () {
      final m = readModel(writeCubeGlb(tmp.path, 'cube').path);
      expectCube(m);
      expect(m.materials.map((x) => x.color), [0xFFE68C59, 0xFF59B34D]);
      expect(m.materials.map((x) => x.name), ['side', 'top']);
      expect(m.materials.first.file, isNull);
      // Ten side triangles, then the two of the top face.
      expect(m.triangleMaterials.where((t) => t == 1).length, 2);
      expect(m.textures, isEmpty);
    });

    test('glTF with a .bin file beside it', () {
      final (json, bin) = cubeGltf(buffer: {'uri': 'cube%20data.bin'});
      File(p.join(tmp.path, 'cube data.bin')).writeAsBytesSync(bin);
      final f = File(p.join(tmp.path, 'cube.gltf'))
        ..writeAsStringSync(jsonEncode(json));
      expectCube(readGltf(f.path));
    });

    test('glTF with a data: URI buffer', () {
      final (_, bin) = cubeGltf();
      final (json, _) = cubeGltf(
        buffer: {
          'uri': 'data:application/octet-stream;base64,${base64Encode(bin)}',
        },
      );
      final f = File(p.join(tmp.path, 'cube.gltf'))
        ..writeAsStringSync(jsonEncode(json));
      expectCube(readGltf(f.path));
    });

    test('node transforms: TRS and matrix', () {
      final trs = writeCubeGlb(
        tmp.path,
        'trs',
        node: {
          'translation': [3, 0, 0],
          'scale': [2, 2, 2],
        },
      );
      expectCube(readModel(trs.path), scale: 2, dx: 3);
      final matrix = writeCubeGlb(
        tmp.path,
        'matrix',
        node: {
          'matrix': [2, 0, 0, 0, 0, 2, 0, 0, 0, 0, 2, 0, 3, 0, 0, 1],
        },
      );
      expectCube(readModel(matrix.path), scale: 2, dx: 3);
    });

    test('a mirroring transform flips the winding back', () {
      final normal = readModel(writeCubeGlb(tmp.path, 'a').path);
      final mirrored = readModel(
        writeCubeGlb(
          tmp.path,
          'b',
          node: {
            'scale': [-1, 1, 1],
          },
        ).path,
      );
      expect(mirrored.indices[1], normal.indices[2]);
      expect(mirrored.indices[2], normal.indices[1]);
    });

    test('baseColorTexture: an external file and an embedded image', () {
      final (json, bin) = cubeGltf();
      json['materials'] = [
        {
          'pbrMetallicRoughness': {
            'baseColorTexture': {'index': 0},
          },
        },
        {
          'pbrMetallicRoughness': {
            'baseColorTexture': {'index': 1},
          },
        },
      ];
      json['textures'] = [
        {'source': 0, 'sampler': 0},
        {'source': 1},
      ];
      json['samplers'] = [
        {'magFilter': 9728},
      ];
      json['images'] = [
        {'uri': 'Textures/colormap.png'},
        {
          'uri': 'data:image/png;base64,${base64Encode([1, 2, 3])}',
        },
      ];
      final f = File(p.join(tmp.path, 'tex.glb'))
        ..writeAsBytesSync(glbBytes(json, bin));
      final m = readGltf(f.path);
      expect(m.materials[0].texture, p.join(tmp.path, 'Textures/colormap.png'));
      expect(m.materials[0].nearest, isTrue);
      expect(m.images[m.materials[1].texture], [1, 2, 3]);
    });

    test('non-triangle primitives are skipped', () {
      final (json, bin) = cubeGltf();
      final prims =
          ((json['meshes']! as List).first as Map)['primitives'] as List;
      (prims[1] as Map)['mode'] = 1; // lines
      final f = File(p.join(tmp.path, 'lines.glb'))
        ..writeAsBytesSync(glbBytes(json, bin));
      expect(readGltf(f.path).triangleCount, 10);
    });

    test('bad files throw ModelReadError with a reason', () {
      final junk = File(p.join(tmp.path, 'junk.glb'))
        ..writeAsBytesSync([1, 2, 3, 4, 5]);
      expect(() => readModel(junk.path), throwsA(isA<ModelReadError>()));

      final good = writeCubeGlb(tmp.path, 'cut').readAsBytesSync();
      final cut = File(p.join(tmp.path, 'cut.glb'))
        ..writeAsBytesSync(good.sublist(0, good.length - 40));
      expect(() => readModel(cut.path), throwsA(isA<ModelReadError>()));

      final (json, _) = cubeGltf(buffer: {'uri': 'missing.bin'});
      final noBin = File(p.join(tmp.path, 'nobin.gltf'))
        ..writeAsStringSync(jsonEncode(json));
      expect(
        () => readModel(noBin.path),
        throwsA(
          isA<ModelReadError>().having(
            (e) => e.reason,
            'reason',
            contains('missing.bin'),
          ),
        ),
      );

      final (bad, bin) = cubeGltf();
      ((bad['accessors']! as List)[0] as Map)['count'] = 4; // indices go to 7
      final range = File(p.join(tmp.path, 'range.glb'))
        ..writeAsBytesSync(glbBytes(bad, bin));
      expect(() => readModel(range.path), throwsA(isA<ModelReadError>()));

      expect(
        () => readModel(p.join(tmp.path, 'a.fbx')),
        throwsA(isA<ModelReadError>()),
      );
    });
  });

  group('readObj', () {
    test('quads, negative indices, usemtl + mtllib colours', () {
      final m = readModel(writeCubeObj(tmp.path, 'cube').path);
      expectCube(m);
      expect(m.usedMaterials.map((x) => x.name), ['side', 'top']);
      expect(m.materials.first.file, p.join(tmp.path, 'cube.mtl'));
      expect(m.materials.map((x) => x.color), [0xFFE68C59, 0xFF59B34D]);
      expect(m.triangleMaterials.where((t) => t == 1).length, 2);
    });

    test('n-gons fan, vt flips, map_Kd relative to the MTL', () {
      Directory(p.join(tmp.path, 'mat')).createSync();
      File(p.join(tmp.path, 'mat', 'm.mtl')).writeAsStringSync(
        'newmtl skin\nKd 1 1 1\nmap_Kd -s 1 1 1 tex/skin.png\n',
      );
      final f = File(p.join(tmp.path, 'hex.obj'))
        ..writeAsStringSync('''
mtllib mat/m.mtl
v 1 0 0
v 0.5 0.87 0
v -0.5 0.87 0
v -1 0 0
v -0.5 -0.87 0
v 0.5 -0.87 0
vt 0 0
vt 1 1
vn 0 0 1
usemtl skin
f 1/1/1 2/2/1 3/1/1 4/2/1 5/1/1 6/2/1
''');
      final m = readObj(f.path);
      expect(m.triangleCount, 4);
      expect(m.materials.single.texture, p.join(tmp.path, 'mat/tex/skin.png'));
      expect(m.uvs![1], 1); // v 0 → 1
      expect(m.uvs![3], 0); // v 1 → 0
      expect(m.normals.sublist(0, 3), [0, 0, 1]);
    });

    test('a missing MTL draws plain; bad indices throw', () {
      final f = File(p.join(tmp.path, 'tri.obj'))
        ..writeAsStringSync(
          'mtllib nope.mtl\nv 0 0 0\nv 1 0 0\nv 0 1 0\n'
          'usemtl x\nf 1 2 3\n',
        );
      final plain = readObj(f.path).materials.single;
      expect(plain.color, 0xFFC8C8C8);
      expect(plain.name, 'x');
      f.writeAsStringSync('v 0 0 0\nf 1 2 9\n');
      expect(() => readObj(f.path), throwsA(isA<ModelReadError>()));
      f.writeAsStringSync('# nothing\n');
      expect(() => readObj(f.path), throwsA(isA<ModelReadError>()));
    });
  });

  group('ModelCache', () {
    test('reads once per modification time; keeps failures; evicts', () async {
      var reads = 0;
      final cache = ModelCache(
        capacity: 2,
        read: (path) async {
          reads++;
          return readModelForPreview(path);
        },
      );
      final a = writeCubeGlb(tmp.path, 'a').path;
      final b = writeCubeObj(tmp.path, 'b').path;
      final c = writeCubeGlb(tmp.path, 'c').path;
      expect(cache.peek(a), isNull);
      await cache.load(a);
      await cache.load(a);
      expect(reads, 1);
      expect(cache.peek(a), isA<ModelMesh>());

      final bad = File(p.join(tmp.path, 'bad.glb'))..writeAsStringSync('x');
      await expectLater(cache.load(bad.path), throwsA(isA<ModelReadError>()));
      await expectLater(cache.load(bad.path), throwsA(isA<ModelReadError>()));
      expect(reads, 2);
      expect(cache.peek(bad.path), isA<ModelReadError>());

      await cache.load(b);
      await cache.load(c);
      expect(cache.length, 2);
      expect(cache.peek(a), isNull);
      await expectLater(
        cache.load(p.join(tmp.path, 'gone.glb')),
        throwsA(isA<ModelReadError>()),
      );
    });

    test('the default reader runs in an isolate', () async {
      final mesh = await ModelCache().load(writeCubeGlb(tmp.path, 'iso').path);
      expect(mesh.triangleCount, 12);
    });
  });

  const kit =
      '../assets_library/Kenney/Kenney Game Assets 1 version 42/3D assets/'
      'Fantasy Town Kit';
  test(
    'every GLB / glTF / OBJ of a real Kenney kit reads (read-only)',
    skip: Directory(kit).existsSync() ? false : 'no $kit',
    () {
      final failures = <String>[];
      var read = 0, largest = 0;
      for (final f in Directory(kit).listSync(recursive: true)) {
        if (f is! File) continue;
        final ext = p.extension(f.path).toLowerCase().replaceFirst('.', '');
        if (!readableModelExts.contains(ext)) continue;
        try {
          final m = readModel(f.path);
          if (m.triangleCount > largest) largest = m.triangleCount;
          read++;
        } on ModelReadError catch (e) {
          failures.add('${p.relative(f.path, from: kit)}: $e');
        }
      }
      // ignore: avoid_print
      print('Fantasy Town Kit: $read models read, largest $largest triangles');
      expect(failures, isEmpty);
      expect(read, greaterThan(300));
    },
  );
}
