import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';

import '../core/model_mesh.dart';

/// Where the camera looks from: a three-quarter view by default.
const defaultModelYaw = 35 * math.pi / 180;
const defaultModelPitch = 25 * math.pi / 180;

/// The camera never tilts past straight up or down.
const maxModelPitch = 89 * math.pi / 180;

/// Above this many triangles the viewer draws an unsorted pass while the
/// camera is being dragged.
const unsortedDragTriangles = 20000;

/// Draws a [ModelMesh] with [Canvas.drawVertices]: an orthographic camera
/// that fits the mesh's bounding sphere to the canvas (so it keeps its size
/// while it turns), back faces culled, triangles sorted back to front and
/// flat-shaded with one directional light (fixed to the camera) plus
/// ambient light.
///
/// Textured materials draw with an [ImageShader] from [textures] (by
/// [ModelMaterial.texture]), one call per texture; a texture that isn't
/// loaded yet draws as its plain colour. [flat] ignores textures,
/// [wireframe] outlines the front faces, [grid] draws a floor under the
/// model, and [sorted] false skips the back-to-front sort (faster, for
/// large meshes while dragging).
///
/// Give a [cache] to keep the projected triangles between paints: they are
/// only recomputed when the camera, the size or the mesh changes, so the
/// toggles redraw without sorting again.
class ModelPainter extends CustomPainter {
  ModelPainter({
    required this.mesh,
    this.yaw = defaultModelYaw,
    this.pitch = defaultModelPitch,
    this.zoom = 1,
    this.pan = Offset.zero,
    this.textures = const {},
    this.background,
    this.flat = false,
    this.wireframe = false,
    this.grid = false,
    this.sorted = true,
    this.lineColor = const Color(0xFF000000),
    this.cache,
  });

  final ModelMesh mesh;

  /// Turn around the up axis and tilt toward the viewer, in radians.
  final double yaw;
  final double pitch;

  /// 1 fits the model to the canvas.
  final double zoom;

  /// Screen offset of the model's centre, in logical pixels.
  final Offset pan;
  final Map<String, ui.Image> textures;

  /// Filled first when given (the theme's stage colour).
  final Color? background;
  final bool flat;
  final bool wireframe;
  final bool grid;
  final bool sorted;

  /// Wireframe and grid lines.
  final Color lineColor;
  final ModelPaintCache? cache;

  static const _ambient = 0.42;

  /// Toward the light, in view space: above, a little left, in front.
  static final _light = () {
    const x = -0.35, y = 0.8, z = 0.55;
    final len = math.sqrt(x * x + y * y + z * z);
    return (x / len, y / len, z / len);
  }();

  @override
  void paint(Canvas canvas, Size size) {
    if (background case final bg?) {
      canvas.drawRect(Offset.zero & size, Paint()..color = bg);
    }
    if (mesh.indices.isEmpty || size.isEmpty) return;
    final key = (mesh, yaw, pitch, zoom, pan, size, sorted);
    var frame = cache?._key == key ? cache!._frame : null;
    if (frame == null) {
      frame = _project(size);
      if (cache case final c?) {
        c
          .._key = key
          .._frame = frame
          .._projections += 1;
      }
    }
    if (grid) {
      canvas.drawRawPoints(
        ui.PointMode.lines,
        frame.grid,
        Paint()
          ..color = lineColor.withValues(alpha: 0.25)
          ..strokeWidth = 1,
      );
    }
    _fill(canvas, frame);
    if (wireframe) {
      canvas.drawRawPoints(
        ui.PointMode.lines,
        frame.edges,
        Paint()
          ..color = lineColor.withValues(alpha: 0.7)
          ..strokeWidth = 1,
      );
    }
  }

