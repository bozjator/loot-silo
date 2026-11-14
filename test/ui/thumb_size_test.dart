import 'dart:io';
import 'dart:ui' as ui;

import 'package:loot_silo/core/library_index.dart';
import 'package:loot_silo/state/settings.dart';
import 'package:loot_silo/ui/cursors.dart';
import 'package:loot_silo/ui/materials_tab.dart';
import 'package:loot_silo/ui/widgets/pixel_image.dart';
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
  m79();
  m80();

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
      // M80: a saved large stop survives, up to the 800 px cap.
      expect(dashboardTileRange.clamp(700), 700);
      expect(dashboardTileRange.clamp(1200), maxCardWidth);
      expect(maxCardWidth, 800);
      expect(dashboardTileRange.clamp(10), 140);
      expect(dashboardTileRange.nudge(240, 1), 260);
      expect(dashboardTileRange.nudge(1200, -1), 460);
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

/// A slider and a grid sharing a [ThumbScale], as every tab wires them.
class _Harness extends StatefulWidget {
  const _Harness({required this.range, required this.initial, this.onSaved});

  final SizeRange range;
  final double initial;
  final ValueChanged<double>? onSaved;

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  late final scale = ThumbScale(widget.range, spacing: 8);
  late double value = widget.initial;

  void _set(double v) {
    setState(() => value = v);
    widget.onSaved?.call(v);
  }

  @override
  void dispose() {
    scale.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Column(
      children: [
        ThumbSizeSlider(
          range: widget.range,
          value: value,
          width: 260,
          scale: scale,
          onChanged: _set,
        ),
        Expanded(
          child: CtrlWheelResize(
            onSteps: (n) => _set(scale.step(value, n)),
            child: GridView.builder(
              physics: const CtrlWheelPhysics(),
              padding: const EdgeInsets.all(16),
              gridDelegate: ThumbGridDelegate(
                maxTileWidth: value,
                imageAspect: 1,
                footer: (_) => 40,
                spacing: 8,
                mainAxisPadding: 32,
                scale: scale,
              ),
              itemCount: 60,
              itemBuilder: (_, i) =>
                  ColoredBox(key: ValueKey('card$i'), color: Colors.teal),
            ),
          ),
        ),
      ],
    ),
  );
}

