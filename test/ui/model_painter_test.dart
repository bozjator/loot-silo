import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loot_silo/core/model_mesh.dart';
import 'package:loot_silo/ui/model_painter.dart';
import 'package:loot_silo/ui/model_picture.dart';
import 'package:loot_silo/ui/theme_colors.dart';

import '../helpers/models.dart';

void main() {
  late ModelMesh cube;
  setUpAll(() {
    final tmp = Directory.systemTemp.createTempSync('painter');
    cube = readModel(writeCubeGlb(tmp.path, 'cube').path);
    tmp.deleteSync(recursive: true);
  });

  late ModelPicture picture;
  setUp(() => picture = ModelPicture());
  tearDown(() => picture.dispose());

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
              picture: picture,
            ),
          ),
        ),
      ),
    );
  }

  /// Pumps [widget] and waits for its picture (drawn and decoded in real
  /// time).
  Future<void> show(WidgetTester tester, Widget widget) async {
    await tester.pumpWidget(widget);
    await settlePicture(tester, picture);
  }

  for (final b in Brightness.values) {
    testWidgets('the cube from the default camera, ${b.name}', (tester) async {
      await show(tester, stage(b));
      expect(picture.renders, 1);
      await expectLater(
        find.byType(RepaintBoundary).first,
        matchesGoldenFile('goldens/model_cube_${b.name}.png'),
      );
    });
  }

  testWidgets('the wireframe cube with the floor grid', (tester) async {
    await show(tester, stage(Brightness.dark, wireframe: true));
    await expectLater(
      find.byType(RepaintBoundary).first,
      matchesGoldenFile('goldens/model_cube_wireframe.png'),
    );
  });

  testWidgets('the picture is drawn once per camera', (tester) async {
    await show(tester, stage(Brightness.dark));
    expect(picture.renders, 1);
    // The same picture again: nothing to draw.
    await show(tester, stage(Brightness.dark));
    expect(picture.renders, 1);
    await show(tester, stage(Brightness.dark, wireframe: true));
    expect(picture.renders, 2);
  });

  test('the picture has the screen\'s pixels', () {
    final view = ModelPainter(
      mesh: cube,
      pixelRatio: 1.5,
      pan: const Offset(10, -4),
    ).viewFor(const Size(200, 100));
    expect((view.width, view.height), (300, 150));
    expect((view.panX, view.panY), (15, -6));
    expect(view.samples, 2);
    final dense = ModelPainter(mesh: cube, pixelRatio: 2);
    expect(dense.viewFor(const Size(200, 100)).samples, 1);
    final fast = ModelPainter(mesh: cube, fast: true);
    expect(fast.viewFor(const Size(200, 100)).samples, 1);
  });

  test('repaints only when what it draws changes', () {
    final a = ModelPainter(mesh: cube, picture: picture);
    ModelPainter other({double? yaw, double zoom = 1, int textures = 0}) =>
        ModelPainter(
          mesh: cube,
          yaw: yaw ?? defaultModelYaw,
          zoom: zoom,
          textures: textures,
          picture: picture,
        );
    expect(a.shouldRepaint(other()), isFalse);
    expect(a.shouldRepaint(other(yaw: 1)), isTrue);
    expect(a.shouldRepaint(other(zoom: 2)), isTrue);
    expect(a.shouldRepaint(other(textures: 1)), isTrue);
  });
}
