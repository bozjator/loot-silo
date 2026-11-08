import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../core/material_sets.dart';

/// The compiled `shaders/material_preview.frag`, loaded once.
Future<ui.FragmentProgram>? _program;
Future<ui.FragmentProgram> materialProgram() =>
    _program ??= ui.FragmentProgram.fromAsset('shaders/material_preview.frag');

/// What the lit preview draws.
enum PreviewShape { sphere, plane }

/// One map decoded for the shader, with the file's own pixel size (the
/// image itself may be scaled down to [maxMapSide]).
class DecodedMap {
  const DecodedMap(this.image, this.width, this.height);

  final ui.Image image;
  final int width;
  final int height;
}

/// Longest side a map is decoded at for the preview.
const maxMapSide = 1024;

/// Decodes [path] at most [maxMapSide] wide or high; null when it can't be
/// read.
Future<DecodedMap?> decodeMap(String path) async {
  try {
    final bytes = await File(path).readAsBytes();
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    final descriptor = await ui.ImageDescriptor.encoded(buffer);
    final w = descriptor.width, h = descriptor.height;
    final scale = math.min(1.0, maxMapSide / math.max(w, h));
    final codec = await descriptor.instantiateCodec(
      targetWidth: (w * scale).round(),
      targetHeight: (h * scale).round(),
    );
    final frame = await codec.getNextFrame();
    codec.dispose();
    descriptor.dispose();
    buffer.dispose();
    return DecodedMap(frame.image, w, h);
  } on Object {
    return null;
  }
}

/// The maps the shader reads, by role (null: not in the material).
class PreviewMaps {
  const PreviewMaps({
    this.color,
    this.normal,
    this.normalDX = false,
    this.roughness,
    this.metalness,
    this.ao,
  });

  final ui.Image? color;
  final ui.Image? normal;

  /// [normal] is a DirectX map (green down).
  final bool normalDX;
  final ui.Image? roughness;
  final ui.Image? metalness;
  final ui.Image? ao;

  /// Width / height of the Color map (else the Normal map); 1 without.
  double get aspect => switch (color ?? normal) {
    final i? when i.height > 0 => i.width / i.height,
    _ => 1,
  };

  /// The paths of [m]'s maps the shader uses: Color, Normal (GL before
  /// DX), Roughness, Metalness, AO.
  static Map<MapRole, String> pathsOf(MaterialSet m) => {
    for (final role in [
      MapRole.color,
      MapRole.roughness,
      MapRole.metalness,
      MapRole.ao,
    ])
      if (m.mapOf(role) case final map?) role: map.path,
    if ((m.mapOf(MapRole.normalGL) ?? m.mapOf(MapRole.normalDX)) case final n?)
      n.role: n.path,
  };
}

/// The float uniforms, in the shader's order: size, mode, zoom, tiling,
/// yaw, aspect, light (3), the five "has" flags and the DX flag.
List<double> previewUniforms({
  required Size size,
  required PreviewShape shape,
  required double zoom,
  required double tiling,
  required double yaw,
  required List<double> light,
  required PreviewMaps maps,
}) => [
  size.width,
  size.height,
  shape == PreviewShape.sphere ? 0 : 1,
  zoom,
  tiling,
  yaw,
  maps.aspect,
  ...light,
  maps.color == null ? 0 : 1,
  maps.normal == null ? 0 : 1,
  maps.roughness == null ? 0 : 1,
  maps.metalness == null ? 0 : 1,
  maps.ao == null ? 0 : 1,
  maps.normalDX ? 1 : 0,
];

/// The direction towards a light at [azimuth] (0: in front, positive: to
/// the right) and [elevation] (positive: above), view space.
List<double> lightDirection(double azimuth, double elevation) => [
  math.sin(azimuth) * math.cos(elevation),
  math.sin(elevation),
  math.cos(azimuth) * math.cos(elevation),
];

/// Draws the lit sphere or tile with [program].
class MaterialPreviewPainter extends CustomPainter {
  MaterialPreviewPainter({
    required this.program,
    required this.blank,
    required this.maps,
    required this.shape,
    required this.zoom,
    required this.tiling,
    required this.yaw,
    required this.azimuth,
    required this.elevation,
  });

  final ui.FragmentProgram program;

  /// Bound for every missing map (the shader ignores it).
  final ui.Image blank;
  final PreviewMaps maps;
  final PreviewShape shape;
  final double zoom;
  final double tiling;
  final double yaw;
  final double azimuth;
  final double elevation;

  @override
  void paint(Canvas canvas, Size size) {
    final shader = program.fragmentShader();
    final floats = previewUniforms(
      size: size,
      shape: shape,
      zoom: zoom,
      tiling: tiling,
      yaw: yaw,
      light: lightDirection(azimuth, elevation),
      maps: maps,
    );
    for (var i = 0; i < floats.length; i++) {
      shader.setFloat(i, floats[i]);
    }
    final images = [
      maps.color,
      maps.normal,
      maps.roughness,
      maps.metalness,
      maps.ao,
    ];
    for (var i = 0; i < images.length; i++) {
      shader.setImageSampler(i, images[i] ?? blank);
    }
    canvas.drawRect(Offset.zero & size, Paint()..shader = shader);
    shader.dispose();
  }

  @override
  bool shouldRepaint(MaterialPreviewPainter old) =>
      old.maps != maps ||
      old.shape != shape ||
      old.zoom != zoom ||
      old.tiling != tiling ||
      old.yaw != yaw ||
      old.azimuth != azimuth ||
      old.elevation != elevation;
}

/// A 1 × 1 white image for unbound samplers.
Future<ui.Image> blankImage() {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawPaint(Paint()..color = const Color(0xFFFFFFFF));
  return recorder.endRecording().toImage(1, 1);
}
