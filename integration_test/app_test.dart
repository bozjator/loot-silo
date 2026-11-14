import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:loot_silo/core/audio_duration.dart';
import 'package:loot_silo/core/library_index.dart';
import 'package:loot_silo/core/library_service.dart';
import 'package:loot_silo/itch/itch_api.dart';
import 'package:loot_silo/itch/itch_key.dart';
import 'package:loot_silo/state/dashboard.dart';
import 'package:loot_silo/state/itch.dart';
import 'package:loot_silo/state/providers.dart';
import 'package:loot_silo/state/settings.dart';
import 'package:loot_silo/ui/app.dart';
import 'package:loot_silo/ui/dashboard.dart';
import 'package:loot_silo/ui/help_screen.dart';
import 'package:loot_silo/ui/image_viewer.dart';
import 'package:loot_silo/ui/model_painter.dart';
import 'package:loot_silo/ui/material_viewer.dart';
import 'package:loot_silo/ui/model_viewer.dart';
import 'package:loot_silo/ui/pack_detail_screen.dart';
import 'package:loot_silo/ui/track_player.dart';
import 'package:loot_silo/ui/widgets/file_menu.dart';
import 'package:loot_silo/ui/widgets/favorite_star.dart';
import 'package:loot_silo/ui/widgets/pack_tile.dart';
import 'package:loot_silo/ui/widgets/animated_sprite.dart';
import 'package:loot_silo/ui/widgets/item_card.dart';
import 'package:loot_silo/ui/widgets/measure_size.dart';
import 'package:loot_silo/ui/reveal.dart';
import 'package:loot_silo/ui/settings_screen.dart';
import 'package:loot_silo/ui/tabs.dart';
import 'package:loot_silo/ui/text_preview_dialog.dart';
import 'package:loot_silo/ui/theme_colors.dart';
import 'package:loot_silo/ui/widgets/thumb_size.dart';
import 'package:loot_silo/ui/clipboard.dart';
import 'package:loot_silo/ui/widgets/waveform.dart';
import 'package:loot_silo/version.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:http/testing.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;

import '../test/helpers/fs.dart';
import '../test/helpers/logo.dart';
import '../test/helpers/models.dart';
import 'screenshot_helper.dart';

class MemoryKeyStore implements KeyStore {
  String? key;

  @override
  Future<String?> read() async => key;

  @override
  Future<void> write(String k) async => key = k;

  @override
  Future<void> delete() async => key = null;
}

/// Pumps until [finder] matches (or, with [gone], stops matching); real
/// isolates need real time.
/// The real library's pack count at the root ("72 packs"). Importing into
/// the library changes it, so the first test to load the library reads it
/// (no search or filter is active then); later calls match that exact text,
/// so a filtered count ("17 packs") doesn't pass for the root.
/// Adds two materials to [pack]: a temp copy of the real
/// `PavingStones138_1K-JPG` (when the library is here; returns whether) and
/// a generated Bricks material without a preview.
bool addMaterials(String pack) {
  // A temp copy of a real ambientCG material when the library is here.
  const paving = '../assets_library/Unknown Author/PavingStones138_1K-JPG';
  final real = Directory(paving).existsSync();
  if (real) {
    copyTree(paving, p.join(pack, 'Paving'));
    File(p.join(pack, 'Paving', 'asset_pack.json')).deleteSync();
  }
  // A generated one without a preview: its Color map shows tiled.
  final color = img.Image(width: 128, height: 128);
  final normal = img.Image(width: 128, height: 128);
  for (var y = 0; y < 128; y++) {
    for (var x = 0; x < 128; x++) {
      final row = y ~/ 32;
      final mortar = y % 32 < 3 || (x + (row.isOdd ? 32 : 0)) % 64 < 3;
      color.setPixelRgb(
        x,
        y,
        mortar ? 200 : 150 + (x * 7 + y * 3) % 30,
        mortar ? 195 : 60,
        mortar ? 185 : 45,
      );
      normal.setPixelRgb(x, y, mortar ? 100 : 128, mortar ? 160 : 128, 255);
    }
  }
  for (final (name, image) in [
    ('Bricks_Color.png', color),
    ('Bricks_Normal.png', normal),
    ('Bricks_Roughness.png', img.grayscale(color.clone())),
  ]) {
    File(p.join(pack, 'Bricks', name))
      ..createSync(recursive: true)
      ..writeAsBytesSync(img.encodePng(image));
  }
  File(p.join(pack, 'Bricks', 'Bricks.tres')).writeAsStringSync('[gd]');
  return real;
}

Finder realPacks() {
  if (_realPacksText case final text?) return find.text(text);
  return find.byWidgetPredicate((w) {
    if (w is! Text) return false;
    final text = w.data;
    if (text == null || !RegExp(r'^[1-9]\d+ packs$').hasMatch(text)) {
      return false;
    }
    _realPacksText = text;
    return true;
  });
}

String? _realPacksText;

