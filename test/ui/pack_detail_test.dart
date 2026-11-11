import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:loot_silo/core/audio_peaks.dart';
import 'package:loot_silo/core/library_index.dart';
import 'package:loot_silo/core/model_cache.dart';
import 'package:loot_silo/core/sidecar.dart';
import 'package:loot_silo/core/type_classifier.dart';
import 'package:loot_silo/state/itch.dart';
import 'package:loot_silo/state/dashboard.dart';
import 'package:loot_silo/state/folder_folds.dart';
import 'package:loot_silo/state/providers.dart';
import 'package:loot_silo/state/settings.dart';
import 'package:loot_silo/ui/app.dart';
import 'package:loot_silo/core/audio_duration.dart';
import 'package:loot_silo/core/audio_formats.dart' show AudioSort;
import 'package:loot_silo/ui/clipboard.dart';
import 'package:loot_silo/ui/format.dart';
import 'package:loot_silo/ui/help_screen.dart';
import 'package:loot_silo/ui/image_viewer.dart';
import 'package:loot_silo/ui/material_viewer.dart';
import 'package:loot_silo/ui/model_viewer.dart';
import 'package:loot_silo/ui/pack_detail_screen.dart';
import 'package:loot_silo/ui/reveal.dart';
import 'package:loot_silo/ui/settings_screen.dart';
import 'package:loot_silo/ui/tabs.dart';
import 'package:loot_silo/ui/dashboard.dart';
import 'package:loot_silo/ui/folder_groups.dart';
import 'package:loot_silo/ui/track_player.dart';
import 'package:loot_silo/ui/widgets/favorite_star.dart';
import 'package:loot_silo/ui/widgets/animated_sprite.dart';
import 'package:loot_silo/ui/widgets/file_menu.dart';
import 'package:loot_silo/ui/widgets/item_card.dart';
import 'package:loot_silo/ui/widgets/measure_size.dart';
import 'package:loot_silo/ui/widgets/overflow_text.dart';
import 'package:loot_silo/ui/widgets/format_chips.dart';
import 'package:loot_silo/ui/widgets/project_links.dart';
import 'package:loot_silo/version.dart';
import 'package:loot_silo/ui/widgets/pack_tile.dart';
import 'package:loot_silo/ui/widgets/tab_toolbar.dart';
import 'package:loot_silo/ui/widgets/thumb_size.dart';
import 'package:loot_silo/ui/widgets/waveform.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import '../helpers/models.dart';
import '../helpers/fonts.dart';
import '../helpers/fs.dart';

class _NoKey implements KeyStore {
  @override
  Future<String?> read() async => null;
  @override
  Future<void> write(String key) async {}
  @override
  Future<void> delete() async {}
}

/// Records calls; tests push positions, lengths and completions.
class _FakePlayer implements TrackPlayer {
  final played = <String>[];
  final seeks = <Duration>[];
  var stops = 0;
  @override
  var looping = false;
  final position = StreamController<Duration>.broadcast();
  final length = StreamController<Duration>.broadcast();
  final complete = StreamController<void>.broadcast();

  @override
  Future<void> play(String path) async => played.add(path);
  @override
  Future<void> stop() async => stops++;
  @override
  Future<void> seek(Duration to) async => seeks.add(to);
  @override
  Future<void> setLoop(bool loop) async => looping = loop;
  @override
  Stream<Duration> get onPosition => position.stream;
  @override
  Stream<Duration> get onDuration => length.stream;
  @override
  Stream<void> get onComplete => complete.stream;
  var disposed = false;
  @override
  Future<void> dispose() async => disposed = true;
}

/// Records clipboard and open calls.
class _FakeClipboard implements FileClipboard {
  _FakeClipboard({this.linux = true});

  final bool linux;
  final calls = <String>[];

  @override
  bool get canCopyFiles => linux;
  @override
  bool get canOpenWith => linux;
  @override
  Future<void> copyImage(String path) async => calls.add('image:$path');
  @override
  Future<void> copyFiles(List<String> paths) async =>
      calls.add('files:${paths.join('|')}');

  /// The last [copyBytes] data.
  Uint8List? bytes;
  @override
  Future<void> copyBytes(String mime, Uint8List bytes) async {
    this.bytes = bytes;
    calls.add('bytes:$mime ${bytes.length}');
  }

  @override
  Future<void> copyText(String text) async => calls.add('text:$text');
  @override
  Future<void> open(String path) async => calls.add('open:$path');
  @override
  Future<bool> openWith(String path) async {
    calls.add('openWith:$path');
    return true;
  }
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late Directory tmp;
  late SettingsStore store;
  setUp(() => tmp = Directory.systemTemp.createTempSync('detail'));
  tearDown(() => tmp.deleteSync(recursive: true));

