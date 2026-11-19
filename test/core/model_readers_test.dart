import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:loot_silo/core/mini_xml.dart';
import 'package:loot_silo/core/model_3ds.dart';
import 'package:loot_silo/core/model_dae.dart';
import 'package:loot_silo/core/model_fbx.dart';
import 'package:loot_silo/core/model_mesh.dart';
import 'package:loot_silo/core/model_stl.dart';
import 'package:path/path.dart' as p;

/// The normal of triangle [t] from its winding (not unit length).
List<double> faceNormal(ModelMesh m, int t) {
  List<double> v(int i) => m.positions.sublist(i * 3, i * 3 + 3);
  final a = v(m.indices[t * 3]), b = v(m.indices[t * 3 + 1]);
  final c = v(m.indices[t * 3 + 2]);
  final u = [b[0] - a[0], b[1] - a[1], b[2] - a[2]];
  final w = [c[0] - a[0], c[1] - a[1], c[2] - a[2]];
  return [
    u[1] * w[2] - u[2] * w[1],
    u[2] * w[0] - u[0] * w[2],
    u[0] * w[1] - u[1] * w[0],
  ];
}

/// A 3DS chunk: id, length, data.
Uint8List chunk(int id, List<List<int>> parts) {
  final body = [for (final part in parts) ...part];
  final head = ByteData(6)
    ..setUint16(0, id, Endian.little)
    ..setUint32(2, body.length + 6, Endian.little);
  return Uint8List.fromList([...head.buffer.asUint8List(), ...body]);
}

List<int> u16(int v) =>
    (ByteData(2)..setUint16(0, v, Endian.little)).buffer.asUint8List();
List<int> u32(int v) =>
    (ByteData(4)..setUint32(0, v, Endian.little)).buffer.asUint8List();
List<int> f32(List<double> values) {
  final d = ByteData(values.length * 4);
  for (var i = 0; i < values.length; i++) {
    d.setFloat32(i * 4, values[i], Endian.little);
  }
  return d.buffer.asUint8List();
}

