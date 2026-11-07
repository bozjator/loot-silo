// README screenshots and GIF frames (M53). Skipped unless README_MEDIA=1
// (environment) or --dart-define=README_MEDIA=1:
//
//   README_MEDIA=1 xvfb-run -a -s "-screen 0 1440x900x24" \
//     flutter test integration_test/readme_media_test.dart -d linux
//   python3 tool/readme_media/make_media.py
//
// Everything shown comes from Kenney's packs (CC0), copied out of the real
// library (read-only) into a temporary one, so nothing in
// ../assets_library is written.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:loot_silo/core/library_index.dart';
import 'package:loot_silo/core/pack_editor.dart';
import 'package:loot_silo/state/itch.dart';
import 'package:loot_silo/state/providers.dart';
import 'package:loot_silo/state/settings.dart';
import 'package:loot_silo/ui/app.dart';
import 'package:loot_silo/ui/credits_screen.dart';
import 'package:loot_silo/ui/image_viewer.dart';
import 'package:loot_silo/ui/reveal.dart';
import 'package:loot_silo/ui/widgets/animated_sprite.dart';
import 'package:path/path.dart' as p;

import '../test/helpers/fs.dart';
import 'screenshot_helper.dart';

const _define = bool.fromEnvironment('README_MEDIA');
final _enabled = _define || Platform.environment['README_MEDIA'] == '1';

/// Where the raw media goes; `tool/readme_media/make_media.py` turns it into
/// `docs/media/`.
const outDir = 'screenshots/readme';

/// Kenney's Game Assets 1, inside the real library.
final kenneySource = p.canonicalize(
  '../assets_library/Kenney/Kenney Game Assets 1 version 42',
);

/// The packs copied into the temporary library: folder under
/// [kenneySource] → (types, tags).
const packs = <String, (List<String>, List<String>)>{
  '2D assets/Platformer Pack Redux': (
    ['character', 'environment'],
    ['platformer', 'tileset'],
  ),
  '2D assets/Platformer Assets Extra Animations & Enemies': (
    ['character'],
    ['platformer', 'enemies', 'animated'],
  ),
  '2D assets/Tappy Plane': (
    ['character', 'environment', 'ui'],
    ['flappy', 'animated'],
  ),
  '2D assets/Explosion Pack': (['vfx'], ['explosion', 'animated']),
  '2D assets/Space Shooter Pack': (
    ['character', 'environment'],
    ['space', 'shooter'],
  ),
  '2D assets/Roguelike Characters Pack': (
    ['character'],
    ['roguelike', 'pixel-art'],
  ),
  '2D assets/UI Pixel Pack': (['ui'], ['pixel-art', 'buttons']),
  '2D assets/Animal Pack': (['character'], ['animals', 'cute']),
  '2D assets/Platformer Assets Pixel': (
    ['character', 'environment'],
    ['pixel-art', 'platformer', 'tileset'],
  ),
  '2D assets/Isometric Tiles City': (['environment'], ['isometric', 'city']),
  '2D assets/Game Icons': (['icons'], ['icons', 'buttons']),
  'Audio/RPG sounds (50 sounds)': (['sfx'], ['rpg']),
  'Audio/Retro sounds (35 sounds)': (['sfx'], ['retro', '8-bit']),
  'Audio/Music loops (30 files)': (['music'], ['loops']),
};

/// Packs offered by the folder import review screenshot.
const importPacks = ['2D assets/Toy Brick Pack', '2D assets/Medals'];

/// The game the Credits screenshot lists.
const game = 'Sky Hopper';
const gamePacks = {
  'Tappy Plane',
  'Explosion Pack',
  'Retro sounds (35 sounds)',
  'UI Pixel Pack',
};
const favoritePacks = {'Platformer Pack Redux', 'Tappy Plane'};

