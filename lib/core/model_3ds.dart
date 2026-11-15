import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'model_mesh.dart';

/// Reads a 3D Studio `.3ds` file: every object's triangles with their
/// materials (diffuse colour, opacity, first texture map) and texture
/// coordinates. Normals come from the smoothing groups: faces that share
/// a group are smooth across their common vertices, the others meet in a
/// hard edge. 3DS is z-up; the mesh is turned to y-up. Keyframes and the
/// objects' pivots are ignored.
ModelMesh read3ds(String path) {
  final bytes = modelFileBytes(path);
  try {
    return _Reader3ds(bytes, p.dirname(path)).read();
  } on RangeError {
    throw const ModelReadError('Truncated 3DS file');
  }
}

class _Reader3ds {
  _Reader3ds(this.bytes, this.dir) : data = ByteData.sublistView(bytes);

  final Uint8List bytes;
  final ByteData data;
  final String dir;
  final b = MeshBuilder();
  final _materials = <String, int>{};

  ModelMesh read() {
    if (bytes.length < 6 || data.getUint16(0, Endian.little) != 0x4D4D) {
      throw const ModelReadError('Not a valid 3DS file');
    }
    _chunks(6, _end(0), (id, start, end) {
      if (id != 0x3D3D) return;
      // Materials first: objects name them.
      _chunks(start, end, (id, start, end) {
        if (id == 0xAFFF) _material(start, end);
      });
      _chunks(start, end, (id, start, end) {
        if (id != 0x4000) return;
        final at = _skipString(start);
        _chunks(at, end, (id, start, end) {
          if (id == 0x4100) _mesh(start, end);
        });
      });
    });
    return b.build();
  }

  int _end(int chunk) =>
      math.min(bytes.length, chunk + data.getUint32(chunk + 2, Endian.little));

  /// Calls [each] with the id and the data range of every chunk in
  /// [start, end).
  void _chunks(int start, int end, void Function(int, int, int) each) {
    var at = start;
    while (at + 6 <= end) {
      final length = data.getUint32(at + 2, Endian.little);
      if (length < 6) throw const ModelReadError('Not a valid 3DS file');
      each(
        data.getUint16(at, Endian.little),
        at + 6,
        math.min(end, at + length),
      );
      at += length;
    }
  }

  int _skipString(int at) {
    while (bytes[at] != 0) {
      at++;
    }
    return at + 1;
  }

  String _string(int at) =>
      latin1.decode(bytes.sublist(at, _skipString(at) - 1));

  /// A colour chunk's 0–1 channels: bytes (0x0011, 0x0012) or floats.
  List<double>? _color(int start, int end) {
    List<double>? out;
    _chunks(start, end, (id, start, end) {
      if (id == 0x0011 || id == 0x0012) {
        out ??= [for (var i = 0; i < 3; i++) bytes[start + i] / 255];
      } else if (id == 0x0010 || id == 0x0013) {
        out ??= [
          for (var i = 0; i < 3; i++)
            data.getFloat32(start + i * 4, Endian.little),
        ];
      }
    });
    return out;
  }

