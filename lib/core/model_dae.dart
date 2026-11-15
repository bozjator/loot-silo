import 'dart:math' as math;
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'mini_xml.dart';
import 'model_mesh.dart';

/// Reads a COLLADA `.dae` file: the visual scene's geometries in their
/// node transforms (matrix, translate, rotate, scale), triangles, polygon
/// lists and polygons (fanned), normals and texture coordinates, and each
/// material's diffuse colour or texture. `up_axis` Z or X is turned to
/// y-up. Skins are drawn in their bind shape; animations are ignored.
ModelMesh readDae(String path) {
  final XmlNode root;
  try {
    root = parseXml(modelFileText(modelFileBytes(path)));
  } on FormatException {
    throw const ModelReadError('Not a valid COLLADA file');
  }
  if (root.name != 'COLLADA') {
    throw const ModelReadError('Not a valid COLLADA file');
  }
  try {
    return _Dae(root, p.dirname(path)).read();
  } on FormatException {
    throw const ModelReadError('Not a valid COLLADA file');
  } on RangeError {
    throw const ModelReadError('Index out of range');
  }
}

class _Source {
  _Source(this.values, this.stride);

  final Float64List values;
  final int stride;
}

class _Dae {
  _Dae(this.root, this.dir) {
    for (final n in root.descendants) {
      final id = n['id'];
      if (id != null) _byId[id] = n;
    }
  }

  final XmlNode root;
  final String dir;
  final _byId = <String, XmlNode>{};
  final b = MeshBuilder();
  final _sources = <String, _Source>{};

  /// Material id → index in the builder's list.
  final _materials = <String, int>{};

  XmlNode? _ref(String? url) =>
      url == null ? null : _byId[url.startsWith('#') ? url.substring(1) : url];

  ModelMesh read() {
    final up = root.path(['asset', 'up_axis'])?.text.trim();
    // Column-major, like the node matrices.
    final axis = switch (up) {
      'Z_UP' => _matrix([1, 0, 0, 0, 0, 0, -1, 0, 0, 1, 0, 0, 0, 0, 0, 1]),
      'X_UP' => _matrix([0, 1, 0, 0, -1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]),
      _ => _identity(),
    };
    final scene = _ref(root.path(['scene', 'instance_visual_scene'])?['url']);
    final scenes = scene != null
        ? [scene]
        : [
            for (final l in root.all('library_visual_scenes'))
              ...l.all('visual_scene'),
          ];
    for (final s in scenes) {
      for (final n in s.all('node')) {
        _node(n, axis, 0);
      }
    }
    if (b.idx.length == 0) {
      // No scene uses them: draw every geometry where it is.
      for (final l in root.all('library_geometries')) {
        for (final g in l.all('geometry')) {
          _geometry(g, axis, const {});
        }
      }
    }
    return b.build();
  }

  void _node(XmlNode node, Float64List parent, int depth) {
    if (depth > 64) throw const ModelReadError('Node tree too deep');
    var m = parent;
    for (final c in node.children) {
      switch (c.name) {
        case 'matrix':
          final v = _floats(c.text);
          if (v.length >= 16) {
            // Written row by row.
            m = _mul(
              m,
              _matrix([
                for (var col = 0; col < 4; col++)
                  for (var row = 0; row < 4; row++) v[row * 4 + col],
              ]),
            );
          }
        case 'translate':
          final v = _floats(c.text);
          if (v.length >= 3) {
            m = _mul(
              m,
              _matrix([
                1,
                0,
                0,
                0,
                0,
                1,
                0,
                0,
                0,
                0,
                1,
                0,
                v[0],
                v[1],
                v[2],
                1,
              ]),
            );
          }
        case 'scale':
          final v = _floats(c.text);
          if (v.length >= 3) {
            m = _mul(
              m,
              _matrix([
                v[0],
                0,
                0,
                0,
                0,
                v[1],
                0,
                0,
                0,
                0,
                v[2],
                0,
                0,
                0,
                0,
                1,
              ]),
            );
          }
        case 'rotate':
          final v = _floats(c.text);
          if (v.length >= 4) m = _mul(m, _rotation(v[0], v[1], v[2], v[3]));
      }
    }
    for (final c in node.children) {
      switch (c.name) {
        case 'instance_geometry':
          final g = _ref(c['url']);
          if (g != null) _geometry(g, m, _bindings(c));
        case 'instance_controller':
          // A skin or morph: its source geometry, in the bind shape.
          final ctrl = _ref(c['url']);
          final inner = ctrl?.child('skin') ?? ctrl?.child('morph');
          final g = _ref(inner?['source']);
          if (g != null && g.name == 'geometry') {
            var shape = m;
            final bind = inner?.child('bind_shape_matrix');
            if (bind != null) {
              final v = _floats(bind.text);
              if (v.length >= 16) {
                shape = _mul(
                  m,
                  _matrix([
                    for (var col = 0; col < 4; col++)
                      for (var row = 0; row < 4; row++) v[row * 4 + col],
                  ]),
                );
              }
            }
            _geometry(g, shape, _bindings(c));
          }
        case 'instance_node':
          final n = _ref(c['url']);
          if (n != null) _node(n, m, depth + 1);
        case 'node':
          _node(c, m, depth + 1);
      }
    }
  }

