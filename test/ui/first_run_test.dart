import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loot_silo/core/library_index.dart';
import 'package:loot_silo/itch/itch_api.dart';
import 'package:loot_silo/itch/itch_matcher.dart';
import 'package:loot_silo/state/itch.dart';
import 'package:loot_silo/state/providers.dart';
import 'package:loot_silo/state/settings.dart';
import 'package:loot_silo/ui/app.dart';
import 'package:loot_silo/ui/itch_screen.dart';
import 'package:path/path.dart' as p;

class _Keys implements KeyStore {
  _Keys(this.key);
  final String? key;
  @override
  Future<String?> read() async => key;
  @override
  Future<void> write(String key) async {}
  @override
  Future<void> delete() async {}
}

OwnedKey _owned(int id, String title) => OwnedKey.fromJson({
  'id': id * 10,
  'game': {
    'id': id,
    'title': title,
    'url': 'https://orcmaker.itch.io/x$id',
    'classification': 'assets',
    'user': {'id': 7, 'username': 'orcmaker'},
  },
});

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('first'));
  tearDown(() => tmp.deleteSync(recursive: true));

  group('M76 empty library', () {
    Future<List<String>> pumpEmpty(
      WidgetTester tester, {
      String? key,
      Size size = const Size(1400, 900),
    }) async {
      final picks = <String>[];
      final library = Directory(p.join(tmp.path, 'library'))..createSync();
      final store = SettingsStore(File(p.join(tmp.path, 'settings.json')))
        ..save(AppSettings(libraryPath: library.path));
      final index = LibraryIndex(NativeDatabase.memory());
      addTearDown(index.close);
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            settingsStoreProvider.overrideWithValue(store),
            libraryIndexProvider.overrideWithValue(index),
            directoryPickerProvider.overrideWithValue((title) async {
              picks.add('folder:$title');
              return null;
            }),
            archivePickerProvider.overrideWithValue(() async {
              picks.add('archive');
              return const [];
            }),
            keyStoreProvider.overrideWithValue(_Keys(key)),
            envKeyProvider.overrideWithValue(() => null),
            itchAccountProvider.overrideWith((ref) async => null),
          ],
          child: const LootSiloApp(),
        ),
      );
      for (var i = 0; i < 20; i++) {
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump(const Duration(milliseconds: 50));
      }
      return picks;
    }

    testWidgets('shows three ways to start, each opens its flow', (
      tester,
    ) async {
      final picks = await pumpEmpty(tester);
      expect(find.text('Your library is empty'), findsOneWidget);
      expect(find.text('Add your first packs in one of these ways:'), findsOne);
      for (final k in [
        'first-import-folder',
        'first-import-archive',
        'first-itch',
      ]) {
        expect(find.byKey(ValueKey(k)), findsOneWidget, reason: k);
      }
      expect(find.text('Connect itch.io'), findsOneWidget);
      expect(find.textContaining('Copy packs from a folder'), findsOneWidget);
      expect(find.textContaining('Unpack zip, tar, 7z or rar'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('first-import-folder')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('first-import-archive')));
      await tester.pump();
      expect(picks, ['folder:Import folder', 'archive']);

      await tester.tap(find.byKey(const ValueKey('first-itch')));
      await tester.pumpAndSettle();
      expect(find.byType(ItchScreen), findsOneWidget);
    });

    testWidgets('a narrow window wraps the lines, nothing overflows', (
      tester,
    ) async {
      await pumpEmpty(tester, size: const Size(600, 700));
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('first-itch')), findsOneWidget);
    });

    testWidgets('with a key the itch.io button says Download', (tester) async {
      await pumpEmpty(tester, key: 'test-key');
      expect(find.text('Download from itch.io'), findsOneWidget);
      expect(find.text('Connect itch.io'), findsNothing);
    });
  });

  group('M76 itch.io screen', () {
    Future<void> pumpItch(WidgetTester tester, List<ItchMatch> matches) async {
      await tester.binding.setSurfaceSize(const Size(1200, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final keys = [for (final m in matches) m.key];
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            keyStoreProvider.overrideWithValue(_Keys('test-key')),
            envKeyProvider.overrideWithValue(() => null),
            itchAccountProvider.overrideWith(
              (ref) async => ItchAccount(
                const ItchUser(id: 7, username: 'orcmaker'),
                keys,
              ),
            ),
            itchMatchesProvider.overrideWith((ref) async => matches),
          ],
          child: const MaterialApp(home: ItchScreen()),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('the header counts owned assets', (tester) async {
      await pumpItch(tester, [
        ItchMatch(_owned(1, 'Orc Pack'), MatchKind.missing),
        ItchMatch(_owned(2, 'Slime Pack'), MatchKind.missing),
      ]);
      expect(
        find.text('Signed in as orcmaker · 2 owned assets · 0 in the library'),
        findsOneWidget,
      );
      expect(find.textContaining('games'), findsNothing);
      expect(find.text('Refresh owned assets'), findsNothing); // a tooltip
      expect(find.byTooltip('Refresh owned assets'), findsOneWidget);
    });

    testWidgets('every empty tab still says what it is for', (tester) async {
      await pumpItch(tester, const []);
      final tabs = {
        'Missing': (
          'Every owned asset is in the library.',
          'Not in the library.',
        ),
        'To link': (
          'Nothing left to link.',
          'Probably already in the library.',
        ),
        'Inside a pack': ('None.', 'A folder inside one of the author'),
        'In library': (
          'No pack is linked to itch yet.',
          'Packs that know their itch.io page.',
        ),
      };
      for (final MapEntry(key: tab, value: (empty, hint)) in tabs.entries) {
        await tester.tap(find.widgetWithText(Tab, tab));
        await tester.pumpAndSettle();
        expect(find.text(empty), findsOneWidget, reason: tab);
        expect(find.textContaining(hint), findsOneWidget, reason: tab);
      }
      // No bulk button over an empty list.
      expect(find.byType(FilledButton), findsNothing);
    });
  });
}
