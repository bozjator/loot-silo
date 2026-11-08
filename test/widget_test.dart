import 'dart:io';

import 'package:loot_silo/core/library_index.dart';
import 'package:loot_silo/state/itch.dart';
import 'package:loot_silo/state/dashboard.dart';
import 'package:loot_silo/state/providers.dart';
import 'package:loot_silo/state/settings.dart';
import 'package:loot_silo/ui/app.dart';
import 'package:loot_silo/ui/settings_screen.dart';
import 'package:loot_silo/version.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'helpers/logo.dart';

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
        child: const LootSiloApp(),
      ),
    );
    expect(find.text('Choose a library folder'), findsOneWidget);
    // M48/M49: the icon and name in the app bar, the logo (name and
    // slogan) over the message.
    final bar = find.byType(AppBar);
    expect(
      find.descendant(of: bar, matching: find.text('Loot Silo')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: bar,
        matching: find.byKey(const ValueKey('app-bar-icon')),
      ),
      findsOneWidget,
    );
    // M52: the lockup with the app icon's silo.
    expectLockup(tester);
    expect(
      tester.widget<MaterialApp>(find.byType(MaterialApp)).title,
      'Loot Silo',
    );
    expect(find.textContaining('Asset Explorer'), findsNothing);
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
        detailHeaderPinned: false,
        imagesView: ItemsView.folders,
        animationsView: ItemsView.folders,
        detailAnimateMode: AnimateMode.all,
        audioView: AudioView.cards,
      ),
    );
    final back = store.load();
    expect(back.audioView, AudioView.cards);
    expect(f.readAsStringSync(), contains('"audio_view": "cards"'));
    expect(back.detailAnimateMode, AnimateMode.all);
    expect(f.readAsStringSync(), contains('"detail_animate_mode": "all"'));
    expect(back.audioLoop, isTrue);
    expect(back.detailHeaderPinned, isFalse);
    expect(back.imagesView, ItemsView.folders);
    expect(back.animationsView, ItemsView.folders);
    expect(back.libraryPath, '/lib');
    expect(back.theme, ThemeChoice.dark);
    expect(back.animateAll, isTrue);
    f.writeAsStringSync('{"library_path": "/x", "theme": "neon"}');
    expect(store.load().theme, ThemeChoice.system);
    expect(store.load().animateAll, isFalse);
    expect(store.load().audioLoop, isFalse);
    expect(store.load().detailHeaderPinned, isTrue);
    expect(store.load().imagesView, ItemsView.flat);
    expect(store.load().audioView, AudioView.rows);
    // Hover is the default; unknown values fall back to it.
    expect(store.load().detailAnimateMode, AnimateMode.hover);
    f.writeAsStringSync('{"detail_animate_mode": "bogus"}');
    expect(store.load().detailAnimateMode, AnimateMode.hover);
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
        child: const LootSiloApp(),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(Duration(milliseconds: 300)),
    );
    await tester.pump();
    // M45: one import icon in the app bar, no import buttons.
    final bar = find.byType(AppBar);
    // M49: the silo icon before the name.
    expect(
      find.descendant(
        of: bar,
        matching: find.byKey(const ValueKey('app-bar-icon')),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: bar, matching: find.byTooltip('Import')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: bar, matching: find.byType(OutlinedButton)),
      findsNothing,
    );
    await tester.tap(find.byTooltip('Settings (Ctrl+,)'));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsScreen), findsOneWidget);
    // The About line at the bottom shows the version.
    final list = find
        .descendant(
          of: find.byType(SettingsScreen),
          matching: find.byType(Scrollable),
        )
        .first;
    // M44's Startup section sits above itch.io.
    await tester.scrollUntilVisible(
      find.text('Not connected'),
      200,
      scrollable: list,
    );
    expect(find.text('Not connected'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text(appVersionLabel),
      300,
      scrollable: list,
    );
    expect(find.text(appVersionLabel), findsOneWidget);
    expect(appVersionLabel, startsWith('Loot Silo '));
    // M54: the slogan is part of the logo picture, not a text line.
    expect(find.text(appSlogan), findsNothing);
    // M49: the logo above the version line.
    expect(
      find.descendant(
        of: find.byType(SettingsScreen),
        matching: find.byKey(const ValueKey('app-logo')),
      ),
      findsOneWidget,
    );
    expectLockup(tester);
    expect(find.text('How Loot Silo works'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Dark'), -300, scrollable: list);

    await tester.tap(find.text('Dark'));
    await tester.pumpAndSettle();
    expect(store.load().theme, ThemeChoice.dark);
    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app.themeMode, ThemeMode.dark);

    await tester.tap(find.text('Animate all sprite previews on dashboard'));
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
        child: const LootSiloApp(),
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
        child: const LootSiloApp(),
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