  /// The camera's projection of the front faces, in drawing order.
  _Frame _project(Size size) {
    final pos = mesh.positions;
    final idx = mesh.indices;
    final b = mesh.bounds;
    final cx = (b[0] + b[3]) / 2,
        cy = (b[1] + b[4]) / 2,
        cz = (b[2] + b[5]) / 2;
    final dx = b[3] - b[0], dy = b[4] - b[1], dz = b[5] - b[2];
    final radius = math.max(math.sqrt(dx * dx + dy * dy + dz * dz) / 2, 1e-9);
    final scale = size.shortestSide / (2 * radius) * 0.95 * zoom;
    final ox = size.width / 2 + pan.dx, oy = size.height / 2 + pan.dy;

    // View space: x right, y up, z toward the viewer.
    final cyw = math.cos(yaw), syw = math.sin(yaw);
    final cp = math.cos(pitch), sp = math.sin(pitch);
    (double, double, double) view(double x, double y, double z) {
      final x1 = x * cyw + z * syw;
      final z1 = -x * syw + z * cyw;
      return (x1, y * cp - z1 * sp, y * sp + z1 * cp);
    }

    final n = mesh.vertexCount;
    final vx = Float32List(n), vy = Float32List(n), vz = Float32List(n);
    for (var i = 0; i < n; i++) {
      final (x, y, z) = view(
        pos[i * 3] - cx,
        pos[i * 3 + 1] - cy,
        pos[i * 3 + 2] - cz,
      );
      vx[i] = x;
      vy[i] = y;
      vz[i] = z;
    }

    // Front faces with their depth and shade.
    final tris = idx.length ~/ 3;
    final depth = Float64List(tris);
    final shade = Float32List(tris);
    final visible = <int>[];
    final (lx, ly, lz) = _light;
    for (var t = 0; t < tris; t++) {
      final a = idx[t * 3], c1 = idx[t * 3 + 1], c2 = idx[t * 3 + 2];
      final ux = vx[c1] - vx[a], uy = vy[c1] - vy[a], uz = vz[c1] - vz[a];
      final wx = vx[c2] - vx[a], wy = vy[c2] - vy[a], wz = vz[c2] - vz[a];
      var nz = ux * wy - uy * wx;
      var nx = uy * wz - uz * wy, ny = uz * wx - ux * wz;
      if (nz <= 0) {
        final m = mesh.materials[mesh.triangleMaterials[t]];
        if (!m.doubleSided) continue;
        nx = -nx;
        ny = -ny;
        nz = -nz;
      }
      final len = math.sqrt(nx * nx + ny * ny + nz * nz);
      final lambert = len == 0
          ? 0.0
          : math.max(0.0, (nx * lx + ny * ly + nz * lz) / len);
      shade[t] = _ambient + (1 - _ambient) * lambert;
      depth[t] = vz[a] + vz[c1] + vz[c2];
      visible.add(t);
    }
    if (sorted) visible.sort((p, q) => depth[p].compareTo(depth[q]));

    double sx(int v) => ox + vx[v] * scale;
    double sy(int v) => oy - vy[v] * scale;

    // Groups by texture (null: plain colours), the farthest group first.
    final byTexture = <String?, List<int>>{};
    final uvs = mesh.uvs;
    for (final t in visible) {
      final tex = mesh.materials[mesh.triangleMaterials[t]].texture;
      (byTexture[uvs == null ? null : tex] ??= []).add(t);
    }
    final order = byTexture.keys.toList();
    if (order.length > 1) {
      double mean(List<int> l) =>
          l.fold(0.0, (s, t) => s + depth[t]) / l.length;
      final means = {for (final k in order) k: mean(byTexture[k]!)};
      order.sort((p, q) => means[p]!.compareTo(means[q]!));
    }
    final groups = <_Group>[];
    for (final key in order) {
      final list = byTexture[key]!;
      final points = Float32List(list.length * 6);
      final colors = Int32List(list.length * 3);
      final coords = key == null ? null : Float32List(list.length * 6);
      for (var k = 0; k < list.length; k++) {
        final t = list[k];
        final c = mesh.materials[mesh.triangleMaterials[t]].color;
        final s = shade[t];
        // A texture is shaded on its own; its material colour tints it.
        final r = ((c >> 16 & 0xFF) * s).round().clamp(0, 255);
        final g = ((c >> 8 & 0xFF) * s).round().clamp(0, 255);
        final bl = ((c & 0xFF) * s).round().clamp(0, 255);
        final argb = (c & 0xFF000000) | r << 16 | g << 8 | bl;
        for (var j = 0; j < 3; j++) {
          final v = idx[t * 3 + j];
          points[k * 6 + j * 2] = sx(v);
          points[k * 6 + j * 2 + 1] = sy(v);
          colors[k * 3 + j] = argb;
          if (coords != null) {
            coords[k * 6 + j * 2] = uvs![v * 2];
            coords[k * 6 + j * 2 + 1] = uvs[v * 2 + 1];
          }
        }
      }
      groups.add(_Group(key, points, colors, coords));
    }

    final edges = Float32List(visible.length * 12);
    for (var k = 0; k < visible.length; k++) {
      final t = visible[k];
      for (var j = 0; j < 3; j++) {
        final a = idx[t * 3 + j], c = idx[t * 3 + (j + 1) % 3];
        final at = k * 12 + j * 4;
        edges[at] = sx(a);
        edges[at + 1] = sy(a);
        edges[at + 2] = sx(c);
        edges[at + 3] = sy(c);
      }
    }

    // A floor of 10 × 10 squares under the model, 1.5 radii around it.
    const cells = 10;
    final half = radius * 1.5;
    final floor = b[1] - cy;
    final gridLines = Float32List((cells + 1) * 2 * 4);
    var g = 0;
    void line(double x0, double z0, double x1, double z1) {
      final (ax, ay, _) = view(x0, floor, z0);
      final (bx, by, _) = view(x1, floor, z1);
      gridLines[g++] = ox + ax * scale;
      gridLines[g++] = oy - ay * scale;
      gridLines[g++] = ox + bx * scale;
      gridLines[g++] = oy - by * scale;
    }

    for (var i = 0; i <= cells; i++) {
      final at = -half + 2 * half * i / cells;
      line(at, -half, at, half);
      line(-half, at, half, at);
    }
    return _Frame(groups, edges, gridLines, visible.length);
  }