  /// Material symbols of an instance → material ids.
  Map<String, String> _bindings(XmlNode instance) => {
    for (final im
        in instance
                .path(['bind_material', 'technique_common'])
                ?.all('instance_material') ??
            const <XmlNode>[])
      if (im['symbol'] != null && im['target'] != null)
        im['symbol']!: im['target']!,
  };

  _Source? _source(String? url) {
    final node = _ref(url);
    if (node == null) return null;
    final id = node['id']!;
    return _sources.putIfAbsent(id, () {
      final array = node.child('float_array');
      final accessor = node.path(['technique_common', 'accessor']);
      return _Source(
        array == null ? Float64List(0) : _floats(array.text),
        int.tryParse(accessor?['stride'] ?? '') ?? 3,
      );
    });
  }

  void _geometry(XmlNode geometry, Float64List m, Map<String, String> bound) {
    final mesh = geometry.child('mesh');
    if (mesh == null) return;
    final flip = _det3(m) < 0;
    for (final prim in mesh.children) {
      final kind = prim.name;
      if (kind != 'triangles' && kind != 'polylist' && kind != 'polygons') {
        continue;
      }
      _Source? pos, nrm, uv;
      var posAt = 0, nrmAt = -1, uvAt = -1, stride = 0;
      for (final input in prim.all('input')) {
        final offset = int.tryParse(input['offset'] ?? '') ?? 0;
        stride = math.max(stride, offset + 1);
        switch (input['semantic']) {
          case 'VERTEX':
            // The <vertices> element names the positions (and sometimes
            // the normals) that share the index.
            final vertices = _ref(input['source']);
            for (final vi in vertices?.all('input') ?? const <XmlNode>[]) {
              if (vi['semantic'] == 'POSITION') {
                pos = _source(vi['source']);
                posAt = offset;
              } else if (vi['semantic'] == 'NORMAL') {
                nrm = _source(vi['source']);
                nrmAt = offset;
              } else if (vi['semantic'] == 'TEXCOORD' && uv == null) {
                uv = _source(vi['source']);
                uvAt = offset;
              }
            }
          case 'NORMAL':
            nrm = _source(input['source']);
            nrmAt = offset;
          case 'TEXCOORD':
            // The first set only.
            if (uvAt < 0 || input['set'] == '0') {
              uv = _source(input['source']);
              uvAt = offset;
            }
        }
      }
      final positions = pos;
      if (positions == null || stride == 0) continue;
      final symbol = prim['material'];
      final material = _material(
        symbol == null ? null : (bound[symbol] ?? symbol),
      );

      // One mesh vertex per distinct index tuple.
      final seen = <int, int>{};
      final radix =
          math.max(
            positions.values.length,
            math.max(nrm?.values.length ?? 0, uv?.values.length ?? 0),
          ) +
          1;
      int vertex(List<int> p, int at) {
        final pi = p[at + posAt];
        final ni = nrmAt < 0 ? -1 : p[at + nrmAt];
        final ti = uvAt < 0 ? -1 : p[at + uvAt];
        final key = (pi * radix + ni + 1) * radix + ti + 1;
        return seen.putIfAbsent(key, () {
          final ps = positions.stride, v = positions.values;
          final x = v[pi * ps], y = v[pi * ps + 1], z = v[pi * ps + 2];
          b.pos
            ..add(m[0] * x + m[4] * y + m[8] * z + m[12])
            ..add(m[1] * x + m[5] * y + m[9] * z + m[13])
            ..add(m[2] * x + m[6] * y + m[10] * z + m[14]);
          final normals = nrm;
          if (normals != null && ni >= 0) {
            final ns = normals.stride, n = normals.values;
            final nx = n[ni * ns], ny = n[ni * ns + 1], nz = n[ni * ns + 2];
            var tx = m[0] * nx + m[4] * ny + m[8] * nz;
            var ty = m[1] * nx + m[5] * ny + m[9] * nz;
            var tz = m[2] * nx + m[6] * ny + m[10] * nz;
            final len = math.sqrt(tx * tx + ty * ty + tz * tz);
            if (len > 0) {
              tx /= len;
              ty /= len;
              tz /= len;
            }
            b.nrm
              ..add(tx)
              ..add(ty)
              ..add(tz);
          } else {
            b.nrm
              ..add(double.nan)
              ..add(double.nan)
              ..add(double.nan);
          }
          final coords = uv;
          if (coords != null && ti >= 0) {
            final ts = coords.stride, t = coords.values;
            // COLLADA's t points up; the mesh keeps image orientation.
            b.uv
              ..add(t[ti * ts])
              ..add(1 - t[ti * ts + 1]);
            b.hasUv = true;
          } else {
            b.uv
              ..add(0)
              ..add(0);
          }
          return b.vertexCount - 1;
        });
      }

      void polygon(List<int> p, int first, int corners) {
        if (corners < 3) return;
        final ids = [
          for (var c = 0; c < corners; c++) vertex(p, first + c * stride),
        ];
        for (var i = 1; i + 1 < corners; i++) {
          b.idx
            ..add(ids[0])
            ..add(flip ? ids[i + 1] : ids[i])
            ..add(flip ? ids[i] : ids[i + 1]);
          b.triMat.add(material);
        }
      }

      if (kind == 'polygons') {
        for (final poly in prim.all('p')) {
          final p = _ints(poly.text);
          polygon(p, 0, p.length ~/ stride);
        }
        continue;
      }
      final p = _ints(prim.child('p')?.text ?? '');
      if (kind == 'triangles') {
        for (var at = 0; at + 3 * stride <= p.length; at += 3 * stride) {
          polygon(p, at, 3);
        }
      } else {
        var at = 0;
        for (final corners in _ints(prim.child('vcount')?.text ?? '')) {
          if (at + corners * stride > p.length) break;
          polygon(p, at, corners);
          at += corners * stride;
        }
      }
    }
  }