/// Kenney ships animations as one file per frame (`alienBlue_walk1.png`,
/// `walk2` …), which the detector rightly leaves as images. These are
/// combined into strips with the app's own "Combine into animation"
/// (`combineFrames`), in the temporary copy only: pack → strip → frames.
Map<String, Map<String, List<String>>> strips() {
  final aliens = <String, List<String>>{};
  for (final c in ['Beige', 'Blue', 'Green', 'Pink', 'Yellow']) {
    for (final move in ['walk', 'swim', 'climb']) {
      aliens['Alien sprites/alien${c}_$move.png'] = [
        'Alien sprites/alien${c}_${move}1.png',
        'Alien sprites/alien${c}_${move}2.png',
      ];
    }
  }
  const enemies = [
    ['bee', 'bee_fly'],
    ['fly', 'fly_fly'],
    ['bat', 'bat_fly'],
    ['fishGreen', 'fishGreen_swim'],
    ['fishPink', 'fishPink_swim'],
    ['mouse', 'mouse_walk'],
    ['ladyBug', 'ladyBug_walk'],
  ];
  for (final e in enemies) {
    aliens['Enemy sprites/${e[0]}_animation.png'] = [
      'Enemy sprites/${e[0]}.png',
      'Enemy sprites/${e[1]}.png',
    ];
  }
  final planes = <String, List<String>>{};
  for (final c in ['Blue', 'Green', 'Red', 'Yellow']) {
    planes['PNG/Planes/plane${c}_fly.png'] = [
      for (var i = 1; i <= 3; i++) 'PNG/Planes/plane$c$i.png',
    ];
  }
  final explosions = <String, List<String>>{};
  const kinds = [
    ['Regular explosion', 'regularExplosion'],
    ['Ground explosion', 'groundExplosion'],
    ['Pixel explosion', 'pixelExplosion'],
    ['Simple explosion', 'simpleExplosion'],
    ['Sonic explosion', 'sonicExplosion'],
  ];
  for (final k in kinds) {
    explosions['PNG/${k[0]}/${k[1]}_animation.png'] = [
      for (var i = 0; i <= 8; i++)
        'PNG/${k[0]}/${k[1]}${i.toString().padLeft(2, '0')}.png',
    ];
  }
  return {
    'Platformer Assets Extra Animations & Enemies': aliens,
    'Tappy Plane': planes,
    'Explosion Pack': explosions,
  };
}

/// Packs whose dashboard tile shows (and plays) a strip.
const covers = {
  'Platformer Assets Extra Animations & Enemies':
      'Alien sprites/alienGreen_walk.png',
  'Tappy Plane': 'PNG/Planes/planeRed_fly.png',
  'Explosion Pack': 'PNG/Regular explosion/regularExplosion_animation.png',
};

