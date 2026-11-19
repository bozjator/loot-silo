// Fresh-install check before a release: the app as main() builds it (real
// settings.json, index database and keychain in the app's support folder),
// on a machine that has never run it. Only the folder pickers are stubbed.
//
// It refuses to run while the support folder holds settings.json, so move
// ~/.local/share/com.bozjatorium.LootSilo aside first. Needs:
//   FRESH_LIBRARY  an empty folder that becomes the library
//   FRESH_IMPORT   a folder of packs to import (copied, never moved)
//   ITCH_API_KEY   optional; a real itch.io key (read like the app's
//                  development fallback, never saved). With it the test
//                  downloads the smallest owned asset into the library.
//
//   FRESH_LIBRARY=... FRESH_IMPORT=... ITCH_API_KEY=... \
//     flutter test integration_test/fresh_install_test.dart -d linux
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift_flutter/drift_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:loot_silo/core/library_index.dart';
import 'package:loot_silo/itch/itch_api.dart';
import 'package:loot_silo/state/folder_folds.dart';
import 'package:loot_silo/state/itch.dart';
import 'package:loot_silo/state/providers.dart';
import 'package:loot_silo/state/settings.dart';
import 'package:loot_silo/ui/app.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

Future<void> pumpUntil(
  WidgetTester tester,
  Finder finder, {
  int seconds = 60,
}) async {
  final end = DateTime.now().add(Duration(seconds: seconds));
  while (finder.evaluate().isEmpty) {
    if (DateTime.now().isAfter(end)) {
      final texts = find
          .byType(Text)
          .evaluate()
          .map((e) => (e.widget as Text).data)
          .join(' | ');
      fail('Timed out waiting for $finder; on screen: $texts');
    }
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final env = Platform.environment;
  final library = env['FRESH_LIBRARY'];
  final imports = env['FRESH_IMPORT'];
  final itchKey = env['ITCH_API_KEY'];

  testWidgets('fresh install: first start, import, itch.io, restart', (
    tester,
  ) async {
    final support = await tester.runAsync(getApplicationSupportDirectory);
    final cache = await tester.runAsync(getApplicationCacheDirectory);
    final settingsFile = File(p.join(support!.path, 'settings.json'));
    expect(
      settingsFile.existsSync(),
      isFalse,
      reason: 'not a fresh install: ${support.path} has settings.json',
    );
    expect(Directory(library!).listSync(), isEmpty, reason: 'library');

    // Same wiring as main(), so a second pump is a restart.
    var picked = library;
    Widget app() => ProviderScope(
      overrides: [
        settingsStoreProvider.overrideWithValue(SettingsStore(settingsFile)),
        folderFoldsProvider.overrideWithValue(
          FolderFolds(File(p.join(support.path, 'ui_state.json'))),
        ),
        libraryIndexProvider.overrideWithValue(
          LibraryIndex(
            driftDatabase(
              name: 'library_index',
              native: DriftNativeOptions(
                databaseDirectory: () async => support,
              ),
            ),
          ),
        ),
        extractRootProvider.overrideWithValue(p.join(cache!.path, 'extract')),
        gifCacheProvider.overrideWithValue(p.join(cache.path, 'gif_cache')),
        directoryPickerProvider.overrideWithValue((_) async => picked),
        envKeyProvider.overrideWithValue(() => itchKey),
      ],
      child: const LootSiloApp(),
    );

    // The real keychain works (and starts empty on a fresh install).
    final keys = SecureKeyStore();
    expect(await tester.runAsync(keys.read), isNull, reason: 'keychain');
    await tester.runAsync(() => keys.write('fresh-install-probe'));
    expect(await tester.runAsync(keys.read), 'fresh-install-probe');
    await tester.runAsync(keys.delete);
    expect(await tester.runAsync(keys.read), isNull);

    // First start: no settings, so the app asks for a library folder.
    await tester.pumpWidget(app());
    await pumpUntil(tester, find.text('Choose a library folder'));
    await tester.tap(find.text('Choose folder'));
    await pumpUntil(tester, find.text('Your library is empty'));
    var saved = jsonDecode(settingsFile.readAsStringSync()) as Map;
    expect(saved['format_version'], 1);
    expect(saved['library_path'], library);

    // Import a folder of packs through the review screen.
    picked = imports!;
    await tester.tap(find.text('Import folder').first);
    final importButton = find.textContaining(RegExp(r'^Import \d+ packs?$'));
    await pumpUntil(tester, importButton, seconds: 120);
    final label = (importButton.evaluate().first.widget as Text).data!;
    final count = int.parse(RegExp(r'\d+').firstMatch(label)![0]!);
    await tester.tap(importButton);
    await pumpUntil(tester, find.text('Done'), seconds: 300);
    expect(
      find.textContaining('$count of $count packs imported and verified'),
      findsOneWidget,
    );
    await tester.tap(find.text('Done'));
    await pumpUntil(tester, find.text(count == 1 ? '1 pack' : '$count packs'));

    final packFiles = Directory(library)
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => p.basename(f.path) == 'asset_pack.json')
        .toList();
    expect(packFiles, hasLength(count));
    for (final f in packFiles) {
      expect(jsonDecode(f.readAsStringSync())['format_version'], 1);
    }
    final authorFiles = Directory(library)
        .listSync()
        .map((d) => File(p.join(d.path, 'ASSET_AUTHOR.txt')))
        .where((f) => f.existsSync());
    for (final f in authorFiles) {
      expect(
        f.readAsStringSync(),
        contains('format_version: 1'),
        reason: f.path,
      );
    }
    expect(
      Directory(imports).listSync(),
      isNotEmpty,
      reason: 'import copies, the source stays',
    );

    if (itchKey != null) {
      // The smallest owned asset, so the download is quick.
      final api = ItchApi(itchKey);
      final owned = await tester.runAsync(api.ownedKeys);
      final assets = owned!.where((k) => k.game.classification == 'assets');
      OwnedKey? smallest;
      var smallestSize = 1 << 62;
      for (final k in assets.take(20)) {
        final ups = await tester.runAsync(() => api.uploads(k));
        final size = ups!.fold(0, (s, u) => s + u.size);
        if (ups.isNotEmpty && size < smallestSize) {
          smallest = k;
          smallestSize = size;
        }
      }
      api.close();

      await tester.tap(find.byTooltip('itch.io'));
      await pumpUntil(tester, find.textContaining('Signed in as'), seconds: 90);
      final row = find.byKey(ValueKey('itch-row:${smallest!.game.id}'));
      await tester.scrollUntilVisible(
        row,
        200,
        scrollable: find
            .ancestor(
              of: find.byType(ListTile).first,
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.tap(
        find.descendant(of: row, matching: find.text('Download')),
      );
      await pumpUntil(tester, row.hitTestable(), seconds: 1);
      final end = DateTime.now().add(const Duration(minutes: 5));
      while (row.evaluate().isNotEmpty) {
        expect(
          find.descendant(of: row, matching: find.text('Retry')),
          findsNothing,
          reason: '${smallest.game.title} failed to download',
        );
        if (DateTime.now().isAfter(end)) fail('download timed out');
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 200)),
        );
        await tester.pump(const Duration(milliseconds: 200));
      }
      final linked = Directory(library)
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => p.basename(f.path) == 'asset_pack.json')
          .where(
            (f) => f.readAsStringSync().contains(
              '"itch_game_id": ${smallest!.game.id}',
            ),
          );
      expect(linked, hasLength(1), reason: smallest.game.title);
      // ignore: avoid_print
      print(
        'itch: downloaded ${smallest.game.title} '
        '(${(smallestSize / 1024).round()} KB)',
      );
      await tester.pageBack();
      await tester.pump(const Duration(milliseconds: 500));
    }

    // Restart: the library and its packs come back from disk.
    final packs = Directory(library)
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => p.basename(f.path) == 'asset_pack.json')
        .length;
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(app());
    await pumpUntil(tester, find.text(packs == 1 ? '1 pack' : '$packs packs'));
    saved = jsonDecode(settingsFile.readAsStringSync()) as Map;
    expect(saved['format_version'], 1);
    expect(saved['library_path'], library);
  }, skip: library == null || imports == null);
}
