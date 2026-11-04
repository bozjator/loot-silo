import 'dart:io';

import 'package:assets_explorer/core/library_index.dart';
import 'package:assets_explorer/state/itch.dart';
import 'package:assets_explorer/state/dashboard.dart';
import 'package:assets_explorer/state/providers.dart';
import 'package:assets_explorer/state/settings.dart';
import 'package:assets_explorer/ui/app.dart';
import 'package:assets_explorer/ui/settings_screen.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('app'));
  tearDown(() => tmp.deleteSync(recursive: true));

  testWidgets('first run asks for a library folder and saves it', (
    tester,
  ) async {
    final store = SettingsStore(File(p.join(tmp.path, 'settings.json')));
    final index = LibraryIndex(NativeDatabase.memory());
    addTearDown(index.close);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsStoreProvider.overrideWithValue(store),
          libraryIndexProvider.overrideWithValue(index),
          directoryPickerProvider.overrideWithValue((_) async => tmp.path),
        ],
        child: const AssetsExplorerApp(),
      ),
    );
    expect(find.text('Choose a library folder'), findsOneWidget);
    await tester.tap(find.text('Choose folder'));
    await tester.pump();
    expect(store.load().libraryPath, tmp.path);
  });

  test('settings survive a corrupt file', () {
    final f = File(p.join(tmp.path, 'settings.json'))..writeAsStringSync('{');
    expect(SettingsStore(f).load().libraryPath, isNull);
  });

  test('theme and animate-all round-trip; unknown theme falls back', () {
    final f = File(p.join(tmp.path, 'settings.json'));
    final store = SettingsStore(f);
    store.save(
      const AppSettings(
        libraryPath: '/lib',
        theme: ThemeChoice.dark,
        animateAll: true,
        audioLoop: true,
        viewerPixelPerfect: true,
      ),
    );
    final back = store.load();
    expect(back.audioLoop, isTrue);
    expect(back.viewerPixelPerfect, isTrue);
    expect(back.libraryPath, '/lib');
    expect(back.theme, ThemeChoice.dark);
    expect(back.animateAll, isTrue);
    f.writeAsStringSync('{"library_path": "/x", "theme": "neon"}');
    expect(store.load().theme, ThemeChoice.system);
    expect(store.load().animateAll, isFalse);
    expect(store.load().audioLoop, isFalse);
    expect(store.load().viewerPixelPerfect, isFalse);
  });

  testWidgets('settings screen saves theme and animation, Esc closes it', (
    tester,
  ) async {
    final store = SettingsStore(File(p.join(tmp.path, 'settings.json')))
      ..save(AppSettings(libraryPath: tmp.path));
    final index = LibraryIndex(NativeDatabase.memory());
    addTearDown(index.close);
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
    await tester.runAsync(
      () => Future<void>.delayed(Duration(milliseconds: 300)),
    );
    await tester.pump();
    await tester.tap(find.byTooltip('Settings (Ctrl+,)'));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsScreen), findsOneWidget);
    expect(find.text('Not connected'), findsOneWidget);

    await tester.tap(find.text('Dark'));
    await tester.pumpAndSettle();
    expect(store.load().theme, ThemeChoice.dark);
    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app.themeMode, ThemeMode.dark);

    await tester.tap(find.text('Animate all sprite previews'));
    await tester.pumpAndSettle();
    expect(store.load().animateAll, isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(SettingsScreen), findsNothing);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.comma);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(find.byType(SettingsScreen), findsOneWidget);
  });

  testWidgets('mouse back button closes a page, then an open bundle', (
    tester,
  ) async {
    final store = SettingsStore(File(p.join(tmp.path, 'settings.json')))
      ..save(AppSettings(libraryPath: tmp.path));
    final index = LibraryIndex(NativeDatabase.memory());
    addTearDown(index.close);
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
    await tester.runAsync(
      () => Future<void>.delayed(Duration(milliseconds: 300)),
    );
    await tester.pump();
    Future<void> mouseBack() async {
      final mouse = await tester.startGesture(
        tester.getCenter(find.byType(Scaffold).last),
        kind: PointerDeviceKind.mouse,
        buttons: kBackMouseButton,
      );
      await mouse.up();
      await tester.pumpAndSettle();
    }

    await tester.tap(find.byTooltip('Settings (Ctrl+,)'));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsScreen), findsOneWidget);
    await mouseBack();
    expect(find.byType(SettingsScreen), findsNothing);

    final container = ProviderScope.containerOf(
      tester.element(find.byType(HomeScreen)),
    );
    container.read(dashboardQueryProvider.notifier).openBundle('Some/Bundle');
    await mouseBack();
    expect(container.read(dashboardQueryProvider).bundleId, isNull);
    expect(find.byType(HomeScreen), findsOneWidget);
  });

  testWidgets('a missing library folder offers another one', (tester) async {
    final gone = p.join(tmp.path, 'gone');
    final store = SettingsStore(File(p.join(tmp.path, 'settings.json')))
      ..save(AppSettings(libraryPath: gone));
    final index = LibraryIndex(NativeDatabase.memory());
    addTearDown(index.close);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsStoreProvider.overrideWithValue(store),
          libraryIndexProvider.overrideWithValue(index),
          directoryPickerProvider.overrideWithValue((_) async => tmp.path),
        ],
        child: const AssetsExplorerApp(),
      ),
    );
    await tester.pump();
    expect(find.textContaining('is missing'), findsOneWidget);
    await tester.tap(find.text('Choose another folder'));
    await tester.pump();
    expect(store.load().libraryPath, tmp.path);
  });
}

class _NoKey implements KeyStore {
  @override
  Future<String?> read() async => null;
  @override
  Future<void> write(String key) async {}
  @override
  Future<void> delete() async {}
}