Future<void> pumpUntil(
  WidgetTester tester,
  Finder finder, {
  int seconds = 90,
  bool gone = false,
}) async {
  final end = DateTime.now().add(Duration(seconds: seconds));
  while (finder.evaluate().isEmpty != gone) {
    if (DateTime.now().isAfter(end)) fail('Timed out waiting for $finder');
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// Real time for decoding images and running isolates.
Future<void> wait(WidgetTester tester, [int ms = 1500]) async {
  for (var t = 0; t < ms; t += 100) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
  }
}

/// The test's mouse; screenshots park it where it shows no hover or
/// tooltip (the empty middle of the app bar).
TestGesture? mouse;

/// A README screenshot: `screenshots/readme/<name>.png`.
Future<void> shot(WidgetTester tester, String name) async {
  await mouse?.moveTo(const Offset(720, 20));
  await wait(tester, 400);
  await wait(tester, 800);
  await captureScreenshot(tester, 'readme/$name', settle: false);
}

/// Records GIF frames in real time: raw RGBA at [ratio] of the window, plus
/// `frames.json` with each frame's time (ms) and size.
class Recorder {
  Recorder(this.name, {this.ratio = 2 / 3});

  final String name;
  final double ratio;
  final _frames = <Map<String, Object>>[];
  final _clock = Stopwatch();

  Directory get dir => Directory('$outDir/frames/$name');

  /// Captures frames for [length] of real time, calling [step] (if given)
  /// before each frame with the time so far.
  Future<void> record(
    WidgetTester tester,
    Duration length, {
    Future<void> Function(Duration t)? step,
  }) async {
    if (!_clock.isRunning) {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
      dir.createSync(recursive: true);
      _clock.start();
    }
    final end = _clock.elapsed + length;
    while (_clock.elapsed < end) {
      if (step != null) await step(_clock.elapsed);
      await frame(tester);
    }
  }

  Future<void> frame(WidgetTester tester) async {
    await tester.pump();
    final t = _clock.elapsedMilliseconds;
    await tester.runAsync(() async {
      final boundary =
          screenshotKey.currentContext!.findRenderObject()!
              as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: ratio);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      final file = File(
        p.join(dir.path, '${_frames.length.toString().padLeft(4, '0')}.rgba'),
      );
      await file.writeAsBytes(bytes!.buffer.asUint8List());
      _frames.add({'t': t, 'w': image.width, 'h': image.height});
      image.dispose();
    });
  }

  void save() =>
      File(p.join(dir.path, 'frames.json'))
          .writeAsStringSync(jsonEncode(_frames));
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
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  testWidgets('README media (Kenney CC0 packs)', (tester) async {
    if (!_enabled || !Directory(kenneySource).existsSync()) {
      markTestSkipped('README_MEDIA not set or no real library');
      return;
    }
    final realMtime = Directory(kenneySource).statSync().modified;
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final tmp = Directory.systemTemp.createTempSync('readme');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final lib = p.join(tmp.path, 'library');
    final kenney = p.join(lib, 'Kenney');
    Directory(kenney).createSync(recursive: true);
    File(p.join(kenney, 'ASSET_AUTHOR.txt')).writeAsStringSync(
      'user: Kenney\n'
      'url: https://kenney.nl/\n'
      'license: CC0 1.0 Universal (public domain)\n'
      'credit: Kenney (www.kenney.nl)\n',
    );
    final stripsByPack = strips();
    for (final MapEntry(key: rel, value: (types, tags)) in packs.entries) {
      final name = p.basename(rel);
      final dest = p.join(kenney, name);
      copyTree(p.join(kenneySource, rel), dest);
      File(p.join(dest, 'asset_pack.json')).writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert({
          'title': name,
          'types': types,
          'tags': tags,
          'source': 'imported',
          if (gamePacks.contains(name)) 'used_in': [game],
          if (favoritePacks.contains(name)) 'favorite': true,
          'cover': ?covers[name],
        }),
      );
      for (final MapEntry(key: out, value: frames)
          in (stripsByPack[name] ?? const <String, List<String>>{}).entries) {
        final present = [
          for (final f in frames)
            if (File(p.join(dest, f)).existsSync()) f,
        ];
        if (present.length < 2) continue;
        combineFrames(dest, present, out);
      }
    }
    final importSrc = p.join(tmp.path, 'downloads');
    File(p.join(importSrc, 'Kenney', 'ASSET_AUTHOR.txt'))
      ..createSync(recursive: true)
      ..writeAsStringSync('user: Kenney\nurl: https://kenney.nl/\n');
    for (final rel in importPacks) {
      copyTree(
        p.join(kenneySource, rel),
        p.join(importSrc, 'Kenney', p.basename(rel)),
      );
    }

    final store = SettingsStore(File(p.join(tmp.path, 'settings.json')));
    Widget app() => screenshotable(
      ProviderScope(
        overrides: [
          settingsStoreProvider.overrideWithValue(store),
          libraryIndexProvider.overrideWithValue(
            LibraryIndex(NativeDatabase.memory()),
          ),
          directoryPickerProvider.overrideWithValue((_) async => importSrc),
          keyStoreProvider.overrideWithValue(_NoKey()),
          envKeyProvider.overrideWithValue(() => null),
          revealProvider.overrideWithValue((_) async {}),
          saveLocationProvider.overrideWithValue(
            (name) async => p.join(tmp.path, name),
          ),
        ],
        child: const LootSiloApp(),
      ),
    );
    Future<void> start(AppSettings settings) async {
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      store.save(settings);
      await tester.pumpWidget(app());
      await pumpUntil(tester, find.text('Platformer Pack Redux'));
      await wait(tester, 2500);
    }

    final base = AppSettings(
      libraryPath: lib,
      theme: ThemeChoice.light,
      resumeSession: false,
    );
    final title = find.text;
    Future<void> openPack(String name) async {
      await tester.tap(title(name).first);
      await pumpUntil(tester, find.byType(TabBar));
      await wait(tester, 1500);
    }

    Future<void> back() async {
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await wait(tester, 800);
    }

    // 1. The dashboard, every preview playing.
    await start(base.copyWith(animateAll: true));
    await shot(tester, 'dashboard');

    // 2. GIF: previews play while the pointer is over a tile.
    await start(base);
    final pointer = await tester.createGesture(kind: PointerDeviceKind.mouse);
    mouse = pointer;
    await pointer.addPointer(location: const Offset(720, 20));
    addTearDown(pointer.removePointer);
    final animated = [
      'Tappy Plane',
      'Platformer Assets Extra Animations & Enemies',
      'Explosion Pack',
      'Roguelike Characters Pack',
    ];
    final hover = Recorder('hover');
    for (final name in animated) {
      if (title(name).evaluate().isEmpty) continue;
      await pointer.moveTo(
        tester.getCenter(title(name).first) - const Offset(0, 90),
      );
      await hover.record(tester, const Duration(milliseconds: 1800));
    }
    hover.save();
    await pointer.moveTo(const Offset(720, 20));

    // 3. GIF: the search narrows the dashboard as you type.
    final search = Recorder('search');
    final field = find.byType(TextField).first;
    await tester.tap(field);
    await search.record(tester, const Duration(milliseconds: 700));
    var typed = '';
    for (final c in 'plat'.split('')) {
      typed += c;
      await tester.enterText(field, typed);
      await search.record(tester, const Duration(milliseconds: 900));
    }
    await search.record(tester, const Duration(milliseconds: 1200));
    await tester.enterText(field, '');
    typed = '';
    for (final c in 'sounds'.split('')) {
      typed += c;
      await tester.enterText(field, typed);
      await search.record(tester, const Duration(milliseconds: 450));
    }
    await search.record(tester, const Duration(milliseconds: 1500));
    search.save();
    await tester.enterText(field, '');
    await wait(tester, 1000);

    // 4. GIF: the thumbnail size slider and its end icons.
    final slider = find.byKey(const ValueKey('dashboard-size-slider'));
    final sizes = Recorder('slider');
    await sizes.record(tester, const Duration(milliseconds: 600));
    for (final (tip, n) in [('Smaller', 4), ('Larger', 8), ('Smaller', 4)]) {
      for (var i = 0; i < n; i++) {
        await tester.tap(
          find.descendant(of: slider, matching: find.byTooltip(tip)),
        );
        await sizes.record(tester, const Duration(milliseconds: 350));
      }
      await sizes.record(tester, const Duration(milliseconds: 500));
    }
    sizes.save();

    // 5. GIF: open a pack and switch its tabs.
    final tabs = Recorder('open_pack');
    await tabs.record(tester, const Duration(milliseconds: 500));
    await tester.tap(
      title('Platformer Assets Extra Animations & Enemies').first,
    );
    await tabs.record(tester, const Duration(milliseconds: 2200));
    for (final tab in ['Images (', 'Animations (', 'Files (']) {
      final t = find.textContaining(tab);
      if (t.evaluate().isEmpty) continue;
      await tester.tap(t.first);
      await tabs.record(tester, const Duration(milliseconds: 1600));
    }
    tabs.save();
    await back();

    // 6. Pack detail: images.
    await openPack('Platformer Pack Redux');
    await tester.tap(find.textContaining('Images (').first);
    await wait(tester, 2500);
    await shot(tester, 'pack_images');

    // 7. The image viewer: Tappy Plane's background at 1:1.
    await back();
    await openPack('Tappy Plane');
    await tester.tap(find.textContaining('Images (').first);
    await wait(tester, 1500);
    await tester.enterText(find.byType(TextField).first, 'background');
    await wait(tester, 1500);
    final card = find.byKey(const ValueKey('image:PNG/background.png'));
    await pointer.moveTo(tester.getCenter(card));
    await tester.pump();
    await tester.tap(
      find.descendant(of: card, matching: find.byTooltip('Open image')),
    );
    await pumpUntil(tester, find.byType(ImageViewer));
    await wait(tester, 1500);
    await shot(tester, 'viewer');
    await back();
    await back();
    await pointer.moveTo(const Offset(720, 20));

    // 8. Animations tab, then GIF: focus mode and the Edit dialog.
    await openPack('Platformer Assets Extra Animations & Enemies');
    await tester.tap(find.textContaining('Animations (').first);
    await wait(tester, 2500);
    await pointer.moveTo(const Offset(720, 20));
    await shot(tester, 'animations');
    final cards = find.byType(AnimatedSprite);
    final focus = Recorder('focus_edit');
    await focus.record(tester, const Duration(milliseconds: 800));
    await tester.tap(cards.at(2));
    await focus.record(tester, const Duration(milliseconds: 1500));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await focus.record(tester, const Duration(milliseconds: 1000));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await focus.record(tester, const Duration(milliseconds: 1000));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await focus.record(tester, const Duration(milliseconds: 600));
    final walk = find.byKey(const ValueKey('Alien sprites/alienBlue_walk.png'));
    await pointer.moveTo(tester.getCenter(walk));
    await focus.record(tester, const Duration(milliseconds: 700));
    await tester.tap(
      find.descendant(of: walk, matching: find.byTooltip('Edit animation')),
    );
    await focus.record(tester, const Duration(milliseconds: 3000));
    expect(find.byType(Dialog), findsOneWidget);
    focus.save();
    await back();
    await pointer.moveTo(const Offset(720, 20));
    await back();

    // 9. Audio.
    await openPack('Music loops (30 files)');
    await wait(tester, 2000);
    await shot(tester, 'audio');
    await back();

    // 10. Two pack tabs side by side in the tab strip.
    for (final name in ['Tappy Plane', 'Space Shooter Pack']) {
      await tester.tap(title(name).first, buttons: kMiddleMouseButton);
      await wait(tester, 800);
    }
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await wait(tester, 2000);
    await shot(tester, 'tabs');

    // 11. Credits for the game.
    await start(base);
    await tester.tap(find.byTooltip('Credits'));
    await pumpUntil(tester, find.byType(CreditsScreen));
    await wait(tester, 1500);
    if (find.text(game).evaluate().isNotEmpty) {
      await tester.tap(find.text(game).first);
      await wait(tester, 1000);
    }
    await shot(tester, 'credits');
    await back();

    // 12. The folder import review.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyI);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await pumpUntil(tester, find.textContaining('Import 2 packs'));
    await wait(tester, 1500);
    await shot(tester, 'import_review');
    await back();

    // 13. Dark theme in another colour.
    await start(
      base.copyWith(
        theme: ThemeChoice.dark,
        themeColor: ThemeColor.indigo,
        animateAll: true,
      ),
    );
    await shot(tester, 'dashboard_dark');

    // 14. The colour swatches.
    await tester.tap(find.byTooltip('Settings (Ctrl+,)'));
    await wait(tester, 1500);
    await shot(tester, 'settings_theme');
    await back();

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(Directory(kenneySource).statSync().modified, realMtime);
  });
}