  void _fill(Canvas canvas, _Frame frame) {
    final plain = <_Group>[];
    final drawn = <(ui.Image, _Group)>[];
    for (final group in frame.groups) {
      final image = flat || group.texture == null
          ? null
          : textures[group.texture];
      if (image == null) {
        plain.add(group);
      } else {
        drawn.add((image, group));
      }
    }
    // Textures that aren't shown draw with the plain colours, in one call.
    if (plain.isNotEmpty) _draw(canvas, _Group.merge(plain), null);
    for (final (image, group) in drawn) {
      _draw(canvas, group, image);
    }
  }

  void _draw(Canvas canvas, _Group group, ui.Image? image) {
    Float32List? coords;
    if (image != null) {
      final uv = group.coords!;
      coords = Float32List(uv.length);
      for (var i = 0; i < uv.length; i += 2) {
        coords[i] = uv[i] * image.width;
        coords[i + 1] = uv[i + 1] * image.height;
      }
    }
    final vertices = ui.Vertices.raw(
      VertexMode.triangles,
      group.points,
      textureCoordinates: coords,
      colors: group.colors,
    );
    final paint = Paint()..color = const Color(0xFFFFFFFF);
    if (image != null) {
      final nearest = mesh.materials.any(
        (m) => m.texture == group.texture && m.nearest,
      );
      paint.shader = ImageShader(
        image,
        TileMode.repeated,
        TileMode.repeated,
        Float64List.fromList([1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]),
        filterQuality: nearest ? FilterQuality.none : FilterQuality.low,
      );
    }
    // Modulate multiplies the vertex colours with the paint (white, or
    // the texture), whichever side the engine treats as the source.
    canvas.drawVertices(vertices, BlendMode.modulate, paint);
    vertices.dispose();
  }

  @override
  bool shouldRepaint(ModelPainter old) =>
      !identical(old.mesh, mesh) ||
      old.yaw != yaw ||
      old.pitch != pitch ||
      old.zoom != zoom ||
      old.pan != pan ||
      old.background != background ||
      old.flat != flat ||
      old.wireframe != wireframe ||
      old.grid != grid ||
      old.sorted != sorted ||
      old.lineColor != lineColor ||
      old.textures.length != textures.length;
}

/// Keeps a [ModelPainter]'s last projection; [projections] counts how
/// often it had to be computed.
class ModelPaintCache {
  Object? _key;
  _Frame? _frame;
  int get projections => _projections;
  var _projections = 0;

  /// Front faces in the last projection.
  int get visibleTriangles => _frame?.visible ?? 0;
}

class _Frame {
  _Frame(this.groups, this.edges, this.grid, this.visible);

  final List<_Group> groups;

  /// Screen line segments: x0, y0, x1, y1 each.
  final Float32List edges;
  final Float32List grid;
  final int visible;
}

class _Group {
  _Group(this.texture, this.points, this.colors, this.coords);

  final String? texture;
  final Float32List points;
  final Int32List colors;

  /// u, v (0–1) per point; null for plain colours.
  final Float32List? coords;

  static _Group merge(List<_Group> groups) {
    if (groups.length == 1) return groups.single;
    final points = Float32List(groups.fold(0, (s, g) => s + g.points.length));
    final colors = Int32List(groups.fold(0, (s, g) => s + g.colors.length));
    var p = 0, c = 0;
    for (final g in groups) {
      points.setAll(p, g.points);
      colors.setAll(c, g.colors);
      p += g.points.length;
      c += g.colors.length;
    }
    return _Group(null, points, colors, null);
  }
}
