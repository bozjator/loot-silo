import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:assets_explorer/core/library_index.dart';
import 'package:assets_explorer/state/itch.dart';
import 'package:assets_explorer/state/dashboard.dart';
import 'package:assets_explorer/state/providers.dart';
import 'package:assets_explorer/state/settings.dart';
import 'package:assets_explorer/ui/app.dart';
import 'package:assets_explorer/ui/help_screen.dart';
import 'package:assets_explorer/ui/image_viewer.dart';
import 'package:assets_explorer/ui/pack_detail_screen.dart';
import 'package:assets_explorer/ui/settings_screen.dart';
import 'package:assets_explorer/ui/tabs.dart';
import 'package:assets_explorer/ui/dashboard.dart';
import 'package:assets_explorer/ui/track_player.dart';
import 'package:assets_explorer/ui/widgets/animated_sprite.dart';
import 'package:assets_explorer/ui/widgets/pack_tile.dart';
import 'package:assets_explorer/ui/widgets/thumb_size.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

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
  @override
  Future<void> dispose() async {}
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
    Size size = const Size(1400, 900),
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
    List<String>? types,
    Map<String, Object?> sidecar = const {},
    List<Override> overrides = const [],
  }) async {
    final lib = p.join(tmp.path, 'library');
    copyTree('test/fixtures/managed', lib);
    final pack = p.join(lib, 'HeroMaker', 'Knight Pack');
    for (final rel in files) {
      File(p.join(pack, rel))
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(img.encodePng(img.Image(width: 8, height: 8)));
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
      ..save(AppSettings(libraryPath: lib));
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
        child: const AssetsExplorerApp(),
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
    await openKnight(tester, size: const Size(1400, 1600));
    await tester.tap(find.textContaining('Images ('));
    await tester.pumpAndSettle();
    await tester.tap(find.text('By folder'));
    await tester.pump();
    expect(store.load().imagesView, ItemsView.folders);
    expect(find.text('Pack root'), findsOneWidget);
    expect(find.text('Heroes / Archer'), findsOneWidget);
    expect(find.text('Heroes / Knight red'), findsOneWidget);

    // Root: knight.png, z_root.png; archer/c, d; knight_red/a, b.
    await tester.tap(find.text('z_root.png'));
    await tester.pumpAndSettle();
    expect(find.text('2 / 6'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(find.text('C'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(ImageViewer), findsNothing);

    // Folding a folder takes its images out of the viewer's list.
    await tester.tap(find.text('Heroes / Archer'));
    await tester.pump();
    await tester.tap(find.text('a.png'));
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
    expect(find.text('e.png'), findsOneWidget);
    expect(find.text('c.png'), findsNothing);

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
      final loop = tester.getRect(find.widgetWithText(FilterChip, 'Loop'));
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

      await tester.tap(find.text('long.ogg'));
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
      await tester.tap(find.text('short.wav'));
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
        find.ancestor(of: find.text('b.wav'), matching: find.byType(ListTile)),
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
        find.widgetWithText(TextField, 'Search files (Ctrl+F)'),
        'hit',
      );
      await tester.pump(DashboardQueryNotifier.searchDebounce);
      await tester.pump();
      expect(find.text('door.wav'), findsNothing);
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
      await tester.tap(find.text('c.wav'));
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
      await tester.tap(find.text('a.wav'));
      await tester.pump();
      expect(button('Play all'), findsOneWidget);
      await finish(tester);
      expect(played(), ['a.wav', 'a.wav', 'a.wav']);
    });

    testWidgets('Loop repeats the whole list, not one sound', (tester) async {
      await open(tester, files: const ['sfx/a.wav', 'sfx/b.wav']);
      await tester.tap(find.widgetWithText(FilterChip, 'Loop'));
      await tester.pump();
      await tester.tap(button('Play all'));
      await tester.pump();
      // The player doesn't loop the sound itself during the run.
      expect(fake.looping, isFalse);
      expect(
        tester
            .widget<FilterChip>(find.widgetWithText(FilterChip, 'Loop'))
            .tooltip,
        'Repeat the whole list',
      );
      await finish(tester);
      await finish(tester);
      await finish(tester);
      expect(played(), ['a.wav', 'b.wav', 'a.wav', 'b.wav']);
      // Stopped, a single sound loops again.
      await tester.tap(button('Stop'));
      await tester.pump();
      await tester.tap(find.text('b.wav'));
      await tester.pump();
      expect(fake.looping, isTrue);
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

    testWidgets('the view is saved; cards show name, length and folder', (
      tester,
    ) async {
      await openCards(tester);
      expect(store.load().audioView, AudioView.cards);
      expect(find.text('Long theme'), findsOneWidget);
      expect(find.text('Coin pickup'), findsOneWidget);
      expect(find.text('1:40'), findsOneWidget);
      expect(find.text(' · sfx'), findsOneWidget);
      await tester.tap(find.text('Rows'));
      await tester.pump();
      expect(store.load().audioView, AudioView.rows);
      expect(find.text('coin_pickup.wav'), findsOneWidget);
    });

    testWidgets('playing: progress ring, seek bar for long, keys work', (
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
      expect(find.byKey(const ValueKey('seek')), findsOneWidget);
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
      expect(find.byKey(const ValueKey('seek')), findsNothing);
      expect(find.byKey(const ValueKey('elapsed')), findsNothing);
      // Space stops it.
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(find.byKey(const ValueKey('progress')), findsNothing);
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
      await tester.tap(find.text('barrels_2.png'));
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
      Size size = const Size(1400, 900),
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

    testWidgets('Not an animation moves the file to Images and back', (
      tester,
    ) async {
      await openGrid(tester);
      await tester.tap(find.text('Not an animation'));
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
      await tester.tap(find.text('Not an animation'));
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
      await tester.tap(find.text('Not an animation'));
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
          // No animation word: only the square guess (9 × 128).
          'props/banner-plain.png': banner(),
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
    }) async {
      await openKnight(tester, files: const [], images: images);
      await tester.tap(find.textContaining('Images ('));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.text(byFolder ? 'By folder' : 'Flat').first);
      await tester.pump(const Duration(milliseconds: 300));
    }

    Future<TestGesture> hover(WidgetTester tester, String name) async {
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(
        location: tester.getCenter(
          find.ancestor(of: find.text(name), matching: find.byType(Card)).first,
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
      await tester.tap(find.byTooltip('Make animation…'));
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
      expect(find.text('portrait.png'), findsOneWidget);
      expect(find.text('panel.png'), findsNothing);
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
      expect(find.text('panel.png'), findsOneWidget);
    });

    /// Every file under the pack with its bytes, to show nothing changed.
    Map<String, String> snapshot() => {
      for (final f in Directory(packDir()).listSync(recursive: true))
        if (f is File)
          p.relative(f.path, from: packDir()): f.readAsBytesSync().join(','),
    };

    testWidgets('a folder header combines: confirm, preview, write on Save', (
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

      // Cancel on the confirmation writes nothing.
      await tester.tap(button);
      await pumpUntil(tester, find.byKey(const ValueKey('combine-confirm')));
      expect(
        find.textContaining(
          'Combine 3 images from Puff into one animation?',
          findRichText: true,
        ),
        findsOneWidget,
      );
      expect(
        find.textContaining('fx/puff/puff_animation.png', findRichText: true),
        findsOneWidget,
      );
      await tester.tap(find.text('Cancel'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(snapshot(), before);

      // Continue: the preview opens, still nothing on disk; Esc leaves.
      await tester.tap(button);
      await pumpUntil(tester, find.text('Continue'));
      await tester.tap(find.text('Continue'));
      await pumpUntil(tester, find.text('Apply size'));
      expect(find.text('Sheet · 8×8 frames · 3 × 1 · 3 frames'), findsOne);
      expect(find.textContaining('not saved yet'), findsOneWidget);
      expect(find.text('Not an animation'), findsNothing);
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
      await pumpUntil(tester, find.text('Continue'));
      await tester.tap(find.text('Continue'));
      await pumpUntil(tester, find.text('Apply size'));
      await tester.tap(find.text('Save'));
      await pumpUntil(tester, find.text('Back to image'));
      expect(out.existsSync(), isTrue);
      final strip = img.decodePng(out.readAsBytesSync())!;
      expect((strip.width, strip.height), (24, 8));
      expect(sidecar(), contains('"manual": true'));
      expect(sidecar(), contains('"frame_w": 8'));
      await tester.tap(find.text('Close'));
      await pumpUntil(tester, find.textContaining('Animations (1)'));

      // Again: Save asks before replacing; Cancel keeps the old file.
      await tester.pump(const Duration(milliseconds: 500));
      final saved = out.readAsBytesSync();
      await tester.tap(find.text('Combine into animation').first);
      await pumpUntil(tester, find.text('Continue'));
      await tester.tap(find.text('Continue'));
      await pumpUntil(tester, find.text('Apply size'));
      await tester.tap(find.text('Save'));
      await pumpUntil(tester, find.text('Replace animation?'));
      await tester.tap(find.text('Cancel'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(out.readAsBytesSync(), saved);
      expect(find.text('Apply size'), findsOneWidget, reason: 'still editing');
    });

    testWidgets('Flat view: Ctrl/Shift-click select, then combine', (
      tester,
    ) async {
      await openImages(tester, {
        'a/k1.png': solid(8, 8, 10),
        'a/k2.png': solid(8, 8, 20),
        'a/k3.png': solid(8, 8, 30),
        'b/z.png': solid(8, 8, 40),
      });
      Future<void> clickWith(LogicalKeyboardKey key, String name) async {
        await tester.sendKeyDownEvent(key);
        await tester.tap(find.text(name));
        await tester.sendKeyUpEvent(key);
        await tester.pump();
      }

      await clickWith(LogicalKeyboardKey.controlLeft, 'k1.png');
      expect(find.text('1 selected'), findsOneWidget);
      final combine = find.widgetWithText(
        FilledButton,
        'Combine 1 images into animation',
      );
      expect(tester.widget<FilledButton>(combine).onPressed, isNull);
      await clickWith(LogicalKeyboardKey.shiftLeft, 'k3.png');
      expect(find.text('3 selected'), findsOneWidget);
      // The hover checkbox toggles too.
      await hover(tester, 'z.png');
      await tester.tap(find.byKey(const ValueKey('select:b/z.png')));
      await tester.pump();
      expect(find.text('4 selected'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('select:b/z.png')));
      await tester.pump();
      await tester.tap(find.text('Combine 3 images into animation'));
      await pumpUntil(tester, find.text('Continue'));
      expect(
        find.textContaining(
          'Combine 3 images from A into one animation?',
          findRichText: true,
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('Continue'));
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

    Finder field() => find.widgetWithText(TextField, 'Search files (Ctrl+F)');

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
      expect(find.text('Barrels 0'), findsNothing); // not a card title
      expect(find.text('barrels_0.png'), findsOneWidget);
      expect(find.text('a.png'), findsNothing);

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
      final field = find.widgetWithText(TextField, 'Search files (Ctrl+F)');
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

    await tester.tap(find.byTooltip('How Asset Explorer works (F1)'));
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
    final entry = find.text('How Asset Explorer works');
    await tester.scrollUntilVisible(entry, 200);
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
      expect(chipText(tester, chip), 'Favorites 1');
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
      expect(chipText(tester, chip), 'Favorites 0');
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
            .ancestor(of: find.text('z_root.png'), matching: find.byType(Card))
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
      expect(find.text('Favorites (3)'), findsOneWidget);
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
}

const previewBoxWidthForTest = 440.0;
