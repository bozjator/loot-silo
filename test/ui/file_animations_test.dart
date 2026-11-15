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
import 'package:loot_silo/ui/file_results.dart';
import 'package:loot_silo/ui/pack_detail_screen.dart';
import 'package:loot_silo/ui/session.dart';
import 'package:loot_silo/ui/tabs.dart';
import 'package:loot_silo/ui/widgets/animated_sprite.dart';
import 'package:loot_silo/ui/widgets/item_card.dart';
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

/// M97: Files view hits that are animations play, and open focused.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late Directory tmp;
  late String lib;
  late File file;
  late LibraryIndex index;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('file_anims_ui');
    lib = p.join(tmp.path, 'library');
    copyTree('test/fixtures/managed', lib);
    File('test/fixtures/images/hero_walk.png')
        .copySync(p.join(lib, knight, 'hero_walk.png'));
    File(p.join(lib, knight, 'tree_walk.png'))
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

  /// Starts on the Files view searching "walk", with the cache filled.
  Future<ProviderContainer> start(
    WidgetTester tester, {
    AnimateMode mode = AnimateMode.hover,
  }) async {
    SettingsStore(file).save(
      AppSettings(
        libraryPath: lib,
        resumeSession: false,
        dashboardView: DashboardView.files,
        detailAnimateMode: mode,
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
    final packs = c.read(libraryProvider).value!.packs;
    await tester.runAsync(
      () => AnimCacheFiller(index, pause: Duration.zero).fill(packs),
    );
    c
        .read(dashboardQueryProvider.notifier)
        .restore(const DashboardQuery(text: 'walk'));
    await wait(
      tester,
      () => find.byKey(const ValueKey('animation-badge')).evaluate().isNotEmpty,
    );
    return c;
  }

  Finder sprite() => find.descendant(
    of: find.byType(FileResultsGrid),
    matching: find.byType(AnimatedSprite),
  );

  Future<void> quit(WidgetTester tester) async {
    await tester.pump(SessionKeeper.delay + const Duration(milliseconds: 100));
    await tester.pumpWidget(const SizedBox());
  }

  testWidgets('the strip plays with a badge; the still stays a still', (
    tester,
  ) async {
    await start(tester, mode: AnimateMode.all);
    expect(find.byKey(const ValueKey('animation-badge')), findsOneWidget);
    expect(sprite(), findsOneWidget);
    expect(tester.widget<AnimatedSprite>(sprite()).anim.path, 'hero_walk.png');
    expect(tester.widget<AnimatedSprite>(sprite()).playing, isTrue);
    // The still is a tile of its own, without a badge.
    expect(find.text('Tree walk'), findsOneWidget);
    expect(
      find.descendant(
        of: find.ancestor(
          of: find.text('Tree walk'),
          matching: find.byType(Card),
        ),
        matching: find.byKey(const ValueKey('animation-badge')),
      ),
      findsNothing,
    );
    await quit(tester);
  });

  testWidgets('hover mode: plays only while hovered', (tester) async {
    await start(tester);
    expect(tester.widget<AnimatedSprite>(sprite()).playing, isFalse);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: tester.getCenter(sprite()));
    addTearDown(mouse.removePointer);
    await tester.pump();
    expect(tester.widget<AnimatedSprite>(sprite()).playing, isTrue);
    await mouse.moveTo(Offset.zero);
    await tester.pump();
    expect(tester.widget<AnimatedSprite>(sprite()).playing, isFalse);
    await quit(tester);
  });

  testWidgets('a click opens the Animations tab with it focused', (
    tester,
  ) async {
    final c = await start(tester);
    await tester.tap(
      find.ancestor(of: sprite(), matching: find.byType(InkWell)).first,
    );
    await wait(
      tester,
      () => find.byType(PackDetailScreen).evaluate().isNotEmpty,
    );
    final focused = find.byWidgetPredicate(
      (w) => w is ItemCard && w.focused && w.path == 'hero_walk.png',
    );
    await wait(tester, () => focused.evaluate().isNotEmpty);
    expect(c.read(tabsProvider).active, 0, reason: 'opened in place');
    await quit(tester);
  });

  testWidgets('middle-click opens a pack tab, the same way', (tester) async {
    final c = await start(tester);
    final mouse = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
      buttons: kMiddleMouseButton,
    );
    await mouse.down(tester.getCenter(sprite()));
    await mouse.up();
    await tester.pump();
    expect(c.read(tabsProvider).tabs.single.packId, knight);
    expect(c.read(tabsProvider).tabs.single.file, 'hero_walk.png');
    c.read(tabsProvider.notifier).select(1);
    final focused = find.byWidgetPredicate(
      (w) => w is ItemCard && w.focused && w.path == 'hero_walk.png',
    );
    await wait(tester, () => focused.evaluate().isNotEmpty);
    await quit(tester);
  });
}
