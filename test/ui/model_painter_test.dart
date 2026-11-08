import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loot_silo/core/model_mesh.dart';
import 'package:loot_silo/ui/model_painter.dart';
import 'package:loot_silo/ui/theme_colors.dart';

import '../helpers/models.dart';

void main() {
  late ModelMesh cube;
  setUpAll(() {
    final tmp = Directory.systemTemp.createTempSync('painter');
    cube = readModel(writeCubeGlb(tmp.path, 'cube').path);
    tmp.deleteSync(recursive: true);
  });

  Widget stage(Brightness brightness, {bool wireframe = false}) {
    final scheme = ColorScheme.fromSeed(
      seedColor: Colors.teal,
      brightness: brightness,
    );
    return Center(
      child: RepaintBoundary(
        child: SizedBox.square(
          dimension: 160,
          child: CustomPaint(
            painter: ModelPainter(
              mesh: cube,
              background: modelStageColor(scheme),
              wireframe: wireframe,
              grid: wireframe,
              lineColor: scheme.onSurface,
            ),
          ),
        ),
      ),
    );
  }

  for (final b in Brightness.values) {
    testWidgets('the cube from the default camera, ${b.name}', (tester) async {
      await tester.pumpWidget(stage(b));
      await expectLater(
        find.byType(RepaintBoundary).first,
        matchesGoldenFile('goldens/model_cube_${b.name}.png'),
      );
    });
  }

  testWidgets('the wireframe cube with the floor grid', (tester) async {
    await tester.pumpWidget(stage(Brightness.dark, wireframe: true));
    await expectLater(
      find.byType(RepaintBoundary).first,
      matchesGoldenFile('goldens/model_cube_wireframe.png'),
    );
  });

  test('repaints only when what it draws changes', () {
    final a = ModelPainter(mesh: cube);
    expect(a.shouldRepaint(ModelPainter(mesh: cube)), isFalse);
    expect(a.shouldRepaint(ModelPainter(mesh: cube, yaw: 1)), isTrue);
    expect(a.shouldRepaint(ModelPainter(mesh: cube, zoom: 2)), isTrue);
  });
}
