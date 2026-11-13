import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loot_silo/core/library_index.dart';
import 'package:loot_silo/core/library_service.dart';
import 'package:loot_silo/state/itch.dart';
import 'package:loot_silo/state/providers.dart';
import 'package:loot_silo/state/settings.dart';
import 'package:loot_silo/ui/app.dart';
import 'package:loot_silo/ui/dashboard.dart';
import 'package:path/path.dart' as p;

import '../helpers/fs.dart';

/// Holds every load until [gate] completes (when one is set).
class _GatedService extends LibraryService {
  _GatedService(super.index);

  Completer<void>? gate;
  var loads = 0;

  @override
  Future<LoadResult> load(String root, {bool force = false}) async {
    loads++;
    if (gate case final g?) await g.future;
    return super.load(root, force: force);
  }
}

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
  setUp(() => tmp = Directory.systemTemp.createTempSync('wait'));
  tearDown(() => tmp.deleteSync(recursive: true));

  const waitTitle = 'Please wait while we scan your library';
  final wait = find.byKey(const ValueKey('library-wait'));
  final firstChoices = find.byKey(const ValueKey('first-choices'));

  /// A library with both fixture packs, or only Slimes.
  String library(String name, {bool knight = true}) {
    final dir = p.join(tmp.path, name);
    copyTree('test/fixtures/managed', dir);
    if (!knight) {
      Directory(p.join(dir, 'HeroMaker', 'Knight Pack'))
          .deleteSync(recursive: true);
    }
    return dir;
  }

  late _GatedService service;
  late SettingsStore store;
  late ProviderContainer container;

  Future<void> start(
    WidgetTester tester, {
    String? libraryPath,
    String? pick,
  }) async {
    store = SettingsStore(File(p.join(tmp.path, 'settings.json')))
      ..save(AppSettings(libraryPath: libraryPath));
    final index = LibraryIndex(NativeDatabase.memory());
    addTearDown(index.close);
    service = _GatedService(index);
    await tester.binding.setSurfaceSize(const Size(1600, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsStoreProvider.overrideWithValue(store),
          libraryIndexProvider.overrideWithValue(index),
          libraryServiceProvider.overrideWithValue(service),
          directoryPickerProvider.overrideWithValue((_) async => pick),
          keyStoreProvider.overrideWithValue(_NoKey()),
          envKeyProvider.overrideWithValue(() => null),
          itchAccountProvider.overrideWith((ref) async => null),
        ],
        child: const LootSiloApp(),
      ),
    );
    container = ProviderScope.containerOf(
      tester.element(find.byType(LootSiloApp)),
    );
  }

  /// Lets isolates and file IO run while pumping; [check] runs after
  /// every pump.
  Future<void> run(WidgetTester tester, {void Function()? check}) async {
    for (var i = 0; i < 30; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 50));
      check?.call();
    }
  }

  void expectWaitScreen(String path) {
    expect(wait, findsOneWidget);
    expect(find.text(waitTitle), findsOneWidget);
    expect(find.text(path), findsOneWidget);
    expect(firstChoices, findsNothing);
    expect(find.byType(Dashboard), findsNothing);
  }

  testWidgets('first run: a folder with packs waits, then the dashboard', (
    tester,
  ) async {
    final lib = library('packs');
    await start(tester, pick: lib);
    expect(find.text('Choose a library folder'), findsOneWidget);
    service.gate = Completer();
    await tester.tap(find.text('Choose folder'));
    await run(tester, check: () => expect(firstChoices, findsNothing));
    expectWaitScreen(lib);
    expect(find.text('Your library is empty'), findsNothing);
    service.gate!.complete();
    await run(tester, check: () => expect(firstChoices, findsNothing));
    expect(wait, findsNothing);
    expect(find.byType(Dashboard), findsOneWidget);
    expect(find.text('Knight Pack'), findsWidgets);
  });

  testWidgets('first run: an empty folder waits, then "empty"', (tester) async {
    final lib = Directory(p.join(tmp.path, 'empty'))..createSync();
    await start(tester, pick: lib.path);
    service.gate = Completer();
    await tester.tap(find.text('Choose folder'));
    await run(tester, check: () => expect(firstChoices, findsNothing));
    expectWaitScreen(lib.path);
    service.gate!.complete();
    await run(tester);
    expect(wait, findsNothing);
    expect(find.text('Your library is empty'), findsOneWidget);
    expect(firstChoices, findsOneWidget);
  });

  testWidgets('switching library hides the old packs until the new load', (
    tester,
  ) async {
    final a = library('a');
    final b = library('b', knight: false);
    await start(tester, libraryPath: a);
    await run(tester);
    expect(find.text('Knight Pack'), findsWidgets);
    service.gate = Completer();
    // What Settings → Library folder does once confirmed.
    container.read(settingsProvider.notifier).setLibraryPath(b);
    await run(
      tester,
      check: () => expect(find.text('Knight Pack'), findsNothing),
    );
    expectWaitScreen(b);
    service.gate!.complete();
    await run(tester);
    expect(wait, findsNothing);
    expect(find.byType(Dashboard), findsOneWidget);
    expect(find.text('Slimes'), findsWidgets);
    expect(find.text('Knight Pack'), findsNothing);
  });

  testWidgets('F5 keeps the dashboard on screen during the rescan', (
    tester,
  ) async {
    final lib = library('packs');
    await start(tester, libraryPath: lib);
    await run(tester);
    expect(find.byType(Dashboard), findsOneWidget);
    service.gate = Completer();
    final before = service.loads;
    await tester.sendKeyEvent(LogicalKeyboardKey.f5);
    await run(
      tester,
      check: () {
        expect(wait, findsNothing);
        expect(find.byType(Dashboard), findsOneWidget);
      },
    );
    expect(service.loads, before + 1, reason: 'the rescan is held');
    expect(container.read(libraryProvider).isLoading, isTrue);
    service.gate!.complete();
    await run(tester);
    expect(container.read(libraryProvider).isLoading, isFalse);
    expect(find.byType(Dashboard), findsOneWidget);
  });
  testWidgets('switching to a missing folder shows the error, not old packs', (
    tester,
  ) async {
    final a = library('a');
    await start(tester, libraryPath: a);
    await run(tester);
    expect(find.text('Knight Pack'), findsWidgets);
    container
        .read(settingsProvider.notifier)
        .setLibraryPath(p.join(tmp.path, 'gone'));
    await run(tester);
    expect(find.text('Could not read the library'), findsOneWidget);
    expect(find.text('Knight Pack'), findsNothing);
    expect(wait, findsNothing);
  });
}
