import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show FrameTiming;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:loot_silo/core/model_mesh.dart';
import 'package:loot_silo/ui/model_painter.dart';
import 'package:loot_silo/ui/model_picture.dart';

/// Frame timings of a turning model, meant to run in profile mode:
///
///     flutter drive --profile -d linux \
///       --driver=test_driver/integration_test.dart \
///       --target=integration_test/model_perf_test.dart
///
/// For each model it turns the camera on every frame for two seconds and
/// reports how long the UI thread worked per frame (build) and how many
/// new pictures a second the renderer delivered. Read-only.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('turning models: UI time per frame, pictures per second', (
    tester,
  ) async {
    final models = <String, ModelMesh>{};
    const tyre = '../assets_library/Unknown Author/Tyre/tyre.obj';
    if (File(tyre).existsSync()) models['tyre_39k'] = readModel(tyre);
    models['ball_100k'] = _ball(160);
    models['ball_1m'] = _ball(500);
    models['ball_4m'] = _ball(1000);

    final frames = <FrameTiming>[];
    void collect(List<FrameTiming> t) => frames.addAll(t);
    WidgetsBinding.instance.addTimingsCallback(collect);
    addTearDown(() => WidgetsBinding.instance.removeTimingsCallback(collect));
    final results = <String, Object>{};
    for (final MapEntry(key: name, value: mesh) in models.entries) {
      final picture = ModelPicture();
      final yaw = ValueNotifier(0.0);
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox(
              width: 1100,
              height: 800,
              child: ValueListenableBuilder(
                valueListenable: yaw,
                builder: (context, value, _) => CustomPaint(
                  painter: ModelPainter(
                    mesh: mesh,
                    yaw: value,
                    background: const Color(0xFF303838),
                    pixelRatio: MediaQuery.devicePixelRatioOf(context),
                    picture: picture,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      // The first picture (and the worker isolates' start).
      for (var i = 0; i < 100 && picture.image == null; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      await tester.pump(const Duration(milliseconds: 300));
      frames.clear();
      final before = picture.renders;
      final watch = Stopwatch()..start();
      var pumps = 0;
      while (watch.elapsedMilliseconds < 2000) {
        yaw.value += 0.02;
        await tester.pump();
        pumps++;
      }
      final seconds = watch.elapsedMicroseconds / 1e6;
      await tester.pump(const Duration(milliseconds: 300));
      double ms(Duration d) => d.inMicroseconds / 1000;
      final build = [for (final f in frames) ms(f.buildDuration)]..sort();
      final r = {
        'triangles': mesh.triangleCount,
        'frames_per_s': (pumps / seconds).round(),
        'pictures_per_s': ((picture.renders - before) / seconds).round(),
        'build_median_ms': build.isEmpty ? 0 : build[build.length ~/ 2],
        'build_max_ms': build.isEmpty ? 0 : build.last,
      };
      results[name] = r;
      // ignore: avoid_print
      print('model_perf $name: $r');
      picture.dispose();
    }
    binding.reportData = {'model_perf': results};
  });
}

/// A bumpy ball of `rings × 2·rings × 2` triangles.
ModelMesh _ball(int rings) {
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
