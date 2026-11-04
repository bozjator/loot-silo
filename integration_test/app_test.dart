import 'dart:io';

import 'package:assets_explorer/core/library_index.dart';
import 'package:assets_explorer/state/providers.dart';
import 'package:assets_explorer/state/settings.dart';
import 'package:assets_explorer/ui/app.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
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

/// Gives file images time to decode on real threads.
Future<void> settleImages(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
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
      await pumpUntil(tester, find.text('7 packs'));
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

  testWidgets('dashboard on the real managed assets_library', (tester) async {
    final real = p.canonicalize('../assets_library');
    if (!Directory(real).existsSync()) return;
    await tester.pumpWidget(app(real, library: real));
    await pumpUntil(tester, find.text('71 packs'));
    await settleImages(tester);
    await captureScreenshot(tester, 'm4_dashboard');

    await tester.enterText(find.byType(TextField), 'slime');
    await pumpUntil(tester, find.textContaining('Tiny RPG'));
    await settleImages(tester);
    await captureScreenshot(tester, 'm4_search_slime');

    await tester.enterText(find.byType(TextField), '');
    await tester.tap(find.widgetWithText(FilterChip, '3d'));
    await pumpUntil(tester, find.text('Clear'));
    await settleImages(tester);
    await captureScreenshot(tester, 'm4_filter_3d');

    await tester.tap(find.text('Clear'));
    await pumpUntil(tester, find.text('71 packs'));
    final kenney = find.text('Kenney Game Assets 1 version 42');
    await tester.scrollUntilVisible(
      kenney,
      300,
      scrollable: find.descendant(
        of: find.byType(GridView),
        matching: find.byType(Scrollable),
      ),
    );
    await settleImages(tester);
    await captureScreenshot(tester, 'm4_dashboard_scrolled');
    await tester.tap(kenney);
    await pumpUntil(tester, find.text('All packs'));
    await settleImages(tester);
    await captureScreenshot(tester, 'm4_bundle_kenney1');
  });

  testWidgets('sprite animations on tiles (real library)', (tester) async {
    final real = p.canonicalize('../assets_library');
    if (!Directory(real).existsSync()) return;
    await tester.pumpWidget(app(real, library: real));
    await pumpUntil(tester, find.text('71 packs'));

    for (final (query, name) in [
      ('zerie', 'm5_zerie'),
      ('oboro', 'm5_oboropixel'),
      ('ashishlko11', 'm5_special_effects'),
    ]) {
      await tester.enterText(find.byType(TextField), query);
      await tester.pump(const Duration(milliseconds: 500));
      await settleImages(tester);
      await captureScreenshot(tester, '${name}_frame0');
      // Hovering a tile plays its animation; capture a later frame.
      final tile = find.byType(Card).first;
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: tester.getCenter(tile));
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 250)),
      );
      await tester.pump(const Duration(milliseconds: 250));
      await captureScreenshot(tester, '${name}_hover', settle: false);
      await mouse.removePointer();
    }
  });

  testWidgets('pack detail: edit tags, save and reset an animation', (
    tester,
  ) async {
    copyTree('test/fixtures/managed', lib);
    final zerie = p.canonicalize('../assets_library/Zerie');
    final hasZerie = Directory(zerie).existsSync();
    if (hasZerie) copyTree(zerie, p.join(lib, 'Zerie'));
    await tester.pumpWidget(app(lib));
    await pumpUntil(tester, find.text('Slimes'));

    await tester.tap(find.text('Slimes'));
    await pumpUntil(tester, find.byTooltip('Edit tags'));
    await settleImages(tester);
    await captureScreenshot(tester, 'm6_detail_slimes', settle: false);
    await tester.tap(find.byTooltip('Edit tags'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.enterText(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      ),
      'green, Cute',
    );
    await tester.tap(find.text('Save'));
    await pumpUntil(tester, find.widgetWithText(Chip, 'cute'));
    final json =
        File(p.join(lib, 'HeroMaker', 'Slimes', 'asset_pack.json'))
            .readAsStringSync();
    expect(json, contains('"cute"'));
    expect(json, contains('"source": "manual"'));
    await tester.pageBack();
    await tester.pump(const Duration(milliseconds: 500));

    if (!hasZerie) return;
    await tester.tap(find.byType(TextField));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'zerie');
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.textContaining('Tiny RPG').first);
    await pumpUntil(tester, find.textContaining('Animations ('));
    await settleImages(tester);
    await captureScreenshot(tester, 'm6_detail_zerie', settle: false);

    final card = find.ancestor(
      of: find.text('Apply size').first,
      matching: find.byType(Card),
    );
    await tester.enterText(
      find.descendant(
        of: card.first,
        matching: find.widgetWithText(TextField, 'Frame width'),
      ),
      '50',
    );
    await tester.tap(
      find.descendant(of: card.first, matching: find.text('Apply size')),
    );
    await tester.pump();
    await tester.tap(
      find.descendant(of: card.first, matching: find.text('Save')),
    );
    await pumpUntil(tester, find.text('Reset to detected'));
    final sidecar = Directory(p.join(lib, 'Zerie'))
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => p.basename(f.path) == 'asset_pack.json')
        .map((f) => f.readAsStringSync())
        .firstWhere((s) => s.contains('animations'));
    expect(sidecar, contains('"frame_w": 50'));
    await settleImages(tester);
    await captureScreenshot(tester, 'm6_detail_zerie_override', settle: false);
    await tester.tap(find.text('Reset to detected'));
    await pumpUntil(tester, find.text('Apply size'));
    for (var i = 0; i < 50 && find.text('Reset to detected').evaluate().isNotEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();
    }
    expect(find.text('Reset to detected'), findsNothing);
  });

  testWidgets('pack detail on the real library (read-only)', (tester) async {
    final real = p.canonicalize('../assets_library');
    if (!Directory(real).existsSync()) return;
    final before = Directory(real).statSync().modified;
    await tester.pumpWidget(app(real, library: real));
    await pumpUntil(tester, find.text('71 packs'));

    await tester.enterText(find.byType(TextField), 'monster sound effects 3');
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('Monster Sound Effects 3'));
    await pumpUntil(tester, find.textContaining('Audio ('));
    await settleImages(tester);
    await captureScreenshot(tester, 'm6_detail_audio', settle: false);
    await tester.pageBack();
    await tester.pump(const Duration(milliseconds: 500));

    // After a route pop the test text input needs a fresh tap.
    await tester.tap(find.byType(TextField));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'ashishlko11');
    await pumpUntil(tester, find.text('Special Effects Vol.03'));
    await tester.tap(find.text('Special Effects Vol.03'));
    await pumpUntil(tester, find.textContaining('Images ('));
    await tester.tap(find.textContaining('Images ('));
    await tester.pump(const Duration(milliseconds: 500));
    await settleImages(tester);
    await captureScreenshot(tester, 'm6_detail_images', settle: false);
    expect(Directory(real).statSync().modified, before);
  });
}

