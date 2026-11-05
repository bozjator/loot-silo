import 'dart:io';

import 'package:assets_explorer/core/library_index.dart';
import 'package:assets_explorer/state/itch.dart';
import 'package:assets_explorer/state/dashboard.dart';
import 'package:assets_explorer/state/providers.dart';
import 'package:assets_explorer/state/settings.dart';
import 'package:assets_explorer/ui/app.dart';
import 'package:assets_explorer/ui/image_viewer.dart';
import 'package:assets_explorer/ui/widgets/pack_tile.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import '../helpers/fs.dart';

class _NoKey implements KeyStore {
  @override
  Future<String?> read() async => null;
  @override
  Future<void> write(String key) async {}
  @override
  Future<void> delete() async {}
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late Directory tmp;
  late SettingsStore store;
  setUp(() => tmp = Directory.systemTemp.createTempSync('detail'));
  tearDown(() => tmp.deleteSync(recursive: true));

  /// Real IO (scan, isolates) needs real time between frames.
  Future<void> pumpUntil(WidgetTester tester, Finder finder) async {
    for (var i = 0; i < 200 && finder.evaluate().isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    expect(finder, findsWidgets);
  }

  /// Opens Knight Pack, with images in the root and two sub-folders.
  Future<void> openKnight(
    WidgetTester tester, {
    Size size = const Size(1400, 900),
    List<String> files = const [
      'heroes/knight_red/a.png',
      'heroes/knight_red/b.png',
      'heroes/archer/c.png',
      'heroes/archer/d.png',
      'z_root.png',
    ],
    bool open = true,
    Map<String, img.Image> images = const {},
  }) async {
    final lib = p.join(tmp.path, 'library');
    copyTree('test/fixtures/managed', lib);
    final pack = p.join(lib, 'HeroMaker', 'Knight Pack');
    for (final rel in files) {
      File(p.join(pack, rel))
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(img.encodePng(img.Image(width: 8, height: 8)));
    }
    for (final MapEntry(key: rel, value: image) in images.entries) {
      File(p.join(pack, rel))
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(img.encodePng(image));
    }
    store = SettingsStore(File(p.join(tmp.path, 'settings.json')))
      ..save(AppSettings(libraryPath: lib));
    final index = LibraryIndex(NativeDatabase.memory());
    addTearDown(index.close);
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsStoreProvider.overrideWithValue(store),
          libraryIndexProvider.overrideWithValue(index),
          keyStoreProvider.overrideWithValue(_NoKey()),
          envKeyProvider.overrideWithValue(() => null),
        ],
        child: const AssetsExplorerApp(),
      ),
    );
    await pumpUntil(tester, find.text('Knight Pack'));
    if (!open) return;
    await tester.tap(find.text('Knight Pack'));
    await pumpUntil(tester, find.textContaining('Images ('));
    // Let the page finish sliding in.
    await tester.pump(const Duration(seconds: 1));
  }

  testWidgets('unpinned header is a slim bar; hover shows it floating', (
    tester,
  ) async {
    await openKnight(tester);
    expect(find.text('Hover for details'), findsNothing);
    final tabsTop = tester.getTopLeft(find.byType(TabBar)).dy;

    await tester.tap(find.byTooltip('Unpin header — show it on hover (H)'));
    await tester.pump();
    expect(store.load().detailHeaderPinned, isFalse);
    expect(find.text('Hover for details'), findsOneWidget);
    expect(find.text('Used in'), findsNothing);
    final unpinnedTop = tester.getTopLeft(find.byType(TabBar)).dy;
    expect(unpinnedTop, lessThan(tabsTop - 200));

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(700, 890));
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.text('Hover for details')));
    await tester.pump();
    expect(find.text('Used in'), findsOneWidget);
    // Floating: the tabs didn't move.
    expect(tester.getTopLeft(find.byType(TabBar)).dy, unpinnedTop);
    await mouse.moveTo(const Offset(700, 890));
    await tester.pump();
    expect(find.text('Used in'), findsNothing);

    // H pins it again.
    await tester.sendKeyEvent(LogicalKeyboardKey.keyH);
    await tester.pump();
    expect(store.load().detailHeaderPinned, isTrue);
    expect(find.text('Used in'), findsOneWidget);
    expect(find.text('Hover for details'), findsNothing);
  });

  testWidgets('images by folder; the viewer follows the grouped order', (
    tester,
  ) async {
    await openKnight(tester, size: const Size(1400, 1600));
    await tester.tap(find.textContaining('Images ('));
    await tester.pumpAndSettle();
    await tester.tap(find.text('By folder'));
    await tester.pump();
    expect(store.load().imagesView, ItemsView.folders);
    expect(find.text('Pack root'), findsOneWidget);
    expect(find.text('Heroes / Archer'), findsOneWidget);
    expect(find.text('Heroes / Knight red'), findsOneWidget);

    // Root: knight.png, z_root.png; archer/c, d; knight_red/a, b.
    await tester.tap(find.text('z_root.png'));
    await tester.pumpAndSettle();
    expect(find.text('2 / 6'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(find.text('C'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(ImageViewer), findsNothing);

    // Folding a folder takes its images out of the viewer's list.
    await tester.tap(find.text('Heroes / Archer'));
    await tester.pump();
    await tester.tap(find.text('a.png'));
    await tester.pumpAndSettle();
    expect(find.text('3 / 4'), findsOneWidget);
  });

  testWidgets('expanded tiles open the pack at their folder', (tester) async {
    await openKnight(
      tester,
      files: ['Archer/c.png', 'Archer/d.png', 'Mage/e.png'],
      open: false,
    );
    expect(find.text('Archer'), findsNothing);
    await tester.tap(find.text('Expanded'));
    await pumpUntil(tester, find.text('Mage'));
    expect(store.load().dashboardView, DashboardView.expanded);
    expect(find.text('Archer'), findsOneWidget);
    // The pack title is the folder tiles' subtitle.
    expect(find.text('Knight Pack'), findsNWidgets(2));

    await tester.tap(find.text('Mage'));
    await pumpUntil(tester, find.textContaining('Images ('));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Images (1)'), findsOneWidget);
    expect(find.byTooltip('Show the whole pack'), findsOneWidget);
    await tester.tap(find.textContaining('Images ('));
    await tester.pumpAndSettle();
    expect(find.text('e.png'), findsOneWidget);
    expect(find.text('c.png'), findsNothing);

    await tester.tap(find.text('Show whole pack'));
    await tester.pumpAndSettle();
    expect(find.text('Images (4)'), findsOneWidget);
    expect(find.byTooltip('Show the whole pack'), findsNothing);
  });

  testWidgets('sorting by tags adds each tile\'s tags, sorted', (tester) async {
    await openKnight(tester, open: false);
    expect(find.textContaining('No tags'), findsNothing);
    await tester.tap(find.byType(DropdownButton<PackSort>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Tags').last);
    await tester.pumpAndSettle();
    final tags = tester.widget<Text>(
      find
          .descendant(
            of: find.byType(PackTile),
            matching: find.byWidgetPredicate(
              (w) => w is Text && (w.data ?? '').contains(','),
            ),
          )
          .first,
    );
    expect(tags.data, 'knight, pixel-art');
    // The type chips stay.
    expect(
      find.descendant(
        of: find.byType(PackTile),
        matching: find.text('character'),
      ),
      findsWidgets,
    );
    final shown = tags.data!.split(', ');
    expect(shown, sortedTags(shown));
  });

  testWidgets('Frames field re-slices a strip; numbered props are images', (
    tester,
  ) async {
    // A 24-cell strip that really holds 16 frames of 24 px, plus numbered
    // props without an animation word.
    final strip = img.Image(width: 384, height: 16, numChannels: 4);
    img.fill(strip, color: img.ColorRgba8(200, 80, 40, 255));
    await openKnight(
      tester,
      files: [for (var i = 0; i < 4; i++) 'props/barrels_$i.png'],
      images: {'Animated stuff/chimney-smoke.png': strip},
    );
    expect(find.textContaining('Animations (1)'), findsOneWidget);
    await tester.tap(find.textContaining('Animations ('));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.byTooltip('Edit animation'));
    await pumpUntil(tester, find.text('Apply size'));
    expect(find.text('Sheet · 16×16 frames · 24 × 1 · 24 frames'), findsOne);

    final frames = find.widgetWithText(TextField, 'Frames');
    await tester.enterText(frames, '7');
    await tester.pump();
    expect(find.text("Doesn't fit 384 px"), findsOneWidget);
    expect(find.text('Sheet · 16×16 frames · 24 × 1 · 24 frames'), findsOne);

    await tester.enterText(frames, '16');
    await tester.pump();
    expect(find.text("Doesn't fit 384 px"), findsNothing);
    expect(find.text('Sheet · 24×16 frames · 16 × 1 · 16 frames'), findsOne);
    expect(
      tester
          .widget<TextField>(find.widgetWithText(TextField, 'Frame width'))
          .controller!
          .text,
      '24',
    );

    await tester.tap(find.text('Save'));
    await pumpUntil(tester, find.text('Reset to detected'));
    final sidecar = File(
      p.join(
        tmp.path,
        'library',
        'HeroMaker',
        'Knight Pack',
        'asset_pack.json',
      ),
    ).readAsStringSync();
    expect(sidecar, contains('"frames": 16'));
    expect(sidecar, isNot(contains('frame_w')));
  });
}
