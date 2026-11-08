import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:path/path.dart' as p;

/// A model file that can't be drawn: bad data or an unsupported feature.
/// [reason] is short enough for a tooltip.
class ModelReadError implements Exception {
  const ModelReadError(this.reason);

  final String reason;

  @override
  String toString() => reason;
}

/// A mesh with more than [maxPreviewTriangles] triangles: read, but not
/// drawn.
class ModelTooLargeError extends ModelReadError {
  const ModelTooLargeError(this.triangles) : super('Too large to preview');

  final int triangles;
}

/// Above this, a model shows "Too large to preview" instead of drawing.
const maxPreviewTriangles = 200000;

/// How a group of triangles is coloured.
class ModelMaterial {
  const ModelMaterial({
    required this.color,
    this.name,
    this.file,
    this.texture,
    this.nearest = true,
    this.doubleSided = false,
  });

  /// Base colour as ARGB, used as-is (no linear → sRGB step: Kenney writes
  /// the same numbers into its MTL and glTF files).
  final int color;

  /// An absolute image path, or a key into [ModelMesh.images] for an image
  /// stored inside the model file; null for a plain colour.
  final String? texture;

  /// Sample the texture without smoothing (glTF NEAREST, and OBJ).
  final bool nearest;

  /// Both sides are drawn (glTF `doubleSided`); otherwise back faces are
  /// culled.
  final bool doubleSided;

  /// As the file names it (`wood`, `leavesGreen`); null when unnamed.
  final String? name;

  /// The file that defines it when that isn't the model file (an OBJ's
  /// `.mtl`), absolute; null for materials stored in the model.
  final String? file;

  static const plain = ModelMaterial(color: 0xFFC8C8C8);
}

/// A static triangle mesh: what the readers produce and the painter draws.
///
/// Every node transform is already applied, so [positions] are in model
/// space. Skins and animations are ignored.
class ModelMesh {
  ModelMesh({
    required this.positions,
    required this.normals,
    required this.indices,
    required this.triangleMaterials,
    required this.materials,
    this.uvs,
    this.images = const {},
  }) : bounds = _bounds(positions);

  /// x, y, z per vertex.
  final Float32List positions;

  /// x, y, z per vertex, unit length. Files without normals get the
  /// average of the faces around each vertex.
  final Float32List normals;

  /// Three vertex indices per triangle, counter-clockwise when seen from
  /// the front.
  final Uint32List indices;

  /// One index into [materials] per triangle.
  final Uint16List triangleMaterials;
  final List<ModelMaterial> materials;

  /// u, v per vertex with v pointing down (glTF / image convention), or null
  /// when the file has none.
  final Float32List? uvs;

  /// Encoded images (PNG / JPEG) stored inside the file, by the key a
  /// material's [ModelMaterial.texture] names.
  final Map<String, Uint8List> images;

  /// min x, y, z then max x, y, z.
  final Float64List bounds;

  int get triangleCount => indices.length ~/ 3;
  int get vertexCount => positions.length ~/ 3;

  /// The materials at least one triangle uses, in [materials] order.
  List<ModelMaterial> get usedMaterials {
    final used = {...triangleMaterials};
    return [
      for (var i = 0; i < materials.length; i++)
        if (used.contains(i)) materials[i],
    ];
  }

  /// The textures the triangles use (paths or [images] keys).
  Set<String> get textures => {
    if (uvs != null)
      for (final m in materials) ?m.texture,
  };

  static Float64List _bounds(Float32List pos) {
    final b = Float64List(6);
    if (pos.isEmpty) return b;
    for (var k = 0; k < 3; k++) {
      b[k] = double.infinity;
      b[k + 3] = double.negativeInfinity;
    }
    for (var i = 0; i < pos.length; i += 3) {
      for (var k = 0; k < 3; k++) {
        final v = pos[i + k];
        if (v < b[k]) b[k] = v;
        if (v > b[k + 3]) b[k + 3] = v;
      }
    }
    return b;
  }
}

