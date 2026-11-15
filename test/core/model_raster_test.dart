import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:loot_silo/core/model_mesh.dart';
import 'package:loot_silo/core/model_raster.dart';
import 'package:loot_silo/core/model_render_pool.dart';

import '../helpers/models.dart';

/// Quads facing +z (toward the default camera at yaw 0, pitch 0), each
/// `(x0, y0, x1, y1, z, material)`.
ModelMesh quads(
  List<(double, double, double, double, double, int)> list, {
  List<ModelMaterial> materials = const [ModelMaterial.plain],
  bool uvs = false,
  bool facetted = false,
}) {
  final pos = <double>[], nrm = <double>[], uv = <double>[];
  final idx = <int>[], mats = <int>[];
  for (final (x0, y0, x1, y1, z, m) in list) {
    final first = pos.length ~/ 3;
    pos.addAll([x0, y0, z, x1, y0, z, x1, y1, z, x0, y1, z]);
    for (var i = 0; i < 4; i++) {
      nrm.addAll([0, 0, 1]);
    }
    // v points down: the top of the image is at the quad's top.
    uv.addAll([0, 1, 1, 1, 1, 0, 0, 0]);
    idx.addAll([first, first + 1, first + 2, first, first + 2, first + 3]);
    mats.addAll([m, m]);
  }
  return ModelMesh(
    positions: Float32List.fromList(pos),
    normals: Float32List.fromList(nrm),
    indices: Uint32List.fromList(idx),
    triangleMaterials: Uint16List.fromList(mats),
    materials: materials,
    uvs: uvs ? Float32List.fromList(uv) : null,
    facetted: facetted,
  );
}

/// A bumpy ball of `rings × 2·rings × 2` triangles.
ModelMesh ball(int rings) {
  final segs = rings * 2;
  final n = (rings + 1) * (segs + 1);
  final pos = Float32List(n * 3), nrm = Float32List(n * 3);
  var k = 0;
  for (var r = 0; r <= rings; r++) {
    final th = math.pi * r / rings;
    for (var s = 0; s <= segs; s++) {
      final ph = 2 * math.pi * s / segs;
      final x = math.sin(th) * math.cos(ph), y = math.cos(th);
      final z = math.sin(th) * math.sin(ph);
      final bump = 1 + 0.15 * math.sin(ph * 12) * math.sin(th * 12);
      pos.setAll(k, [x * bump, y * bump, z * bump]);
      nrm.setAll(k, [x, y, z]);
      k += 3;
    }
  }
  final idx = Uint32List(rings * segs * 6);
  k = 0;
  for (var r = 0; r < rings; r++) {
    for (var s = 0; s < segs; s++) {
      final a = r * (segs + 1) + s, b = a + segs + 1;
      idx.setAll(k, [a, a + 1, b, a + 1, b + 1, b]);
      k += 6;
    }
  }
  return ModelMesh(
    positions: pos,
    normals: nrm,
    indices: idx,
    triangleMaterials: Uint16List(idx.length ~/ 3),
    materials: const [ModelMaterial.plain],
  );
}

