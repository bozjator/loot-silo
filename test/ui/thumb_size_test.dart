import 'dart:io';

import 'package:loot_silo/core/library_index.dart';
import 'package:loot_silo/state/settings.dart';
import 'package:loot_silo/ui/cursors.dart';
import 'package:loot_silo/ui/widgets/pack_tile.dart';
import 'package:loot_silo/ui/widgets/thumb_size.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../helpers/fonts.dart';

/// A delegate with a fixed footer, as the dashboard used before rows sized
/// to their content.
ThumbGridDelegate dashboardGrid(double size) => ThumbGridDelegate(
  maxTileWidth: size,
  imageAspect: 4 / 3,
  footer: (w) => w < 190 ? 148 : 120,
);

PackRow longPack(int i, {String? title}) => PackRow(
  id: 'p$i',
  path: '/nowhere',
  title:
      title ?? 'The Extremely Long Pack Title Of Many Words Volume $i Deluxe',
  author: 'An Author With A Rather Long Name Indeed',
  isContainer: false,
  types: const ['character', 'environment', 'tileset', 'ui', 'vfx'],
  tags: const ['zebra', 'Animals', 'a very long tag name indeed', 'cozy'],
  usedIn: const [],
  favorite: false,
  favoriteFiles: const [],
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
            body: ThumbRows(
              padding: const EdgeInsets.all(16),
              maxTileWidth: size,
              itemCount: 12,
              itemBuilder: (_, i) => PackTile(pack: longPack(i), onTap: () {}),
            ),
          ),
        ),
      );
      // A RenderFlex overflow would be reported here.
      expect(tester.takeException(), isNull);
      await expectLater(
        find.byType(ThumbRows),
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
            body: ThumbRows(
              padding: const EdgeInsets.all(16),
              maxTileWidth: size,
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

  testWidgets('rows are as tall as their tallest card, no taller', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1040, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    // Four 240 px columns; row 1 has one long card, row 2 only short ones.
    final packs = [
      longPack(0),
      for (var i = 1; i < 8; i++)
        longPack(i, title: 'Short $i').copyWith(types: const ['music']),
    ];
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(fontFamily: 'Roboto'),
        home: Scaffold(
          body: ThumbRows(
            padding: const EdgeInsets.all(16),
            maxTileWidth: 240,
            itemCount: packs.length,
            itemBuilder: (_, i) => PackTile(pack: packs[i]),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    double height(int i) => tester.getSize(find.byType(PackTile).at(i)).height;
    final image = tester.getSize(find.byType(PackTile).first).width * 3 / 4;
    // Row 1 matches the long card; its short neighbours stretch to it.
    expect(height(1), height(0));
    // Row 2: title, author and one chip row — about 80 px under the image,
    // where the fixed grid footer was 120 px.
    expect(height(4) - image, lessThan(90));
    expect(height(0), greaterThan(height(4) + 30));
  });

  testWidgets('end icons step one size, disabled at the ends (M50)', (
    tester,
  ) async {
    var value = imageThumbRange.max - imageThumbRange.step;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: StatefulBuilder(
              builder: (context, setState) => ThumbSizeSlider(
                range: imageThumbRange,
                value: value,
                onChanged: (v) => setState(() => value = v),
              ),
            ),
          ),
        ),
      ),
    );
    IconButton button(String tooltip) => tester.widget<IconButton>(
      find.ancestor(
        of: find.byTooltip(tooltip),
        matching: find.byType(IconButton),
      ),
    );
    await tester.tap(find.byTooltip('Larger'));
    await tester.pump();
    expect(value, imageThumbRange.max);
    expect(button('Larger').onPressed, isNull);
    expect(button('Smaller').onPressed, isNotNull);
    await tester.tap(find.byTooltip('Smaller'));
    await tester.pump();
    expect(value, imageThumbRange.max - imageThumbRange.step);
    value = imageThumbRange.min;
    await tester.tap(find.byTooltip('Larger'));
    await tester.pump();
    value = imageThumbRange.min;
    (tester.element(find.byType(StatefulBuilder)) as StatefulElement)
        .markNeedsBuild();
    await tester.pump();
    expect(button('Smaller').onPressed, isNull);
    expect(button('Smaller').mouseCursor, clickCursor);
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

  group('balancedColumns (M42)', () {
    test('the examples from the plan', () {
      expect(balancedColumns(8, 5), 4);
      expect(balancedColumns(9, 5), 5);
      expect(balancedColumns(7, 3), 3);
      expect(balancedColumns(8, 4), 4);
      expect(balancedColumns(2, 4), 2);
      expect(balancedColumns(0, 4), 4);
    });

    test('n = 1…20: never more columns or rows than wanted gives, '
        'and rows differ by at most the minimum', () {
      for (var wanted = 1; wanted <= 8; wanted++) {
        for (var n = 1; n <= 20; n++) {
          final c = balancedColumns(n, wanted);
          final rows = (n + wanted - 1) ~/ wanted;
          expect(c, lessThanOrEqualTo(wanted), reason: '$n/$wanted');
          expect(c, greaterThanOrEqualTo(1));
          // Same number of rows as the wanted count would need.
          expect((n + c - 1) ~/ c, rows, reason: '$n/$wanted');
          // No narrower count keeps that many rows.
          if (c > 1) {
            expect((n + c - 2) ~/ (c - 1), greaterThan(rows));
          }
        }
      }
    });
  });

  test('previews_columns round-trips, defaults to 4, stays in 1–8', () {
    final dir = Directory.systemTemp.createTempSync('cols');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File(p.join(dir.path, 'settings.json'));
    final store = SettingsStore(file);
    expect(store.load().previewsColumns, 4);
    store.save(const AppSettings(previewsColumns: 6));
    expect(store.load().previewsColumns, 6);
    expect(file.readAsStringSync(), contains('"previews_columns": 6'));
    file.writeAsStringSync('{"previews_columns": 40}');
    expect(store.load().previewsColumns, 8);
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