/// Formats [readModel] can draw.
const readableModelExts = {'glb', 'gltf', 'obj'};

/// Reads a GLB, glTF or OBJ file by its extension.
ModelMesh readModel(String path) => switch (p.extension(path).toLowerCase()) {
  '.glb' || '.gltf' => readGltf(path),
  '.obj' => readObj(path),
  _ => throw const ModelReadError('Format not supported'),
};

Uint8List _bytes(String path) {
  try {
    return File(path).readAsBytesSync();
  } on FileSystemException {
    throw ModelReadError('Missing file: ${p.basename(path)}');
  }
}

/// Collects triangles from the parts of a file, then builds the mesh.
class _MeshBuilder {
  final pos = <double>[];

  /// NaN where a part has no normals.
  final nrm = <double>[];
  final uv = <double>[];
  var hasUv = false;
  final idx = <int>[];
  final triMat = <int>[];
  final materials = <ModelMaterial>[];
  final images = <String, Uint8List>{};

  int get vertexCount => pos.length ~/ 3;

  ModelMesh build() {
    if (idx.isEmpty) throw const ModelReadError('No triangles');
    final positions = Float32List.fromList(pos);
    final normals = Float32List.fromList(nrm);
    final indices = Uint32List.fromList(idx);
    _fillNormals(positions, normals, indices);
    return ModelMesh(
      positions: positions,
      normals: normals,
      indices: indices,
      triangleMaterials: Uint16List.fromList(triMat),
      materials: materials.isEmpty ? [ModelMaterial.plain] : materials,
      uvs: hasUv ? Float32List.fromList(uv) : null,
      images: images,
    );
  }

  /// Vertices without a normal get the sum of their faces' normals.
  static void _fillNormals(Float32List pos, Float32List nrm, Uint32List idx) {
    final missing = <int>{};
    for (var v = 0; v < nrm.length ~/ 3; v++) {
      if (nrm[v * 3].isNaN) {
        missing.add(v);
        nrm[v * 3] = nrm[v * 3 + 1] = nrm[v * 3 + 2] = 0;
      }
    }
    if (missing.isEmpty) return;
    for (var t = 0; t < idx.length; t += 3) {
      final a = idx[t] * 3, b = idx[t + 1] * 3, c = idx[t + 2] * 3;
      final ux = pos[b] - pos[a], uy = pos[b + 1] - pos[a + 1];
      final uz = pos[b + 2] - pos[a + 2];
      final vx = pos[c] - pos[a], vy = pos[c + 1] - pos[a + 1];
      final vz = pos[c + 2] - pos[a + 2];
      final nx = uy * vz - uz * vy, ny = uz * vx - ux * vz;
      final nz = ux * vy - uy * vx;
      for (final v in [idx[t], idx[t + 1], idx[t + 2]]) {
        if (!missing.contains(v)) continue;
        nrm[v * 3] += nx;
        nrm[v * 3 + 1] += ny;
        nrm[v * 3 + 2] += nz;
      }
    }
    for (final v in missing) {
      final x = nrm[v * 3], y = nrm[v * 3 + 1], z = nrm[v * 3 + 2];
      final len = math.sqrt(x * x + y * y + z * z);
      if (len > 0) {
        nrm[v * 3] = x / len;
        nrm[v * 3 + 1] = y / len;
        nrm[v * 3 + 2] = z / len;
      } else {
        nrm[v * 3 + 1] = 1;
      }
    }
  }
}

int _argb(double r, double g, double b, double a) {
  int c(double v) => (v.clamp(0.0, 1.0) * 255).round();
  return c(a) << 24 | c(r) << 16 | c(g) << 8 | c(b);
}

// ---------------------------------------------------------------- glTF --