void m79() {
  group('M79 slider stops', () {
    const ranges = {
      'dashboard': (dashboardTileRange, 12.0),
      'images': (imageThumbRange, 8.0),
      'animations': (animationThumbRange, 12.0),
    };
    for (final width in [900.0, 1200.0, 1440.0, 1920.0]) {
      for (final MapEntry(key: name, value: (range, spacing))
          in ranges.entries) {
        test('$name at ${width.round()} px: each stop its own columns', () {
          final stops = thumbStops(width, range, spacing);
          expect(stops.length, greaterThan(2));
          for (var i = 0; i < stops.length; i++) {
            final s = stops[i];
            // M80: up to 800 px, at least two per row.
            expect(s.tile, inInclusiveRange(range.min, maxCardWidth));
            expect(s.columns, greaterThanOrEqualTo(minThumbColumns));
            // The tiles and gaps fill the width exactly.
            expect(
              s.tile * s.columns + spacing * (s.columns - 1),
              closeTo(width, 1e-6),
            );
            if (i > 0) {
              // Smallest first; neighbours one column apart, so the card
              // size always changes.
              expect(stops[i - 1].columns, s.columns + 1);
              expect(s.tile, greaterThan(stops[i - 1].tile));
            }
            // A saved stop maps back to its own column count, also after
            // a JSON round trip and a little float error.
            for (final saved in [
              s.tile,
              double.parse(s.tile.toString()),
              s.tile + 1e-9,
              s.tile - 1e-9,
            ]) {
              expect(
                thumbStop(width, saved, range, spacing).columns,
                s.columns,
              );
            }
          }
          // Every column count from two whose tile fits has a stop.
          final counts = stops.map((s) => s.columns).toSet();
          for (var n = 1; n < 40; n++) {
            final tile = (width - spacing * (n - 1)) / n;
            expect(
              counts.contains(n),
              n >= 2 && tile >= range.min && tile <= maxCardWidth,
              reason: 'n=$n tile=$tile',
            );
          }
        });
      }
    }

    test('a grid narrower than the range still gets one stop', () {
      // M80: two narrower cards, so it stays a grid.
      expect(thumbStops(100, dashboardTileRange, 12), [
        (columns: 2, tile: 44.0),
      ]);
      expect(thumbStops(0, dashboardTileRange, 12), hasLength(1));
    });

    test('the old values pick their nearest stop', () {
      // 1408 px: 240, 260 and 280 were all 6 columns of 224.7 px before.
      for (final saved in [240.0, 260.0, 280.0]) {
        final s = thumbStop(1408, saved, dashboardTileRange, 12);
        expect(s.tile, inInclusiveRange(saved - 40, saved + 40));
      }
      expect(
        thumbStop(1408, 240, dashboardTileRange, 12).columns,
        isNot(thumbStop(1408, 280, dashboardTileRange, 12).columns),
      );
    });

    test('ThumbScale.step moves one stop, kept at the ends', () {
      final scale = ThumbScale(imageThumbRange, spacing: 8);
      addTearDown(scale.dispose);
      // No width yet: whole range steps.
      expect(scale.step(160, 1), 180);
      scale.width.value = 1200;
      final stops = thumbStops(1200, imageThumbRange, 8);
      final i = nearestStop(stops, 160);
      expect(scale.step(160, 1), stops[i + 1].tile);
      expect(scale.step(160, -1), stops[i - 1].tile);
      expect(scale.step(160, 99), stops.last.tile);
      expect(scale.step(160, -99), stops.first.tile);
    });

    Future<List<double>> pump(
      WidgetTester tester, {
      Size size = const Size(1200, 800),
      double initial = 160,
    }) async {
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final saved = <double>[];
      await tester.pumpWidget(
        MaterialApp(
          home: _Harness(
            range: imageThumbRange,
            initial: initial,
            onSaved: saved.add,
          ),
        ),
      );
      // The grid reports its width after the first frame.
      await tester.pump();
      return saved;
    }

    double card(WidgetTester tester) =>
        tester.getSize(find.byKey(const ValueKey('card0'))).width;
    // The harness grid's stops: its size without the 16 px padding, a
    // square card over a 40 px footer.
    List<ThumbStop> gridStops(WidgetTester tester) {
      final grid = tester.getSize(find.byType(GridView));
      return thumbStops(
        grid.width - 32,
        imageThumbRange,
        8,
        height: grid.height - 32,
        tileHeight: (w) => w + 40,
      );
    }

    Slider slider(WidgetTester tester) =>
        tester.widget<Slider>(find.byKey(const ValueKey('thumb-slider')));

    testWidgets('dragging through every stop changes the card each time', (
      tester,
    ) async {
      await pump(tester);
      final stops = gridStops(tester);
      expect(slider(tester).divisions, stops.length - 1);
      final seen = <double>[];
      for (var i = 0; i < stops.length; i++) {
        slider(tester).onChanged!(i.toDouble());
        await tester.pump();
        expect(card(tester), closeTo(stops[i].tile, 0.01));
        if (seen.isNotEmpty) expect(card(tester), isNot(seen.last));
        seen.add(card(tester));
        // M80: no value popup; the tooltip gives the cards per row.
        expect(slider(tester).label, isNull);
        expect(
          find.byTooltip('${stops[i].columns} per row (Ctrl + mouse wheel)'),
          findsOneWidget,
        );
      }
      expect(seen.toSet(), hasLength(stops.length));
    });

    testWidgets('± and Ctrl + wheel move one stop, disabled at the ends', (
      tester,
    ) async {
      await pump(tester);
      final stops = gridStops(tester);
      int at() => nearestStop(stops, card(tester));
      final start = at();
      await tester.tap(find.byTooltip('Larger'));
      await tester.pump();
      expect(at(), start + 1);
      await tester.tap(find.byTooltip('Smaller'));
      await tester.pump();
      await tester.tap(find.byTooltip('Smaller'));
      await tester.pump();
      expect(at(), start - 1);

      final grid = tester.getCenter(find.byType(GridView));
      final pointer = TestPointer(1, PointerDeviceKind.mouse);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendEventToBinding(pointer.hover(grid));
      await tester.sendEventToBinding(pointer.scroll(const Offset(0, -50)));
      await tester.pump();
      expect(at(), start);
      await tester.sendEventToBinding(pointer.scroll(const Offset(0, 50)));
      await tester.pump();
      expect(at(), start - 1);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);

      IconButton button(String tip) => tester.widget<IconButton>(
        find.ancestor(
          of: find.byTooltip(tip),
          matching: find.byType(IconButton),
        ),
      );
      while (button('Smaller').onPressed != null) {
        await tester.tap(find.byTooltip('Smaller'));
        await tester.pump();
      }
      expect(at(), 0);
      expect(card(tester), closeTo(stops.first.tile, 0.01));
      while (button('Larger').onPressed != null) {
        await tester.tap(find.byTooltip('Larger'));
        await tester.pump();
      }
      expect(at(), stops.length - 1);
      expect(button('Smaller').onPressed, isNotNull);
    });

    testWidgets('a resize keeps the nearest stop; the slider stays on one', (
      tester,
    ) async {
      final saved = await pump(tester, size: const Size(1440, 800));
      // The saved width (the harness starts at 160).
      const before = 160.0;
      for (final w in [1300.0, 1100.0, 1700.0, 1920.0]) {
        await tester.binding.setSurfaceSize(Size(w, 800));
        await tester.pump();
        await tester.pump();
        final stops = gridStops(tester);
        // The grid shows a stop of the new width, the one nearest the
        // saved width (unchanged: a resize saves nothing).
        expect(
          card(tester),
          closeTo(stops[nearestStop(stops, before)].tile, 0.01),
        );
        // The slider sits exactly on that stop.
        final s = slider(tester);
        expect(s.divisions, stops.length - 1);
        expect(s.value, nearestStop(stops, before).toDouble());
        expect(s.label, isNull);
      }
      // Resizing saved nothing.
      expect(saved, isEmpty);
    });
  });
}

