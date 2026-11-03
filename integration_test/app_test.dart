import 'dart:io';

import 'package:assets_explorer/core/library_index.dart';
import 'package:assets_explorer/state/providers.dart';
import 'package:assets_explorer/state/settings.dart';
import 'package:assets_explorer/ui/app.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;

import '../test/helpers/fs.dart';
import 'screenshot_helper.dart';

/// Pumps until [finder] matches; real isolates need real time.
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
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late Directory tmp;
  late String lib;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('it');
    lib = p.join(tmp.path, 'library');
    Directory(lib).createSync();
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  Widget app(String source, {String? library}) {
    final store = SettingsStore(File(p.join(tmp.path, 'settings.json')))
      ..save(AppSettings(libraryPath: library ?? lib));
    return screenshotable(
      ProviderScope(
        overrides: [
          settingsStoreProvider.overrideWithValue(store),
          libraryIndexProvider.overrideWithValue(
            LibraryIndex(NativeDatabase.memory()),
          ),
          directoryPickerProvider.overrideWithValue((_) async => source),
        ],
        child: const AssetsExplorerApp(),
      ),
    );
  }

  testWidgets(
    'folder import: review, edit author, import, library shows packs',
    (tester) async {
      final src = p.join(tmp.path, 'src');
      copyTree('test/fixtures/library_src', src);

      await tester.pumpWidget(app(src));
      await pumpUntil(tester, find.text('Your library is empty'));
      await captureScreenshot(tester, 'm3_empty');

      await tester.tap(find.text('Import folder').first);
      await pumpUntil(tester, find.text('Import 7 packs'));
      await tester.pumpAndSettle();
      await captureScreenshot(tester, 'm3_review');

      await tester.tap(find.text('Unknown — set author'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, 'Name'), 'Me');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.text('Me/misc'), findsOneWidget);

      await tester.tap(find.text('Import 7 packs'));
      await pumpUntil(tester, find.text('Done'));
      expect(
        find.textContaining('7 of 7 packs imported and verified'),
        findsOneWidget,
      );
      await captureScreenshot(tester, 'm3_done');

      await tester.tap(find.text('Done'));
      await pumpUntil(tester, find.textContaining('7 packs · 3 sub-packs'));
      await tester.pumpAndSettle();
      await captureScreenshot(tester, 'm3_library');
      expect(
        File(p.join(lib, 'Me', 'misc', 'asset_pack.json')).existsSync(),
        isTrue,
      );
    },
  );

  testWidgets('review of the real assets_library_OLD (read-only, no import)', (
    tester,
  ) async {
    const old = '../assets_library_OLD';
    if (!Directory(old).existsSync()) return;
    await tester.pumpWidget(app(p.canonicalize(old)));
    await pumpUntil(tester, find.text('Import folder'));
    await tester.tap(find.text('Import folder').first);
    await pumpUntil(tester, find.text('Import 71 packs'));
    await tester.pumpAndSettle();
    await captureScreenshot(tester, 'm3_review_real');
  });

  testWidgets('opens the real managed assets_library', (tester) async {
    final real = p.canonicalize('../assets_library');
    if (!Directory(real).existsSync()) return;
    await tester.pumpWidget(app(real, library: real));
    await pumpUntil(tester, find.textContaining('71 packs · 130 sub-packs'));
    await tester.pumpAndSettle();
    await captureScreenshot(tester, 'm3_real_library');
  });
}