Future<void> pumpUntil(
  WidgetTester tester,
  Finder finder, {
  int seconds = 60,
  bool gone = false,
}) async {
  final end = DateTime.now().add(Duration(seconds: seconds));
  while (finder.evaluate().isEmpty != gone) {
    if (DateTime.now().isAfter(end)) {
      final texts = find
          .byType(Text)
          .evaluate()
          .map((e) => (e.widget as Text).data)
          .join(' | ');
      fail('Timed out waiting for $finder; on screen: $texts');
    }
    // Isolates and file IO need real time, not just frames.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// Gives file images time to decode on real threads.
/// Moves a mouse over [finder] (card icons only take clicks while hovered)
/// and leaves it there until the test ends.
/// Opens image [rel] in the viewer through its card's Open image icon (a
/// click focuses the card since M40).
Future<void> openImageCard(WidgetTester tester, String rel) async {
  final card = find.byKey(ValueKey('image:$rel'));
  final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await mouse.addPointer(location: tester.getCenter(card));
  await tester.pump();
  await tester.tap(
    find.descendant(of: card, matching: find.byTooltip('Open image')),
  );
  await mouse.removePointer();
}

Future<void> hoverOver(WidgetTester tester, Finder finder) async {
  final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await mouse.addPointer(location: tester.getCenter(finder));
  addTearDown(mouse.removePointer);
  await tester.pump();
}

Future<void> settleImages(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
  }
}

/// Opens the app bar's import menu and picks [item] ("Import folder" or
/// "Import archive"; the menu adds "… (Ctrl+I)").
Future<void> importFrom(WidgetTester tester, String item) async {
  await tester.tap(find.byTooltip('Import'));
  await tester.pump(const Duration(milliseconds: 400));
  await tester.tap(find.textContaining('$item…'));
  await tester.pump(const Duration(milliseconds: 400));
}

/// Screenshot suffix for the m27 before/after comparison.
const m27Phase = String.fromEnvironment('M27_PHASE', defaultValue: 'after');

/// Reads the clipboard's [target] through our channel, retrying a few
/// times: the X selection round trip can come back empty under load. Each
/// empty read prints the targets on offer (diagnostics).
Future<Uint8List?> clipRead(WidgetTester tester, String target) async {
  for (var i = 0; i < 5; i++) {
    final data = await tester.runAsync(
      () => PlatformFileClipboard.read(target),
    );
    if (data != null) return data;
    final offered = await tester.runAsync(PlatformFileClipboard.targets);
    // ignore: avoid_print
    print('clipboard read $target empty (try ${i + 1}); targets: $offered');
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
  }
  return null;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late Directory tmp;
  late String lib;
  final keyStore = MemoryKeyStore();
  setUp(() {
    keyStore.key = null;
    tmp = Directory.systemTemp.createTempSync('it');
    lib = p.join(tmp.path, 'library');
    Directory(lib).createSync();
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  /// itch.io as seen by the app in tests; null = the real API.
  http.Client? itchClient;

  /// The developer's real key file, for the read-only live screenshots.
  final liveEnvFile = p.join(
    Platform.environment['HOME'] ?? '',
    '.config/my-dev-claude/assets-explorer-app.env',
  );
  var useLiveKey = false;

  /// Archives the "Import archive" button picks.
  var pickedArchives = <String>[];

  /// Overrides the folder [app] was given, for a second pick.
  String? pickedFolder;

  /// Paths "Show in file manager" was asked for; no file manager opens.
  final revealed = <String>[];

  /// Stands in for the audio player where a test drives playback itself.
  TrackPlayer Function()? fakePlayer;

  /// [restart]: keeps the saved settings (and last session), as when the
  /// app starts again.
  Widget app(
    String source, {
    String? library,
    bool restart = false,
    // No library chosen yet: the first-start screen.
    bool firstRun = false,
    List<Override> overrides = const [],
  }) {
    final store = SettingsStore(File(p.join(tmp.path, 'settings.json')));
    if (!restart) {
      store.save(AppSettings(libraryPath: firstRun ? null : library ?? lib));
    }
    return screenshotable(
      ProviderScope(
        overrides: [
          settingsStoreProvider.overrideWithValue(store),
          libraryIndexProvider.overrideWithValue(
            LibraryIndex(NativeDatabase.memory()),
          ),
          directoryPickerProvider.overrideWithValue(
            (_) async => pickedFolder ?? source,
          ),
          archivePickerProvider.overrideWithValue(() async => pickedArchives),
          extractRootProvider.overrideWithValue(p.join(tmp.path, 'extract')),
          keyStoreProvider.overrideWithValue(keyStore),
          revealProvider.overrideWithValue((path) async => revealed.add(path)),
          if (fakePlayer case final make?)
            trackPlayerFactoryProvider.overrideWithValue(make),
          if (itchClient == null && useLiveKey)
            envKeyProvider.overrideWithValue(
              () => readKeyFromEnvFile(liveEnvFile),
            ),
          if (itchClient case final client?) ...[
            itchApiFactoryProvider.overrideWithValue(
              (key) => ItchApi(key, client: client),
            ),
            envKeyProvider.overrideWithValue(() => null),
          ],
          saveLocationProvider.overrideWithValue(
            (name) async => p.join(tmp.path, name),
          ),
          ...overrides,
        ],
        child: const LootSiloApp(),
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

      // M24: the author cell is an inline picker.
      final unknown = find.widgetWithText(TextField, 'Unknown — set author');
      await tester.tap(unknown);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.enterText(unknown, 'Me');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('Add new author “Me”'));
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

  testWidgets('m24: import review — author picker, tag chips, overlap', (
    tester,
  ) async {
    copyTree('test/fixtures/managed', lib);
    final src = p.join(tmp.path, 'src');
    copyTree('test/fixtures/library_src', src);
    await tester.pumpWidget(app(src));
    await pumpUntil(tester, find.text('Slimes'));
    await importFrom(tester, 'Import folder');
    await pumpUntil(tester, find.text('Import 7 packs'));
    await tester.pump(const Duration(milliseconds: 500));
    // One line per pack unless the path adds something.
    expect(find.text('.'), findsNothing);
    await captureScreenshot(tester, 'm24_review', settle: false);

    final unknown = find.widgetWithText(TextField, 'Unknown — set author');
    await tester.tap(unknown);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Add new author…'), findsOneWidget);
    expect(find.text('2 packs'), findsOneWidget);
    await captureScreenshot(tester, 'm24_author_suggestions', settle: false);
    await tester.enterText(unknown, 'hero');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('HeroMaker').last);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('HeroMaker/misc'), findsOneWidget);

    await tester.tap(find.text('—').first);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'retro, top-down,');
    await tester.pump(const Duration(milliseconds: 300));
    await captureScreenshot(tester, 'm24_tag_chips', settle: false);
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('retro'), findsOneWidget);
    await captureScreenshot(tester, 'm24_review_edited', settle: false);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();

    // A folder inside the library: a plain explanation.
    pickedFolder = p.join(lib, 'HeroMaker');
    addTearDown(() => pickedFolder = null);
    await importFrom(tester, 'Import folder');
    await pumpUntil(tester, find.textContaining('This folder is inside'));
    expect(find.textContaining('Invalid argument'), findsNothing);
    await tester.pump(const Duration(seconds: 1));
    await captureScreenshot(tester, 'm24_overlap', settle: false);
  });

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
    await pumpUntil(tester, realPacks());
    await settleImages(tester);
    await captureScreenshot(tester, 'm4_dashboard');

    await tester.enterText(find.byType(TextField), 'slime');

    await tester.pump(DashboardQueryNotifier.searchDebounce);
    await pumpUntil(tester, find.textContaining('Tiny RPG'));
    await settleImages(tester);
    await captureScreenshot(tester, 'm4_search_slime');

    await tester.enterText(find.byType(TextField), '');

    await tester.pump(DashboardQueryNotifier.searchDebounce);
    // Type chips follow the search (M23): 3d shows again once it's cleared.
    await pumpUntil(tester, find.widgetWithText(FilterChip, '3d'));
    await tester.tap(find.widgetWithText(FilterChip, '3d'));
    await pumpUntil(tester, find.text('Clear'));
    await settleImages(tester);
    await captureScreenshot(tester, 'm4_filter_3d');

    await tester.tap(find.text('Clear'));
    await pumpUntil(tester, realPacks());
    final kenney = find.text('Kenney Game Assets 1 version 42');
    await tester.scrollUntilVisible(
      kenney,
      300,
      scrollable: find.descendant(
        of: find.byType(ThumbRows),
        matching: find.byType(Scrollable),
      ),
    );
    await settleImages(tester);
    await captureScreenshot(tester, 'm4_dashboard_scrolled');
    // Since M91 the all-in-one is one pack: its page opens.
    await tester.tap(kenney);
    await pumpUntil(tester, find.textContaining('Images ('));
    await tester.pump(const Duration(seconds: 1));
    await settleImages(tester);
    await captureScreenshot(tester, 'm4_kenney1_pack', settle: false);
  });

  testWidgets('sprite animations on tiles (real library)', (tester) async {
    final real = p.canonicalize('../assets_library');
    if (!Directory(real).existsSync()) return;
    await tester.pumpWidget(app(real, library: real));
    await pumpUntil(tester, realPacks());

    for (final (query, name) in [
      ('zerie', 'm5_zerie'),
      ('oboro', 'm5_oboropixel'),
      ('ashishlko11', 'm5_special_effects'),
    ]) {
      await tester.enterText(find.byType(TextField), query);
      await tester.pump(DashboardQueryNotifier.searchDebounce);
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
    final json = File(p.join(lib, 'HeroMaker', 'Slimes', 'asset_pack.json'))
        .readAsStringSync();
    expect(json, contains('"cute"'));
    expect(json, contains('"source": "manual"'));
    await tester.pageBack();
    await tester.pump(const Duration(milliseconds: 500));

    if (!hasZerie) return;
    await tester.tap(find.byType(TextField));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'zerie');
    await tester.pump(DashboardQueryNotifier.searchDebounce);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.textContaining('Tiny RPG').first);
    await pumpUntil(tester, find.textContaining('Animations ('));
    await settleImages(tester);
    await captureScreenshot(tester, 'm6_detail_zerie', settle: false);

    // Fps / frame size / row are edited in a dialog from the grid card.
    await hoverOver(
      tester,
      find.ancestor(
        of: find.byTooltip('Edit animation').first,
        matching: find.byType(Card),
      ),
    );
    await tester.tap(find.byTooltip('Edit animation').first);
    await pumpUntil(tester, find.text('Apply size'));
    final card = find.byType(Dialog);
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
    for (
      var i = 0;
      i < 50 && find.text('Reset to detected').evaluate().isNotEmpty;
      i++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();
    }
    expect(find.text('Reset to detected'), findsNothing);
    await tester.tap(find.widgetWithText(TextButton, 'Close'));
    await tester.pump(const Duration(milliseconds: 300));
  });

  testWidgets('pack detail on the real library (read-only)', (tester) async {
    final real = p.canonicalize('../assets_library');
    if (!Directory(real).existsSync()) return;
    final before = Directory(real).statSync().modified;
    await tester.pumpWidget(app(real, library: real));
    await pumpUntil(tester, realPacks());

    await tester.enterText(find.byType(TextField), 'monster sound effects 3');

    await tester.pump(DashboardQueryNotifier.searchDebounce);
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
    // M34: Special Effects Vol.03 holds only animations now (no Images
    // tab); Village(interiors) has plain images.
    await tester.enterText(find.byType(TextField), 'Village(interiors)');
    await tester.pump(DashboardQueryNotifier.searchDebounce);
    await pumpUntil(tester, find.text(villageInteriors));
    await tester.tap(find.text(villageInteriors).first);
    await pumpUntil(tester, find.textContaining('Images ('));
    await tester.tap(find.textContaining('Images ('));
    await tester.pump(const Duration(milliseconds: 500));
    await settleImages(tester);
    await captureScreenshot(tester, 'm6_detail_images', settle: false);
    expect(Directory(real).statSync().modified, before);
  });

  testWidgets('credits: mark used in, choose packs, save CREDITS.md', (
    tester,
  ) async {
    copyTree('test/fixtures/managed', lib);
    await tester.pumpWidget(app(lib));
    await pumpUntil(tester, find.text('Slimes'));

    await tester.tap(find.text('Slimes'));
    await pumpUntil(tester, find.byTooltip('Mark as used in a game'));
    await tester.tap(find.byTooltip('Mark as used in a game'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.enterText(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      ),
      'Orc Siege',
    );
    // Let Autocomplete rebuild its options layer before tapping.
    await tester.pump();
    await tester.tap(find.text('Save'));
    await pumpUntil(tester, find.widgetWithText(Chip, 'Orc Siege'));
    await tester.pageBack();
    await tester.pump(const Duration(milliseconds: 500));

    await tester.tap(find.byTooltip('Credits'));
    // The fixture's Knight Pack is already used in "My Game".
    await pumpUntil(tester, find.widgetWithText(ListTile, 'Orc Siege'));
    expect(find.widgetWithText(ListTile, 'My Game'), findsOneWidget);
    await tester.tap(find.widgetWithText(ListTile, 'Orc Siege'));
    await pumpUntil(tester, find.textContaining('# Credits — Orc Siege'));
    await tester.tap(find.text('Choose packs…'));
    final knight = find.widgetWithText(CheckboxListTile, 'Knight Pack');
    await pumpUntil(tester, knight);
    await settleImages(tester);
    await tester.tap(knight);
    await pumpUntil(
      tester,
      find.byWidgetPredicate(
        (w) =>
            w is CheckboxListTile &&
            w.value == true &&
            (w.title as Text?)?.data == 'Knight Pack',
      ),
    );
    await tester.tap(find.text('Save'));
    await pumpUntil(tester, find.textContaining('Knight Pack, Slimes'));
    await captureScreenshot(tester, 'm7_credits');

    await tester.tap(find.text('Save…'));
    await pumpUntil(tester, find.textContaining('Saved'));
    final saved = File(p.join(tmp.path, 'CREDITS.md')).readAsStringSync();
    expect(saved, startsWith('# Credits — Orc Siege'));
    expect(saved, contains('## HeroMaker'));
    expect(saved, contains('- Assets: Knight Pack, Slimes'));
    await tester.tap(find.text('.txt'));
    await tester.pump();
    expect(find.textContaining('CREDITS — Orc Siege'), findsOneWidget);
  });

  testWidgets('m11: loop toggle, confirm removal, taller detail header', (
    tester,
  ) async {
    copyTree('test/fixtures/managed', lib);
    // Any bytes do: the scanner classifies by extension, nothing plays.
    File(p.join(lib, 'HeroMaker', 'Knight Pack', 'sword_swing-01.wav'))
        .writeAsBytesSync(List.filled(64, 0));
    await tester.pumpWidget(app(lib));
    await pumpUntil(tester, find.text('Knight Pack'));

    await tester.tap(find.text('Knight Pack'));
    await pumpUntil(tester, find.widgetWithText(Chip, 'My Game'));
    await settleImages(tester);
    await captureScreenshot(tester, 'm11_detail_header', settle: false);

    // Removing "used in" from the detail page asks first; Cancel keeps it.
    await tester.tap(
      find.descendant(
        of: find.widgetWithText(Chip, 'My Game'),
        matching: find.byIcon(Icons.clear),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Remove "Knight Pack" from "My Game"?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.widgetWithText(Chip, 'My Game'), findsOneWidget);

    await tester.tap(find.textContaining('Audio ('));
    await pumpUntil(tester, find.text('Loop'));
    // Let the tab slide in before tapping.
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.byKey(const ValueKey('loop')));
    await tester.pump(const Duration(milliseconds: 300));
    final settings = File(p.join(tmp.path, 'settings.json'));
    expect(settings.readAsStringSync(), contains('"audio_loop": true'));
    await captureScreenshot(tester, 'm11_audio_loop', settle: false);
    await tester.pageBack();
    await tester.pump(const Duration(milliseconds: 500));

    await tester.tap(find.byTooltip('Credits'));
    await pumpUntil(tester, find.widgetWithText(ListTile, 'My Game'));
    await tester.tap(find.widgetWithText(ListTile, 'My Game'));
    final remove = find.byTooltip('Remove from My Game');
    await pumpUntil(tester, remove);
    await tester.tap(remove);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Remove "Knight Pack" from "My Game"?'), findsOneWidget);
    await captureScreenshot(tester, 'm11_credits_confirm', settle: false);
    await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
    await pumpUntil(
      tester,
      find.text(
        'No games yet. Create one, or mark a '
        'pack as "used in" from its detail page.',
      ),
    );
    final sidecar = File(
      p.join(lib, 'HeroMaker', 'Knight Pack', 'asset_pack.json'),
    ).readAsStringSync();
    expect(sidecar, isNot(contains('My Game')));
  });

  testWidgets('m12: image viewer from the carousel and the images tab', (
    tester,
  ) async {
    copyTree('test/fixtures/managed', lib);
    final pack = p.join(lib, 'HeroMaker', 'Knight Pack');
    // Checkerboards, so proportions and crispness show in the screenshots.
    void checker(String rel, int w, int h, int cell) {
      final image = img.Image(width: w, height: h);
      for (final px in image) {
        final on = (px.x ~/ cell + px.y ~/ cell).isEven;
        px.setRgb(on ? 230 : 40, on ? 120 : 90, on ? 60 : 160);
      }
      File(p.join(pack, rel))
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(img.encodePng(image));
    }

    checker('knight_mockup.png', 500, 300, 50);
    checker('ui/tall_banner-panel.png', 300, 1200, 60);
    // A UI word: a 20:1 image that isn't a strip, so it stays in Images
    // (M34 lists animations under Animations only).
    checker('fx/wide_ui-panorama.png', 4000, 200, 100);
    checker('tiny_gem.png', 16, 16, 4);
    await tester.pumpWidget(app(lib));
    await pumpUntil(tester, find.text('Knight Pack'));
    await tester.tap(find.text('Knight Pack'));
    await pumpUntil(tester, find.byTooltip('Enlarge'));
    await settleImages(tester);

    // The header preview opens the viewer on the carousel's list.
    await tester.tap(find.byTooltip('Enlarge'));
    await pumpUntil(tester, find.byType(ImageViewer));
    await settleImages(tester);
    await captureScreenshot(tester, 'm12_viewer_carousel', settle: false);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await settleImages(tester);
    expect(
      find.descendant(
        of: find.byType(ImageViewer),
        matching: find.text('Knight mockup'),
      ),
      findsOneWidget,
    );
    await captureScreenshot(tester, 'm12_viewer_mockup', settle: false);

    // The mouse back button closes it like Esc.
    final mouse = await tester.startGesture(
      const Offset(20, 20),
      kind: PointerDeviceKind.mouse,
      buttons: kBackMouseButton,
    );
    await mouse.up();
    // Frees the mouse for the card hover below.
    await mouse.removePointer();
    await pumpUntil(tester, find.byType(ImageViewer), seconds: 5, gone: true);
    expect(find.text('Knight Pack'), findsWidgets);

    await tester.tap(find.textContaining('Images ('));
    await tester.pump(const Duration(milliseconds: 500));
    await settleImages(tester);
    await openImageCard(tester, 'fx/wide_ui-panorama.png');
    await pumpUntil(tester, find.byType(ImageViewer));
    await settleImages(tester);
    expect(find.textContaining('4000 × 200 px'), findsOneWidget);
    await captureScreenshot(tester, 'm12_viewer_strip', settle: false);
    // Sorted order: fx/wide_ui-panorama, knight, knight_mockup, tiny_gem, ui/tall.
    for (final (steps, title, shot) in [
      (3, 'Tiny gem', 'm12_viewer_tiny'),
      (1, 'Tall banner panel', 'm12_viewer_tall'),
    ]) {
      for (var i = 0; i < steps; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pump();
      }
      expect(
        find.descendant(
          of: find.byType(ImageViewer),
          matching: find.text(title),
        ),
        findsOneWidget,
      );
      await settleImages(tester);
      await captureScreenshot(tester, shot, settle: false);
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await pumpUntil(tester, find.byType(ImageViewer), seconds: 5, gone: true);
  });

  testWidgets('m12: image viewer on the real library (read-only)', (
    tester,
  ) async {
    final real = p.canonicalize('../assets_library');
    if (!Directory(real).existsSync()) return;
    final before = Directory(real).statSync().modified;
    await tester.pumpWidget(app(real, library: real));
    await pumpUntil(tester, realPacks());
    // M34: Special Effects Vol.03 holds only animations now (no Images
    // tab); Village(interiors) has plain images.
    await tester.enterText(find.byType(TextField), 'Village(interiors)');
    await tester.pump(DashboardQueryNotifier.searchDebounce);
    await pumpUntil(tester, find.text(villageInteriors));
    await tester.tap(find.text(villageInteriors).first);
    await pumpUntil(tester, find.textContaining('Images ('));
    await tester.tap(find.textContaining('Images ('));
    await tester.pump(const Duration(milliseconds: 500));
    await settleImages(tester);
    // Since M40 a click focuses; the Open image icon opens the viewer.
    final first = find.byType(ItemCard).first;
    await hoverOver(tester, first);
    await tester.tap(
      find.descendant(of: first, matching: find.byTooltip('Open image')),
    );
    await pumpUntil(tester, find.byType(ImageViewer));
    await settleImages(tester);
    await captureScreenshot(tester, 'm12_viewer_real', settle: false);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await settleImages(tester);
    await captureScreenshot(tester, 'm12_viewer_real_next', settle: false);
    expect(Directory(real).statSync().modified, before);
  });

  testWidgets('m13: reveal in file manager, text and Markdown preview', (
    tester,
  ) async {
    copyTree('test/fixtures/managed', lib);
    final pack = p.join(lib, 'HeroMaker', 'Knight Pack');
    File(p.join(pack, 'README.md')).writeAsStringSync('''
# Knight Pack

A **16×16** knight with *walk* and *idle* animations.

## Contents
- `knight.png` — sprite sheet
- [itch.io page](https://heromaker.itch.io/knight)

![Banner](docs/banner.png)

| Animation | Frames |
|-----------|--------|
| Idle      | 4      |
| Walk      | 6      |
''');
    final banner = img.Image(width: 96, height: 24);
    for (final px in banner) {
      final on = (px.x ~/ 8 + px.y ~/ 8).isEven;
      px.setRgb(on ? 230 : 40, on ? 120 : 90, on ? 60 : 160);
    }
    File(p.join(pack, 'docs', 'banner.png'))
      ..parent.createSync()
      ..writeAsBytesSync(img.encodePng(banner));
    // "Licence: © 2024 Café Studio" in Latin-1, not valid UTF-8.
    File(p.join(pack, 'docs', 'License.txt'))
      ..parent.createSync()
      ..writeAsBytesSync([
        ...'Licence: '.codeUnits,
        0xA9,
        ...' 2024 Caf'.codeUnits,
        0xE9,
        ...' Studio\r\nFree for commercial use.\r\n'.codeUnits,
      ]);
    revealed.clear();
    await tester.pumpWidget(app(lib));
    await pumpUntil(tester, find.text('Knight Pack'));
    await tester.tap(find.text('Knight Pack'));
    await pumpUntil(tester, find.textContaining('Other files ('));

    // Image cards show the reveal button on hover.
    await tester.tap(find.textContaining('Images ('));
    await tester.pump(const Duration(milliseconds: 500));
    await settleImages(tester);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    final knight = find.byKey(const ValueKey('image:knight.png'));
    await mouse.moveTo(tester.getCenter(knight));
    await tester.pump();
    await captureScreenshot(tester, 'm13_image_hover', settle: false);
    await tester.tap(
      find.descendant(
        of: knight,
        matching: find.byTooltip('Show in file manager'),
      ),
    );
    expect(revealed.last, p.join(pack, 'knight.png'));
    await mouse.moveTo(Offset.zero);

    await tester.tap(find.textContaining('Other files ('));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('README.md'));
    await pumpUntil(tester, find.text('Rendered'));
    await tester.pump(const Duration(milliseconds: 400));
    await settleImages(tester);
    expect(find.byType(Image), findsWidgets);
    await captureScreenshot(tester, 'm13_markdown_rendered', settle: false);
    await tester.tap(find.text('Raw'));
    await tester.pump();
    expect(find.textContaining('# Knight Pack'), findsOneWidget);
    await captureScreenshot(tester, 'm13_markdown_raw', settle: false);
    await tester.tap(find.byTooltip('Close'));
    await pumpUntil(
      tester,
      find.byType(TextPreviewDialog),
      seconds: 5,
      gone: true,
    );

    await tester.tap(find.text('docs/License.txt'));
    await pumpUntil(tester, find.textContaining('shown as Latin-1'));
    expect(find.textContaining('© 2024 Café Studio'), findsOneWidget);
    // Let the dialog finish fading in.
    await tester.pump(const Duration(milliseconds: 400));
    await captureScreenshot(tester, 'm13_text_latin1', settle: false);
    await tester.tap(find.byTooltip('Show in file manager').last);
    expect(revealed.last, p.join(pack, 'docs', 'License.txt'));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await pumpUntil(
      tester,
      find.byType(TextPreviewDialog),
      seconds: 5,
      gone: true,
    );
  });

  testWidgets('m13: text preview on the real library (read-only)', (
    tester,
  ) async {
    final real = p.canonicalize('../assets_library');
    if (!Directory(real).existsSync()) return;
    final before = Directory(real).statSync().modified;
    await tester.pumpWidget(app(real, library: real));
    await pumpUntil(tester, realPacks());
    await tester.enterText(find.byType(TextField), 'craftpix');
    await tester.pump(DashboardQueryNotifier.searchDebounce);
    await pumpUntil(tester, find.text('Free-Basic-Pixel-Art-UI-for-RPG'));
    await tester.tap(find.text('Free-Basic-Pixel-Art-UI-for-RPG'));
    await pumpUntil(tester, find.textContaining('Other files ('));
    await tester.tap(find.textContaining('Other files ('));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('License.txt'));
    await pumpUntil(tester, find.byType(SelectableText));
    await tester.pump(const Duration(milliseconds: 400));
    await captureScreenshot(tester, 'm13_real_license', settle: false);
    expect(Directory(real).statSync().modified, before);
  });

  testWidgets('m14: tile and image thumbnail sizes (real library, read-only)', (
    tester,
  ) async {
    final real = p.canonicalize('../assets_library');
    if (!Directory(real).existsSync()) return;
    final before = Directory(real).statSync().modified;
    final settings = File(p.join(tmp.path, 'settings.json'));
    await tester.pumpWidget(app(real, library: real));
    await pumpUntil(tester, realPacks());

    // M79: the saved size is the cards' real width, a stop of the grid.
    double saved(String key) =>
        ((jsonDecode(settings.readAsStringSync()) as Map)[key] as num)
            .toDouble();
    double card(Finder f) => tester.getSize(f.first).width;

    // Slider to the far left, then the far right.
    for (final (dx, shot) in [
      (-400.0, 'm14_dashboard_min'),
      (400.0, 'm14_dashboard_max'),
    ]) {
      await tester.drag(find.byType(Slider), Offset(dx, 0));
      await tester.pump(const Duration(milliseconds: 300));
      final size = saved('dashboard_tile_size');
      expect(size, closeTo(card(find.byType(PackTile)), 1e-6));
      if (dx < 0) {
        expect(size, inInclusiveRange(140, 140 + 40));
      } else {
        // M80: over 480 px only when a whole card fits the grid's height
        // (since M91 fewer type chips leave the grid taller at 900 px).
        final tile = find.byType(PackTile).first;
        final viewport = tester
            .getSize(
              find.ancestor(of: tile, matching: find.byType(Scrollable)).first,
            )
            .height;
        expect(size, inInclusiveRange(480 - 120, maxCardWidth));
        if (size > 480) {
          expect(tester.getSize(tile).height, lessThanOrEqualTo(viewport));
        }
      }
      await settleImages(tester);
      await captureScreenshot(tester, shot, settle: false);
    }

    // M34: Special Effects Vol.03 holds only animations now (no Images
    // tab); Village(interiors) has plain images.
    await tester.enterText(find.byType(TextField), 'Village(interiors)');
    await tester.pump(DashboardQueryNotifier.searchDebounce);
    await pumpUntil(tester, find.text(villageInteriors));
    await tester.tap(find.text(villageInteriors).first);
    await pumpUntil(tester, find.textContaining('Images ('));
    await tester.tap(find.textContaining('Images ('));
    await tester.pump(const Duration(milliseconds: 500));

    // Ctrl + wheel up over the images grid: three steps bigger.
    final grid = tester.getCenter(find.byType(CustomScrollView));
    final mouse = TestPointer(1, PointerDeviceKind.mouse)..hover(grid);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    for (var i = 0; i < 3; i++) {
      await tester.sendEventToBinding(mouse.scroll(const Offset(0, -50)));
      await tester.pump();
    }
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    final bigger = saved('image_thumb_size');
    expect(bigger, greaterThan(160));
    expect(bigger, closeTo(card(find.byType(ItemCard)), 1e-6));
    await settleImages(tester);
    await captureScreenshot(tester, 'm14_images_220', settle: false);

    await tester.drag(find.byType(Slider), const Offset(-400, 0));
    await tester.pump(const Duration(milliseconds: 300));
    final smallest = saved('image_thumb_size');
    expect(smallest, inInclusiveRange(80, 100));
    expect(smallest, closeTo(card(find.byType(ItemCard)), 1e-6));
    await settleImages(tester);
    await captureScreenshot(tester, 'm14_images_min', settle: false);
    expect(Directory(real).statSync().modified, before);
  });

  testWidgets('m15: animations grid, focus mode, 60 animations', (
    tester,
  ) async {
    copyTree('test/fixtures/managed', lib);
    final zoo = Directory(p.join(lib, 'HeroMaker', 'Monster Zoo'))
      ..createSync(recursive: true);
    File(p.join(zoo.path, 'asset_pack.json'))
        .writeAsStringSync('{"title": "Monster Zoo", "types": ["character"]}');
    // 60 four-frame strips of 32 px squares: a block hopping across.
    for (var i = 0; i < 60; i++) {
      final strip = img.Image(width: 128, height: 32, numChannels: 4);
      final color = img.ColorRgba8(
        60 + (i * 37) % 190,
        60 + (i * 91) % 190,
        60 + (i * 53) % 190,
        255,
      );
      for (var f = 0; f < 4; f++) {
        img.fillRect(
          strip,
          x1: f * 32 + 4 + f * 4,
          y1: 8 + (f.isEven ? 0 : 6),
          x2: f * 32 + 16 + f * 4,
          y2: 22 + (f.isEven ? 0 : 6),
          color: color,
        );
      }
      final name = 'monster_${(i + 1).toString().padLeft(2, '0')}-walk.png';
      File(p.join(zoo.path, name)).writeAsBytesSync(img.encodePng(strip));
    }
    await tester.pumpWidget(app(lib));
    await pumpUntil(tester, find.text('Monster Zoo'));
    await tester.tap(find.text('Monster Zoo'));
    await pumpUntil(tester, find.text('Animations (60)'));
    await settleImages(tester);
    expect(find.text('Monster 01 walk'), findsOneWidget);
    // M19: Hover mode (the default) keeps the whole grid idle (the header
    // preview above it still plays).
    final gridSprites = find.descendant(
      of: find.byType(CustomScrollView),
      matching: find.byType(AnimatedSprite),
    );
    expect(
      tester.widgetList<AnimatedSprite>(gridSprites).where((s) => s.playing),
      isEmpty,
    );
    await captureScreenshot(tester, 'm15_grid', settle: false);

    await tester.tap(find.text('Monster 03 walk'));
    await tester.pump(const Duration(milliseconds: 300));
    await captureScreenshot(tester, 'm15_focus', settle: false);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump(const Duration(milliseconds: 300));
    final walk4 = tester.widget<AnimatedOpacity>(
      find.ancestor(
        of: find.text('Monster 04 walk'),
        matching: find.byType(AnimatedOpacity),
      ),
    );
    expect(walk4.opacity, 1);
    // Esc clears the focus first; the page stays open.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Animations (60)'), findsOneWidget);
    final walk3 = tester.widget<AnimatedOpacity>(
      find.ancestor(
        of: find.text('Monster 03 walk'),
        matching: find.byType(AnimatedOpacity),
      ),
    );
    expect(walk3.opacity, 1);

    // Scroll the whole grid while every visible card plays.
    await tester.tap(find.text('All'));
    await tester.pump();
    expect(
      tester.widgetList<AnimatedSprite>(gridSprites).every((s) => s.playing),
      isTrue,
    );
    final binding = IntegrationTestWidgetsFlutterBinding.instance;
    await binding.watchPerformance(() async {
      for (var i = 0; i < 6; i++) {
        await tester.fling(
          find.byType(CustomScrollView),
          const Offset(0, -500),
          2000,
        );
        await tester.pump(const Duration(milliseconds: 400));
      }
    }, reportKey: 'm15_scroll');
    final perf = binding.reportData?['m15_scroll'] as Map<String, dynamic>?;
    debugPrint(
      'm15 scroll: frames ${perf?['frame_count']}, '
      'build avg ${perf?['average_frame_build_time_millis']} ms, '
      'p90 ${perf?['90th_percentile_frame_build_time_millis']} ms, '
      'raster avg ${perf?['average_frame_rasterizer_time_millis']} ms',
    );
    await settleImages(tester);
    expect(find.text('Monster 60 walk'), findsOneWidget);
    await captureScreenshot(tester, 'm15_scrolled', settle: false);

    // Ctrl + wheel: two steps bigger.
    final startWidth = tester.getSize(find.byType(ItemCard).first).width;
    final mouse = TestPointer(1, PointerDeviceKind.mouse)
      ..hover(tester.getCenter(find.byType(CustomScrollView)));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    for (var i = 0; i < 2; i++) {
      await tester.sendEventToBinding(mouse.scroll(const Offset(0, -50)));
      await tester.pump();
    }
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    // M79: two stops up, saved as the cards' real width.
    final json = jsonDecode(
      File(p.join(tmp.path, 'settings.json')).readAsStringSync(),
    ) as Map;
    final anim = (json['animation_thumb_size'] as num).toDouble();
    expect(anim, greaterThan(startWidth));
    expect(
      anim,
      closeTo(tester.getSize(find.byType(ItemCard).first).width, 1e-6),
    );
    await settleImages(tester);
    await captureScreenshot(tester, 'm15_bigger', settle: false);
  });

  testWidgets('m15: focus mode on the real library (read-only)', (
    tester,
  ) async {
    final real = p.canonicalize('../assets_library');
    if (!Directory(real).existsSync()) return;
    final before = Directory(real).statSync().modified;
    await tester.pumpWidget(app(real, library: real));
    await pumpUntil(tester, realPacks());
    await tester.enterText(find.byType(TextField), 'oboropixel');
    await tester.pump(DashboardQueryNotifier.searchDebounce);
    await pumpUntil(tester, find.text('CharactersAnimationsAssetPack'));
    await tester.tap(find.text('CharactersAnimationsAssetPack'));
    await pumpUntil(tester, find.textContaining('Animations ('));
    await settleImages(tester);
    await captureScreenshot(tester, 'm15_real_grid', settle: false);
    await tester.tap(find.byType(AnimatedOpacity).at(4));
    await tester.pump(const Duration(milliseconds: 300));
    await settleImages(tester);
    await captureScreenshot(tester, 'm15_real_focus', settle: false);
    expect(Directory(real).statSync().modified, before);
  });

  testWidgets('m16: pin/unpin header, by-folder view (real library)', (
    tester,
  ) async {
    final real = p.canonicalize('../assets_library');
    if (!Directory(real).existsSync()) return;
    final before = Directory(real).statSync().modified;
    await tester.pumpWidget(app(real, library: real));
    await pumpUntil(tester, realPacks());
    await tester.enterText(find.byType(TextField), 'pixel banner');
    await tester.pump(DashboardQueryNotifier.searchDebounce);
    await pumpUntil(tester, find.text('Pixel-Banner'));
    await tester.tap(find.text('Pixel-Banner'));
    await pumpUntil(tester, find.textContaining('Images ('));
    await tester.pump(const Duration(milliseconds: 500));

    await tester.tap(find.textContaining('Images ('));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('By folder'));
    await tester.pump(const Duration(milliseconds: 300));
    await settleImages(tester);
    await captureScreenshot(tester, 'm16_images_by_folder', settle: false);
    // Since M43 the All-Spritesheet files are animations; the 15 images
    // left (arrows, projectiles) average two or more per sub-folder, so the
    // sections are the sub-folders, not the characters.
    expect(find.text('ArcherSkeleton / Arrow'), findsOneWidget);
    expect(find.text('ArcherSkeleton'), findsNothing);

    // Unpinned: the grid gets the height the header had.
    final gridTop = tester.getTopLeft(find.byType(CustomScrollView)).dy;
    await tester.tap(find.byTooltip('Unpin header — show it on hover (H)'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      tester.getTopLeft(find.byType(CustomScrollView)).dy,
      lessThan(gridTop - 250),
    );
    expect(
      File(p.join(tmp.path, 'settings.json')).readAsStringSync(),
      contains('"detail_header_pinned": false'),
    );
    await settleImages(tester);
    await captureScreenshot(tester, 'm16_unpinned', settle: false);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(700, 700));
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.text('Hover for details')));
    // M36: it opens after a short rest on the bar.
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(headerHoverDelay);
    await pumpUntil(tester, find.text('Used in'));
    await settleImages(tester);
    await captureScreenshot(tester, 'm16_hover_header', settle: false);
    await mouse.moveTo(const Offset(700, 700));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Used in'), findsNothing);

    await tester.tap(find.textContaining('Animations ('));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('By folder'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('ArcherSkeleton'));
    await tester.pump(const Duration(milliseconds: 300));
    await settleImages(tester);
    await captureScreenshot(tester, 'm16_animations_folded', settle: false);

    // H pins the header again.
    await tester.sendKeyEvent(LogicalKeyboardKey.keyH);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Used in'), findsOneWidget);
    expect(Directory(real).statSync().modified, before);
  });

  testWidgets('m17: expanded view and tag sort (real library, read-only)', (
    tester,
  ) async {
    final real = p.canonicalize('../assets_library');
    if (!Directory(real).existsSync()) return;
    final before = Directory(real).statSync().modified;
    await tester.pumpWidget(app(real, library: real));
    await pumpUntil(tester, realPacks());

    await tester.tap(find.text('Expanded'));
    await pumpUntil(tester, find.textContaining(' tiles'));
    expect(
      File(p.join(tmp.path, 'settings.json')).readAsStringSync(),
      contains('"dashboard_view": "expanded"'),
    );
    await tester.enterText(find.byType(TextField), 'pixel banner');
    await tester.pump(DashboardQueryNotifier.searchDebounce);
    await pumpUntil(tester, find.text('ArcherSkeleton'));
    // One tile per character folder, the pack title underneath.
    expect(find.text('Pixel-Banner', skipOffstage: false), findsNWidgets(12));
    for (final c in ['SkeletonMage', 'Wolf', 'WarriorBandit']) {
      expect(find.text(c, skipOffstage: false), findsOneWidget);
    }
    await settleImages(tester);
    await captureScreenshot(tester, 'm17_expanded', settle: false);

    // Folder names are searchable; switching views keeps the search.
    await tester.enterText(find.byType(TextField), 'skeleton');
    await tester.pump(DashboardQueryNotifier.searchDebounce);
    // The old results go once the search has run.
    await pumpUntil(tester, find.text('Wolf'), gone: true);
    expect(find.text('SkeletonWarrior'), findsOneWidget);
    await settleImages(tester);
    await captureScreenshot(tester, 'm17_expanded_search', settle: false);
    await tester.tap(find.text('Packs'));
    await pumpUntil(tester, find.text('SkeletonWarrior'), gone: true);
    expect(find.text('Pixel-Banner'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'skeleton'), findsOneWidget);
    await tester.tap(find.text('Expanded'));
    await pumpUntil(tester, find.text('SkeletonMage'));

    // A tile opens the pack at its folder.
    await tester.tap(find.text('SkeletonMage'));
    await pumpUntil(tester, find.textContaining('Images ('));
    await tester.pump(const Duration(seconds: 1));
    expect(find.byTooltip('Show the whole pack'), findsOneWidget);
    await tester.tap(find.textContaining('Images ('));
    await tester.pump(const Duration(milliseconds: 500));
    await settleImages(tester);
    await captureScreenshot(tester, 'm17_detail_folder', settle: false);
    await tester.tap(find.text('Show whole pack'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byTooltip('Show the whole pack'), findsNothing);
    await tester.pageBack();
    await tester.pump(const Duration(seconds: 1));

    // Tag sort: tiles show their tags, sorted.
    await tester.enterText(find.byType(TextField), '');
    await tester.pump(DashboardQueryNotifier.searchDebounce);
    await tester.tap(find.text('Packs'));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.byType(DropdownButton<PackSort>));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('Tags').last);
    await tester.pump(const Duration(milliseconds: 500));
    await pumpUntil(tester, find.byIcon(Icons.sell_outlined));
    await settleImages(tester);
    await captureScreenshot(tester, 'm17_tag_sort', settle: false);
    expect(Directory(real).statSync().modified, before);
  });

  testWidgets('m18: total frames in the Edit dialog; props stay images', (
    tester,
  ) async {
    copyTree('test/fixtures/managed', lib);
    final pack = Directory(p.join(lib, 'HeroMaker', 'Village Bits'))
      ..createSync(recursive: true);
    File(
      p.join(pack.path, 'asset_pack.json'),
    ).writeAsStringSync('{"title": "Village Bits", "types": ["environment"]}');
    // A 1536×64 smoke strip: 24 cells of 64 px by size, but really 16
    // frames of 96 px with a puff rising and growing.
    final strip = img.Image(width: 1536, height: 64, numChannels: 4);
    for (var f = 0; f < 16; f++) {
      final r = 8 + f;
      img.fillCircle(
        strip,
        x: f * 96 + 48,
        y: 56 - f * 3,
        radius: r,
        color: img.ColorRgba8(200 - f * 6, 200 - f * 6, 210, 255 - f * 8),
      );
    }
    File(p.join(pack.path, 'Animated stuff', 'chimney-smoke.png'))
      ..parent.createSync(recursive: true)
      ..writeAsBytesSync(img.encodePng(strip));
    // Numbered barrels: separate props, not frames.
    for (var i = 0; i < 4; i++) {
      final barrel = img.Image(width: 32, height: 32, numChannels: 4);
      img.fillRect(
        barrel,
        x1: 8,
        y1: 4 + i,
        x2: 24,
        y2: 28,
        color: img.ColorRgba8(120 + i * 20, 70, 30, 255),
      );
      File(p.join(pack.path, 'props', 'barrels_$i.png'))
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(img.encodePng(barrel));
    }

    await tester.pumpWidget(app(lib));
    await pumpUntil(tester, find.text('Village Bits'));
    await tester.tap(find.text('Village Bits'));
    await pumpUntil(tester, find.textContaining('Animations ('));
    expect(find.textContaining('Animations (1)'), findsOneWidget);
    await tester.tap(find.textContaining('Animations ('));
    await tester.pump(const Duration(milliseconds: 500));
    await hoverOver(tester, find.text('Chimney smoke'));
    await tester.tap(find.byTooltip('Edit animation'));
    await pumpUntil(tester, find.text('Apply size'));
    // M34: the column gaps give the real 16 frames of 96 px right away.
    expect(find.text('Sheet · 96×64 frames · 16 × 1 · 16 frames'), findsOne);
    final frames = find.widgetWithText(TextField, 'Frames');
    // Since M26 a count only fails when no grid fits at all.
    await tester.enterText(frames, '600');
    await tester.pump();
    expect(find.text("Doesn't fit 1536×64 px"), findsOneWidget);
    await tester.enterText(frames, '24');
    await tester.pump();
    expect(find.text('Sheet · 64×64 frames · 24 × 1 · 24 frames'), findsOne);
    await settleImages(tester);
    await captureScreenshot(tester, 'm18_frames_dialog', settle: false);
    await tester.tap(find.text('Save'));
    await pumpUntil(tester, find.text('Reset to detected'));
    expect(
      File(p.join(pack.path, 'asset_pack.json')).readAsStringSync(),
      contains('"frames": 24'),
    );
    await tester.tap(find.text('Close'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('64×64 · 24 frames · 10 fps'), findsOneWidget);
    await settleImages(tester);
    await captureScreenshot(tester, 'm18_card_16_frames', settle: false);
  });

  testWidgets('m18: Special Effects Vol.03 shows 5 grids (read-only)', (
    tester,
  ) async {
    final real = p.canonicalize('../assets_library');
    if (!Directory(real).existsSync()) return;
    final before = Directory(real).statSync().modified;
    await tester.pumpWidget(app(real, library: real));
    await pumpUntil(tester, realPacks());
    await tester.enterText(find.byType(TextField), 'special effects vol');
    await tester.pump(DashboardQueryNotifier.searchDebounce);
    await pumpUntil(tester, find.text('Special Effects Vol.03'));
    await tester.tap(find.text('Special Effects Vol.03'));
    await pumpUntil(tester, find.textContaining('Animations ('));
    expect(find.textContaining('Animations (5)'), findsOneWidget);
    await tester.tap(find.textContaining('Animations ('));
    await tester.pump(const Duration(milliseconds: 500));
    await settleImages(tester);
    await captureScreenshot(tester, 'm18_real_vol03', settle: false);
    expect(Directory(real).statSync().modified, before);
  });

  testWidgets('m19: hover play, card icons, open image (real, read-only)', (
    tester,
  ) async {
    final real = p.canonicalize('../assets_library');
    if (!Directory(real).existsSync()) return;
    final before = Directory(real).statSync().modified;
    await tester.pumpWidget(app(real, library: real));
    await pumpUntil(tester, realPacks());
    await tester.enterText(find.byType(TextField), 'oboropixel');
    await tester.pump(DashboardQueryNotifier.searchDebounce);
    await pumpUntil(tester, find.text('CharactersAnimationsAssetPack'));
    await tester.tap(find.text('CharactersAnimationsAssetPack'));
    await pumpUntil(tester, find.textContaining('Animations ('));
    await tester.tap(find.textContaining('Animations ('));
    await tester.pump(const Duration(milliseconds: 500));
    // Unpinned header: the card footers fit in the window.
    await tester.tap(find.byTooltip('Unpin header — show it on hover (H)'));
    await tester.pump(const Duration(milliseconds: 300));
    await settleImages(tester);
    bool anyPlaying() => tester
        .widgetList<AnimatedSprite>(
          find.descendant(
            of: find.byType(Card),
            matching: find.byType(AnimatedSprite),
          ),
        )
        .any((s) => s.playing);
    expect(anyPlaying(), isFalse);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(5, 895));
    addTearDown(mouse.removePointer);
    final second = find.byType(Card).at(1);
    await mouse.moveTo(tester.getCenter(second));
    await tester.pump(const Duration(milliseconds: 400));
    expect(anyPlaying(), isTrue);
    await settleImages(tester);
    await captureScreenshot(tester, 'm19_hover_card', settle: false);

    await tester.tap(
      find.descendant(of: second, matching: find.byTooltip('Open image')),
    );
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(ImageViewer), findsOneWidget);
    await settleImages(tester);
    await captureScreenshot(tester, 'm19_open_image', settle: false);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await pumpUntil(tester, find.byType(ImageViewer), seconds: 5, gone: true);

    await mouse.moveTo(tester.getCenter(second));
    await tester.pump();
    await tester.tap(
      // The tooltip says "(edited)" when the sidecar has an override.
      find.descendant(of: second, matching: find.byIcon(Icons.tune)),
    );
    await pumpUntil(tester, find.text('Apply size'));
    expect(find.byType(SelectableText), findsWidgets);
    expect(find.byTooltip('Copy relative path'), findsOneWidget);
    await settleImages(tester);
    await captureScreenshot(tester, 'm19_edit_dialog', settle: false);
    await tester.tap(find.text('Close'));
    await tester.pump(const Duration(milliseconds: 400));

    await tester.tap(find.text('All'));
    await tester.pump(const Duration(milliseconds: 300));
    await mouse.moveTo(const Offset(5, 895));
    await tester.pump();
    expect(anyPlaying(), isTrue);
    await settleImages(tester);
    await captureScreenshot(tester, 'm19_all_mode', settle: false);
    expect(Directory(real).statSync().modified, before);
  });

  testWidgets('m20: music pack opens on Audio, lengths, seek bar (real)', (
    tester,
  ) async {
    final real = p.canonicalize('../assets_library');
    if (!Directory(real).existsSync()) return;
    final before = Directory(real).statSync().modified;
    final fake = _FakeTrackPlayer();
    fakePlayer = () => fake;
    addTearDown(() => fakePlayer = null);
    await tester.pumpWidget(app(real, library: real));
    await pumpUntil(tester, realPacks());
    await tester.enterText(find.byType(TextField), 'chiptune');
    await tester.pump(DashboardQueryNotifier.searchDebounce);
    await pumpUntil(tester, find.text('music-loop-bundle-chiptune'));
    await tester.tap(find.text('music-loop-bundle-chiptune'));
    // Opens straight on Audio: the Loop chip shows without a tab tap.
    await pumpUntil(tester, find.byKey(const ValueKey('loop')));
    final length = find.textContaining(RegExp(r'^\d+:\d\d$'));
    await pumpUntil(tester, length);
    await tester.pump(const Duration(milliseconds: 500));
    await captureScreenshot(tester, 'm20_audio_lengths', settle: false);

    await tester.tap(find.byTooltip('Play').first);
    await pumpUntil(tester, find.byKey(const ValueKey('seek')));
    fake.position.add(const Duration(seconds: 42));
    await tester.pump();
    await tester.pump();
    await captureScreenshot(tester, 'm20_seek_bar', settle: false);
    await tester.tapAt(tester.getCenter(find.byKey(const ValueKey('seek'))));
    await tester.pump();
    expect(fake.seeks, isNotEmpty);
    await tester.tap(find.byTooltip('Stop'));
    await tester.pump();
    expect(find.byKey(const ValueKey('seek')), findsNothing);
    expect(Directory(real).statSync().modified, before);
  });

  testWidgets('m65: waveforms on audio cards and rows (real, read-only)', (
    tester,
  ) async {
    final real = p.canonicalize('../assets_library');
    if (!Directory(real).existsSync()) return;
    final before = Directory(real).statSync().modified;
    final fake = _FakeTrackPlayer();
    fakePlayer = () => fake;
    addTearDown(() => fakePlayer = null);
    await tester.pumpWidget(app(real, library: real));
    await pumpUntil(tester, realPacks());
    const title = 'Achievements Sound Effects 1 - Universal Sound Effects';
    await tester.enterText(
      find.byType(TextField),
      'Achievements Sound Effects 1',
    );
    await tester.pump(DashboardQueryNotifier.searchDebounce);
    await pumpUntil(tester, find.text(title));
    await tester.tap(find.text(title));
    await pumpUntil(tester, find.byKey(const ValueKey('loop')));
    await tester.tap(find.text('Cards'));
    await tester.pump(const Duration(milliseconds: 300));
    // Decoded in isolates by our own decoders: wait for every visible card.
    final bars = find.byKey(const ValueKey('waveform-bars'));
    await pumpUntil(tester, bars);
    final strips = find.byWidgetPredicate((w) => w is Waveform);
    final end = DateTime.now().add(const Duration(seconds: 30));
    while (bars.evaluate().length < strips.evaluate().length &&
        DateTime.now().isBefore(end)) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();
    }
    expect(bars.evaluate().length, strips.evaluate().length);

    // The second card plays, halfway: its played part is highlighted.
    await tester.tap(find.byTooltip('Play').at(1));
    await tester.pump();
    final playing = fake.played.single;
    final length = await tester.runAsync(
      () => Future.value(audioDuration(playing)),
    );
    fake.position.add(length! * 0.5);
    await tester.pump();
    await tester.pump();
    final painters = [
      for (final e in bars.evaluate())
        (e.widget as CustomPaint).painter! as WaveformPainter,
    ];
    expect(painters.where((w) => w.progress != null), hasLength(1));
    await captureScreenshot(tester, 'm65_audio_cards', settle: false);

    await tester.tap(find.text('Rows'));
    await tester.pump(const Duration(milliseconds: 300));
    await pumpUntil(tester, bars);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pump();
    final rowStrips = strips.evaluate().length;
    expect(bars.evaluate().length, rowStrips);
    expect(tester.getSize(bars.first), const Size(80, 20));
    await captureScreenshot(tester, 'm65_audio_rows', settle: false);
    await tester.tap(find.byTooltip('Stop'));
    await tester.pump();
    expect(Directory(real).statSync().modified, before);
  });

  testWidgets('m68: card waveform seeks, audio details (real, read-only)', (
    tester,
  ) async {
    final real = p.canonicalize('../assets_library');
    if (!Directory(real).existsSync()) return;
    final before = Directory(real).statSync().modified;
    final fake = _FakeTrackPlayer();
    fakePlayer = () => fake;
    addTearDown(() => fakePlayer = null);
    await tester.pumpWidget(app(real, library: real));
    await pumpUntil(tester, realPacks());
    await tester.enterText(find.byType(TextField), 'chiptune');
    await tester.pump(DashboardQueryNotifier.searchDebounce);
    await pumpUntil(tester, find.text('music-loop-bundle-chiptune'));
    await tester.tap(find.text('music-loop-bundle-chiptune'));
    await pumpUntil(tester, find.byKey(const ValueKey('loop')));
    await tester.tap(find.text('Cards'));
    await tester.pump(const Duration(milliseconds: 300));
    final bars = find.byKey(const ValueKey('waveform-bars'));
    await pumpUntil(tester, bars);
    await pumpUntil(tester, find.textContaining(RegExp(r'^\d+:\d\d$')));

    // A long track plays: ring, playhead, elapsed above the waveform.
    await tester.tap(find.byTooltip('Play').first);
    await pumpUntil(tester, find.byKey(const ValueKey('waveform-seek')));
    fake.position.add(const Duration(seconds: 42));
    await tester.pump();
    await tester.pump();
    final strip = tester.getRect(find.byKey(const ValueKey('waveform-seek')));
    final elapsed = find.byKey(const ValueKey('elapsed'));
    expect(tester.widget<Text>(elapsed).data, '0:42');
    expect(tester.getRect(elapsed).bottom, lessThanOrEqualTo(strip.top));
    final card = tester.getRect(
      find
          .ancestor(
            of: find.byKey(const ValueKey('waveform-seek')),
            matching: find.byType(Card),
          )
          .first,
    );
    final button = tester.getRect(find.byTooltip('Stop').first);
    expect(button.center.dy, lessThanOrEqualTo(card.center.dy + 0.5));
    expect(button.center.dy + 28, lessThanOrEqualTo(strip.top - 3.5));
    await captureScreenshot(tester, 'm68_audio_card_playing', settle: false);
    await tester.tapAt(strip.center);
    await tester.pump();
    expect(fake.seeks, isNotEmpty);
    await tester.tap(find.byTooltip('Stop').first);
    await tester.pump();

    // Rows: the Details column, and a chip's tooltip.
    await tester.tap(find.text('Rows'));
    await tester.pump(const Duration(milliseconds: 300));
    final details = find.textContaining(RegExp(r'kHz · (Mono|Stereo)'));
    await pumpUntil(tester, details);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pump();
    final chip = find.byWidgetPredicate(
      (w) =>
          w.key is ValueKey<String> &&
          (w.key! as ValueKey<String>).value.startsWith('format:'),
    );
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: tester.getCenter(chip.first));
    addTearDown(mouse.removePointer);
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(
      find.byWidgetPredicate(
        (w) => w is Text && (w.data?.contains(' kHz · ') ?? false),
      ),
      findsWidgets,
    );
    await captureScreenshot(tester, 'm68_audio_rows_details', settle: false);
    expect(Directory(real).statSync().modified, before);
  });

  testWidgets('m72: audio card details and times (real, read-only)', (
    tester,
  ) async {
    final real = p.canonicalize('../assets_library');
    if (!Directory(real).existsSync()) return;
    final before = Directory(real).statSync().modified;
    final fake = _FakeTrackPlayer();
    fakePlayer = () => fake;
    addTearDown(() => fakePlayer = null);
    await tester.pumpWidget(app(real, library: real));
    await pumpUntil(tester, realPacks());
    await tester.enterText(find.byType(TextField), 'chiptune');
    await tester.pump(DashboardQueryNotifier.searchDebounce);
    await pumpUntil(tester, find.text('music-loop-bundle-chiptune'));
    await tester.tap(find.text('music-loop-bundle-chiptune'));
    await pumpUntil(tester, find.byKey(const ValueKey('loop')));
    await tester.tap(find.text('Cards'));
    await tester.pump(const Duration(milliseconds: 300));
    await pumpUntil(tester, find.byKey(const ValueKey('waveform-bars')));
    final details = find.byWidgetPredicate(
      (w) =>
          w is Text &&
          RegExp(r'^(M|S) · [\d.]+ [KMG]?B · [\d.]+ kHz')
              .hasMatch(w.data ?? ''),
    );
    await pumpUntil(tester, details);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pump();

    // The first card: star in the corner, the length above the
    // waveform's right end, the button between the top row and the times.
    final card = find
        .ancestor(of: details.first, matching: find.byType(Card))
        .first;
    Rect part(Finder f) =>
        tester.getRect(find.descendant(of: card, matching: f).first);
    final box = tester.getRect(card);
    final wave = part(find.byKey(const ValueKey('waveform-bars')));
    final total = part(find.byKey(const ValueKey('total')));
    expect(total.right, closeTo(wave.right, 1));
    expect(total.bottom, lessThanOrEqualTo(wave.top));
    final icons = part(find.byKey(const ValueKey('audio-card-icons')));
    expect(icons.right, closeTo(box.right, 0.5));
    final button = part(find.byTooltip('Play'));
    expect(button.overlaps(icons), isFalse);
    expect(button.overlaps(total), isFalse);
    expect(button.bottom, lessThan(wave.top));
    await captureScreenshot(tester, 'm72_audio_card', settle: false);

    await tester.tap(
      find.descendant(of: card, matching: find.byTooltip('Play')),
    );
    await pumpUntil(tester, find.byKey(const ValueKey('waveform-seek')));
    fake.position.add(const Duration(seconds: 42));
    await tester.pump();
    await tester.pump();
    final elapsed = tester.getRect(find.byKey(const ValueKey('elapsed')));
    expect(elapsed.bottom, closeTo(total.bottom, 0.5));
    await captureScreenshot(tester, 'm72_audio_card_playing', settle: false);
    await tester.tap(find.byTooltip('Stop').first);
    await tester.pump();
    expect(Directory(real).statSync().modified, before);
  });

  testWidgets('m81: sort button spacing and search placeholders (real)', (
    tester,
  ) async {
    final real = p.canonicalize('../assets_library');
    if (!Directory(real).existsSync()) return;
    final before = Directory(real).statSync().modified;
    await tester.pumpWidget(app(real, library: real));
    await pumpUntil(tester, realPacks());
    final dash = find.byWidgetPredicate(
      (w) =>
          w is TextField &&
          w.decoration?.hintText == 'Search packs, authors, tags, file names',
    );
    expect(dash, findsOneWidget);
    await tester.enterText(find.byType(TextField), 'chiptune');
    await tester.pump(DashboardQueryNotifier.searchDebounce);
    await pumpUntil(tester, find.text('music-loop-bundle-chiptune'));
    await tester.tap(find.text('music-loop-bundle-chiptune'));
    await pumpUntil(tester, find.byKey(const ValueKey('loop')));
    await tester.pump(const Duration(milliseconds: 300));
    final arrow = tester.getRect(
      find.byKey(const ValueKey('audio-sort-direction')),
    );
    final icon = tester.getRect(
      find.descendant(
        of: find.byKey(const ValueKey('audio-sort-direction')),
        matching: find.byType(Icon),
      ),
    );
    // Arrow glyph → divider is the name's divider → first letter (12 px).
    final name = tester.getRect(find.byKey(const ValueKey('audio-sort-label')));
    final half = tester.getRect(find.byKey(const ValueKey('audio-sort')));
    expect(
      arrow.right - (icon.right - sortArrowGlyphInset),
      closeTo(name.left - half.left, 1),
    );
    expect(
      arrow.height,
      tester.getSize(find.byKey(const ValueKey('play-all'))).height,
    );
    expect(find.widgetWithText(TextField, 'Search files'), findsOneWidget);
    await captureScreenshot(tester, 'm81_audio_sort_button', settle: false);
    // The dashboard's field, empty, shows its placeholder.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.enterText(dash, '');
    await tester.pump(const Duration(milliseconds: 500));
    await captureScreenshot(tester, 'm81_search_fields', settle: false);
    expect(Directory(real).statSync().modified, before);
  });

  testWidgets('m77: audio card S / M line, centred button, sort button', (
    tester,
  ) async {
    final real = p.canonicalize('../assets_library');
    if (!Directory(real).existsSync()) return;
    final before = Directory(real).statSync().modified;
    await tester.pumpWidget(app(real, library: real));
    await pumpUntil(tester, realPacks());
    await tester.enterText(find.byType(TextField), 'chiptune');
    await tester.pump(DashboardQueryNotifier.searchDebounce);
    await pumpUntil(tester, find.text('music-loop-bundle-chiptune'));
    await tester.tap(find.text('music-loop-bundle-chiptune'));
    await pumpUntil(tester, find.byKey(const ValueKey('loop')));
    await tester.tap(find.text('Cards'));
    await tester.pump(const Duration(milliseconds: 300));
    await pumpUntil(tester, find.byKey(const ValueKey('waveform-bars')));
    final details = find.byWidgetPredicate(
      (w) =>
          w is Text &&
          RegExp(r'^(M|S) · [\d.]+ [KMG]?B · [\d.]+ kHz · ~?\d+')
              .hasMatch(w.data ?? ''),
    );
    await pumpUntil(tester, details);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pump();
    final card = find
        .ancestor(of: details.first, matching: find.byType(Card))
        .first;
    Rect part(Finder f) =>
        tester.getRect(find.descendant(of: card, matching: f).first);
    final box = tester.getRect(card);
    final wave = part(find.byKey(const ValueKey('waveform-bars')));
    final button = part(find.byTooltip('Play'));
    // Halfway between the card's top edge and the waveform (the strip's
    // padding: the bars may sit inside it).
    final strip = part(
      find.byWidgetPredicate(
        (w) =>
            w.key is ValueKey<String> &&
            (w.key! as ValueKey<String>).value.startsWith('waveform:'),
      ),
    );
    expect(button.center.dy, closeTo((box.top + strip.top) / 2, 1));
    expect(button.bottom, lessThan(wave.top));
    await captureScreenshot(tester, 'm77_audio_card', settle: false);

    // The sort button: Play all's height, the arrow leading.
    final play = tester.getRect(find.byKey(const ValueKey('play-all')));
    final arrow = tester.getRect(
      find.byKey(const ValueKey('audio-sort-direction')),
    );
    final label = tester.getRect(find.byKey(const ValueKey('audio-sort')));
    expect(arrow.height, play.height);
    expect(label.height, play.height);
    expect(arrow.right, closeTo(label.left, 0.5));
    await tester.tap(find.byKey(const ValueKey('audio-sort')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('audio-sort:duration')), findsOneWidget);
    await captureScreenshot(tester, 'm77_audio_toolbar', settle: false);
    // Picking the current key closes the menu; the sort stays Name.
    await tester.tap(find.byKey(const ValueKey('audio-sort:name')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('audio-sort:duration')), findsNothing);
    expect(Directory(real).statSync().modified, before);
  });

  testWidgets('m79: every slider stop changes the card size (real)', (
    tester,
  ) async {
    final real = p.canonicalize('../assets_library');
    if (!Directory(real).existsSync()) return;
    final before = Directory(real).statSync().modified;
    await tester.pumpWidget(app(real, library: real));
    await pumpUntil(tester, realPacks());
    await tester.pump(const Duration(milliseconds: 300));
    final bar = find.byKey(const ValueKey('dashboard-size-slider'));
    final s = find.descendant(
      of: bar,
      matching: find.byKey(const ValueKey('thumb-slider')),
    );
    double card() => tester.getSize(find.byType(PackTile).first).width;
    final container = ProviderScope.containerOf(
      tester.element(find.byType(Dashboard)),
    );
    final saved = container.read(settingsProvider).dashboardTileSize;
    // Every stop, smallest to largest: a new card width each time.
    final n = tester.widget<Slider>(s).divisions! + 1;
    expect(n, greaterThan(2));
    final widths = <double>[];
    for (var i = 0; i < n; i++) {
      tester.widget<Slider>(s).onChanged!(i.toDouble());
      await tester.pump();
      await tester.pump();
      widths.add(card());
      if (i > 0) expect(widths[i], greaterThan(widths[i - 1]));
    }
    // A middle stop, the label showing while the thumb is held.
    tester.widget<Slider>(s).onChanged!((n ~/ 2).toDouble());
    await tester.pump();
    await tester.pump();
    final thumb = tester.getRect(s);
    final x = thumb.left + 10 + (thumb.width - 20) * (n ~/ 2) / (n - 1);
    final drag = await tester.startGesture(Offset(x, thumb.center.dy));
    await tester.pump(const Duration(milliseconds: 300));
    await settleImages(tester);
    // M80: no value popup while dragging.
    expect(tester.widget<Slider>(s).label, isNull);
    await captureScreenshot(tester, 'm79_slider_stops', settle: false);
    await drag.up();
    await tester.pump();
    // Back to the saved size for the other tests.
    container.read(settingsProvider.notifier).setDashboardTileSize(saved);
    await tester.pump();
    expect(Directory(real).statSync().modified, before);
  });

  testWidgets('m80: the top slider stop, dashboard and Images (real)', (
    tester,
  ) async {
    final real = p.canonicalize('../assets_library');
    if (!Directory(real).existsSync()) return;
    final before = Directory(real).statSync().modified;
    await tester.pumpWidget(app(real, library: real));
    await pumpUntil(tester, realPacks());
    await tester.pump(const Duration(milliseconds: 300));
    final container = ProviderScope.containerOf(
      tester.element(find.byType(Dashboard)),
    );
    final savedTile = container.read(settingsProvider).dashboardTileSize;
    final savedImage = container.read(settingsProvider).imageThumbSize;

    Future<void> toTop(Finder bar, Finder cards, String shot) async {
      final s = find.descendant(
        of: bar,
        matching: find.byKey(const ValueKey('thumb-slider')),
      );
      final startWidth = tester.getSize(cards.first).width;
      final slider = tester.widget<Slider>(s);
      slider.onChanged!(slider.divisions!.toDouble());
      await tester.pump();
      await tester.pump();
      await settleImages(tester);
      final card = tester.getSize(cards.first);
      final viewport = tester
          .getSize(
            find
                .ancestor(of: cards.first, matching: find.byType(Scrollable))
                .first,
          )
          .height;
      // Grew; at most 800 px; over the old maximum only when it fits
      // whole (the stops are unit-tested).
      expect(card.width, greaterThan(startWidth));
      expect(card.width, lessThanOrEqualTo(maxCardWidth));
      if (card.width > 480) expect(card.height, lessThanOrEqualTo(viewport));
      expect(tester.widget<Slider>(s).label, isNull);
      await captureScreenshot(tester, shot, settle: false);
    }

    await toTop(
      find.byKey(const ValueKey('dashboard-size-slider')),
      find.byType(PackTile),
      'm80_one_per_row_dashboard',
    );
    container.read(settingsProvider.notifier).setDashboardTileSize(savedTile);
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'Village(interiors)');
    await tester.pump(DashboardQueryNotifier.searchDebounce);
    await pumpUntil(tester, find.text(villageInteriors));
    await tester.tap(find.text(villageInteriors).first);
    await pumpUntil(tester, find.textContaining('Images ('));
    await tester.tap(find.textContaining('Images ('));
    await tester.pump(const Duration(milliseconds: 500));
    await settleImages(tester);
    await toTop(
      find.byType(ThumbSizeSlider),
      find.byType(ItemCard),
      'm80_one_per_row_images',
    );
    container.read(settingsProvider.notifier).setImageThumbSize(savedImage);
    await tester.pump();
    expect(Directory(real).statSync().modified, before);
  });

  testWidgets('m73: audio sorted by duration (real, read-only)', (
    tester,
  ) async {
    final real = p.canonicalize('../assets_library');
    if (!Directory(real).existsSync()) return;
    final before = Directory(real).statSync().modified;
    await tester.pumpWidget(app(real, library: real));
    await pumpUntil(tester, realPacks());
    await tester.enterText(find.byType(TextField), 'chiptune');
    await tester.pump(DashboardQueryNotifier.searchDebounce);
    await pumpUntil(tester, find.text('music-loop-bundle-chiptune'));
    await tester.tap(find.text('music-loop-bundle-chiptune'));
    await pumpUntil(tester, find.byKey(const ValueKey('loop')));
    await tester.tap(find.text('Rows'));
    await tester.pump(const Duration(milliseconds: 300));
    final header = find.byKey(const ValueKey('audio-header:Duration'));
    await pumpUntil(tester, header);
    // Longest first: click twice.
    await tester.tap(header);
    await tester.pump();
    await tester.tap(header);
    await tester.pump();
    final progress = find.byKey(const ValueKey('audio-sort-progress'));
    for (var i = 0; i < 100 && progress.evaluate().isNotEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
    }
    expect(progress, findsNothing);
    await pumpUntil(tester, find.byKey(const ValueKey('waveform-bars')));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pump();
    // The lengths down the list never grow.
    final texts = [
      for (final e
          in find
              .descendant(
                of: find.byWidgetPredicate(
                  (w) =>
                      w.key is ValueKey<String> &&
                      (w.key! as ValueKey<String>).value.startsWith('length:'),
                ),
                matching: find.byType(Text),
              )
              .evaluate())
        (
          tester.getTopLeft(find.byWidget(e.widget)).dy,
          (e.widget as Text).data!,
        ),
    ]..sort((a, b) => a.$1.compareTo(b.$1));
    int secs(String s) {
      final [m, sec] = s.split(':');
      return int.parse(m) * 60 + int.parse(sec);
    }

    final shown = [
      for (final (_, s) in texts)
        if (s.isNotEmpty) secs(s),
    ];
    expect(shown.length, greaterThan(3));
    expect(shown, orderedEquals([...shown]..sort((a, b) => b - a)));
    await captureScreenshot(tester, 'm73_audio_sorted', settle: false);
    // Back to the default for the other tests.
    await tester.tap(find.byKey(const ValueKey('audio-header:Name')));
    await tester.pump();
    expect(Directory(real).statSync().modified, before);
  });

  testWidgets('m74: one sound at a time across pack tabs (real, read-only)', (
    tester,
  ) async {
    final real = p.canonicalize('../assets_library');
    if (!Directory(real).existsSync()) return;
    final before = Directory(real).statSync().modified;
    final players = <_FakeTrackPlayer>[];
    fakePlayer = () {
      final f = _FakeTrackPlayer();
      players.add(f);
      return f;
    };
    addTearDown(() => fakePlayer = null);
    await tester.pumpWidget(app(real, library: real));
    await pumpUntil(tester, realPacks());
    // One search shows both (a second search after a tab opened did not
    // reach the query in this harness; see the M74 report).
    const music = 'Monster Sound Effects 3';
    const sfx = 'Footsteps Sound Effects 3 - Universal Sound Effects';
    Finder tile(String t) =>
        find.descendant(of: find.byType(PackTile), matching: find.text(t));
    Finder strip(String t) =>
        find.descendant(of: find.byType(PackTabStrip), matching: find.text(t));
    await tester.enterText(find.byType(TextField).first, 'Sound Effects 3');
    await tester.pump(DashboardQueryNotifier.searchDebounce);
    await pumpUntil(tester, tile(music));
    await pumpUntil(tester, tile(sfx));
    for (final title in [music, sfx]) {
      // Built is not on screen: the grid builds a little ahead.
      await tester.ensureVisible(tile(title));
      await tester.pump(const Duration(milliseconds: 300));
      final g = await tester.startGesture(
        tester.getCenter(tile(title)),
        kind: PointerDeviceKind.mouse,
        buttons: kMiddleMouseButton,
      );
      await g.up();
      await tester.pump(const Duration(milliseconds: 300));
    }
    Future<void> show(String title) async {
      await tester.tap(strip(title));
      await tester.pump(const Duration(milliseconds: 500));
      await pumpUntil(tester, find.byKey(const ValueKey('loop')).hitTestable());
    }

    // Play in the music tab.
    await show(music);
    await tester.tap(find.byTooltip('Play').hitTestable().first);
    await tester.pump();
    final a = players.single;
    expect(a.played, hasLength(1));
    expect(find.byTooltip('Stop').hitTestable(), findsOneWidget);
    final stops = a.stops;

    // The sound effects tab: the music stopped; play one here.
    await show(sfx);
    expect(a.stops, greaterThan(stops));
    await tester.tap(find.byTooltip('Play').hitTestable().first);
    await tester.pump();
    expect(players, hasLength(2));
    expect(players.last.played, hasLength(1));
    await settleImages(tester);
    await captureScreenshot(tester, 'm74_second_tab_playing', settle: false);

    // Back to the music: nothing plays there, nothing resumed.
    await show(music);
    expect(a.played, hasLength(1));
    expect(find.byTooltip('Stop').hitTestable(), findsNothing);
    await settleImages(tester);
    await captureScreenshot(tester, 'm74_first_tab_stopped', settle: false);
    expect(Directory(real).statSync().modified, before);
  });

  testWidgets('m69: right-click menu copies through GTK (real, read-only)', (
    tester,
  ) async {
    final real = p.canonicalize('../assets_library');
    if (!Directory(real).existsSync()) return;
    final before = Directory(real).statSync().modified;
    await tester.pumpWidget(app(real, library: real));
    await pumpUntil(tester, realPacks());
    await tester.enterText(find.byType(TextField).first, 'Epic RPG World');
    await tester.pump(DashboardQueryNotifier.searchDebounce);
    const village = 'Epic RPG World - The Village V2.2';
    final tile = find.descendant(
      of: find.byType(PackTile),
      matching: find.text(village),
    );
    await pumpUntil(tester, tile);
    await tester.tap(tile);
    await pumpUntil(tester, find.textContaining('Images ('));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.textContaining('Images ('));
    await tester.pump(const Duration(milliseconds: 500));
    final cards = find.byType(ItemCard);
    await pumpUntil(tester, cards);
    await settleImages(tester);
    final card = cards.at(1);
    final rel = tester.widget<ItemCard>(card).path;
    final path = p.join(real, 'RafaelMatos', village, rel);

    Future<void> menu() async {
      await tester.tap(card, buttons: kSecondaryButton);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    }

    await menu();
    expect(find.text('Copy image to clipboard'), findsOneWidget);
    expect(find.text('Open with…'), findsOneWidget);
    await captureScreenshot(tester, 'm69_card_menu', settle: false);

    // Copy image: PNG bytes at the image's own size.
    await tester.tap(find.text('Copy image to clipboard'));
    await pumpUntil(tester, find.text('Image copied'));
    final png = await clipRead(tester, 'image/png');
    expect(png, isNotNull);
    final copied = img.decodePng(png!)!;
    final source = img.decodeImage(File(path).readAsBytesSync())!;
    expect((copied.width, copied.height), (source.width, source.height));

    // Copy file: a URI list, the file managers' list, and the path.
    await menu();
    await tester.tap(find.text('Copy file'));
    await pumpUntil(tester, find.text('File copied'));
    final uris = await clipRead(tester, 'text/uri-list');
    expect(utf8.decode(uris!).trim(), Uri.file(path).toString());
    if (Platform.isLinux) {
      final gnome = await clipRead(tester, 'x-special/gnome-copied-files');
      expect(utf8.decode(gnome!), 'copy\n${Uri.file(path)}');
    }
    // A file only: no picture for a file manager to paste instead (M75).
    final offered = await tester.runAsync(PlatformFileClipboard.targets);
    expect(offered!.where((t) => t.startsWith('image/')), isEmpty);
    final text = await tester.runAsync(
      () => Clipboard.getData(Clipboard.kTextPlain),
    );
    expect(text?.text, path);
    expect(Directory(real).statSync().modified, before);
  });

  testWidgets('m70: Copy as GIF on an animation card (real, read-only)', (
    tester,
  ) async {
    final real = p.canonicalize('../assets_library');
    if (!Directory(real).existsSync()) return;
    final before = Directory(real).statSync().modified;
    await tester.pumpWidget(app(real, library: real));
    await pumpUntil(tester, realPacks());
    await tester.enterText(find.byType(TextField).first, 'Epic RPG World');
    await tester.pump(DashboardQueryNotifier.searchDebounce);
    const village = 'Epic RPG World - The Village V2.2';
    final tile = find.descendant(
      of: find.byType(PackTile),
      matching: find.text(village),
    );
    await pumpUntil(tester, tile);
    await tester.tap(tile);
    await pumpUntil(tester, find.textContaining('Animations ('));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.textContaining('Animations ('));
    await tester.pump(const Duration(milliseconds: 500));
    final cards = find.byType(ItemCard);
    await pumpUntil(tester, cards);
    await settleImages(tester);
    // A sheet with several frames.
    final card = cards.first;
    Future<void> menu() async {
      await tester.tap(card, buttons: kSecondaryButton);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    }

    await menu();
    // The GIF items first, then the image card's (M75).
    final labels = [
      for (final e
          in find
              .descendant(
                of: find.byType(PopupMenuItem<FileMenuAction>),
                matching: find.byType(ListTile),
              )
              .evaluate())
        ((e.widget as ListTile).title! as Text).data!,
    ];
    expect(labels, [
      'Copy as GIF to clipboard',
      'Copy as GIF file',
      'Copy image to clipboard',
      'Copy file',
      'Copy path',
      'Open',
      'Open with…',
      // The pack's own previews (cover picker commits, 2026-11-14).
      'Use as pack cover',
      'Add to pack previews',
    ]);
    await captureScreenshot(tester, 'm70_copy_as_gif', settle: false);
    await captureScreenshot(tester, 'm75_card_menu', settle: false);

    // To clipboard: only the picture (image/gif), no file.
    await tester.tap(find.text('Copy as GIF to clipboard'));
    await pumpUntil(tester, find.text('GIF copied'));
    final gif = await clipRead(tester, 'image/gif');
    expect(gif, isNotNull);
    expect(String.fromCharCodes(gif!.take(6)), 'GIF89a');
    final frames = await tester.runAsync(() async {
      final codec = await ui.instantiateImageCodec(gif);
      final n = codec.frameCount;
      codec.dispose();
      return n;
    });
    expect(frames, greaterThan(1));
    var offered = (await tester.runAsync(PlatformFileClipboard.targets))!;
    expect(offered, contains('image/gif'));
    expect(offered, isNot(contains('text/uri-list')));
    expect(offered, isNot(contains('x-special/gnome-copied-files')));

    // GIF file: only the file (a moving .gif), no image target.
    await menu();
    await tester.tap(find.text('Copy as GIF file'));
    await pumpUntil(tester, find.text('GIF file copied'));
    final uris = await clipRead(tester, 'text/uri-list');
    final file = File.fromUri(Uri.parse(utf8.decode(uris!).trim()));
    expect(p.extension(file.path), '.gif');
    expect(file.readAsBytesSync(), gif);
    offered = (await tester.runAsync(PlatformFileClipboard.targets))!;
    expect(offered.where((t) => t.startsWith('image/')), isEmpty);
    if (Platform.isLinux) {
      expect(offered, contains('x-special/gnome-copied-files'));
    }
    expect(p.isWithin(real, file.path), isFalse);
    expect(Directory(real).statSync().modified, before);
  });

  testWidgets('m71: plain card icons on white and black, audio hover', (
    tester,
  ) async {
    copyTree('test/fixtures/managed', lib);
    final pack = p.join(lib, 'HeroMaker', 'Knight Pack');
    for (final (name, v) in [('white', 255), ('black', 0), ('grey', 128)]) {
      final image = img.Image(width: 32, height: 32, numChannels: 4);
      img.fill(image, color: img.ColorRgba8(v, v, v, 255));
      File(p.join(pack, 'tiles', '$name.png'))
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(img.encodePng(image));
    }
    for (final name in ['blip', 'chime', 'thud']) {
      File(p.join(pack, 'sfx', '$name.wav'))
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(List.filled(64, 1));
    }
    // Hover fades run on real time here.
    Future<void> fades(WidgetTester tester) async {
      for (var i = 0; i < 4; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 150)),
        );
        await tester.pump(const Duration(milliseconds: 150));
      }
    }

    await tester.pumpWidget(app(lib));
    await pumpUntil(tester, find.text('Knight Pack'));
    await tester.tap(find.text('Knight Pack'));
    await pumpUntil(tester, find.textContaining('Images ('));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.textContaining('Images ('));
    await tester.pump(const Duration(milliseconds: 500));
    Finder card(String rel) => find.byKey(ValueKey('image:$rel'));
    await pumpUntil(tester, card('tiles/white.png'));
    await settleImages(tester);

    // Black: starred. Grey: selected. White: hovered.
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: tester.getCenter(card('tiles/black.png')));
    addTearDown(mouse.removePointer);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const ValueKey('star:tiles/black.png')));
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.tap(card('tiles/grey.png'));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump(const Duration(milliseconds: 300));
    await mouse.moveTo(tester.getCenter(card('tiles/white.png')));
    await fades(tester);
    expect(find.byKey(const ValueKey('star:tiles/white.png')), findsOneWidget);
    expect(find.byKey(const ValueKey('select:tiles/grey.png')), findsOneWidget);
    await captureScreenshot(tester, 'm71_image_card_icons', settle: false);

    await tester.tap(find.textContaining('Audio ('));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('Cards'));
    await tester.pump(const Duration(milliseconds: 300));
    final sound = find.ancestor(
      of: find.text('Chime'),
      matching: find.byType(Card),
    );
    await pumpUntil(tester, sound);
    // Over the card, clear of the play button (no tooltip).
    await mouse.moveTo(
      tester.getRect(sound.first).topLeft + const Offset(60, 70),
    );
    await fades(tester);
    await captureScreenshot(tester, 'm71_audio_hover', settle: false);
  });

  testWidgets('m66: each format in its own column (real, read-only)', (
    tester,
  ) async {
    final real = p.canonicalize('../assets_library');
    if (!Directory(real).existsSync()) return;
    final before = Directory(real).statSync().modified;
    await tester.pumpWidget(app(real, library: real));
    await pumpUntil(tester, realPacks());
    const title = 'Achievements Sound Effects 1 - Universal Sound Effects';
    await tester.enterText(
      find.byType(TextField),
      'Achievements Sound Effects 1',
    );
    await tester.pump(DashboardQueryNotifier.searchDebounce);
    await pumpUntil(tester, find.text(title));
    await tester.tap(find.text(title));
    await pumpUntil(tester, find.byKey(const ValueKey('loop')));
    await tester.tap(find.text('Rows'));
    await tester.pump(const Duration(milliseconds: 300));
    // The last tracks have only WAV: scroll to them.
    await tester.drag(find.byType(ListView).last, const Offset(0, -20000));
    await tester.pump(const Duration(milliseconds: 300));
    Map<String, Set<double>> lefts() {
      final byFormat = <String, Set<double>>{};
      for (final e
          in find
              .byWidgetPredicate(
                (w) =>
                    w.key is ValueKey<String> &&
                    (w.key! as ValueKey<String>).value.startsWith('format:'),
              )
              .evaluate()) {
        final key = (e.widget.key! as ValueKey<String>).value;
        final box = e.renderObject! as RenderBox;
        byFormat
            .putIfAbsent(p.extension(key).toLowerCase(), () => {})
            .add(box.localToGlobal(Offset.zero).dx);
      }
      return byFormat;
    }

    final byFormat = lefts();
    expect(byFormat['.wav'], isNotNull);
    for (final MapEntry(:key, :value) in byFormat.entries) {
      expect(value, hasLength(1), reason: key);
    }
    await settleImages(tester);
    await captureScreenshot(tester, 'm66_audio_format_columns', settle: false);
    expect(Directory(real).statSync().modified, before);
  });

  testWidgets('m25: audio cards on a real SFX pack, loop restart (real)', (
    tester,
  ) async {
    final real = p.canonicalize('../assets_library');
    if (!Directory(real).existsSync()) return;
    final before = Directory(real).statSync().modified;
    final fake = _FakeTrackPlayer();
    fakePlayer = () => fake;
    addTearDown(() => fakePlayer = null);
    await tester.pumpWidget(app(real, library: real));
    await pumpUntil(tester, realPacks());
    await tester.enterText(find.byType(TextField), '16-BIT Achievements');
    await tester.pump(DashboardQueryNotifier.searchDebounce);
    await pumpUntil(tester, find.text('16-BIT Achievements SFX Pack 1'));
    await tester.tap(find.text('16-BIT Achievements SFX Pack 1'));
    await pumpUntil(tester, find.byKey(const ValueKey('loop')));
    await tester.tap(find.text('Cards'));
    await pumpUntil(tester, find.textContaining(RegExp(r'^\d+:\d\d$')));
    await tester.pump(const Duration(milliseconds: 500));
    await captureScreenshot(tester, 'm25_audio_cards', settle: false);

    // A short sound: progress ring, only its length.
    await tester.tap(find.byTooltip('Play').first);
    await tester.pump();
    fake.position.add(const Duration(milliseconds: 600));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('progress')), findsOneWidget);
    expect(find.byKey(const ValueKey('elapsed')), findsNothing);
    await captureScreenshot(tester, 'm25_card_playing', settle: false);
    await tester.tap(find.byTooltip('Stop'));
    await tester.pump();
    await tester.tap(find.text('Rows'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(Directory(real).statSync().modified, before);
  });

  testWidgets('m37: Play all on a real SFX pack (real, read-only)', (
    tester,
  ) async {
    final real = p.canonicalize('../assets_library');
    if (!Directory(real).existsSync()) return;
    final before = Directory(real).statSync().modified;
    final fake = _FakeTrackPlayer();
    fakePlayer = () => fake;
    addTearDown(() => fakePlayer = null);
    await tester.pumpWidget(app(real, library: real));
    await pumpUntil(tester, realPacks());
    await tester.enterText(find.byType(TextField), '16-BIT Achievements');
    await tester.pump(DashboardQueryNotifier.searchDebounce);
    await pumpUntil(tester, find.text('16-BIT Achievements SFX Pack 1'));
    await tester.tap(find.text('16-BIT Achievements SFX Pack 1'));
    await pumpUntil(tester, find.widgetWithText(FilledButton, 'Play all'));
    await tester.pump(const Duration(milliseconds: 500));

    await tester.tap(find.widgetWithText(FilledButton, 'Play all'));
    await tester.pump();
    expect(find.widgetWithText(FilledButton, 'Stop'), findsOneWidget);
    // Three sounds end; the fourth plays (no audio under xvfb: a fake).
    for (var i = 0; i < 3; i++) {
      fake.complete.add(null);
      await tester.pump();
      await tester.pump(playAllGap + const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 300));
    }
    expect(fake.played, hasLength(4));
    expect(fake.played.toSet(), hasLength(4));
    expect(fake.looping, isFalse);
    final fourth = p.basenameWithoutExtension(fake.played.last);
    final row = tester.widget<ListTile>(
      find.ancestor(of: find.text(fourth), matching: find.byType(ListTile)),
    );
    expect(row.selected, isTrue);
    await captureScreenshot(tester, 'm37_play_all_rows', settle: false);

    // Cards: the run goes on; the playing card is shown.
    await tester.tap(find.text('Cards'));
    await tester.pump(const Duration(milliseconds: 300));
    fake.complete.add(null);
    await tester.pump();
    await tester.pump(playAllGap + const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 300));
    expect(fake.played, hasLength(5));
    await captureScreenshot(tester, 'm37_play_all_cards', settle: false);

    await tester.tap(find.widgetWithText(FilledButton, 'Stop'));
    await tester.pump();
    expect(find.widgetWithText(FilledButton, 'Play all'), findsOneWidget);
    await tester.tap(find.text('Rows'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(Directory(real).statSync().modified, before);
  });

  testWidgets('m38: favorites — stars, dashboard and detail chips', (
    tester,
  ) async {
    const pixel =
        '../assets_library/Kenney/Kenney Game Assets 1 version 42/2D assets/'
        'Explosion Pack/PNG/Pixel explosion';
    if (!Directory(pixel).existsSync()) return;
    // A temp copy: the real library is never written.
    copyTree('test/fixtures/managed', lib);
    final pack = p.join(lib, 'HeroMaker', 'Knight Pack');
    copyTree(pixel, p.join(pack, 'fx', 'Pixel explosion'));
    Map<String, Object?> sidecar() =>
        jsonDecode(File(p.join(pack, 'asset_pack.json')).readAsStringSync())
            as Map<String, Object?>;
    final fileStars = find.byWidgetPredicate(
      (w) =>
          w is FavoriteStar &&
          w.key is ValueKey<String> &&
          (w.key! as ValueKey<String>).value.startsWith('star:'),
    );

    await tester.pumpWidget(app(lib));
    await pumpUntil(tester, find.text('Knight Pack'));
    final g = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await g.addPointer(
      location: tester.getCenter(find.widgetWithText(PackTile, 'Knight Pack')),
    );
    addTearDown(g.removePointer);
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('pack-star')));
    await tester.pump();
    expect(sidecar()['favorite'], isTrue);
    await g.moveTo(const Offset(1430, 890));
    await tester.pump();
    await settleImages(tester);
    await captureScreenshot(tester, 'm38_dashboard_star', settle: false);

    // Pack page: star two images.
    await tester.tap(find.text('Knight Pack'));
    await pumpUntil(tester, find.textContaining('Images ('));
    await tester.tap(find.textContaining('Images ('));
    await tester.pump(const Duration(milliseconds: 500));
    final cards = find.byType(ItemCard);
    await pumpUntil(tester, cards);
    for (final i in [0, 2]) {
      await g.moveTo(tester.getCenter(cards.at(i)));
      await tester.pump();
      await tester.tap(fileStars.last);
      await tester.pump();
    }
    expect(sidecar()['favorite_files'], hasLength(2));
    expect(sidecar()['future_field'], 42);
    await g.moveTo(const Offset(1430, 890));
    await tester.pump();
    await settleImages(tester);
    await captureScreenshot(tester, 'm38_detail_stars', settle: false);

    await tester.tap(find.byKey(const ValueKey('detail-favorites-chip')));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Images (2)'), findsOneWidget);
    await settleImages(tester);
    await captureScreenshot(tester, 'm38_detail_chip', settle: false);

    // Dashboard: the Favorites chip, then the Files view.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await pumpUntil(tester, find.byKey(const ValueKey('favorites-chip')));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.byKey(const ValueKey('favorites-chip')));
    await tester.pump();
    expect(find.widgetWithText(PackTile, 'Slimes'), findsNothing);
    await settleImages(tester);
    await captureScreenshot(tester, 'm38_dashboard_chip', settle: false);
    await tester.tap(find.text('Files'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('2 files'), findsOneWidget);
    await settleImages(tester);
    await captureScreenshot(tester, 'm38_files_view', settle: false);
    await tester.tap(find.text('Packs'));
    await tester.tap(find.byKey(const ValueKey('favorites-chip')));
    await tester.pump();
  });

  testWidgets('m45: import menu, ★ chip height, confirm, Audio toolbar', (
    tester,
  ) async {
    copyTree('test/fixtures/managed', lib);
    final pack = p.join(lib, 'HeroMaker', 'Knight Pack');
    File('test/fixtures/audio/tone.wav').copySync(p.join(pack, 'hit.wav'));
    final strip = img.Image(width: 64, height: 16, numChannels: 4);
    for (var f = 0; f < 4; f++) {
      img.fillRect(
        strip,
        x1: f * 16 + 4,
        y1: 4,
        x2: f * 16 + 11,
        y2: 11,
        color: img.ColorRgba8(220, 120, 40, 255),
      );
    }
    Directory(p.join(pack, 'fx')).createSync();
    File(p.join(pack, 'fx', 'smoke_strip.png'))
        .writeAsBytesSync(img.encodePng(strip));

    await tester.pumpWidget(app(lib));
    await pumpUntil(tester, find.text('Knight Pack'));
    await tester.pump(const Duration(milliseconds: 500));
    // Dashboard: one import icon, its menu open.
    final bar = find.byType(AppBar);
    expect(
      find.descendant(of: bar, matching: find.byType(OutlinedButton)),
      findsNothing,
    );
    final chip = find.byKey(const ValueKey('favorites-chip'));
    expect(find.descendant(of: chip, matching: find.text('0')), findsOneWidget);
    await tester.tap(find.byTooltip('Import'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Import folder… (Ctrl+I)'), findsOneWidget);
    expect(find.text('Import archive… (Ctrl+O)'), findsOneWidget);
    await settleImages(tester);
    await captureScreenshot(tester, 'm45_import_menu', settle: false);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await pumpUntil(tester, find.text('Import folder… (Ctrl+I)'), gone: true);

    // Detail: the ★ chip and the search box paint one box.
    await tester.tap(find.text('Knight Pack'));
    await pumpUntil(tester, find.textContaining('Audio ('));
    await tester.pump(const Duration(milliseconds: 500));
    final detailChip = find.byKey(const ValueKey('detail-favorites-chip'));
    final search = find.widgetWithText(TextField, 'Search files');
    final chipBox = tester.getRect(
      find.descendant(of: detailChip, matching: find.byType(Material)).first,
    );
    final fieldBox = tester.getRect(
      find.descendant(of: search, matching: find.byType(InputDecorator)),
    );
    expect(chipBox.top, fieldBox.top);
    expect(chipBox.bottom, fieldBox.bottom);
    await settleImages(tester);
    final shot = await captureScreenshot(
      tester,
      'm45_detail_toolbar',
      settle: false,
    );
    // A 4× crop of the chip and the search box.
    final area = chipBox.expandToInclude(fieldBox).inflate(8);
    final full = img.decodePng(shot.readAsBytesSync())!;
    final crop = img.copyCrop(
      full,
      x: area.left.floor(),
      y: area.top.floor(),
      width: area.width.ceil(),
      height: area.height.ceil(),
    );
    File('screenshots/m45_detail_toolbar_zoom.png').writeAsBytesSync(
      img.encodePng(
        img.copyResize(
          crop,
          width: crop.width * 4,
          interpolation: img.Interpolation.nearest,
        ),
      ),
    );

    // "Not an animation" asks first; Cancel keeps it.
    await tester.tap(find.textContaining('Animations ('));
    await tester.pump(const Duration(milliseconds: 500));
    final card = find.byType(ItemCard).first;
    await pumpUntil(tester, card);
    await hoverOver(tester, card);
    await tester.tap(find.byTooltip('Edit animation').first);
    await pumpUntil(tester, find.text('Not an animation'));
    await tester.tap(find.text('Not an animation'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Mark as image'), findsOneWidget);
    await captureScreenshot(tester, 'm45_not_animation_confirm', settle: false);
    await tester.tap(find.text('Cancel'));
    await pumpUntil(tester, find.text('Mark as image'), gone: true);
    expect(find.text('Not an animation'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump(const Duration(milliseconds: 800));
    expect(
      File(p.join(pack, 'asset_pack.json')).readAsStringSync(),
      isNot(contains('smoke_strip')),
    );

    // Audio: its toolbar sits where the Images toolbar does.
    Rect toolbarOf(Finder toggle) => tester.getRect(toggle);
    await tester.tap(find.textContaining('Images ('));
    await tester.pump(const Duration(milliseconds: 500));
    final images = toolbarOf(find.text('Flat').last);
    await tester.tap(find.textContaining('Audio ('));
    await tester.pump(const Duration(milliseconds: 500));
    final audio = toolbarOf(find.text('Rows').last);
    expect(audio.top, images.top);
    await settleImages(tester);
    await captureScreenshot(tester, 'm45_audio_toolbar', settle: false);
  });

  testWidgets('m46: By folder view after Collapse all', (tester) async {
    copyTree('test/fixtures/managed', lib);
    final pack = p.join(lib, 'HeroMaker', 'Knight Pack');
    var shade = 0;
    for (final rel in [
      'heroes/red/a.png',
      'heroes/red/b.png',
      'heroes/blue/c.png',
      'props/d.png',
    ]) {
      final sprite = img.Image(width: 32, height: 32, numChannels: 4);
      img.fillCircle(
        sprite,
        x: 16,
        y: 16,
        radius: 12,
        color: img.ColorRgba8(60 + shade, 160, 220 - shade, 255),
      );
      shade += 50;
      File(p.join(pack, rel))
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(img.encodePng(sprite));
    }
    await tester.pumpWidget(app(lib));
    await pumpUntil(tester, find.text('Knight Pack'));
    await tester.tap(find.text('Knight Pack'));
    await pumpUntil(tester, find.textContaining('Images ('));
    await tester.tap(find.textContaining('Images ('));
    await tester.pump(const Duration(milliseconds: 500));
    final fold = find.byKey(const ValueKey('fold-all'));
    expect(fold, findsNothing);
    await tester.tap(find.text('By folder').first);
    await pumpUntil(tester, fold);
    await settleImages(tester);
    await captureScreenshot(tester, 'm46_by_folder_open', settle: false);
    await tester.tap(fold);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(ItemCard), findsNothing);
    expect(find.byTooltip('Expand all folders'), findsOneWidget);
    await captureScreenshot(tester, 'm46_collapsed_all', settle: false);
    // Every folder header is on screen once folded.
    for (final title in ['Pack root', 'Heroes', 'Props']) {
      expect(find.text(title), findsOneWidget, reason: title);
    }
    await tester.tap(fold);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(ItemCard), findsWidgets);
    expect(find.byTooltip('Collapse all folders'), findsOneWidget);
  });

  testWidgets('m48: Loot Silo on the first-start screen and dashboard', (
    tester,
  ) async {
    copyTree('test/fixtures/managed', lib);
    // No settings file yet: the first-start screen.
    await tester.pumpWidget(app(lib, restart: true));
    await pumpUntil(tester, find.text('Choose a library folder'));
    // The app bar name; since M52 the logo below shows it too, as text.
    expect(
      find.descendant(
        of: find.byType(AppBar),
        matching: find.text('Loot Silo'),
      ),
      findsOneWidget,
    );
    expectLockup(tester);
    expect(
      find.bySemanticsLabel('Loot Silo. Your game assets. At a glance.'),
      findsOneWidget,
    );
    await captureScreenshot(tester, 'm48_first_start', settle: false);
    await tester.tap(find.text('Choose folder'));
    await pumpUntil(tester, find.text('Knight Pack'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(
      find.descendant(
        of: find.byType(AppBar),
        matching: find.text('Loot Silo'),
      ),
      findsOneWidget,
    );
    expect(find.byTooltip('How Loot Silo works (F1)'), findsOneWidget);
    await settleImages(tester);
    await settleImages(tester);
    await captureScreenshot(tester, 'm48_dashboard', settle: false);
  });

  testWidgets('m49/m52: one logo on first start, About and Help', (
    tester,
  ) async {
    copyTree('test/fixtures/managed', lib);
    final logo = find.byKey(const ValueKey('app-logo'));
    for (final theme in [ThemeChoice.light, ThemeChoice.dark]) {
      final name = theme.name;
      // A fresh start in this theme: no library yet.
      SettingsStore(File(p.join(tmp.path, 'settings.json')))
          .save(AppSettings(theme: theme));
      await tester.pumpWidget(app(lib, restart: true));
      await pumpUntil(tester, find.text('Choose a library folder'));
      await pumpUntil(tester, logo);
      expectLockup(tester);
      await settleImages(tester);
      expect(find.byKey(const ValueKey('app-bar-icon')), findsOneWidget);
      await captureScreenshot(tester, 'm52_first_start_$name', settle: false);

      await tester.tap(find.text('Choose folder'));
      await pumpUntil(tester, find.text('Knight Pack'));
      await settleImages(tester);
      await captureScreenshot(tester, 'm49_app_bar_$name', settle: false);

      // Settings → About.
      await tester.tap(find.byTooltip('Settings (Ctrl+,)'));
      await pumpUntil(tester, find.byType(SettingsScreen));
      await tester.pump(const Duration(milliseconds: 500));
      final list = find
          .descendant(
            of: find.byType(SettingsScreen),
            matching: find.byType(Scrollable),
          )
          .first;
      await tester.scrollUntilVisible(
        find.text(appVersionLabel),
        300,
        scrollable: list,
      );
      await tester.pump(const Duration(milliseconds: 300));
      expectLockup(tester);
      await settleImages(tester);
      await captureScreenshot(tester, 'm52_about_$name', settle: false);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await pumpUntil(tester, find.byType(SettingsScreen), gone: true);

      // Help: the logo at the top.
      await tester.tap(find.byTooltip('How Loot Silo works (F1)'));
      await pumpUntil(tester, logo);
      expectLockup(tester);
      await settleImages(tester);
      await captureScreenshot(tester, 'm52_help_$name', settle: false);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await pumpUntil(tester, logo, gone: true);
      File(p.join(tmp.path, 'settings.json')).deleteSync();
      // A new app, not the old one's providers.
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    }
  });

  testWidgets('m50: slider width, end icons, viewer 1:1, About links', (
    tester,
  ) async {
    copyTree('test/fixtures/managed', lib);
    final pack = p.join(lib, 'HeroMaker', 'Knight Pack');
    final coin = img.Image(width: 16, height: 16, numChannels: 4);
    img.fillCircle(
      coin,
      x: 8,
      y: 8,
      radius: 6,
      color: img.ColorRgba8(240, 190, 40, 255),
    );
    Directory(p.join(pack, 'items')).createSync();
    File(p.join(pack, 'items', 'coin.png'))
        .writeAsBytesSync(img.encodePng(coin));

    await tester.pumpWidget(app(lib));
    await pumpUntil(tester, find.text('Knight Pack'));
    await tester.pump(const Duration(milliseconds: 500));
    // The size slider is as wide as the app bar's icons, under them.
    final icons = tester.getRect(
      find
          .ancestor(
            of: find.byTooltip('itch.io'),
            matching: find.byType(MeasureSize),
          )
          .first,
    );
    final slider = find.byKey(const ValueKey('dashboard-size-slider'));
    expect(tester.getRect(slider).width, icons.width);
    expect(tester.getRect(slider).right, icons.right);
    await tester.tap(
      find.descendant(of: slider, matching: find.byTooltip('Larger')),
    );
    await tester.pump(const Duration(milliseconds: 300));
    final container = ProviderScope.containerOf(
      tester.element(find.byType(Dashboard)),
    );
    // M79: one stop up, saved as the cards' real width.
    final tile = tester.getSize(find.byType(PackTile).first).width;
    expect(tile, greaterThan(240));
    expect(
      container.read(settingsProvider).dashboardTileSize,
      closeTo(tile, 1e-6),
    );
    await settleImages(tester);
    await captureScreenshot(tester, 'm50_dashboard_top_row', settle: false);

    // Detail: the search box's corners match the ★ chip's.
    await tester.tap(find.text('Knight Pack'));
    await pumpUntil(tester, find.textContaining('Images ('));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.textContaining('Images ('));
    await tester.pump(const Duration(milliseconds: 500));
    await pumpUntil(tester, find.byKey(const ValueKey('image:items/coin.png')));
    await settleImages(tester);
    await captureScreenshot(tester, 'm50_detail_toolbar', settle: false);

    // A 16 px coin opens at 1:1, not blown up to the window.
    await openImageCard(tester, 'items/coin.png');
    await pumpUntil(tester, find.byType(ImageViewer));
    await settleImages(tester);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('1×'), findsOneWidget);
    expect(
      tester
          .getRect(
            find.descendant(
              of: find.byType(ImageViewer),
              matching: find.byType(RawImage),
            ),
          )
          .width,
      closeTo(16, 0.5),
    );
    await captureScreenshot(tester, 'm50_viewer_small', settle: false);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await pumpUntil(tester, find.byType(ImageViewer), gone: true);

    // Settings → About (Ctrl+, works from the pack page): the two links.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.comma);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await pumpUntil(tester, find.byType(SettingsScreen));
    await tester.pump(const Duration(milliseconds: 500));
    final list = find
        .descendant(
          of: find.byType(SettingsScreen),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('link:itch.io')),
      300,
      scrollable: list,
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('link:GitHub')), findsOneWidget);
    await settleImages(tester);
    await captureScreenshot(tester, 'm50_about', settle: false);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await pumpUntil(tester, find.byType(SettingsScreen), gone: true);
  });

  testWidgets('m51: dashboard in three colours, light and dark; restart', (
    tester,
  ) async {
    copyTree('test/fixtures/managed', lib);
    final settingsFile = File(p.join(tmp.path, 'settings.json'));
    for (final color in [
      ThemeColor.teal,
      ThemeColor.purple,
      ThemeColor.orange,
    ]) {
      for (final theme in [ThemeChoice.light, ThemeChoice.dark]) {
        SettingsStore(
          settingsFile,
        ).save(AppSettings(libraryPath: lib, theme: theme, themeColor: color));
        await tester.pumpWidget(app(lib, restart: true));
        await pumpUntil(tester, find.text('Knight Pack'));
        await tester.pump(const Duration(milliseconds: 500));
        // A selected type chip and the slider show the colour.
        await tester.tap(find.widgetWithText(FilterChip, 'character'));
        await tester.pump(const Duration(milliseconds: 500));
        final scheme = Theme.of(tester.element(find.byType(Dashboard)))
            .colorScheme;
        expect(
          scheme.primary,
          ColorScheme.fromSeed(
            seedColor: color.seed,
            brightness: theme == ThemeChoice.dark
                ? Brightness.dark
                : Brightness.light,
          ).primary,
        );
        await settleImages(tester);
        await captureScreenshot(
          tester,
          'm51_dashboard_${color.name}_${theme.name}',
          settle: false,
        );
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
      }
    }

    // Pick a colour in Settings → Appearance; it survives a restart.
    SettingsStore(settingsFile).save(AppSettings(libraryPath: lib));
    await tester.pumpWidget(app(lib, restart: true));
    await pumpUntil(tester, find.text('Knight Pack'));
    await tester.tap(find.byTooltip('Settings (Ctrl+,)'));
    await pumpUntil(tester, find.byType(SettingsScreen));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.byKey(const ValueKey('theme-color:indigo')));
    await tester.pump(const Duration(milliseconds: 500));
    await captureScreenshot(tester, 'm51_appearance', settle: false);
    expect(SettingsStore(settingsFile).load().themeColor, ThemeColor.indigo);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    await tester.pumpWidget(app(lib, restart: true));
    await pumpUntil(tester, find.text('Knight Pack'));
    // Theme "system": whatever brightness the system gives.
    final restarted = Theme.of(tester.element(find.byType(Dashboard)));
    expect(
      restarted.colorScheme.primary,
      ColorScheme.fromSeed(
        seedColor: Colors.indigo,
        brightness: restarted.brightness,
      ).primary,
    );
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('m39: toolbars, Loop, slim bar, Settings (real, read-only)', (
    tester,
  ) async {
    final real = p.canonicalize('../assets_library');
    if (!Directory(real).existsSync()) return;
    final before = Directory(real).statSync().modified;
    await tester.pumpWidget(app(real, library: real));
    await pumpUntil(tester, realPacks());
    await settleImages(tester);
    await captureScreenshot(tester, 'm39_dashboard_slider', settle: false);

    // Audio toolbar: Play all and Loop, one shape.
    await tester.enterText(find.byType(TextField).first, '16-BIT Achievements');
    await tester.pump(DashboardQueryNotifier.searchDebounce);
    await pumpUntil(tester, find.text('16-BIT Achievements SFX Pack 1'));
    await tester.tap(find.text('16-BIT Achievements SFX Pack 1'));
    final loop = find.byKey(const ValueKey('loop'));
    await pumpUntil(tester, loop);
    await tester.pump(const Duration(milliseconds: 500));
    final play = find.byKey(const ValueKey('play-all'));
    expect(tester.getSize(loop).height, tester.getSize(play).height);
    // The search box and the Favorites chip: one height.
    final search = find.widgetWithText(TextField, 'Search files');
    final chip = find.byKey(const ValueKey('detail-favorites-chip'));
    expect(tester.getSize(search).height, tester.getSize(chip).height);
    await captureScreenshot(tester, 'm39_audio_toolbar', settle: false);

    // A sprite pack: the detail toolbar, then the slim bar.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await pumpUntil(tester, find.byType(PackDetailScreen), gone: true);
    await tester.pump(const Duration(milliseconds: 500));
    final dashSearch = find.widgetWithText(TextField, '16-BIT Achievements');
    await tester.tap(dashSearch);
    await tester.pump();
    await tester.enterText(dashSearch, 'Epic RPG World');
    await tester.pump(const Duration(milliseconds: 300));
    const village = 'Epic RPG World - The Village V2.2';
    final tile = find.descendant(
      of: find.byType(PackTile),
      matching: find.text(village),
    );
    await pumpUntil(tester, tile);
    await tester.tap(tile);
    await pumpUntil(tester, find.textContaining('Animations ('));
    await tester.pump(const Duration(milliseconds: 500));
    await settleImages(tester);
    await captureScreenshot(tester, 'm39_detail_toolbar', settle: false);
    await tester.tap(find.byTooltip('Unpin header — show it on hover (H)'));
    await tester.pump(const Duration(milliseconds: 300));
    final icons = tester.getRect(find.byKey(const ValueKey('header-actions')));
    final bar = tester.getRect(
      find
          .ancestor(
            of: find.text('Hover for details'),
            matching: find.byType(Container),
          )
          .first,
    );
    expect(icons.right, closeTo(bar.right - 8, 0.5));
    await settleImages(tester);
    await captureScreenshot(tester, 'm39_slim_bar', settle: false);

    // Settings: Help right above About.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await pumpUntil(tester, find.byType(PackDetailScreen), gone: true);
    await tester.tap(find.byTooltip('Settings (Ctrl+,)'));
    await pumpUntil(tester, find.text('Appearance'));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.scrollUntilVisible(
      find.text('About'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      tester.getTopLeft(find.text('Help')).dy,
      lessThan(tester.getTopLeft(find.text('About')).dy),
    );
    await captureScreenshot(tester, 'm39_settings_help', settle: false);
    expect(Directory(real).statSync().modified, before);
  });

  testWidgets('m40: image cards — focus mode and hover icons (real)', (
    tester,
  ) async {
    final real = p.canonicalize('../assets_library');
    if (!Directory(real).existsSync()) return;
    final before = Directory(real).statSync().modified;
    await tester.pumpWidget(app(real, library: real));
    await pumpUntil(tester, realPacks());
    await tester.enterText(find.byType(TextField).first, 'Epic RPG World');
    await tester.pump(DashboardQueryNotifier.searchDebounce);
    const village = 'Epic RPG World - The Village V2.2';
    final tile = find.descendant(
      of: find.byType(PackTile),
      matching: find.text(village),
    );
    await pumpUntil(tester, tile);
    await tester.tap(tile);
    await pumpUntil(tester, find.textContaining('Images ('));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.textContaining('Images ('));
    await tester.pump(const Duration(milliseconds: 500));
    final cards = find.byType(ItemCard);
    await pumpUntil(tester, cards);
    await settleImages(tester);

    // Hover icons on the second card.
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: tester.getCenter(cards.at(1)));
    addTearDown(mouse.removePointer);
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      find.descendant(of: cards.at(1), matching: find.byTooltip('Open image')),
      findsOneWidget,
    );
    await settleImages(tester);
    await captureScreenshot(tester, 'm40_hover_icons', settle: false);

    // A click focuses the third card; the others dim.
    await tester.tap(cards.at(2));
    await mouse.moveTo(const Offset(1430, 890));
    await tester.pump(const Duration(milliseconds: 400));
    final third = tester.widget<ItemCard>(cards.at(2));
    expect(third.focused, isTrue);
    expect(tester.widget<ItemCard>(cards.at(0)).dimmed, isTrue);
    await settleImages(tester);
    await captureScreenshot(tester, 'm40_focused_card', settle: false);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.widget<ItemCard>(cards.at(3)).focused, isTrue);
    // Esc leaves focus mode; the page stays.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.widget<ItemCard>(cards.at(3)).focused, isFalse);
    expect(find.byType(PackDetailScreen), findsOneWidget);
    expect(Directory(real).statSync().modified, before);
  });

  testWidgets('m41: select in By folder, combine, rename, Save (temp copy)', (
    tester,
  ) async {
    const explosion =
        '../assets_library/Kenney/Kenney Game Assets 1 version 42/2D assets/'
        'Smoke Particles/PNG/Explosion';
    if (!Directory(explosion).existsSync()) return;
    copyTree('test/fixtures/managed', lib);
    final pack = p.join(lib, 'HeroMaker', 'Knight Pack');
    copyTree(explosion, p.join(pack, 'fx', 'Explosion'));
    await tester.pumpWidget(app(lib));
    await pumpUntil(tester, find.text('Knight Pack'));
    await tester.tap(find.text('Knight Pack'));
    await pumpUntil(tester, find.textContaining('Images ('));
    await tester.tap(find.textContaining('Images ('));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('By folder'));
    await tester.pump(const Duration(milliseconds: 500));
    final scrollable = find
        .descendant(
          of: find.byType(CustomScrollView),
          matching: find.byType(Scrollable),
        )
        .first;
    Future<void> clickWith(LogicalKeyboardKey key, String name) async {
      final card = find.byKey(ValueKey('image:fx/Explosion/$name'));
      await tester.scrollUntilVisible(card, 300, scrollable: scrollable);
      await tester.ensureVisible(card);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.sendKeyDownEvent(key);
      await tester.tap(card);
      await tester.sendKeyUpEvent(key);
      await tester.pump(const Duration(milliseconds: 300));
    }

    // Ctrl on the first frame, Shift on the fourth: four selected.
    await clickWith(LogicalKeyboardKey.controlLeft, 'explosion00.png');
    await clickWith(LogicalKeyboardKey.shiftLeft, 'explosion03.png');
    expect(find.text('4 selected'), findsOneWidget);
    await settleImages(tester);
    await captureScreenshot(tester, 'm41_by_folder_selection', settle: false);

    await tester.tap(find.text('Combine 4 images into animation'));
    await pumpUntil(tester, find.text('Apply size'));
    final name = find.byKey(const ValueKey('combine-name'));
    expect(
      tester.widget<TextField>(name).controller!.text,
      'Explosion_animation',
    );
    await tester.enterText(name, 'boom');
    await tester.pump(const Duration(milliseconds: 300));
    await settleImages(tester);
    await captureScreenshot(tester, 'm41_named_strip', settle: false);
    await tester.tap(find.text('Save'));
    await pumpUntil(tester, find.text('Back to image'));
    expect(
      File(p.join(pack, 'fx', 'Explosion', 'boom.png')).existsSync(),
      isTrue,
    );
    expect(
      File(p.join(pack, 'fx', 'Explosion', 'Explosion_animation.png'))
          .existsSync(),
      isFalse,
    );
    await tester.tap(find.text('Close'));
    await pumpUntil(tester, find.textContaining('Animations (1)'));
  });

  testWidgets('m26: saved rows in the editor (real, unsaved)', (tester) async {
    final real = p.canonicalize('../assets_library');
    if (!Directory(real).existsSync()) return;
    final vfx = File(
      p.join(real, 'ashishlko11', 'Special Effects Vol.03', 'asset_pack.json'),
    );
    if (!vfx.existsSync()) return;
    final vfxBefore = vfx.readAsStringSync();
    await tester.pumpWidget(app(real, library: real));
    await pumpUntil(tester, realPacks());

    // One mouse for the whole test; card icons need a hover.
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);

    /// Opens [title]'s Animations tab and the editor of the card whose
    /// name matches [card].
    Future<void> openEditor(String search, String title, Pattern card) async {
      await tester.enterText(find.byType(TextField).first, search);
      await tester.pump(DashboardQueryNotifier.searchDebounce);
      await pumpUntil(tester, find.text(title));
      await tester.tap(find.text(title));
      final tab = find.descendant(
        of: find.byType(TabBar),
        matching: find.textContaining('Animations ('),
      );
      await pumpUntil(tester, tab);
      // The old page may still be fading out; let the route settle.
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(tab.last);
      await tester.pump(const Duration(milliseconds: 500));
      // Names show on the card title and in tooltips; the card title is
      // the one inside a Card.
      final name = find.descendant(
        of: find.byType(Card),
        matching: find.textContaining(card),
      );
      for (var i = 0; i < 40 && name.evaluate().isEmpty; i++) {
        await tester.drag(find.byType(Scrollable).last, const Offset(0, -300));
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.ensureVisible(name.first);
      await tester.pump(const Duration(milliseconds: 300));
      final edit = find.descendant(
        of: find.ancestor(of: name.first, matching: find.byType(Card)).first,
        matching: find.byIcon(Icons.tune),
      );
      await mouse.moveTo(tester.getCenter(edit));
      await tester.pump();
      await tester.tap(edit);
      await pumpUntil(tester, find.text('Apply size'));
      await settleImages(tester);
    }

    // The frame-count grid search (islands 16 → 4×4) is covered by unit
    // tests: the real islands image is no animation without a saved edit.
    // Special Effects Vol.03: All rows is the default (M34); one row makes
    // the dialog savable.
    await openEditor(
      'Special Effects Vol',
      'Special Effects Vol.03',
      RegExp(r'^1$'),
    );
    FilledButton save() =>
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Save'));
    expect(save().onPressed, isNull);
    await tester.tap(find.text('All rows'));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('Row 1').last);
    await tester.pump(const Duration(milliseconds: 500));
    expect(save().onPressed, isNotNull);
    expect(find.text('Not an animation'), findsOneWidget);
    await settleImages(tester);
    await captureScreenshot(tester, 'm26_one_row', settle: false);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump(const Duration(milliseconds: 500));

    expect(vfx.readAsStringSync(), vfxBefore);
  });

  testWidgets('m27: trimmed animation cards on padded packs (real)', (
    tester,
  ) async {
    final real = p.canonicalize('../assets_library');
    if (!Directory(real).existsSync()) return;
    final before = Directory(real).statSync().modified;
    await tester.pumpWidget(app(real, library: real));
    await pumpUntil(tester, realPacks());
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    for (final (search, title, shot) in const [
      (
        'Tiny RPG',
        'Tiny RPG Character Asset Pack 01 v2.0 -Full 22 Characters',
        'tiny_rpg',
      ),
      ('Pixel Banner', 'Pixel-Banner', 'pixel_banner'),
      ('Grass Land 2.0', 'ERW - Grass Land 2.0 v2.1', 'grass_land'),
      (
        'CharactersAnimationsAssetPack',
        'CharactersAnimationsAssetPack',
        'characters',
      ),
    ]) {
      await tester.tap(find.byType(TextField).first);
      await tester.pump();
      await tester.enterText(find.byType(TextField).first, search);
      await tester.pump(DashboardQueryNotifier.searchDebounce);
      await tester.pump(const Duration(milliseconds: 300));
      // The search box can hold the same text; tap the tile.
      final tile = find.descendant(
        of: find.byType(PackTile),
        matching: find.text(title),
      );
      await pumpUntil(tester, tile);
      await tester.tap(tile.first);
      final tab = find.descendant(
        of: find.byType(TabBar),
        matching: find.textContaining('Animations ('),
      );
      await pumpUntil(tester, tab);
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(tab.last);
      await tester.pump(const Duration(milliseconds: 500));
      await settleImages(tester);
      await captureScreenshot(tester, 'm27_${shot}_$m27Phase', settle: false);
      if (shot == 'tiny_rpg' && m27Phase == 'after') {
        // Zoom 2× in the editor (not saved).
        final edit = find.byIcon(Icons.tune).first;
        // The header can push the first row's buttons below the window;
        // hover the (hidden) button itself.
        await tester.ensureVisible(edit);
        await tester.pump(const Duration(milliseconds: 300));
        await mouse.moveTo(tester.getCenter(edit));
        // The card icons fade in on hover.
        await tester.pump(const Duration(milliseconds: 300));
        await tester.tap(edit);
        await pumpUntil(tester, find.text('Apply size'));
        // M35: the −/+/reset overlay on the preview replaced the dropdown.
        await mouse.moveTo(tester.getCenter(find.byType(ZoomPreview)));
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('zoom-reset')));
        await tester.pump();
        while (tester
                .widget<Text>(find.byKey(const ValueKey('zoom-value')))
                .data !=
            '2×') {
          final value = tester
              .widget<Text>(find.byKey(const ValueKey('zoom-value')))
              .data!;
          final n = value == 'Auto' ? 3 : int.parse(value.replaceAll('×', ''));
          await tester.tap(
            find.byKey(ValueKey(n > 2 ? 'zoom-out' : 'zoom-in')),
          );
          await tester.pump();
        }
        await tester.pump(const Duration(milliseconds: 500));
        await settleImages(tester);
        await captureScreenshot(tester, 'm27_zoom_2x', settle: false);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pump(const Duration(milliseconds: 500));
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await pumpUntil(tester, find.text('Clear'));
      await tester.tap(find.text('Clear'));
      await pumpUntil(tester, realPacks());
    }
    expect(Directory(real).statSync().modified, before);
  });

  testWidgets('m28: combine a real frame folder (temp copy)', (tester) async {
    const explosion =
        '../assets_library/Kenney/Kenney Game Assets 1 version 42/2D assets/'
        'Smoke Particles/PNG/Explosion';
    if (!Directory(explosion).existsSync()) return;
    copyTree('test/fixtures/managed', lib);
    final pack = p.join(lib, 'HeroMaker', 'Knight Pack');
    copyTree(explosion, p.join(pack, 'fx', 'Explosion'));
    await tester.pumpWidget(app(lib));
    await pumpUntil(tester, find.text('Knight Pack'));
    await tester.tap(find.text('Knight Pack'));
    await pumpUntil(tester, find.textContaining('Images ('));
    await tester.tap(find.textContaining('Images ('));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('By folder'));
    await tester.pump(const Duration(milliseconds: 500));
    final combine = find.text('Combine into animation');
    // Taller cards (M40) can put the folder below the built area.
    await tester.scrollUntilVisible(
      combine,
      300,
      scrollable: find
          .descendant(
            of: find.byType(CustomScrollView),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.ensureVisible(combine);
    await tester.pump(const Duration(milliseconds: 300));
    await settleImages(tester);
    await captureScreenshot(tester, 'm28_folder_header', settle: false);

    await tester.tap(combine);
    // M41: straight to the preview; Save writes.
    await pumpUntil(tester, find.text('Apply size'));
    await settleImages(tester);
    await captureScreenshot(tester, 'm28_combined_editor', settle: false);
    // The frames differ in size; the strip uses the largest.
    expect(find.text('Sheet · 634×636 frames · 9 × 1 · 9 frames'), findsOne);
    final out = File(
      p.join(pack, 'fx', 'Explosion', 'Explosion_animation.png'),
    );
    expect(out.existsSync(), isFalse);
    await tester.tap(find.text('Save'));
    await pumpUntil(tester, find.text('Back to image'));
    expect(out.existsSync(), isTrue);
    // The frame files stay.
    expect(
      File(p.join(pack, 'fx', 'Explosion', 'explosion00.png')).existsSync(),
      isTrue,
    );
    await tester.tap(find.text('Close'));
    await tester.pump(const Duration(milliseconds: 500));

    // Flat view: select two frames with Ctrl-click.
    await tester.tap(find.text('Flat'));
    await tester.pump(const Duration(milliseconds: 500));
    for (final name in ['explosion00.png', 'explosion01.png']) {
      final card = find.byKey(ValueKey('image:fx/Explosion/$name'));
      await tester.scrollUntilVisible(
        card,
        300,
        scrollable: find
            .descendant(
              of: find.byType(CustomScrollView),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.ensureVisible(card);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.tap(card);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
    }
    expect(find.text('Combine 2 images into animation'), findsOneWidget);
    await settleImages(tester);
    await captureScreenshot(tester, 'm28_selection_bar', settle: false);
  });

  testWidgets('m35: combine Pixel explosion — preview, Save', (tester) async {
    const pixel =
        '../assets_library/Kenney/Kenney Game Assets 1 version 42/2D assets/'
        'Explosion Pack/PNG/Pixel explosion';
    if (!Directory(pixel).existsSync()) return;
    copyTree('test/fixtures/managed', lib);
    final pack = p.join(lib, 'HeroMaker', 'Knight Pack');
    final folder = p.join(pack, 'fx', 'Pixel explosion');
    copyTree(pixel, folder);
    final out = File(p.join(folder, 'Pixel explosion_animation.png'));
    List<String> files() =>
        Directory(pack).listSync(recursive: true).map((e) => e.path).toList()
          ..sort();
    final before = files();
    await tester.pumpWidget(app(lib));
    await pumpUntil(tester, find.text('Knight Pack'));
    await tester.tap(find.text('Knight Pack'));
    await pumpUntil(tester, find.textContaining('Images ('));
    await tester.tap(find.textContaining('Images ('));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('By folder'));
    await tester.pump(const Duration(milliseconds: 500));
    final combine = find.text('Combine into animation');
    // Taller cards (M40) can put the folder below the built area.
    await tester.scrollUntilVisible(
      combine,
      300,
      scrollable: find
          .descendant(
            of: find.byType(CustomScrollView),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.ensureVisible(combine);
    await tester.pump(const Duration(milliseconds: 300));
    await settleImages(tester);
    await captureScreenshot(tester, 'm35_folder_header', settle: false);

    // No confirmation since M41: the preview opens directly.
    await tester.tap(combine);
    await pumpUntil(tester, find.text('Apply size'));
    expect(find.byKey(const ValueKey('combine-confirm')), findsNothing);
    expect(find.text('Sheet · 96×91 frames · 9 × 1 · 9 frames'), findsOne);
    await tester.pump(const Duration(milliseconds: 500));
    await settleImages(tester);
    // The strip plays before anything is written.
    await captureScreenshot(tester, 'm35_combine_preview', settle: false);
    expect(files(), before);

    // Esc: nothing written.
    expect(await tester.sendKeyEvent(LogicalKeyboardKey.escape), isTrue);
    await pumpUntil(tester, find.text('Apply size'), gone: true, seconds: 10);
    expect(files(), before);

    // Again, zoom with the wheel, then Save.
    await tester.tap(combine);
    await pumpUntil(tester, find.text('Apply size'));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(
      location: tester.getCenter(find.byType(ZoomPreview)),
    );
    addTearDown(mouse.removePointer);
    await tester.pump();
    final pointer = TestPointer(9, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(
      pointer.hover(tester.getCenter(find.byType(ZoomPreview))),
    );
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, -20)));
    await tester.pump(const Duration(milliseconds: 300));
    await settleImages(tester);
    await captureScreenshot(tester, 'm35_preview_zoom', settle: false);
    final zoom = tester
        .widget<Text>(find.byKey(const ValueKey('zoom-value')))
        .data!;
    expect(zoom, isNot('Auto'));
    await tester.tap(find.text('Save'));
    await pumpUntil(tester, find.text('Back to image'));
    expect(out.existsSync(), isTrue);
    final sidecar = File(p.join(pack, 'asset_pack.json')).readAsStringSync();
    expect(sidecar, contains('"manual": true'));
    expect(sidecar, contains('"zoom": ${zoom.replaceAll('×', '')}'));
    await tester.tap(find.text('Close'));
    await pumpUntil(tester, find.textContaining('Animations ('));
    await tester.pump(const Duration(milliseconds: 500));
  });

  testWidgets('m42: previews grid at two column counts (real, read-only)', (
    tester,
  ) async {
    final real = p.canonicalize('../assets_library');
    if (!Directory(real).existsSync()) return;
    const title = 'Epic RPG World - Village(interiors) V1.3';
    if (!Directory(p.join(real, 'RafaelMatos', title)).existsSync()) return;
    final before = Directory(real).statSync().modified;
    await tester.pumpWidget(app(real, library: real));
    await pumpUntil(tester, realPacks());
    await tester.enterText(find.byType(TextField).first, 'Village(interiors)');
    await tester.pump(DashboardQueryNotifier.searchDebounce);
    final tile = find.descendant(
      of: find.byType(PackTile),
      matching: find.text(title),
    );
    await pumpUntil(tester, tile);
    await tester.tap(tile.first);
    final box = find.byKey(const ValueKey('header-preview'));
    await pumpUntil(tester, box);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: tester.getCenter(box));
    addTearDown(mouse.removePointer);
    await tester.pump();
    await tester.tap(
      find.byWidgetPredicate(
        (w) => w is Tooltip && (w.message ?? '').startsWith('All previews'),
      ),
    );
    await pumpUntil(tester, find.byType(PreviewGridDialog));
    await mouse.moveTo(const Offset(5, 5));
    await settleImages(tester);
    await captureScreenshot(tester, 'm42_previews_default', settle: false);

    // Two columns: bigger cards, still filling the width.
    final less = find.byTooltip('Fewer columns (Ctrl + wheel up)');
    await tester.tap(less);
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(less);
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('previews-columns'))).data,
      '2',
    );
    await settleImages(tester);
    await captureScreenshot(tester, 'm42_previews_two', settle: false);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await pumpUntil(tester, find.byType(PreviewGridDialog), gone: true);
    expect(Directory(real).statSync().modified, before);
    // The header's animated preview schedules its next GIF frame; unmount
    // and let pending decodes land so none outlives the test.
    await tester.pumpWidget(const SizedBox());
    await settleImages(tester);
    await tester.pump();
  });

  testWidgets('m29: header previews and viewer zoom (real, read-only)', (
    tester,
  ) async {
    final real = p.canonicalize('../assets_library');
    if (!Directory(real).existsSync()) return;
    const title = 'Epic RPG World - Village(interiors) V1.3';
    if (!Directory(p.join(real, 'RafaelMatos', title)).existsSync()) return;
    final before = Directory(real).statSync().modified;
    await tester.pumpWidget(app(real, library: real));
    await pumpUntil(tester, realPacks());
    await tester.tap(find.byType(TextField));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'Village(interiors)');
    await tester.pump(DashboardQueryNotifier.searchDebounce);
    final tile = find.descendant(
      of: find.byType(PackTile),
      matching: find.text(title),
    );
    await pumpUntil(tester, tile);
    await tester.tap(tile.first);
    final box = find.byKey(const ValueKey('header-preview'));
    await pumpUntil(tester, box);
    await settleImages(tester);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: tester.getCenter(box));
    addTearDown(mouse.removePointer);
    await tester.pump();
    await captureScreenshot(tester, 'm29_header', settle: false);

    // All previews: the 8 mockups (plus the preview, if it is another).
    final grid = find.byWidgetPredicate(
      (w) => w is Tooltip && (w.message ?? '').startsWith('All previews'),
    );
    expect(grid, findsOneWidget);
    await tester.tap(grid);
    await pumpUntil(tester, find.byType(PreviewGridDialog));
    await settleImages(tester);
    await captureScreenshot(tester, 'm29_previews_grid', settle: false);
    final mockup = find.descendant(
      of: find.byType(PreviewGridDialog),
      matching: find.text('mockup2.png'),
    );
    await tester.tap(mockup);
    await pumpUntil(tester, find.byType(ImageViewer));
    await settleImages(tester);
    await captureScreenshot(tester, 'm29_viewer_fit', settle: false);
    await tester.tap(find.text('1:1'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('1×'), findsOneWidget);
    await settleImages(tester);
    await captureScreenshot(tester, 'm29_viewer_1to1', settle: false);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump(const Duration(milliseconds: 300));
    // mockup2.png is this pack's preview, so it comes first.
    expect(find.textContaining('mockups/mockup1'), findsOneWidget);
    expect(Directory(real).statSync().modified, before);
  });

  testWidgets('m30: detail search and author link (real, read-only)', (
    tester,
  ) async {
    final real = p.canonicalize('../assets_library');
    if (!Directory(real).existsSync()) return;
    const title = 'Epic RPG World - Village(interiors) V1.3';
    if (!Directory(p.join(real, 'RafaelMatos', title)).existsSync()) return;
    final before = Directory(real).statSync().modified;
    await tester.pumpWidget(app(real, library: real));
    await pumpUntil(tester, realPacks());
    await tester.tap(find.byType(TextField));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'Village(interiors)');
    await tester.pump(DashboardQueryNotifier.searchDebounce);
    final tile = find.descendant(
      of: find.byType(PackTile),
      matching: find.text(title),
    );
    await pumpUntil(tester, tile);
    await tester.tap(tile.first);
    await pumpUntil(tester, find.byType(TabBar));
    await tester.pump(const Duration(seconds: 1));
    // Opened from a pack search (not a file search): no file filter yet.
    final field = find.widgetWithText(TextField, 'Search files');
    expect(field, findsOneWidget);
    expect(find.textContaining('Matching'), findsNothing);
    final images = find.textContaining('Images (');
    final all = (tester
        .widget<Tab>(find.ancestor(of: images, matching: find.byType(Tab)))
        .text)!;

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    await tester.enterText(field, 'barrel');
    await pumpUntil(tester, find.text('Matching “barrel”'));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(images);
    await tester.pump(const Duration(seconds: 1));
    final filtered = (tester
        .widget<Tab>(find.ancestor(of: images, matching: find.byType(Tab)))
        .text)!;
    expect(filtered, isNot(all));
    await settleImages(tester);
    await captureScreenshot(tester, 'm30_detail_search', settle: false);

    // The author's pack count leads to the dashboard filtered by author.
    final link = find.byKey(const ValueKey('author-packs'));
    expect(link, findsOneWidget);
    final label = tester
        .widget<Text>(find.descendant(of: link, matching: find.byType(Text)))
        .data!;
    final n = int.parse(label.split(' ').first);
    await tester.tap(link);
    await pumpUntil(tester, find.byType(Dashboard));
    await tester.pump(const Duration(seconds: 1));
    // The result count says the same number of packs.
    expect(find.text(label), findsOneWidget);
    expect(n, greaterThan(1));
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      isEmpty,
    );
    await settleImages(tester);
    await captureScreenshot(tester, 'm30_author_filter', settle: false);
    expect(Directory(real).statSync().modified, before);
  });

  testWidgets('m31: two pack tabs side by side (real, read-only)', (
    tester,
  ) async {
    final real = p.canonicalize('../assets_library');
    if (!Directory(real).existsSync()) return;
    final before = Directory(real).statSync().modified;
    await tester.pumpWidget(app(real, library: real));
    await pumpUntil(tester, realPacks());
    await tester.enterText(find.byType(TextField).first, 'Epic RPG World');
    await tester.pump(DashboardQueryNotifier.searchDebounce);
    const village = 'Epic RPG World - The Village V2.2';
    const volcano = 'Epic RPG World - Volcano V1.6.1';
    Finder tile(String t) =>
        find.descendant(of: find.byType(PackTile), matching: find.text(t));
    await pumpUntil(tester, tile(volcano));
    for (final t in [village, volcano]) {
      final g = await tester.startGesture(
        tester.getCenter(tile(t)),
        kind: PointerDeviceKind.mouse,
        buttons: kMiddleMouseButton,
      );
      await g.up();
      await tester.pump(const Duration(milliseconds: 300));
    }
    final strip = find.byType(PackTabStrip);
    expect(strip, findsOneWidget);
    expect(
      find.descendant(of: strip, matching: find.text(volcano)),
      findsOneWidget,
    );
    await settleImages(tester);
    await captureScreenshot(tester, 'm31_dashboard_tabs', settle: false);

    // Ctrl+Tab to the first pack, then its neighbour.
    Future<void> ctrlTab() async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump(const Duration(milliseconds: 500));
    }

    await ctrlTab();
    await pumpUntil(tester, find.byType(TabBar));
    await settleImages(tester);
    await captureScreenshot(tester, 'm31_village_tab', settle: false);
    await ctrlTab();
    await pumpUntil(tester, find.text(volcano));
    await tester.pump(const Duration(seconds: 1));
    await settleImages(tester);
    await captureScreenshot(tester, 'm31_volcano_tab', settle: false);
    expect(Directory(real).statSync().modified, before);
  });

  testWidgets('m36: detail layout with and without tabs (real, read-only)', (
    tester,
  ) async {
    final real = p.canonicalize('../assets_library');
    if (!Directory(real).existsSync()) return;
    final before = Directory(real).statSync().modified;
    await tester.pumpWidget(app(real, library: real));
    await pumpUntil(tester, realPacks());
    await tester.enterText(find.byType(TextField).first, 'Epic RPG World');
    await tester.pump(DashboardQueryNotifier.searchDebounce);
    const village = 'Epic RPG World - The Village V2.2';
    const volcano = 'Epic RPG World - Volcano V1.6.1';
    Finder tile(String t) =>
        find.descendant(of: find.byType(PackTile), matching: find.text(t));
    final detail = find.byType(PackDetailScreen);
    await pumpUntil(tester, tile(volcano));

    // No tabs: the bar with the back arrow.
    await tester.tap(tile(village));
    await pumpUntil(tester, find.textContaining('Animations ('));
    await tester.pump(const Duration(milliseconds: 500));
    expect(
      find.descendant(of: detail, matching: find.byType(BackButton)),
      findsOneWidget,
    );
    await settleImages(tester);
    await captureScreenshot(tester, 'm36_no_tabs', settle: false);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await pumpUntil(tester, detail, gone: true);

    // A tab open; a plain click opens Village inside the Dashboard tab.
    final g = await tester.startGesture(
      tester.getCenter(tile(volcano)),
      kind: PointerDeviceKind.mouse,
      buttons: kMiddleMouseButton,
    );
    await g.up();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(tile(village));
    await pumpUntil(tester, find.textContaining('Animations (').hitTestable());
    await tester.pump(const Duration(milliseconds: 500));
    final shown = detail.hitTestable();
    expect(
      find.descendant(of: shown.first, matching: find.byType(AppBar)),
      findsNothing,
    );
    await settleImages(tester);
    await captureScreenshot(
      tester,
      'm36_tabs_pack_in_dashboard',
      settle: false,
    );

    // Unpinned: the slim bar with the icons; resting on it opens the header.
    final unpin = find
        .byTooltip('Unpin header — show it on hover (H)')
        .hitTestable();
    await tester.tap(unpin);
    await tester.pump(const Duration(milliseconds: 300));
    // The middle-click's mouse is still there; it hovers from now on.
    final mouse = g;
    await mouse.moveTo(const Offset(640, 700));
    await tester.pump();
    await captureScreenshot(tester, 'm36_slim_bar', settle: false);
    await mouse.moveTo(
      tester.getCenter(find.text('Hover for details').hitTestable()),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Used in').hitTestable(), findsNothing);
    await tester.pump(headerHoverDelay);
    await pumpUntil(tester, find.text('Used in').hitTestable());
    await settleImages(tester);
    await captureScreenshot(tester, 'm36_slim_hover', settle: false);
    // Pin it again from the floating header's corner.
    await tester.tap(find.byTooltip('Pin header (H)').hitTestable().first);
    await tester.pump(const Duration(milliseconds: 300));
    await mouse.moveTo(const Offset(640, 700));

    // The Dashboard tab goes back to the dashboard.
    await tester.tap(
      find
          .descendant(
            of: find.byType(PackTabStrip),
            matching: find.text('Dashboard'),
          )
          .hitTestable()
          .first,
    );
    await pumpUntil(tester, tile(volcano).hitTestable());
    await tester.pump(const Duration(milliseconds: 500));
    expect(detail.hitTestable(), findsNothing);
    await captureScreenshot(tester, 'm36_back_on_dashboard', settle: false);
    expect(Directory(real).statSync().modified, before);
  });

  testWidgets('m32: help page (real library, read-only)', (tester) async {
    final real = p.canonicalize('../assets_library');
    if (!Directory(real).existsSync()) return;
    final before = Directory(real).statSync().modified;
    await tester.pumpWidget(app(real, library: real));
    await pumpUntil(tester, realPacks());
    await tester.sendKeyEvent(LogicalKeyboardKey.f1);
    await pumpUntil(tester, find.byType(HelpScreen));
    await tester.pump(const Duration(seconds: 1));
    await captureScreenshot(tester, 'm32_help_top', settle: false);
    // The page's list (its paragraphs have scrollables of their own).
    final list = find
        .descendant(
          of: find.byType(HelpScreen),
          matching: find.byType(Scrollable),
        )
        .first;
    final animations = find.text('Animations');
    await tester.scrollUntilVisible(animations, 300, scrollable: list);
    await tester.pump(const Duration(milliseconds: 300));
    await captureScreenshot(tester, 'm32_help_animations', settle: false);
    final keys = find.text('Keyboard & mouse');
    await tester.scrollUntilVisible(keys, 300, scrollable: list);
    await tester.drag(list, const Offset(0, -200));
    await tester.pump(const Duration(milliseconds: 300));
    await captureScreenshot(tester, 'm32_help_keys', settle: false);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    for (
      var i = 0;
      i < 30 && find.byType(HelpScreen).evaluate().isNotEmpty;
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(HelpScreen), findsNothing);
    expect(Directory(real).statSync().modified, before);
  });

  testWidgets('m33: toolbars, author chip, version (real, read-only)', (
    tester,
  ) async {
    final real = p.canonicalize('../assets_library');
    if (!Directory(real).existsSync()) return;
    const title = 'Epic RPG World - Village(interiors) V1.3';
    if (!Directory(p.join(real, 'RafaelMatos', title)).existsSync()) return;
    final before = Directory(real).statSync().modified;
    await tester.pumpWidget(app(real, library: real));
    await pumpUntil(tester, realPacks());
    // M45: one import icon with a menu replaced the two buttons.
    expect(find.byTooltip('Import'), findsOne);
    expect(find.widgetWithText(OutlinedButton, 'Import archive'), findsNothing);

    // A selected author shows as a filled chip.
    await tester.tap(find.text('Author'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(
      find.descendant(
        of: find.byType(CheckboxMenuButton),
        matching: find.textContaining('RafaelMatos'),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    // Its button closes the menu again.
    await tester.tap(find.text('Author · 1'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.widgetWithText(InputChip, 'RafaelMatos'), findsOneWidget);
    await settleImages(tester);
    await captureScreenshot(tester, 'm33_dashboard_toolbar', settle: false);

    // The detail toolbar: slider as wide as the search box.
    final tile = find.descendant(
      of: find.byType(PackTile),
      matching: find.text(title),
    );
    await pumpUntil(tester, tile);
    await tester.tap(tile.first);
    await pumpUntil(tester, find.byType(TabBar));
    await tester.pump(const Duration(seconds: 1));
    final field = find.widgetWithText(TextField, 'Search files');
    expect(
      tester.getSize(find.byType(ThumbSizeSlider)).width,
      tester.getSize(field).width,
    );
    await settleImages(tester);
    await captureScreenshot(tester, 'm33_detail_toolbar', settle: false);

    // Settings ends with the version.
    // Ctrl+, (the detail page has no Settings button).
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.comma);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await pumpUntil(tester, find.text('Appearance'));
    final list = find
        .descendant(
          of: find.byType(SettingsScreen),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(
      find.text(appVersionLabel),
      300,
      scrollable: list,
    );
    await tester.pump(const Duration(milliseconds: 300));
    await captureScreenshot(tester, 'm33_settings_about', settle: false);
    expect(Directory(real).statSync().modified, before);
  });

  testWidgets('m34: Sea Adventures animations, one file each (real)', (
    tester,
  ) async {
    final real = p.canonicalize('../assets_library');
    if (!Directory(real).existsSync()) return;
    const title = 'ERW - Sea Adventures (GL 2.0 expansion) V1.5';
    if (!Directory(p.join(real, 'RafaelMatos', title)).existsSync()) return;
    final before = Directory(real).statSync().modified;
    await tester.pumpWidget(app(real, library: real));
    await pumpUntil(tester, realPacks());
    await tester.tap(find.byType(TextField));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'Sea Adventures');
    await tester.pump(DashboardQueryNotifier.searchDebounce);
    final tile = find.descendant(
      of: find.byType(PackTile),
      matching: find.text(title),
    );
    await pumpUntil(tester, tile);
    await tester.tap(tile.first);
    await pumpUntil(tester, find.textContaining('Animations ('), seconds: 60);
    await tester.tap(find.textContaining('Animations ('));
    await tester.pump(const Duration(seconds: 1));
    await settleImages(tester);
    await tester.pump(const Duration(milliseconds: 300));
    await captureScreenshot(tester, 'm34_sea_animations', settle: false);

    // banner-only.png: 12 frames of 96×128; gems-1.png an 8-frame strip.
    final field = find.widgetWithText(TextField, 'Search files');
    await tester.enterText(field, 'banner');
    await pumpUntil(tester, find.text('Matching “banner”'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('96×128 · 12 frames · 10 fps'), findsWidgets);
    await settleImages(tester);
    await tester.pump(const Duration(milliseconds: 300));
    await captureScreenshot(tester, 'm34_sea_banner', settle: false);
    await tester.enterText(field, 'gems');
    await pumpUntil(tester, find.text('Matching “gems”'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('32×32 · 8 frames · 10 fps'), findsNWidgets(4));
    // Animations aren't listed again among the images.
    expect(find.textContaining('Images ('), findsNothing);
    await settleImages(tester);
    await tester.pump(const Duration(milliseconds: 300));
    await captureScreenshot(tester, 'm34_sea_gems', settle: false);
    expect(Directory(real).statSync().modified, before);
  });

  testWidgets('m43: ship sheets in the Animations tab (real, read-only)', (
    tester,
  ) async {
    final real = p.canonicalize('../assets_library');
    if (!Directory(real).existsSync()) return;
    const title = 'ERW - Sea Adventures (GL 2.0 expansion) V1.5';
    if (!Directory(p.join(real, 'RafaelMatos', title)).existsSync()) return;
    final before = Directory(real).statSync().modified;
    await tester.pumpWidget(app(real, library: real));
    await pumpUntil(tester, realPacks());
    await tester.tap(find.byType(TextField));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'Sea Adventures');
    await tester.pump(DashboardQueryNotifier.searchDebounce);
    final tile = find.descendant(
      of: find.byType(PackTile),
      matching: find.text(title),
    );
    await pumpUntil(tester, tile);
    await tester.tap(tile.first);
    await pumpUntil(tester, find.textContaining('Animations ('), seconds: 60);
    await tester.tap(find.textContaining('Animations ('));
    await tester.pump(const Duration(seconds: 1));
    final field = find.widgetWithText(TextField, 'Search files');
    await tester.enterText(field, 'ship-animations');
    await pumpUntil(tester, find.text('Matching “ship-animations”'));
    await tester.pump(const Duration(milliseconds: 500));
    // Idle: 15 frames of 608×640 (strips and 4×4 grids of 15 used cells);
    // sailing: 17 (strips and 5×4 grids), windFX ones included.
    expect(find.text('608×640 · 15 frames · 10 fps'), findsWidgets);
    expect(find.text('608×640 · 17 frames · 10 fps'), findsWidgets);
    await tester.tap(find.text('By folder'));
    await tester.pump(const Duration(seconds: 1));
    // Fold the mockup GIF's section so the ship folder is in view.
    await tester.tap(find.text('Mockups'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Props / Animated / Ship'), findsOneWidget);
    await settleImages(tester);
    await tester.pump(const Duration(seconds: 1));
    await captureScreenshot(tester, 'm43_ship_folder', settle: false);
    expect(Directory(real).statSync().modified, before);
  });

  testWidgets('m47: fisherman grids in the Animations tab (real, read-only)', (
    tester,
  ) async {
    final real = p.canonicalize('../assets_library');
    if (!Directory(real).existsSync()) return;
    const title = 'Epic RPG World - The Village V2.2';
    if (!Directory(p.join(real, 'RafaelMatos', title)).existsSync()) return;
    final before = Directory(real).statSync().modified;
    await tester.pumpWidget(app(real, library: real));
    await pumpUntil(tester, realPacks());
    await tester.tap(find.byType(TextField));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'The Village V2.2');
    await tester.pump(DashboardQueryNotifier.searchDebounce);
    final tile = find.descendant(
      of: find.byType(PackTile),
      matching: find.text(title),
    );
    await pumpUntil(tester, tile);
    await tester.tap(tile.first);
    await pumpUntil(tester, find.textContaining('Animations ('), seconds: 60);
    await tester.tap(find.textContaining('Animations ('));
    await tester.pump(const Duration(seconds: 1));
    final field = find.widgetWithText(TextField, 'Search files');
    await tester.enterText(field, 'fisherman-beard-headband');
    await pumpUntil(tester, find.text('Matching “fisherman-beard-headband”'));
    await tester.pump(const Duration(milliseconds: 500));
    // Pulling back: 35 of the 6 × 6 cells; throwing: 14 of 4 × 4.
    expect(find.text('192×192 · 35 frames · 10 fps'), findsOneWidget);
    expect(find.text('192×192 · 14 frames · 10 fps'), findsOneWidget);
    expect(
      find.text('Fisherman beard headband fishing pulling back'),
      findsOne,
    );
    await tester.tap(find.text('By folder'));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('NPCs / Fisherman / Beard and headband'), findsOneWidget);
    await settleImages(tester);
    await tester.pump(const Duration(seconds: 1));
    await captureScreenshot(tester, 'm47_fisherman_folder', settle: false);
    expect(Directory(real).statSync().modified, before);
  });

  testWidgets('m44: tabs, filters and a pack search survive a restart', (
    tester,
  ) async {
    copyTree('test/fixtures/managed', lib);
    for (final rel in ['heroes/knight_a.png', 'heroes/knight_b.png']) {
      File(p.join(lib, 'HeroMaker', 'Knight Pack', rel))
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(img.encodePng(img.Image(width: 16, height: 16)));
    }
    await tester.pumpWidget(app(lib));
    await pumpUntil(tester, find.text('Slimes'));
    var c = ProviderScope.containerOf(tester.element(find.byType(TabsHost)));
    // Filters: the character type, sorted by name.
    c
        .read(dashboardQueryProvider.notifier)
        .restore(
          const DashboardQuery(types: {'character'}, sort: PackSort.title),
        );
    c.read(tabsProvider.notifier)
      ..open('HeroMaker/Slimes')
      ..open('HeroMaker/Knight Pack')
      ..select(2);
    final field = find.descendant(
      of: find.byKey(const ValueKey('tab-1')),
      matching: find.widgetWithText(TextField, 'Search files'),
    );
    await pumpUntil(tester, field);
    await tester.enterText(field, 'knight');
    await pumpUntil(tester, find.text('Matching “knight”'));
    final settings = File(p.join(tmp.path, 'settings.json'));
    final end = DateTime.now().add(const Duration(seconds: 10));
    while (!settings.readAsStringSync().contains('"search": "knight"')) {
      if (DateTime.now().isAfter(end)) fail('last_session not saved');
      await tester.pump(const Duration(milliseconds: 100));
    }
    // Restart on the same settings file.
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpWidget(app(lib, restart: true));
    await pumpUntil(tester, find.text('Matching “knight”'));
    c = ProviderScope.containerOf(tester.element(find.byType(TabsHost)));
    final tabs = c.read(tabsProvider);
    expect(tabs.tabs.map((t) => t.packId), [
      'HeroMaker/Slimes',
      'HeroMaker/Knight Pack',
    ]);
    expect(tabs.active, 2);
    expect(c.read(dashboardQueryProvider).types, {'character'});
    expect(c.read(dashboardQueryProvider).sort, PackSort.title);
    expect(
      tester
          .widget<TextField>(
            find.descendant(
              of: find.byKey(const ValueKey('tab-1')),
              matching: find.byType(TextField),
            ),
          )
          .controller!
          .text,
      'knight',
    );
    await settleImages(tester);
    await tester.pump(const Duration(milliseconds: 500));
    await captureScreenshot(tester, 'm44_restored_tab', settle: false);
    // The dashboard tab kept its filters.
    c.read(tabsProvider.notifier).select(0);
    await tester.pump(const Duration(milliseconds: 500));
    await settleImages(tester);
    await captureScreenshot(tester, 'm44_restored_dashboard', settle: false);
  });

  testWidgets('m34: a file result that is an animation opens Animations', (
    tester,
  ) async {
    final real = p.canonicalize('../assets_library');
    if (!Directory(real).existsSync()) return;
    const title = 'ERW - Sea Adventures (GL 2.0 expansion) V1.5';
    if (!Directory(p.join(real, 'RafaelMatos', title)).existsSync()) return;
    final before = Directory(real).statSync().modified;
    await tester.pumpWidget(app(real, library: real));
    await pumpUntil(tester, realPacks());
    await tester.tap(find.text('Files'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.enterText(find.byType(TextField), 'gems');
    await tester.pump(DashboardQueryNotifier.searchDebounce);
    final result = find.textContaining('$title · ');
    await pumpUntil(tester, result);
    await tester.ensureVisible(result.first);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(result.first);
    await pumpUntil(tester, find.text('Matching “gems”'));
    await tester.pump(const Duration(seconds: 1));
    // The Animations tab is the one shown: its cards are built.
    await pumpUntil(tester, find.text('32×32 · 8 frames · 10 fps'));
    await settleImages(tester);
    await tester.pump(const Duration(milliseconds: 300));
    await captureScreenshot(tester, 'm34_file_result_animation', settle: false);
    expect(Directory(real).statSync().modified, before);
  });

  testWidgets('m21: sort by type (real library, read-only)', (tester) async {
    final real = p.canonicalize('../assets_library');
    if (!Directory(real).existsSync()) return;
    final before = Directory(real).statSync().modified;
    await tester.pumpWidget(app(real, library: real));
    await pumpUntil(tester, realPacks());
    await tester.tap(find.byType(DropdownButton<PackSort>));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('Type').last);
    await tester.pump(const Duration(milliseconds: 500));
    final keys = [
      for (final e in find.byType(PackTile).evaluate())
        typeSortKey((e.widget as PackTile).pack.types) ?? '\uffff',
    ];
    expect(keys, isNotEmpty);
    expect(keys, orderedEquals([...keys]..sort()));
    await settleImages(tester);
    await captureScreenshot(tester, 'm21_type_sort', settle: false);
    expect(Directory(real).statSync().modified, before);
  });

  testWidgets('m22: file search results (real library, read-only)', (
    tester,
  ) async {
    final real = p.canonicalize('../assets_library');
    if (!Directory(real).existsSync()) return;
    final before = Directory(real).statSync().modified;
    await tester.pumpWidget(app(real, library: real));
    await pumpUntil(tester, realPacks());
    await tester.tap(find.text('Files'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Type to search file names'), findsOneWidget);
    await captureScreenshot(tester, 'm22_files_hint', settle: false);

    await tester.enterText(find.byType(TextField), 'barrels');

    await tester.pump(DashboardQueryNotifier.searchDebounce);
    // The first result on screen (the grid builds lazily).
    final village = find.textContaining('Village(interiors) V1.3 · ');
    await pumpUntil(tester, village);
    await settleImages(tester);
    await captureScreenshot(tester, 'm22_files_barrels', settle: false);

    // Packs view: the pack says which files matched.
    await tester.tap(find.text('Packs'));
    await pumpUntil(tester, find.byKey(const ValueKey('file-matches')));
    expect(find.textContaining('files match: barrels'), findsWidgets);
    await settleImages(tester);
    await captureScreenshot(tester, 'm22_packs_match_line', settle: false);

    await tester.tap(find.text('Files'));
    await pumpUntil(tester, village);
    await tester.ensureVisible(village.first);
    await tester.pump(const Duration(milliseconds: 300));
    // M23: a file result opens the filtered detail only, not the viewer.
    await tester.tap(village.first);
    await pumpUntil(tester, find.text('Matching “barrels”'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(ImageViewer), findsNothing);
    await settleImages(tester);
    await captureScreenshot(tester, 'm22_detail_filtered', settle: false);
    await tester.tap(find.text('Show all files'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Matching “barrels”'), findsNothing);
    expect(Directory(real).statSync().modified, before);
  });

  testWidgets('m23: debounce, tooltip, facet counts, shortcuts (real)', (
    tester,
  ) async {
    final real = p.canonicalize('../assets_library');
    if (!Directory(real).existsSync()) return;
    final before = Directory(real).statSync().modified;
    await tester.pumpWidget(app(real, library: real));
    await pumpUntil(tester, realPacks());
    final all = find.text(
      tester.widget<Text>(realPacks()).data!,
    ); // e.g. "72 packs"

    // Typing doesn't search until it pauses for 250 ms: keys closer
    // together keep the full list. The timer runs on the real clock and a
    // frame of this dashboard can take 100+ ms here, so the pause between
    // keys is short and the real gap is checked to be under the debounce.
    var typed = '';
    final clock = Stopwatch()..start();
    for (final ch in 'barrels'.split('')) {
      typed += ch;
      final gap = clock.elapsed;
      await tester.enterText(find.byType(TextField), typed);
      clock.reset();
      await tester.pump(const Duration(milliseconds: 50));
      if (typed.length > 1) {
        expect(gap, lessThan(DashboardQueryNotifier.searchDebounce));
      }
      expect(all, findsOneWidget, reason: typed);
    }
    final line = find.byKey(const ValueKey('file-matches'));
    await pumpUntil(tester, line);

    // The match line's tooltip lists the names.
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(line.first));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('barrels_0'), findsWidgets);
    await settleImages(tester);
    await captureScreenshot(tester, 'm23_match_tooltip', settle: false);
    await mouse.moveTo(Offset.zero);
    await tester.pump(const Duration(seconds: 1));

    // Clearing applies at once.
    await tester.tap(find.byTooltip('Clear search'));
    await tester.pump();
    expect(all, findsOneWidget);

    // Facet counts: the Tag menu within one author's packs.
    List<String> menuItems() => [
      for (final e in find.byType(CheckboxMenuButton).evaluate())
        ((e.widget as CheckboxMenuButton).child! as Text).data!,
    ];
    await tester.tap(find.widgetWithText(TextButton, 'Tag'));
    await tester.pump(const Duration(milliseconds: 400));
    final allTags = menuItems();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.widgetWithText(TextButton, 'Author'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.textContaining('RafaelMatos  ('));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.widgetWithText(TextButton, 'Tag'));
    await tester.pump(const Duration(milliseconds: 400));
    final rafaelTags = menuItems();
    expect(rafaelTags, isNotEmpty);
    expect(rafaelTags, isNot(allTags));
    await settleImages(tester);
    await captureScreenshot(tester, 'm23_tag_counts_one_author', settle: false);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump(const Duration(milliseconds: 400));

    // Ctrl+, after a click on empty space opens the settings.
    await tester.tap(find.byType(TextField));
    await tester.pump();
    await tester.tapAt(const Offset(720, 880));
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.comma);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await pumpUntil(
      tester,
      find.text('Animate all sprite previews on dashboard'),
    );
    await tester.pump(const Duration(milliseconds: 500));
    await captureScreenshot(tester, 'm23_settings_label', settle: false);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump(const Duration(milliseconds: 500));
    expect(Directory(real).statSync().modified, before);
  });

  testWidgets('archive import: zip and tar.gz through the review screen', (
    tester,
  ) async {
    copyTree('test/fixtures/managed', lib);
    final orc = Archive()
      ..add(ArchiveFile.string('Orc Pack/preview.png', 'x'))
      ..add(
        ArchiveFile.bytes(
          'Orc Pack/orc.png',
          File('test/fixtures/images/hero.png').readAsBytesSync(),
        ),
      )
      ..add(
        ArchiveFile.string('Orc Pack/credits.txt', 'https://orcs.itch.io/'),
      );
    final zipPath = p.join(tmp.path, 'orc_pack_v1.zip');
    File(zipPath).writeAsBytesSync(ZipEncoder().encodeBytes(orc));
    final sfx = Archive()
      ..add(ArchiveFile.string('hit.wav', 'RIFF'))
      ..add(ArchiveFile.string('jump.wav', 'RIFF'));
    final tgzPath = p.join(tmp.path, 'Retro SFX.tar.gz');
    File(tgzPath).writeAsBytesSync(
      GZipEncoder().encodeBytes(TarEncoder().encodeBytes(sfx)),
    );
    final badPath = p.join(tmp.path, 'broken.zip');
    File(badPath).writeAsStringSync('nope');
    pickedArchives = [zipPath, tgzPath, badPath];

    await tester.pumpWidget(app(lib));
    await pumpUntil(tester, find.text('Slimes'));
    await importFrom(tester, 'Import archive');
    await pumpUntil(tester, find.text('Import 2 packs'));
    await captureScreenshot(tester, 'm8_archive_review');
    await settleImages(tester);
    await captureScreenshot(tester, 'm8_archive_review');

    await tester.tap(find.text('Import 2 packs'));
    await pumpUntil(tester, find.text('Done'));
    expect(
      find.textContaining('2 of 2 packs imported and verified'),
      findsOneWidget,
    );
    await tester.tap(find.text('Done'));
    await pumpUntil(tester, find.text('Orc Pack'));
    await settleImages(tester);
    await captureScreenshot(tester, 'm8_library_after');
    final sidecar = File(p.join(lib, 'orcs', 'Orc Pack', 'asset_pack.json'))
        .readAsStringSync();
    expect(sidecar, contains(zipPath));
    expect(
      Directory(p.join(lib, 'Unknown Author', 'Retro SFX')).existsSync(),
      isTrue,
    );
    expect(
      Directory(p.join(tmp.path, 'extract')).listSync(),
      isEmpty,
      reason: 'temporary extraction removed',
    );
    expect(File(zipPath).existsSync(), isTrue, reason: 'archive kept');
  });

  testWidgets('itch: connect, link a matching pack, download a missing one', (
    tester,
  ) async {
    copyTree('test/fixtures/managed', lib);
    final zip = ZipEncoder().encodeBytes(
      Archive()..add(
        ArchiveFile.bytes(
          'Orc Pack/orc.png',
          File('test/fixtures/images/hero.png').readAsBytesSync(),
        ),
      ),
    );
    final cover = File('test/fixtures/images/hero.png').readAsBytesSync();
    Map<String, Object?> game(int id, String title, String user) => {
      'id': id,
      'title': title,
      'url': 'https://$user.itch.io/g$id',
      'classification': 'assets',
      'cover_url': 'https://img.example/c$id.png',
      'user': {'id': id, 'username': user, 'url': 'https://$user.itch.io'},
    };
    itchClient = MockClient((r) async {
      final path = '${r.url.host}${r.url.path}';
      if (r.url.host == 'api.itch.io' &&
          r.headers['Authorization'] != 'Bearer test-key') {
        return http.Response('{"errors":["invalid key"]}', 401);
      }
      return switch (path) {
        'api.itch.io/profile' => http.Response(
          '{"user":{"id":1,"username":"tester"}}',
          200,
        ),
        'api.itch.io/profile/owned-keys' => http.Response(
          jsonEncode(
            r.url.queryParameters['page'] == '1'
                ? {
                    'owned_keys': [
                      {'id': 10, 'game': game(1, 'Knight Pack', 'heromaker')},
                      {'id': 20, 'game': game(2, 'Orc Pack', 'orcmaker')},
                    ],
                    'per_page': 50,
                  }
                : {'owned_keys': {}},
          ),
          200,
        ),
        'api.itch.io/games/2/uploads' => http.Response(
          jsonEncode({
            'uploads': [
              {'id': 5, 'filename': 'orc.zip', 'size': zip.length},
            ],
          }),
          200,
        ),
        'api.itch.io/uploads/5/download' => http.Response(
          '',
          302,
          headers: {'location': 'https://cdn.example/orc.zip'},
        ),
        'cdn.example/orc.zip' => http.Response.bytes(zip, 200),
        'img.example/c1.png' ||
        'img.example/c2.png' => http.Response.bytes(cover, 200),
        _ => http.Response('<html></html>', 200),
      };
    });

    await tester.pumpWidget(app(lib));
    await pumpUntil(tester, find.text('Slimes'));
    await tester.tap(find.byTooltip('itch.io'));
    await pumpUntil(tester, find.text('Connect itch.io'));
    await captureScreenshot(tester, 'm9_connect');
    await tester.enterText(find.byType(TextField), 'wrong');
    await tester.pump(DashboardQueryNotifier.searchDebounce);
    await tester.tap(find.text('Connect'));
    await pumpUntil(tester, find.textContaining('rejected the API key'));
    await tester.tap(find.byType(TextField));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'test-key');
    await tester.pump(DashboardQueryNotifier.searchDebounce);
    await tester.pump();
    await tester.tap(find.text('Connect'));
    await pumpUntil(tester, find.textContaining('Signed in as tester'));
    expect(keyStore.key, 'test-key');
    await pumpUntil(tester, find.text('Orc Pack'));
    await captureScreenshot(tester, 'm9_missing');

    await tester.tap(find.text('Download'));
    // Once installed, the game moves from Missing to In library.
    await pumpUntil(
      tester,
      find.text('Every owned asset is in the library.'),
      seconds: 90,
    );
    expect(
      File(p.join(lib, 'orcmaker', 'Orc Pack', 'asset_pack.json'))
          .readAsStringSync(),
      contains('"itch_game_id": 2'),
    );

    await tester.tap(find.text('To link'));
    await pumpUntil(tester, find.text('Link'));
    await settleImages(tester);
    await tester.tap(find.text('Link'));
    await pumpUntil(tester, find.text('Nothing left to link.'));
    expect(
      File(p.join(lib, 'HeroMaker', 'Knight Pack', '_itch', 'c1.png'))
              .existsSync() ||
          File(p.join(lib, 'HeroMaker', 'Knight Pack', '_itch', 'cover.png'))
              .existsSync(),
      isTrue,
    );
    await tester.tap(find.text('In library'));
    await pumpUntil(tester, find.text('Knight Pack'));
    await pumpUntil(tester, find.text('Orc Pack'));
    await settleImages(tester);
    await captureScreenshot(tester, 'm9_in_library');
  });

  testWidgets('m76: empty library choices, itch.io tabs when empty', (
    tester,
  ) async {
    // A temp, empty library and a mock itch.io: one owned asset, missing.
    itchClient = MockClient((r) async {
      if (r.url.host == 'api.itch.io' &&
          r.headers['Authorization'] != 'Bearer test-key') {
        return http.Response('{"errors":["invalid key"]}', 401);
      }
      return switch ('${r.url.host}${r.url.path}') {
        'api.itch.io/profile' => http.Response(
          '{"user":{"id":1,"username":"tester"}}',
          200,
        ),
        'api.itch.io/profile/owned-keys' => http.Response(
          jsonEncode(
            r.url.queryParameters['page'] == '1'
                ? {
                    'owned_keys': [
                      {
                        'id': 20,
                        'game': {
                          'id': 2,
                          'title': 'Orc Pack',
                          'url': 'https://orcmaker.itch.io/orc-pack',
                          'classification': 'assets',
                          'user': {'id': 2, 'username': 'orcmaker'},
                        },
                      },
                    ],
                    'per_page': 50,
                  }
                : {'owned_keys': {}},
          ),
          200,
        ),
        _ => http.Response('<html></html>', 200),
      };
    });
    addTearDown(() => itchClient = null);

    await tester.pumpWidget(app(lib));
    await pumpUntil(tester, find.text('Your library is empty'));
    for (final k in [
      'first-import-folder',
      'first-import-archive',
      'first-itch',
    ]) {
      expect(find.byKey(ValueKey(k)), findsOneWidget, reason: k);
    }
    expect(find.text('Connect itch.io'), findsOneWidget);
    await captureScreenshot(tester, 'm76_empty_library');

    await tester.tap(find.byKey(const ValueKey('first-itch')));
    await pumpUntil(tester, find.text('Create a key on itch.io'));
    await tester.enterText(find.byType(TextField), 'test-key');
    await tester.pump(DashboardQueryNotifier.searchDebounce);
    await tester.pump();
    await tester.tap(find.text('Connect'));
    await pumpUntil(
      tester,
      find.text('Signed in as tester · 1 owned assets · 0 in the library'),
    );
    expect(find.text('Orc Pack'), findsOneWidget);
    expect(find.textContaining('never downloaded, only assets'), findsOne);

    // An empty tab still says what it holds.
    await tester.tap(find.text('To link'));
    await pumpUntil(tester, find.text('Nothing left to link.'));
    expect(find.textContaining('Packs you added yourself'), findsOne);
    await captureScreenshot(tester, 'm76_itch_empty_tabs');
    await tester.tap(find.text('In library'));
    await pumpUntil(tester, find.text('No pack is linked to itch yet.'));
    expect(find.text('Packs that know their itch.io page.'), findsOneWidget);

    // Back on the empty library, the itch.io choice now imports (M78):
    // three filled buttons of one width.
    await tester.pageBack();
    await pumpUntil(tester, find.text('Import from itch.io'));
    expect(find.text('Connect itch.io'), findsNothing);
    final widths = {
      for (final k in [
        'first-import-folder',
        'first-import-archive',
        'first-itch',
      ])
        tester.getSize(find.byKey(ValueKey(k))).width,
    };
    expect(widths, hasLength(1));
    expect(
      find.byWidgetPredicate(
        (w) => w is FilledButton && w.key.toString().contains('first-'),
      ),
      findsNWidgets(3),
    );
    await captureScreenshot(tester, 'm78_empty_library');
    expect(Directory(lib).listSync(), isEmpty);
  });

  testWidgets('m90: itch.io Missing tab — striped rows, hover', (tester) async {
    copyTree('test/fixtures/managed', lib);
    const titles = [
      'Orc Pack',
      'Dungeon Tiles',
      'Forest Tileset',
      'UI Icons 16x16',
      'Sea Creatures',
      'Desert Ruins',
      'Spell Effects',
    ];
    itchClient = MockClient((r) async {
      if (r.url.host == 'api.itch.io' &&
          r.headers['Authorization'] != 'Bearer test-key') {
        return http.Response('{"errors":["invalid key"]}', 401);
      }
      return switch ('${r.url.host}${r.url.path}') {
        'api.itch.io/profile' => http.Response(
          '{"user":{"id":1,"username":"tester"}}',
          200,
        ),
        'api.itch.io/profile/owned-keys' => http.Response(
          jsonEncode(
            r.url.queryParameters['page'] == '1'
                ? {
                    'owned_keys': [
                      for (var i = 0; i < titles.length; i++)
                        {
                          'id': 100 + i,
                          'game': {
                            'id': 50 + i,
                            'title': titles[i],
                            'url': 'https://maker$i.itch.io/g$i',
                            'classification': 'assets',
                            'user': {'id': 50 + i, 'username': 'maker$i'},
                          },
                        },
                    ],
                    'per_page': 50,
                  }
                : {'owned_keys': {}},
          ),
          200,
        ),
        _ => http.Response('<html></html>', 200),
      };
    });
    addTearDown(() => itchClient = null);

    await tester.pumpWidget(app(lib));
    await pumpUntil(tester, find.text('Slimes'));
    await tester.tap(find.byTooltip('itch.io'));
    await pumpUntil(tester, find.text('Connect itch.io'));
    await tester.enterText(find.byType(TextField).last, 'test-key');
    await tester.pump();
    await tester.tap(find.text('Connect'));
    await pumpUntil(tester, find.text('Spell Effects'));
    final band = tester.getRect(find.byKey(const ValueKey('itch-row:51')));
    final list = tester.getRect(
      find.ancestor(
        of: find.byKey(const ValueKey('itch-row:51')),
        matching: find.byType(ListView),
      ),
    );
    expect(band.width, list.width);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(
      location: tester.getCenter(find.byKey(const ValueKey('itch-row:52'))),
    );
    addTearDown(mouse.removePointer);
    await tester.pump(const Duration(milliseconds: 200));
    await captureScreenshot(tester, 'm90_itch_missing_stripes', settle: false);
  });

  testWidgets('itch on the real account and library (read-only)', (
    tester,
  ) async {
    final real = p.canonicalize('../assets_library');
    if (!Directory(real).existsSync() || !File(liveEnvFile).existsSync()) {
      return;
    }
    itchClient = null;
    useLiveKey = true;
    addTearDown(() => useLiveKey = false);
    await tester.pumpWidget(app(real, library: real));
    await pumpUntil(tester, realPacks());
    await tester.tap(find.byTooltip('itch.io'));
    await pumpUntil(tester, find.textContaining('Signed in as'), seconds: 90);
    await pumpUntil(tester, find.text('Download all missing (3)'));
    await settleImages(tester);
    await captureScreenshot(tester, 'm9_real_missing');
    await tester.tap(find.text('To link'));
    await tester.pump(const Duration(milliseconds: 500));
    await settleImages(tester);
    await captureScreenshot(tester, 'm9_real_to_link');
    expect(keyStore.key, isNull, reason: 'env key is never saved');
  });

  testWidgets('polish: settings, dark theme, empty and missing library', (
    tester,
  ) async {
    final empty = p.join(tmp.path, 'empty_lib');
    Directory(empty).createSync();
    await tester.pumpWidget(app(empty, library: p.join(tmp.path, 'gone')));
    await pumpUntil(tester, find.textContaining('is missing'));
    await captureScreenshot(tester, 'm10_library_missing');
    await tester.tap(find.text('Choose another folder'));
    await pumpUntil(tester, find.text('Your library is empty'));
    await captureScreenshot(tester, 'm10_library_empty');

    final real = p.canonicalize('../assets_library');
    if (!Directory(real).existsSync()) return;
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(app(real, library: real));
    await pumpUntil(tester, realPacks());
    await tester.tap(find.byTooltip('Settings (Ctrl+,)'));
    await pumpUntil(tester, find.text('Appearance'));
    await captureScreenshot(tester, 'm10_settings');

    await tester.tap(find.text('Dark'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Animate all sprite previews on dashboard'));
    await tester.pumpAndSettle();
    await captureScreenshot(tester, 'm10_settings_dark');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await pumpUntil(tester, realPacks());
    await settleImages(tester);
    await tester.pump(const Duration(milliseconds: 400));
    await captureScreenshot(tester, 'm10_dashboard_dark', settle: false);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'knight');
    await tester.pump(DashboardQueryNotifier.searchDebounce);
    await pumpUntil(tester, find.textContaining('packs'));
    await settleImages(tester);
    await tester.pump(const Duration(milliseconds: 400));
    await captureScreenshot(tester, 'm10_search_dark', settle: false);
  });

  testWidgets('m60: Models tab — one card per model, chips, broken file', (
    tester,
  ) async {
    copyTree('test/fixtures/managed', lib);
    final pack = p.join(lib, 'HeroMaker', 'Knight Pack');
    final models = p.join(pack, 'Models');
    writeCubeGlb(p.join(models, 'GLTF format'), 'crate');
    writeCubeObj(p.join(models, 'OBJ format'), 'crate');
    File(p.join(models, 'FBX format', 'crate.fbx'))
      ..createSync(recursive: true)
      ..writeAsBytesSync([0, 1, 2]);
    writeCubeGlb(
      p.join(models, 'GLTF format'),
      'tower',
      node: {
        'scale': [0.6, 2, 0.6],
        'rotation': [0, 0.38, 0, 0.92],
      },
    );
    File(p.join(models, 'GLTF format', 'broken.glb')).writeAsBytesSync([1, 2]);
    revealed.clear();

    await tester.pumpWidget(app(lib));
    await pumpUntil(tester, find.text('Knight Pack'));
    await tester.tap(find.text('Knight Pack'));
    await pumpUntil(tester, find.textContaining('Models ('));
    expect(find.text('Models (3)'), findsOneWidget);
    await tester.tap(find.textContaining('Models ('));
    await tester.pump(const Duration(milliseconds: 500));
    await pumpUntil(tester, find.byKey(const ValueKey('model-error')));
    await pumpUntil(
      tester,
      find.byKey(const ValueKey('model-loading')),
      gone: true,
    );
    expect(find.byKey(const ValueKey('model-paint')), findsNWidgets(2));
    expect(find.text('12 triangles · GLB, OBJ, FBX'), findsOneWidget);
    await captureScreenshot(tester, 'm60_models_tab', settle: false);

    // OBJ draws the OBJ; FBX is shown in the file manager.
    final crate = find.byKey(const ValueKey('model:models/crate'));
    // The chips show on hover.
    await hoverOver(tester, crate);
    await tester.tap(
      find.byKey(const ValueKey('format:Models/OBJ format/crate.obj')),
    );
    await tester.pump();
    await pumpUntil(
      tester,
      find.byKey(const ValueKey('model-loading')),
      gone: true,
    );
    expect(tester.widget<ItemCard>(crate).path, 'Models/OBJ format/crate.obj');
    await tester.tap(
      find.byKey(const ValueKey('format:Models/FBX format/crate.fbx')),
    );
    await tester.pump();
    expect(revealed.single, endsWith('crate.fbx'));

    // Hover turns it; By folder leaves the format folders out.
    await tester.pump(const Duration(seconds: 1));
    await captureScreenshot(tester, 'm60_hover', settle: false);
    await tester.tap(find.text('By folder'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.textContaining('format'), findsNothing);
    await captureScreenshot(tester, 'm60_models_by_folder', settle: false);
  });

  testWidgets('m62: Materials tab — two materials and a plain image', (
    tester,
  ) async {
    copyTree('test/fixtures/managed', lib);
    final pack = p.join(lib, 'HeroMaker', 'Knight Pack');
    final real = addMaterials(pack);
    revealed.clear();

    await tester.pumpWidget(app(lib));
    await pumpUntil(tester, find.text('Knight Pack'));
    await tester.tap(find.text('Knight Pack'));
    await pumpUntil(tester, find.textContaining('Materials ('));
    expect(find.text('Materials (${real ? 2 : 1})'), findsOneWidget);
    // Only knight.png is left as an image.
    expect(find.text('Images (1)'), findsOneWidget);
    await tester.tap(find.textContaining('Materials ('));
    await tester.pump(const Duration(milliseconds: 500));
    await settleImages(tester);
    final bricks = find.byKey(const ValueKey('material:Bricks/Bricks'));
    expect(bricks, findsOneWidget);
    expect(
      find.byKey(const ValueKey('material-picture:Bricks/Bricks_Color.png')),
      findsNWidgets(4),
    );
    if (real) {
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('material:Paving/PavingStones138')),
          matching: find.text('1K · 6 maps'),
        ),
        findsOneWidget,
      );
    }
    await tester.pump(const Duration(milliseconds: 400));
    await captureScreenshot(tester, 'm62_materials_tab', settle: false);

    // A map chip shows that map; a tool chip reveals its file.
    await hoverOver(tester, bricks);
    await tester.tap(
      find.byKey(const ValueKey('map:Bricks/Bricks_Normal.png')),
    );
    await tester.pump();
    await settleImages(tester);
    expect(
      find.byKey(const ValueKey('material-picture:Bricks/Bricks_Normal.png')),
      findsOneWidget,
    );
    await tester.pump(const Duration(milliseconds: 400));
    await captureScreenshot(tester, 'm62_map_chip', settle: false);
    await tester.tap(find.byKey(const ValueKey('format:Bricks/Bricks.tres')));
    await tester.pump();
    expect(revealed.single, endsWith('Bricks.tres'));

    // Search by map role.
    await tester.enterText(find.byType(TextField).first, 'displacement');
    await tester.pump(DashboardQueryNotifier.searchDebounce);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Materials (${real ? 1 : 0})'), findsOneWidget);
    await tester.enterText(find.byType(TextField).first, '');
    await tester.pump(DashboardQueryNotifier.searchDebounce);
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.text('By folder'));
    await tester.pump(const Duration(milliseconds: 500));
    await settleImages(tester);
    await tester.pump(const Duration(milliseconds: 400));
    await captureScreenshot(tester, 'm62_by_folder', settle: false);
  });

  testWidgets('m63: material viewer — sphere, plane, tiled, Esc closes', (
    tester,
  ) async {
    copyTree('test/fixtures/managed', lib);
    final pack = p.join(lib, 'HeroMaker', 'Knight Pack');
    final real = addMaterials(pack);
    materialViewOptions.reset();

    await tester.pumpWidget(app(lib));
    await pumpUntil(tester, find.text('Knight Pack'));
    await tester.tap(find.text('Knight Pack'));
    await pumpUntil(tester, find.textContaining('Materials ('));
    await tester.tap(find.textContaining('Materials ('));
    await tester.pump(const Duration(milliseconds: 500));
    await settleImages(tester);
    final card = find.byKey(
      ValueKey(
        real ? 'material:Paving/PavingStones138' : 'material:Bricks/Bricks',
      ),
    );
    await hoverOver(tester, card);
    final watch = Stopwatch()..start();
    await tester.tap(
      find.descendant(of: card, matching: find.byTooltip('Open in viewer')),
    );
    await pumpUntil(tester, find.byType(MaterialViewer));
    await pumpUntil(
      tester,
      find.byKey(const ValueKey('material-loading')),
      gone: true,
    );
    // ignore: avoid_print
    print(
      'm63: maps decoded and the sphere drawn in '
      '${watch.elapsedMilliseconds} ms',
    );
    expect(
      find.byKey(const ValueKey('material-shader:sphere')),
      findsOneWidget,
    );
    await settleImages(tester);
    await tester.pump(const Duration(milliseconds: 300));
    await captureScreenshot(tester, 'm63_sphere', settle: false);

    // Light from the right, a few repeats, then the plane.
    final stage = find.byKey(const ValueKey('material-viewer-stage'));
    await tester.drag(stage, const Offset(160, 40));
    await tester.pump();
    await tester.tap(find.text('Plane'));
    await tester.pump();
    expect(find.byKey(const ValueKey('material-shader:plane')), findsOneWidget);
    await tester.tap(find.text('Sphere'));
    await tester.pump();
    for (var i = 0; i < 2; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
    }
    await tester.tap(find.text('Plane'));
    await tester.pump(const Duration(milliseconds: 300));
    await captureScreenshot(tester, 'm63_plane', settle: false);

    await tester.tap(find.text('Tiled 3 × 3'));
    await tester.pump();
    await settleImages(tester);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('material-tiled')), findsOneWidget);
    await captureScreenshot(tester, 'm63_tiled', settle: false);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(MaterialViewer), findsNothing);
    expect(find.byType(PackDetailScreen), findsOneWidget);
    materialViewOptions.reset();
  });

  testWidgets('m64: audio columns, double-click viewer, slim header title', (
    tester,
  ) async {
    copyTree('test/fixtures/managed', lib);
    final pack = p.join(lib, 'HeroMaker', 'Knight Pack');
    final tone = File('test/fixtures/audio/tone.wav').readAsBytesSync();
    for (final rel in [
      'sfx/hit.wav',
      'sfx/coin_pickup.wav',
      'music/OGG/theme.ogg',
      'music/MP3/theme.mp3',
      'music/WAV/theme.wav',
    ]) {
      File(p.join(pack, rel))
        ..createSync(recursive: true)
        ..writeAsBytesSync(tone);
    }
    // A big one: the size column has to hold `1.3 MB` beside `44 B`.
    File(p.join(pack, 'music', 'long_ambience.wav'))
        .writeAsBytesSync([...tone, ...List.filled(1200000, 0)]);
    File(p.join(pack, 'sfx', 'tiny.wav')).writeAsBytesSync(tone.sublist(0, 44));

    await tester.pumpWidget(app(lib));
    await pumpUntil(tester, find.text('Knight Pack'));
    await tester.tap(find.text('Knight Pack'));
    await pumpUntil(tester, find.textContaining('Audio ('));
    await tester.tap(find.textContaining('Audio ('));
    await tester.pump(const Duration(milliseconds: 500));
    await pumpUntil(tester, find.text('1.3 MB'));
    final lefts = {
      for (final e
          in find
              .byWidgetPredicate(
                (w) =>
                    w.key is ValueKey<String> &&
                    (w.key! as ValueKey<String>).value.startsWith('length:'),
              )
              .evaluate())
        (e.renderObject! as RenderBox).localToGlobal(Offset.zero).dx,
    };
    expect(lefts, hasLength(1));
    await tester.pump(const Duration(milliseconds: 300));
    await captureScreenshot(tester, 'm64_audio_rows', settle: false);

    // A double-click on an image card opens the viewer.
    await tester.tap(find.textContaining('Images ('));
    await tester.pump(const Duration(milliseconds: 500));
    await settleImages(tester);
    final knight = find.byKey(const ValueKey('image:knight.png'));
    await tester.tap(knight);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(knight);
    await pumpUntil(tester, find.byType(ImageViewer));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(ImageViewer), findsNothing);

    // The slim bar names the pack.
    await tester.tap(find.byTooltip('Unpin header — show it on hover (H)'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('slim-title')), findsOneWidget);
    await captureScreenshot(tester, 'm64_slim_header', settle: false);
    await tester.tap(find.byTooltip('Pin header (H)'));
    await tester.pump(const Duration(milliseconds: 300));
  });

  testWidgets('m88: pack header — icons by the values, info to the edge', (
    tester,
  ) async {
    copyTree('test/fixtures/managed', lib);
    final pack = p.join(lib, 'HeroMaker', 'Knight Pack');
    final sidecar = File(p.join(pack, 'asset_pack.json'));
    final json = jsonDecode(sidecar.readAsStringSync()) as Map;
    const title =
        'Knight Pack — heroes, armour sets, idle, walk, attack and death '
        'animations for every direction';
    sidecar.writeAsStringSync(
      jsonEncode({
        ...json,
        'title': title,
        'tags': [
          for (final t in [
            'knight',
            'pixel-art',
            'rpg',
            'medieval',
            'top-down',
            'hero',
            'armour',
            'sword',
            'shield',
            'animated',
            '16x16',
            'fantasy',
            'character',
            'enemy',
            'npc',
            'dungeon',
            'retro',
            'side-view',
          ])
            t,
        ],
        'itch_url': 'https://example.itch.io/knight-pack',
      }),
    );

    await tester.pumpWidget(app(lib));
    await pumpUntil(tester, find.text(title));
    await tester.tap(find.text(title));
    await pumpUntil(tester, find.byType(TabBar));
    await tester.pump(const Duration(milliseconds: 500));
    await settleImages(tester);
    final titleRect = tester.getRect(
      find.byKey(const ValueKey('header-title')),
    );
    final icons = tester.getRect(find.byKey(const ValueKey('header-actions')));
    final info = tester.getRect(find.byKey(const ValueKey('header-info')));
    expect(titleRect.right, lessThanOrEqualTo(icons.left));
    expect(icons.right, closeTo(info.right, 0.5));
    expect(find.byTooltip('itch.io page'), findsOneWidget);
    await captureScreenshot(tester, 'm88_pack_header', settle: false);
  });

  testWidgets('m91: a former bundle is one flat pack (By folder, Expanded)', (
    tester,
  ) async {
    copyTree('test/fixtures/managed', lib);
    const cozy = 'HeroMaker/Cozy Tunes + Cozy FX';
    final hero = File('test/fixtures/images/hero.png').readAsBytesSync();
    final walk = File('test/fixtures/images/hero_walk.png').readAsBytesSync();
    final tone = File('test/fixtures/audio/tone.wav').readAsBytesSync();
    for (final (rel, bytes) in [
      ('License.txt', utf8.encode('CC0')),
      ('_itch/cover.png', walk),
      ('_itch/screenshot_01.png', hero),
      ('Cozy FX/License Agreement.pdf', utf8.encode('%PDF')),
      ('Cozy FX/pop.wav', tone),
      ('Cozy FX/icons/pop.png', hero),
      ('Cozy Tunes/Read Me.txt', utf8.encode('Thanks!')),
      ('Cozy Tunes/Audio/ogg/morning.wav', tone),
      ('Cozy Tunes/art/morning.png', hero),
      ('Cozy Tunes - The Classics/waltz.wav', tone),
      ('Cozy Tunes - The Classics/waltz.png', hero),
    ]) {
      File(p.join(lib, cozy, rel))
        ..createSync(recursive: true)
        ..writeAsBytesSync(bytes);
    }

    await tester.pumpWidget(app(lib));
    await pumpUntil(tester, find.text('Cozy Tunes + Cozy FX'));
    // One tile, no "Bundle" badge, no sub-pack tiles.
    expect(find.textContaining('Bundle ·'), findsNothing);
    expect(find.text('Cozy FX'), findsNothing);
    await tester.tap(find.text('Cozy Tunes + Cozy FX'));
    await pumpUntil(tester, find.textContaining('Images ('));
    await tester.pump(const Duration(seconds: 1));
    expect(find.textContaining('Audio (3)'), findsOneWidget);
    // M92: the cover and screenshot aren't the pack's images.
    expect(find.textContaining('Images (3)'), findsOneWidget);
    await tester.tap(find.textContaining('Images ('));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('By folder').first);
    await tester.pump(const Duration(milliseconds: 500));
    await settleImages(tester);
    await captureScreenshot(tester, 'm91_flat_pack', settle: false);
    for (final folder in ['Cozy FX', 'Cozy Tunes', 'Cozy Tunes The Classics']) {
      expect(
        find.textContaining(folder, skipOffstage: false),
        findsWidgets,
        reason: folder,
      );
    }
    expect(find.text('Itch', skipOffstage: false), findsNothing);

    // M92: the Files tab lists no `_itch` entry; the header counts 9 files
    // (11 on disk) and its carousel starts at the itch cover.
    await tester.tap(find.textContaining('Other files ('));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.textContaining('_itch', skipOffstage: false), findsNothing);
    expect(find.text('Cozy Tunes/Read Me.txt'), findsOneWidget);
    expect(find.textContaining('9 files'), findsWidgets);
    expect(find.textContaining('· cover.png'), findsOneWidget);
    await settleImages(tester);
    await captureScreenshot(tester, 'm92_itch_hidden', settle: false);

    // Back on the dashboard, Expanded shows its folders as tiles.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.text('Expanded'));
    await pumpUntil(tester, find.text('Cozy FX'));
    await settleImages(tester);
    await captureScreenshot(tester, 'm91_expanded', settle: false);
    expect(find.text('Cozy Tunes'), findsOneWidget);
  });

  testWidgets('m89: wait screen while a newly chosen library scans', (
    tester,
  ) async {
    copyTree('test/fixtures/managed', lib);
    final gate = Completer<void>();
    await tester.pumpWidget(
      app(
        lib,
        firstRun: true,
        overrides: [
          libraryServiceProvider.overrideWith(
            (ref) => _HeldService(ref.read(libraryIndexProvider), gate),
          ),
        ],
      ),
    );
    await pumpUntil(tester, find.text('Choose folder'));
    await tester.tap(find.text('Choose folder'));
    const title = 'Please wait while we scan your library';
    await pumpUntil(tester, find.text(title));
    expect(find.text(lib), findsOneWidget);
    expect(find.byKey(const ValueKey('first-choices')), findsNothing);
    await tester.pump(const Duration(milliseconds: 300));
    await captureScreenshot(tester, 'm89_scanning_library', settle: false);
    gate.complete();
    await pumpUntil(tester, find.text('Knight Pack'));
    expect(find.text(title), findsNothing);
  });

  testWidgets('m61: model viewer — orbit, wireframe, Esc closes', (
    tester,
  ) async {
    const kit =
        '../assets_library/Kenney/Kenney Game Assets 1 version 42/3D assets/'
        'Fantasy Town Kit/Models/GLTF format';
    copyTree('test/fixtures/managed', lib);
    final pack = p.join(lib, 'HeroMaker', 'Knight Pack');
    final models = p.join(pack, 'Models');
    if (Directory(kit).existsSync()) {
      // A temp copy of three real models: the library is never written.
      for (final name in ['cart.glb', 'fountainRoundDetail.glb', 'tree.glb']) {
        final from = File(p.join(kit, name));
        if (!from.existsSync()) continue;
        Directory(models).createSync(recursive: true);
        from.copySync(p.join(models, name));
      }
    }
    writeCubeGlb(models, 'crate');
    modelViewOptions
      ..textured = true
      ..wireframe = false
      ..turntable = false
      ..grid = false;

    await tester.pumpWidget(app(lib));
    await pumpUntil(tester, find.text('Knight Pack'));
    await tester.tap(find.text('Knight Pack'));
    await pumpUntil(tester, find.textContaining('Models ('));
    await tester.tap(find.textContaining('Models ('));
    await tester.pump(const Duration(milliseconds: 500));
    await pumpUntil(
      tester,
      find.byKey(const ValueKey('model-loading')),
      gone: true,
    );
    final first = find.byType(ItemCard).first;
    await tester.tap(first);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(first);
    await pumpUntil(tester, find.byKey(const ValueKey('model-viewer-paint')));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.textContaining('1 / '), findsOneWidget);
    await captureScreenshot(tester, 'm61_viewer', settle: false);

    // Orbit by dragging.
    ModelPainter painter() =>
        tester
                .widget<CustomPaint>(
                  find.byKey(const ValueKey('model-viewer-paint')),
                )
                .painter!
            as ModelPainter;
    final stage = find.byKey(const ValueKey('model-viewer-stage'));
    final drag = await tester.startGesture(
      tester.getCenter(stage),
      kind: PointerDeviceKind.mouse,
    );
    await drag.moveBy(const Offset(120, 0));
    await drag.moveBy(const Offset(0, 30));
    await drag.up();
    await tester.pump();
    expect(painter().yaw, closeTo(defaultModelYaw + 1.2, 1e-6));
    expect(painter().pitch, closeTo(defaultModelPitch + 0.3, 1e-6));

    await tester.tap(find.byKey(const ValueKey('toggle-wireframe')));
    await tester.tap(find.byKey(const ValueKey('toggle-grid')));
    await tester.pump(const Duration(milliseconds: 400));
    expect(painter().wireframe, isTrue);
    await captureScreenshot(tester, 'm61_wireframe', settle: false);

    // Next model, then Esc closes the viewer only.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(find.textContaining('2 / '), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(ModelViewer), findsNothing);
    expect(find.byType(PackDetailScreen), findsOneWidget);
    modelViewOptions
      ..wireframe = false
      ..grid = false;
  });

  testWidgets('m60: a real Kenney kit (temp copy), smallest cards', (
    tester,
  ) async {
    const kit =
        '../assets_library/Kenney/Kenney Game Assets 1 version 42/3D assets/'
        'Fantasy Town Kit/Models';
    if (!Directory(kit).existsSync()) return;
    copyTree('test/fixtures/managed', lib);
    final pack = p.join(lib, 'HeroMaker', 'Knight Pack');
    copyTree(kit, p.join(pack, 'Models'));

    await tester.pumpWidget(app(lib));
    await pumpUntil(tester, find.text('Knight Pack'));
    await tester.tap(find.text('Knight Pack'));
    await pumpUntil(tester, find.textContaining('Models ('));
    expect(find.text('Models (153)'), findsOneWidget);
    await tester.tap(find.textContaining('Models ('));
    await tester.pump(const Duration(milliseconds: 500));
    await pumpUntil(
      tester,
      find.byKey(const ValueKey('model-loading')),
      gone: true,
    );
    expect(find.byKey(const ValueKey('model-error')), findsNothing);
    await captureScreenshot(tester, 'm60_kenney_kit', settle: false);

    // Smallest cards, then scroll the whole grid.
    final slider = find.byType(ThumbSizeSlider);
    for (var i = 0; i < 20; i++) {
      await tester.tap(
        find.descendant(of: slider, matching: find.byTooltip('Smaller')),
      );
      await tester.pump();
    }
    await tester.pump(const Duration(milliseconds: 300));
    await pumpUntil(
      tester,
      find.byKey(const ValueKey('model-loading')),
      gone: true,
    );
    await captureScreenshot(tester, 'm60_kenney_small', settle: false);
    final scrollable = find
        .descendant(
          of: find.byType(CustomScrollView),
          matching: find.byType(Scrollable),
        )
        .first;
    final watch = Stopwatch()..start();
    var frames = 0;
    for (var i = 0; i < 30; i++) {
      await tester.drag(scrollable, const Offset(0, -200));
      await tester.pump();
      frames++;
    }
    await pumpUntil(
      tester,
      find.byKey(const ValueKey('model-loading')),
      gone: true,
    );
    // ignore: avoid_print
    print('m60: ${watch.elapsedMilliseconds} ms for $frames scroll steps');
    expect(find.byKey(const ValueKey('model-error')), findsNothing);
    await captureScreenshot(tester, 'm60_kenney_scrolled', settle: false);
  });
}

/// A real pack with both animations and plain images.
const villageInteriors = 'Epic RPG World - Village(interiors) V1.3';

/// Records seeks; the test pushes positions.
class _FakeTrackPlayer implements TrackPlayer {
  final seeks = <Duration>[];
  final played = <String>[];
  @override
  var looping = false;
  final position = StreamController<Duration>.broadcast();
  final complete = StreamController<void>.broadcast();

  @override
  Future<void> play(String path) async => played.add(path);
  var stops = 0;
  @override
  Future<void> stop() async => stops++;
  @override
  Future<void> seek(Duration to) async => seeks.add(to);
  @override
  Future<void> setLoop(bool loop) async => looping = loop;
  @override
  Stream<Duration> get onPosition => position.stream;
  @override
  Stream<Duration> get onDuration => const Stream.empty();
  @override
  Stream<void> get onComplete => complete.stream;
  @override
  Future<void> dispose() async {}
}

/// Holds the library load until [gate] completes, so a screenshot can
/// catch the wait screen.
class _HeldService extends LibraryService {
  _HeldService(super.index, this.gate);

  final Completer<void> gate;

  @override
  Future<LoadResult> load(String root, {bool force = false}) async {
    await gate.future;
    return super.load(root, force: force);
  }
}