/// Reads a GLB container or a JSON glTF with its buffers (the GLB BIN
/// chunk, `.bin` files beside it, or `data:` URIs). Draws the default
/// scene's meshes in their node transforms (TRS or matrix); only triangle
/// lists (mode 4). Colours from `baseColorFactor`, the first
/// `baseColorTexture` (a file or an image inside the model).
ModelMesh readGltf(String path) {
  final bytes = _bytes(path);
  try {
    return _Gltf.parse(bytes, p.dirname(path)).read();
  } on ModelReadError {
    rethrow;
  } on FormatException {
    throw const ModelReadError('Not a valid glTF file');
  } on TypeError {
    throw const ModelReadError('Not a valid glTF file');
  } on RangeError {
    throw const ModelReadError('Data out of range');
  }
}

class _Gltf {
  _Gltf(this.json, this.bin, this.dir);

  final Map<String, Object?> json;
  final Uint8List? bin;
  final String dir;
  final _buffers = <int, Uint8List>{};
  final _builder = _MeshBuilder();

  /// glTF material index → index in the builder's list.
  final _materials = <int, int>{};

  factory _Gltf.parse(Uint8List bytes, String dir) {
    final data = ByteData.sublistView(bytes);
    if (bytes.length >= 12 && data.getUint32(0, Endian.little) == 0x46546C67) {
      if (data.getUint32(4, Endian.little) != 2) {
        throw const ModelReadError('Only glTF 2.0 is supported');
      }
      Map<String, Object?>? json;
      Uint8List? bin;
      var at = 12;
      final end = math.min(bytes.length, data.getUint32(8, Endian.little));
      while (at + 8 <= end) {
        final len = data.getUint32(at, Endian.little);
        final type = data.getUint32(at + 4, Endian.little);
        final start = at + 8;
        if (start + len > end) throw const ModelReadError('Truncated GLB');
        final chunk = Uint8List.sublistView(bytes, start, start + len);
        if (type == 0x4E4F534A) {
          json = jsonDecode(utf8.decode(chunk)) as Map<String, Object?>;
        } else if (type == 0x004E4942) {
          bin = chunk;
        }
        at = start + ((len + 3) & ~3);
      }
      if (json == null) throw const ModelReadError('GLB without JSON');
      return _Gltf(json, bin, dir);
    }
    final json = jsonDecode(utf8.decode(bytes));
    if (json is! Map<String, Object?>) {
      throw const ModelReadError('Not a valid glTF file');
    }
    return _Gltf(json, null, dir);
  }

  List<Object?> _list(String key) => (json[key] as List<Object?>?) ?? const [];

  Map<String, Object?> _at(String key, int i) {
    final l = _list(key);
    if (i < 0 || i >= l.length) throw ModelReadError('Bad $key index');
    return l[i]! as Map<String, Object?>;
  }

  Uint8List _buffer(int i) => _buffers.putIfAbsent(i, () {
    final uri = _at('buffers', i)['uri'] as String?;
    if (uri == null) {
      if (bin == null) throw const ModelReadError('Missing binary chunk');
      return bin!;
    }
    return _load(uri);
  });

  /// A `data:` URI's bytes, or a file next to the model.
  Uint8List _load(String uri) {
    if (uri.startsWith('data:')) {
      return UriData.parse(uri).contentAsBytes();
    }
    return _bytes(p.join(dir, Uri.decodeFull(uri)));
  }

  Uint8List _view(int i) {
    final v = _at('bufferViews', i);
    final buf = _buffer(v['buffer']! as int);
    final off = (v['byteOffset'] as int?) ?? 0;
    final len = v['byteLength']! as int;
    if (off + len > buf.length) throw const ModelReadError('Data out of range');
    return Uint8List.sublistView(buf, off, off + len);
  }

  static const _components = {
    'SCALAR': 1,
    'VEC2': 2,
    'VEC3': 3,
    'VEC4': 4,
    'MAT4': 16,
  };