  int? _plain;
  int _material(String? url) {
    final node = _ref(url);
    if (node == null || node.name != 'material') {
      return _plain ??= () {
        b.materials.add(ModelMaterial.plain);
        return b.materials.length - 1;
      }();
    }
    return _materials.putIfAbsent(node['id']!, () {
      final effect = _ref(node.child('instance_effect')?['url']);
      final profile = effect?.child('profile_COMMON');
      XmlNode? diffuse;
      for (final shader
          in profile?.child('technique')?.children ?? const <XmlNode>[]) {
        diffuse ??= shader.child('diffuse');
      }
      var color = ModelMaterial.plain.color;
      String? texture;
      final rgba = _floats(diffuse?.child('color')?.text ?? '');
      if (rgba.length >= 3) {
        color = argbColor(rgba[0], rgba[1], rgba[2], 1);
      }
      final sampler = diffuse?.child('texture')?['texture'];
      if (sampler != null && profile != null) {
        texture = _image(profile, sampler);
        if (texture != null) color = 0xFFFFFFFF;
      }
      b.materials.add(
        ModelMaterial(
          color: color,
          name: node['name'] ?? node['id'],
          texture: texture,
          nearest: false,
        ),
      );
      return b.materials.length - 1;
    });
  }

  /// The image file behind a sampler sid: sampler2D → surface → image, or
  /// an image id used directly.
  String? _image(XmlNode profile, String sid) {
    XmlNode? param(String sid) {
      for (final n in profile.descendants) {
        if (n.name == 'newparam' && n['sid'] == sid) return n;
      }
      return null;
    }

    var image = sid;
    final sampler = param(sid)?.child('sampler2D');
    if (sampler != null) {
      final source = sampler.child('source')?.text.trim();
      final direct = sampler.child('instance_image')?['url'];
      if (direct != null) {
        image = direct.startsWith('#') ? direct.substring(1) : direct;
      } else if (source != null) {
        final surface = param(source)?.child('surface');
        image = surface?.child('init_from')?.text.trim() ?? source;
      }
    }
    final node = _byId[image];
    if (node == null || node.name != 'image') return null;
    final from = node.child('init_from');
    final file = (from?.child('ref')?.text ?? from?.text ?? '').trim();
    if (file.isEmpty) return null;
    var path = file;
    if (path.startsWith('file://')) path = Uri.parse(path).toFilePath();
    path = Uri.decodeFull(path).replaceAll(r'\', '/');
    return p.normalize(p.isAbsolute(path) ? path : p.join(dir, path));
  }

  static final _space = RegExp(r'\s+');

  static Float64List _floats(String text) {
    final parts = text.trim().split(_space);
    final out = Float64List(parts.length);
    var n = 0;
    for (final s in parts) {
      if (s.isEmpty) continue;
      out[n++] = double.parse(s);
    }
    return n == out.length ? out : Float64List.sublistView(out, 0, n);
  }

  static List<int> _ints(String text) {
    final parts = text.trim().split(_space);
    final out = Int32List(parts.length);
    var n = 0;
    for (final s in parts) {
      if (s.isEmpty) continue;
      out[n++] = int.parse(s);
    }
    return n == out.length ? out : Int32List.sublistView(out, 0, n);
  }

  static Float64List _matrix(List<num> m) =>
      Float64List.fromList([for (final v in m) v.toDouble()]);

  static Float64List _identity() =>
      _matrix([1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]);

  /// A turn of [degrees] around the axis (x, y, z), column-major.
  static Float64List _rotation(double x, double y, double z, double degrees) {
    final len = math.sqrt(x * x + y * y + z * z);
    if (len == 0) return _identity();
    x /= len;
    y /= len;
    z /= len;
    final a = degrees * math.pi / 180;
    final c = math.cos(a), s = math.sin(a), t = 1 - c;
    return _matrix([
      t * x * x + c,
      t * x * y + s * z,
      t * x * z - s * y,
      0,
      t * x * y - s * z,
      t * y * y + c,
      t * y * z + s * x,
      0,
      t * x * z + s * y,
      t * y * z - s * x,
      t * z * z + c,
      0,
      0,
      0,
      0,
      1,
    ]);
  }

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
