import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:loot_silo/core/library_index.dart';
import 'package:loot_silo/state/dashboard.dart';
import 'package:loot_silo/state/folder_tree.dart';
import 'package:loot_silo/state/itch.dart';
import 'package:loot_silo/state/providers.dart';
import 'package:loot_silo/state/settings.dart';
import 'package:loot_silo/ui/app.dart';
import 'package:loot_silo/ui/folder_tree_panel.dart';
import 'package:loot_silo/ui/session.dart';
import 'package:loot_silo/ui/tabs.dart';
import 'package:loot_silo/ui/widgets/pack_tile.dart';
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

const knight = 'HeroMaker/Knight Pack';
const slimes = 'HeroMaker/Slimes';
const tiles = 'Pixel/Tiles';

/// M98: the folder tree panel on the dashboard.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late Directory tmp;
  late String lib;
  late File file;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('tree_panel');
    lib = p.join(tmp.path, 'library');
    copyTree('test/fixtures/managed', lib);
    final png = img.encodePng(img.Image(width: 8, height: 8));
    for (final rel in ['PNG/Default/a.png', 'PNG/Default/b.png', 'c.png']) {
      File(p.join(lib, tiles, rel))
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(png);
    }
    File(p.join(lib, tiles, 'License.txt')).writeAsStringSync('CC0');
    file = File(p.join(tmp.path, 'settings.json'));
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  Future<void> wait(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 300 && !done(); i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    expect(done(), isTrue);
  }

  Future<ProviderContainer> start(
    WidgetTester tester, {
    AppSettings? settings,
    Size size = const Size(1600, 900),
  }) async {
    if (settings != null) SettingsStore(file).save(settings);
    final index = LibraryIndex(NativeDatabase.memory());
    addTearDown(index.close);
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsStoreProvider.overrideWithValue(SettingsStore(file)),
          libraryIndexProvider.overrideWithValue(index),
          keyStoreProvider.overrideWithValue(_NoKey()),
          envKeyProvider.overrideWithValue(() => null),
        ],
        child: const LootSiloApp(),
      ),
    );
    final c = ProviderScope.containerOf(tester.element(find.byType(TabsHost)));
    await wait(tester, () => c.read(sessionKeeperProvider).started);
    await wait(tester, () => c.read(packsWithFoldersProvider).hasValue);
    return c;
  }

  Future<void> quit(WidgetTester tester) async {
    await tester.pump(SessionKeeper.delay + const Duration(milliseconds: 100));
    await tester.pumpWidget(const SizedBox());
  }

  Finder row(String path) => find.byKey(ValueKey('tree:$path'));
  final panel = find.byType(FolderTreePanel);
  final chip = find.byKey(const ValueKey('node-chip'));
  List<String> shownPacks(WidgetTester tester) => [
    for (final e in find.byType(PackTile).evaluate())
      (e.widget as PackTile).pack.id,
  ]..sort();

  AppSettings open({bool resume = false}) =>
      AppSettings(libraryPath: lib, resumeSession: resume);

  testWidgets('the toggle opens and closes the panel; saved for a restart', (
    tester,
  ) async {
    await start(tester, settings: open());
    expect(panel, findsNothing);
    await tester.tap(find.byKey(const ValueKey('folder-tree-toggle')));
    await tester.pump();
    expect(panel, findsOneWidget);
    expect(SettingsStore(file).load().dashboardTreeOpen, isTrue);
    await quit(tester);

    await start(tester);
    expect(panel, findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('folder-tree-toggle')));
    await tester.pump();
    expect(panel, findsNothing);
    expect(SettingsStore(file).load().dashboardTreeOpen, isFalse);
    await quit(tester);
  });

  testWidgets('dragging the divider changes and saves the width', (
    tester,
  ) async {
    await start(tester, settings: open().copyWith(dashboardTreeOpen: true));
    final side = find.byKey(const ValueKey('folder-tree-panel'));
    final before = tester.getSize(side).width;
    expect(before, AppSettings.defaultTreeWidth + 6);
    await tester.drag(
      find.byKey(const ValueKey('folder-tree-divider')),
      const Offset(120, 0),
    );
    await tester.pump();
    expect(tester.getSize(side).width, closeTo(before + 120, 1));
    expect(
      SettingsStore(file).load().dashboardTreeWidth,
      closeTo(AppSettings.defaultTreeWidth + 120, 1),
    );
    // Never past 40 % of the window.
    await tester.drag(
      find.byKey(const ValueKey('folder-tree-divider')),
      const Offset(2000, 0),
    );
    await tester.pump();
    expect(tester.getSize(side).width, closeTo(1600 * 0.4 + 6, 1));
    await quit(tester);
  });

  testWidgets('selecting filters; the chip shows it, × and a second click '
      'clear it', (tester) async {
    final c = await start(
      tester,
      settings: open().copyWith(dashboardTreeOpen: true),
    );
    await wait(tester, () => shownPacks(tester).length == 3);
    await tester.tap(row('HeroMaker'));
    await tester.pump();
    expect(shownPacks(tester), [knight, slimes]);
    expect(find.text('In: HeroMaker'), findsOneWidget);
    // Selecting opens it.
    expect(row(knight), findsOneWidget);

    await tester.tap(
      find.descendant(of: chip, matching: find.byIcon(Icons.clear)),
    );
    await tester.pump();
    expect(chip, findsNothing);
    expect(shownPacks(tester), hasLength(3));

    // A folder inside a pack: that pack only.
    await tester.tap(row('Pixel'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byKey(const ValueKey('tree-fold:$tiles')));
    await wait(tester, () => row('$tiles/PNG/Default').evaluate().isNotEmpty);
    expect(find.text('PNG / Default'), findsOneWidget);
    await tester.tap(row('$tiles/PNG/Default'));
    await tester.pump();
    expect(c.read(dashboardQueryProvider).node, '$tiles/PNG/Default');
    expect(shownPacks(tester), [tiles]);
    expect(find.text('In: Pixel › Tiles › PNG › Default'), findsOneWidget);

    // Clicking it again (not a double-click) clears it.
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(row('$tiles/PNG/Default'));
    await tester.pump();
    expect(c.read(dashboardQueryProvider).node, isNull);
    await quit(tester);
  });

  testWidgets('keyboard: Down, Right, Left, Enter', (tester) async {
    final c = await start(
      tester,
      settings: open().copyWith(dashboardTreeOpen: true),
    );
    await tester.tap(row('HeroMaker'));
    await tester.pump();
    // Back to nothing selected; the panel keeps the keyboard.
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(row('HeroMaker'));
    await tester.pump();
    c.read(treeExpandedProvider.notifier).set(const {});
    await tester.pump();
    // Rows: HeroMaker, Pixel.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(c.read(dashboardQueryProvider).node, 'Pixel');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(c.read(treeExpandedProvider), contains('HeroMaker'));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(c.read(dashboardQueryProvider).node, knight);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(c.read(treeExpandedProvider), isNot(contains('HeroMaker')));
    await quit(tester);
  });

  testWidgets('below 900 px the panel overlays the grid and closes on a '
      'selection', (tester) async {
    await start(
      tester,
      settings: open().copyWith(dashboardTreeOpen: true),
      size: const Size(860, 900),
    );
    await wait(tester, () => shownPacks(tester).length == 3);
    final side = tester.getRect(
      find.byKey(const ValueKey('folder-tree-panel')),
    );
    final grid = tester.getRect(find.byType(PackTile).first);
    expect(grid.left, lessThan(side.right), reason: 'under the panel');
    await tester.tap(row('HeroMaker'));
    await tester.pump();
    expect(panel, findsNothing);
    expect(shownPacks(tester), [knight, slimes]);
    await quit(tester);
  });

  testWidgets('a rescan that removes the selected pack clears the chip', (
    tester,
  ) async {
    final c = await start(
      tester,
      settings: open().copyWith(dashboardTreeOpen: true),
    );
    c.read(dashboardQueryProvider.notifier).setNode(slimes);
    await tester.pump();
    expect(chip, findsOneWidget);
    // A rescan that keeps it keeps it.
    unawaited(c.read(libraryProvider.notifier).rescan());
    await wait(tester, () => !c.read(libraryProvider).isLoading);
    await tester.pump();
    expect(c.read(dashboardQueryProvider).node, slimes);
    Directory(p.join(lib, slimes)).deleteSync(recursive: true);
    unawaited(c.read(libraryProvider.notifier).rescan());
    await wait(tester, () => c.read(dashboardQueryProvider).node == null);
    await tester.pump();
    expect(chip, findsNothing);
    await quit(tester);
  });

  testWidgets('expanded and selected nodes come back on resume', (
    tester,
  ) async {
    var c = await start(
      tester,
      settings: open(resume: true).copyWith(dashboardTreeOpen: true),
    );
    c.read(treeExpandedProvider.notifier).set({'Pixel', tiles});
    c.read(dashboardQueryProvider.notifier).setNode('$tiles/PNG/Default');
    await quit(tester);
    final saved = SettingsStore(file).load().lastSession!;
    expect(saved.node, '$tiles/PNG/Default');
    expect(saved.treeExpanded, ['Pixel', tiles]);

    c = await start(tester);
    expect(c.read(dashboardQueryProvider).node, '$tiles/PNG/Default');
    expect(c.read(treeExpandedProvider), {'Pixel', tiles});
    await wait(tester, () => row('$tiles/PNG/Default').evaluate().isNotEmpty);
    await quit(tester);
  });

  test('dashboard_tree_open / _width round-trip', () {
    final dir = Directory.systemTemp.createTempSync('tree_settings');
    addTearDown(() => dir.deleteSync(recursive: true));
    final store = SettingsStore(File(p.join(dir.path, 'settings.json')));
    expect(store.load().dashboardTreeOpen, isFalse);
    expect(store.load().dashboardTreeWidth, AppSettings.defaultTreeWidth);
    store.save(
      const AppSettings(dashboardTreeOpen: true, dashboardTreeWidth: 333),
    );
    expect(store.load().dashboardTreeOpen, isTrue);
    expect(store.load().dashboardTreeWidth, 333);
    final text = File(p.join(dir.path, 'settings.json')).readAsStringSync();
    expect(text, contains('"dashboard_tree_open": true'));
    expect(text, contains('"dashboard_tree_width": 333'));
  });
}