  void _material(int start, int end) {
    var name = '';
    var color = [0.8, 0.8, 0.8];
    var alpha = 1.0;
    String? texture;
    _chunks(start, end, (id, start, end) {
      switch (id) {
        case 0xA000:
          name = _string(start);
        case 0xA020:
          color = _color(start, end) ?? color;
        case 0xA050:
          // Transparency in percent.
          _chunks(start, end, (id, start, end) {
            if (id == 0x0030) {
              alpha = 1 - data.getUint16(start, Endian.little) / 100;
            } else if (id == 0x0031) {
              alpha = 1 - data.getFloat32(start, Endian.little);
            }
          });
        case 0xA200:
          _chunks(start, end, (id, start, end) {
            if (id == 0xA300) {
              final file = _string(start).replaceAll(r'\', '/');
              if (file.isNotEmpty) texture = p.normalize(p.join(dir, file));
            }
          });
      }
    });
    b.materials.add(
      ModelMaterial(
        color: argbColor(color[0], color[1], color[2], alpha),
        name: name.isEmpty ? null : name,
        texture: texture,
        nearest: false,
      ),
    );
    _materials[name] = b.materials.length - 1;
  }

  int? _plain;
  int _plainMaterial() => _plain ??= () {
    b.materials.add(ModelMaterial.plain);
    return b.materials.length - 1;
  }();

  void _mesh(int start, int end) {
    var verts = Float32List(0);
    Float32List? uvs;
    var faces = Uint16List(0);
    Uint32List? groups;
    final faceMaterial = <int, int>{};
    _chunks(start, end, (id, start, end) {
      switch (id) {
        case 0x4110:
          final n = data.getUint16(start, Endian.little);
          verts = Float32List(n * 3);
          for (var i = 0; i < n * 3; i++) {
            verts[i] = data.getFloat32(start + 2 + i * 4, Endian.little);
          }
        case 0x4140:
          final n = data.getUint16(start, Endian.little);
          final list = uvs = Float32List(n * 2);
          for (var i = 0; i < n * 2; i++) {
            list[i] = data.getFloat32(start + 2 + i * 4, Endian.little);
          }
        case 0x4120:
          final n = data.getUint16(start, Endian.little);
          faces = Uint16List(n * 3);
          for (var f = 0; f < n; f++) {
            for (var k = 0; k < 3; k++) {
              faces[f * 3 + k] = data.getUint16(
                start + 2 + f * 8 + k * 2,
                Endian.little,
              );
            }
          }
          _chunks(start + 2 + n * 8, end, (id, start, end) {
            if (id == 0x4130) {
              final name = _string(start);
              var at = _skipString(start);
              final count = data.getUint16(at, Endian.little);
              at += 2;
              final material = _materials[name] ?? _plainMaterial();
              for (var i = 0; i < count; i++) {
                faceMaterial[data.getUint16(at + i * 2, Endian.little)] =
                    material;
              }
            } else if (id == 0x4150) {
              final list = groups = Uint32List(n);
              for (var f = 0; f < n && start + f * 4 + 4 <= end; f++) {
                list[f] = data.getUint32(start + f * 4, Endian.little);
              }
            }
          });
      }
    });
    final vertexCount = verts.length ~/ 3;
    final faceCount = faces.length ~/ 3;
    for (final v in faces) {
      if (v >= vertexCount) throw const ModelReadError('Index out of range');
    }

    // Face normals (not unit: bigger faces weigh more in a smooth corner)
    // and the faces around each vertex.
    final normals = Float64List(faceCount * 3);
    final around = List<List<int>?>.filled(vertexCount, null);
    for (var f = 0; f < faceCount; f++) {
      final a = faces[f * 3] * 3, c1 = faces[f * 3 + 1] * 3;
      final c2 = faces[f * 3 + 2] * 3;
      final ux = verts[c1] - verts[a], uy = verts[c1 + 1] - verts[a + 1];
      final uz = verts[c1 + 2] - verts[a + 2];
      final wx = verts[c2] - verts[a], wy = verts[c2 + 1] - verts[a + 1];
      final wz = verts[c2 + 2] - verts[a + 2];
      normals[f * 3] = uy * wz - uz * wy;
      normals[f * 3 + 1] = uz * wx - ux * wz;
      normals[f * 3 + 2] = ux * wy - uy * wx;
      if (groups != null) {
        for (var k = 0; k < 3; k++) {
          (around[faces[f * 3 + k]] ??= []).add(f);
        }
      }
    }
    final list = uvs;
    for (var f = 0; f < faceCount; f++) {
      final group = groups?[f] ?? 0;
      final first = b.vertexCount;
      for (var k = 0; k < 3; k++) {
        final v = faces[f * 3 + k];
        var nx = normals[f * 3], ny = normals[f * 3 + 1];
        var nz = normals[f * 3 + 2];
        if (group != 0) {
          for (final other in around[v]!) {
            if (other == f || groups![other] & group == 0) continue;
            nx += normals[other * 3];
            ny += normals[other * 3 + 1];
            nz += normals[other * 3 + 2];
          }
        }
        final length = math.sqrt(nx * nx + ny * ny + nz * nz);
        // z-up → y-up: (x, y, z) → (x, z, −y).
        b.pos
          ..add(verts[v * 3])
          ..add(verts[v * 3 + 2])
          ..add(-verts[v * 3 + 1]);
        if (length > 0) {
          b.nrm
            ..add(nx / length)
            ..add(nz / length)
            ..add(-ny / length);
        } else {
          b.nrm
            ..add(0)
            ..add(1)
            ..add(0);
        }
        if (list != null && v * 2 + 1 < list.length) {
          // 3DS's v points up; the mesh keeps image orientation.
          b.uv
            ..add(list[v * 2])
            ..add(1 - list[v * 2 + 1]);
          b.hasUv = true;
        } else {
          b.uv
            ..add(0)
            ..add(0);
        }
      }
      b.idx
        ..add(first)
        ..add(first + 1)
        ..add(first + 2);
      b.triMat.add(faceMaterial[f] ?? _plainMaterial());
    }
  }
}