  /// An accessor's values as doubles (normalized ints scaled to 0–1 or
  /// -1–1), [count] × components. An accessor without a buffer view is
  /// all zeros (sparse data isn't read).
  (List<double>, int) _floats(int i) {
    final a = _at('accessors', i);
    final count = a['count']! as int;
    final n = _components[a['type']] ?? 1;
    final out = Float64List(count * n);
    final viewIndex = a['bufferView'] as int?;
    if (viewIndex == null) return (out, n);
    final type = a['componentType']! as int;
    final normalized = a['normalized'] == true;
    final size = switch (type) {
      5120 || 5121 => 1,
      5122 || 5123 => 2,
      5125 || 5126 => 4,
      _ => throw const ModelReadError('Unknown component type'),
    };
    final view = _view(viewIndex);
    final stride =
        (_at('bufferViews', viewIndex)['byteStride'] as int?) ?? size * n;
    final base = (a['byteOffset'] as int?) ?? 0;
    if (count > 0 && base + stride * (count - 1) + size * n > view.length) {
      throw const ModelReadError('Data out of range');
    }
    final d = ByteData.sublistView(view);
    for (var e = 0; e < count; e++) {
      for (var k = 0; k < n; k++) {
        final at = base + e * stride + k * size;
        out[e * n + k] = switch (type) {
          5126 => d.getFloat32(at, Endian.little),
          5121 => normalized ? d.getUint8(at) / 255 : d.getUint8(at) * 1.0,
          5120 =>
            normalized
                ? math.max(d.getInt8(at) / 127, -1.0)
                : d.getInt8(at) * 1.0,
          5123 =>
            normalized
                ? d.getUint16(at, Endian.little) / 65535
                : d.getUint16(at, Endian.little) * 1.0,
          5122 =>
            normalized
                ? math.max(d.getInt16(at, Endian.little) / 32767, -1.0)
                : d.getInt16(at, Endian.little) * 1.0,
          _ => d.getUint32(at, Endian.little) * 1.0,
        };
      }
    }
    return (out, n);
  }

  ModelMesh read() {
    final asset = json['asset'] as Map<String, Object?>?;
    final version = asset?['version'] as String?;
    if (version != null && !version.startsWith('2')) {
      throw const ModelReadError('Only glTF 2.0 is supported');
    }
    final scenes = _list('scenes');
    List<int> roots;
    if (scenes.isNotEmpty) {
      final s = (json['scene'] as int?) ?? 0;
      roots = [
        for (final n in (_at('scenes', s)['nodes'] as List<Object?>?) ?? [])
          n! as int,
      ];
    } else {
      // No scene: every node nobody lists as a child.
      final children = {
        for (final n in _list('nodes'))
          for (final c
              in ((n! as Map<String, Object?>)['children'] as List<Object?>?) ??
                  [])
            c! as int,
      };
      roots = [
        for (var i = 0; i < _list('nodes').length; i++)
          if (!children.contains(i)) i,
      ];
    }
    for (final r in roots) {
      _node(r, _identity(), 0);
    }
    return _builder.build();
  }

  void _node(int i, Float64List parent, int depth) {
    if (depth > 64) throw const ModelReadError('Node tree too deep');
    final n = _at('nodes', i);
    final m = _mul(parent, _local(n));
    if (n['mesh'] case final int mesh) _mesh(mesh, m);
    for (final c in (n['children'] as List<Object?>?) ?? const []) {
      _node(c! as int, m, depth + 1);
    }
  }

