import 'dart:io';

import 'package:assets_explorer/core/library_index.dart';
import 'package:assets_explorer/state/settings.dart';
import 'package:assets_explorer/ui/widgets/pack_tile.dart';
import 'package:assets_explorer/ui/widgets/thumb_size.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../helpers/fonts.dart';

/// The dashboard's delegate, as `dashboard.dart` builds it.
ThumbGridDelegate dashboardGrid(double size, {bool tags = false}) =>
    ThumbGridDelegate(
      maxTileWidth: size,
      imageAspect: 4 / 3,
      footer: (w) => (w < 190 ? 148 : 120) + (tags ? tagsLineHeight : 0),
      footerKey: tags,
    );

PackRow longPack(int i) => PackRow(
  id: 'p$i',
  path: '/nowhere',
  title: 'The Extremely Long Pack Title Of Many Words Volume $i Deluxe',
  author: 'An Author With A Rather Long Name Indeed',
  isContainer: false,
  types: const ['character', 'environment', 'tileset', 'ui', 'vfx'],
  tags: const ['zebra', 'Animals', 'a very long tag name indeed', 'cozy'],
  usedIn: const [],
  preview: null,
  previewAnim: null,
  fileCount: 1,
  totalBytes: 1,
);

void main() {
  setUpAll(loadAppFonts);

  group('ThumbGridDelegate', () {
    SliverConstraints at(double width) => SliverConstraints(
      axisDirection: AxisDirection.down,
      growthDirection: GrowthDirection.forward,
      userScrollDirection: ScrollDirection.idle,
      scrollOffset: 0,
      precedingScrollExtent: 0,
      overlap: 0,
      remainingPaintExtent: 800,
      crossAxisExtent: width,
      crossAxisDirection: AxisDirection.right,
      viewportMainAxisExtent: 800,
      remainingCacheExtent: 800,
      cacheOrigin: 0,
    );

    SliverGridRegularTileLayout layout(SliverGridDelegate d, double width) =>
        d.getLayout(at(width)) as SliverGridRegularTileLayout;

    test('default size keeps the old 240 px / 0.8 tiles', () {
      final old = const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 240,
        childAspectRatio: 0.8,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
      );
      for (final width in [700.0, 1008.0, 1408.0, 2000.0]) {
        expect(
          layout(dashboardGrid(240), width).crossAxisCount,
          layout(old, width).crossAxisCount,
          reason: '$width',
        );
      }
      // Four 240 px tiles: the same 240 × 300 as before. Other widths keep a
      // fixed footer instead of growing the text area with the tile.
      expect(layout(dashboardGrid(240), 996).childMainAxisExtent, 300);
      expect(layout(old, 996).childMainAxisExtent, 300);
    });

    test('column count follows the size; height follows the width', () {
      expect(layout(dashboardGrid(140), 1408).crossAxisCount, 10);
      expect(layout(dashboardGrid(480), 1408).crossAxisCount, 3);
      final big = layout(dashboardGrid(480), 1408);
      expect(
        big.childMainAxisExtent,
        closeTo(big.childCrossAxisExtent * 3 / 4 + 120, 0.01),
      );
    });

    test('size ranges clamp and step', () {
      expect(dashboardTileRange.clamp(9999), 480);
      expect(dashboardTileRange.nudge(240, 1), 260);
      expect(dashboardTileRange.nudge(140, -1), 140);
      expect(imageThumbRange.nudge(400, 3), 400);
    });
  });

  for (final size in [dashboardTileRange.min, dashboardTileRange.max]) {
    testWidgets('tiles at ${size.round()} px fit their labels', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1440, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            colorSchemeSeed: Colors.teal,
            brightness: Brightness.dark,
            fontFamily: 'Roboto',
          ),
          home: Scaffold(
            body: GridView.builder(
              padding: const EdgeInsets.all(16),
              gridDelegate: dashboardGrid(size),
              itemCount: 12,
              itemBuilder: (_, i) => PackTile(pack: longPack(i), onTap: () {}),
            ),
          ),
        ),
      );
      // A RenderFlex overflow would be reported here.
      expect(tester.takeException(), isNull);
      await expectLater(
        find.byType(GridView),
        matchesGoldenFile('goldens/tiles_${size.round()}.png'),
      );
    });
  }

  for (final size in [dashboardTileRange.min, dashboardTileRange.max]) {
    testWidgets('tiles at ${size.round()} px fit types and tags', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1440, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(fontFamily: 'Roboto'),
          home: Scaffold(
            body: GridView.builder(
              padding: const EdgeInsets.all(16),
              gridDelegate: dashboardGrid(size, tags: true),
              itemCount: 12,
              itemBuilder: (_, i) =>
                  PackTile(pack: longPack(i), onTap: () {}, showTags: true),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      // Type chips stay; the tags line comes under them, sorted.
      expect(find.text('character'), findsWidgets);
      expect(
        find.text('a very long tag name indeed, Animals, cozy, zebra'),
        findsWidgets,
      );
    });
  }

  test('a tags footer change lays the grid out again', () {
    expect(dashboardGrid(240).shouldRelayout(dashboardGrid(240)), isFalse);
    expect(
      dashboardGrid(240, tags: true).shouldRelayout(dashboardGrid(240)),
      isTrue,
    );
  });

  testWidgets('Ctrl + wheel resizes instead of scrolling', (tester) async {
    final steps = <int>[];
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: CtrlWheelResize(
          onSteps: steps.add,
          child: GridView.builder(
            controller: controller,
            physics: const CtrlWheelPhysics(),
            gridDelegate: dashboardGrid(240),
            itemCount: 200,
            itemBuilder: (_, i) => Text('$i'),
          ),
        ),
      ),
    );
    final center = tester.getCenter(find.byType(GridView));
    Future<void> wheel(double dy) async {
      final pointer = TestPointer(1, PointerDeviceKind.mouse);
      pointer.hover(center);
      await tester.sendEventToBinding(pointer.scroll(Offset(0, dy)));
      await tester.pump();
    }

    await wheel(100);
    expect(controller.offset, greaterThan(0));
    expect(steps, isEmpty);
    final offset = controller.offset;

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await wheel(-100);
    await wheel(100);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    expect(steps, [1, -1]);
    expect(controller.offset, offset);
  });

  test('tile sizes round-trip and default to today\'s sizes', () {
    final dir = Directory.systemTemp.createTempSync('sizes');
    addTearDown(() => dir.deleteSync(recursive: true));
    final store = SettingsStore(File(p.join(dir.path, 'settings.json')));
    expect(store.load().dashboardTileSize, 240);
    expect(store.load().imageThumbSize, 160);
    expect(store.load().animationThumbSize, 200);
    store.save(
      const AppSettings(
        dashboardTileSize: 400,
        imageThumbSize: 80,
        animationThumbSize: 320,
      ),
    );
    expect(store.load().dashboardTileSize, 400);
    expect(store.load().imageThumbSize, 80);
    expect(store.load().animationThumbSize, 320);
    expect(
      File(p.join(dir.path, 'settings.json')).readAsStringSync(),
      allOf(
        contains('"dashboard_tile_size": 400'),
        contains('"image_thumb_size": 80'),
      ),
    );
  });
}
