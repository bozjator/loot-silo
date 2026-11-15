import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show FrameTiming;

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:loot_silo/core/library_index.dart';
import 'package:loot_silo/state/folder_tree.dart';
import 'package:loot_silo/state/itch.dart';
import 'package:loot_silo/state/providers.dart';
import 'package:loot_silo/state/settings.dart';
import 'package:loot_silo/ui/app.dart';
import 'package:loot_silo/ui/folder_tree_panel.dart';
import 'package:loot_silo/ui/tabs.dart';
import 'package:path/path.dart' as p;

/// Frame timings of the dashboard's folder tree on the real library, meant
/// to run in profile mode (the numbers of a debug build are mostly JIT and
/// asserts):
///
///     flutter drive --profile -d linux \
///       --driver=test_driver/integration_test.dart \
///       --target=integration_test/tree_perf_test.dart
///
/// Read-only: the library is only scanned into an in-memory index.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  testWidgets('folder tree frame timings (real library)', (tester) async {
    final real = p.canonicalize('../assets_library');
    if (!Directory(p.join(real, 'Kenney')).existsSync()) return;
    final before = Directory(real).statSync().modified;
    final tmp = Directory.systemTemp.createTempSync('tree_perf');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final store = SettingsStore(File(p.join(tmp.path, 'settings.json')))
      ..save(AppSettings(libraryPath: real));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsStoreProvider.overrideWithValue(store),
          libraryIndexProvider.overrideWithValue(
            LibraryIndex(NativeDatabase.memory()),
          ),
          keyStoreProvider.overrideWithValue(_NoKeys()),
          envKeyProvider.overrideWithValue(() => null),
        ],
        child: const LootSiloApp(),
      ),
    );
    final c = ProviderScope.containerOf(tester.element(find.byType(TabsHost)));
    for (var i = 0; i < 1200 && c.read(libraryProvider).value == null; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
    final packs = c.read(libraryProvider).value!.packs;
    final kenney1 = packs.firstWhere(
      (pk) => pk.isBundle && pk.title.contains('Game Assets 1'),
    );
    await tester.runAsync(() => c.read(packsWithFoldersProvider.future));
    // Let thumbnails and the background cache fill quieten down.
    for (var i = 0; i < 30; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();
    }

    final frames = <FrameTiming>[];
    void collect(List<FrameTiming> t) => frames.addAll(t);
    WidgetsBinding.instance.addTimingsCallback(collect);
    addTearDown(() => WidgetsBinding.instance.removeTimingsCallback(collect));
    final results = <String, Object>{};
    Future<void> timed(String name, Future<void> Function() action) async {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 300)),
      );
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 300)),
      );
      frames.clear();
      await action();
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 1200)),
      );
      await tester.pump();
      double ms(Duration d) => d.inMicroseconds / 1000;
      final build = [for (final f in frames) ms(f.buildDuration)];
      final raster = [for (final f in frames) ms(f.rasterDuration)];
      final r = {
        'frames': frames.length,
        'build_max_ms': build.isEmpty ? 0 : build.reduce(math.max),
        'raster_max_ms': raster.isEmpty ? 0 : raster.reduce(math.max),
      };
      results[name] = r;
      // ignore: avoid_print
      print('tree_perf $name: $r');
    }

    await timed(
      'panel_opens',
      () => tester.tap(find.byKey(const ValueKey('folder-tree-toggle'))),
    );
    expect(find.byType(FolderTreePanel), findsOneWidget);
    await timed(
      'panel_closes',
      () => tester.tap(find.byKey(const ValueKey('folder-tree-toggle'))),
    );
    await timed(
      'panel_reopens',
      () => tester.tap(find.byKey(const ValueKey('folder-tree-toggle'))),
    );
    await tester.tap(find.byKey(const ValueKey('tree-fold:Kenney')));
    await tester.pump();
    await tester.tap(find.byKey(ValueKey('tree-fold:${kenney1.id}')));
    await tester.pump();
    final section = '${kenney1.id}/2D assets';
    await timed(
      'expand_2d_assets',
      () => tester.tap(find.byKey(ValueKey('tree-fold:$section'))),
    );
    await timed('scroll_tree', () async {
      final tree = find.byKey(const ValueKey('folder-tree'));
      for (var i = 0; i < 10; i++) {
        await tester.drag(tree, const Offset(0, -150));
        await tester.pump();
      }
    });
    await timed('select_section', () async {
      await tester.scrollUntilVisible(
        find.byKey(ValueKey('tree:$section')),
        -150,
        scrollable: find.descendant(
          of: find.byType(FolderTreePanel),
          matching: find.byType(Scrollable),
        ),
      );
      await tester.tap(find.byKey(ValueKey('tree:$section')));
    });
    binding.reportData = {'tree_perf': results};
    c.read(settingsProvider.notifier).setDashboardTreeOpen(false);
    await tester.pump();
    expect(Directory(real).statSync().modified, before);
  });
}

class _NoKeys implements KeyStore {
  @override
  Future<String?> read() async => null;

  @override
  Future<void> write(String k) async {}

  @override
  Future<void> delete() async {}
}