  void _mesh(int i, Float64List m) {
    final b = _builder;
    final flip = _det3(m) < 0;
    for (final prim
        in (_at('meshes', i)['primitives'] as List<Object?>?) ?? const []) {
      final pr = prim! as Map<String, Object?>;
      if (((pr['mode'] as int?) ?? 4) != 4) continue;
      final attrs = pr['attributes']! as Map<String, Object?>;
      final posIndex = attrs['POSITION'] as int?;
      if (posIndex == null) continue;
      final (pos, _) = _floats(posIndex);
      final count = pos.length ~/ 3;
      final nrm = switch (attrs['NORMAL']) {
        final int k => _floats(k).$1,
        _ => null,
      };
      final uv = switch (attrs['TEXCOORD_0']) {
        final int k => _floats(k).$1,
        _ => null,
      };
      final first = b.vertexCount;
      for (var v = 0; v < count; v++) {
        final x = pos[v * 3], y = pos[v * 3 + 1], z = pos[v * 3 + 2];
        b.pos
          ..add(m[0] * x + m[4] * y + m[8] * z + m[12])
          ..add(m[1] * x + m[5] * y + m[9] * z + m[13])
          ..add(m[2] * x + m[6] * y + m[10] * z + m[14]);
        if (nrm != null && nrm.length >= (v + 1) * 3) {
          final nx = nrm[v * 3], ny = nrm[v * 3 + 1], nz = nrm[v * 3 + 2];
          var tx = m[0] * nx + m[4] * ny + m[8] * nz;
          var ty = m[1] * nx + m[5] * ny + m[9] * nz;
          var tz = m[2] * nx + m[6] * ny + m[10] * nz;
          final len = math.sqrt(tx * tx + ty * ty + tz * tz);
          if (len > 0) {
            tx /= len;
            ty /= len;
            tz /= len;
          }
          b.nrm.addAll([tx, ty, tz]);
        } else {
          b.nrm.addAll([double.nan, double.nan, double.nan]);
        }
        if (uv != null && uv.length >= (v + 1) * 2) {
          b.uv.addAll([uv[v * 2], uv[v * 2 + 1]]);
          b.hasUv = true;
        } else {
          b.uv.addAll([0, 0]);
        }
      }
      final List<int> idx = switch (pr['indices']) {
        final int k => [for (final v in _floats(k).$1) v.toInt()],
        _ => [for (var v = 0; v < count; v++) v],
      };
      final mat = _material(pr['material'] as int?);
      for (var t = 0; t + 2 < idx.length; t += 3) {
        final a = idx[t], c1 = idx[t + 1], c2 = idx[t + 2];
        if (a >= count || c1 >= count || c2 >= count) {
          throw const ModelReadError('Index out of range');
        }
        b.idx.addAll(
          flip
              ? [first + a, first + c2, first + c1]
              : [first + a, first + c1, first + c2],
        );
        b.triMat.add(mat);
      }
    }
  }

  int _material(int? i) {
    if (i == null) return _plain();
    return _materials.putIfAbsent(i, () {
      final m = _at('materials', i);
      final pbr = m['pbrMetallicRoughness'] as Map<String, Object?>?;
      final f = [
        for (final v
            in (pbr?['baseColorFactor'] as List<Object?>?) ??
                const [1.0, 1.0, 1.0, 1.0])
          (v! as num).toDouble(),
      ];
      final color = f.length >= 4 ? _argb(f[0], f[1], f[2], f[3]) : 0xFFFFFFFF;
      String? texture;
      var nearest = false;
      final tex = pbr?['baseColorTexture'] as Map<String, Object?>?;
      if (tex?['index'] case final int t) {
        (texture, nearest) = _texture(t);
      }
      _builder.materials.add(
        ModelMaterial(
          color: color,
          name: m['name'] as String?,
          texture: texture,
          nearest: nearest,
          doubleSided: m['doubleSided'] == true,
        ),
      );
      return _builder.materials.length - 1;
    });
  }

  int? _plainIndex;
  int _plain() => _plainIndex ??= () {
    _builder.materials.add(ModelMaterial.plain);
    return _builder.materials.length - 1;
  }();

  /// The texture's image (a path, or a key into the mesh's images) and
  /// whether it is sampled without smoothing.
  (String?, bool) _texture(int i) {
    final t = _at('textures', i);
    final source = t['source'] as int?;
    if (source == null) return (null, false);
    final nearest = switch (t['sampler']) {
      final int s => _at('samplers', s)['magFilter'] == 9728,
      _ => false,
    };
    final img = _at('images', source);
    final key = 'image:$source';
    if (img['bufferView'] case final int v) {
      _builder.images[key] ??= Uint8List.fromList(_view(v));
      return (key, nearest);
    }
    final uri = img['uri'] as String?;
    if (uri == null) return (null, false);
    if (uri.startsWith('data:')) {
      _builder.images[key] ??= _load(uri);
      return (key, nearest);
    }
    return (p.normalize(p.join(dir, Uri.decodeFull(uri))), nearest);
  }

