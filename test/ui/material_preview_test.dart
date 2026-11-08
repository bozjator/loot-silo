import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loot_silo/core/material_sets.dart';
import 'package:loot_silo/ui/material_preview.dart';

Future<ui.Image> solid(Color c) {
  final r = ui.PictureRecorder();
  Canvas(r).drawPaint(Paint()..color = c);
  return r.endRecording().toImage(1, 1);
}

/// Draws the preview at 64 × 64 and returns its RGBA bytes.
Future<ByteData> render({
  required PreviewMaps maps,
  PreviewShape shape = PreviewShape.sphere,
  double azimuth = defaultAzimuthForTest,
  double elevation = 0,
}) async {
  final program = await materialProgram();
  final recorder = ui.PictureRecorder();
  MaterialPreviewPainter(
    program: program,
    blank: await blankImage(),
    maps: maps,
    shape: shape,
    zoom: 0.9,
    tiling: 1,
    yaw: 0,
    azimuth: azimuth,
    elevation: elevation,
  ).paint(Canvas(recorder), const Size(64, 64));
  final image = await recorder.endRecording().toImage(64, 64);
  return (await image.toByteData())!;
}

const defaultAzimuthForTest = 0.0;

(int, int, int, int) px(ByteData d, int x, int y) {
  final o = (y * 64 + x) * 4;
  return (
    d.getUint8(o),
    d.getUint8(o + 1),
    d.getUint8(o + 2),
    d.getUint8(o + 3),
  );
}

void main() {
  test('uniforms in the shader order; missing maps flagged off', () {
    final u = previewUniforms(
      size: const Size(300, 200),
      shape: PreviewShape.plane,
      zoom: 0.8,
      tiling: 3,
      yaw: 0.5,
      light: const [0, 0, 1],
      maps: const PreviewMaps(normalDX: true),
    );
    expect(u, [300, 200, 1, 0.8, 3, 0.5, 1, 0, 0, 1, 0, 0, 0, 0, 0, 1]);
  });

  test('the maps\' aspect comes from the Color map', () async {
    final r = ui.PictureRecorder();
    Canvas(r).drawPaint(Paint());
    final tall = await r.endRecording().toImage(512, 1024);
    expect(PreviewMaps(color: tall).aspect, 0.5);
    expect(PreviewMaps(normal: tall).aspect, 0.5);
    expect(const PreviewMaps().aspect, 1);
  });

  test('light direction: front, right, above', () {
    expect(lightDirection(0, 0), [0, 0, 1]);
    final right = lightDirection(1.5707963, 0);
    expect(right[0], closeTo(1, 1e-6));
    expect(lightDirection(0, 1.5707963)[1], closeTo(1, 1e-6));
  });

  test('the shader reads GL normals before DX ones', () {
    const both = MaterialSet(
      key: 'a',
      name: 'a',
      maps: [
        MaterialMap(MapRole.color, 'a_Color.png'),
        MaterialMap(MapRole.normalGL, 'a_NormalGL.png'),
        MaterialMap(MapRole.normalDX, 'a_NormalDX.png'),
        MaterialMap(MapRole.height, 'a_Height.png'),
      ],
    );
    expect(PreviewMaps.pathsOf(both), {
      MapRole.color: 'a_Color.png',
      MapRole.normalGL: 'a_NormalGL.png',
    });
    const dx = MaterialSet(
      key: 'b',
      name: 'b',
      maps: [MaterialMap(MapRole.normalDX, 'b_NormalDX.png')],
    );
    expect(PreviewMaps.pathsOf(dx), {MapRole.normalDX: 'b_NormalDX.png'});
  });

  group('the shader runs in flutter test', () {
    test('a red sphere: lit centre, transparent corners', () async {
      final d = await render(
        maps: PreviewMaps(color: await solid(const Color(0xFFFF0000))),
      );
      final (r, g, b, a) = px(d, 32, 32);
      expect(a, 255);
      // Red, with some white from the highlight.
      expect(r, greaterThan(g + 80));
      expect(r, greaterThan(b + 80));
      expect(px(d, 1, 1).$4, 0);
    });

    test('the plane fills its square; no Color map is light grey', () async {
      final d = await render(
        maps: const PreviewMaps(),
        shape: PreviewShape.plane,
      );
      expect(px(d, 5, 5).$4, 255);
      final (r, g, b, _) = px(d, 32, 32);
      expect(r, greaterThan(120));
      expect((r - g).abs(), lessThan(3));
      expect((r - b).abs(), lessThan(3));
    });

    test('a light from the left lights the left side', () async {
      final maps = PreviewMaps(color: await solid(const Color(0xFFFFFFFF)));
      final d = await render(maps: maps, azimuth: -1.2);
      expect(px(d, 12, 32).$1, greaterThan(px(d, 52, 32).$1 + 40));
    });

    test('a normal map tilts the surface (DX flips green)', () async {
      // Normals pointing up (GL: green high).
      final up = await solid(const Color(0xFF80E0A0));
      final white = await solid(const Color(0xFFFFFFFF));
      Future<int> centre(bool dx) async => px(
        await render(
          maps: PreviewMaps(color: white, normal: up, normalDX: dx),
          shape: PreviewShape.plane,
          elevation: 1.0,
        ),
        32,
        32,
      ).$1;
      // Light from above: the GL map faces it, the DX one away.
      expect(await centre(false), greaterThan(await centre(true) + 20));
    });
  });
}
