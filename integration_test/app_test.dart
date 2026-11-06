import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:assets_explorer/core/library_index.dart';
import 'package:assets_explorer/itch/itch_api.dart';
import 'package:assets_explorer/itch/itch_key.dart';
import 'package:assets_explorer/state/dashboard.dart';
import 'package:assets_explorer/state/itch.dart';
import 'package:assets_explorer/state/providers.dart';
import 'package:assets_explorer/state/settings.dart';
import 'package:assets_explorer/ui/app.dart';
import 'package:assets_explorer/ui/dashboard.dart';
import 'package:assets_explorer/ui/image_viewer.dart';
import 'package:assets_explorer/ui/pack_detail_screen.dart';
import 'package:assets_explorer/ui/track_player.dart';
import 'package:assets_explorer/ui/widgets/pack_tile.dart';
import 'package:assets_explorer/ui/widgets/animated_sprite.dart';
import 'package:assets_explorer/ui/reveal.dart';
import 'package:assets_explorer/ui/tabs.dart';
import 'package:assets_explorer/ui/text_preview_dialog.dart';
import 'package:assets_explorer/ui/widgets/thumb_size.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:http/testing.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;

import '../test/helpers/fs.dart';
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

/// Screenshot suffix for the m27 before/after comparison.
const m27Phase = String.fromEnvironment('M27_PHASE', defaultValue: 'after');

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
    await tester.tap(find.text('Import folder').first);
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
    await tester.tap(find.text('Import folder').first);
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
    await pumpUntil(tester, find.textContaining('Tiny RPG'));
    await settleImages(tester);
    await captureScreenshot(tester, 'm4_search_slime');

    await tester.enterText(find.byType(TextField), '');
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
    await tester.tap(kenney);
    await pumpUntil(tester, find.text('All packs'));
    await settleImages(tester);
    await captureScreenshot(tester, 'm4_bundle_kenney1');
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
    await tester.tap(find.widgetWithText(FilterChip, 'Loop'));
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
    checker('fx/wide_strip.png', 4000, 200, 100);
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
    expect(find.text('Knight mockup'), findsOneWidget);
    await captureScreenshot(tester, 'm12_viewer_mockup', settle: false);

    // The mouse back button closes it like Esc.
    final mouse = await tester.startGesture(
      const Offset(20, 20),
      kind: PointerDeviceKind.mouse,
      buttons: kBackMouseButton,
    );
    await mouse.up();
    await pumpUntil(tester, find.byType(ImageViewer), seconds: 5, gone: true);
    expect(find.text('Knight Pack'), findsWidgets);

    await tester.tap(find.textContaining('Images ('));
    await tester.pump(const Duration(milliseconds: 500));
    await settleImages(tester);
    await tester.tap(find.text('wide_strip.png'));
    await pumpUntil(tester, find.text('Wide strip'));
    await settleImages(tester);
    expect(find.textContaining('4000 × 200 px'), findsOneWidget);
    await captureScreenshot(tester, 'm12_viewer_strip', settle: false);
    // Sorted order: fx/wide_strip, knight, knight_mockup, tiny_gem, ui/tall.
    for (final (steps, title, shot) in [
      (3, 'Tiny gem', 'm12_viewer_tiny'),
      (1, 'Tall banner panel', 'm12_viewer_tall'),
    ]) {
      for (var i = 0; i < steps; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pump();
      }
      expect(find.text(title), findsOneWidget);
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
    await tester.enterText(find.byType(TextField), 'ashishlko11');
    await pumpUntil(tester, find.text('Special Effects Vol.03'));
    await tester.tap(find.text('Special Effects Vol.03'));
    await pumpUntil(tester, find.textContaining('Images ('));
    await tester.tap(find.textContaining('Images ('));
    await tester.pump(const Duration(milliseconds: 500));
    await settleImages(tester);
    await tester.tap(find.text('1.png'));
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
    await mouse.moveTo(tester.getCenter(find.text('knight.png')));
    await tester.pump();
    await captureScreenshot(tester, 'm13_image_hover', settle: false);
    await tester.tap(find.byTooltip('Show in file manager').last);
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

    // Slider to the far left, then the far right.
    for (final (dx, size, shot) in [
      (-400.0, 140, 'm14_dashboard_min'),
      (400.0, 480, 'm14_dashboard_max'),
    ]) {
      await tester.drag(find.byType(Slider), Offset(dx, 0));
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        settings.readAsStringSync(),
        contains('"dashboard_tile_size": $size'),
      );
      await settleImages(tester);
      await captureScreenshot(tester, shot, settle: false);
    }

    await tester.enterText(find.byType(TextField), 'ashishlko11');
    await pumpUntil(tester, find.text('Special Effects Vol.03'));
    await tester.tap(find.text('Special Effects Vol.03'));
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
    expect(settings.readAsStringSync(), contains('"image_thumb_size": 220'));
    await settleImages(tester);
    await captureScreenshot(tester, 'm14_images_220', settle: false);

    await tester.drag(find.byType(Slider), const Offset(-400, 0));
    await tester.pump(const Duration(milliseconds: 300));
    expect(settings.readAsStringSync(), contains('"image_thumb_size": 80'));
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
    final mouse = TestPointer(1, PointerDeviceKind.mouse)
      ..hover(tester.getCenter(find.byType(CustomScrollView)));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    for (var i = 0; i < 2; i++) {
      await tester.sendEventToBinding(mouse.scroll(const Offset(0, -50)));
      await tester.pump();
    }
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    expect(
      File(p.join(tmp.path, 'settings.json')).readAsStringSync(),
      contains('"animation_thumb_size": 240'),
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
    await pumpUntil(tester, find.text('Pixel-Banner'));
    await tester.tap(find.text('Pixel-Banner'));
    await pumpUntil(tester, find.textContaining('Images ('));
    await tester.pump(const Duration(milliseconds: 500));

    await tester.tap(find.textContaining('Images ('));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('By folder'));
    await tester.pump(const Duration(milliseconds: 300));
    // One section per character, not one per action sub-folder.
    expect(find.text('ArcherSkeleton'), findsOneWidget);
    expect(find.textContaining('ArcherSkeleton /'), findsNothing);
    await settleImages(tester);
    await captureScreenshot(tester, 'm16_images_by_folder', settle: false);

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
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Used in'), findsOneWidget);
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
    expect(find.text('Sheet · 64×64 frames · 24 × 1 · 24 frames'), findsOne);
    final frames = find.widgetWithText(TextField, 'Frames');
    // Since M26 a count only fails when no grid fits at all.
    await tester.enterText(frames, '600');
    await tester.pump();
    expect(find.text("Doesn't fit 1536×64 px"), findsOneWidget);
    await tester.enterText(frames, '16');
    await tester.pump();
    expect(find.text('Sheet · 96×64 frames · 16 × 1 · 16 frames'), findsOne);
    await settleImages(tester);
    await captureScreenshot(tester, 'm18_frames_dialog', settle: false);
    await tester.tap(find.text('Save'));
    await pumpUntil(tester, find.text('Reset to detected'));
    expect(
      File(p.join(pack.path, 'asset_pack.json')).readAsStringSync(),
      contains('"frames": 16'),
    );
    await tester.tap(find.text('Close'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('96×64 · 16 frames · 10 fps'), findsOneWidget);
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
    await pumpUntil(tester, find.text('music-loop-bundle-chiptune'));
    await tester.tap(find.text('music-loop-bundle-chiptune'));
    // Opens straight on Audio: the Loop chip shows without a tab tap.
    await pumpUntil(tester, find.widgetWithText(FilterChip, 'Loop'));
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
    await pumpUntil(tester, find.text('16-BIT Achievements SFX Pack 1'));
    await tester.tap(find.text('16-BIT Achievements SFX Pack 1'));
    await pumpUntil(tester, find.widgetWithText(FilterChip, 'Loop'));
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

  testWidgets('m26: frame grid, saved rows, editor layout (real, unsaved)', (
    tester,
  ) async {
    final real = p.canonicalize('../assets_library');
    if (!Directory(real).existsSync()) return;
    final sea = File(
      p.join(
        real,
        'RafaelMatos',
        'ERW - Sea Adventures (GL 2.0 expansion) V1.5',
        'asset_pack.json',
      ),
    );
    final vfx = File(
      p.join(real, 'ashishlko11', 'Special Effects Vol.03', 'asset_pack.json'),
    );
    if (!sea.existsSync() || !vfx.existsSync()) return;
    final seaBefore = sea.readAsStringSync();
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

    // islands-grass-tower-vfx: 640×640, really 4×4 frames of 160 px.
    await openEditor(
      'Sea Adventures',
      'ERW - Sea Adventures (GL 2.0 expansion) V1.5',
      RegExp('grass tower vfx', caseSensitive: false),
    );
    final frames = find.widgetWithText(TextField, 'Frames');
    await tester.enterText(frames, '16');
    await tester.pump();
    expect(find.textContaining("Doesn't fit"), findsNothing);
    await settleImages(tester);
    await captureScreenshot(tester, 'm26_islands_16_frames', settle: false);
    expect(find.textContaining('160×160 frames · 4 × 4 · 16 frames'), findsOne);
    // − skips counts with no grid; the result always fits.
    await tester.tap(find.byTooltip('Fewer frames'));
    await tester.pump();
    expect(find.textContaining("Doesn't fit"), findsNothing);
    // Close without saving.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Apply size'), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    // Back on the dashboard, still filtered by the search.
    await pumpUntil(tester, find.text('1 pack'));

    // Special Effects Vol.03: All rows makes the dialog savable.
    await openEditor(
      'Special Effects Vol',
      'Special Effects Vol.03',
      RegExp(r'^1$'),
    );
    FilledButton save() =>
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Save'));
    expect(save().onPressed, isNull);
    await tester.tap(find.text('Row 1'));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('All rows').last);
    await tester.pump(const Duration(milliseconds: 500));
    expect(save().onPressed, isNotNull);
    expect(find.text('Not an animation'), findsOneWidget);
    await settleImages(tester);
    await captureScreenshot(tester, 'm26_all_rows', settle: false);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump(const Duration(milliseconds: 500));

    expect(sea.readAsStringSync(), seaBefore);
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
        await mouse.moveTo(
          tester.getCenter(
            find.ancestor(of: edit, matching: find.byType(Card)).first,
          ),
        );
        await tester.pump();
        await tester.tap(edit);
        await pumpUntil(tester, find.text('Apply size'));
        await tester.tap(find.byKey(const ValueKey('zoom')));
        await tester.pump(const Duration(milliseconds: 500));
        await tester.tap(find.text('2×').last);
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
    await tester.ensureVisible(combine);
    await tester.pump(const Duration(milliseconds: 300));
    await settleImages(tester);
    await captureScreenshot(tester, 'm28_folder_header', settle: false);

    await tester.tap(combine);
    await pumpUntil(tester, find.text('Apply size'));
    await settleImages(tester);
    await captureScreenshot(tester, 'm28_combined_editor', settle: false);
    // The frames differ in size; the strip uses the largest.
    expect(find.text('Sheet · 634×636 frames · 9 × 1 · 9 frames'), findsOne);
    final out = File(
      p.join(pack, 'fx', 'Explosion', 'Explosion_animation.png'),
    );
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
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.tap(find.text(name));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
    }
    expect(find.text('Combine 2 images into animation'), findsOneWidget);
    await settleImages(tester);
    await captureScreenshot(tester, 'm28_selection_bar', settle: false);
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
    final tile = find.descendant(
      of: find.byType(PackTile),
      matching: find.text(title),
    );
    await pumpUntil(tester, tile);
    await tester.tap(tile.first);
    await pumpUntil(tester, find.byType(TabBar));
    await tester.pump(const Duration(seconds: 1));
    // Opened from a pack search (not a file search): no file filter yet.
    final field = find.widgetWithText(TextField, 'Search files (Ctrl+F)');
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

    // Typing doesn't search until it pauses.
    await tester.enterText(find.byType(TextField), 'barrels');
    await tester.pump(const Duration(milliseconds: 50));
    expect(all, findsOneWidget);
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
    await tester.tap(find.text('Import archive'));
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
    await tester.tap(find.text('Connect'));
    await pumpUntil(tester, find.textContaining('rejected the API key'));
    await tester.tap(find.byType(TextField));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'test-key');
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
    await pumpUntil(tester, find.text('Keyboard shortcuts'));
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
    await pumpUntil(tester, find.textContaining('packs'));
    await settleImages(tester);
    await tester.pump(const Duration(milliseconds: 400));
    await captureScreenshot(tester, 'm10_search_dark', settle: false);
  });
}

/// Records seeks; the test pushes positions.
class _FakeTrackPlayer implements TrackPlayer {
  final seeks = <Duration>[];
  @override
  var looping = false;
  final position = StreamController<Duration>.broadcast();

  @override
  Future<void> play(String path) async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> seek(Duration to) async => seeks.add(to);
  @override
  Future<void> setLoop(bool loop) async => looping = loop;
  @override
  Stream<Duration> get onPosition => position.stream;
  @override
  Stream<Duration> get onDuration => const Stream.empty();
  @override
  Stream<void> get onComplete => const Stream.empty();
  @override
  Future<void> dispose() async {}
}
