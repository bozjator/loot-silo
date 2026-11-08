import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

/// A unit cube (-1…1) as 8 corners and 12 counter-clockwise triangles.
const cubeCorners = [
  [-1.0, -1.0, -1.0], [1.0, -1.0, -1.0], [1.0, 1.0, -1.0], [-1.0, 1.0, -1.0], //
  [-1.0, -1.0, 1.0], [1.0, -1.0, 1.0], [1.0, 1.0, 1.0], [-1.0, 1.0, 1.0],
];

/// Faces as quads, counter-clockwise seen from outside.
const cubeQuads = [
  [4, 5, 6, 7], // +z
  [1, 0, 3, 2], // -z
  [5, 1, 2, 6], // +x
  [0, 4, 7, 3], // -x
  [7, 6, 2, 3], // +y
  [0, 1, 5, 4], // -y
];

List<int> get cubeTriangles => [
  for (final q in cubeQuads) ...[q[0], q[1], q[2], q[0], q[2], q[3]],
];

/// The cube's glTF JSON and binary buffer: positions (float VEC3) then
/// 16-bit indices; [buffer] is the buffer entry (a `uri`, or none for GLB).
/// The top three faces' material is [topColor], the rest [sideColor].
(Map<String, Object?>, Uint8List) cubeGltf({
  Map<String, Object?> buffer = const {},
  List<double> sideColor = const [0.9, 0.55, 0.35, 1],
  List<double> topColor = const [0.35, 0.7, 0.3, 1],
  Map<String, Object?>? node,
}) {
  final pos = Float32List.fromList([for (final c in cubeCorners) ...c]);
  final tris = cubeTriangles;
  // The +y face (indices 24..29) gets its own primitive and material.
  final sides = [...tris.sublist(0, 24), ...tris.sublist(30)];
  final top = tris.sublist(24, 30);
  final idx = Uint16List.fromList([...sides, ...top]);
  final bytes = BytesBuilder()
    ..add(pos.buffer.asUint8List())
    ..add(idx.buffer.asUint8List());
  final bin = bytes.toBytes();
  final json = <String, Object?>{
    'asset': {'version': '2.0'},
    'scene': 0,
    'scenes': [
      {
        'nodes': [0],
      },
    ],
    'nodes': [
      {'mesh': 0, ...?node},
    ],
    'meshes': [
      {
        'primitives': [
          {
            'attributes': {'POSITION': 0},
            'indices': 1,
            'material': 0,
          },
          {
            'attributes': {'POSITION': 0},
            'indices': 2,
            'material': 1,
          },
        ],
      },
    ],
    'materials': [
      {
        'name': 'side',
        'pbrMetallicRoughness': {'baseColorFactor': sideColor},
      },
      {
        'name': 'top',
        'pbrMetallicRoughness': {'baseColorFactor': topColor},
      },
    ],
    'buffers': [
      {'byteLength': bin.length, ...buffer},
    ],
    'bufferViews': [
      {'buffer': 0, 'byteOffset': 0, 'byteLength': pos.lengthInBytes},
      {
        'buffer': 0,
        'byteOffset': pos.lengthInBytes,
        'byteLength': idx.lengthInBytes,
      },
    ],
    'accessors': [
      {
        'bufferView': 0,
        'componentType': 5126,
        'count': 8,
        'type': 'VEC3',
        'min': [-1, -1, -1],
        'max': [1, 1, 1],
      },
      {
        'bufferView': 1,
        'componentType': 5123,
        'count': sides.length,
        'type': 'SCALAR',
      },
      {
        'bufferView': 1,
        'byteOffset': sides.length * 2,
        'componentType': 5123,
        'count': top.length,
        'type': 'SCALAR',
      },
    ],
  };
  return (json, bin);
}

/// A GLB container around [json] and [bin].
Uint8List glbBytes(Map<String, Object?> json, Uint8List bin) {
  Uint8List pad(List<int> b, int fill) {
    final out = Uint8List((b.length + 3) & ~3);
    out.setAll(0, b);
    out.fillRange(b.length, out.length, fill);
    return out;
  }

  final j = pad(utf8.encode(jsonEncode(json)), 0x20);
  final b = pad(bin, 0);
  final total = 12 + 8 + j.length + 8 + b.length;
  final d = ByteData(total);
  d.setUint32(0, 0x46546C67, Endian.little);
  d.setUint32(4, 2, Endian.little);
  d.setUint32(8, total, Endian.little);
  d.setUint32(12, j.length, Endian.little);
  d.setUint32(16, 0x4E4F534A, Endian.little);
  final out = d.buffer.asUint8List();
  out.setAll(20, j);
  final at = 20 + j.length;
  d.setUint32(at, b.length, Endian.little);
  d.setUint32(at + 4, 0x004E4942, Endian.little);
  out.setAll(at + 8, b);
  return out;
}

/// Writes the cube as `<dir>/<name>.glb`.
File writeCubeGlb(String dir, String name, {Map<String, Object?>? node}) {
  final (json, bin) = cubeGltf(node: node);
  final f = File(p.join(dir, '$name.glb'))..createSync(recursive: true);
  return f..writeAsBytesSync(glbBytes(json, bin));
}

/// Writes the cube as `<dir>/<name>.obj` with a `.mtl` beside it: quads,
/// negative (relative) indices for the last face, two materials.
File writeCubeObj(String dir, String name) {
  Directory(dir).createSync(recursive: true);
  File(p.join(dir, '$name.mtl')).writeAsStringSync('''
newmtl side
Kd 0.9 0.55 0.35

newmtl top
Kd 0.35 0.7 0.3
''');
  final b = StringBuffer('# cube\nmtllib $name.mtl\n');
  for (final c in cubeCorners) {
    b.writeln('v ${c[0]} ${c[1]} ${c[2]}');
  }
  b.writeln('usemtl side');
  for (final q in cubeQuads.take(4)) {
    b.writeln('f ${q.map((i) => i + 1).join(' ')}');
  }
  // -y side, with negative indices (8 corners: -8 is the first).
  b.writeln('f ${cubeQuads[5].map((i) => i - 8).join(' ')}');
  b.writeln('usemtl top');
  b.writeln('f ${cubeQuads[4].map((i) => i + 1).join(' ')}');
  return File(p.join(dir, '$name.obj'))..writeAsStringSync(b.toString());
}