void m80() {
  group('M80 stops up to the grid height', () {
    // The grids' tile heights: dashboard (pack tiles), Images tab (square
    // over the item footer, as the harness).
    final grids = {
      'dashboard': (dashboardTileRange, 12.0, packTileMaxHeight),
      'images': (imageThumbRange, 8.0, (double w) => w + 40),
    };
    double tileOf(double w, double spacing, int n) =>
        (w - spacing * (n - 1)) / n;
    // Grid width × scroll height for 1440×900 and 1920×1080 windows (the
    // toolbar and padding taken off), and a short pack-page grid.
    for (final (w, h) in [(1408.0, 740.0), (1888.0, 920.0), (1248.0, 240.0)]) {
      for (final MapEntry(key: name, value: (range, spacing, tileHeight))
          in grids.entries) {
        test('$name ${w.round()}×${h.round()}: old stops kept, bigger ones '
            'only when they fit the height', () {
          final stops = thumbStops(
            w,
            range,
            spacing,
            height: h,
            tileHeight: tileHeight,
          );
          final counts = stops.map((s) => s.columns).toSet();
          for (var n = 1; n < 40; n++) {
            final tile = tileOf(w, spacing, n);
            if (tile < range.min) break;
            final want =
                n >= minThumbColumns &&
                tile <= maxCardWidth &&
                (tile <= range.max || tileHeight(tile) <= h);
            expect(counts.contains(n), want, reason: 'n=$n tile=$tile');
          }
          for (var i = 1; i < stops.length; i++) {
            expect(stops[i - 1].columns, stops[i].columns + 1);
          }
        });
      }
    }

    test('a tall window: two per row at most, never over 800 px', () {
      for (final MapEntry(value: (range, spacing, tileHeight))
          in grids.entries) {
        final small = thumbStops(
          1000,
          range,
          spacing,
          height: 2000,
          tileHeight: tileHeight,
        );
        expect(small.last, (columns: 2, tile: tileOf(1000, spacing, 2)));
        final wide = thumbStops(
          1888,
          range,
          spacing,
          height: 4000,
          tileHeight: tileHeight,
        );
        expect(wide.last.columns, 3);
        expect(wide.last.tile, lessThanOrEqualTo(maxCardWidth));
        expect(wide.last.tile, greaterThan(range.max));
      }
    });

    test('a short grid keeps the stops it had before M80', () {
      final stops = thumbStops(
        900,
        imageThumbRange,
        8,
        height: 50,
        tileHeight: (w) => w + 40,
      );
      expect(
        stops,
        thumbStops(900, imageThumbRange, 8).where((s) => s.tile <= 400),
      );
      expect(stops.last.tile, lessThanOrEqualTo(imageThumbRange.max));
    });

    test('a saved card too tall for the height uses the largest that fits', () {
      double th(double w) => w + 40;
      final s = thumbStop(
        1200,
        800,
        imageThumbRange,
        8,
        height: 500,
        tileHeight: th,
      );
      final stops = thumbStops(
        1200,
        imageThumbRange,
        8,
        height: 500,
        tileHeight: th,
      );
      expect(s, stops.last);
      expect(s.columns, 3);
    });

    testWidgets('a pack tile with every line stays within its max height', (
      tester,
    ) async {
      await loadAppFonts();
      await tester.binding.setSurfaceSize(const Size(1200, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      for (final w in [200.0, 480.0, 1000.0]) {
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(
              colorSchemeSeed: Colors.teal,
              fontFamily: 'Roboto',
            ),
            home: Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                // As the dashboard's rows lay it out.
                child: SizedBox(
                  width: w,
                  child: IntrinsicHeight(
                    child: PackTile(
                      pack: longPack(1),
                      showTags: true,
                      fileMatches: '12 files match: a.png, b.png',
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        expect(
          tester.getSize(find.byType(PackTile)).height,
          lessThanOrEqualTo(packTileMaxHeight(w)),
          reason: 'width $w',
        );
      }
    });

    testWidgets('dragging to the top stop: the card fits the viewport', (
      tester,
    ) async {
      for (final size in [const Size(1200, 800), const Size(900, 500)]) {
        await tester.binding.setSurfaceSize(size);
        await tester.pumpWidget(
          MaterialApp(home: _Harness(range: imageThumbRange, initial: 160)),
        );
        await tester.pump();
        final s = find.byKey(const ValueKey('thumb-slider'));
        final slider = tester.widget<Slider>(s);
        slider.onChanged!(slider.divisions!.toDouble());
        await tester.pump();
        await tester.pump();
        final card = tester.getSize(find.byKey(const ValueKey('card0')));
        final grid = tester.getSize(find.byType(GridView));
        // A card over the old 400 px fits the height whole.
        if (card.width > 400) {
          expect(card.height, lessThanOrEqualTo(grid.height - 32));
        }
        // Bigger than the old cap where the height allows it.
        if (size.height == 800) expect(card.width, greaterThan(400));
        expect(card.width, lessThanOrEqualTo(maxCardWidth));
        expect(tester.widget<Slider>(s).label, isNull);
        expect(
          find.byWidgetPredicate(
            (w) => w is Tooltip && (w.message ?? '').contains('px'),
          ),
          findsNothing,
        );
        await tester.pumpWidget(const SizedBox());
      }
      await tester.binding.setSurfaceSize(null);
    });

    testWidgets('a resize caps a large saved stop by the height', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1200, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final saved = <double>[];
      await tester.pumpWidget(
        MaterialApp(
          home: _Harness(
            range: imageThumbRange,
            initial: 4000,
            onSaved: saved.add,
          ),
        ),
      );
      await tester.pump();
      for (final h in [900.0, 600.0, 400.0, 900.0]) {
        await tester.binding.setSurfaceSize(Size(1200, h));
        await tester.pump();
        await tester.pump();
        final card = tester.getSize(find.byKey(const ValueKey('card0')));
        final grid = tester.getSize(find.byType(GridView));
        final stops = thumbStops(
          grid.width - 32,
          imageThumbRange,
          8,
          height: grid.height - 32,
          tileHeight: (w) => w + 40,
        );
        expect(card.width, closeTo(stops.last.tile, 0.01), reason: 'h=$h');
        if (card.width > 400) {
          expect(card.height, lessThanOrEqualTo(grid.height - 32));
        }
        final s = tester.widget<Slider>(
          find.byKey(const ValueKey('thumb-slider')),
        );
        expect(s.value, stops.length - 1.0);
      }
      expect(saved, isEmpty);
    });
  });

  group('M80 decode sizes follow the card', () {
    test('decodeEdgeFor: 256 px buckets, never below today\'s 768', () {
      expect(decodeEdgeFor(200, 1), maxDecodeEdge);
      expect(decodeEdgeFor(768, 1), 768);
      expect(decodeEdgeFor(769, 1), 1024);
      expect(decodeEdgeFor(1000, 1), 1024);
      expect(decodeEdgeFor(1000, 2), 2048);
      expect(decodeEdgeFor(1100, 1.5), 1792);
      expect(decodeEdgeFor(double.infinity, 1), maxDecodeEdge);
      // Small moves inside a bucket keep the same decode.
      expect(decodeEdgeFor(1030, 1), decodeEdgeFor(1100, 1));
    });

    test('materialDecodeWidth: buckets, at most 4096', () {
      expect(materialDecodeWidth(10), 256);
      expect(materialDecodeWidth(300), 512);
      expect(materialDecodeWidth(512), 512);
      expect(materialDecodeWidth(9000), 4096);
    });

    testWidgets('a big card decodes at its bucket, a small one at 768', (
      tester,
    ) async {
      final dir = Directory.systemTemp.createTempSync('m80_decode');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File(p.join(dir.path, 'big.png'));
      await tester.runAsync(() async {
        final rec = ui.PictureRecorder();
        Canvas(rec).drawRect(
          const Rect.fromLTWH(0, 0, 2400, 1200),
          Paint()..color = Colors.teal,
        );
        final img = await rec.endRecording().toImage(2400, 1200);
        final png = await img.toByteData(format: ui.ImageByteFormat.png);
        file.writeAsBytesSync(png!.buffer.asUint8List());
      });
      int? decodedWidth() {
        final raw = find.byType(RawImage);
        if (raw.evaluate().isEmpty) return null;
        return tester.widget<RawImage>(raw).image?.width;
      }

      Future<void> show(double side) async {
        await tester.pumpWidget(
          MediaQuery(
            data: const MediaQueryData(devicePixelRatio: 1),
            child: Center(
              child: SizedBox.square(dimension: side, child: PixelImage(file)),
            ),
          ),
        );
        for (var i = 0; i < 20; i++) {
          await tester.runAsync(
            () => Future.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump();
        }
      }

      await tester.binding.setSurfaceSize(const Size(1600, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await show(300);
      expect(decodedWidth(), 768);
      await show(1000);
      expect(decodedWidth(), 1024);
      await show(1100);
      expect(decodedWidth(), 1280);
      await tester.pumpWidget(const SizedBox());
    });
  });
}