List<int> cstr(String s) => [...latin1.encode(s), 0];

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('readers'));
  tearDown(() => tmp.deleteSync(recursive: true));

  group('readStl', () {
    // One triangle in the ground plane (z-up), counter-clockwise from above.
    const corners = [
      [0.0, 0.0, 0.0],
      [2.0, 0.0, 0.0],
      [0.0, 1.0, 0.0],
    ];

    void expectFloor(ModelMesh m, int triangles) {
      expect(m.triangleCount, triangles);
      expect(m.facetted, isTrue);
      expect(m.materials.single.color, ModelMaterial.plain.color);
      // z-up became y-up: the triangle lies in y = 0 and faces up.
      expect(m.bounds, [0, 0, -1, 2, 0, 0]);
      final n = faceNormal(m, 0);
      expect(n[1], greaterThan(0));
      expect(n[0], 0);
      expect(n[2], 0);
    }

    test('binary, also when its header starts with "solid"', () {
      final data = ByteData(84 + 2 * 50);
      data.buffer.asUint8List().setAll(0, 'solid made by a tool'.codeUnits);
      data.setUint32(80, 2, Endian.little);
      for (var t = 0; t < 2; t++) {
        for (var v = 0; v < 3; v++) {
          for (var k = 0; k < 3; k++) {
            data.setFloat32(
              84 + t * 50 + 12 + v * 12 + k * 4,
              corners[v][k],
              Endian.little,
            );
          }
        }
      }
      final f = File(p.join(tmp.path, 'a.stl'))
        ..writeAsBytesSync(data.buffer.asUint8List());
      expectFloor(readModel(f.path), 2);
    });

    test('text', () {
      final f = File(p.join(tmp.path, 'a.stl'))
        ..writeAsStringSync('''
solid floor
  facet normal 0 0 1
    outer loop
      vertex 0 0 0
      vertex 2.0e0 0 0
      vertex 0 1 0
    endloop
  endfacet
endsolid floor
''');
      expectFloor(readStl(f.path), 1);
    });

    test('junk and empty solids are refused', () {
      final f = File(p.join(tmp.path, 'a.stl'))..writeAsStringSync('hello');
      expect(() => readStl(f.path), throwsA(isA<ModelReadError>()));
      f.writeAsStringSync('solid x\nendsolid x\n');
      expect(() => readStl(f.path), throwsA(isA<ModelReadError>()));
      f.writeAsStringSync('solid x\nfacet\nvertex 1 nope 2\n');
      expect(() => readStl(f.path), throwsA(isA<ModelReadError>()));
    });
  });

  group('read3ds', () {
    /// Two triangles forming a roof ridge along x (z is up in the file),
    /// in smoothing groups [groups], with a red half see-through material
    /// on the first.
    Uint8List roof(List<int> groups) => chunk(0x4D4D, [
      chunk(0x3D3D, [
        chunk(0xAFFF, [
          chunk(0xA000, [cstr('paint')]),
          chunk(0xA020, [
            chunk(0x0011, [
              [255, 0, 0],
            ]),
          ]),
          chunk(0xA050, [
            chunk(0x0030, [u16(50)]),
          ]),
          chunk(0xA200, [
            chunk(0xA300, [cstr(r'tex\wall.png')]),
          ]),
        ]),
        chunk(0x4000, [
          cstr('roof'),
          chunk(0x4100, [
            chunk(0x4110, [
              u16(4),
              f32([0, 0, 1, 2, 0, 1, 0, -1, 0, 0, 1, 0]),
            ]),
            chunk(0x4140, [
              u16(4),
              f32([0, 0, 1, 0, 0, 1, 1, 1]),
            ]),
            chunk(0x4120, [
              u16(2),
              // ridge a-b, then the eaves; both wound to face outward.
              [...u16(0), ...u16(2), ...u16(1), ...u16(0)],
              [...u16(0), ...u16(1), ...u16(3), ...u16(0)],
              chunk(0x4130, [cstr('paint'), u16(1), u16(0)]),
              chunk(0x4150, [u32(groups[0]), u32(groups[1])]),
            ]),
          ]),
        ]),
      ]),
    ]);

    test('objects, materials, texture names, UVs; z-up turned y-up', () {
      final f = File(p.join(tmp.path, 'r.3ds'))..writeAsBytesSync(roof([0, 0]));
      final m = readModel(f.path);
      expect(m.triangleCount, 2);
      // The ridge is the highest part (y = 1 after the turn).
      expect(m.bounds, [0, 0, -1, 2, 1, 1]);
      final paint = m.materials[m.triangleMaterials[0]];
      expect(paint.name, 'paint');
      expect(paint.color, 0x80FF0000);
      expect(paint.texture, p.join(tmp.path, 'tex', 'wall.png'));
      expect(
        m.materials[m.triangleMaterials[1]].color,
        ModelMaterial.plain.color,
      );
      // v flipped to image orientation.
      expect(m.uvs!.sublist(0, 2), [0, 1]);
      expect(m.facetted, isFalse);
      // Both faces point up and outward.
      expect(faceNormal(m, 0)[1], greaterThan(0));
      expect(faceNormal(m, 1)[1], greaterThan(0));
    });

    test('smoothing groups round the shared edge; none keeps it hard', () {
      final f = File(p.join(tmp.path, 'r.3ds'));
      f.writeAsBytesSync(roof([0, 0]));
      final hard = read3ds(f.path);
      // Corner 0 of each face is ridge vertex a: two different normals.
      expect(hard.normals[2], closeTo(0.707, 0.01));
      expect(hard.normals[9 + 2], closeTo(-0.707, 0.01));
      f.writeAsBytesSync(roof([1, 1]));
      final smooth = read3ds(f.path);
      expect(smooth.normals.sublist(0, 3), smooth.normals.sublist(9, 12));
      expect(smooth.normals[1], closeTo(1, 1e-6));
      // Different groups: hard again.
      f.writeAsBytesSync(roof([1, 2]));
      expect(read3ds(f.path).normals[2], closeTo(0.707, 0.01));
    });

    test('junk and cut-off files are refused', () {
      final f = File(p.join(tmp.path, 'r.3ds'))..writeAsBytesSync([1, 2, 3]);
      expect(() => read3ds(f.path), throwsA(isA<ModelReadError>()));
      final whole = roof([0, 0]);
      f.writeAsBytesSync(whole.sublist(0, whole.length ~/ 2));
      expect(() => read3ds(f.path), throwsA(isA<ModelReadError>()));
    });
  });

  group('parseXml', () {
    test('elements, attributes, text, entities, CDATA, comments', () {
      final root = parseXml('''
<?xml version="1.0"?>
<!DOCTYPE a [ <!ENTITY x "y"> ]>
<a xmlns:xsi="u" xsi:kind='one &amp; "two"'>
  <!-- a comment with <tags> -->
  <b id="1">1 2 &lt;3&gt; &#65;&#x42;</b>
  <b id="2"/>
  <c><![CDATA[<raw & text>]]></c>
</a>''');
      expect(root.name, 'a');
      expect(root['kind'], 'one & "two"');
      expect(root.all('b').map((b) => b['id']), ['1', '2']);
      expect(root.child('b')!.text, '1 2 <3> AB');
      expect(root.child('c')!.text, '<raw & text>');
      expect(root.path(['c', 'nothing']), isNull);
      expect(root.descendants.map((n) => n.name), ['a', 'b', 'b', 'c']);
    });

    test('documents that are not well formed are refused', () {
      for (final bad in [
        '',
        'text',
        '<a>',
        '<a></a><b/>',
        '<a b=c/>',
        '</a>',
      ]) {
        expect(() => parseXml(bad), throwsFormatException, reason: bad);
      }
    });
  });

  group('readDae', () {
    String dae({
      String up = 'Z_UP',
      String transform = '<translate>0 0 2</translate>',
    }) =>
        '''
<?xml version="1.0" encoding="utf-8"?>
<COLLADA xmlns="http://www.collada.org/2005/11/COLLADASchema" version="1.4.1">
  <asset><up_axis>$up</up_axis></asset>
  <library_images>
    <image id="img"><init_from>tex/wall%20a.png</init_from></image>
  </library_images>
  <library_effects>
    <effect id="red-fx"><profile_COMMON><technique sid="common"><phong>
      <diffuse><color>1 0 0 1</color></diffuse>
    </phong></technique></profile_COMMON></effect>
    <effect id="tex-fx"><profile_COMMON>
      <newparam sid="surf"><surface type="2D"><init_from>img</init_from></surface></newparam>
      <newparam sid="samp"><sampler2D><source>surf</source></sampler2D></newparam>
      <technique sid="common"><lambert>
        <diffuse><texture texture="samp" texcoord="UV"/></diffuse>
      </lambert></technique>
    </profile_COMMON></effect>
  </library_effects>
  <library_materials>
    <material id="red" name="Red paint"><instance_effect url="#red-fx"/></material>
    <material id="tex" name="Wall"><instance_effect url="#tex-fx"/></material>
  </library_materials>
  <library_geometries>
    <geometry id="quad"><mesh>
      <source id="pos"><float_array id="pos-a" count="12">0 0 0 1 0 0 1 1 0 0 1 0</float_array>
        <technique_common><accessor source="#pos-a" count="4" stride="3"/></technique_common></source>
      <source id="nrm"><float_array id="nrm-a" count="3">0 0 1</float_array>
        <technique_common><accessor source="#nrm-a" count="1" stride="3"/></technique_common></source>
      <source id="uv"><float_array id="uv-a" count="8">0 0 1 0 1 1 0 1</float_array>
        <technique_common><accessor source="#uv-a" count="4" stride="2"/></technique_common></source>
      <vertices id="verts"><input semantic="POSITION" source="#pos"/></vertices>
      <polylist material="m0" count="1">
        <input semantic="VERTEX" source="#verts" offset="0"/>
        <input semantic="NORMAL" source="#nrm" offset="1"/>
        <input semantic="TEXCOORD" source="#uv" offset="2" set="0"/>
        <vcount>4</vcount>
        <p>0 0 0 1 0 1 2 0 2 3 0 3</p>
      </polylist>
      <triangles material="m1" count="1">
        <input semantic="VERTEX" source="#verts" offset="0"/>
        <p>0 1 2</p>
      </triangles>
    </mesh></geometry>
  </library_geometries>
  <library_visual_scenes><visual_scene id="scene">
    <node id="n">$transform
      <instance_geometry url="#quad"><bind_material><technique_common>
        <instance_material symbol="m0" target="#red"/>
        <instance_material symbol="m1" target="#tex"/>
      </technique_common></bind_material></instance_geometry>
    </node>
  </visual_scene></library_visual_scenes>
  <scene><instance_visual_scene url="#scene"/></scene>
</COLLADA>''';

    test('polylist and triangles, materials, textures, transforms, z-up', () {
      final f = File(p.join(tmp.path, 'q.dae'))..writeAsStringSync(dae());
      final m = readModel(f.path);
      expect(m.triangleCount, 3);
      // Lifted by 2 along the file's up axis, which becomes y.
      expect(m.bounds, [0, 2, -1, 1, 2, 0]);
      expect(m.materials.map((x) => x.name), ['Red paint', 'Wall']);
      expect(m.materials[0].color, 0xFFFF0000);
      expect(m.materials[1].texture, p.join(tmp.path, 'tex', 'wall a.png'));
      expect(m.triangleMaterials, [0, 0, 1]);
      // The quad's normals came from the file and point up now.
      expect(m.normals.sublist(0, 3), [0, 1, 0]);
      for (var t = 0; t < 3; t++) {
        expect(faceNormal(m, t)[1], greaterThan(0));
      }
      // t flipped to image orientation.
      expect(m.uvs!.sublist(0, 2), [0, 1]);
      // The triangle had no normals of its own.
      expect(m.facetted, isTrue);
    });

    test('matrix, rotate and scale; a mirror keeps faces outward', () {
      final f = File(p.join(tmp.path, 'q.dae'));
      f.writeAsStringSync(
        dae(
          up: 'Y_UP',
          transform: '<matrix>2 0 0 5  0 2 0 0  0 0 2 0  0 0 0 1</matrix>',
        ),
      );
      expect(readDae(f.path).bounds, [5, 0, 0, 7, 2, 0]);
      f.writeAsStringSync(
        dae(
          up: 'Y_UP',
          transform: '<rotate>1 0 0 -90</rotate><scale>3 1 1</scale>',
        ),
      );
      final turned = readDae(f.path);
      expect(turned.bounds[3], closeTo(3, 1e-6));
      expect(turned.bounds[2], closeTo(-1, 1e-6));
      expect(faceNormal(turned, 0)[1], greaterThan(0));
      f.writeAsStringSync(dae(up: 'Y_UP', transform: '<scale>-1 1 1</scale>'));
      final mirrored = readDae(f.path);
      expect(mirrored.bounds[0], -1);
      expect(faceNormal(mirrored, 0)[2], greaterThan(0));
    });

    test('not COLLADA, broken XML and bad indices are refused', () {
      final f = File(p.join(tmp.path, 'q.dae'))..writeAsStringSync('<a/>');
      expect(() => readDae(f.path), throwsA(isA<ModelReadError>()));
      f.writeAsStringSync('<COLLADA><asset>');
      expect(() => readDae(f.path), throwsA(isA<ModelReadError>()));
      f.writeAsStringSync(dae().replaceFirst('<p>0 1 2</p>', '<p>0 1 9</p>'));
      expect(() => readDae(f.path), throwsA(isA<ModelReadError>()));
      f.writeAsStringSync(dae().replaceFirst('<p>0 1 2</p>', '<p>0 x 2</p>'));
      expect(() => readDae(f.path), throwsA(isA<ModelReadError>()));
    });
  });

  group('readFbx', () {
    test('a text FBX from Kenney: triangles, materials, y-up', () {
      final m = readModel('test/fixtures/models/kenney_road_tile002.fbx');
      expect(m.triangleCount, 38);
      expect(m.vertexCount, 38 * 3);
      expect(m.usedMaterials.map((x) => x.name), ['pavement', 'asphalt']);
      expect(m.usedMaterials.map((x) => x.color), [0xFFD8D3BF, 0xFF696969]);
      // A 10 × 10 road tile lying flat, its kerb 2.1 high.
      expect(m.bounds[0], closeTo(-5, 1e-4));
      expect(m.bounds[3], closeTo(5, 1e-4));
      expect(m.bounds[1], closeTo(0, 1e-4));
      expect(m.bounds[4], closeTo(2.1, 1e-4));
      expect(m.facetted, isFalse);
      // Normals and winding agree.
      for (var t = 0; t < m.triangleCount; t++) {
        final n = faceNormal(m, t);
        final v = m.indices[t * 3] * 3;
        final dot =
            n[0] * m.normals[v] +
            n[1] * m.normals[v + 1] +
            n[2] * m.normals[v + 2];
        expect(dot, greaterThan(0), reason: 'triangle $t');
      }
    });

    test('junk and cut-off files are refused', () {
      final f = File(p.join(tmp.path, 'a.fbx'))..writeAsStringSync('nope');
      expect(
        () => readFbx(f.path),
        throwsA(
          isA<ModelReadError>().having(
            (e) => e.reason,
            'reason',
            startsWith('Not a valid FBX file'),
          ),
        ),
      );
      final good = File('test/fixtures/models/kenney_road_tile002.fbx')
          .readAsStringSync();
      f.writeAsStringSync(good.substring(0, good.length ~/ 2));
      expect(() => readFbx(f.path), throwsA(isA<ModelReadError>()));
      f.writeAsBytesSync([]);
      expect(() => readFbx(f.path), throwsA(isA<ModelReadError>()));
    });
  });
}
