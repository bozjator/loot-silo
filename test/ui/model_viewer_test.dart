import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loot_silo/core/model_cache.dart';
import 'package:loot_silo/core/model_formats.dart';
import 'package:loot_silo/core/model_mesh.dart';
import 'package:loot_silo/state/providers.dart';
import 'package:loot_silo/ui/model_painter.dart';
import 'package:loot_silo/ui/model_viewer.dart';
import 'package:loot_silo/ui/reveal.dart';
import 'package:path/path.dart' as p;

import '../helpers/models.dart';

void main() {
  late Directory tmp;
  final reveals = <String>[];
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('viewer');
    reveals.clear();
    // Session toggles start fresh in every test.
    modelViewOptions
      ..textured = true
      ..wireframe = false
      ..turntable = false
      ..grid = false;
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  /// Two models: a cube (GLB + OBJ + FBX) and a tall one (GLB).
  Future<void> open(
    WidgetTester tester, {
    int index = 0,
    ModelCache? cache,
  }) async {
    final dir = p.join(tmp.path, 'Models');
    writeCubeGlb(p.join(dir, 'GLTF format'), 'crate');
    writeCubeObj(p.join(dir, 'OBJ format'), 'crate');
    File(p.join(dir, 'FBX format', 'crate.fbx'))
      ..createSync(recursive: true)
      ..writeAsBytesSync([0]);
    writeCubeGlb(
      p.join(dir, 'GLTF format'),
      'tower',
      node: {
        'scale': [1, 3, 1],
      },
    );
    final items = groupModelFormats([
      'Models/GLTF format/crate.glb',
      'Models/OBJ format/crate.obj',
      'Models/FBX format/crate.fbx',
      'Models/GLTF format/tower.glb',
    ]);
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          modelCacheProvider.overrideWithValue(
            cache ??
                ModelCache(read: (path) async => readModelForPreview(path)),
          ),
          revealProvider.overrideWithValue((path) async => reveals.add(path)),
        ],
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showModelViewer(
                  context,
                  packPath: tmp.path,
                  items: items,
                  files: [for (final m in items) m.shown!],
                  index: index,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  ModelPainter painter(WidgetTester tester) =>
      tester
              .widget<CustomPaint>(
                find.byKey(const ValueKey('model-viewer-paint')),
              )
              .painter!
          as ModelPainter;

  Finder stage() => find.byKey(const ValueKey('model-viewer-stage'));

  testWidgets('drag orbits (pitch clamped), wheel zooms, double-click resets', (
    tester,
  ) async {
    await open(tester);
    expect(painter(tester).yaw, defaultModelYaw);
    final g = await tester.startGesture(
      tester.getCenter(stage()),
      kind: PointerDeviceKind.mouse,
    );
    await g.moveBy(const Offset(100, 0));
    await g.moveBy(const Offset(0, 20));
    await tester.pump();
    expect(painter(tester).yaw, closeTo(defaultModelYaw + 1, 1e-9));
    expect(painter(tester).pitch, closeTo(defaultModelPitch + 0.2, 1e-9));
    await g.moveBy(const Offset(0, 1000));
    await g.up();
    await tester.pump();
    expect(painter(tester).pitch, closeTo(maxModelPitch, 1e-9));

    final mouse = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(mouse.hover(tester.getCenter(stage())));
    await tester.sendEventToBinding(mouse.scroll(const Offset(0, -400)));
    await tester.pump();
    expect(painter(tester).zoom, closeTo(math.e, 1e-9));

    // Right-drag pans.
    final pan = await tester.startGesture(
      tester.getCenter(stage()),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await pan.moveBy(const Offset(30, -10));
    await pan.up();
    await tester.pump();
    expect(painter(tester).pan, const Offset(30, -10));

    await tester.tap(stage());
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(stage());
    await tester.pump(const Duration(milliseconds: 400));
    final reset = painter(tester);
    expect(reset.yaw, defaultModelYaw);
    expect(reset.pitch, defaultModelPitch);
    expect(reset.zoom, 1);
    expect(reset.pan, Offset.zero);
  });

  testWidgets('keys: Shift+arrows and ↑↓ orbit, + − zoom, 0 resets', (
    tester,
  ) async {
    await open(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(painter(tester).yaw, greaterThan(defaultModelYaw));
    expect(painter(tester).pitch, greaterThan(defaultModelPitch));
    await tester.sendKeyEvent(LogicalKeyboardKey.equal, character: '+');
    await tester.pump();
    expect(painter(tester).zoom, closeTo(1.25, 1e-9));
    await tester.sendKeyEvent(LogicalKeyboardKey.minus, character: '-');
    await tester.sendKeyEvent(LogicalKeyboardKey.minus, character: '-');
    await tester.pump();
    expect(painter(tester).zoom, closeTo(0.8, 1e-9));
    await tester.sendKeyEvent(LogicalKeyboardKey.digit0, character: '0');
    await tester.pump();
    expect(painter(tester).yaw, defaultModelYaw);
    expect(painter(tester).zoom, 1);
  });

  testWidgets('←/→ and the buttons go through the models; Esc closes', (
    tester,
  ) async {
    await open(tester);
    expect(find.text('1 / 2'), findsOneWidget);
    expect(find.text('Crate'), findsWidgets);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(find.text('2 / 2'), findsOneWidget);
    expect(find.text('Tower'), findsWidgets);
    // Stops at the end.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(find.text('2 / 2'), findsOneWidget);
    await tester.tap(find.byTooltip('Previous model (←)'));
    await tester.pump();
    expect(find.text('1 / 2'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(ModelViewer), findsNothing);
  });

  testWidgets('toggles redraw without projecting again', (tester) async {
    await open(tester);
    final cache = painter(tester).cache!;
    final before = cache.projections;
    for (final t in ['wireframe', 'grid', 'textured']) {
      await tester.tap(find.byKey(ValueKey('toggle-$t')));
      await tester.pump();
    }
    final on = painter(tester);
    expect(on.wireframe, isTrue);
    expect(on.grid, isTrue);
    expect(on.flat, isTrue);
    expect(cache.projections, before);
    // Kept for the next viewer this session.
    expect(modelViewOptions.wireframe, isTrue);

    await tester.tap(find.byKey(const ValueKey('toggle-turntable')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(
      painter(tester).yaw,
      closeTo(defaultModelYaw + 2 * math.pi / 6, 0.05),
    );
    await tester.tap(find.byKey(const ValueKey('toggle-turntable')));
    await tester.pump();
  });

  testWidgets('info panel; chips draw or reveal; copy path', (tester) async {
    await open(tester);
    String info(String name) =>
        tester.widget<SelectableText>(find.byKey(ValueKey('info:$name'))).data!;
    expect(info('Triangles'), '12');
    // The GLB's two primitives each carry the 8 corners.
    expect(info('Vertices'), '16');
    expect(info('Size'), '2 × 2 × 2');
    expect(info('Texture'), 'None');
    expect(info('Folder'), 'Models');
    await tester.tap(
      find.byKey(const ValueKey('format:Models/OBJ format/crate.obj')),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('Models/OBJ format/crate.obj'), findsOneWidget);
    expect(info('Vertices'), '8');
    await tester.tap(
      find.byKey(const ValueKey('format:Models/FBX format/crate.fbx')),
    );
    await tester.pump();
    expect(reveals.single, endsWith('crate.fbx'));
    await tester.tap(find.text('Copy path'));
    await tester.pump();
    expect(find.text('Copied'), findsOneWidget);
  });

  testWidgets('a large mesh draws unsorted while dragging, sorted after', (
    tester,
  ) async {
    // A strip of 20,002 triangles.
    const quads = 10001;
    final pos = Float32List((quads + 1) * 2 * 3);
    for (var i = 0; i <= quads; i++) {
      pos.setAll(i * 6, [i / 100, 0, 0, i / 100, 1, 0]);
    }
    final idx = Uint32List(quads * 6);
    for (var i = 0; i < quads; i++) {
      final a = i * 2;
      idx.setAll(i * 6, [a, a + 2, a + 1, a + 1, a + 2, a + 3]);
    }
    final big = ModelMesh(
      positions: pos,
      normals: Float32List(pos.length),
      indices: idx,
      triangleMaterials: Uint16List(quads * 2),
      materials: const [ModelMaterial.plain],
    );
    await open(tester, cache: ModelCache(read: (_) async => big));
    expect(painter(tester).sorted, isTrue);
    final g = await tester.startGesture(
      tester.getCenter(stage()),
      kind: PointerDeviceKind.mouse,
    );
    await g.moveBy(const Offset(10, 0));
    await tester.pump();
    expect(painter(tester).sorted, isFalse);
    await g.up();
    await tester.pump();
    expect(painter(tester).sorted, isTrue);
    // Let the double-click window pass.
    await tester.pump(const Duration(milliseconds: 400));
  });
}
