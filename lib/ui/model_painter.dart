import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';

import '../core/model_mesh.dart';

/// Where the camera looks from: a three-quarter view by default.
const defaultModelYaw = 35 * math.pi / 180;
const defaultModelPitch = 25 * math.pi / 180;

/// Draws a [ModelMesh] with [Canvas.drawVertices]: an orthographic camera
/// that fits the mesh's bounding sphere to the canvas (so it keeps its size
/// while it turns), back faces culled, triangles sorted back to front and
/// flat-shaded with one directional light (fixed to the camera) plus
/// ambient light.
///
/// Textured materials draw with an [ImageShader] from [textures] (by
/// [ModelMaterial.texture]), one call per texture; a texture that isn't
/// loaded yet draws as its plain colour.
class ModelPainter extends CustomPainter {
  ModelPainter({
    required this.mesh,
    this.yaw = defaultModelYaw,
    this.pitch = defaultModelPitch,
    this.zoom = 1,
    this.pan = Offset.zero,
    this.textures = const {},
    this.background,
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
    final pos = mesh.positions;
    final idx = mesh.indices;
    if (idx.isEmpty || size.isEmpty) return;
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
    final n = mesh.vertexCount;
    final vx = Float32List(n), vy = Float32List(n), vz = Float32List(n);
    for (var i = 0; i < n; i++) {
      final x = pos[i * 3] - cx, y = pos[i * 3 + 1] - cy;
      final z = pos[i * 3 + 2] - cz;
      final x1 = x * cyw + z * syw;
      final z1 = -x * syw + z * cyw;
      vx[i] = x1;
      vy[i] = y * cp - z1 * sp;
      vz[i] = y * sp + z1 * cp;
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
    visible.sort((p, q) => depth[p].compareTo(depth[q]));

    // One draw call per texture (null: plain colours), the farthest group
    // first.
    final groups = <String?, List<int>>{};
    final uvs = mesh.uvs;
    for (final t in visible) {
      final tex = mesh.materials[mesh.triangleMaterials[t]].texture;
      final key = uvs != null && tex != null && textures.containsKey(tex)
          ? tex
          : null;
      (groups[key] ??= []).add(t);
    }
    final order = groups.keys.toList();
    if (order.length > 1) {
      double mean(List<int> l) =>
          l.fold(0.0, (s, t) => s + depth[t]) / l.length;
      final means = {for (final k in order) k: mean(groups[k]!)};
      order.sort((p, q) => means[p]!.compareTo(means[q]!));
    }
    for (final key in order) {
      final list = groups[key]!;
      final image = key == null ? null : textures[key];
      final points = Float32List(list.length * 6);
      final colors = Int32List(list.length * 3);
      final coords = image == null ? null : Float32List(list.length * 6);
      for (var k = 0; k < list.length; k++) {
        final t = list[k];
        final m = mesh.materials[mesh.triangleMaterials[t]];
        final c = m.color;
        final s = shade[t];
        // A texture is shaded on its own; its material colour tints it.
        final r = ((c >> 16 & 0xFF) * s).round().clamp(0, 255);
        final g = ((c >> 8 & 0xFF) * s).round().clamp(0, 255);
        final bl = ((c & 0xFF) * s).round().clamp(0, 255);
        final argb = (c & 0xFF000000) | r << 16 | g << 8 | bl;
        for (var j = 0; j < 3; j++) {
          final v = idx[t * 3 + j];
          points[k * 6 + j * 2] = ox + vx[v] * scale;
          points[k * 6 + j * 2 + 1] = oy - vy[v] * scale;
          colors[k * 3 + j] = argb;
          if (coords != null) {
            coords[k * 6 + j * 2] = uvs![v * 2] * image!.width;
            coords[k * 6 + j * 2 + 1] = uvs[v * 2 + 1] * image.height;
          }
        }
      }
      final vertices = ui.Vertices.raw(
        VertexMode.triangles,
        points,
        textureCoordinates: coords,
        colors: colors,
      );
      final paint = Paint()..color = const Color(0xFFFFFFFF);
      if (image != null) {
        final nearest = mesh.materials.any(
          (m) => m.texture == key && m.nearest,
        );
        paint.shader = ImageShader(
          image,
          TileMode.repeated,
          TileMode.repeated,
          Float64List.fromList([
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
            0,
            0,
            0,
            1,
          ]),
          filterQuality: nearest ? FilterQuality.none : FilterQuality.low,
        );
      }
      // Modulate multiplies the vertex colours with the paint (white, or
      // the texture), whichever side the engine treats as the source.
      canvas.drawVertices(vertices, BlendMode.modulate, paint);
      vertices.dispose();
    }
  }

  @override
  bool shouldRepaint(ModelPainter old) =>
      !identical(old.mesh, mesh) ||
      old.yaw != yaw ||
      old.pitch != pitch ||
      old.zoom != zoom ||
      old.pan != pan ||
      old.background != background ||
      old.textures.length != textures.length;
}