  /// A node's own transform, column-major.
  static Float64List _local(Map<String, Object?> n) {
    if (n['matrix'] case final List<Object?> m when m.length == 16) {
      return Float64List.fromList([for (final v in m) (v! as num).toDouble()]);
    }
    List<double> vec(String key, List<double> def) => [
      for (final v in (n[key] as List<Object?>?) ?? def) (v! as num).toDouble(),
    ];
    final t = vec('translation', [0, 0, 0]);
    final r = vec('rotation', [0, 0, 0, 1]);
    final s = vec('scale', [1, 1, 1]);
    final x = r[0], y = r[1], z = r[2], w = r[3];
    return Float64List.fromList([
      (1 - 2 * (y * y + z * z)) * s[0],
      (2 * (x * y + z * w)) * s[0],
      (2 * (x * z - y * w)) * s[0],
      0,
      (2 * (x * y - z * w)) * s[1],
      (1 - 2 * (x * x + z * z)) * s[1],
      (2 * (y * z + x * w)) * s[1],
      0,
      (2 * (x * z + y * w)) * s[2],
      (2 * (y * z - x * w)) * s[2],
      (1 - 2 * (x * x + y * y)) * s[2],
      0,
      t[0],
      t[1],
      t[2],
      1,
    ]);
  }

  static Float64List _identity() =>
      Float64List.fromList([1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]);

  static Float64List _mul(Float64List a, Float64List b) {
    final out = Float64List(16);
    for (var c = 0; c < 4; c++) {
      for (var r = 0; r < 4; r++) {
        var s = 0.0;
        for (var k = 0; k < 4; k++) {
          s += a[k * 4 + r] * b[c * 4 + k];
        }
        out[c * 4 + r] = s;
      }
    }
    return out;
  }

  static double _det3(Float64List m) =>
      m[0] * (m[5] * m[10] - m[9] * m[6]) -
      m[4] * (m[1] * m[10] - m[9] * m[2]) +
      m[8] * (m[1] * m[6] - m[5] * m[2]);
}

// ----------------------------------------------------------------- OBJ --

