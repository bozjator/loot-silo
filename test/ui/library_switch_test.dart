import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loot_silo/core/library_index.dart';
import 'package:loot_silo/state/dashboard.dart';
import 'package:loot_silo/state/itch.dart';
import 'package:loot_silo/state/providers.dart';
import 'package:loot_silo/state/settings.dart';
import 'package:loot_silo/ui/app.dart';
import 'package:loot_silo/ui/pack_detail_screen.dart';
import 'package:loot_silo/ui/session.dart';
import 'package:loot_silo/ui/tabs.dart';
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
const bats = 'Other/Bats';

/// M96: switching the library folder closes the old library's tabs; a tab
/// whose pack went away shows a page with a way out.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late Directory tmp;
  late String lib;
  late String lib2;
  late File file;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('library_switch');
    lib = p.join(tmp.path, 'library');
    copyTree('test/fixtures/managed', lib);
    copyTree('test/fixtures/managed/HeroMaker/Slimes', p.join(lib, bats));
    lib2 = p.join(tmp.path, 'library2');
    copyTree('test/fixtures/managed/HeroMaker/Slimes', p.join(lib2, 'Slimes'));
    file = File(p.join(tmp.path, 'settings.json'));
    SettingsStore(file)
        .save(AppSettings(libraryPath: lib, resumeSession: false));
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  /// Real IO (scan, isolates) needs real time between frames.
  Future<void> wait(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 200 && !done(); i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    expect(done(), isTrue);
  }

  Future<ProviderContainer> start(WidgetTester tester) async {
    final index = LibraryIndex(NativeDatabase.memory());
    addTearDown(index.close);
    await tester.binding.setSurfaceSize(const Size(1600, 900));
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
    return c;
  }

  bool loaded(ProviderContainer c, String root) {
    final v = c.read(libraryProvider);
    return !v.isLoading && v.value?.root == root;
  }

  Future<void> quit(WidgetTester tester) async {
    await tester.pump(SessionKeeper.delay + const Duration(milliseconds: 100));
    await tester.pumpWidget(const SizedBox());
  }

  testWidgets('another library closes the tabs and clears the filters', (
    tester,
  ) async {
    final c = await start(tester);
    final tabs = c.read(tabsProvider.notifier)
      ..open(knight)
      ..open(slimes)
      ..open(bats);
    tabs.select(2);
    final query = c.read(dashboardQueryProvider.notifier)
      ..restore(
        const DashboardQuery(
          text: 'slime',
          authors: {'HeroMaker'},
          sort: PackSort.title,
        ),
      );
    expect(query, isNotNull);
    c.read(settingsProvider.notifier).setDashboardView(DashboardView.expanded);
    await tester.pump();

    // A rescan of the same folder keeps everything.
    unawaited(c.read(libraryProvider.notifier).rescan());
    await wait(tester, () => loaded(c, lib));
    expect(c.read(tabsProvider).tabs.map((t) => t.packId), [
      knight,
      slimes,
      bats,
    ]);
    expect(c.read(tabsProvider).active, 2);
    expect(c.read(dashboardQueryProvider).text, 'slime');
    final generation = c.read(libraryGenerationProvider);

    c.read(settingsProvider.notifier).setLibraryPath(lib2);
    await tester.pump();
    expect(c.read(tabsProvider).tabs, isEmpty);
    expect(c.read(tabsProvider).active, 0);
    final q = c.read(dashboardQueryProvider);
    expect(q.text, '');
    expect(q.authors, isEmpty);
    expect(q.isNarrowed, isFalse);
    // Preferences stay.
    expect(q.sort, PackSort.title);
    expect(c.read(settingsProvider).dashboardView, DashboardView.expanded);
    expect(c.read(libraryGenerationProvider), generation + 1);
    await wait(tester, () => loaded(c, lib2));
    // The search field follows the cleared query.
    final field = find.descendant(
      of: find.byKey(const ValueKey('tab-dashboard')),
      matching: find.byType(TextField),
    );
    expect(tester.widget<TextField>(field.first).controller!.text, '');
    expect(find.byType(MissingPackPage), findsNothing);

    // And back: still only the dashboard.
    c.read(settingsProvider.notifier).setLibraryPath(lib);
    await wait(tester, () => loaded(c, lib));
    expect(c.read(tabsProvider).tabs, isEmpty);
    await quit(tester);
  });

  testWidgets('a pack opened on the dashboard tab goes back to the grid', (
    tester,
  ) async {
    final c = await start(tester);
    c
        .read(tabsProvider.notifier)
        .dashboardNavigator
        .currentState!
        .push(
          MaterialPageRoute<void>(
            builder: (_) => const PackDetailScreen(packId: knight),
          ),
        );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(c.read(tabsProvider.notifier).dashboardTop.pages.value, 2);
    c.read(settingsProvider.notifier).setLibraryPath(lib2);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(c.read(tabsProvider.notifier).dashboardTop.pages.value, 1);
    await wait(tester, () => loaded(c, lib2));
    await quit(tester);
  });

  Future<ProviderContainer> vanish(WidgetTester tester) async {
    final c = await start(tester);
    c.read(tabsProvider.notifier)
      ..open(knight)
      ..open(slimes)
      ..select(2);
    await tester.pump();
    Directory(p.join(lib, slimes)).deleteSync(recursive: true);
    unawaited(c.read(libraryProvider.notifier).rescan());
    await wait(tester, () => loaded(c, lib));
    await wait(
      tester,
      () => find.byType(MissingPackPage).evaluate().isNotEmpty,
    );
    // Not closed by itself: the user sees why the tab is empty.
    expect(c.read(tabsProvider).tabs.length, 2);
    expect(find.text('This pack is no longer in the library'), findsOneWidget);
    return c;
  }

  testWidgets('Close tab on a vanished pack shows the left neighbour', (
    tester,
  ) async {
    final c = await vanish(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Close tab'));
    await tester.pump();
    expect(c.read(tabsProvider).tabs.map((t) => t.packId), [knight]);
    expect(c.read(tabsProvider).active, 1);
    await quit(tester);
  });

  testWidgets('Esc on a vanished pack closes its tab', (tester) async {
    final c = await vanish(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(c.read(tabsProvider).tabs.map((t) => t.packId), [knight]);
    expect(c.read(tabsProvider).active, 1);
    await quit(tester);
  });
}
