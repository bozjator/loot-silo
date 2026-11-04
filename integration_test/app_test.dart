import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:assets_explorer/core/library_index.dart';
import 'package:assets_explorer/itch/itch_api.dart';
import 'package:assets_explorer/itch/itch_key.dart';
import 'package:assets_explorer/state/itch.dart';
import 'package:assets_explorer/state/providers.dart';
import 'package:assets_explorer/state/settings.dart';
import 'package:assets_explorer/ui/app.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
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
    // Isolates and file IO need real time, not just frames.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump(const Duration(milliseconds: 50));
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
          archivePickerProvider.overrideWithValue(() async => pickedArchives),
          extractRootProvider.overrideWithValue(p.join(tmp.path, 'extract')),
          keyStoreProvider.overrideWithValue(keyStore),
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
    await pumpUntil(tester, find.text('71 packs'));
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
    await pumpUntil(tester, find.text('71 packs'));
    await tester.tap(find.byTooltip('Settings (Ctrl+,)'));
    await pumpUntil(tester, find.text('Keyboard shortcuts'));
    await captureScreenshot(tester, 'm10_settings');

    await tester.tap(find.text('Dark'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Animate all sprite previews'));
    await tester.pumpAndSettle();
    await captureScreenshot(tester, 'm10_settings_dark');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await pumpUntil(tester, find.text('71 packs'));
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
