import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:assets_explorer/core/library_index.dart';
import 'package:assets_explorer/state/itch.dart';
import 'package:assets_explorer/state/dashboard.dart';
import 'package:assets_explorer/state/providers.dart';
import 'package:assets_explorer/state/settings.dart';
import 'package:assets_explorer/ui/app.dart';
import 'package:assets_explorer/ui/image_viewer.dart';
import 'package:assets_explorer/ui/settings_screen.dart';
import 'package:assets_explorer/ui/track_player.dart';
import 'package:assets_explorer/ui/widgets/animated_sprite.dart';
import 'package:assets_explorer/ui/widgets/pack_tile.dart';
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
    if (types != null) {
      final sidecar = File(p.join(pack, 'asset_pack.json'));
      final json = jsonDecode(sidecar.readAsStringSync()) as Map;
      sidecar.writeAsStringSync(jsonEncode({...json, 'types': types}));
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
    await mouse.moveTo(tester.getCenter(find.text('Hover for details')));
    await tester.pump();
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

    testWidgets('All rows can be saved and the card plays every row', (
      tester,
    ) async {
      await openGrid(tester);
      FilledButton save() => tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Save'),
      );
      expect(save().onPressed, isNull);
      await tester.tap(find.text('Row 1'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('All rows').last);
      await tester.pumpAndSettle();
      expect(save().onPressed, isNotNull, reason: 'the row choice is dirty');
      await tester.tap(find.text('Save'));
      await pumpUntil(tester, find.text('Reset to detected'));
      expect(sidecar(), contains('"rows": "all"'));
      // Every sprite of this sheet (dialog preview and card) plays all rows.
      final sprites = tester.widgetList<AnimatedSprite>(
        find.byType(AnimatedSprite),
      );
      expect(sprites, isNotEmpty);
      for (final s in sprites) {
        expect(s.anim.rowToPlay, isNull);
      }
    });

    testWidgets('Not an animation moves the file to Images and back', (
      tester,
    ) async {
      await openGrid(tester);
      await tester.tap(find.text('Not an animation'));
      await pumpUntil(tester, find.textContaining('listed as an image only'));
      await pumpUntil(tester, find.textContaining('Images ('));
      expect(find.textContaining('Animations ('), findsNothing);
      expect(sidecar(), contains('"fx/Explosion(16x16).png": false'));
      expect(find.text('1 marked not an animation'), findsOneWidget);

      await tester.tap(find.text('1 marked not an animation'));
      await tester.pumpAndSettle();
      expect(find.text('fx/Explosion(16x16).png'), findsOneWidget);
      await tester.tap(find.text('Restore'));
      await pumpUntil(tester, find.textContaining('Animations ('));
      expect(sidecar(), isNot(contains('animations')));
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
}