/// Reads a Wavefront OBJ: `v`, `vn`, `vt`, `f` (polygons fanned into
/// triangles, negative indices), `usemtl` with `mtllib` (`Kd` colour, `d`
/// opacity, `map_Kd` texture relative to the MTL file).
ModelMesh readObj(String path) {
  final String text;
  try {
    text = latin1.decode(_bytes(path));
  } on FormatException {
    throw const ModelReadError('Not a text file');
  }
  final dir = p.dirname(path);
  final b = _MeshBuilder();
  final vs = <double>[], vns = <double>[], vts = <double>[];
  final mtl = <String, ModelMaterial>{};
  final matIndex = <String, int>{};
  var current = -1;
  final verts = <(int, int, int), int>{};

  int resolve(String s, int count) {
    final i = int.tryParse(s);
    if (i == null || i == 0) throw const ModelReadError('Bad face index');
    final r = i < 0 ? count + i : i - 1;
    if (r < 0 || r >= count) throw const ModelReadError('Index out of range');
    return r;
  }

  int vertex(String token) {
    final parts = token.split('/');
    final v = resolve(parts[0], vs.length ~/ 3);
    final t = parts.length > 1 && parts[1].isNotEmpty
        ? resolve(parts[1], vts.length ~/ 2)
        : -1;
    final n = parts.length > 2 && parts[2].isNotEmpty
        ? resolve(parts[2], vns.length ~/ 3)
        : -1;
    return verts.putIfAbsent((v, t, n), () {
      b.pos.addAll([vs[v * 3], vs[v * 3 + 1], vs[v * 3 + 2]]);
      if (n >= 0) {
        b.nrm.addAll([vns[n * 3], vns[n * 3 + 1], vns[n * 3 + 2]]);
      } else {
        b.nrm.addAll([double.nan, double.nan, double.nan]);
      }
      if (t >= 0) {
        // OBJ's v points up; the mesh keeps image orientation.
        b.uv.addAll([vts[t * 2], 1 - vts[t * 2 + 1]]);
        b.hasUv = true;
      } else {
        b.uv.addAll([0, 0]);
      }
      return b.vertexCount - 1;
    });
  }

  int material() {
    if (current < 0) {
      b.materials.add(ModelMaterial.plain);
      current = b.materials.length - 1;
    }
    return current;
  }

  double num(List<String> parts, int i, [double def = 0]) =>
      i < parts.length ? double.tryParse(parts[i]) ?? def : def;

  for (final raw in LineSplitter.split(text)) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    final parts = line.split(RegExp(r'\s+'));
    switch (parts[0]) {
      case 'v':
        vs.addAll([num(parts, 1), num(parts, 2), num(parts, 3)]);
      case 'vn':
        vns.addAll([num(parts, 1), num(parts, 2), num(parts, 3)]);
      case 'vt':
        vts.addAll([num(parts, 1), num(parts, 2)]);
      case 'f':
        if (parts.length < 4) continue;
        final m = material();
        final ids = [for (final t in parts.skip(1)) vertex(t)];
        for (var i = 1; i + 1 < ids.length; i++) {
          b.idx.addAll([ids[0], ids[i], ids[i + 1]]);
          b.triMat.add(m);
        }
      case 'mtllib':
        final name = line.substring(6).trim();
        mtl.addAll(_readMtl(p.join(dir, name)));
      case 'usemtl':
        final name = line.substring(6).trim();
        current = matIndex.putIfAbsent(name, () {
          // A name the MTL doesn't define (or no MTL): plain grey.
          b.materials.add(
            mtl[name] ??
                ModelMaterial(color: ModelMaterial.plain.color, name: name),
          );
          return b.materials.length - 1;
        });
    }
  }
  return b.build();
}

/// The materials of an MTL file by name; none when it is missing.
Map<String, ModelMaterial> _readMtl(String path) {
  final file = File(path);
  if (!file.existsSync()) return const {};
  final out = <String, ModelMaterial>{};
  String? name;
  var kd = [0.8, 0.8, 0.8];
  var alpha = 1.0;
  String? map;
  void flush() {
    if (name == null) return;
    out[name] = ModelMaterial(
      color: _argb(kd[0], kd[1], kd[2], alpha),
      name: name,
      file: path,
      texture: map,
    );
  }

  for (final raw in LineSplitter.split(latin1.decode(file.readAsBytesSync()))) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    final parts = line.split(RegExp(r'\s+'));
    switch (parts[0]) {
      case 'newmtl':
        flush();
        name = line.substring(6).trim();
        kd = [0.8, 0.8, 0.8];
        alpha = 1;
        map = null;
      case 'Kd' when parts.length >= 4:
        kd = [for (final v in parts.sublist(1, 4)) double.tryParse(v) ?? 0.8];
      case 'd' when parts.length >= 2:
        alpha = double.tryParse(parts[1]) ?? 1;
      case 'Tr' when parts.length >= 2:
        alpha = 1 - (double.tryParse(parts[1]) ?? 0);
      case 'map_Kd' when parts.length >= 2:
        // Options (`-s 1 1 1`) come first; the file name is last.
        final rest = line.substring(6).trim();
        final file = rest.startsWith('-') ? parts.last : rest;
        map = p.normalize(p.join(p.dirname(path), file.replaceAll(r'\', '/')));
    }
  }
  flush();
  return out;
}