  /// Real IO (scan, isolates) needs real time between frames.
  Future<void> pumpUntil(WidgetTester tester, Finder finder) async {
    for (var i = 0; i < 200 && finder.evaluate().isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    expect(finder, findsWidgets);
  }

  /// [pumpUntil] the other way: until nothing matches [finder].
  Future<void> pumpUntilGone(WidgetTester tester, Finder finder) async {
    for (var i = 0; i < 200 && finder.evaluate().isNotEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    expect(finder, findsNothing);
  }

  /// Opens Knight Pack, with images in the root and two sub-folders.
  Future<void> openKnight(
    WidgetTester tester, {
    // Wide enough for the dashboard's top row in the test font, whose
    // glyphs are about twice as wide as the app's.
    Size size = const Size(1600, 900),
    List<String> files = const [
      'heroes/knight_red/a.png',
      'heroes/knight_red/b.png',
      'heroes/archer/c.png',
      'heroes/archer/d.png',
      'z_root.png',
    ],
    bool open = true,
    Map<String, img.Image> images = const {},
    Map<String, List<int>> raw = const {},
    // Files written into the Slimes pack.
    Map<String, List<int>> slimes = const {},
    List<String>? types,
    Map<String, Object?> sidecar = const {},
    List<Override> overrides = const [],
    // Changes the settings saved before the app starts.
    AppSettings Function(AppSettings)? settings,
  }) async {
    final lib = p.join(tmp.path, 'library');
    copyTree('test/fixtures/managed', lib);
    final pack = p.join(lib, 'HeroMaker', 'Knight Pack');
    for (final rel in files) {
      File(p.join(pack, rel))
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(img.encodePng(img.Image(width: 8, height: 8)));
    }
    for (final MapEntry(key: rel, value: bytes) in slimes.entries) {
      File(p.join(lib, 'HeroMaker', 'Slimes', rel))
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(bytes);
    }
    for (final MapEntry(key: rel, value: bytes) in raw.entries) {
      File(p.join(pack, rel))
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(bytes);
    }
    if (types != null || sidecar.isNotEmpty) {
      final file = File(p.join(pack, 'asset_pack.json'));
      final json = jsonDecode(file.readAsStringSync()) as Map;
      file.writeAsStringSync(
        jsonEncode({...json, 'types': ?types, ...sidecar}),
      );
    }
    for (final MapEntry(key: rel, value: image) in images.entries) {
      File(p.join(pack, rel))
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(img.encodePng(image));
    }
    store = SettingsStore(File(p.join(tmp.path, 'settings.json')))
      ..save((settings ?? (s) => s)(AppSettings(libraryPath: lib)));
    final index = LibraryIndex(NativeDatabase.memory());
    addTearDown(index.close);
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsStoreProvider.overrideWithValue(store),
          libraryIndexProvider.overrideWithValue(index),
          keyStoreProvider.overrideWithValue(_NoKey()),
          envKeyProvider.overrideWithValue(() => null),
          ...overrides,
        ],
        child: const LootSiloApp(),
      ),
    );
    await pumpUntil(tester, find.text('Knight Pack'));
    if (!open) return;
    await tester.tap(find.text('Knight Pack'));
    await pumpUntil(tester, find.byType(TabBar));
    // Let the page finish sliding in.
    await tester.pump(const Duration(seconds: 1));
  }

  /// Hovers the first animation card: its icons take clicks only then.
  Future<void> hoverCard(WidgetTester tester) async {
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(
      location: tester.getCenter(
        find.ancestor(
          of: find.byTooltip('Edit animation'),
          matching: find.byType(Card),
        ),
      ),
    );
    addTearDown(mouse.removePointer);
    await tester.pump();
  }

  /// Opens image [rel] in the viewer through its card's Open image icon
  /// (a click focuses the card since M40).
  Future<void> openImage(WidgetTester tester, String rel) async {
    final card = find.byKey(ValueKey('image:$rel'));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: tester.getCenter(card));
    await tester.pump();
    await tester.tap(
      find.descendant(of: card, matching: find.byTooltip('Open image')),
    );
    await mouse.removePointer();
  }

  testWidgets('unpinned header is a slim bar; hover shows it floating', (
    tester,
  ) async {
    await openKnight(tester);
    expect(find.text('Hover for details'), findsNothing);
    final tabsTop = tester.getTopLeft(find.byType(TabBar)).dy;

    await tester.tap(find.byTooltip('Unpin header — show it on hover (H)'));
    await tester.pump();
    expect(store.load().detailHeaderPinned, isFalse);
    expect(find.text('Hover for details'), findsOneWidget);
    expect(find.text('Used in'), findsNothing);
    final unpinnedTop = tester.getTopLeft(find.byType(TabBar)).dy;
    expect(unpinnedTop, lessThan(tabsTop - 200));

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(700, 890));
    addTearDown(mouse.removePointer);
    // Passing over it quickly (on the way to a tab) doesn't open it (M36).
    await mouse.moveTo(tester.getCenter(find.text('Hover for details')));
    await tester.pump(headerHoverDelay - const Duration(milliseconds: 100));
    expect(find.text('Used in'), findsNothing);
    await mouse.moveTo(const Offset(700, 890));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Used in'), findsNothing, reason: 'left before the delay');
    // Resting on it opens it after the delay.
    await mouse.moveTo(tester.getCenter(find.text('Hover for details')));
    await tester.pump(headerHoverDelay - const Duration(milliseconds: 100));
    expect(find.text('Used in'), findsNothing);
    await tester.pump(const Duration(milliseconds: 150));
    expect(find.text('Used in'), findsOneWidget);
    // Floating: the tabs didn't move.
    expect(tester.getTopLeft(find.byType(TabBar)).dy, unpinnedTop);
    await mouse.moveTo(const Offset(700, 890));
    await tester.pump();
    expect(find.text('Used in'), findsNothing);

    // H pins it again.
    await tester.sendKeyEvent(LogicalKeyboardKey.keyH);
    await tester.pump();
    expect(store.load().detailHeaderPinned, isTrue);
    expect(find.text('Used in'), findsOneWidget);
    expect(find.text('Hover for details'), findsNothing);
  });

  testWidgets('images by folder; the viewer follows the grouped order', (
    tester,
  ) async {
    await openKnight(tester, size: const Size(1600, 1600));
    await tester.tap(find.textContaining('Images ('));
    await tester.pumpAndSettle();
    await tester.tap(find.text('By folder'));
    await tester.pump();
    expect(store.load().imagesView, ItemsView.folders);
    expect(find.text('Pack root'), findsOneWidget);
    expect(find.text('Heroes / Archer'), findsOneWidget);
    expect(find.text('Heroes / Knight red'), findsOneWidget);

    // Root: knight.png, z_root.png; archer/c, d; knight_red/a, b.
    await openImage(tester, 'z_root.png');
    await tester.pumpAndSettle();
    expect(find.text('2 / 6'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(
      find.descendant(of: find.byType(ImageViewer), matching: find.text('C')),
      findsOneWidget,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(ImageViewer), findsNothing);

    // Folding a folder takes its images out of the viewer's list.
    await tester.tap(find.text('Heroes / Archer'));
    await tester.pump();
    await openImage(tester, 'heroes/knight_red/a.png');
    await tester.pumpAndSettle();
    expect(find.text('3 / 4'), findsOneWidget);
  });

  testWidgets('expanded tiles open the pack at their folder', (tester) async {
    await openKnight(
      tester,
      files: ['Archer/c.png', 'Archer/d.png', 'Mage/e.png'],
      open: false,
    );
    expect(find.text('Archer'), findsNothing);
    await tester.tap(find.text('Expanded'));
    await pumpUntil(tester, find.text('Mage'));
    expect(store.load().dashboardView, DashboardView.expanded);
    expect(find.text('Archer'), findsOneWidget);
    // The pack title is the folder tiles' subtitle.
    expect(find.text('Knight Pack'), findsNWidgets(2));

    await tester.tap(find.text('Mage'));
    await pumpUntil(tester, find.textContaining('Images ('));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Images (1)'), findsOneWidget);
    expect(find.byTooltip('Show the whole pack'), findsOneWidget);
    await tester.tap(find.textContaining('Images ('));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('image:Mage/e.png')), findsOneWidget);
    expect(find.byKey(const ValueKey('image:Archer/c.png')), findsNothing);

    await tester.tap(find.text('Show whole pack'));
    await tester.pumpAndSettle();
    expect(find.text('Images (4)'), findsOneWidget);
    expect(find.byTooltip('Show the whole pack'), findsNothing);
  });

  testWidgets('sorting by tags adds each tile\'s tags, sorted', (tester) async {
    await openKnight(tester, open: false);
    expect(find.textContaining('No tags'), findsNothing);
    await tester.tap(find.byType(DropdownButton<PackSort>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Tags').last);
    await tester.pumpAndSettle();
    final tags = tester.widget<Text>(
      find
          .descendant(
            of: find.byType(PackTile),
            matching: find.byWidgetPredicate(
              (w) => w is Text && (w.data ?? '').contains(','),
            ),
          )
          .first,
    );
    expect(tags.data, 'knight, pixel-art');
    // The type chips stay.
    expect(
      find.descendant(
        of: find.byType(PackTile),
        matching: find.text('character'),
      ),
      findsWidgets,
    );
    final shown = tags.data!.split(', ');
    expect(shown, sortedTags(shown));
  });

  testWidgets('Type sort orders tiles; chips show sorted types', (
    tester,
  ) async {
    await openKnight(
      tester,
      open: false,
      files: const [],
      types: ['vfx', 'character', 'environment'],
    );
    await tester.tap(find.byType(DropdownButton<PackSort>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Type').last);
    await tester.pumpAndSettle();
    final knight = find.ancestor(
      of: find.text('Knight Pack'),
      matching: find.byType(PackTile),
    );
    final chips = [
      for (final t in ['character', 'environment', 'vfx'])
        tester
            .getTopLeft(find.descendant(of: knight, matching: find.text(t)))
            .dx,
    ];
    expect(chips, orderedEquals([...chips]..sort()));
    // Tiles follow the type keys.
    final titles = [
      for (final e in find.byType(PackTile).evaluate())
        (e.widget as PackTile).pack,
    ];
    final keys = [for (final p in titles) typeSortKey(p.types) ?? '\uffff'];
    expect(keys, orderedEquals([...keys]..sort()));
  });

  testWidgets('Frames field re-slices a strip; numbered props are images', (
    tester,
  ) async {
    // A 24-cell strip that really holds 16 frames of 24 px, plus numbered
    // props without an animation word.
    final strip = img.Image(width: 384, height: 16, numChannels: 4);
    img.fill(strip, color: img.ColorRgba8(200, 80, 40, 255));
    await openKnight(
      tester,
      files: [for (var i = 0; i < 4; i++) 'props/barrels_$i.png'],
      images: {'Animated stuff/chimney-smoke.png': strip},
    );
    expect(find.textContaining('Animations (1)'), findsOneWidget);
    await tester.tap(find.textContaining('Animations ('));
    await tester.pump(const Duration(milliseconds: 500));
    await hoverCard(tester);
    await tester.tap(find.byTooltip('Edit animation'));
    await pumpUntil(tester, find.text('Apply size'));
    expect(find.text('Sheet · 16×16 frames · 24 × 1 · 24 frames'), findsOne);

    final frames = find.widgetWithText(TextField, 'Frames');
    // More frames than pixels allow: no grid fits.
    await tester.enterText(frames, '600');
    await tester.pump();
    expect(find.text("Doesn't fit 384×16 px"), findsOneWidget);
    expect(find.text('Sheet · 16×16 frames · 24 × 1 · 24 frames'), findsOne);

    await tester.enterText(frames, '16');
    await tester.pump();
    expect(find.text("Doesn't fit 384×16 px"), findsNothing);
    expect(find.text('Sheet · 24×16 frames · 16 × 1 · 16 frames'), findsOne);
    expect(
      tester
          .widget<TextField>(find.widgetWithText(TextField, 'Frame width'))
          .controller!
          .text,
      '24',
    );

    await tester.tap(find.text('Save'));
    await pumpUntil(tester, find.text('Reset to detected'));
    final sidecar = File(
      p.join(
        tmp.path,
        'library',
        'HeroMaker',
        'Knight Pack',
        'asset_pack.json',
      ),
    ).readAsStringSync();
    expect(sidecar, contains('"frames": 16'));
    expect(sidecar, isNot(contains('frame_w')));
  });

  testWidgets('Edit dialog: selectable title/path, copy, open image on top', (
    tester,
  ) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    final strip = img.Image(width: 64, height: 16, numChannels: 4);
    img.fill(strip, color: img.ColorRgba8(40, 120, 200, 255));
    await openKnight(
      tester,
      files: const [],
      images: {'fx/smoke_strip.png': strip},
    );
    await tester.tap(find.textContaining('Animations ('));
    await tester.pump(const Duration(milliseconds: 500));
    await hoverCard(tester);
    await tester.tap(find.byTooltip('Edit animation'));
    await pumpUntil(tester, find.text('Apply size'));
    final dialog = find.byType(Dialog);
    expect(
      find.descendant(
        of: dialog,
        matching: find.widgetWithText(SelectableText, 'Smoke strip'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: dialog,
        matching: find.widgetWithText(SelectableText, 'fx/smoke_strip.png'),
      ),
      findsOneWidget,
    );

    await tester.tap(find.byTooltip('Copy relative path'));
    await tester.pump();
    expect(copied, 'fx/smoke_strip.png');
    await tester.tap(find.byTooltip('Copy full path'));
    await tester.pump();
    expect(copied, endsWith('Knight Pack/fx/smoke_strip.png'));
    expect(p.isAbsolute(copied!), isTrue);

    await tester.tap(
      find.descendant(of: dialog, matching: find.byTooltip('Open image')),
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(ImageViewer), findsOneWidget);
    // Esc closes the viewer first, then the dialog.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(ImageViewer), findsNothing);
    expect(find.text('Apply size'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('Apply size'), findsNothing);
    expect(find.textContaining('Animations ('), findsOneWidget);
  });

  group('Image cards (M40)', () {
    Finder card(String rel) => find.byKey(ValueKey('image:$rel'));
    ItemCard cardOf(WidgetTester tester, String rel) =>
        tester.widget<ItemCard>(card(rel));
    String? focused(WidgetTester tester) => [
      for (final e in find.byType(ItemCard).evaluate())
        if ((e.widget as ItemCard).focused) (e.widget as ItemCard).path,
    ].singleOrNull;

    Future<void> openImagesTab(WidgetTester tester) async {
      await openKnight(tester);
      await tester.tap(find.textContaining('Images ('));
      await tester.pumpAndSettle();
    }

    Future<TestGesture> hoverCard(WidgetTester tester, String rel) async {
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: tester.getCenter(card(rel)));
      addTearDown(mouse.removePointer);
      await tester.pump();
      return mouse;
    }

    testWidgets('a click focuses; arrows move; Esc, back, empty space leave', (
      tester,
    ) async {
      await openImagesTab(tester);
      await tester.tap(card('z_root.png'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(focused(tester), 'z_root.png');
      expect(find.byType(ImageViewer), findsNothing);
      expect(cardOf(tester, 'heroes/archer/c.png').dimmed, isTrue);
      expect(cardOf(tester, 'z_root.png').dimmed, isFalse);

      // ←/→ follow the on-screen order (Flat: sorted paths).
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      final before = focused(tester);
      expect(before, isNot('z_root.png'));
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(focused(tester), 'z_root.png');

      // Esc leaves focus mode; the page stays.
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(focused(tester), isNull);
      expect(find.byType(PackDetailScreen), findsOneWidget);

      // The mouse back button too, before it would close the page.
      await tester.tap(card('z_root.png'));
      await tester.pump(const Duration(milliseconds: 300));
      final back = await tester.startGesture(
        const Offset(5, 895),
        kind: PointerDeviceKind.mouse,
        buttons: kBackMouseButton,
      );
      await back.up();
      await tester.pump(const Duration(milliseconds: 300));
      expect(focused(tester), isNull);
      expect(find.byType(PackDetailScreen), findsOneWidget);

      // A click on the focused card, or on empty space, leaves it too.
      await tester.tap(card('z_root.png'));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(card('z_root.png'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(focused(tester), isNull);
      await tester.tap(card('z_root.png'));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tapAt(const Offset(1300, 880));
      await tester.pump(const Duration(milliseconds: 300));
      expect(focused(tester), isNull);
    });

    testWidgets('M64: a double-click opens the viewer; Ctrl never does', (
      tester,
    ) async {
      await openImagesTab(tester);
      // A single click only focuses.
      await tester.tap(card('heroes/archer/c.png'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(focused(tester), 'heroes/archer/c.png');
      expect(find.byType(ImageViewer), findsNothing);
      // Two clicks on another card, soon after each other: the viewer, on
      // that image, with the card focused.
      await tester.tap(card('z_root.png'));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(card('z_root.png'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(ImageViewer), findsOneWidget);
      final viewer = tester.widget<ImageViewer>(find.byType(ImageViewer));
      expect(viewer.images[viewer.initialIndex], 'z_root.png');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(ImageViewer), findsNothing);
      expect(focused(tester), 'z_root.png');

      // Ctrl-double-click selects and unselects, without the viewer.
      await tester.pump(const Duration(seconds: 1));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.tap(card('heroes/archer/d.png'));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(card('heroes/archer/d.png'));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(ImageViewer), findsNothing);
      // Two clicks far apart are two single clicks.
      await tester.tap(card('heroes/archer/d.png'));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(card('heroes/archer/d.png'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(ImageViewer), findsNothing);
      expect(focused(tester), isNull);
    });

    testWidgets('Open image starts the viewer at that image', (tester) async {
      await openImagesTab(tester);
      await openImage(tester, 'z_root.png');
      await pumpUntil(tester, find.byType(ImageViewer));
      final viewer = tester.widget<ImageViewer>(find.byType(ImageViewer));
      expect(viewer.images[viewer.initialIndex], 'z_root.png');
    });

    testWidgets('star top right, footer size, icons all one size', (
      tester,
    ) async {
      await openImagesTab(tester);
      final rel = 'z_root.png';
      // Footer: pretty title and the image size.
      expect(
        find.descendant(of: card(rel), matching: find.text('Z root')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: card(rel), matching: find.text('8×8')),
        findsOneWidget,
      );
      final star = find.byKey(const ValueKey('star:z_root.png'));
      expect(star, findsNothing);
      await hoverCard(tester, rel);
      expect(star, findsOneWidget);
      // Top right of the card.
      final box = tester.getRect(card(rel));
      final at = tester.getRect(star);
      expect(at.right, greaterThan(box.right - 40));
      expect(at.top, lessThan(box.top + 40));
      await tester.tap(star);
      await tester.pump();
      expect(cardOf(tester, rel).starred, isTrue);

      Size icon(String tooltip) => tester.getSize(
        find.descendant(of: card(rel), matching: find.byTooltip(tooltip)),
      );
      final open = icon('Open image');
      expect(icon('Make animation…'), open);
      expect(icon('Show in file manager'), open);
    });

    testWidgets('Ctrl-click selects without focusing', (tester) async {
      await openImagesTab(tester);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.tap(card('z_root.png'));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(find.text('1 selected'), findsOneWidget);
      expect(focused(tester), isNull);
      expect(cardOf(tester, 'z_root.png').selected, isTrue);
      // A plain click focuses and leaves the selection as it is.
      await tester.tap(card('heroes/archer/c.png'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(focused(tester), 'heroes/archer/c.png');
      expect(find.text('1 selected'), findsOneWidget);
    });
  });

  group('Quick UI fixes (M39)', () {
    final tone = File('test/fixtures/audio/tone.wav').readAsBytesSync();

    testWidgets('search box and Favorites chip have one height', (
      tester,
    ) async {
      await openKnight(tester);
      final search = find.widgetWithText(TextField, 'Search files');
      final chip = find.byKey(const ValueKey('detail-favorites-chip'));
      final field = tester.getRect(search);
      expect(field.height, detailControlHeight);
      expect(tester.getSize(chip).height, detailControlHeight);
      expect(tester.getRect(chip).center.dy, field.center.dy);
      // Typing shows the clear button; the height stays.
      await tester.enterText(search, 'knight');
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.getSize(search).height, detailControlHeight);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Loop is shaped like Play all', (tester) async {
      await openKnight(
        tester,
        files: const [],
        raw: {'theme.wav': tone},
        types: ['music'],
      );
      final play = find.byKey(const ValueKey('play-all'));
      final loop = find.byKey(const ValueKey('loop'));
      expect(tester.widget(play).runtimeType, tester.widget(loop).runtimeType);
      expect(tester.getSize(loop).height, tester.getSize(play).height);
      expect(tester.getRect(loop).center.dy, tester.getRect(play).center.dy);
      ShapeBorder? shape(Finder f) => tester
          .widget<Material>(
            find.descendant(of: f, matching: find.byType(Material)).first,
          )
          .shape;
      expect(shape(loop), shape(play));
      // A toggle: on is saved, and the shape stays.
      await tester.tap(loop);
      await tester.pump();
      expect(store.load().audioLoop, isTrue);
      expect(shape(loop), shape(play));
    });

    testWidgets('Settings: Help sits right above About', (tester) async {
      await openKnight(tester, open: false);
      await tester.tap(find.byTooltip('Settings (Ctrl+,)'));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.scrollUntilVisible(
        find.text('About'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      final shortcuts = tester.getTopLeft(find.text('Keyboard shortcuts')).dy;
      final help = tester.getTopLeft(find.text('Help')).dy;
      final entry = tester.getTopLeft(find.text('How Loot Silo works')).dy;
      final about = tester.getTopLeft(find.text('About')).dy;
      expect(shortcuts, lessThan(help));
      expect(help, lessThan(entry));
      expect(entry, lessThan(about));
    });

    testWidgets('dashboard slider is wide enough for its dots', (tester) async {
      await openKnight(tester, open: false);
      final slider = find.descendant(
        of: find.byType(ThumbSizeSlider),
        matching: find.byType(Slider),
      );
      final s = tester.widget<Slider>(slider);
      // M79: one division per column count that fits the grid.
      expect(s.divisions, greaterThan(2));
      // Flutter paints the dots only when they are at least three reported
      // dot widths apart, on the track inside 24 px of thumb room a side,
      // less the 4 px track height.
      final theme = SliderTheme.of(tester.element(slider));
      final dot = theme.tickMarkShape!
          .getPreferredSize(sliderTheme: theme, isEnabled: true)
          .width;
      final track = tester.getSize(slider).width - 2 * 24 - 4;
      expect(track / s.divisions!, greaterThanOrEqualTo(3 * dot));
      expect(tester.takeException(), isNull);
    });

    testWidgets('M64: the slim bar shows the title; facts are cut first', (
      tester,
    ) async {
      await openKnight(
        tester,
        size: const Size(1024, 800),
        types: [for (final t in AssetType.values) t.id],
      );
      tester.takeException();
      await tester.tap(find.byTooltip('Unpin header — show it on hover (H)'));
      await tester.pump();
      final title = find.byKey(const ValueKey('slim-title'));
      expect(tester.widget<Text>(title).data, 'Knight Pack');
      bool cut(Finder f) => tester
          .renderObject<RenderParagraph>(
            find.descendant(of: f, matching: find.byType(RichText)),
          )
          .didExceedMaxLines;
      expect(cut(title), isFalse);
      expect(cut(find.byKey(const ValueKey('slim-facts'))), isTrue);
      expect(find.text('Hover for details'), findsOneWidget);
      // The title comes before the facts, after the star.
      expect(
        tester.getTopLeft(title).dx,
        lessThan(
          tester.getTopLeft(find.byKey(const ValueKey('slim-facts'))).dx,
        ),
      );
    });

    for (final width in [1024.0, 1800.0]) {
      testWidgets('slim bar icons at the far right (${width.round()} px)', (
        tester,
      ) async {
        await openKnight(tester, size: Size(width, 800));
        tester.takeException();
        await tester.tap(find.byTooltip('Unpin header — show it on hover (H)'));
        await tester.pump();
        final bar = tester.getRect(
          find
              .ancestor(
                of: find.text('Hover for details'),
                matching: find.byType(Container),
              )
              .first,
        );
        final icons = tester.getRect(
          find.byKey(const ValueKey('header-actions')),
        );
        // The bar's right padding is 8 px.
        expect(icons.right, closeTo(bar.right - 8, 0.5));
      });
    }
  });

  group('Audio tab', () {
    final tone = File('test/fixtures/audio/tone.wav').readAsBytesSync();

    int tabIndex(WidgetTester tester) =>
        DefaultTabController.of(tester.element(find.byType(TabBar))).index;

    testWidgets('music / sfx packs open on Audio; mixed packs do not', (
      tester,
    ) async {
      await openKnight(
        tester,
        files: const [],
        raw: {'theme.wav': tone},
        types: ['music', 'sfx'],
      );
      expect(find.textContaining('Audio ('), findsOneWidget);
      // Images (knight.png) is first, Audio second.
      expect(tabIndex(tester), 1);
      expect(find.text('Loop'), findsOneWidget);
      // The header length is read off the UI thread.
      await pumpUntil(tester, find.text('0:01'));
    });

    testWidgets('a mixed pack keeps its first tab', (tester) async {
      await openKnight(
        tester,
        files: const [],
        raw: {'hit.wav': tone},
        types: ['character', 'sfx'],
      );
      expect(tabIndex(tester), 0);
    });

    testWidgets('toolbar: Rows / Cards left, Loop right (M33)', (tester) async {
      await openKnight(
        tester,
        files: const [],
        raw: {'theme.wav': tone},
        types: ['music'],
      );
      final rows = tester.getRect(find.text('Rows'));
      final loop = tester.getRect(find.byKey(const ValueKey('loop')));
      expect(rows.right, lessThan(loop.left));
      // Same left edge as the Images / Animations toggles (16 px in).
      expect(rows.left, lessThan(200));
      expect(loop.right, greaterThan(800));
    });

    testWidgets('seek bar: long tracks seek, short ones show only length', (
      tester,
    ) async {
      final fake = _FakePlayer();
      final lengths = {
        'long.ogg': const Duration(minutes: 2, seconds: 30),
        'short.wav': const Duration(seconds: 3),
      };
      await openKnight(
        tester,
        files: const ['long.ogg', 'short.wav'],
        types: ['music'],
        overrides: [
          trackPlayerFactoryProvider.overrideWithValue(() => fake),
          audioDurationProvider.overrideWithValue(
            (path) async => lengths[p.basename(path)],
          ),
        ],
      );
      await tester.pump();
      expect(find.text('2:30'), findsOneWidget);
      expect(find.text('0:03'), findsOneWidget);

      await tester.tap(find.text('long'));
      await tester.pump();
      expect(p.basename(fake.played.single), 'long.ogg');
      final seek = find.byKey(const ValueKey('seek'));
      expect(seek, findsOneWidget);
      fake.length.add(const Duration(minutes: 2, seconds: 30));
      fake.position.add(const Duration(seconds: 30));
      await tester.pump();
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('elapsed'))).data,
        '0:30',
      );

      // Click in the middle of the bar seeks there.
      await tester.tapAt(tester.getCenter(seek));
      await tester.pump();
      expect(fake.seeks.last.inSeconds, closeTo(75, 3));

      // Drag: position updates wait until the drag ends.
      final box = tester.getRect(seek);
      final drag = await tester.startGesture(
        Offset(box.left + box.width / 2, box.center.dy),
      );
      await drag.moveTo(Offset(box.left + box.width * 0.8, box.center.dy));
      await tester.pump();
      fake.position.add(const Duration(seconds: 76));
      await tester.pump();
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('elapsed'))).data,
        isNot('1:16'),
      );
      await drag.up();
      await tester.pump();
      expect(fake.seeks.last.inSeconds, greaterThan(100));

      // Keys: → seeks 5 s on; Space stops the selected row.
      fake.position.add(const Duration(seconds: 40));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(fake.seeks.last, const Duration(seconds: 45));
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      expect(fake.seeks.last, const Duration(seconds: 40));

      // Loop on: each pass completes, the position restarts, it keeps going.
      fake.looping = true;
      fake.complete.add(null);
      fake.position.add(Duration.zero);
      await tester.pump();
      expect(find.byTooltip('Stop'), findsOneWidget);
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('elapsed'))).data,
        '0:00',
      );
      // Position events after the restart keep moving the bar.
      fake.position.add(const Duration(seconds: 5));
      // Stream events land after the first frame; the second shows them.
      await tester.pump();
      await tester.pump();
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('elapsed'))).data,
        '0:05',
      );
      final slider = tester.widget<Slider>(seek);
      expect(slider.value, 5000);
      // And on the next pass too.
      fake.complete.add(null);
      fake.position.add(const Duration(seconds: 1));
      await tester.pump();
      await tester.pump();
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('elapsed'))).data,
        '0:01',
      );
      fake.looping = false;

      // Another file stops this one; short sounds get no slider.
      final stopsBefore = fake.stops;
      await tester.tap(find.text('short'));
      await tester.pump();
      expect(fake.stops, greaterThan(stopsBefore));
      expect(p.basename(fake.played.last), 'short.wav');
      expect(seek, findsNothing);
      // Short sounds: only their length, no elapsed counter.
      fake.position.add(const Duration(seconds: 2));
      await tester.pump();
      expect(find.byKey(const ValueKey('elapsed')), findsNothing);
      expect(find.text('0:03'), findsOneWidget);
      fake.complete.add(null);
      // The event lands after the first frame; the second shows it.
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const ValueKey('elapsed')), findsNothing);

      // Space replays the selected row, and stops it again.
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(find.byTooltip('Stop'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(find.byTooltip('Stop'), findsNothing);
    });
  });

  group('Play all (M37)', () {
    late _FakePlayer fake;

    Future<void> open(
      WidgetTester tester, {
      List<String> files = const ['sfx/a.wav', 'sfx/b.wav', 'sfx/c.wav'],
    }) async {
      fake = _FakePlayer();
      await openKnight(
        tester,
        files: files,
        types: ['sfx'],
        overrides: [
          trackPlayerFactoryProvider.overrideWithValue(() => fake),
          audioDurationProvider.overrideWithValue(
            (path) async => const Duration(seconds: 1),
          ),
        ],
      );
      await tester.pump();
    }

    List<String> played() => [for (final f in fake.played) p.basename(f)];
    Finder button(String label) => find.widgetWithText(FilledButton, label);

    /// The sound ends; the next one starts after the gap.
    Future<void> finish(WidgetTester tester) async {
      fake.complete.add(null);
      await tester.pump();
      await tester.pump(playAllGap);
      await tester.pump();
    }

    testWidgets('plays the list in order with a gap, then stops', (
      tester,
    ) async {
      await open(tester);
      await tester.tap(button('Play all'));
      await tester.pump();
      expect(played(), ['a.wav']);
      expect(button('Stop'), findsOneWidget);
      expect(fake.looping, isFalse);
      // Nothing during the gap.
      fake.complete.add(null);
      await tester.pump();
      await tester.pump(playAllGap - const Duration(milliseconds: 50));
      expect(played(), ['a.wav']);
      await tester.pump(const Duration(milliseconds: 100));
      expect(played(), ['a.wav', 'b.wav']);
      // The playing row is the selected (highlighted) one.
      final row = tester.widget<ListTile>(
        find.ancestor(of: find.text('b'), matching: find.byType(ListTile)),
      );
      expect(row.selected, isTrue);
      await finish(tester);
      expect(played(), ['a.wav', 'b.wav', 'c.wav']);
      // After the last one the run ends.
      await finish(tester);
      expect(played(), hasLength(3));
      expect(button('Play all'), findsOneWidget);
    });

    testWidgets('follows the search: only the shown sounds', (tester) async {
      await open(
        tester,
        files: const ['sfx/hit_1.wav', 'sfx/door.wav', 'sfx/hit_2.wav'],
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Search files'),
        'hit',
      );
      await tester.pump(DashboardQueryNotifier.searchDebounce);
      await tester.pump();
      expect(find.text('door'), findsNothing);
      await tester.tap(button('Play all'));
      await tester.pump();
      await finish(tester);
      await finish(tester);
      expect(played(), ['hit_1.wav', 'hit_2.wav']);
    });

    testWidgets('a click in the middle continues from there', (tester) async {
      await open(
        tester,
        files: const ['sfx/a.wav', 'sfx/b.wav', 'sfx/c.wav', 'sfx/d.wav'],
      );
      await tester.tap(button('Play all'));
      await tester.pump();
      await tester.tap(find.text('c'));
      await tester.pump();
      expect(played(), ['a.wav', 'c.wav']);
      expect(button('Stop'), findsOneWidget);
      await finish(tester);
      expect(played(), ['a.wav', 'c.wav', 'd.wav']);
    });

    testWidgets('Stop, Space and a click on the playing row end it', (
      tester,
    ) async {
      await open(tester);
      // Stop button.
      await tester.tap(button('Play all'));
      await tester.pump();
      await tester.tap(button('Stop'));
      await tester.pump();
      expect(button('Play all'), findsOneWidget);
      await finish(tester);
      expect(played(), ['a.wav']);
      // Space (the run starts from the last played one, a.wav).
      await tester.tap(button('Play all'));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(button('Play all'), findsOneWidget);
      await finish(tester);
      expect(played(), ['a.wav', 'a.wav']);
      // Shift+Space starts it; a click on the playing row stops it.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();
      expect(button('Stop'), findsOneWidget);
      await tester.tap(find.text('a'));
      await tester.pump();
      expect(button('Play all'), findsOneWidget);
      await finish(tester);
      expect(played(), ['a.wav', 'a.wav', 'a.wav']);
    });

    testWidgets('Loop repeats the whole list, not one sound', (tester) async {
      await open(tester, files: const ['sfx/a.wav', 'sfx/b.wav']);
      await tester.tap(find.byKey(const ValueKey('loop')));
      await tester.pump();
      await tester.tap(button('Play all'));
      await tester.pump();
      // The player doesn't loop the sound itself during the run.
      expect(fake.looping, isFalse);
      expect(find.byTooltip('Repeat the whole list'), findsOneWidget);
      await finish(tester);
      await finish(tester);
      await finish(tester);
      expect(played(), ['a.wav', 'b.wav', 'a.wav', 'b.wav']);
      // Stopped, a single sound loops again.
      await tester.tap(button('Stop'));
      await tester.pump();
      await tester.tap(find.text('b'));
      await tester.pump();
      expect(fake.looping, isTrue);
    });
  });

  group('Audio formats (M59)', () {
    late _FakePlayer fake;

    Future<void> open(WidgetTester tester) async {
      fake = _FakePlayer();
      await openKnight(
        tester,
        files: const [
          'music/MP3/theme.mp3',
          'music/OGG/theme.ogg',
          'music/WAV/theme.wav',
          'music/other.wav',
        ],
        types: ['music'],
        overrides: [
          trackPlayerFactoryProvider.overrideWithValue(() => fake),
          audioDurationProvider.overrideWithValue(
            (path) async => const Duration(minutes: 1),
          ),
        ],
      );
      await tester.pump();
    }

    List<String> played() => [for (final f in fake.played) p.basename(f)];

    testWidgets('M64: formats, length and size line up down the rows', (
      tester,
    ) async {
      fake = _FakePlayer();
      await openKnight(
        tester,
        files: const [],
        raw: {
          'a.ogg': List.filled(512, 0),
          'b.ogg': List.filled(12300, 0),
          'c.mp3': [0],
          'c.ogg': List.filled(1200000, 0),
          'c.wav': [0],
        },
        types: ['sfx'],
        overrides: [
          trackPlayerFactoryProvider.overrideWithValue(() => fake),
          audioDurationProvider.overrideWithValue(
            (path) async => const Duration(seconds: 5),
          ),
        ],
      );
      await tester.pump();
      expect(find.text('512 B'), findsOneWidget);
      expect(find.text('12 KB'), findsOneWidget);
      expect(find.text('1.2 MB'), findsOneWidget);
      double left(String key) =>
          tester.getTopLeft(find.byKey(ValueKey(key))).dx;
      double right(String key) =>
          tester.getTopRight(find.byKey(ValueKey(key))).dx;
      for (final key in ['length', 'format', 'formats-column']) {
        expect(
          {
            for (final r in ['a.ogg', 'b.ogg', 'c.ogg']) left('$key:$r'),
          },
          hasLength(1),
          reason: key,
        );
      }
      expect({
        for (final r in ['a.ogg', 'b.ogg', 'c.ogg']) right('size:$r'),
      }, hasLength(1));
    });

    Future<void> openRaw(WidgetTester tester, List<String> files) async {
      fake = _FakePlayer();
      await openKnight(
        tester,
        files: const [],
        raw: {
          for (final f in files) f: const [0],
        },
        types: ['sfx'],
        overrides: [
          trackPlayerFactoryProvider.overrideWithValue(() => fake),
          audioDurationProvider.overrideWithValue(
            (path) async => const Duration(seconds: 5),
          ),
        ],
      );
      await tester.pump();
    }

    Rect chipRect(WidgetTester tester, String file) =>
        tester.getRect(find.byKey(ValueKey('format:$file')));

    testWidgets('M66: each format keeps its own column slot', (tester) async {
      await openRaw(tester, const [
        'a.ogg', 'a.wav', 'a.mp3', //
        'b.ogg', 'b.wav', 'b.mp3', //
        'c.wav', 'd.mp3', 'e.ogg', 'e.mp3',
      ]);
      // One row per sound, under the column headers (M73).
      expect(find.byType(ListTile), findsNWidgets(5 + 1));
      expect(find.byKey(const ValueKey('audio-list-header')), findsOneWidget);
      for (final (ext, names) in [
        ('ogg', ['a', 'b', 'e']),
        ('wav', ['a', 'b', 'c']),
        ('mp3', ['a', 'b', 'd', 'e']),
      ]) {
        expect(
          {for (final n in names) chipRect(tester, '$n.$ext').left},
          hasLength(1),
          reason: ext,
        );
      }
      // In the fixed order: OGG, WAV, MP3.
      expect(
        chipRect(tester, 'c.wav').left,
        greaterThan(chipRect(tester, 'a.ogg').right),
      );
      expect(
        chipRect(tester, 'd.mp3').left,
        greaterThan(chipRect(tester, 'a.wav').right),
      );
      // Every row's column is as wide as all three slots, and the length
      // after it starts at the same x.
      double left(String key) =>
          tester.getTopLeft(find.byKey(ValueKey(key))).dx;
      for (final key in ['formats-column', 'length']) {
        expect(
          {
            for (final r in ['a.ogg', 'c.wav', 'd.mp3']) left('$key:$r'),
          },
          hasLength(1),
          reason: key,
        );
      }
      final column = tester.getRect(
        find.byKey(const ValueKey('formats-column:c.wav')),
      );
      expect(
        column.width,
        greaterThanOrEqualTo(chipRect(tester, 'a.mp3').right - column.left),
      );
    });

    testWidgets('M66: a tab with the same formats everywhere packs them', (
      tester,
    ) async {
      await openRaw(tester, const ['a.ogg', 'a.wav', 'b.ogg', 'b.wav']);
      for (final n in ['a', 'b']) {
        final column = tester.getRect(
          find.byKey(ValueKey('formats-column:$n.ogg')),
        );
        final ogg = chipRect(tester, '$n.ogg');
        final wav = chipRect(tester, '$n.wav');
        expect(ogg.left, column.left);
        // Only the chip's 4 px gap between them, as before.
        expect(wav.left, ogg.right + 4);
        expect(column.width, closeTo(wav.right + 4 - column.left, 1));
      }
      // Cards still pack the chips without gaps.
      await tester.tap(find.text('Cards'));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const ValueKey('format-slot:ogg')), findsNothing);
    });

    testWidgets('one row per sound; a format chip switches mid-play', (
      tester,
    ) async {
      await open(tester);
      expect(find.textContaining('Audio (2)'), findsOneWidget);
      // One row per sound, under the column headers (M73).
      expect(find.byType(ListTile), findsNWidgets(2 + 1));
      expect(find.byKey(const ValueKey('audio-list-header')), findsOneWidget);
      // No folder line under the name (M72); the name's tooltip is the
      // path in the pack.
      expect(
        find.descendant(
          of: find.byType(ListTile),
          matching: find.text('music'),
        ),
        findsNothing,
      );
      expect(
        tester
            .widget<Tooltip>(
              find
                  .ancestor(
                    of: find.byKey(const ValueKey('name:music/OGG/theme.ogg')),
                    matching: find.byType(Tooltip),
                  )
                  .first,
            )
            .message,
        'music/OGG/theme.ogg',
      );
      expect(find.text('OGG'), findsOneWidget);
      expect(find.text('MP3'), findsOneWidget);
      // theme's and other's.
      expect(find.text('WAV'), findsNWidgets(2));

      // The preferred format (ogg) plays.
      await tester.tap(find.text('theme'));
      await tester.pump();
      expect(played(), ['theme.ogg']);
      fake.position.add(const Duration(seconds: 12));
      await tester.pump();

      // Switching carries on from where it was.
      await tester.tap(
        find.byKey(const ValueKey('format:music/MP3/theme.mp3')),
      );
      await tester.pump();
      expect(played(), ['theme.ogg', 'theme.mp3']);
      expect(fake.seeks.last, const Duration(seconds: 12));

      // Play all goes by sound: the picked format, then the next sound.
      await tester.tap(find.widgetWithText(FilledButton, 'Play all'));
      await tester.pump();
      expect(played().last, 'theme.mp3');
      fake.complete.add(null);
      await tester.pump();
      await tester.pump(playAllGap);
      await tester.pump();
      expect(played().last, 'other.wav');
    });

    testWidgets('the star is on when any format is starred', (tester) async {
      await open(tester);
      await tester.tap(find.byKey(const ValueKey('star:music/OGG/theme.ogg')));
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey('format:music/WAV/theme.wav')),
      );
      await tester.pump();
      final star = find.byKey(const ValueKey('star:music/WAV/theme.wav'));
      expect(tester.widget<FavoriteStar>(star).starred, isTrue);
      // Unstarring clears the starred format.
      await tester.tap(star);
      await tester.pump();
      expect(tester.widget<FavoriteStar>(star).starred, isFalse);
    });
  });

  group('Audio cards', () {
    final lengths = {
      'music/long_theme.ogg': const Duration(minutes: 1, seconds: 40),
      'sfx/coin_pickup.wav': const Duration(seconds: 2),
    };

    Future<_FakePlayer> openCards(WidgetTester tester) async {
      final fake = _FakePlayer();
      await openKnight(
        tester,
        files: lengths.keys.toList(),
        types: ['music', 'sfx'],
        overrides: [
          trackPlayerFactoryProvider.overrideWithValue(() => fake),
          audioDurationProvider.overrideWithValue(
            (path) async => lengths.entries
                .where((e) => path.endsWith(e.key))
                .firstOrNull
                ?.value,
          ),
        ],
      );
      await tester.tap(find.text('Cards'));
      await tester.pump();
      // The lengths are futures; the next frame shows them.
      await tester.pump();
      return fake;
    }

    testWidgets('the view is saved; cards show name, length, no folder', (
      tester,
    ) async {
      await openCards(tester);
      expect(store.load().audioView, AudioView.cards);
      expect(find.text('Long theme'), findsOneWidget);
      expect(find.text('Coin pickup'), findsOneWidget);
      expect(find.text('1:40'), findsOneWidget);
      expect(
        find.descendant(
          of: find.ancestor(
            of: find.text('Coin pickup'),
            matching: find.byType(Card),
          ),
          matching: find.textContaining('sfx'),
        ),
        findsNothing,
      );
      await tester.tap(find.text('Rows'));
      await tester.pump();
      expect(store.load().audioView, AudioView.rows);
      expect(find.text('coin_pickup'), findsOneWidget);
    });

    testWidgets('playing: progress ring, waveform seeks for long, keys work', (
      tester,
    ) async {
      final fake = await openCards(tester);
      await tester.tap(find.text('Long theme'));
      await tester.pump();
      expect(p.basename(fake.played.single), 'long_theme.ogg');
      fake.position.add(const Duration(seconds: 50));
      await tester.pump();
      final ring = tester.widget<CircularProgressIndicator>(
        find.byKey(const ValueKey('progress')),
      );
      expect(ring.value, closeTo(0.5, 0.01));
      // The waveform is the seek bar; no slider on the card.
      expect(find.byKey(const ValueKey('waveform-seek')), findsOneWidget);
      expect(find.byKey(const ValueKey('seek')), findsNothing);
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('elapsed'))).data,
        '0:50',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(fake.seeks.last, const Duration(seconds: 55));

      // A short sound: ring, no seek bar or counter.
      await tester.tap(find.text('Coin pickup'));
      await tester.pump();
      fake.position.add(const Duration(seconds: 1));
      await tester.pump();
      expect(find.byKey(const ValueKey('progress')), findsOneWidget);
      expect(find.byKey(const ValueKey('waveform-seek')), findsNothing);
      expect(find.byKey(const ValueKey('elapsed')), findsNothing);
      // Space stops it.
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(find.byKey(const ValueKey('progress')), findsNothing);
    });
  });

  group('Audio waveforms (M65)', () {
    final lengths = {
      'music/long_theme.ogg': const Duration(minutes: 1, seconds: 40),
      'sfx/coin_pickup.wav': const Duration(seconds: 2),
      'sfx/odd_format.m4a': const Duration(seconds: 2),
    };
    final peaks = Float32List.fromList([
      for (var i = 0; i < 200; i++) (i % 20) / 20,
    ]);

    /// Opens the Audio tab with peaks that arrive when [gate] completes.
    Future<_FakePlayer> open(
      WidgetTester tester,
      Completer<void> gate, {
      bool cards = true,
    }) async {
      final fake = _FakePlayer();
      await openKnight(
        tester,
        files: lengths.keys.toList(),
        types: ['music', 'sfx'],
        overrides: [
          trackPlayerFactoryProvider.overrideWithValue(() => fake),
          audioDurationProvider.overrideWithValue(
            (path) async => lengths.entries
                .where((e) => path.endsWith(e.key))
                .firstOrNull
                ?.value,
          ),
          audioPeaksProvider.overrideWithValue(
            AudioPeaksCache(
              read: (path) async {
                await gate.future;
                return peaks;
              },
            ),
          ),
        ],
      );
      if (cards) {
        await tester.tap(find.text('Cards'));
        await tester.pump();
      }
      await tester.pump();
      return fake;
    }

    Finder wave(String rel) => find.byKey(ValueKey('waveform:$rel'));
    Finder bars(String rel) => find.descendant(
      of: wave(rel),
      matching: find.byKey(const ValueKey('waveform-bars')),
    );
    double? progressOf(WidgetTester tester, String rel) =>
        (tester.widget<CustomPaint>(bars(rel)).painter! as WaveformPainter)
            .progress;

    testWidgets('cards: a strip between the button and the name', (
      tester,
    ) async {
      final gate = Completer<void>();
      await open(tester, gate);
      const ogg = 'music/long_theme.ogg';
      const m4a = 'sfx/odd_format.m4a';
      // Before the peaks arrive: the strip is there, empty.
      expect(wave(ogg), findsOneWidget);
      expect(bars(ogg), findsNothing);
      final empty = tester.getRect(wave(ogg));
      gate.complete();
      await tester.pump();
      await tester.pump();
      expect(bars(ogg), findsOneWidget);
      expect(bars('sfx/coin_pickup.wav'), findsOneWidget);
      // No waveform for M4A, and no layout change.
      expect(bars(m4a), findsNothing);
      expect(tester.getRect(wave(ogg)), empty);
      expect(tester.getSize(wave(m4a)), empty.size);
      expect(empty.height, 32);
      // Between the play button and the name, nearly the card's width.
      final card = tester.getRect(
        find.ancestor(of: wave(ogg), matching: find.byType(Card)).first,
      );
      final button = tester.getRect(
        find
            .descendant(
              of: find.ancestor(of: wave(ogg), matching: find.byType(Card)),
              matching: find.byIcon(Icons.play_circle),
            )
            .first,
      );
      final name = tester.getRect(find.text('Long theme'));
      expect(button.bottom, lessThanOrEqualTo(empty.top));
      expect(empty.bottom, lessThanOrEqualTo(name.top));
      expect(empty.width, card.width - 20);
    });

    testWidgets('cards and rows: the played part follows the position', (
      tester,
    ) async {
      final gate = Completer<void>()..complete();
      final fake = await open(tester, gate);
      await tester.pump();
      const ogg = 'music/long_theme.ogg';
      expect(progressOf(tester, ogg), isNull);
      await tester.tap(find.text('Long theme'));
      await tester.pump();
      fake.position.add(const Duration(seconds: 50));
      await tester.pump();
      expect(progressOf(tester, ogg), closeTo(0.5, 0.01));
      expect(progressOf(tester, 'sfx/coin_pickup.wav'), isNull);
      // The waveform of a long track is its seek bar, with a playhead.
      expect(find.byKey(const ValueKey('waveform-seek')), findsOneWidget);
      expect(
        find.descendant(
          of: wave(ogg),
          matching: find.byWidgetPredicate(
            (w) => w is CustomPaint && w.foregroundPainter is PlayheadPainter,
          ),
        ),
        findsOneWidget,
      );

      await tester.tap(find.text('Rows'));
      await tester.pump();
      await tester.pump();
      expect(tester.getSize(wave(ogg)), const Size(80, 20));
      expect(progressOf(tester, ogg), closeTo(0.5, 0.01));
      fake.position.add(const Duration(seconds: 75));
      await tester.pump();
      expect(progressOf(tester, ogg), closeTo(0.75, 0.01));
    });

    testWidgets('rows: the column lines up, also without a waveform', (
      tester,
    ) async {
      final gate = Completer<void>()..complete();
      await open(tester, gate, cards: false);
      await tester.pump();
      const m4a = 'sfx/odd_format.m4a';
      const wav = 'sfx/coin_pickup.wav';
      expect(bars(wav), findsOneWidget);
      expect(bars(m4a), findsNothing);
      expect(tester.getSize(wave(m4a)), const Size(80, 20));
      expect(tester.getRect(wave(m4a)).left, tester.getRect(wave(wav)).left);
      // Between the formats and the length.
      final chips = tester.getRect(
        find.byKey(const ValueKey('formats-column:$wav')),
      );
      final length = tester.getRect(find.byKey(const ValueKey('length:$wav')));
      expect(chips.right, lessThan(tester.getRect(wave(wav)).left));
      expect(tester.getRect(wave(wav)).right, lessThan(length.left));
      expect(
        tester.getRect(find.byKey(const ValueKey('length:$m4a'))).left,
        length.left,
      );
    });
  });

  group('Audio card layout and details (M68)', () {
    final lengths = {
      'music/long_theme.ogg': const Duration(minutes: 1, seconds: 40),
      'music/long_theme.wav': const Duration(minutes: 1, seconds: 40),
      'sfx/coin_pickup.wav': const Duration(seconds: 2),
    };
    const ogg = 'music/long_theme.ogg';
    const coin = 'sfx/coin_pickup.wav';
    final peaks = Float32List.fromList([for (var i = 0; i < 200; i++) 0.5]);

    Future<_FakePlayer> open(
      WidgetTester tester, {
      bool cards = true,
      Size size = const Size(1644, 900),
    }) async {
      final fake = _FakePlayer();
      await openKnight(
        tester,
        size: size,
        files: lengths.keys.toList(),
        types: ['music', 'sfx'],
        overrides: [
          trackPlayerFactoryProvider.overrideWithValue(() => fake),
          audioDurationProvider.overrideWithValue(
            (path) async => lengths.entries
                .where((e) => path.endsWith(e.key))
                .firstOrNull
                ?.value,
          ),
          audioInfoProvider.overrideWithValue(
            (path) async => path.endsWith('.ogg')
                ? const AudioInfo(
                    sampleRate: 48000,
                    channels: 1,
                    kbps: 112,
                    approximate: true,
                  )
                : const AudioInfo(sampleRate: 44100, channels: 2, bitDepth: 16),
          ),
          audioPeaksProvider.overrideWithValue(
            AudioPeaksCache(read: (path) async => peaks),
          ),
        ],
      );
      if (cards) {
        await tester.tap(find.text('Cards'));
        await tester.pump();
      }
      await tester.pump();
      await tester.pump();
      return fake;
    }

    Finder wave(String rel) => find.byKey(ValueKey('waveform:$rel'));
    Finder cardOf(String rel) =>
        find.ancestor(of: wave(rel), matching: find.byType(Card)).first;
    Rect buttonOf(WidgetTester tester, String rel) => tester.getRect(
      find.descendant(
        of: cardOf(rel),
        matching: find.byKey(const ValueKey('card-play')),
      ),
    );

    testWidgets('M77: the button sits halfway between top edge and waveform', (
      tester,
    ) async {
      await open(tester);
      final card = tester.getRect(cardOf(ogg));
      expect(card.width, closeTo(220, 0.5));
      // The card's size is unchanged (M65): 220 / 1.6 plus the footer.
      expect(card.height, closeTo(220 / 1.6 + 60 + 32 + 6, 0.5));
      for (final rel in [ogg, coin]) {
        final cardRect = tester.getRect(cardOf(rel));
        final button = buttonOf(tester, rel);
        expect(button.center.dx, closeTo(cardRect.center.dx, 0.5));
        final strip = tester.getRect(wave(rel));
        expect(button.center.dy, closeTo((cardRect.top + strip.top) / 2, 0.5));
        // Clear of the top row's parts and the times.
        final ring = Rect.fromCircle(center: button.center, radius: 28);
        final card = cardOf(rel);
        for (final f in [
          find.byType(FormatChips),
          find.byKey(const ValueKey('audio-card-icons')),
          find.byKey(const ValueKey('total')),
        ]) {
          final part = tester.getRect(
            find.descendant(of: card, matching: f).first,
          );
          expect(ring.overlaps(part), isFalse, reason: '$f');
        }
        expect(button.bottom, lessThan(strip.top));
      }
    });

    test('M77: buttonCentre clears the top row and the times', () {
      const d = 56.0;
      // Nothing in the ring's column: the middle of the area.
      expect(
        audioButtonCentre(areaHeight: 137.5, width: 220, timeHeight: 20),
        closeTo(137.5 / 2, 1e-9),
      );
      // Chips under the ring push it down just enough.
      expect(
        audioButtonCentre(
          areaHeight: 137.5,
          width: 220,
          timeHeight: 20,
          chips: const Rect.fromLTWH(8, 8, 120, 50),
        ),
        closeTo(58 + d / 2, 1e-9),
      );
      // Wide times under the ring push it up just enough.
      expect(
        audioButtonCentre(
          areaHeight: 120,
          width: 140,
          timeHeight: 40,
          timeWidth: 70,
        ),
        closeTo(120 - 2 - 40 - d / 2, 1e-9),
      );
      // The same times outside the ring's column don't count.
      expect(
        audioButtonCentre(
          areaHeight: 120,
          width: 300,
          timeHeight: 40,
          timeWidth: 70,
        ),
        closeTo(60, 1e-9),
      );
    });

    testWidgets('M72: narrow cards: the ring overlaps nothing', (tester) async {
      await open(tester);
      // From the widest cards to the narrowest a desktop window gives.
      for (var w = 1700.0; w >= 900; w -= 25) {
        await tester.binding.setSurfaceSize(Size(w, 900));
        await tester.pump();
        // Narrow windows overflow the header's author line (not this
        // milestone's); that error is dropped.
        tester.takeException();
        final card = cardOf(ogg);
        final ring = Rect.fromCircle(
          center: buttonOf(tester, ogg).center,
          radius: 28,
        );
        Rect part(Finder f) =>
            tester.getRect(find.descendant(of: card, matching: f).first);
        final parts = {
          'chips': part(find.byType(FormatChips)),
          'star': part(find.byKey(const ValueKey('star:$ogg'))),
          'reveal': part(find.byType(RevealButton)),
          'total': part(find.byKey(const ValueKey('total'))),
          'waveform': tester.getRect(wave(ogg)),
        };
        for (final MapEntry(:key, :value) in parts.entries) {
          expect(
            ring.overlaps(value),
            isFalse,
            reason: '$key at ${w}px (card ${tester.getRect(card).size})',
          );
        }
      }
    });

    testWidgets('M72: star in the corner, reveal left of it', (tester) async {
      await open(tester);
      final card = tester.getRect(cardOf(ogg));
      final star = tester.getRect(find.byKey(const ValueKey('star:$ogg')));
      final reveal = tester.getRect(
        find.descendant(of: cardOf(ogg), matching: find.byType(RevealButton)),
      );
      expect(star.right, closeTo(card.right, 0.5));
      expect(star.top, closeTo(card.top, 0.5));
      expect(reveal.right, closeTo(star.left, 0.5));
      expect(reveal.top, star.top);
    });

    testWidgets('M72: the length above the waveform\'s right end', (
      tester,
    ) async {
      final fake = await open(tester);
      final total = find.descendant(
        of: cardOf(ogg),
        matching: find.byKey(const ValueKey('total')),
      );
      expect(tester.widget<Text>(total).data, '1:40');
      final strip = tester.getRect(wave(ogg));
      final t = tester.getRect(total);
      expect(t.right, closeTo(strip.right, 0.5));
      expect(t.bottom, lessThanOrEqualTo(strip.top));
      expect(t.bottom, greaterThan(strip.top - 6));
      // A bit bigger than the old length under the name (body text, 14).
      final style = tester.widget<Text>(total).style!;
      expect(style.fontSize, 15);
      expect(style.fontFeatures, contains(const FontFeature.tabularFigures()));

      // Playing: the elapsed time at the left end, in the same size.
      await tester.tap(find.text('Long theme'));
      await tester.pump();
      fake.position.add(const Duration(seconds: 10));
      await tester.pump();
      final elapsed = find.byKey(const ValueKey('elapsed'));
      expect(tester.widget<Text>(elapsed).style!.fontSize, style.fontSize);
      expect(tester.getRect(elapsed).bottom, tester.getRect(total).bottom);
      expect(tester.getRect(elapsed).left, closeTo(strip.left, 0.5));
    });

    testWidgets('M72: a details line; no folder, the path as the tooltip', (
      tester,
    ) async {
      await open(tester);
      String sizeOf(String rel) => formatBytes(
        File(p.join(tmp.path, 'library', 'HeroMaker', 'Knight Pack', rel))
            .lengthSync(),
      );
      String line(String rel) => tester
          .widget<Text>(
            find.descendant(
              of: find.byKey(ValueKey('card-details:$rel')),
              matching: find.byType(Text),
            ),
          )
          .data!;
      // M77: S / M first, then the size.
      expect(line(coin), 'S · ${sizeOf(coin)} · 44.1 kHz · 16-bit');
      expect(line(ogg), 'M · ${sizeOf(ogg)} · 48 kHz · ~112 kbps');
      // The tooltip spells the channels out, cut or not.
      expect(
        find.byTooltip('Stereo · ${sizeOf(coin)} · 44.1 kHz · 16-bit'),
        findsOneWidget,
      );
      // No folder text on the cards.
      for (final (rel, folder) in [(ogg, 'music'), (coin, 'sfx')]) {
        expect(
          find.descendant(
            of: cardOf(rel),
            matching: find.textContaining(folder),
          ),
          findsNothing,
        );
      }
      String tipOf(String rel) => tester
          .widget<Tooltip>(
            find
                .ancestor(
                  of: find.byKey(ValueKey('name:$rel')),
                  matching: find.byType(Tooltip),
                )
                .first,
          )
          .message!;
      expect(tipOf(coin), coin);
      // The list rows too.
      await tester.tap(find.text('Rows'));
      await tester.pump();
      await tester.pump();
      expect(tipOf(ogg), ogg);
      expect(
        find.descendant(of: find.byType(ListTile), matching: find.text('sfx')),
        findsNothing,
      );
    });

    testWidgets('M72: a cut details line has the whole line as a tooltip', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox(
              width: 60,
              child: OverflowText(
                audioCardDetails(
                  1234567,
                  const AudioInfo(sampleRate: 44100, channels: 2, bitDepth: 16),
                ),
              ),
            ),
          ),
        ),
      );
      expect(find.byTooltip('S · 1.2 MB · 44.1 kHz · 16-bit'), findsOneWidget);
      expect(audioCardDetails(1234567, null), '1.2 MB');
      expect(
        audioCardDetails(1234567, const AudioInfo(channels: 2), words: true),
        'Stereo · 1.2 MB',
      );
    });

    testWidgets('tap and drag on the waveform seek; elapsed above its left', (
      tester,
    ) async {
      final fake = await open(tester);
      await tester.tap(find.text('Long theme'));
      await tester.pump();
      fake.position.add(const Duration(seconds: 10));
      await tester.pump();
      final strip = tester.getRect(find.byKey(const ValueKey('waveform-seek')));
      expect(strip, tester.getRect(wave(ogg)));
      // Only the elapsed time, just above the waveform's left end; the
      // total is the length under the name, once.
      final elapsed = find.byKey(const ValueKey('elapsed'));
      expect(tester.widget<Text>(elapsed).data, '0:10');
      final time = tester.getRect(elapsed);
      expect(time.left, strip.left);
      expect(time.bottom, lessThanOrEqualTo(strip.top));
      expect(time.bottom, greaterThan(strip.top - 6));
      expect(find.text('1:40'), findsOneWidget);
      // The ring does not cover the time.
      final button = buttonOf(tester, ogg);
      expect(
        Rect.fromCircle(center: button.center, radius: 28).overlaps(time),
        isFalse,
      );

      final stops = fake.stops;
      await tester.tapAt(strip.centerLeft + Offset(strip.width * 0.25, 0));
      await tester.pump();
      expect(fake.seeks.last.inSeconds, 25);
      // Still playing: a click on the strip seeks, it doesn't stop.
      expect(fake.stops, stops);
      expect(find.byKey(const ValueKey('progress')), findsOneWidget);

      final drag = await tester.startGesture(
        strip.centerLeft + Offset(strip.width * 0.1, 0),
      );
      await drag.moveTo(strip.centerLeft + Offset(strip.width * 0.4, 0));
      await tester.pump();
      await drag.moveTo(strip.centerLeft + Offset(strip.width * 0.6, 0));
      await tester.pump();
      // While dragging the time follows the finger; nothing seeks yet.
      expect(tester.widget<Text>(elapsed).data, '1:00');
      expect(fake.seeks, hasLength(1));
      await drag.up();
      await tester.pump();
      expect(fake.seeks.last.inSeconds, 60);
    });

    testWidgets('format chip tooltips give the file details', (tester) async {
      await open(tester);
      String tipOf(String rel) => tester
          .widget<Tooltip>(
            find
                .ancestor(
                  of: find.byKey(ValueKey('format:$rel')),
                  matching: find.byType(Tooltip),
                )
                .first,
          )
          .message!;
      final size = formatBytes(
        File(p.join(tmp.path, 'library', 'HeroMaker', 'Knight Pack', ogg))
            .lengthSync(),
      );
      expect(tipOf(ogg), 'OGG · 48 kHz · Mono · ~112 kbps · $size');
      expect(
        tipOf('music/long_theme.wav'),
        startsWith('WAV · 44.1 kHz · Stereo · 16-bit · '),
      );
      expect(
        tipOf('music/long_theme.wav'),
        endsWith('\nSwitch to long_theme.wav'),
      );
    });

    testWidgets('rows: a Details column, aligned across rows', (tester) async {
      await open(tester, cards: false);
      final a = find.byKey(const ValueKey('details-column:$ogg'));
      final b = find.byKey(const ValueKey('details-column:$coin'));
      expect(tester.getRect(a).left, tester.getRect(b).left);
      expect(tester.getRect(a).width, tester.getRect(b).width);
      // The first format's details ([audioFormatOrder]: OGG before WAV).
      expect(
        find.descendant(
          of: a,
          matching: find.text('48 kHz · Mono · ~112 kbps'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: b,
          matching: find.text('44.1 kHz · Stereo · 16-bit'),
        ),
        findsOneWidget,
      );
      // After the formats, before the waveform.
      expect(
        tester.getRect(find.byKey(const ValueKey('formats-column:$ogg'))).right,
        lessThan(tester.getRect(a).left),
      );
      expect(tester.getRect(a).right, lessThan(tester.getRect(wave(ogg)).left));
      // Narrow windows cut it (ellipsis), then leave it out. (Below
      // ~1000 px the test font's wide glyphs overflow the header's author
      // line, which this milestone doesn't touch; that error is dropped.)
      final wide = tester.getRect(a).width;
      await tester.binding.setSurfaceSize(const Size(980, 900));
      await tester.pump();
      tester.takeException();
      expect(tester.getRect(a).width, lessThan(wide));
      expect(tester.getRect(a).width, greaterThanOrEqualTo(48));
      await tester.binding.setSurfaceSize(const Size(620, 900));
      await tester.pump();
      tester.takeException();
      expect(a, findsNothing);
    });

    testWidgets('rows: the seek bar keeps elapsed and total on one line', (
      tester,
    ) async {
      final fake = await open(tester, cards: false);
      await tester.tap(find.text('long_theme'));
      await tester.pump();
      fake.position.add(const Duration(seconds: 5));
      await tester.pump();
      final seek = tester.getRect(find.byKey(const ValueKey('seek')));
      final elapsed = tester.getRect(find.byKey(const ValueKey('elapsed')));
      expect(elapsed.right, lessThanOrEqualTo(seek.left));
      expect(elapsed.center.dy, closeTo(seek.center.dy, 2));
    });
  });

  group('Audio sort (M73)', () {
    const infos = {
      'sfx/a_long.wav': AudioInfo(
        duration: Duration(seconds: 30),
        sampleRate: 44100,
        channels: 2,
        bitDepth: 16,
      ),
      'sfx/b_short.wav': AudioInfo(
        duration: Duration(seconds: 1),
        sampleRate: 22050,
        channels: 1,
        bitDepth: 8,
      ),
      'sfx/c_mid.wav': AudioInfo(
        duration: Duration(seconds: 5),
        sampleRate: 48000,
        channels: 2,
        bitDepth: 24,
      ),
    };
    // Sizes: c biggest, then a, then b.
    final raw = {
      'sfx/a_long.wav': List.filled(3000, 1),
      'sfx/b_short.wav': List.filled(1000, 1),
      'sfx/c_mid.wav': List.filled(9000, 1),
    };
    late Completer<void> gate;
    late int reads;

    Future<void> open(
      WidgetTester tester, {
      bool cards = false,
      AppSettings Function(AppSettings)? settings,
    }) async {
      gate = Completer<void>();
      reads = 0;
      AudioInfo? infoOf(String path) =>
          infos.entries.where((e) => path.endsWith(e.key)).firstOrNull?.value;
      await openKnight(
        tester,
        files: const [],
        raw: raw,
        types: ['sfx'],
        settings: settings,
        overrides: [
          trackPlayerFactoryProvider.overrideWithValue(_FakePlayer.new),
          audioInfoProvider.overrideWithValue((path) async {
            reads++;
            await gate.future;
            return infoOf(path);
          }),
          audioDurationProvider.overrideWithValue(
            (path) async => infoOf(path)?.duration,
          ),
          audioPeaksProvider.overrideWithValue(
            AudioPeaksCache(read: (_) async => Float32List(0)),
          ),
        ],
      );
      if (cards) {
        await tester.tap(find.text('Cards'));
        await tester.pump();
      }
      await tester.pump();
    }

    /// The tracks' names in on-screen order (cards: rows of the grid).
    List<String> shown(WidgetTester tester, {bool cards = false}) {
      final names = cards
          ? ['A long', 'B short', 'C mid']
          : ['a_long', 'b_short', 'c_mid'];
      Offset at(String n) => tester.getTopLeft(find.text(n).first);
      return names..sort((a, b) {
        final pa = at(a);
        final pb = at(b);
        final dy = pa.dy.compareTo(pb.dy);
        return dy != 0 ? dy : pa.dx.compareTo(pb.dx);
      });
    }

    Future<void> pickSort(WidgetTester tester, String label) async {
      await tester.tap(find.byKey(const ValueKey('audio-sort')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text(label).last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    }

    testWidgets('M81: the sort button\'s glyphs sit evenly', (tester) async {
      await open(tester, cards: true);
      gate.complete();
      await tester.pump();
      final play = tester.getRect(find.byKey(const ValueKey('play-all')));
      final arrow = find.byKey(const ValueKey('audio-sort-direction'));
      final label = find.byKey(const ValueKey('audio-sort'));
      final a = tester.getRect(arrow);
      final l = tester.getRect(label);
      // Play all's height (40 on desktop; the test's touch target adds 8).
      expect(a.height, play.height);
      expect(l.height, play.height);
      final icon = tester.getRect(
        find.descendant(of: arrow, matching: find.byType(Icon)),
      );
      // Name half: divider → first letter equals caret glyph → edge (the
      // caret's glyph sits ~5 px inside its 20 px box).
      final name = tester.getRect(
        find.byKey(const ValueKey('audio-sort-label')),
      );
      final caret = tester.getRect(
        find.descendant(
          of: label,
          matching: find.byIcon(Icons.arrow_drop_down),
        ),
      );
      final leftGap = name.left - l.left;
      final rightGap = l.right - (caret.right - 5);
      expect((leftGap - rightGap).abs(), lessThanOrEqualTo(1));
      // Arrow glyph → divider equals divider → first letter (the glyph sits
      // 3 px inside its 18 px box).
      // The visible half (its Material): the key's rect is padded to the
      // test's 48 px touch target.
      final face = tester.getRect(
        find.descendant(of: arrow, matching: find.byType(Material)).first,
      );
      final arrowGap = face.right - (icon.right - sortArrowGlyphInset);
      expect(arrowGap, closeTo(leftGap, 1));
      expect(arrowGap, closeTo(sortNamePadLeft, 0.01));
    });

    testWidgets('M77: the sort button looks like Play all, arrow leading', (
      tester,
    ) async {
      await open(tester, cards: true);
      gate.complete();
      await tester.pump();
      final play = tester.getRect(find.byKey(const ValueKey('play-all')));
      final arrow = find.byKey(const ValueKey('audio-sort-direction'));
      final label = find.byKey(const ValueKey('audio-sort'));
      final a = tester.getRect(arrow);
      final l = tester.getRect(label);
      // One height and one line with Play all; the two halves touch.
      expect(a.height, play.height);
      expect(l.height, play.height);
      expect(a.top, play.top);
      expect(a.right, closeTo(l.left, 0.5));
      expect(a.left, lessThan(l.left));
      // The same tonal colour as Play all, stadium ends outside.
      Material material(Finder f) => tester.widget<Material>(
        find.descendant(of: f, matching: find.byType(Material)).first,
      );
      final playMaterial = material(find.byKey(const ValueKey('play-all')));
      expect(material(arrow).color, playMaterial.color);
      expect(material(label).color, playMaterial.color);
      final shape = material(arrow).shape! as RoundedRectangleBorder;
      final r = (shape.borderRadius as BorderRadius).topLeft.x;
      expect(r, greaterThanOrEqualTo(a.height / 2));
      expect((shape.borderRadius as BorderRadius).topRight.x, 0);
      // The arrow leads: an icon left of the label's text.
      final icon = find.descendant(of: arrow, matching: find.byType(Icon));
      expect(tester.widget<Icon>(icon).icon, Icons.arrow_upward);
      expect(
        tester.getRect(icon).right,
        lessThan(tester.getRect(find.text('Name').first).left),
      );
      expect(find.byTooltip('Ascending'), findsOneWidget);

      // The arrow flips the direction, without opening the menu.
      await tester.tap(arrow);
      await tester.pump();
      expect(tester.widget<Icon>(icon).icon, Icons.arrow_downward);
      expect(find.byTooltip('Descending'), findsOneWidget);
      expect(find.byKey(const ValueKey('audio-sort:duration')), findsNothing);
      expect(store.load().audioSortDesc, isTrue);

      // The label opens the menu.
      await tester.tap(label);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const ValueKey('audio-sort:duration')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('audio-sort:size')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('audio-sort-label')))
            .data,
        'File size',
      );
      expect(store.load().audioSort, AudioSort.size);
    });

    testWidgets('the menu reads the headers, then sorts the cards', (
      tester,
    ) async {
      await open(tester, cards: true);
      expect(shown(tester, cards: true), ['A long', 'B short', 'C mid']);
      await pickSort(tester, 'Duration');
      // Reading every track's header first: a small progress, same order.
      // Each file is read once (the cards had asked already).
      expect(reads, 3);
      expect(find.byKey(const ValueKey('audio-sort-progress')), findsOneWidget);
      expect(shown(tester, cards: true), ['A long', 'B short', 'C mid']);
      gate.complete();
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const ValueKey('audio-sort-progress')), findsNothing);
      expect(shown(tester, cards: true), ['B short', 'C mid', 'A long']);
      expect(store.load().audioSort, AudioSort.duration);

      // The arrow flips the direction.
      await tester.tap(find.byKey(const ValueKey('audio-sort-direction')));
      await tester.pump();
      expect(shown(tester, cards: true), ['A long', 'C mid', 'B short']);
      expect(store.load().audioSortDesc, isTrue);

      // File size needs no header; the direction stays.
      await pickSort(tester, 'File size');
      expect(shown(tester, cards: true), ['C mid', 'A long', 'B short']);
    });

    testWidgets('list headers sort and flip; the sorted one has an arrow', (
      tester,
    ) async {
      await open(tester);
      gate.complete();
      await tester.pump();
      Finder arrowIn(String label) => find.descendant(
        of: find.byKey(ValueKey('audio-header:$label')),
        matching: find.byKey(const ValueKey('sort-arrow')),
      );
      expect(arrowIn('Name'), findsOneWidget);
      expect(arrowIn('Duration'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('audio-header:Duration')));
      await tester.pump();
      await tester.pump();
      expect(shown(tester), ['b_short', 'c_mid', 'a_long']);
      expect(arrowIn('Duration'), findsOneWidget);
      expect(arrowIn('Name'), findsNothing);
      // Again: the other way, and the menu shows the same key.
      await tester.tap(find.byKey(const ValueKey('audio-header:Duration')));
      await tester.pump();
      expect(shown(tester), ['a_long', 'c_mid', 'b_short']);
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('audio-sort-label')))
            .data,
        AudioSort.duration.label,
      );
      expect(
        tester.widget<Icon>(arrowIn('Duration')).icon,
        Icons.arrow_downward,
      );

      // Size: a new column starts ascending.
      await tester.tap(find.byKey(const ValueKey('audio-header:Size')));
      await tester.pump();
      expect(shown(tester), ['b_short', 'a_long', 'c_mid']);

      // Details: the sample rate (the menu's key is not a detail) ...
      await tester.tap(find.byKey(const ValueKey('audio-header:Details')));
      await tester.pump();
      expect(store.load().audioSort, AudioSort.sampleRate);
      expect(shown(tester), ['b_short', 'a_long', 'c_mid']);
      // ... or the menu's detail key.
      await pickSort(tester, 'Bit depth');
      expect(arrowIn('Details'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('audio-header:Details')));
      await tester.pump();
      expect(store.load().audioSort, AudioSort.bitDepth);
      expect(store.load().audioSortDesc, isTrue);
      expect(shown(tester), ['c_mid', 'a_long', 'b_short']);

      // The headers sit over their columns.
      final size = tester.getRect(
        find.byKey(const ValueKey('audio-header:Size')),
      );
      final cell = tester.getRect(
        find.byKey(const ValueKey('size:sfx/a_long.wav')),
      );
      expect(size.right, closeTo(cell.right, 3));
      final details = tester.getRect(
        find.byKey(const ValueKey('audio-header:Details')),
      );
      final column = tester.getRect(
        find.byKey(const ValueKey('details-column:sfx/a_long.wav')),
      );
      expect(details.left, closeTo(column.left, 0.5));
    });

    testWidgets('a saved sort is restored and read on open', (tester) async {
      await open(
        tester,
        settings: (s) =>
            s.copyWith(audioSort: AudioSort.channels, audioSortDesc: true),
      );
      expect(find.byKey(const ValueKey('audio-sort-progress')), findsOneWidget);
      gate.complete();
      await tester.pump();
      await tester.pump();
      // Stereo first (a, c in pack order), then mono.
      expect(shown(tester), ['a_long', 'c_mid', 'b_short']);
      expect(find.text('Channels'), findsOneWidget);
    });
  });

  group('Right-click menu (M69)', () {
    late _FakeClipboard clip;
    String abs(String rel) =>
        p.join(tmp.path, 'library', 'HeroMaker', 'Knight Pack', rel);

    Future<void> open(
      WidgetTester tester, {
      List<String> files = const [
        'heroes/a.png',
        'heroes/b.png',
        'heroes/c.png',
        'sfx/coin.wav',
        'notes/readme.txt',
      ],
      Map<String, img.Image> images = const {},
      bool linux = true,
    }) async {
      clip = _FakeClipboard(linux: linux);
      await openKnight(
        tester,
        files: files,
        images: images,
        overrides: [
          fileClipboardProvider.overrideWithValue(clip),
          gifCacheProvider.overrideWithValue(p.join(tmp.path, 'gif_cache')),
          trackPlayerFactoryProvider.overrideWithValue(_FakePlayer.new),
          audioDurationProvider.overrideWithValue((_) async => null),
          audioInfoProvider.overrideWithValue((_) async => null),
          audioPeaksProvider.overrideWithValue(
            AudioPeaksCache(read: (_) async => Float32List(0)),
          ),
        ],
      );
    }

    Future<void> tab(WidgetTester tester, String name) async {
      await tester.tap(find.textContaining('$name ('));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
    }

    Future<void> rightClick(WidgetTester tester, Finder target) async {
      await tester.tap(target, buttons: kSecondaryButton);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    }

    /// The open menu's labels, in order (M75).
    List<String> labels(WidgetTester tester) => [
      for (final e
          in find
              .descendant(
                of: find.byType(PopupMenuItem<FileMenuAction>),
                matching: find.byType(ListTile),
              )
              .evaluate())
        ((e.widget as ListTile).title! as Text).data!,
    ];

    /// The open menu's items, in order.
    List<String> items(WidgetTester tester) => [
      for (final e
          in find
              .byWidgetPredicate(
                (w) =>
                    w is PopupMenuItem &&
                    w.key is ValueKey<String> &&
                    (w.key! as ValueKey<String>).value.startsWith('menu:'),
              )
              .evaluate())
        (e.widget.key! as ValueKey<String>).value.substring(5),
    ];

    Future<void> pick(WidgetTester tester, String action) async {
      await tester.tap(find.byKey(ValueKey('menu:$action')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    }

    const all = ['copyImage', 'copyFiles', 'copyPath', 'open', 'openWith'];
    const file = ['copyFiles', 'copyPath', 'open', 'openWith'];

    testWidgets('image card: every item in order, each does its job', (
      tester,
    ) async {
      await open(tester);
      await tab(tester, 'Images');
      final card = find.byKey(const ValueKey('image:heroes/a.png'));
      await rightClick(tester, card);
      expect(items(tester), all);
      // Nothing the card's icons already do, and no Play.
      for (final text in [
        'Show in file manager',
        'Add to favorites',
        'Select',
        'Open image',
        'Play',
      ]) {
        expect(
          find.descendant(
            of: find.byType(PopupMenuItem<FileMenuAction>),
            matching: find.text(text),
          ),
          findsNothing,
        );
      }
      // The labels, in order (M75).
      expect(labels(tester), [
        'Copy image to clipboard',
        'Copy file',
        'Copy path',
        'Open',
        'Open with…',
      ]);
      await pick(tester, 'copyImage');
      expect(clip.calls.last, 'image:${abs('heroes/a.png')}');
      expect(find.text('Image copied'), findsOneWidget);

      final expected = {
        'copyFiles': ('files:${abs('heroes/a.png')}', 'File copied'),
        'copyPath': ('text:${abs('heroes/a.png')}', 'Path copied'),
        'open': ('open:${abs('heroes/a.png')}', null),
        'openWith': ('openWith:${abs('heroes/a.png')}', null),
      };
      for (final MapEntry(key: action, value: (call, snack))
          in expected.entries) {
        await rightClick(tester, card);
        await pick(tester, action);
        expect(clip.calls.last, call);
        if (snack != null) expect(find.text(snack), findsWidgets);
      }
    });

    testWidgets('several selected images: the menu acts on all of them', (
      tester,
    ) async {
      await open(tester);
      await tab(tester, 'Images');
      final a = find.byKey(const ValueKey('image:heroes/a.png'));
      final b = find.byKey(const ValueKey('image:heroes/b.png'));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.tap(a);
      await tester.tap(b);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump(const Duration(milliseconds: 300));
      await rightClick(tester, b);
      // No Copy image (or Open) for more than one.
      expect(items(tester), ['copyFiles', 'copyPath']);
      expect(find.text('Copy 2 files'), findsOneWidget);
      await pick(tester, 'copyFiles');
      expect(
        clip.calls.last,
        'files:${abs('heroes/a.png')}|${abs('heroes/b.png')}',
      );
      expect(find.text('2 files copied'), findsOneWidget);
      // An unselected image still gets its own menu.
      await rightClick(
        tester,
        find.byKey(const ValueKey('image:heroes/c.png')),
      );
      expect(items(tester), all);
    });

    testWidgets('animation card: copies its one image file', (tester) async {
      final sheet = img.Image(width: 64, height: 16, numChannels: 4);
      img.fill(sheet, color: img.ColorRgba8(220, 120, 40, 255));
      await open(
        tester,
        files: const [],
        images: {'fx/Explosion(16x16).png': sheet},
      );
      await tab(tester, 'Animations');
      final card = find.byWidgetPredicate(
        (w) => w is ItemCard && w.path == 'fx/Explosion(16x16).png',
      );
      await rightClick(tester, card.first);
      // The two GIF items first, then the image card's (M75).
      expect(items(tester), ['copyGif', 'copyGifFile', ...all]);
      expect(labels(tester), [
        'Copy as GIF to clipboard',
        'Copy as GIF file',
        'Copy image to clipboard',
        'Copy file',
        'Copy path',
        'Open',
        'Open with…',
      ]);
      await pick(tester, 'copyFiles');
      expect(clip.calls.last, 'files:${abs('fx/Explosion(16x16).png')}');
      await rightClick(tester, card.first);
      await pick(tester, 'copyImage');
      expect(clip.calls.last, 'image:${abs('fx/Explosion(16x16).png')}');

      Future<void> until(bool Function() done) async {
        for (var i = 0; i < 50 && !done(); i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 50)),
          );
          await tester.pump();
        }
      }

      // Copy as GIF to clipboard: built off the UI thread, offered only as
      // image/gif bytes (no file, nothing written).
      final gif = p.join(tmp.path, 'gif_cache', 'Explosion(16x16).gif');
      await rightClick(tester, card.first);
      await pick(tester, 'copyGif');
      expect(find.text('Making GIF…'), findsOneWidget);
      await until(() => clip.calls.last.startsWith('bytes:'));
      final bytes = clip.bytes!;
      expect(clip.calls.last, 'bytes:image/gif ${bytes.length}');
      expect(String.fromCharCodes(bytes.take(6)), 'GIF89a');
      expect(File(gif).existsSync(), isFalse);
      expect(find.text('GIF copied'), findsOneWidget);

      // Copy as GIF file: written to the GIF cache, offered only as that
      // file.
      await rightClick(tester, card.first);
      await pick(tester, 'copyGifFile');
      await until(() => clip.calls.last.startsWith('files:'));
      expect(clip.calls.last, 'files:$gif');
      expect(File(gif).readAsBytesSync(), bytes);
      expect(find.text('GIF file copied'), findsOneWidget);

      // The viewer opened from the animation card has the same menu.
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: tester.getCenter(card.first));
      await tester.pump();
      await tester.tap(
        find.descendant(of: card.first, matching: find.byTooltip('Open image')),
      );
      await mouse.removePointer();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(ImageViewer), findsOneWidget);
      await rightClick(
        tester,
        find.descendant(
          of: find.byType(ImageViewer),
          matching: find.byType(InteractiveViewer),
        ),
      );
      expect(items(tester), ['copyGif', 'copyGifFile', ...all]);
    });

    testWidgets('audio rows and cards, Other files rows: file items', (
      tester,
    ) async {
      await open(tester);
      await tab(tester, 'Audio');
      await rightClick(tester, find.text('coin'));
      expect(items(tester), file);
      expect(labels(tester), ['Copy file', 'Copy path', 'Open', 'Open with…']);
      await pick(tester, 'copyFiles');
      expect(clip.calls.last, 'files:${abs('sfx/coin.wav')}');
      // Right-click doesn't play.
      expect(find.byKey(const ValueKey('progress')), findsNothing);

      await tester.tap(find.text('Cards'));
      await tester.pump();
      await rightClick(tester, find.text('Coin'));
      expect(items(tester), file);
      await pick(tester, 'openWith');
      expect(clip.calls.last, 'openWith:${abs('sfx/coin.wav')}');
      expect(find.byKey(const ValueKey('progress')), findsNothing);

      await tab(tester, 'Other files');
      await rightClick(tester, find.text('notes/readme.txt'));
      expect(items(tester), file);
      await pick(tester, 'copyPath');
      expect(clip.calls.last, 'text:${abs('notes/readme.txt')}');
    });

    testWidgets('material card: Copy file copies all its maps', (tester) async {
      await open(
        tester,
        files: const [
          'Stone/Rock_Color.png',
          'Stone/Rock_Normal.png',
          'Stone/Rock_Roughness.png',
        ],
      );
      await tab(tester, 'Materials');
      await rightClick(
        tester,
        find.byKey(const ValueKey('material:Stone/Rock')),
      );
      expect(items(tester), ['copyFiles', 'copyPath']);
      expect(labels(tester), ['Copy 3 files', 'Copy 3 paths']);
      await pick(tester, 'copyFiles');
      final copied = clip.calls.last.substring(6).split('|');
      expect(copied.toSet(), {
        abs('Stone/Rock_Color.png'),
        abs('Stone/Rock_Normal.png'),
        abs('Stone/Rock_Roughness.png'),
      });
      expect(find.text('3 files copied'), findsOneWidget);
    });

    testWidgets('image viewer: right-click menu and Ctrl+C', (tester) async {
      await open(tester);
      await tab(tester, 'Images');
      await openImage(tester, 'heroes/a.png');
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(ImageViewer), findsOneWidget);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(clip.calls.last, 'image:${abs('heroes/a.png')}');
      expect(find.text('Image copied'), findsOneWidget);
      await rightClick(
        tester,
        find.descendant(
          of: find.byType(ImageViewer),
          matching: find.byType(InteractiveViewer),
        ),
      );
      expect(items(tester), all);
      await pick(tester, 'open');
      expect(clip.calls.last, 'open:${abs('heroes/a.png')}');
    });

    testWidgets('other platforms: only Copy path and Open', (tester) async {
      await open(tester, linux: false);
      await tab(tester, 'Images');
      await rightClick(
        tester,
        find.byKey(const ValueKey('image:heroes/a.png')),
      );
      expect(items(tester), ['copyPath', 'open']);
    });
  });

  group('Card icons (M71)', () {
    Future<void> open(WidgetTester tester) async {
      await openKnight(
        tester,
        files: const ['heroes/a.png', 'heroes/b.png', 'sfx/coin.wav'],
        overrides: [
          trackPlayerFactoryProvider.overrideWithValue(_FakePlayer.new),
          audioDurationProvider.overrideWithValue((_) async => null),
          audioInfoProvider.overrideWithValue((_) async => null),
          audioPeaksProvider.overrideWithValue(
            AudioPeaksCache(read: (_) async => Float32List(0)),
          ),
        ],
      );
    }

    Future<TestGesture> hover(WidgetTester tester, Finder target) async {
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: tester.getCenter(target));
      addTearDown(mouse.removePointer);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      return mouse;
    }

    Future<void> audioCards(WidgetTester tester) async {
      await tester.tap(find.textContaining('Audio ('));
      // The tab slide takes several frames.
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.tap(find.text('Cards'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    }

    final icons = find.byKey(const ValueKey('audio-card-icons'));
    final star = find.byKey(const ValueKey('star:sfx/coin.wav'));
    final reveal = find.descendant(
      of: icons,
      matching: find.byTooltip('Show in file manager'),
    );
    double opacityOf(WidgetTester tester, Finder f) => tester
        .widget<AnimatedOpacity>(
          find.ancestor(of: f, matching: find.byType(AnimatedOpacity)).first,
        )
        .opacity;
    bool ignored(WidgetTester tester, Finder f) => tester
        .widget<IgnorePointer>(
          find.ancestor(of: f, matching: find.byType(IgnorePointer)).first,
        )
        .ignoring;
    Finder cardOf(Finder f) =>
        find.ancestor(of: f, matching: find.byType(Card)).first;

    testWidgets(
      'audio cards: star and reveal only on hover; a set star stays',
      (tester) async {
        await open(tester);
        await audioCards(tester);
        expect(opacityOf(tester, star), 0);
        expect(opacityOf(tester, reveal), 0);
        expect(ignored(tester, star), isTrue);
        expect(ignored(tester, reveal), isTrue);

        final mouse = await hover(tester, cardOf(star));
        expect(opacityOf(tester, star), 1);
        expect(opacityOf(tester, reveal), 1);
        expect(ignored(tester, star), isFalse);
        await tester.tap(star);
        await tester.pump();
        expect(tester.widget<FavoriteStar>(star).starred, isTrue);

        // Off the card: the set star stays, the reveal icon hides.
        await mouse.moveTo(const Offset(5, 5));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(opacityOf(tester, star), 1);
        expect(ignored(tester, star), isFalse);
        expect(opacityOf(tester, reveal), 0);
        // The list rows are unchanged: icons always there.
        await tester.tap(find.text('Rows'));
        await tester.pump();
        expect(
          find.ancestor(of: star, matching: find.byType(AnimatedOpacity)),
          findsNothing,
        );
      },
    );

    testWidgets('image cards: plain star and select box at the audio insets', (
      tester,
    ) async {
      await open(tester);
      await audioCards(tester);
      final audioMouse = await hover(tester, cardOf(star));
      final audioCard = tester.getRect(cardOf(star));
      // The audio card's corner icon: the star (M72; reveal to its left).
      final corner = tester.getRect(star);
      final right = audioCard.right - corner.right;
      final top = corner.top - audioCard.top;
      final size = corner.size;
      expect(
        tester
            .getRect(
              find.descendant(of: icons, matching: find.byType(RevealButton)),
            )
            .size,
        size,
      );
      await audioMouse.removePointer();

      await tester.tap(find.textContaining('Images ('));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      final card = find.byKey(const ValueKey('image:heroes/a.png'));
      await hover(tester, card);
      final imageStar = find.byKey(const ValueKey('star:heroes/a.png'));
      final select = find.byKey(const ValueKey('select:heroes/a.png'));
      final box = tester.getRect(
        find.descendant(of: card, matching: find.byType(Card)),
      );
      final s = tester.getRect(imageStar);
      final b = tester.getRect(select);
      expect(s.size, size);
      expect(box.right - s.right, closeTo(right, 0.01));
      expect(s.top - box.top, closeTo(top, 0.01));
      // The select box mirrors it in the top-left corner.
      expect(b.left - box.left, closeTo(right, 0.01));
      expect(b.top - box.top, closeTo(top, 0.01));
      expect(b.size, size);
      // No disc behind them; a soft shadow under the glyph instead.
      for (final icon in [imageStar, select]) {
        expect(
          find.ancestor(
            of: icon,
            matching: find.byWidgetPredicate(
              (w) => w is Material && w.shape is CircleBorder,
            ),
          ),
          findsNothing,
        );
        final glyph = tester.widget<RichText>(
          find.descendant(of: icon, matching: find.byType(RichText)).first,
        );
        expect(glyph.text.style?.shadows, cardIconShadows);
      }
    });
  });

  group('file search', () {
    final barrels = [for (var i = 0; i < 3; i++) 'props/barrels_$i.png'];

    Future<void> search(WidgetTester tester, String text) async {
      await tester.enterText(find.byType(TextField).first, text);
      // The query runs once typing pauses.
      await tester.pump(DashboardQueryNotifier.searchDebounce);
      // Let the pack and file searches land.
      for (var i = 0; i < 5; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
    }

    testWidgets('Files view: hint, results, and a pack tile match line', (
      tester,
    ) async {
      await openKnight(
        tester,
        open: false,
        files: [...barrels, 'sfx/barrel_roll.wav', 'heroes/a.png'],
      );
      await tester.tap(find.text('Files'));
      await tester.pump();
      expect(store.load().dashboardView, DashboardView.files);
      expect(find.text('Type to search file names'), findsOneWidget);

      await search(tester, 'barrel');
      await pumpUntil(tester, find.text('Barrels 0'));
      expect(find.text('Barrels 1'), findsOneWidget);
      expect(find.text('Barrel roll'), findsOneWidget);
      expect(find.text('Knight Pack · props'), findsNWidgets(3));
      expect(find.text('4 files'), findsOneWidget);
      expect(find.text('A'), findsNothing);

      await tester.tap(find.text('Packs'));
      await tester.pump();
      final line = find.byKey(const ValueKey('file-matches'));
      expect(line, findsOneWidget);
      expect(
        find.descendant(
          of: line,
          matching: find.textContaining('4 files match'),
        ),
        findsOneWidget,
      );
      // The line opens the pack filtered to the search.
      await tester.tap(line);
      await pumpUntil(tester, find.text('Show all files'));
      await tester.pump(const Duration(seconds: 1));
      expect(find.textContaining('Images (3)'), findsOneWidget);
      expect(find.textContaining('Audio (1)'), findsOneWidget);
    });

    testWidgets('a file result opens the detail filtered, not the viewer', (
      tester,
    ) async {
      await openKnight(
        tester,
        open: false,
        files: [...barrels, 'sfx/barrel_roll.wav', 'heroes/a.png'],
      );
      await tester.tap(find.text('Files'));
      await tester.pump();
      await search(tester, 'barrel');
      await pumpUntil(tester, find.text('Barrels 1'));
      await tester.tap(find.text('Barrels 1'));
      await pumpUntil(tester, find.text('Show all files'));
      // The tab slide takes several frames.
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.byType(ImageViewer), findsNothing);

      // Filtered: the Images tab shows only the barrels, and is selected.
      expect(find.text('Matching “barrel”'), findsOneWidget);
      expect(find.textContaining('Images (3)'), findsOneWidget);
      expect(find.textContaining('Audio (1)'), findsOneWidget);
      expect(
        DefaultTabController.of(tester.element(find.byType(TabBar))).index,
        0,
      );
      await tester.tap(find.text('Show all files'));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('Matching “barrel”'), findsNothing);
      // knight.png + 3 barrels + heroes/a.png.
      expect(find.textContaining('Images (5)'), findsOneWidget);
    });

    testWidgets('a sound result opens the detail on the Audio tab', (
      tester,
    ) async {
      await openKnight(
        tester,
        open: false,
        files: [...barrels, 'sfx/barrel_roll.wav'],
      );
      await tester.tap(find.text('Files'));
      await tester.pump();
      await search(tester, 'roll');
      await pumpUntil(tester, find.text('Barrel roll'));
      await tester.tap(find.text('Barrel roll'));
      await pumpUntil(tester, find.text('Show all files'));
      await tester.pump(const Duration(milliseconds: 500));
      final tabs = tester.widget<TabBar>(find.byType(TabBar)).tabs;
      final selected = DefaultTabController.of(
        tester.element(find.byType(TabBar)),
      ).index;
      expect((tabs[selected] as Tab).text, startsWith('Audio'));
      expect(find.byType(ImageViewer), findsNothing);
    });

    testWidgets('infix fallback: "arrel" still finds the barrels', (
      tester,
    ) async {
      await openKnight(tester, open: false, files: barrels);
      await tester.tap(find.text('Files'));
      await tester.pump();
      await search(tester, 'arrel');
      await pumpUntil(tester, find.text('Barrels 2'));
      await tester.tap(find.text('Barrels 2'));
      await pumpUntil(tester, find.text('Show all files'));
      await tester.pump(const Duration(milliseconds: 500));
      // The detail lists the barrels; clicking one opens them in order.
      await openImage(tester, barrels[2]);
      await pumpUntil(tester, find.byType(ImageViewer));
      final viewer = tester.widget<ImageViewer>(find.byType(ImageViewer));
      expect(viewer.images, barrels);
      expect(viewer.initialIndex, 2);
    });
  });

  testWidgets('the "files match" line shows every example in a tooltip', (
    tester,
  ) async {
    await openKnight(
      tester,
      open: false,
      files: [for (var i = 0; i < 4; i++) 'props/barrels_$i.png'],
    );
    await tester.enterText(find.byType(TextField).first, 'barrels');
    await tester.pump(DashboardQueryNotifier.searchDebounce);
    final line = find.byKey(const ValueKey('file-matches'));
    await pumpUntil(tester, line);
    final tip = tester.widget<Tooltip>(
      find.ancestor(of: line, matching: find.byType(Tooltip)).first,
    );
    expect(
      tip.message,
      '4 files match:\nbarrels_0.png\nbarrels_1.png\nbarrels_2.png\n'
      'barrels_3.png',
    );
  });

  group('app shortcuts', () {
    late List<String> picked;
    late int scans;
    late ProviderContainer container;

    Future<void> start(WidgetTester tester) async {
      picked = [];
      await openKnight(
        tester,
        open: false,
        overrides: [
          directoryPickerProvider.overrideWithValue((title) async {
            picked.add(title);
            return null;
          }),
          archivePickerProvider.overrideWithValue(() async {
            picked.add('archive');
            return const <String>[];
          }),
        ],
      );
      scans = 0;
      container = ProviderScope.containerOf(
        tester.element(find.byType(HomeScreen)),
      );
      final sub = container.listen(libraryProvider, (_, next) {
        if (next.isLoading) scans++;
      });
      addTearDown(sub.close);
    }

    Future<void> press(
      WidgetTester tester,
      LogicalKeyboardKey key, {
      bool ctrl = true,
    }) async {
      if (ctrl) await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(key);
      if (ctrl) await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
    }

    Future<void> scanDone(WidgetTester tester) async {
      for (
        var i = 0;
        i < 200 && container.read(libraryProvider).isLoading;
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      await pumpUntil(tester, find.text('Knight Pack'));
    }

    /// Each app-wide shortcut, then `/` (dashboard only).
    Future<void> expectAllWork(WidgetTester tester) async {
      await press(tester, LogicalKeyboardKey.keyI);
      expect(picked, ['Import folder']);
      await press(tester, LogicalKeyboardKey.keyO);
      expect(picked, ['Import folder', 'archive']);
      await press(tester, LogicalKeyboardKey.keyR);
      expect(scans, 1);
      await scanDone(tester);
      await press(tester, LogicalKeyboardKey.f5, ctrl: false);
      expect(scans, 2);
      await scanDone(tester);
      await press(tester, LogicalKeyboardKey.comma);
      await tester.pumpAndSettle();
      expect(find.byType(SettingsScreen), findsOneWidget);
      // Not twice.
      await press(tester, LogicalKeyboardKey.comma);
      await tester.pumpAndSettle();
      expect(find.byType(SettingsScreen), findsOneWidget);
      // Rescan works on other pages too.
      await press(tester, LogicalKeyboardKey.keyR);
      expect(scans, 3);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      // The scan's progress bar never settles.
      await scanDone(tester);
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(SettingsScreen), findsNothing);
      // `/` still reaches the dashboard after the settings page closed.
      await tester.sendKeyEvent(LogicalKeyboardKey.slash);
      await tester.pump();
      final field = tester.widget<TextField>(find.byType(TextField).first);
      expect(field.focusNode!.hasFocus, isTrue);
    }

    testWidgets('work after a click on empty space', (tester) async {
      await start(tester);
      // Focus the search, then click on empty grid space.
      await tester.tap(find.byType(TextField).first);
      await tester.pump();
      await tester.tapAt(const Offset(1300, 860));
      await tester.pump();
      final field = tester.widget<TextField>(find.byType(TextField).first);
      expect(field.focusNode!.hasFocus, isFalse);
      await expectAllWork(tester);
    });

    testWidgets('work after returning from a pack page', (tester) async {
      await start(tester);
      await tester.tap(find.text('Knight Pack'));
      await pumpUntil(tester, find.byType(TabBar));
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      // The tab slide takes several frames.
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.byType(TabBar), findsNothing);
      await expectAllWork(tester);
    });

    testWidgets('Ctrl+F works after leaving the search with Esc', (
      tester,
    ) async {
      await start(tester);
      final focus = tester
          .widget<TextField>(find.byType(TextField).first)
          .focusNode!;
      await press(tester, LogicalKeyboardKey.keyF);
      expect(focus.hasFocus, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(focus.hasFocus, isFalse);
      await press(tester, LogicalKeyboardKey.keyF);
      expect(focus.hasFocus, isTrue);
    });

    testWidgets('the import icon opens a menu with both imports (M45)', (
      tester,
    ) async {
      await start(tester);
      final bar = find.byType(AppBar);
      final button = find.descendant(
        of: bar,
        matching: find.byTooltip('Import'),
      );
      expect(button, findsOneWidget);
      // Same size as Help and Settings next to it.
      final help = find.byTooltip('How Loot Silo works (F1)');
      expect(tester.getSize(button), tester.getSize(help));
      await tester.tap(button);
      await tester.pumpAndSettle();
      final folder = find.text('Import folder… (Ctrl+I)');
      final archive = find.text('Import archive… (Ctrl+O)');
      expect(folder, findsOneWidget);
      expect(archive, findsOneWidget);
      // Esc closes the menu.
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(folder, findsNothing);
      await tester.tap(button);
      await tester.pumpAndSettle();
      await tester.tap(folder);
      await tester.pumpAndSettle();
      expect(picked, ['Import folder']);
      await tester.tap(button);
      await tester.pumpAndSettle();
      await tester.tap(archive);
      await tester.pumpAndSettle();
      expect(picked, ['Import folder', 'archive']);
    });

    testWidgets('import shortcuts skip an open dialog', (tester) async {
      await start(tester);
      // The sort menu is a popup route.
      await tester.tap(find.byType(DropdownButton<PackSort>));
      await tester.pumpAndSettle();
      await press(tester, LogicalKeyboardKey.keyI);
      await press(tester, LogicalKeyboardKey.comma);
      await tester.pump();
      expect(picked, isEmpty);
      expect(find.byType(SettingsScreen), findsNothing);
    });
  });

  group('Animation editor (M26)', () {
    /// A 4×2 grid of 16 px cells, opened in the Edit dialog.
    Future<void> openGrid(
      WidgetTester tester, {
      Size size = const Size(1600, 900),
    }) async {
      final sheet = img.Image(width: 64, height: 32, numChannels: 4);
      img.fill(sheet, color: img.ColorRgba8(220, 120, 40, 255));
      await openKnight(
        tester,
        size: size,
        files: const [],
        images: {'fx/Explosion(16x16).png': sheet},
      );
      // Narrow test windows overflow the dashboard's filter bar (Ahem
      // glyphs are wide); only the editor is checked here.
      tester.takeException();
      await tester.tap(find.textContaining('Animations ('));
      await tester.pump(const Duration(milliseconds: 500));
      // Short windows leave the card at the bottom edge: hover the
      // (hidden) button itself.
      final edit = find.byTooltip('Edit animation');
      await tester.ensureVisible(edit);
      await tester.pump();
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: tester.getCenter(edit));
      addTearDown(mouse.removePointer);
      await tester.pump();
      await tester.tap(find.byTooltip('Edit animation'));
      await pumpUntil(tester, find.text('Apply size'));
    }

    String sidecar() => File(
      p.join(
        tmp.path,
        'library',
        'HeroMaker',
        'Knight Pack',
        'asset_pack.json',
      ),
    ).readAsStringSync();

    testWidgets('All rows is the default; one row can be saved (M34)', (
      tester,
    ) async {
      await openGrid(tester);
      FilledButton save() => tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Save'),
      );
      expect(save().onPressed, isNull);
      // A 4×2 grid plays every row out of the box (dialog and card).
      for (final s in tester.widgetList<AnimatedSprite>(
        find.byType(AnimatedSprite),
      )) {
        expect(s.anim.rowToPlay, isNull);
      }
      await tester.tap(find.text('All rows'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Row 1').last);
      await tester.pumpAndSettle();
      expect(save().onPressed, isNotNull, reason: 'the row choice is dirty');
      await tester.tap(find.text('Save'));
      await pumpUntil(tester, find.text('Reset to detected'));
      expect(sidecar(), contains('"rows": 1'));
      final sprites = tester.widgetList<AnimatedSprite>(
        find.byType(AnimatedSprite),
      );
      expect(sprites, isNotEmpty);
      for (final s in sprites) {
        expect(s.anim.rowToPlay, 0);
      }
    });

    /// "Not an animation", confirmed in its dialog.
    Future<void> markNotAnimation(WidgetTester tester) async {
      await tester.tap(find.text('Not an animation'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('confirm-not-animation')));
      await tester.pump();
    }

    testWidgets('Not an animation asks first; Cancel changes nothing (M45)', (
      tester,
    ) async {
      await openGrid(tester);
      await tester.tap(find.text('Not an animation'));
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Mark "Explosion(16x16)" as not an animation? It moves to the '
          'Images tab; you can restore it there.',
        ),
        findsOneWidget,
      );
      expect(find.text('Mark as image'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byType(AnimationEditor), findsOneWidget);
      expect(sidecar(), isNot(contains('animations')));
      // Confirming marks it.
      await markNotAnimation(tester);
      await pumpUntil(tester, find.textContaining('listed as an image only'));
      expect(sidecar(), contains('"fx/Explosion(16x16).png": false'));
    });

    testWidgets('Not an animation moves the file to Images and back', (
      tester,
    ) async {
      await openGrid(tester);
      await markNotAnimation(tester);
      await pumpUntil(tester, find.textContaining('listed as an image only'));
      await pumpUntilGone(tester, find.textContaining('Animations ('));
      expect(sidecar(), contains('"fx/Explosion(16x16).png": false'));
      expect(find.text('1 marked not an animation'), findsOneWidget);

      await tester.tap(find.text('1 marked not an animation'));
      await tester.pumpAndSettle();
      expect(find.text('fx/Explosion(16x16).png'), findsOneWidget);
      await tester.tap(find.text('Restore'));
      await pumpUntil(tester, find.textContaining('Animations ('));
      expect(sidecar(), isNot(contains('animations')));
    });

    testWidgets('wheel and −/+/reset over the preview set the saved zoom', (
      tester,
    ) async {
      await openGrid(tester);
      final preview = find.byType(ZoomPreview);
      final center = tester.getCenter(preview);
      FilledButton save() => tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Save'),
      );
      String value() =>
          tester.widget<Text>(find.byKey(const ValueKey('zoom-value'))).data!;
      // No Zoom dropdown any more.
      expect(find.byKey(const ValueKey('zoom')), findsNothing);
      expect(find.byKey(const ValueKey('zoom-overlay')), findsNothing);
      final summary = find.textContaining('Sheet · ');
      final summaryBefore = tester.widget<Text>(summary).data;

      // Hover shows the overlay at Auto; Save stays off.
      final pointer = TestPointer(7, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(pointer.hover(center));
      await tester.pump();
      expect(find.byKey(const ValueKey('zoom-overlay')), findsOneWidget);
      expect(value(), 'Auto');
      expect(save().onPressed, isNull);

      // Wheel up: one whole step above the fit.
      await tester.sendEventToBinding(pointer.scroll(const Offset(0, -20)));
      await tester.pump();
      final up = int.parse(value().replaceAll('×', ''));
      expect(up, inInclusiveRange(2, 8));
      expect(save().onPressed, isNotNull);
      // The wheel over the image leaves the frame count alone.
      expect(tester.widget<Text>(summary).data, summaryBefore);
      await tester.sendEventToBinding(pointer.scroll(const Offset(0, 20)));
      await tester.pump();
      expect(value(), '${up - 1}×');

      // + and −, then reset back to Auto (not dirty any more).
      await tester.tap(find.byKey(const ValueKey('zoom-in')));
      await tester.pump();
      expect(value(), '$up×');
      await tester.tap(find.byKey(const ValueKey('zoom-out')));
      await tester.pump();
      expect(value(), '${up - 1}×');
      await tester.tap(find.byKey(const ValueKey('zoom-reset')));
      await tester.pump();
      expect(value(), 'Auto');
      expect(save().onPressed, isNull);

      // Saved and drawn on the card.
      await tester.tap(find.byKey(const ValueKey('zoom-in')));
      await tester.pump();
      await tester.tap(find.text('Save'));
      await pumpUntil(tester, find.text('Reset to detected'));
      expect(sidecar(), contains('"zoom": $up'));
      for (final s in tester.widgetList<AnimatedSprite>(
        find.byType(AnimatedSprite),
      )) {
        expect(s.anim.zoom, up);
      }
      // Reset clears it again.
      await tester.tap(find.text('Reset to detected'));
      await pumpUntil(tester, find.text('Not an animation'));
      await tester.pump(const Duration(milliseconds: 500));
      expect(sidecar(), isNot(contains('zoom')));
      await tester.sendEventToBinding(pointer.removePointer());
    });

    testWidgets('Undo on the snackbar restores the animation', (tester) async {
      await openGrid(tester);
      await markNotAnimation(tester);
      final undo = find.widgetWithText(SnackBarAction, 'Undo');
      await pumpUntil(tester, undo);
      // Let the snackbar slide in before tapping it.
      await tester.pump(const Duration(seconds: 1));
      await tester.tap(undo);
      await pumpUntil(tester, find.textContaining('Animations ('));
      expect(sidecar(), isNot(contains('animations')));
    });

    testWidgets('the Undo snackbar hides by itself (M33)', (tester) async {
      await openGrid(tester);
      await markNotAnimation(tester);
      final undo = find.widgetWithText(SnackBarAction, 'Undo');
      await pumpUntil(tester, undo);
      final bar = tester.widget<SnackBar>(find.byType(SnackBar));
      expect(bar.persist, isFalse);
      expect(bar.duration, undoSnackDuration);
      // Fake time: the slide-in (the timer starts after it), its
      // duration, then the slide-out.
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(SnackBar), findsOneWidget);
      await tester.pump(undoSnackDuration);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(SnackBar), findsNothing);
      // Nothing was undone.
      expect(sidecar(), contains('animations'));
    });

    testWidgets('−/+ step the frame count to counts that fit', (tester) async {
      await openGrid(tester);
      final frames = find.widgetWithText(TextField, 'Frames');
      String count() => tester.widget<TextField>(frames).controller!.text;
      expect(count(), '8');
      await tester.tap(find.byTooltip('Fewer frames'));
      await tester.pump();
      expect(count(), '7');
      expect(find.textContaining("Doesn't fit"), findsNothing);
      await tester.tap(find.byTooltip('More frames'));
      await tester.tap(find.byTooltip('More frames'));
      await tester.pump();
      final n = int.parse(count());
      expect(n, greaterThan(8));
      expect(find.textContaining("Doesn't fit"), findsNothing);
      // Arrow keys in the field do the same.
      await tester.tap(frames);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(int.parse(count()), lessThan(n));
      // And the wheel.
      final before = int.parse(count());
      final mouse = TestPointer(1, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(mouse.hover(tester.getCenter(frames)));
      await tester.sendEventToBinding(mouse.scroll(const Offset(0, -20)));
      await tester.pump();
      expect(int.parse(count()), greaterThan(before));
    });

    for (final size in const [
      Size(1024, 600),
      Size(1280, 720),
      Size(1920, 1200),
    ]) {
      testWidgets(
        'dialog fits at ${size.width.toInt()}×${size.height.toInt()}',
        (tester) async {
          await openGrid(tester, size: size);
          expect(tester.takeException(), isNull);
          final preview = tester.getRect(
            find
                .ancestor(
                  of: find.byType(AnimatedSprite).last,
                  matching: find.byType(Container),
                )
                .first,
          );
          expect(preview.height, greaterThanOrEqualTo(240));
          final dialog = tester.getRect(find.byType(Dialog));
          expect(dialog.bottom, lessThanOrEqualTo(size.height));
          expect(find.text('Not an animation'), findsOneWidget);
        },
      );
    }
  });

  group('Banner strips (M34)', () {
    /// 1152×128 with 12 frames of 96×128, a transparent gap in each.
    img.Image banner() {
      final image = img.Image(width: 1152, height: 128, numChannels: 4);
      for (var i = 0; i < 12; i++) {
        img.fillRect(
          image,
          x1: i * 96 + 6,
          y1: 4,
          x2: i * 96 + 89,
          y2: 123,
          color: img.ColorRgba8(40, 120, 220, 255),
        );
      }
      return image;
    }

    String sidecar() => File(
      p.join(
        tmp.path,
        'library',
        'HeroMaker',
        'Knight Pack',
        'asset_pack.json',
      ),
    ).readAsStringSync();

    testWidgets('12 frames of 96×128, also when typed into Frames', (
      tester,
    ) async {
      await openKnight(
        tester,
        files: const ['props/portrait.png'],
        images: {
          'props/animated/banner-only.png': banner(),
          // No animation word: only the square guess (9 × 128). Opaque
          // like water tiles, so its frames look alike and it stays a
          // strip (M43: a banner drawn across the cuts is one picture).
          'props/banner-plain.png': img.fill(
            img.Image(width: 1152, height: 128, numChannels: 4),
            color: img.ColorRgba8(40, 120, 220, 255),
          ),
        },
      );
      tester.takeException();
      // Both strips are animations, not images.
      expect(find.textContaining('Animations (2)'), findsOneWidget);
      await tester.tap(find.textContaining('Animations ('));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('96×128 · 12 frames · 10 fps'), findsOneWidget);
      expect(find.text('128×128 · 9 frames · 10 fps'), findsOneWidget);

      // The square guess, set to 12 frames by hand.
      final card = find.ancestor(
        of: find.text('128×128 · 9 frames · 10 fps'),
        matching: find.byType(Card),
      );
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: tester.getCenter(card.first));
      addTearDown(mouse.removePointer);
      await tester.pump();
      await tester.tap(
        find.descendant(of: card, matching: find.byTooltip('Edit animation')),
      );
      await pumpUntil(tester, find.text('Apply size'));
      final frames = find.widgetWithText(TextField, 'Frames');
      await tester.enterText(frames, '');
      await tester.enterText(frames, '1');
      await tester.enterText(frames, '12');
      await tester.pump();
      String field(String label) => tester
          .widget<TextField>(find.widgetWithText(TextField, label))
          .controller!
          .text;
      expect((field('Frame width'), field('Frame height')), ('96', '128'));
      expect(find.textContaining('12 × 1 · 12 frames'), findsOneWidget);
      // One row: no row choice.
      expect(find.text('All rows'), findsNothing);
      await tester.tap(find.text('Save'));
      await pumpUntil(tester, find.text('Reset to detected'));
      expect(sidecar(), contains('"frames": 12'));
      await tester.tap(find.text('Close'));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('96×128 · 12 frames · 10 fps'), findsNWidgets(2));
      for (final s in tester.widgetList<AnimatedSprite>(
        find.byType(AnimatedSprite),
      )) {
        expect((s.anim.frameW, s.anim.cols, s.anim.rows), (96, 12, 1));
      }
    });
  });

  group('Make animations from images (M28)', () {
    img.Image solid(int w, int h, int shade) {
      final i = img.Image(width: w, height: h, numChannels: 4);
      img.fill(i, color: img.ColorRgba8(shade, 90, 200, 255));
      return i;
    }

    String packDir() => p.join(tmp.path, 'library', 'HeroMaker', 'Knight Pack');
    String sidecar() =>
        File(p.join(packDir(), 'asset_pack.json')).readAsStringSync();

    Future<void> openImages(
      WidgetTester tester,
      Map<String, img.Image> images, {
      bool byFolder = false,
      Size size = const Size(1600, 900),
    }) async {
      await openKnight(tester, files: const [], images: images, size: size);
      await tester.tap(find.textContaining('Images ('));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.text(byFolder ? 'By folder' : 'Flat').first);
      await tester.pump(const Duration(milliseconds: 300));
    }

    Future<TestGesture> hover(WidgetTester tester, String name) async {
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(
        location: tester.getCenter(
          find
              .ancestor(
                of: find.text(prettyName(name)),
                matching: find.byType(Card),
              )
              .first,
        ),
      );
      addTearDown(mouse.removePointer);
      await tester.pump();
      return mouse;
    }

    testWidgets('Make animation… on an image card saves a strip', (
      tester,
    ) async {
      await openImages(tester, {
        'ui/panel.png': solid(64, 16, 10),
        'ui/portrait.png': solid(20, 30, 40),
      });
      expect(find.textContaining('Animations ('), findsNothing);
      final mouse = await hover(tester, 'panel.png');
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('image:ui/panel.png')),
          matching: find.byTooltip('Make animation…'),
        ),
      );
      await pumpUntil(tester, find.text('Apply size'));
      expect(find.text('Sheet · 16×16 frames · 4 × 1 · 4 frames'), findsOne);
      expect(find.text('Not an animation'), findsNothing);
      await tester.tap(find.text('Save'));
      await pumpUntil(tester, find.text('Back to image'));
      expect(sidecar(), contains('"manual": true'));
      await tester.tap(find.text('Close'));
      await pumpUntil(tester, find.textContaining('Animations (1)'));
      await tester.pump(const Duration(milliseconds: 500));
      // Still on the Images tab after the rescan; the strip is listed under
      // Animations only (M34).
      expect(find.text('Portrait'), findsOneWidget);
      expect(find.text('Panel'), findsNothing);
      await tester.tap(find.textContaining('Animations ('));
      final edit = find.byIcon(Icons.tune);
      // The tab slide takes several frames.
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await pumpUntil(tester, edit);
      await tester.pump(const Duration(milliseconds: 500));
      await mouse.moveTo(
        tester.getCenter(
          find.ancestor(of: edit, matching: find.byType(Card)).first,
        ),
      );
      await tester.pump();
      await tester.tap(edit);
      await pumpUntil(tester, find.text('Back to image'));
      await tester.tap(find.text('Back to image'));
      await pumpUntilGone(tester, find.textContaining('Animations ('));
      expect(sidecar(), isNot(contains('manual')));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('Apply size'), findsNothing, reason: 'dialog closed');
      // Back among the images.
      expect(find.text('Panel'), findsOneWidget);
    });

    testWidgets('Make animation… starts from the guessed grid (M47)', (
      tester,
    ) async {
      // A 3×3 grid of 48 px cells with 8 small sprites and no animation
      // word: not detected, but the gaps give the cells.
      final grid = img.Image(width: 144, height: 144, numChannels: 4);
      for (var i = 0; i < 8; i++) {
        final x = (i % 3) * 48 + 18;
        final y = (i ~/ 3) * 48 + 14;
        img.fillRect(
          grid,
          x1: x,
          y1: y,
          x2: x + 11,
          y2: y + 19,
          color: img.ColorRgba8(200, 80, 40, 255),
        );
      }
      await openImages(tester, {
        'npc/reeling.png': grid,
        'npc/portrait.png': solid(20, 30, 40),
      });
      expect(find.textContaining('Animations ('), findsNothing);
      await hover(tester, 'reeling.png');
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('image:npc/reeling.png')),
          matching: find.byTooltip('Make animation…'),
        ),
      );
      await pumpUntil(tester, find.text('Apply size'));
      expect(find.text('Sheet · 48×48 frames · 3 × 3 · 8 frames'), findsOne);
      await tester.tap(find.text('Save'));
      await pumpUntil(tester, find.text('Back to image'));
      expect(sidecar(), contains('"frames": 8'));
      await tester.tap(find.text('Close'));
      await pumpUntil(tester, find.textContaining('Animations (1)'));
      await tester.pump(const Duration(milliseconds: 500));
      // Detected again from the sidecar: the same grid.
      await tester.tap(find.textContaining('Animations ('));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await pumpUntil(tester, find.textContaining('48×48 · 8 frames'));
    });

    /// Every file under the pack with its bytes, to show nothing changed.
    Map<String, String> snapshot() => {
      for (final f in Directory(packDir()).listSync(recursive: true))
        if (f is File)
          p.relative(f.path, from: packDir()): f.readAsBytesSync().join(','),
    };

    testWidgets('a folder header Combine opens the editor directly (M41)', (
      tester,
    ) async {
      await openImages(tester, {
        'fx/puff/puff_c.png': solid(8, 8, 30),
        'fx/puff/puff_a.png': solid(8, 8, 10),
        'fx/puff/puff_b.png': solid(6, 6, 20),
        'single/one.png': solid(8, 8, 40),
      }, byFolder: true);
      // Only folders with 2+ images get the button, right after the name.
      final button = find.text('Combine into animation');
      expect(button, findsOneWidget);
      final name = find.text('Fx');
      expect(name, findsOneWidget);
      expect(
        tester.getRect(button).left - tester.getRect(name).right,
        lessThan(120),
      );
      final out = File(p.join(packDir(), 'fx', 'puff', 'puff_animation.png'));
      final before = snapshot();

      // No confirmation: the preview opens, nothing on disk; Esc leaves.
      await tester.tap(button);
      await pumpUntil(tester, find.text('Apply size'));
      expect(find.byKey(const ValueKey('combine-confirm')), findsNothing);
      expect(find.text('Continue'), findsNothing);
      expect(find.text('Sheet · 8×8 frames · 3 × 1 · 3 frames'), findsOne);
      expect(find.textContaining('not saved yet'), findsOneWidget);
      expect(find.text('Not an animation'), findsNothing);
      final field = find.byKey(const ValueKey('combine-name'));
      expect(
        tester.widget<TextField>(field).controller!.text,
        'puff_animation',
      );
      final sprite = tester.widget<AnimatedSprite>(
        find.descendant(
          of: find.byType(ZoomPreview),
          matching: find.byType(AnimatedSprite),
        ),
      );
      expect(sprite.bytes, isNotNull);
      expect(snapshot(), before);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Apply size'), findsNothing);
      expect(snapshot(), before);

      // Save writes the strip and the sidecar entry.
      await tester.tap(button);
      await pumpUntil(tester, find.text('Apply size'));
      await tester.tap(find.text('Save'));
      await pumpUntil(tester, find.text('Back to image'));
      expect(out.existsSync(), isTrue);
      final strip = img.decodePng(out.readAsBytesSync())!;
      expect((strip.width, strip.height), (24, 8));
      expect(sidecar(), contains('"manual": true'));
      expect(sidecar(), contains('"frame_w": 8'));
      // Saved: no name field any more.
      expect(field, findsNothing);
      await tester.tap(find.text('Close'));
      await pumpUntil(tester, find.textContaining('Animations (1)'));

      // Again: Save asks before replacing; Cancel keeps the old file.
      await tester.pump(const Duration(milliseconds: 500));
      final saved = out.readAsBytesSync();
      await tester.tap(find.text('Combine into animation').first);
      await pumpUntil(tester, find.text('Apply size'));
      await tester.tap(find.text('Save'));
      await pumpUntil(tester, find.text('Replace animation?'));
      await tester.tap(find.text('Cancel'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(out.readAsBytesSync(), saved);
      expect(find.text('Apply size'), findsOneWidget, reason: 'still editing');
    });

    testWidgets('the new file can be named; bad names block Save (M41)', (
      tester,
    ) async {
      await openImages(
        tester,
        {
          'fx/puff/puff_a.png': solid(8, 8, 10),
          'fx/puff/puff_b.png': solid(8, 8, 20),
          'fx/puff/taken.png': solid(8, 8, 30),
        },
        byFolder: true,
        size: const Size(1600, 1600),
      );
      final before = snapshot();
      await tester.tap(find.text('Combine into animation'));
      await pumpUntil(tester, find.text('Apply size'));
      final field = find.byKey(const ValueKey('combine-name'));
      final save = find.widgetWithText(FilledButton, 'Save');
      bool canSave() => tester.widget<FilledButton>(save).onPressed != null;
      expect(canSave(), isTrue);

      for (final (bad, message) in [
        ('', 'Enter a file name'),
        ('a/b', 'Not allowed: / \\ < > : " | ? *'),
        ('what?', 'Not allowed: / \\ < > : " | ? *'),
        ('.hidden', 'The name can\'t start with a dot'),
      ]) {
        await tester.enterText(field, bad);
        await tester.pump();
        expect(canSave(), isFalse, reason: bad);
        expect(find.text(message), findsOneWidget, reason: bad);
      }

      // An existing name asks before replacing; Cancel writes nothing.
      await tester.enterText(field, 'taken');
      await tester.pump();
      await tester.tap(save);
      await pumpUntil(tester, find.text('Replace animation?'));
      expect(
        find.text('fx/puff/taken.png already exists. Replace it?'),
        findsOneWidget,
      );
      await tester.tap(find.text('Cancel'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(snapshot(), before);

      // A free name is written on Save, under that name only. The title
      // and path follow the field.
      await tester.enterText(field, 'smoke puff');
      await tester.pump();
      expect(find.text('fx/puff/smoke puff.png'), findsOneWidget);
      expect(find.text('Smoke puff'), findsOneWidget);
      await tester.tap(save);
      await pumpUntil(tester, find.text('Back to image'));
      final out = File(p.join(packDir(), 'fx', 'puff', 'smoke puff.png'));
      expect(out.existsSync(), isTrue);
      expect(
        File(p.join(packDir(), 'fx', 'puff', 'puff_animation.png'))
            .existsSync(),
        isFalse,
      );
      expect(sidecar(), contains('"fx/puff/smoke puff.png"'));
      await tester.tap(find.text('Close'));
      await pumpUntil(tester, find.textContaining('Animations (1)'));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.textContaining('Animations ('));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.text('Smoke puff'), findsOneWidget);
    });

    testWidgets('Cancel on a renamed strip writes nothing (M41)', (
      tester,
    ) async {
      await openImages(tester, {
        'fx/a.png': solid(8, 8, 10),
        'fx/b.png': solid(8, 8, 20),
      }, byFolder: true);
      final before = snapshot();
      await tester.tap(find.text('Combine into animation'));
      await pumpUntil(tester, find.text('Apply size'));
      await tester.enterText(find.byKey(const ValueKey('combine-name')), 'x');
      await tester.pump();
      await tester.tap(find.text('Close'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Apply size'), findsNothing);
      expect(snapshot(), before);
    });

    Future<void> clickWith(
      WidgetTester tester,
      LogicalKeyboardKey? key,
      String rel,
    ) async {
      if (key != null) await tester.sendKeyDownEvent(key);
      await tester.tap(find.byKey(ValueKey('image:$rel')));
      if (key != null) await tester.sendKeyUpEvent(key);
      await tester.pump(const Duration(milliseconds: 300));
    }

    testWidgets('Flat view: Ctrl/Shift-click select, then combine', (
      tester,
    ) async {
      await openImages(tester, {
        'a/k1.png': solid(8, 8, 10),
        'a/k2.png': solid(8, 8, 20),
        'a/k3.png': solid(8, 8, 30),
        'b/z.png': solid(8, 8, 40),
      });
      await clickWith(tester, LogicalKeyboardKey.controlLeft, 'a/k1.png');
      expect(find.text('1 selected'), findsOneWidget);
      final combine = find.widgetWithText(
        FilledButton,
        'Combine 1 images into animation',
      );
      expect(tester.widget<FilledButton>(combine).onPressed, isNull);
      await clickWith(tester, LogicalKeyboardKey.shiftLeft, 'a/k3.png');
      expect(find.text('3 selected'), findsOneWidget);
      // The hover checkbox toggles too.
      await hover(tester, 'z.png');
      await tester.tap(find.byKey(const ValueKey('select:b/z.png')));
      await tester.pump();
      expect(find.text('4 selected'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('select:b/z.png')));
      await tester.pump();
      // Straight to the editor (M41).
      await tester.tap(find.text('Combine 3 images into animation'));
      await pumpUntil(tester, find.text('Apply size'));
      expect(find.text('Sheet · 8×8 frames · 3 × 1 · 3 frames'), findsOne);
      final out = File(p.join(packDir(), 'a', 'a_animation.png'));
      expect(out.existsSync(), isFalse);
      await tester.tap(find.text('Save'));
      await pumpUntil(tester, find.text('Back to image'));
      expect(out.existsSync(), isTrue);
      await tester.tap(find.text('Close'));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.textContaining('selected'), findsNothing);
    });

    testWidgets('By folder: select across folders; kept when folded (M41)', (
      tester,
    ) async {
      await openImages(
        tester,
        {
          'a/k1.png': solid(8, 8, 10),
          'a/k2.png': solid(8, 8, 20),
          'b/z1.png': solid(8, 8, 30),
          'b/z2.png': solid(8, 8, 40),
        },
        byFolder: true,
        size: const Size(1600, 1600),
      );
      // A plain click focuses, it doesn't select.
      await clickWith(tester, null, 'a/k1.png');
      expect(find.textContaining('selected'), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();

      await clickWith(tester, LogicalKeyboardKey.controlLeft, 'a/k2.png');
      expect(find.text('1 selected'), findsOneWidget);
      // Shift: a range in on-screen order, across the folder break.
      await clickWith(tester, LogicalKeyboardKey.shiftLeft, 'b/z1.png');
      expect(find.text('2 selected'), findsOneWidget);
      ItemCard card(String rel) =>
          tester.widget<ItemCard>(find.byKey(ValueKey('image:$rel')));
      expect(card('a/k2.png').selected, isTrue);
      expect(card('b/z1.png').selected, isTrue);
      expect(card('a/k1.png').selected, isFalse);

      // The bar has room below it, like above.
      final bar = tester.getRect(find.byKey(const ValueKey('selection-bar')));
      final row = tester.getRect(
        find
            .descendant(
              of: find.byKey(const ValueKey('selection-bar')),
              matching: find.byType(Row),
            )
            .first,
      );
      expect(bar.bottom - row.bottom, 8);
      expect(row.top - bar.top, 4);

      // Folding a folder and switching views keep the selection.
      await tester.tap(find.text('B'));
      await tester.pump();
      expect(find.text('2 selected'), findsOneWidget);
      await tester.tap(find.text('Flat'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('2 selected'), findsOneWidget);
      expect(card('b/z1.png').selected, isTrue);
    });

    testWidgets('the select box is the size of the reveal icon (M41)', (
      tester,
    ) async {
      await openImages(tester, {
        'a/k1.png': solid(8, 8, 10),
        'a/k2.png': solid(8, 8, 20),
      });
      await hover(tester, 'k1.png');
      final card = find.byKey(const ValueKey('image:a/k1.png'));
      final reveal = find.ancestor(
        of: find.descendant(
          of: card,
          matching: find.byTooltip('Show in file manager'),
        ),
        matching: find.byType(IconButton),
      );
      expect(
        tester.getSize(find.byKey(const ValueKey('select:a/k1.png'))),
        tester.getSize(reveal.first),
      );
    });
  });

  group('Detail search (M30)', () {
    final files = [
      'props/barrels_0.png',
      'props/barrels_1.png',
      'heroes/knight_red/a.png',
      'sfx/barrel_roll.wav',
      'sfx/sword.wav',
      'docs/readme.txt',
    ];

    Finder field() => find.widgetWithText(TextField, 'Search files');

    testWidgets('the size slider is as wide as the search box (M33)', (
      tester,
    ) async {
      await openKnight(tester, files: files);
      final search = tester.getRect(field());
      final slider = tester.getRect(find.byType(ThumbSizeSlider));
      expect(slider.width, search.width);
      expect(slider.width, detailControlWidth);
      // Right under it, same right edge.
      expect(slider.right, closeTo(search.right, 0.5));
    });

    Future<void> type(WidgetTester tester, String text) async {
      await tester.enterText(field(), text);
      await tester.pump(DashboardQueryNotifier.searchDebounce);
      await tester.pump(const Duration(milliseconds: 300));
    }

    Future<void> ctrlF(WidgetTester tester) async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
    }

    bool searchFocused(WidgetTester tester) =>
        tester.widget<TextField>(field()).focusNode!.hasFocus;

    testWidgets('typing restarts the 250 ms wait on every key', (tester) async {
      await openKnight(tester, files: files);
      expect(find.text('Images (4)'), findsOneWidget);
      var text = '';
      for (final ch in 'barrel'.split('')) {
        text += ch;
        await tester.enterText(field(), text);
        await tester.pump(const Duration(milliseconds: 240));
        expect(find.text('Images (4)'), findsOneWidget, reason: text);
      }
      await tester.pump(const Duration(milliseconds: 9));
      expect(find.text('Images (4)'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pump();
      expect(find.text('Images (2)'), findsOneWidget);
    });

    testWidgets('filters every tab, counts follow, Esc clears', (tester) async {
      await openKnight(tester, files: files);
      expect(find.text('Images (4)'), findsOneWidget);
      expect(find.text('Audio (2)'), findsOneWidget);
      expect(find.text('Other files (1)'), findsOneWidget);

      // Debounced: nothing changes until typing pauses.
      await tester.enterText(field(), 'barrel');
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('Images (4)'), findsOneWidget);
      await tester.pump(DashboardQueryNotifier.searchDebounce);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Images (2)'), findsOneWidget);
      expect(find.text('Audio (1)'), findsOneWidget);
      // No match in Other files: that tab goes.
      expect(find.textContaining('Other files'), findsNothing);
      expect(find.text('Matching “barrel”'), findsOneWidget);
      // Image cards show pretty titles (M40).
      expect(find.text('Barrels 0'), findsOneWidget);
      expect(find.byKey(const ValueKey('image:a.png')), findsNothing);

      // The open tab stays even without matches.
      await type(tester, 'sword');
      expect(find.text('Images (0)'), findsOneWidget);
      expect(find.text('No files match “sword”'), findsOneWidget);
      expect(find.text('Audio (1)'), findsOneWidget);

      // Infix fallback, like the dashboard.
      await type(tester, 'arrel');
      expect(find.text('Images (2)'), findsOneWidget);

      // Esc in the field clears it, a second Esc leaves the field, and the
      // page is still open.
      expect(searchFocused(tester), isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(find.text('Images (4)'), findsOneWidget);
      expect(find.text('Other files (1)'), findsOneWidget);
      expect(find.textContaining('Matching'), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(searchFocused(tester), isFalse);
      expect(find.byType(PackDetailScreen), findsOneWidget);

      // Ctrl+F focuses it again (focus stayed on the page).
      await ctrlF(tester);
      expect(searchFocused(tester), isTrue);
    });

    testWidgets('works inside the folder filter', (tester) async {
      await openKnight(
        tester,
        files: ['Archer/c.png', 'Archer/bow.png', 'Mage/bow_staff.png'],
        open: false,
      );
      await tester.tap(find.text('Expanded'));
      await pumpUntil(tester, find.text('Mage'));
      await tester.tap(find.text('Archer'));
      await pumpUntil(tester, find.textContaining('Images ('));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Images (2)'), findsOneWidget);
      await type(tester, 'bow');
      // Only Archer/bow.png: Mage's bow is outside the folder.
      expect(find.text('Images (1)'), findsOneWidget);
      await tester.tap(find.text('Show whole pack'));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('Images (2)'), findsOneWidget);
      expect(find.text('Matching “bow”'), findsOneWidget);
    });

    testWidgets('a dashboard search seeds the field; one chip', (tester) async {
      await openKnight(tester, files: files, open: false);
      await tester.tap(find.text('Files'));
      await tester.pump();
      await tester.enterText(find.byType(TextField).first, 'barrel');
      await tester.pump(DashboardQueryNotifier.searchDebounce);
      await pumpUntil(tester, find.text('Barrels 1'));
      await tester.tap(find.text('Barrels 1'));
      await pumpUntil(tester, find.text('Show all files'));
      await tester.pump(const Duration(seconds: 1));
      expect(tester.widget<TextField>(field()).controller!.text, 'barrel');
      expect(find.byType(InputChip), findsOneWidget);
      expect(find.text('Images (2)'), findsOneWidget);
      // Refining here replaces the dashboard search, still one chip.
      await type(tester, 'barrel roll');
      expect(find.text('Matching “barrel roll”'), findsOneWidget);
      expect(find.byType(InputChip), findsOneWidget);
      expect(find.text('Audio (1)'), findsOneWidget);
      await tester.tap(find.text('Show all files'));
      await tester.pump(const Duration(milliseconds: 500));
      expect(tester.widget<TextField>(field()).controller!.text, isEmpty);
      expect(find.text('Images (4)'), findsOneWidget);
    });

    testWidgets('Ctrl+F on the detail page focuses its search', (tester) async {
      await openKnight(tester, files: files);
      expect(searchFocused(tester), isFalse);
      await ctrlF(tester);
      expect(searchFocused(tester), isTrue);
      // A click outside hands focus back to the page: H still pins.
      await tester.tapAt(const Offset(700, 880));
      await tester.pump();
      expect(searchFocused(tester), isFalse);
      final pinned = store.load().detailHeaderPinned;
      await tester.sendKeyEvent(LogicalKeyboardKey.keyH);
      await tester.pump();
      expect(store.load().detailHeaderPinned, !pinned);
    });
  });

  testWidgets('author link: N packs opens the dashboard filtered by author', (
    tester,
  ) async {
    await openKnight(tester, open: false);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(HomeScreen)),
    );
    // A search and a type filter that the link must clear.
    await tester.enterText(find.byType(TextField).first, 'knight');
    await tester.pump(DashboardQueryNotifier.searchDebounce);
    container.read(dashboardQueryProvider.notifier).toggleType('character');
    await pumpUntil(tester, find.text('Knight Pack'));
    await tester.pump();
    await tester.tap(find.text('Knight Pack'));
    await pumpUntil(tester, find.byType(TabBar));
    await tester.pump(const Duration(seconds: 1));

    // Knight Pack and Slimes.
    final link = find.byKey(const ValueKey('author-packs'));
    expect(
      find.descendant(of: link, matching: find.text('2 packs')),
      findsOneWidget,
    );
    await tester.tap(link);
    await pumpUntil(tester, find.text('Slimes'));
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(PackDetailScreen), findsNothing);
    final q = container.read(dashboardQueryProvider);
    expect(q.authors, {'HeroMaker'});
    expect(q.text, isEmpty);
    expect(q.types, isEmpty);
    expect(
      tester.widget<TextField>(find.byType(TextField).first).controller!.text,
      isEmpty,
    );
    expect(find.text('Knight Pack'), findsOneWidget);
  });

  group('One sound at a time (M74)', () {
    late List<_FakePlayer> players;
    Finder strip(String label) => find.descendant(
      of: find.byType(PackTabStrip),
      matching: find.text(label),
    );
    Finder tile(String title) =>
        find.descendant(of: find.byType(PackTile), matching: find.text(title));

    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 6; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    NowPlaying nowPlaying(WidgetTester tester) =>
        ProviderScope.containerOf(tester.element(find.byType(TabsHost)))
            .read(nowPlayingProvider);

    /// Knight Pack and Slimes, each with a sound, open in background tabs.
    Future<void> open(WidgetTester tester) async {
      players = [];
      await openKnight(
        tester,
        open: false,
        files: const [],
        raw: {
          'sfx/sword.wav': const [1, 2, 3],
        },
        slimes: {
          'sfx/splat.wav': const [1, 2, 3],
        },
        overrides: [
          trackPlayerFactoryProvider.overrideWithValue(() {
            final p = _FakePlayer();
            players.add(p);
            return p;
          }),
          audioInfoProvider.overrideWithValue((_) async => null),
          audioDurationProvider.overrideWithValue((_) async => null),
          audioPeaksProvider.overrideWithValue(
            AudioPeaksCache(read: (_) async => Float32List(0)),
          ),
        ],
      );
      for (final title in ['Knight Pack', 'Slimes']) {
        await tester.tapAt(
          tester.getCenter(tile(title)),
          buttons: kSecondaryMouseButton,
        );
        await settle(tester);
        await tester.tap(find.text('Open in new tab'));
        await settle(tester);
      }
    }

    /// Shows the [pack] tab and its Audio tab.
    Future<void> show(WidgetTester tester, String pack) async {
      await tester.tap(strip(pack));
      await settle(tester);
      await tester.tap(find.textContaining('Audio (').hitTestable());
      await settle(tester);
    }

    Future<void> play(WidgetTester tester, String name) async {
      await tester.tap(find.text(name).hitTestable());
      await tester.pump();
    }

    test('NowPlaying: a new owner stops the last one', () {
      final now = NowPlaying();
      final a = Object();
      final b = Object();
      final stopped = <String>[];
      now.claim(a, () => stopped.add('a'));
      // Claiming again (the next track) keeps it.
      now.claim(a, () => stopped.add('a2'));
      expect(stopped, isEmpty);
      now.claim(b, () => stopped.add('b'));
      expect(stopped, ['a2']);
      expect(now.owns(b), isTrue);
      // A release by someone else does nothing.
      now.release(a);
      expect(now.owns(b), isTrue);
      now.release(b);
      expect(now.owns(b), isFalse);
    });

    testWidgets('play in A, show tab B: A stops and does not resume', (
      tester,
    ) async {
      await open(tester);
      await show(tester, 'Knight Pack');
      await play(tester, 'sword');
      final a = players.single;
      expect(a.played, hasLength(1));
      final stops = a.stops;

      await show(tester, 'Slimes');
      expect(a.stops, greaterThan(stops));
      expect(nowPlaying(tester).playing, isFalse);

      // Back in A: stopped, not playing again.
      await tester.tap(strip('Knight Pack'));
      await settle(tester);
      expect(a.played, hasLength(1));
      expect(find.byTooltip('Stop').hitTestable(), findsNothing);
    });

    testWidgets('play in A, then in B: A stops', (tester) async {
      await open(tester);
      await show(tester, 'Knight Pack');
      await play(tester, 'sword');
      await show(tester, 'Slimes');
      await play(tester, 'splat');
      expect(players, hasLength(2));
      expect(players.last.played, hasLength(1));
      // Only B's sound plays.
      await tester.tap(strip('Knight Pack'));
      await settle(tester);
      expect(find.byTooltip('Stop').hitTestable(), findsNothing);
      await tester.tap(strip('Slimes'));
      await settle(tester);
      // Leaving B stopped it too; both are stopped now.
      expect(find.byTooltip('Stop').hitTestable(), findsNothing);
    });

    testWidgets('a sound started elsewhere stops this one', (tester) async {
      await open(tester);
      await show(tester, 'Knight Pack');
      await play(tester, 'sword');
      final a = players.single;
      expect(find.byTooltip('Stop').hitTestable(), findsOneWidget);
      final stops = a.stops;
      // Any other owner (a future player anywhere in the app).
      nowPlaying(tester).claim(Object(), () {});
      await tester.pump();
      expect(a.stops, greaterThan(stops));
      expect(find.byTooltip('Stop').hitTestable(), findsNothing);
    });

    testWidgets('play in A, show the dashboard: A stops', (tester) async {
      await open(tester);
      await show(tester, 'Knight Pack');
      await play(tester, 'sword');
      final a = players.single;
      final stops = a.stops;
      await tester.tap(strip('Dashboard'));
      await settle(tester);
      expect(a.stops, greaterThan(stops));
      expect(nowPlaying(tester).playing, isFalse);
    });

    testWidgets('closing A while it plays (Ctrl+W) stops it', (tester) async {
      await open(tester);
      await show(tester, 'Knight Pack');
      await play(tester, 'sword');
      final a = players.single;
      final now = nowPlaying(tester);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyW);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await settle(tester);
      expect(strip('Knight Pack'), findsNothing);
      // The player went away with the tab (audioplayers stops on dispose).
      expect(a.disposed, isTrue);
      expect(now.playing, isFalse);
    });
  });

  group('Pack tabs (M31)', () {
    Finder tile(String title) =>
        find.descendant(of: find.byType(PackTile), matching: find.text(title));
    Finder strip(String label) => find.descendant(
      of: find.byType(PackTabStrip),
      matching: find.text(label),
    );

    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 5; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    Future<void> middleClick(WidgetTester tester, Finder f) async {
      final g = await tester.startGesture(
        tester.getCenter(f),
        kind: PointerDeviceKind.mouse,
        buttons: kMiddleMouseButton,
      );
      await g.up();
      await settle(tester);
    }

    Future<void> ctrl(
      WidgetTester tester,
      LogicalKeyboardKey key, {
      bool shift = false,
    }) async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(key);
      if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await settle(tester);
    }

    Tabs tabs(WidgetTester tester) =>
        ProviderScope.containerOf(tester.element(find.byType(TabsHost)))
            .read(tabsProvider);

    testWidgets('middle-click and the menu open background tabs', (
      tester,
    ) async {
      await openKnight(tester, open: false);
      expect(find.byType(PackTabStrip), findsNothing);
      await middleClick(tester, tile('Knight Pack'));
      // A tab, but the dashboard stays in front.
      expect(strip('Knight Pack'), findsOneWidget);
      expect(strip('Dashboard'), findsOneWidget);
      expect(tabs(tester).active, 0);
      expect(tile('Slimes'), findsOneWidget);
      expect(find.byType(PackDetailScreen), findsNothing);

      await tester.tapAt(
        tester.getCenter(tile('Slimes')),
        buttons: kSecondaryMouseButton,
      );
      await settle(tester);
      await tester.tap(find.text('Open in new tab'));
      await settle(tester);
      expect(strip('Slimes'), findsOneWidget);
      expect(tabs(tester).tabs.map((t) => t.packId), [
        'HeroMaker/Knight Pack',
        'HeroMaker/Slimes',
      ]);
      expect(tabs(tester).active, 0);

      // A pack that already has a tab: that tab is shown.
      await middleClick(tester, tile('Knight Pack'));
      expect(tabs(tester).tabs, hasLength(2));
      expect(tabs(tester).active, 1);
      expect(find.byType(PackDetailScreen), findsOneWidget);
      expect(find.textContaining('Images ('), findsOneWidget);

      // A plain click still opens the pack in the current (dashboard) tab.
      await tester.tap(strip('Dashboard'));
      await settle(tester);
      await tester.tap(tile('Slimes'));
      await pumpUntil(tester, find.byType(PackDetailScreen));
      await tester.pump(const Duration(seconds: 1));
      expect(tabs(tester).active, 0);
      expect(tabs(tester).tabs, hasLength(2));
      // Esc goes back within the dashboard tab.
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(PackDetailScreen), findsNothing);
      expect(tile('Slimes'), findsOneWidget);
    });

    testWidgets('each tab keeps its state; Ctrl+Tab and Ctrl+W', (
      tester,
    ) async {
      await openKnight(tester, open: false);
      // Dashboard search, kept while another tab shows.
      await tester.enterText(find.byType(TextField).first, 'knight');
      await tester.pump(DashboardQueryNotifier.searchDebounce);
      await pumpUntil(tester, tile('Knight Pack'));
      await middleClick(tester, tile('Knight Pack'));
      await tester.tap(strip('Knight Pack'));
      await settle(tester);
      expect(tabs(tester).active, 1);

      // A detail search in the pack tab.
      final field = find.widgetWithText(TextField, 'Search files');
      await tester.enterText(field, 'z root');
      await tester.pump(DashboardQueryNotifier.searchDebounce);
      await settle(tester);
      expect(find.text('Matching “z root”'), findsOneWidget);
      // Esc on a pack tab's own page has nothing to go back to: the tab
      // and its search stay.
      await tester.tapAt(const Offset(700, 880));
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);
      expect(tabs(tester).active, 1);
      expect(find.text('Matching “z root”'), findsOneWidget);

      // Ctrl+Tab to the dashboard: its search is still there.
      await ctrl(tester, LogicalKeyboardKey.tab);
      expect(tabs(tester).active, 0);
      expect(
        tester.widget<TextField>(find.byType(TextField).first).controller!.text,
        'knight',
      );
      expect(tile('Slimes'), findsNothing);
      // Ctrl+Shift+Tab wraps back to the pack, with its search.
      await ctrl(tester, LogicalKeyboardKey.tab, shift: true);
      expect(tabs(tester).active, 1);
      expect(find.text('Matching “z root”'), findsOneWidget);
      // Keys work in the shown tab without a click (focus followed).
      await ctrl(tester, LogicalKeyboardKey.keyF);
      expect(tester.widget<TextField>(field).focusNode!.hasFocus, isTrue);

      // Ctrl+W closes the pack tab; the dashboard shows and stays.
      await tester.tapAt(const Offset(700, 880));
      await ctrl(tester, LogicalKeyboardKey.keyW);
      expect(tabs(tester).tabs, isEmpty);
      expect(tabs(tester).active, 0);
      expect(find.byType(PackTabStrip), findsNothing);
      await ctrl(tester, LogicalKeyboardKey.keyW);
      expect(find.byType(Dashboard), findsOneWidget);
    });

    bool selected(WidgetTester tester, Finder stripTab) {
      // The stadium behind the shown strip's tab.
      final material = tester.widget<Material>(
        find
            .ancestor(
              of: stripTab.hitTestable().first,
              matching: find.byType(Material),
            )
            .first,
      );
      return material.color != Colors.transparent;
    }

    testWidgets('M36: no top bar with the strip; Dashboard tab goes back', (
      tester,
    ) async {
      // No pack tab: the detail page keeps its bar with the back arrow.
      await openKnight(tester);
      final detail = find.byType(PackDetailScreen);
      expect(
        find.descendant(of: detail, matching: find.byType(AppBar)),
        findsOneWidget,
      );
      expect(
        find.descendant(of: detail, matching: find.byType(BackButton)),
        findsOneWidget,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);
      await tester.pump(const Duration(seconds: 1));
      expect(detail, findsNothing);

      // With a tab open, a pack opened by a plain click has no bar: only
      // the strip, where the Dashboard tab isn't selected.
      await middleClick(tester, tile('Slimes'));
      expect(selected(tester, strip('Dashboard')), isTrue);
      await tester.tap(tile('Knight Pack'));
      await pumpUntil(tester, detail);
      await tester.pump(const Duration(seconds: 1));
      expect(
        find.descendant(of: detail, matching: find.byType(AppBar)),
        findsNothing,
      );
      expect(
        find.descendant(of: detail, matching: find.byType(PackTabStrip)),
        findsOneWidget,
      );
      expect(selected(tester, strip('Dashboard')), isFalse);
      expect(selected(tester, strip('Slimes')), isFalse);
      // The pin / folder icons are in the header, not a bar.
      final folder = find.byTooltip('Open folder').hitTestable();
      await pumpUntil(tester, folder);
      expect(folder, findsOneWidget);
      expect(tester.getTopRight(folder).dx, greaterThan(1400 - 80));
      expect(
        tester.getBottomLeft(folder).dy,
        lessThan(tester.getTopLeft(find.byType(TabBar).hitTestable()).dy),
      );

      // Its click goes back to the dashboard, which is selected again.
      await tester.tap(strip('Dashboard'));
      await settle(tester);
      await tester.pump(const Duration(seconds: 1));
      expect(detail, findsNothing);
      expect(tile('Knight Pack'), findsOneWidget);
      expect(selected(tester, strip('Dashboard')), isTrue);

      // A pack tab is selected on its own page; Esc and the strip still work.
      await tester.tap(strip('Slimes'));
      await settle(tester);
      expect(selected(tester, strip('Slimes')), isTrue);
      expect(selected(tester, strip('Dashboard')), isFalse);
      expect(
        find.descendant(of: detail, matching: find.byType(AppBar)),
        findsNothing,
      );
    });

    testWidgets('M36: the slim bar carries the icons too', (tester) async {
      await openKnight(tester);
      await tester.tap(find.byTooltip('Unpin header — show it on hover (H)'));
      await tester.pump();
      expect(find.text('Hover for details'), findsOneWidget);
      final pin = find.byTooltip('Pin header (H)');
      expect(pin, findsOneWidget);
      final bar = tester.getRect(
        find
            .ancestor(
              of: find.text('Hover for details'),
              matching: find.byType(Container),
            )
            .first,
      );
      expect(bar.contains(tester.getCenter(pin)), isTrue);
      expect(
        bar.contains(tester.getCenter(find.byTooltip('Open folder'))),
        isTrue,
      );
      // Clicking the pin there pins it again without opening on hover.
      await tester.tap(pin);
      await tester.pump();
      expect(store.load().detailHeaderPinned, isTrue);
    });

    testWidgets('M36: icons fit at the minimum window size', (tester) async {
      await openKnight(tester, size: const Size(1024, 600));
      tester.takeException();
      final info = tester.getRect(find.byKey(const ValueKey('header-info')));
      final icons = tester.getRect(
        find.byKey(const ValueKey('header-actions')),
      );
      expect(info.right, lessThanOrEqualTo(icons.left));
      expect(icons.right, lessThanOrEqualTo(1024));
      final preview = tester.getRect(
        find.byKey(const ValueKey('header-preview')),
      );
      expect(preview.right, lessThan(icons.left));
    });

    testWidgets('a snack bar with two tabs open, then a page on top', (
      tester,
    ) async {
      await openKnight(tester, open: false);
      await middleClick(tester, tile('Knight Pack'));
      await tester.tap(strip('Knight Pack'));
      await settle(tester);
      // Every tab's Scaffold shows the app's snack bar; hidden tabs must
      // not add a second snack bar hero to the page transition.
      final context = tester.element(find.byType(PackDetailScreen));
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('listed as an image')));
      await settle(tester);
      openHelp(context);
      await settle(tester);
      await tester.pump(const Duration(seconds: 1));
      expect(tester.takeException(), isNull);
      expect(find.byType(HelpScreen), findsOneWidget);
    });

    testWidgets('× and middle-click close tabs; left neighbour shows', (
      tester,
    ) async {
      await openKnight(tester, open: false);
      await middleClick(tester, tile('Knight Pack'));
      await middleClick(tester, tile('Slimes'));
      await tester.tap(strip('Slimes'));
      await settle(tester);
      expect(tabs(tester).active, 2);
      // The tooltip carries the full title.
      expect(find.byTooltip('Slimes'), findsWidgets);
      final close = find.descendant(
        of: find.byKey(ValueKey('strip-${tabs(tester).tabs[1].id}')),
        matching: find.byTooltip('Close tab (Ctrl+W)'),
      );
      await tester.tap(close);
      await settle(tester);
      expect(tabs(tester).tabs.map((t) => t.packId), ['HeroMaker/Knight Pack']);
      expect(tabs(tester).active, 1);
      await middleClick(tester, strip('Knight Pack'));
      expect(tabs(tester).tabs, isEmpty);
      expect(tabs(tester).active, 0);
      expect(tile('Knight Pack'), findsOneWidget);
    });

    test('closing tabs keeps the shown one when it is not closed', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final n = c.read(tabsProvider.notifier)
        ..open('a')
        ..open('b')
        ..open('c')
        ..select(3);
      n.close(0); // a, left of the shown c
      expect(c.read(tabsProvider).active, 2);
      expect(c.read(tabsProvider).tabs.map((t) => t.packId), ['b', 'c']);
      n.cycle(1); // wraps to the dashboard
      expect(c.read(tabsProvider).active, 0);
      n.cycle(-1);
      expect(c.read(tabsProvider).active, 2);
      n.closeCurrent();
      expect(c.read(tabsProvider).active, 1);
      n
        ..select(0)
        ..closeCurrent();
      expect(c.read(tabsProvider).tabs, hasLength(1));
    });
  });

  testWidgets('Help opens from the app bar, F1 and Settings (M32)', (
    tester,
  ) async {
    await openKnight(tester, open: false);
    Future<void> settle() async {
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    await tester.tap(find.byTooltip('How Loot Silo works (F1)'));
    await settle();
    expect(find.byType(HelpScreen), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle();
    expect(find.byType(HelpScreen), findsNothing);

    await tester.sendKeyEvent(LogicalKeyboardKey.f1);
    await settle();
    expect(find.byType(HelpScreen), findsOneWidget);
    // Clicking or dragging over its text (selectable) keeps Esc working.
    await tester.drag(find.byType(SelectableText).first, const Offset(0, -200));
    await tester.tap(find.byType(SelectableText).at(2));
    await settle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle();
    expect(find.byType(HelpScreen), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.f1);
    await settle();
    // F1 again doesn't stack a second page.
    await tester.sendKeyEvent(LogicalKeyboardKey.f1);
    await settle();
    expect(find.byType(HelpScreen), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle();

    // F1 from a pack page too.
    await tester.tap(find.text('Knight Pack'));
    await pumpUntil(tester, find.byType(TabBar));
    await settle();
    await tester.sendKeyEvent(LogicalKeyboardKey.f1);
    await settle();
    expect(find.byType(HelpScreen), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle();

    await tester.tap(find.byTooltip('Settings (Ctrl+,)'));
    await settle();
    final entry = find.text('How Loot Silo works');
    // Help sits near the end, right above About (M39).
    await tester.scrollUntilVisible(entry, 200);
    await tester.ensureVisible(entry);
    await settle();
    await tester.tap(entry);
    await settle();
    expect(find.byType(HelpScreen), findsOneWidget);
  });

  group('Header preview (M29)', () {
    img.Image solid(int w, int h, int shade) {
      final i = img.Image(width: w, height: h, numChannels: 4);
      img.fill(i, color: img.ColorRgba8(shade, 120, 60, 255));
      return i;
    }

    Map<String, img.Image> mockups(int n) => {
      for (var i = 1; i <= n; i++)
        'mockups/mockup$i.png': solid(40, 30, i * 20),
    };

    testWidgets('the preview box is as tall as the info column', (
      tester,
    ) async {
      await openKnight(tester, files: const []);
      final box = tester.getSize(find.byKey(const ValueKey('header-preview')));
      final info = tester.getSize(find.byKey(const ValueKey('header-info')));
      expect(box.width, previewBoxWidthForTest);
      expect(box.height, info.height);
      // At least the minimum, unless the window leaves less room.
      expect(box.height, greaterThanOrEqualTo(300));
      expect(tester.takeException(), isNull);
    });

    test('the box minimum shrinks in short windows', () {
      expect(previewBoxMinHeightFor(const Size(1440, 900)), 320);
      expect(previewBoxMinHeightFor(const Size(1280, 720)), 288);
      expect(previewBoxMinHeightFor(const Size(800, 400)), 240);
    });

    testWidgets('the viewer from the header steps through the mockups', (
      tester,
    ) async {
      await openKnight(tester, files: const [], images: mockups(10));
      await tester.tap(find.byKey(const ValueKey('header-preview')));
      await tester.pumpAndSettle();
      // The mockups are the pack's preview now: mockup1 first, then the
      // rest in natural order (mockup10 last, not after mockup1).
      expect(find.text('1 / 10'), findsOneWidget);
      expect(find.textContaining('mockups/mockup1.png'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(find.textContaining('mockups/mockup2.png'), findsOneWidget);
      for (var i = 0; i < 8; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pump();
      }
      expect(find.text('10 / 10'), findsOneWidget);
      expect(find.textContaining('mockups/mockup10.png'), findsOneWidget);
    });

    testWidgets('the previews grid opens one in the viewer', (tester) async {
      await openKnight(tester, files: const [], images: mockups(3));
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(
        location: tester.getCenter(
          find.byKey(const ValueKey('header-preview')),
        ),
      );
      addTearDown(mouse.removePointer);
      await tester.pump();
      await tester.tap(find.byTooltip('All previews (3)'));
      await tester.pumpAndSettle();
      expect(find.text('Previews (3)'), findsOneWidget);
      final grid = find.byType(PreviewGridDialog);
      expect(
        find.descendant(of: grid, matching: find.text('mockup3.png')),
        findsOneWidget,
      );
      await tester.tap(
        find.descendant(of: grid, matching: find.text('mockup2.png')),
      );
      await tester.pumpAndSettle();
      expect(find.text('2 / 3'), findsOneWidget);
      expect(find.textContaining('mockups/mockup2.png'), findsOneWidget);
    });

    Future<void> openGrid(WidgetTester tester, int n) async {
      await openKnight(tester, files: const [], images: mockups(n));
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(
        location: tester.getCenter(
          find.byKey(const ValueKey('header-preview')),
        ),
      );
      addTearDown(mouse.removePointer);
      await tester.pump();
      await tester.tap(find.byTooltip('All previews ($n)'));
      await tester.pumpAndSettle();
    }

    List<Rect> cards(WidgetTester tester) => [
      for (final e
          in find
              .descendant(
                of: find.byType(PreviewGridDialog),
                matching: find.byWidgetPredicate(
                  (w) =>
                      w is Card &&
                      w.key is ValueKey<String> &&
                      (w.key! as ValueKey<String>).value.startsWith('preview:'),
                ),
              )
              .evaluate())
        tester.getRect(find.byWidget(e.widget)),
    ];

    testWidgets(
      'cards fill the width; 8 previews at 5 wanted are 4 + 4 (M42)',
      (tester) async {
        await openGrid(tester, 8);
        expect(store.load().previewsColumns, 4);
        await tester.tap(find.byTooltip('More columns (Ctrl + wheel down)'));
        await tester.pumpAndSettle();
        expect(store.load().previewsColumns, 5);
        expect(
          tester
              .widget<Text>(find.byKey(const ValueKey('previews-columns')))
              .data,
          '5',
        );
        final rects = cards(tester);
        expect(rects, hasLength(8));
        final rows = {for (final r in rects) r.top}.toList()..sort();
        expect(rows, hasLength(2));
        expect(rects.where((r) => r.top == rows.first), hasLength(4));
        // The row spans the grid: 16 px padding a side, 8 px gaps.
        final grid = tester.getRect(
          find.descendant(
            of: find.byType(PreviewGridDialog),
            matching: find.byType(GridView),
          ),
        );
        final first = rects.where((r) => r.top == rows.first).toList()
          ..sort((a, b) => a.left.compareTo(b.left));
        expect(first.first.left, closeTo(grid.left + 16, 0.5));
        expect(first.last.right, closeTo(grid.right - 16, 0.5));
        expect(first[1].left - first[0].right, closeTo(8, 0.5));
      },
    );

    testWidgets('Ctrl + wheel and −/+ set the columns, within 1–8 (M42)', (
      tester,
    ) async {
      await openGrid(tester, 3);
      final grid = find.descendant(
        of: find.byType(PreviewGridDialog),
        matching: find.byType(GridView),
      );
      Future<void> wheel(double dy) async {
        final pointer = TestPointer(7, PointerDeviceKind.mouse);
        await tester.sendEventToBinding(pointer.hover(tester.getCenter(grid)));
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendEventToBinding(pointer.scroll(Offset(0, dy)));
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pumpAndSettle();
      }

      await wheel(-100); // up: bigger cards, fewer columns
      expect(store.load().previewsColumns, 3);
      await wheel(100);
      await wheel(100);
      expect(store.load().previewsColumns, 5);
      final less = find.byTooltip('Fewer columns (Ctrl + wheel up)');
      final more = find.byTooltip('More columns (Ctrl + wheel down)');
      for (var i = 0; i < 6; i++) {
        await tester.tap(less, warnIfMissed: false);
        await tester.pumpAndSettle();
      }
      expect(store.load().previewsColumns, 1);
      IconButton button(Finder f) => tester.widget<IconButton>(
        find.ancestor(of: f, matching: find.byType(IconButton)).first,
      );
      expect(button(less).onPressed, isNull);
      // One column: one card per row, as wide as the grid allows.
      expect({for (final r in cards(tester)) r.left}, hasLength(1));
      for (var i = 0; i < 9; i++) {
        await tester.tap(more, warnIfMissed: false);
        await tester.pumpAndSettle();
      }
      expect(store.load().previewsColumns, 8);
      expect(button(more).onPressed, isNull);
      await wheel(100);
      expect(store.load().previewsColumns, 8);
      // 3 previews never need more than 3 columns.
      expect({for (final r in cards(tester)) r.top}, hasLength(1));
    });

    testWidgets('one candidate: no grid button', (tester) async {
      await openKnight(tester, files: const []);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(
        location: tester.getCenter(
          find.byKey(const ValueKey('header-preview')),
        ),
      );
      addTearDown(mouse.removePointer);
      await tester.pump();
      expect(
        find.byWidgetPredicate(
          (w) => w is Tooltip && (w.message ?? '').startsWith('All previews'),
        ),
        findsNothing,
      );
    });
  });
  group('Favorites (M38)', () {
    Map<String, Object?> sidecar() => jsonDecode(
      File(
        p.join(
          tmp.path,
          'library',
          'HeroMaker',
          'Knight Pack',
          'asset_pack.json',
        ),
      ).readAsStringSync(),
    ) as Map<String, Object?>;

    Future<TestGesture> hoverOver(WidgetTester tester, Finder f) async {
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: tester.getCenter(f));
      addTearDown(mouse.removePointer);
      await tester.pump();
      return mouse;
    }

    String chipText(WidgetTester tester, Key key) => [
      for (final e
          in find
              .descendant(of: find.byKey(key), matching: find.byType(Text))
              .evaluate())
        (e.widget as Text).data,
    ].join(' ');

    testWidgets('pack tile star on hover; dashboard chip filters packs', (
      tester,
    ) async {
      await openKnight(tester, open: false);
      await pumpUntil(tester, find.text('Slimes'));
      final tile = find.widgetWithText(PackTile, 'Knight Pack');
      final star = find.byKey(const ValueKey('pack-star'));
      expect(star, findsNothing);
      final mouse = await hoverOver(tester, tile);
      expect(star, findsOneWidget);
      await tester.tap(star);
      await tester.pump();
      expect(sidecar()['favorite'], isTrue);
      // Other keys kept.
      expect(sidecar()['future_field'], 42);
      expect(sidecar()['used_in'], ['My Game']);
      // Starred: shown without hover too.
      await mouse.moveTo(const Offset(2, 890));
      await tester.pump();
      expect(star, findsOneWidget);
      expect(
        tester
            .widget<Icon>(
              find.descendant(of: star, matching: find.byType(Icon)),
            )
            .icon,
        Icons.star,
      );

      const chip = ValueKey('favorites-chip');
      expect(chipText(tester, chip), '1');
      await tester.tap(find.byKey(chip));
      await tester.pump();
      expect(find.widgetWithText(PackTile, 'Slimes'), findsNothing);
      expect(tile, findsOneWidget);
      expect(find.text('1 pack'), findsOneWidget);
      // Unstar: the filter now lists nothing.
      await tester.tap(star);
      await tester.pump();
      expect(sidecar().containsKey('favorite'), isFalse);
      expect(find.text('No packs match'), findsOneWidget);
      expect(chipText(tester, chip), '0');
    });

    testWidgets('header, image, audio and other-file stars; detail chip', (
      tester,
    ) async {
      await openKnight(
        tester,
        files: const ['heroes/a.png', 'z_root.png', 'sfx/hit.wav'],
        raw: {'notes.txt': utf8.encode('hello')},
        overrides: [
          audioDurationProvider.overrideWithValue(
            (path) async => const Duration(seconds: 1),
          ),
        ],
      );
      final header = find.byKey(const ValueKey('header-star'));
      expect(header, findsOneWidget);
      await tester.tap(header);
      await tester.pump();
      expect(sidecar()['favorite'], isTrue);

      // Image card: on hover.
      await tester.tap(find.textContaining('Images ('));
      await tester.pumpAndSettle();
      final star = find.byKey(const ValueKey('star:z_root.png'));
      expect(star, findsNothing);
      final mouse = await hoverOver(
        tester,
        find
            .ancestor(of: find.text('Z root'), matching: find.byType(Card))
            .first,
      );
      expect(star, findsOneWidget);
      await tester.tap(star);
      await tester.pump();
      expect(sidecar()['favorite_files'], ['z_root.png']);
      await mouse.moveTo(const Offset(2, 890));
      await tester.pump();
      expect(star, findsOneWidget);
      expect(find.byKey(const ValueKey('star:heroes/a.png')), findsNothing);

      // Audio row and Other files row: always there.
      await tester.tap(find.textContaining('Audio ('));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('star:sfx/hit.wav')));
      await tester.pump();
      await tester.tap(find.textContaining('Other files ('));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('star:notes.txt')));
      await tester.pump();
      expect(sidecar()['favorite_files'], [
        'notes.txt',
        'sfx/hit.wav',
        'z_root.png',
      ]);
      expect(sidecar()['future_field'], 42);

      // The detail chip: only starred files; tab counts follow.
      const chip = ValueKey('detail-favorites-chip');
      expect(
        find.descendant(of: find.byKey(chip), matching: find.text('3')),
        findsOneWidget,
      );
      expect(find.text('Images (3)'), findsOneWidget);
      await tester.tap(find.byKey(chip));
      await tester.pumpAndSettle();
      expect(find.text('Images (1)'), findsOneWidget);
      expect(find.text('Audio (1)'), findsOneWidget);
      expect(find.text('Other files (1)'), findsOneWidget);
      // Unstarring the last other file empties the open tab, which stays.
      await tester.tap(find.byKey(const ValueKey('star:notes.txt')));
      await tester.pumpAndSettle();
      expect(find.text('Other files (0)'), findsOneWidget);
      expect(find.text('No starred files'), findsOneWidget);
      await tester.tap(find.byKey(chip));
      await tester.pumpAndSettle();
      expect(find.text('Images (3)'), findsOneWidget);
      expect(find.text('Other files (1)'), findsOneWidget);
    });

    testWidgets('audio cards and animation cards have stars', (tester) async {
      final strip = img.Image(width: 64, height: 16, numChannels: 4);
      img.fill(strip, color: img.ColorRgba8(40, 120, 200, 255));
      await openKnight(
        tester,
        files: const ['sfx/hit.wav'],
        images: {'fx/smoke_strip.png': strip},
        overrides: [
          audioDurationProvider.overrideWithValue(
            (path) async => const Duration(seconds: 1),
          ),
        ],
      );
      await tester.tap(find.textContaining('Animations ('));
      await tester.pumpAndSettle();
      final anim = find.byKey(const ValueKey('star:fx/smoke_strip.png'));
      expect(anim, findsNothing);
      await hoverCard(tester);
      expect(anim, findsOneWidget);
      await tester.tap(anim);
      await tester.pump();
      expect(sidecar()['favorite_files'], ['fx/smoke_strip.png']);

      await tester.tap(find.textContaining('Audio ('));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cards'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('star:sfx/hit.wav')));
      await tester.pump();
      expect(sidecar()['favorite_files'], [
        'fx/smoke_strip.png',
        'sfx/hit.wav',
      ]);
    });

    testWidgets('Files view: the chip lists starred files without search', (
      tester,
    ) async {
      // Starred before the scan: read from the sidecar.
      await openKnight(
        tester,
        files: const ['other.png'],
        open: false,
        sidecar: {
          'favorite_files': ['knight.png'],
        },
      );
      await tester.tap(find.text('Files'));
      await tester.pump();
      expect(find.text('Type to search file names'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('favorites-chip')));
      await tester.pump();
      expect(find.text('1 file'), findsOneWidget);
      expect(find.textContaining('night'), findsWidgets);
      expect(find.textContaining('ther'), findsNothing);
    });
  });

  group('Quick UI fixes (M45)', () {
    final tone = File('test/fixtures/audio/tone.wav').readAsBytesSync();

    testWidgets('Favorites chips show only the star and the count', (
      tester,
    ) async {
      await openKnight(tester, files: const ['heroes/a.png'], open: false);
      String label(Finder chip) => [
        for (final e
            in find
                .descendant(of: chip, matching: find.byType(Text))
                .evaluate())
          (e.widget as Text).data,
      ].join(' ');
      final dashboard = find.byKey(const ValueKey('favorites-chip'));
      expect(label(dashboard), '0');
      expect(
        find.descendant(of: dashboard, matching: find.byTooltip('Favorites')),
        findsOneWidget,
      );
      // Selected at 0 still shows.
      await tester.tap(dashboard);
      await tester.pump();
      expect(label(dashboard), '0');
      await tester.tap(dashboard);
      await tester.pump();

      await tester.tap(find.text('Knight Pack'));
      await pumpUntil(tester, find.byType(TabBar));
      final detail = find.byKey(const ValueKey('detail-favorites-chip'));
      expect(label(detail), '0');
      expect(
        find.descendant(
          of: detail,
          matching: find.byTooltip(
            'Favorites: show only the starred files of this pack',
          ),
        ),
        findsOneWidget,
      );
      expect(find.textContaining('Favorites ('), findsNothing);
    });

    testWidgets('the detail chip and search box paint one height', (
      tester,
    ) async {
      await openKnight(tester);
      final search = find.widgetWithText(TextField, 'Search files');
      final chip = find.byKey(const ValueKey('detail-favorites-chip'));
      // The painted boxes: the chip's Material (RawChip centres it inside
      // the box it's given) and the field's outlined decorator.
      final chipBox = tester.getRect(
        find.descendant(of: chip, matching: find.byType(Material)).first,
      );
      final fieldBox = tester.getRect(
        find.descendant(of: search, matching: find.byType(InputDecorator)),
      );
      expect(chipBox.height, detailControlHeight);
      expect(fieldBox.height, detailControlHeight);
      expect(chipBox.top, fieldBox.top);
      expect(chipBox.bottom, fieldBox.bottom);
      // A long search stays on one line (M47 screenshot).
      await tester.enterText(search, 'fisherman-beard-headband-fishing');
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.widget<TextField>(search).maxLines, 1);
      expect(
        tester
            .getRect(
              find.descendant(
                of: search,
                matching: find.byType(InputDecorator),
              ),
            )
            .height,
        detailControlHeight,
      );
    });

    testWidgets('Audio and Images toolbars have one padding', (tester) async {
      await openKnight(
        tester,
        files: const ['heroes/a.png'],
        raw: {'theme.wav': tone},
      );
      ({double top, double gap, double height}) measure() {
        final view = tester.getRect(find.byType(TabBarView));
        // The shown tab's toolbar, and the list in the same column.
        final toolbar = find.byWidgetPredicate((w) {
          if (w is! TabToolbar) return false;
          final r = tester.getRect(find.byWidget(w));
          return r.left >= view.left && r.right <= view.right;
        });
        final bar = tester.getRect(toolbar);
        final column = find
            .ancestor(of: toolbar, matching: find.byType(Column))
            .first;
        final list = tester.getRect(
          find.descendant(of: column, matching: find.byType(Scrollable)).first,
        );
        // Audio rows: the content starts with the column headers (M73),
        // inside the same top gap the lists have as padding.
        final header = find.descendant(
          of: column,
          matching: find.byKey(const ValueKey('audio-list-header')),
        );
        final top = header.evaluate().isEmpty
            ? list.top
            : tester.getRect(header).top - tabContentGap;
        return (
          top: bar.top - view.top,
          gap: top - bar.bottom,
          height: bar.height,
        );
      }

      await tester.tap(find.textContaining('Images ('));
      await tester.pumpAndSettle();
      final images = measure();
      final grid = tester.widget<GroupedGrid>(find.byType(GroupedGrid));
      await tester.tap(find.textContaining('Audio ('));
      await tester.pumpAndSettle();
      final audio = measure();
      expect(audio, images);
      expect(images.height, tabToolbarHeight + tabToolbarPadding.vertical);
      // The content's own top padding: the same small gap, above the
      // list's column headers (M73), which the rows follow directly.
      final header = find.byKey(const ValueKey('audio-list-header'));
      final padding = tester.widget<Padding>(
        find.ancestor(of: header, matching: find.byType(Padding)).first,
      );
      expect(padding.padding.resolve(TextDirection.ltr).top, tabContentGap);
      final rows = tester.widget<ListView>(find.byType(ListView).last);
      expect(rows.padding!.resolve(TextDirection.ltr).top, 0);
      expect(
        tester.getRect(find.byType(ListView).last).top,
        tester.getRect(header).bottom,
      );
      expect(grid.padding.top, tabContentGap);
      await tester.tap(find.text('Cards'));
      await tester.pumpAndSettle();
      final cards = tester.widget<GridView>(find.byType(GridView).last);
      expect(cards.padding!.resolve(TextDirection.ltr).top, tabContentGap);
      expect(measure(), audio);
    });
  });

  group('Expand / collapse all folders (M46)', () {
    img.Image solid(int w, int h, int shade) {
      final image = img.Image(width: w, height: h, numChannels: 4);
      img.fill(image, color: img.ColorRgba8(shade, 120, 200, 255));
      return image;
    }

    final fold = find.byKey(const ValueKey('fold-all'));
    IconData icon(WidgetTester tester) => tester
        .widget<Icon>(find.descendant(of: fold, matching: find.byType(Icon)))
        .icon!;

    /// Opens [tab] ("Images" or "Animations") in By folder view.
    Future<void> open(
      WidgetTester tester,
      String tab,
      Map<String, img.Image> images,
    ) async {
      await openKnight(
        tester,
        files: const [],
        images: images,
        size: const Size(1600, 1600),
      );
      await tester.tap(find.textContaining('$tab ('));
      await tester.pump(const Duration(milliseconds: 500));
      expect(fold, findsNothing, reason: 'hidden in Flat view');
      await tester.tap(find.text('By folder').first);
      await tester.pump(const Duration(milliseconds: 300));
    }

    for (final (tab, files, key) in [
      (
        'Images',
        {
          'a/k1.png': solid(8, 8, 10),
          'a/k2.png': solid(8, 8, 20),
          'b/z1.png': solid(8, 8, 30),
        },
        'image:a/k1.png',
      ),
      (
        'Animations',
        {
          'a/run_strip.png': solid(64, 16, 10),
          'b/jump_strip.png': solid(64, 16, 30),
        },
        'a/run_strip.png',
      ),
    ]) {
      testWidgets('$tab: collapse all, expand all, icon and tooltip', (
        tester,
      ) async {
        await open(tester, tab, files);
        final card = find.byKey(ValueKey(key));
        expect(fold, findsOneWidget);
        expect(icon(tester), Icons.unfold_less);
        expect(find.byTooltip('Collapse all folders'), findsOneWidget);
        expect(card, findsOneWidget);
        final cards = find.byType(ItemCard).evaluate().length;

        await tester.tap(fold);
        await tester.pump();
        expect(find.byType(ItemCard), findsNothing);
        expect(icon(tester), Icons.unfold_more);
        // M54: the button sits left of the view switch, whose first
        // segment is By folder.
        final toggle = find.byType(ItemsViewToggle);
        double left(Finder f) => tester.getTopLeft(f).dx;
        expect(left(fold), lessThan(left(toggle)));
        expect(
          left(find.descendant(of: toggle, matching: find.text('By folder'))),
          lessThan(
            left(find.descendant(of: toggle, matching: find.text('Flat'))),
          ),
        );
        expect(find.byTooltip('Expand all folders'), findsOneWidget);
        // The folder headers stay.
        expect(find.text('A'), findsOneWidget);
        expect(find.text('B'), findsOneWidget);

        await tester.tap(fold);
        await tester.pump();
        expect(card, findsOneWidget);
        expect(find.byType(ItemCard), findsNWidgets(cards));
        expect(icon(tester), Icons.unfold_less);

        // One folder open is enough for "Collapse all".
        await tester.tap(fold);
        await tester.pump();
        await tester.tap(find.text('B'));
        await tester.pump();
        expect(icon(tester), Icons.unfold_less);

        // Back in Flat view the button goes away.
        await tester.tap(find.text('Flat').first);
        await tester.pump(const Duration(milliseconds: 300));
        expect(fold, findsNothing);
      });
    }

    for (final (tab, foldTab, files, a, b) in [
      (
        'Images',
        FoldTab.images,
        {'a/k1.png': solid(8, 8, 10), 'b/z1.png': solid(8, 8, 30)},
        'image:a/k1.png',
        'image:b/z1.png',
      ),
      (
        'Animations',
        FoldTab.animations,
        {
          'a/run_strip.png': solid(64, 16, 10),
          'b/jump_strip.png': solid(64, 16, 30),
        },
        'a/run_strip.png',
        'b/jump_strip.png',
      ),
    ]) {
      testWidgets('$tab: collapsed folders are remembered per pack', (
        tester,
      ) async {
        final pack = p.join(tmp.path, 'library', 'HeroMaker', 'Knight Pack');
        final file = File(p.join(tmp.path, 'ui_state.json'));
        // Folded last time: B.
        FolderFolds(file).set(pack, foldTab, {'b'});
        final folds = FolderFolds(file);
        await openKnight(
          tester,
          files: const [],
          images: files,
          size: const Size(1600, 1600),
          overrides: [folderFoldsProvider.overrideWithValue(folds)],
        );
        await tester.tap(find.textContaining('$tab ('));
        await tester.pump(const Duration(milliseconds: 500));
        await tester.tap(find.text('By folder').first);
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.byKey(ValueKey(a)), findsOneWidget);
        expect(find.byKey(ValueKey(b)), findsNothing);

        // A click saves at once.
        await tester.tap(find.text('A'));
        await tester.pump();
        expect(FolderFolds(file).of(pack, foldTab), {'a', 'b'});
        await tester.tap(find.text('B'));
        await tester.pump();
        expect(FolderFolds(file).of(pack, foldTab), {'a'});
        // Collapse all remembers every folder (Images has a root one too).
        await tester.tap(fold);
        await tester.pump();
        expect(FolderFolds(file).of(pack, foldTab), containsAll(['a', 'b']));
        // Expand all leaves nothing to remember.
        await tester.tap(fold);
        await tester.pump();
        expect(FolderFolds(file).of(pack, foldTab), isEmpty);
      });
    }

    testWidgets('a selection survives Collapse all; focus mode ends', (
      tester,
    ) async {
      await open(tester, 'Images', {
        'a/k1.png': solid(8, 8, 10),
        'a/k2.png': solid(8, 8, 20),
        'b/z1.png': solid(8, 8, 30),
      });
      final k2 = find.byKey(const ValueKey('image:a/k2.png'));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.tap(k2);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(find.text('1 selected'), findsOneWidget);
      // Focus a card, then fold everything away.
      await tester.tap(find.byKey(const ValueKey('image:b/z1.png')));
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        tester
            .widget<ItemCard>(find.byKey(const ValueKey('image:b/z1.png')))
            .focused,
        isTrue,
      );
      await tester.tap(fold);
      await tester.pump();
      expect(find.text('1 selected'), findsOneWidget);
      await tester.tap(fold);
      await tester.pump();
      expect(tester.widget<ItemCard>(k2).selected, isTrue);
      expect([
        for (final e in find.byType(ItemCard).evaluate())
          if ((e.widget as ItemCard).focused) e,
      ], isEmpty);
    });

    testWidgets('acts on the folders the search shows', (tester) async {
      await open(tester, 'Images', {
        'a/k1.png': solid(8, 8, 10),
        'b/z1.png': solid(8, 8, 30),
      });
      // Fold B, then search for A's file only: A is the one folder shown.
      await tester.tap(find.text('B'));
      await tester.pump();
      await tester.enterText(
        find.widgetWithText(TextField, 'Search files'),
        'k1',
      );
      await tester.pump(const Duration(milliseconds: 500));
      expect(icon(tester), Icons.unfold_less);
      await tester.tap(fold);
      await tester.pump();
      expect(find.byType(ItemCard), findsNothing);
      // Expanding again opens A only: B stays folded after the search.
      await tester.tap(fold);
      await tester.pump();
      await tester.enterText(
        find.widgetWithText(TextField, 'Search files'),
        '',
      );
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byKey(const ValueKey('image:a/k1.png')), findsOneWidget);
      expect(find.byKey(const ValueKey('image:b/z1.png')), findsNothing);
    });
  });

  group('Quick UI fixes (M50)', () {
    // Real Roboto, not the test font's wide boxes, so the 1024 px top row
    // measures like the app's. Last group in the file: earlier tests keep
    // the test font.
    setUpAll(loadAppFonts);
    Rect actionsRow(WidgetTester tester) => tester.getRect(
      find
          .ancestor(
            of: find.byTooltip('itch.io'),
            matching: find.byType(MeasureSize),
          )
          .first,
    );
    final slider = find.byKey(const ValueKey('dashboard-size-slider'));

    testWidgets('the dashboard slider is as wide as the app bar icons', (
      tester,
    ) async {
      await openKnight(tester, open: false);
      await tester.pump();
      final icons = actionsRow(tester);
      final row = tester.getRect(slider);
      expect(row.width, icons.width);
      // Six icon buttons; lined up under them.
      expect(icons.width, greaterThan(200));
      expect(row.right, icons.right);
      // Labels at this width.
      expect(find.text('Expanded'), findsOneWidget);
    });

    testWidgets('the top row fits at 1024 px: view toggle icons only', (
      tester,
    ) async {
      await openKnight(tester, open: false, size: const Size(1024, 600));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text('Expanded'), findsNothing);
      expect(tester.getSize(slider).width, actionsRow(tester).width);
      final search = find.widgetWithText(
        TextField,
        'Search packs, authors, tags, file names',
      );
      expect(tester.getSize(search).width, greaterThan(200));
      // The facet menus are icons too, with their names as tooltips.
      expect(find.text('Author'), findsNothing);
      expect(find.byTooltip('Author'), findsOneWidget);
      // The segments still switch, by icon.
      await tester.tap(find.byIcon(Icons.view_comfy_alt_outlined));
      await tester.pump();
      expect(store.load().dashboardView, DashboardView.expanded);
    });

    testWidgets('M81: search placeholders without shortcuts, no tooltip', (
      tester,
    ) async {
      await openKnight(tester);
      for (final hint in [
        'Search packs, authors, tags, file names',
        'Search files',
      ]) {
        // By the decoration: a field with text doesn't show its hint.
        // The dashboard stays built, offstage, behind the pack tab.
        final field = find.byWidgetPredicate(
          (w) => w is TextField && w.decoration?.hintText == hint,
          skipOffstage: false,
        );
        expect(field, findsOneWidget, reason: hint);
        final text = tester.widget<TextField>(field).decoration!.hintText!;
        for (final bad in ['/', 'Ctrl', '(', ')']) {
          expect(text, isNot(contains(bad)));
        }
        expect(
          find.ancestor(
            of: field,
            matching: find.byType(Tooltip, skipOffstage: false),
          ),
          findsNothing,
          reason: hint,
        );
      }
      // Ctrl+F still focuses the file search.
      final files = tester
          .widget<TextField>(
            find.byWidgetPredicate(
              (w) => w is TextField && w.decoration?.hintText == 'Search files',
            ),
          )
          .focusNode!;
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(files.hasFocus, isTrue);
    });

    testWidgets('M79: slider end icons step one stop, disabled at the ends', (
      tester,
    ) async {
      await openKnight(tester, open: false);
      await tester.pump();
      final smaller = find.descendant(
        of: slider,
        matching: find.byTooltip('Smaller'),
      );
      final larger = find.descendant(
        of: slider,
        matching: find.byTooltip('Larger'),
      );
      double card() => tester.getSize(find.byType(PackTile).first).width;
      final start = card();
      await tester.tap(larger);
      await tester.pump();
      // The saved value is the card's real width, one stop up.
      expect(card(), greaterThan(start));
      expect(store.load().dashboardTileSize, closeTo(card(), 1e-6));
      await tester.tap(smaller);
      await tester.pump();
      expect(card(), closeTo(start, 1e-6));
      await tester.tap(smaller);
      await tester.pump();
      expect(card(), lessThan(start));
      IconButton button(Finder f) => tester.widget<IconButton>(
        find.ancestor(of: f, matching: find.byType(IconButton)).first,
      );
      var last = card();
      for (var i = 0; i < 30; i++) {
        if (button(smaller).onPressed == null) break;
        await tester.tap(smaller);
        await tester.pump();
        // Every stop changes the size.
        expect(card(), lessThan(last));
        last = card();
      }
      expect(card(), greaterThanOrEqualTo(dashboardTileRange.min));
      expect(button(smaller).onPressed, isNull);
      expect(button(larger).onPressed, isNotNull);
    });

    for (final images in [false, true]) {
      testWidgets('M79: dragging through all stops changes the card '
          '(${images ? 'Images tab' : 'dashboard'})', (tester) async {
        await openKnight(tester, open: images);
        if (images) {
          await tester.tap(find.textContaining('Images ('));
          await tester.pumpAndSettle();
        }
        await tester.pump();
        final bar = images
            ? find.byType(ThumbSizeSlider)
            : find.byKey(const ValueKey('dashboard-size-slider'));
        final s = find.descendant(
          of: bar,
          matching: find.byKey(const ValueKey('thumb-slider')),
        );
        final cards = images ? find.byType(ItemCard) : find.byType(PackTile);
        double card() => tester.getSize(cards.first).width;
        final n = tester.widget<Slider>(s).divisions! + 1;
        expect(n, greaterThan(2));
        final widths = <double>[];
        for (var i = 0; i < n; i++) {
          tester.widget<Slider>(s).onChanged!(i.toDouble());
          await tester.pump();
          await tester.pump();
          widths.add(card());
          // M80: no value popup while dragging.
          expect(tester.widget<Slider>(s).label, isNull);
          if (i > 0) expect(widths[i], greaterThan(widths[i - 1]));
        }
        final saved = images
            ? store.load().imageThumbSize
            : store.load().dashboardTileSize;
        expect(saved, closeTo(widths.last, 1e-6));
        // M80: a top stop over the old maximum fits the scroll area whole;
        // never over 800 px, always two per row.
        final range = images ? imageThumbRange : dashboardTileRange;
        expect(widths.last, lessThanOrEqualTo(maxCardWidth));
        final viewport = tester
            .getSize(
              find
                  .ancestor(of: cards.first, matching: find.byType(Scrollable))
                  .first,
            )
            .height;
        if (widths.last > range.max) {
          expect(
            tester.getSize(cards.first).height,
            lessThanOrEqualTo(viewport),
          );
        }
        expect(
          find.descendant(
            of: bar,
            matching: find.byWidgetPredicate(
              (w) => w is Tooltip && (w.message ?? '').contains('px'),
            ),
          ),
          findsNothing,
        );
      });
    }

    testWidgets('detail search box and Favorites chip share a radius', (
      tester,
    ) async {
      await openKnight(tester);
      final field = tester.widget<TextField>(
        find.widgetWithText(TextField, 'Search files'),
      );
      final border = field.decoration!.border! as OutlineInputBorder;
      final chip = tester.widget<FilterChip>(
        find.byKey(const ValueKey('detail-favorites-chip')),
      );
      final shape = chip.shape! as RoundedRectangleBorder;
      expect(border.borderRadius, shape.borderRadius);
      expect(border.borderRadius, detailControlRadius);
    });

    testWidgets('About and Help link to GitHub and itch.io', (tester) async {
      final launched = <Uri>[];
      await openKnight(
        tester,
        open: false,
        overrides: [
          urlLauncherProvider.overrideWithValue((uri) async {
            launched.add(uri);
            return true;
          }),
        ],
      );
      await tester.tap(find.byTooltip('Settings (Ctrl+,)'));
      await tester.pumpAndSettle();
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
      expect(
        find.textContaining('Star the project on ', findRichText: true),
        findsOneWidget,
      );
      expect(
        find.textContaining('Download it on ', findRichText: true),
        findsOneWidget,
      );
      // No URL text shown.
      expect(find.textContaining('https://', findRichText: true), findsNothing);
      await tester.ensureVisible(find.byKey(const ValueKey('link:GitHub')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('link:GitHub')));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.ensureVisible(find.byKey(const ValueKey('link:itch.io')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('link:itch.io')));
      await tester.pump(const Duration(milliseconds: 500));
      expect(launched, [Uri.parse(appGitHubUrl), Uri.parse(appItchUrl)]);
      // M54: no license line in About.
      expect(
        find.textContaining('not for resale', findRichText: true),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('link:license')), findsNothing);
      expect(appGitHubUrl, 'https://github.com/bozjator/loot-silo');
      expect(appItchUrl, 'https://bozjator.itch.io/loot-silo');

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.f1);
      await tester.pumpAndSettle();
      final help = find
          .descendant(
            of: find.byType(HelpScreen),
            matching: find.byType(Scrollable),
          )
          .first;
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('link:GitHub')),
        600,
        scrollable: help,
      );
      await tester.ensureVisible(find.byKey(const ValueKey('link:GitHub')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('link:GitHub')));
      expect(launched.last, Uri.parse(appGitHubUrl));
    });
  });

  group('Models tab (M60)', () {
    final reveals = <String>[];

    Future<void> open(WidgetTester tester, {List<String>? types}) async {
      reveals.clear();
      final tmpModels = Directory.systemTemp.createTempSync('m60');
      addTearDown(() => tmpModels.deleteSync(recursive: true));
      final (json, bin) = cubeGltf();
      final obj = writeCubeObj(tmpModels.path, 'tree');
      await openKnight(
        tester,
        files: const [],
        types: types,
        raw: {
          'Models/GLTF format/tree.glb': glbBytes(json, bin),
          'Models/OBJ format/tree.obj': obj.readAsBytesSync(),
          'Models/OBJ format/tree.mtl': File(p.join(tmpModels.path, 'tree.mtl'))
              .readAsBytesSync(),
          'Models/FBX format/tree.fbx': [0, 1, 2],
          'Models/GLTF format/broken.glb': [1, 2, 3, 4],
          'Models/FBX format/fence.fbx': [0],
        },
        overrides: [
          // Read on the test's thread: isolates need real time.
          modelCacheProvider.overrideWithValue(
            ModelCache(read: (path) async => readModelForPreview(path)),
          ),
          revealProvider.overrideWithValue((path) async => reveals.add(path)),
        ],
      );
      if (types == null) {
        await tester.tap(find.textContaining('Models ('));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
      }
      await tester.pump();
    }

    testWidgets('M75: a model card\'s right-click menu: file items', (
      tester,
    ) async {
      await open(tester);
      final card = find.byKey(const ValueKey('model:models/tree'));
      await tester.tap(card, buttons: kSecondaryButton);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        [
          for (final e
              in find
                  .descendant(
                    of: find.byType(PopupMenuItem<FileMenuAction>),
                    matching: find.byType(ListTile),
                  )
                  .evaluate())
            ((e.widget as ListTile).title! as Text).data!,
        ],
        Platform.isLinux
            ? ['Copy file', 'Copy path', 'Open', 'Open with…']
            : ['Copy path', 'Open'],
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump(const Duration(milliseconds: 300));
    });

    testWidgets('one card per model; FBX-only models stay other files', (
      tester,
    ) async {
      await open(tester);
      expect(find.text('Models (2)'), findsOneWidget);
      expect(find.byKey(const ValueKey('model:models/tree')), findsOneWidget);
      expect(find.byKey(const ValueKey('model:models/broken')), findsOneWidget);
      expect(find.textContaining('Other files'), findsOneWidget);
      // Drawn, with formats and the triangle count in the footer.
      expect(find.byKey(const ValueKey('model-paint')), findsOneWidget);
      expect(find.text('12 triangles · GLB, OBJ, FBX'), findsOneWidget);
    });

    testWidgets('a broken file shows the error stage with its reason', (
      tester,
    ) async {
      await open(tester);
      final error = find.byKey(const ValueKey('model-error'));
      expect(error, findsOneWidget);
      final tip = tester.widget<Tooltip>(
        find.ancestor(of: error, matching: find.byType(Tooltip)).first,
      );
      expect(tip.message, isNotEmpty);
    });

    testWidgets('format chips: OBJ draws the OBJ, FBX is revealed', (
      tester,
    ) async {
      await open(tester);
      final card = find.byKey(const ValueKey('model:models/tree'));
      expect(tester.widget<ItemCard>(card).path, 'Models/GLTF format/tree.glb');
      // Only the drawn format's chip until the card is hovered.
      final objChip = find.byKey(
        const ValueKey('format:Models/OBJ format/tree.obj'),
      );
      expect(objChip, findsNothing);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: tester.getCenter(card));
      addTearDown(mouse.removePointer);
      await tester.pump();
      expect(objChip, findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('format:Models/OBJ format/tree.obj')),
      );
      await tester.pump();
      await tester.pump();
      expect(tester.widget<ItemCard>(card).path, 'Models/OBJ format/tree.obj');
      expect(find.byKey(const ValueKey('model-paint')), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('format:Models/FBX format/tree.fbx')),
      );
      await tester.pump();
      expect(tester.widget<ItemCard>(card).path, 'Models/OBJ format/tree.obj');
      expect(reveals.single, endsWith('Models/FBX format/tree.fbx'));
    });

    testWidgets('M61: double-click opens the viewer; back button, Esc close', (
      tester,
    ) async {
      await open(tester);
      final card = find.byKey(const ValueKey('model:models/tree'));
      await tester.tap(card);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(card);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(ModelViewer), findsOneWidget);
      // In on-screen order: tree, then broken.
      expect(find.text('1 / 2'), findsOneWidget);
      final back = await tester.startGesture(
        const Offset(5, 895),
        kind: PointerDeviceKind.mouse,
        buttons: kBackMouseButton,
      );
      await back.up();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(ModelViewer), findsNothing);
      expect(find.byType(PackDetailScreen), findsOneWidget);

      // The card icon opens it too; Esc closes only the viewer.
      await back.moveTo(tester.getCenter(card));
      await tester.pump();
      await tester.tap(
        find.descendant(of: card, matching: find.byTooltip('Open in viewer')),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(ModelViewer), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(ModelViewer), findsNothing);
      expect(find.byType(PackDetailScreen), findsOneWidget);
    });

    testWidgets('search, By folder without format folders, 3D packs', (
      tester,
    ) async {
      await open(tester, types: ['3d']);
      // A 3D-only pack opens on Models.
      expect(find.byKey(const ValueKey('model:models/tree')), findsOneWidget);
      await tester.enterText(find.byType(TextField).first, 'tree');
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Models (1)'), findsOneWidget);
      expect(find.byKey(const ValueKey('model:models/broken')), findsNothing);
      await tester.tap(find.text('By folder'));
      await tester.pump();
      // One section: "Models", not "Models / GLTF format".
      expect(find.text('Models'), findsOneWidget);
      expect(find.textContaining('GLTF format'), findsNothing);
    });
  });

  group('Materials tab (M62)', () {
    final reveals = <String>[];
    // The viewer's options last for the session.
    setUp(materialViewOptions.reset);

    Future<void> open(WidgetTester tester, {List<String>? types}) async {
      reveals.clear();
      await openKnight(
        tester,
        files: const [
          'Stone/Rock_Color.png',
          'Stone/Rock_Normal.png',
          'Stone/Rock_Roughness.png',
          'Stone/Rock.png',
          'Wood_BaseColor.png',
          'Wood_Normal.png',
          'hero.png',
        ],
        raw: {
          'Stone/Rock.tres': [1],
        },
        types: types,
        overrides: [
          revealProvider.overrideWithValue((path) async => reveals.add(path)),
        ],
      );
      if (types == null) {
        await tester.tap(find.textContaining('Materials ('));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
      }
      await tester.pump();
    }

    final rock = find.byKey(const ValueKey('material:Stone/Rock'));
    final wood = find.byKey(const ValueKey('material:Wood'));

    testWidgets('one card per material; maps and previews leave Images', (
      tester,
    ) async {
      await open(tester);
      expect(find.text('Materials (2)'), findsOneWidget);
      // hero.png and the fixture's knight.png.
      expect(find.text('Images (2)'), findsOneWidget);
      expect(find.textContaining('Other files'), findsNothing);
      expect(rock, findsOneWidget);
      expect(wood, findsOneWidget);
      expect(
        find.descendant(of: rock, matching: find.text('8 px · 3 maps')),
        findsOneWidget,
      );
      // The shipped picture on Rock; Wood's Color map tiled 2 × 2.
      expect(
        find.byKey(const ValueKey('material-picture:Stone/Rock.png')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('material-picture:Wood_BaseColor.png')),
        findsNWidgets(4),
      );
    });

    testWidgets('map chips switch the picture, tool chips reveal', (
      tester,
    ) async {
      await open(tester);
      final normal = find.byKey(const ValueKey('map:Stone/Rock_Normal.png'));
      expect(normal, findsNothing);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: tester.getCenter(rock));
      addTearDown(mouse.removePointer);
      await tester.pump();
      expect(normal, findsOneWidget);
      // Both chip kinds show the hand.
      for (final chip in [
        normal,
        find.byKey(const ValueKey('format:Stone/Rock.tres')),
      ]) {
        await mouse.moveTo(tester.getCenter(chip));
        await tester.pump();
        expect(
          RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1),
          SystemMouseCursors.click,
        );
      }
      await tester.tap(normal);
      await tester.pump();
      expect(
        find.byKey(const ValueKey('material-picture:Stone/Rock_Normal.png')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('format:Stone/Rock.tres')));
      await tester.pump();
      expect(reveals.single, endsWith('Stone/Rock.tres'));
      // Leaving the card brings the picture back.
      await mouse.moveTo(const Offset(5, 895));
      await tester.pump();
      expect(
        find.byKey(const ValueKey('material-picture:Stone/Rock.png')),
        findsOneWidget,
      );
    });

    testWidgets('search by name and map role; material packs open here', (
      tester,
    ) async {
      await open(tester, types: ['material']);
      expect(rock, findsOneWidget);
      await tester.enterText(find.byType(TextField).first, 'roughness');
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Materials (1)'), findsOneWidget);
      expect(wood, findsNothing);
      await tester.enterText(find.byType(TextField).first, 'wood');
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Materials (1)'), findsOneWidget);
      expect(wood, findsOneWidget);
      expect(rock, findsNothing);
    });

    Future<void> openViewer(WidgetTester tester) async {
      // Maps decode and the shader loads on real time, so the viewer opens
      // with real timers (both clicks, so they share one clock).
      await tester.runAsync(() async {
        await tester.tap(rock);
        await tester.pump();
        await tester.tap(rock);
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      final loading = find.byKey(const ValueKey('material-loading'));
      for (var i = 0; i < 50 && loading.evaluate().isNotEmpty; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump();
      }
      expect(loading, findsNothing);
    }

    testWidgets('M63: double-click opens the viewer; ←/→, back, Esc', (
      tester,
    ) async {
      await open(tester);
      await openViewer(tester);
      expect(find.byType(MaterialViewer), findsOneWidget);
      // On-screen order: Stone/Rock, then Wood.
      expect(find.text('1 / 2'), findsOneWidget);
      expect(find.text('Stone/Rock'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(find.text('2 / 2'), findsOneWidget);
      expect(find.text('Wood'), findsWidgets);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      expect(find.text('1 / 2'), findsOneWidget);

      final back = await tester.startGesture(
        const Offset(5, 895),
        kind: PointerDeviceKind.mouse,
        buttons: kBackMouseButton,
      );
      await back.up();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(MaterialViewer), findsNothing);
      expect(find.byType(PackDetailScreen), findsOneWidget);

      await openViewer(tester);
      expect(find.byType(MaterialViewer), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(MaterialViewer), findsNothing);
      expect(find.byType(PackDetailScreen), findsOneWidget);
    });

    testWidgets('M63: modes, the map strip and the info panel', (tester) async {
      await open(tester);
      await openViewer(tester);
      expect(
        find.byKey(const ValueKey('material-shader:sphere')),
        findsOneWidget,
      );
      await tester.tap(find.text('Plane'));
      await tester.pump();
      expect(
        find.byKey(const ValueKey('material-shader:plane')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('material-tiling')), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit3);
      await tester.pump();
      expect(find.byKey(const ValueKey('material-tiled')), findsOneWidget);
      expect(find.byKey(const ValueKey('material-tiling')), findsNothing);

      // The strip: one entry per map, with its pixel size; a click shows it.
      for (final m in ['Color', 'Normal', 'Roughness']) {
        expect(find.byKey(ValueKey('strip:Stone/Rock_$m.png')), findsOneWidget);
      }
      expect(
        find.byKey(const ValueKey('strip-size:Stone/Rock_Normal.png')),
        findsOneWidget,
      );
      expect(find.text('8 × 8'), findsNWidgets(3));
      await tester.tap(
        find.byKey(const ValueKey('strip:Stone/Rock_Normal.png')),
      );
      await tester.pump();
      expect(
        find.byKey(const ValueKey('material-map:Stone/Rock_Normal.png')),
        findsOneWidget,
      );

      // Info: maps with roles, the tool file chip reveals, total size.
      final info = find.byKey(const ValueKey('material-info'));
      expect(
        find.descendant(of: info, matching: find.text('Folder')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('info-map:Stone/Rock_Roughness.png')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('info:total')), findsOneWidget);
      await tester.tap(
        find.descendant(
          of: info,
          matching: find.byKey(const ValueKey('format:Stone/Rock.tres')),
        ),
      );
      await tester.pump();
      expect(reveals.single, endsWith('Stone/Rock.tres'));
      await tester.tap(find.text('Show in file manager'));
      await tester.pump();
      expect(reveals.last, endsWith('Stone/Rock.png'));
    });

    testWidgets('the star saves the material key', (tester) async {
      await open(tester);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: tester.getCenter(wood));
      addTearDown(mouse.removePointer);
      await tester.pump();
      await tester.tap(
        find.descendant(of: wood, matching: find.byType(FavoriteStar)),
      );
      await tester.pump();
      final sidecar = PackSidecar.read(
        p.join(tmp.path, 'library', 'HeroMaker', 'Knight Pack'),
      );
      expect(sidecar?.favoriteFiles, ['Wood']);
    });
  });
}

const previewBoxWidthForTest = 440.0;
