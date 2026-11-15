import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:loot_silo/core/library_index.dart';
import 'package:loot_silo/state/anim_cache_fill.dart';
import 'package:loot_silo/state/dashboard.dart';
import 'package:loot_silo/state/itch.dart';
import 'package:loot_silo/state/providers.dart';
import 'package:loot_silo/state/settings.dart';
import 'package:loot_silo/ui/app.dart';
import 'package:loot_silo/ui/session.dart';
import 'package:loot_silo/ui/tabs.dart';
import 'package:loot_silo/ui/widgets/animated_sprite.dart';
import 'package:loot_silo/ui/widgets/pack_tile.dart';
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

const knight = 'HeroMaker/Knight Pack';
const slimes = 'HeroMaker/Slimes';

/// The animation badge on Packs and Expanded tiles: how many animations a
/// pack has, and one playing in a corner while the cover plays.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late Directory tmp;
  late String lib;
  late File file;
  late LibraryIndex index;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('pack_anims_ui');
    lib = p.join(tmp.path, 'library');
    copyTree('test/fixtures/managed', lib);
    final pack = p.join(lib, knight);
    // A still cover that outranks animations, and two animations.
    File(p.join(pack, 'preview.png'))
        .writeAsBytesSync(img.encodePng(img.Image(width: 64, height: 48)));
    for (final rel in ['walk/hero_walk.png', 'idle/hero_idle.png']) {
      File('test/fixtures/images/hero_walk.png').copySync(
        (File(p.join(pack, rel))..parent.createSync(recursive: true)).path,
      );
    }
    File(p.join(pack, 'walk', 'tree_walk.png'))
        .writeAsBytesSync(img.encodePng(img.Image(width: 16, height: 16)));
    file = File(p.join(tmp.path, 'settings.json'));
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  Future<void> wait(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 300 && !done(); i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    expect(done(), isTrue);
  }

  final badge = find.byKey(const ValueKey('pack-animations-badge'));
  final inset = find.byKey(const ValueKey('pack-animation-inset'));

  Finder tileOf(String id) =>
      find.byWidgetPredicate((w) => w is PackTile && w.pack.id == id);

  /// Fills the animation cache. Not awaited inside `runAsync`: the tiles'
  /// cache streams answer the fill's writes on the test's clock, so it is
  /// pumped until done.
  Future<void> fillCache(WidgetTester tester, ProviderContainer c) async {
    final packs = c.read(libraryProvider).value!.packs;
    var done = false;
    unawaited(
      AnimCacheFiller(
        index,
        pause: Duration.zero,
      ).fill(packs).whenComplete(() => done = true),
    );
    await wait(tester, () => done);
  }

  /// Starts on the Packs view; the animation cache filled when [fill].
  Future<ProviderContainer> start(
    WidgetTester tester, {
    bool animateAll = false,
    bool fill = true,
  }) async {
    SettingsStore(file).save(
      AppSettings(
        libraryPath: lib,
        resumeSession: false,
        animateAll: animateAll,
      ),
    );
    index = LibraryIndex(NativeDatabase.memory());
    addTearDown(index.close);
    await tester.binding.setSurfaceSize(const Size(1600, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsStoreProvider.overrideWithValue(SettingsStore(file)),
          libraryIndexProvider.overrideWithValue(index),
          keyStoreProvider.overrideWithValue(_NoKey()),
          envKeyProvider.overrideWithValue(() => null),
        ],
        child: const LootSiloApp(),
      ),
    );
    final c = ProviderScope.containerOf(tester.element(find.byType(TabsHost)));
    await wait(tester, () => c.read(sessionKeeperProvider).started);
    await wait(tester, () => tileOf(knight).evaluate().isNotEmpty);
    if (fill) {
      await fillCache(tester, c);
      await wait(tester, () => badge.evaluate().isNotEmpty);
    }
    return c;
  }

  Future<void> quit(WidgetTester tester) async {
    await tester.pump(SessionKeeper.delay + const Duration(milliseconds: 100));
    await tester.pumpWidget(const SizedBox());
  }

  testWidgets('no badge before the cache is filled; then "2" on the pack '
      'with animations only, and one plays while hovered', (tester) async {
    final c = await start(tester, fill: false);
    expect(badge, findsNothing, reason: 'nothing is decoded for it');

    final packs = c.read(libraryProvider).value!.packs;
    final cover = packs.firstWhere((pk) => pk.id == knight);
    expect(cover.preview, 'preview.png');
    expect(cover.previewAnim, isNull, reason: 'a still cover');
    await fillCache(tester, c);
    await wait(tester, () => badge.evaluate().isNotEmpty);
    expect(
      find.descendant(of: tileOf(knight), matching: badge),
      findsOneWidget,
    );
    expect(find.descendant(of: tileOf(slimes), matching: badge), findsNothing);
    expect(
      find.descendant(of: badge, matching: find.text('2')),
      findsOneWidget,
    );
    expect(find.byTooltip('2 animations'), findsOneWidget);
    expect(inset, findsNothing, reason: 'Hover mode, not hovered');

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: tester.getCenter(tileOf(knight)));
    addTearDown(mouse.removePointer);
    await tester.pump();
    expect(inset, findsOneWidget);
    final sprite = tester.widget<AnimatedSprite>(
      find.descendant(of: inset, matching: find.byType(AnimatedSprite)),
    );
    expect(sprite.packPath, p.join(lib, knight));
    expect(sprite.anim.path, 'idle/hero_idle.png', reason: 'idle first');
    expect(sprite.playing, isTrue);
    await mouse.moveTo(const Offset(1590, 890));
    await tester.pump();
    expect(inset, findsNothing);
    await quit(tester);
  });

  testWidgets('"Animate all" plays it without hovering', (tester) async {
    await start(tester, animateAll: true);
    expect(inset, findsOneWidget);
    await quit(tester);
  });

  testWidgets("the pack's animations: folders, a playing cover, and "
      "another pack's cache entry doesn't change them", (tester) async {
    final c = await start(tester);
    final anims = c.read(packAnimationsProvider(knight)).value!;
    expect(anims.keys.toSet(), {'walk/hero_walk.png', 'idle/hero_idle.png'});
    expect(c.read(packAnimationsProvider(slimes)).value, isEmpty);

    // An Expanded folder tile counts its own.
    final walk = tileAnimations(anims, folder: 'walk');
    expect(walk.count, 1);
    expect(walk.sample!.path, 'walk/hero_walk.png');
    expect(tileAnimations(anims, folder: 'other').count, 0);
    // A cover that plays already: the badge, no second animation.
    final playing = tileAnimations(anims, coverPlays: true);
    expect(playing.count, 2);
    expect(playing.sample, isNull);

    final sub = c.listen(packAnimationsProvider(knight), (_, _) {});
    addTearDown(sub.close);
    await tester.runAsync(() => index.putAnimCache(slimes, 'other', '{}'));
    await wait(tester, () => !c.read(packAnimationsProvider(knight)).isLoading);
    expect(
      c.read(packAnimationsProvider(knight)).value,
      same(anims),
      reason: "another pack's entry: Knight's are reused, not worked out again",
    );
    await quit(tester);
  });
}
