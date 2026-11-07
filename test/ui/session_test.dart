import 'dart:io';

import 'package:assets_explorer/core/library_index.dart';
import 'package:assets_explorer/state/dashboard.dart';
import 'package:assets_explorer/state/itch.dart';
import 'package:assets_explorer/state/providers.dart';
import 'package:assets_explorer/state/settings.dart';
import 'package:assets_explorer/ui/app.dart';
import 'package:assets_explorer/ui/session.dart';
import 'package:assets_explorer/ui/settings_screen.dart';
import 'package:assets_explorer/ui/tabs.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
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

const knight = 'HeroMaker/Knight Pack';
const slimes = 'HeroMaker/Slimes';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late Directory tmp;
  late String lib;
  late File file;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('session');
    lib = p.join(tmp.path, 'library');
    copyTree('test/fixtures/managed', lib);
    for (final rel in ['heroes/a.png', 'heroes/b.png', 'z.png']) {
      File(p.join(lib, knight, rel))
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(img.encodePng(img.Image(width: 8, height: 8)));
    }
    file = File(p.join(tmp.path, 'settings.json'));
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  test('resume_session and last_session round-trip', () {
    final store = SettingsStore(file);
    expect(store.load().resumeSession, isTrue);
    expect(store.load().lastSession, isNull);
    const session = LastSession(
      tabs: [
        PageSession(packId: knight, folder: 'heroes', tab: 'images'),
        PageSession(packId: slimes, search: 'blue', favorites: true),
      ],
      active: 2,
      dashboardPage: PageSession(packId: slimes, tab: 'files'),
      search: 'slime',
      types: ['character'],
      authors: ['HeroMaker'],
      tags: ['knight'],
      sources: ['manual'],
      favorites: true,
      sort: 'title',
      bundleId: 'Some/Bundle',
    );
    store.save(const AppSettings(libraryPath: '/lib', lastSession: session));
    final back = store.load();
    expect(back.lastSession, session);
    expect(back.resumeSession, isTrue);
    final text = file.readAsStringSync();
    expect(text, contains('"last_session"'));
    expect(text, contains('"dashboard_page"'));
    expect(text, contains('"pack_id": "HeroMaker/Knight Pack"'));
    expect(text, contains('"bundle_id": "Some/Bundle"'));
    store.save(const AppSettings(resumeSession: false));
    expect(store.load().resumeSession, isFalse);
    expect(file.readAsStringSync(), contains('"resume_session": false'));
    expect(file.readAsStringSync(), isNot(contains('last_session')));
    // Empty values aren't written; a bare page reads back the same.
    expect(const PageSession(packId: 'a').toJson(), {'pack_id': 'a'});
    expect(
      PageSession.fromJson(const {'pack_id': 'a'}),
      const PageSession(packId: 'a'),
    );
  });

  /// Starts the app on [file]; a fresh index each time, as after a restart.
  Future<ProviderContainer> start(WidgetTester tester) async {
    final index = LibraryIndex(NativeDatabase.memory());
    addTearDown(index.close);
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsStoreProvider.overrideWithValue(SettingsStore(file)),
          libraryIndexProvider.overrideWithValue(index),
          keyStoreProvider.overrideWithValue(_NoKey()),
          envKeyProvider.overrideWithValue(() => null),
        ],
        child: const AssetsExplorerApp(),
      ),
    );
    final c = ProviderScope.containerOf(tester.element(find.byType(TabsHost)));
    for (var i = 0; i < 200 && !c.read(sessionKeeperProvider).started; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    expect(c.read(sessionKeeperProvider).started, isTrue);
    // Pack contents load on real IO too.
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await tester.pump();
    }
    return c;
  }

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

  /// Quits: lets the save timer run, then drops the whole tree.
  Future<void> quit(WidgetTester tester) async {
    await tester.pump(SessionKeeper.delay + const Duration(milliseconds: 100));
    await tester.pumpWidget(const SizedBox());
  }

  testWidgets('tabs, filters and pack page state come back after a restart', (
    tester,
  ) async {
    SettingsStore(file).save(AppSettings(libraryPath: lib));
    var c = await start(tester);
    c
        .read(dashboardQueryProvider.notifier)
        .restore(
          const DashboardQuery(
            tags: {'knight'},
            sort: PackSort.title,
            favorites: false,
          ),
        );
    final tabs = c.read(tabsProvider.notifier)
      ..open(slimes)
      ..open(knight);
    tabs.select(2);
    // The Knight tab's page: a file search.
    final field = find.descendant(
      of: find.byKey(const ValueKey('tab-1')),
      matching: find.byType(TextField),
    );
    await pumpUntil(tester, field);
    await tester.enterText(field, 'a');
    await tester.pump(DashboardQueryNotifier.searchDebounce);
    await quit(tester);

    final saved = SettingsStore(file).load().lastSession!;
    expect(saved.tabs.map((t) => t.packId), [slimes, knight]);
    expect(saved.active, 2);
    expect(saved.tabs[1].search, 'a');
    expect(saved.tags, ['knight']);
    expect(saved.sort, 'title');

    c = await start(tester);
    final restored = c.read(tabsProvider);
    expect(restored.tabs.map((t) => t.packId), [slimes, knight]);
    expect(restored.active, 2);
    expect(c.read(dashboardQueryProvider).tags, {'knight'});
    expect(c.read(dashboardQueryProvider).sort, PackSort.title);
    final again = find.descendant(
      of: find.byKey(const ValueKey('tab-1')),
      matching: find.byType(TextField),
    );
    await pumpUntil(tester, again);
    expect(tester.widget<TextField>(again).controller!.text, 'a');
    await quit(tester);
  });

  testWidgets('nothing is restored with the setting off', (tester) async {
    SettingsStore(file).save(
      AppSettings(
        libraryPath: lib,
        resumeSession: false,
        lastSession: const LastSession(
          tabs: [PageSession(packId: knight)],
          active: 1,
          search: 'knight',
        ),
      ),
    );
    final c = await start(tester);
    expect(c.read(tabsProvider).tabs, isEmpty);
    expect(c.read(dashboardQueryProvider).text, '');
    c.read(tabsProvider.notifier).open(slimes);
    await quit(tester);
    expect(SettingsStore(file).load().lastSession, isNull);
  });

  testWidgets('a deleted pack and an unknown tag are dropped quietly', (
    tester,
  ) async {
    SettingsStore(file).save(
      AppSettings(
        libraryPath: lib,
        lastSession: const LastSession(
          tabs: [
            PageSession(packId: 'HeroMaker/Gone'),
            PageSession(packId: slimes),
          ],
          active: 2,
          search: 'slime',
          tags: ['knight', 'no-such-tag'],
          authors: ['Nobody'],
          sort: 'bogus',
          bundleId: 'HeroMaker/Gone',
          dashboardPage: PageSession(packId: 'HeroMaker/Gone'),
        ),
      ),
    );
    final c = await start(tester);
    final tabs = c.read(tabsProvider);
    expect(tabs.tabs.map((t) => t.packId), [slimes]);
    expect(tabs.active, 1);
    final q = c.read(dashboardQueryProvider);
    expect(q.text, 'slime');
    expect(q.tags, {'knight'});
    expect(q.authors, isEmpty);
    expect(q.sort, PackSort.relevance);
    expect(q.bundleId, isNull);
    // The dashboard search field shows the restored text.
    c.read(tabsProvider.notifier).select(0);
    await pumpUntil(
      tester,
      find.descendant(
        of: find.byKey(const ValueKey('tab-dashboard')),
        matching: find.widgetWithText(TextField, 'slime'),
      ),
    );
    await quit(tester);
  });

  testWidgets('Settings has the switch; turning it off forgets the session', (
    tester,
  ) async {
    SettingsStore(file).save(
      AppSettings(
        libraryPath: lib,
        lastSession: const LastSession(tabs: [PageSession(packId: knight)]),
      ),
    );
    final c = await start(tester);
    await tester.tap(find.byTooltip('Settings (Ctrl+,)').first);
    await tester.pumpAndSettle();
    expect(find.byType(SettingsScreen), findsOneWidget);
    final tile = find.byKey(const ValueKey('resume-session'));
    await tester.scrollUntilVisible(tile, 200);
    expect(find.text('Resume where I left off'), findsOneWidget);
    await tester.tap(tile);
    await tester.pumpAndSettle();
    expect(c.read(settingsProvider).resumeSession, isFalse);
    expect(SettingsStore(file).load().lastSession, isNull);
    expect(SettingsStore(file).load().resumeSession, isFalse);
    await quit(tester);
  });

  test('restoredQuery keeps only values some pack has', () {
    // Exercised through the widget tests; the facets of PackRow come from
    // the index, so this only checks the sort fallback without packs.
    final q = restoredQuery(
      const LastSession(sort: 'author', sources: [noSource]),
      const [],
    );
    expect(q.sort, PackSort.author);
    expect(q.sources, {noSource});
  });
}