void main() {
  final context = RasterContext();

  Uint8List render(ModelMesh mesh, RasterView view) {
    final out = Uint8List(view.width * view.height * 4);
    expect(context.render(RasterMesh.of(mesh), view, out), isTrue);
    return out;
  }

  /// R, G, B, A at ([x], [y]).
  List<int> at(Uint8List px, RasterView view, int x, int y) =>
      px.sublist((y * view.width + x) * 4, (y * view.width + x) * 4 + 4);

  const red = ModelMaterial(color: 0xFFFF0000);
  const blue = ModelMaterial(color: 0xFF0000FF);
  const view = RasterView(width: 64, height: 64);

  test('the nearest surface shows, whatever the order in the file', () {
    // A small red quad in front of a big blue one, and the other way round.
    const near = (-0.4, -0.4, 0.4, 0.4, 0.5, 0);
    const far = (-1.0, -1.0, 1.0, 1.0, -0.5, 1);
    for (final order in [
      [near, far],
      [far, near],
    ]) {
      final px = render(quads(order, materials: const [red, blue]), view);
      final centre = at(px, view, 32, 32);
      expect(centre[0], greaterThan(100), reason: 'red in front');
      expect(centre[2], 0);
      expect(centre[3], 255);
      final side = at(px, view, 12, 32);
      expect(side[2], greaterThan(100), reason: 'blue around it');
      expect(side[0], 0);
      // Outside the model the picture is see-through.
      expect(at(px, view, 1, 1), [0, 0, 0, 0]);
    }
  });

  test('surfaces that cut through each other meet in a straight line', () {
    // Two quads crossing at x = 0: sorting whole triangles can't draw
    // this, a depth per pixel does.
    final pos = Float32List.fromList([
      -1, -1, -1, 1, -1, 1, 1, 1, 1, -1, 1, -1, // rising to the right
      -1, -1, 1, 1, -1, -1, 1, 1, -1, -1, 1, 1, // falling to the right
    ]);
    final mesh = ModelMesh(
      positions: pos,
      normals: Float32List.fromList([
        for (var i = 0; i < 4; i++) ...[-0.7, 0, 0.7],
        for (var i = 0; i < 4; i++) ...[0.7, 0, 0.7],
      ]),
      indices: Uint32List.fromList([0, 1, 2, 0, 2, 3, 4, 5, 6, 4, 6, 7]),
      triangleMaterials: Uint16List.fromList([0, 0, 1, 1]),
      materials: const [red, blue],
    );
    final px = render(mesh, view);
    for (final y in [20, 32, 44]) {
      final left = at(px, view, 20, y), right = at(px, view, 44, y);
      expect(
        left[2],
        greaterThan(left[0]),
        reason: 'blue is nearer on the left',
      );
      expect(right[0], greaterThan(right[2]), reason: 'red on the right');
    }
  });

  test('back faces are culled unless the material is double-sided', () {
    // Seen from behind (yaw 180°).
    const behind = RasterView(width: 64, height: 64, yaw: math.pi);
    const quad = (-1.0, -1.0, 1.0, 1.0, 0.0, 0);
    expect(at(render(quads([quad]), behind), behind, 32, 32)[3], 0);
    final both = quads(
      [quad],
      materials: const [ModelMaterial(color: 0xFFFFFFFF, doubleSided: true)],
    );
    final px = at(render(both, behind), behind, 32, 32);
    expect(px[3], 255);
    // Lit from its back like the front is from the front.
    expect(px[0], at(render(both, view), view, 32, 32)[0]);
  });

  test('a see-through material blends over what is behind it', () {
    const glass = ModelMaterial(color: 0x80FF0000);
    final px = render(
      quads(
        const [(-0.4, -0.4, 0.4, 0.4, 0.5, 0), (-1.0, -1.0, 1.0, 1.0, -0.5, 1)],
        materials: const [glass, blue],
      ),
      view,
    );
    final centre = at(px, view, 32, 32);
    expect(centre[0], greaterThan(40));
    expect(centre[2], greaterThan(40));
    expect(centre[3], 255);
    // Alone, it is half see-through (premultiplied).
    final alone = render(
      quads(const [(-1.0, -1.0, 1.0, 1.0, 0.0, 0)], materials: const [glass]),
      view,
    );
    expect(at(alone, view, 32, 32)[3], closeTo(128, 1));
  });

  test('shading follows the normals; a facetted mesh ignores them', () {
    // Normals turned away from the light on the left corners.
    final mesh = quads(const [(-1.0, -1.0, 1.0, 1.0, 0.0, 0)]);
    mesh.normals.setAll(0, [0, -1, 0]);
    mesh.normals.setAll(9, [0, -1, 0]);
    final px = render(mesh, view);
    expect(
      at(px, view, 50, 32)[0],
      greaterThan(at(px, view, 14, 32)[0] + 20),
      reason: 'brighter toward the lit corners',
    );
    final flat = quads(const [(-1.0, -1.0, 1.0, 1.0, 0.0, 0)], facetted: true);
    flat.normals.setAll(0, [0, -1, 0]);
    final fpx = render(flat, view);
    expect(at(fpx, view, 50, 32), at(fpx, view, 14, 32));
  });

  test('textures colour the surface; flat colours ignore them', () {
    final mesh = quads(
      const [(-1.0, -1.0, 1.0, 1.0, 0.0, 0)],
      materials: const [ModelMaterial(color: 0xFFFFFFFF, texture: 'tex')],
      uvs: true,
    );
    // Left half red, right half blue, a see-through bottom row.
    final rgba = Uint8List(4 * 4 * 4);
    for (var y = 0; y < 4; y++) {
      for (var x = 0; x < 4; x++) {
        rgba.setAll((y * 4 + x) * 4, [
          x < 2 ? 255 : 0,
          0,
          x < 2 ? 0 : 255,
          y == 3 ? 0 : 255,
        ]);
      }
    }
    final raster = RasterMesh.of(mesh);
    expect(raster.textureVersion, 0);
    raster.setTexture('tex', RasterTexture.fromRgba(rgba, 4, 4)!);
    expect(raster.textureVersion, 1);
    expect(raster.hasTexture('tex'), isTrue);
    final px = render(mesh, view);
    expect(at(px, view, 20, 20)[0], greaterThan(100));
    expect(at(px, view, 20, 20)[2], 0);
    expect(at(px, view, 44, 20)[2], greaterThan(100));
    expect(at(px, view, 44, 20)[0], 0);
    expect(at(px, view, 32, 56)[3], 0, reason: 'cut out');
    const plain = RasterView(width: 64, height: 64, textured: false);
    final ppx = at(render(mesh, plain), plain, 20, 20);
    expect(ppx[0], ppx[2]);
    expect(RasterTexture.fromRgba(rgba, 8, 8), isNull);
  });

  test('wireframe edges hide behind the surface; the grid lies under it', () {
    const wire = RasterView(
      width: 64,
      height: 64,
      wireframe: true,
      lineColor: 0xFF00FF00,
    );
    final px = render(
      quads(
        const [(-0.4, -0.4, 0.4, 0.4, 0.5, 0), (-1.0, -1.0, 1.0, 1.0, -0.5, 1)],
        materials: const [red, blue],
      ),
      wire,
    );
    int greens(Uint8List p) {
      var n = 0;
      for (var i = 0; i < p.length; i += 4) {
        if (p[i + 1] > 60) n++;
      }
      return n;
    }

    expect(greens(px), greaterThan(60));
    // The near quad's own diagonal is drawn across its middle…
    var onDiagonal = 0;
    for (var k = -4; k <= 4; k++) {
      if (at(px, wire, 32 + k, 31 - k)[1] > 30) onDiagonal++;
    }
    expect(onDiagonal, greaterThanOrEqualTo(7));
    // …and the far quad's diagonal, which passes behind it, is hidden
    // there: away from that line the near quad is plain red.
    expect(at(px, wire, 36, 34)[1], 0);
    expect(at(px, wire, 28, 30)[1], 0);

    const floor = RasterView(
      width: 64,
      height: 64,
      pitch: 0.5,
      grid: true,
      lineColor: 0xFF00FF00,
    );
    final cube = Directory.systemTemp.createTempSync('raster');
    addTearDown(() => cube.deleteSync(recursive: true));
    final mesh = readModel(writeCubeGlb(cube.path, 'cube').path);
    final withGrid = render(mesh, floor);
    final without = render(
      mesh,
      const RasterView(width: 64, height: 64, pitch: 0.5),
    );
    expect(greens(withGrid), greaterThan(greens(without) + 40));
    // Nothing of the floor shows through the cube.
    expect(at(withGrid, floor, 32, 32), at(without, floor, 32, 32));
  });

  test('smoothed edges; the camera fits, zooms and pans', () {
    final mesh = ball(24);
    const smooth = RasterView(width: 96, height: 96);
    final px = render(mesh, smooth);
    var partial = 0, solid = 0;
    for (var i = 3; i < px.length; i += 4) {
      if (px[i] == 255) solid++;
      if (px[i] > 0 && px[i] < 255) partial++;
    }
    expect(partial, greaterThan(50), reason: 'edge pixels are blended');
    // The ball fills most of the picture without touching its border.
    expect(solid, greaterThan(96 * 96 * 0.15));
    for (var i = 0; i < 96; i++) {
      expect(at(px, smooth, i, 0)[3], 0);
      expect(at(px, smooth, 0, i)[3], 0);
    }
    const sharp = RasterView(width: 96, height: 96, samples: 1);
    final spx = render(mesh, sharp);
    for (var i = 3; i < spx.length; i += 4) {
      expect(spx[i] == 0 || spx[i] == 255, isTrue);
    }
    const zoomed = RasterView(width: 96, height: 96, zoom: 4);
    expect(at(render(mesh, zoomed), zoomed, 1, 1)[3], 255);
    const panned = RasterView(width: 96, height: 96, panX: 40);
    final ppx = render(mesh, panned);
    expect(at(ppx, panned, 10, 48)[3], 0);
    expect(at(ppx, panned, 90, 48)[3], 255);
  });

  test('a mesh with a bad index or material is refused', () {
    final bad = ModelMesh(
      positions: Float32List(9),
      normals: Float32List(9),
      indices: Uint32List.fromList([0, 1, 3]),
      triangleMaterials: Uint16List(1),
      materials: const [ModelMaterial.plain],
    );
    expect(() => RasterMesh.of(bad), throwsA(isA<ModelReadError>()));
    final badMaterial = ModelMesh(
      positions: Float32List(9),
      normals: Float32List(9),
      indices: Uint32List.fromList([0, 1, 2]),
      triangleMaterials: Uint16List.fromList([2]),
      materials: const [ModelMaterial.plain],
    );
    expect(() => RasterMesh.of(badMaterial), throwsA(isA<ModelReadError>()));
  });

  test('the worker pool draws the same picture, band by band', () async {
    final mesh = ball(60);
    final pool = ModelRenderPool(workers: 3);
    addTearDown(pool.dispose);
    for (final v in const [
      RasterView(width: 301, height: 203, yaw: 0.7, pitch: 0.3),
      RasterView(width: 64, height: 5, wireframe: true, grid: true),
      RasterView(width: 120, height: 90, samples: 1, zoom: 3, panX: 20),
    ]) {
      final pooled = await pool.render(RasterMesh.of(mesh), v);
      expect(pooled, render(mesh, v));
    }
    // Pictures asked for at once come back in order, each its own.
    final a = pool.render(RasterMesh.of(mesh), view);
    final b = pool.render(
      RasterMesh.of(mesh),
      const RasterView(width: 64, height: 64, yaw: 2),
    );
    expect(await a, render(mesh, view));
    expect(await b, isNot(await a));
  });

  test('speed: big meshes on one core and on the pool', () async {
    final pool = ModelRenderPool();
    addTearDown(pool.dispose);
    const v = RasterView(width: 1100, height: 800, yaw: 0.6, pitch: 0.4);
    for (final rings in [160, 500, 1000]) {
      final mesh = ball(rings);
      final raster = RasterMesh.of(mesh);
      final out = Uint8List(v.width * v.height * 4);
      int median(List<int> t) => (t..sort())[t.length ~/ 2];
      final one = <int>[], many = <int>[];
      final watch = Stopwatch()..start();
      for (var i = 0; i < 7; i++) {
        watch.reset();
        context.render(raster, v, out);
        one.add(watch.elapsedMicroseconds);
        watch.reset();
        await pool.render(raster, v);
        many.add(watch.elapsedMicroseconds);
      }
      // ignore: avoid_print
      print(
        '${mesh.triangleCount} triangles at 1100 × 800: '
        '${(median(one) / 1000).toStringAsFixed(1)} ms on one core, '
        '${(median(many) / 1000).toStringAsFixed(1)} ms on '
        '${pool.workerCount} workers',
      );
      if (rings == 500) {
        // A million triangles stay interactive (measured: about 16 ms).
        expect(median(many), lessThan(100000));
      }
    }
  });
}
