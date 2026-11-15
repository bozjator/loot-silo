import 'dart:math' as math;

import 'package:flutter/rendering.dart';

import '../core/model_mesh.dart';
import '../core/model_raster.dart';
import 'model_picture.dart';

/// Where the camera looks from: a three-quarter view by default.
const defaultModelYaw = 35 * math.pi / 180;
const defaultModelPitch = 25 * math.pi / 180;

/// The camera never tilts past straight up or down.
const maxModelPitch = 89 * math.pi / 180;

/// Above this many triangles the viewer draws without edge smoothing while
/// the camera is being dragged.
const fastDragTriangles = 500000;

/// Draws a [ModelMesh] with the app's renderer (`native/model_raster.c`):
/// an orthographic camera that fits the mesh's bounding sphere to the
/// canvas (so it keeps its size while it turns), back faces culled, every
/// pixel showing its nearest surface, shaded from the normals with one
/// directional light (fixed to the camera) plus ambient light.
///
/// The picture is kept in [picture] and only drawn again when the camera,
/// the size, the mesh or a toggle changes. Small models are drawn at once;
/// big ones on worker isolates, the painter showing the last picture until
/// the new one is ready.
///
/// Textured materials use the textures set on the mesh's [RasterMesh];
/// [flat] ignores them. [wireframe] outlines the triangles facing the
/// camera, [grid] draws a floor under the model, and [fast] skips edge
/// smoothing (for large meshes while dragging).
class ModelPainter extends CustomPainter {
  factory ModelPainter({
    required ModelMesh mesh,
    double yaw = defaultModelYaw,
    double pitch = defaultModelPitch,
    double zoom = 1,
    Offset pan = Offset.zero,
    int textures = 0,
    Color? background,
    bool flat = false,
    bool wireframe = false,
    bool grid = false,
    bool fast = false,
    Color lineColor = const Color(0xFF000000),
    double pixelRatio = 1,
    ModelPicture? picture,
  }) => ModelPainter._(
    mesh,
    yaw,
    pitch,
    zoom,
    pan,
    textures,
    background,
    flat,
    wireframe,
    grid,
    fast,
    lineColor,
    pixelRatio,
    picture ?? ModelPicture(),
  );

  ModelPainter._(
    this.mesh,
    this.yaw,
    this.pitch,
    this.zoom,
    this.pan,
    this.textures,
    this.background,
    this.flat,
    this.wireframe,
    this.grid,
    this.fast,
    this.lineColor,
    this.pixelRatio,
    this.picture,
  ) : super(repaint: picture);

  final ModelMesh mesh;

  /// Turn around the up axis and tilt toward the viewer, in radians.
  final double yaw;
  final double pitch;

  /// 1 fits the model to the canvas.
  final double zoom;

  /// Screen offset of the model's centre, in logical pixels.
  final Offset pan;

  /// How many of the mesh's textures are loaded: a change repaints.
  final int textures;

  /// Filled first when given (the theme's stage colour).
  final Color? background;
  final bool flat;
  final bool wireframe;
  final bool grid;
  final bool fast;

  /// Wireframe and grid lines.
  final Color lineColor;

  /// Device pixels per logical pixel: the picture is drawn at the screen's
  /// own resolution.
  final double pixelRatio;
  final ModelPicture picture;

  /// The camera and picture size for a canvas of [size].
  RasterView viewFor(Size size) => RasterView(
    width: (size.width * pixelRatio).round().clamp(1, 8192),
    height: (size.height * pixelRatio).round().clamp(1, 8192),
    yaw: yaw,
    pitch: pitch,
    zoom: zoom,
    panX: pan.dx * pixelRatio,
    panY: pan.dy * pixelRatio,
    // Two samples a side smooth the edges; a dense screen is fine as is.
    samples: fast || pixelRatio >= 2 ? 1 : 2,
    textured: !flat,
    wireframe: wireframe,
    grid: grid,
    lineColor: lineColor.toARGB32(),
    lineWidth: math.max(1, pixelRatio),
  );

  @override
  void paint(Canvas canvas, Size size) {
    if (background case final bg?) {
      canvas.drawRect(Offset.zero & size, Paint()..color = bg);
    }
    if (mesh.indices.isEmpty || size.isEmpty) return;
    final image = picture.frame(mesh, viewFor(size));
    if (image == null) return;
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      Offset.zero & size,
      Paint()..filterQuality = FilterQuality.low,
    );
  }

  @override
  bool shouldRepaint(ModelPainter old) =>
      !identical(old.mesh, mesh) ||
      !identical(old.picture, picture) ||
      old.yaw != yaw ||
      old.pitch != pitch ||
      old.zoom != zoom ||
      old.pan != pan ||
      old.background != background ||
      old.flat != flat ||
      old.wireframe != wireframe ||
      old.grid != grid ||
      old.fast != fast ||
      old.lineColor != lineColor ||
      old.pixelRatio != pixelRatio ||
      old.textures != textures;
}
