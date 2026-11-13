import 'dart:math' as math;

import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
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

    testWidgets('with a key the itch.io button says Import from itch.io', (
      tester,
    ) async {
      await pumpEmpty(tester, key: 'test-key');
      expect(find.text('Import from itch.io'), findsOneWidget);
      expect(find.text('Connect itch.io'), findsNothing);
      expect(find.text('Download from itch.io'), findsNothing);
    });

    for (final key in [null, 'test-key']) {
      testWidgets('M78: three filled buttons, one width (key: $key)', (
        tester,
      ) async {
        await pumpEmpty(tester, key: key);
        const keys = [
          'first-import-folder',
          'first-import-archive',
          'first-itch',
        ];
        final rects = [
          for (final k in keys) tester.getRect(find.byKey(ValueKey(k))),
        ];
        for (final k in keys) {
          final w = tester.widget(find.byKey(ValueKey(k)));
          expect(w, isA<FilledButton>(), reason: k);
          // One style: none of them overrides the theme's.
          expect((w as FilledButton).style, isNull, reason: k);
        }
        for (final r in rects.skip(1)) {
          expect(r.width, rects.first.width);
          expect(r.left, rects.first.left);
        }
        // The widest label sets the width: its text is not cut, and the
        // button is no wider than it needs (label + icon + padding).
        final widest = keys
            .map(
              (k) => tester
                  .getSize(
                    find.descendant(
                      of: find.byKey(ValueKey(k)),
                      matching: find.byType(Text),
                    ),
                  )
                  .width,
            )
            .reduce(math.max);
        expect(rects.first.width, lessThan(widest + 80));
        expect(rects.first.width, greaterThan(widest + 30));
        // The lines beside them start at one x.
        final lines = [
          'Copy packs from a folder',
          'Unpack zip, tar, 7z or rar',
          key == null
              ? 'Sign in with an API key'
              : 'Download the assets you own',
        ].map((t) => tester.getTopLeft(find.textContaining(t)).dx).toSet();
        expect(lines, hasLength(1));
        expect(lines.single, greaterThan(rects.first.right));
      });
    }
  });

  group('M76 itch.io screen', () {
    Future<void> pumpItch(
      WidgetTester tester,
      List<ItchMatch> matches, {
      Size size = const Size(1200, 800),
    }) async {
      await tester.binding.setSurfaceSize(size);
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
          'Packs you added yourself (folder or archive) that look like '
              'assets you own on itch.io: same title and author.',
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
        expect(find.textContaining('Probably already'), findsNothing);
      }
      // No bulk button over an empty list.
      expect(find.byType(FilledButton), findsNothing);
    });

    testWidgets('a narrow window: space between the hint and the bulk button', (
      tester,
    ) async {
      await pumpItch(tester, [
        ItchMatch(_owned(1, 'Orc Pack'), MatchKind.missing),
        ItchMatch(
          _owned(2, 'Slime Pack'),
          MatchKind.fuzzy,
          pack: PackRow(
            id: 'orcmaker/Slime Pack',
            path: '/lib/orcmaker/Slime Pack',
            title: 'Slime Pack',
            author: 'orcmaker',
            isContainer: false,
            types: const [],
            tags: const [],
            usedIn: const [],
            favorite: false,
            favoriteFiles: const [],
            fileCount: 1,
            totalBytes: 1,
          ),
        ),
      ], size: const Size(800, 600));
      for (final (tab, hint) in [
        ('Missing', 'Not in the library.'),
        ('To link', 'Packs you added yourself'),
      ]) {
        await tester.tap(find.widgetWithText(Tab, tab));
        await tester.pumpAndSettle();
        final text = tester.getRect(find.textContaining(hint));
        final button = tester.getRect(find.byType(FilledButton));
        expect(button.left - text.right, greaterThanOrEqualTo(12), reason: tab);
      }
    });

    group('M90 striped rows', () {
      Finder row(int id) => find.byKey(ValueKey('itch-row:$id'));

      Color colorOf(WidgetTester tester, int id) => tester
          .widget<Material>(
            find.descendant(of: row(id), matching: find.byType(Material)).first,
          )
          .color!;

      PackRow pack(String id) => PackRow(
        id: id,
        path: '/lib/$id',
        title: id.split('/').last,
        author: id.split('/').first,
        isContainer: false,
        types: const [],
        tags: const [],
        usedIn: const [],
        favorite: false,
        favoriteFiles: const [],
        fileCount: 1,
        totalBytes: 1,
      );

      testWidgets('Missing: odd rows tinted, full width, hover highlight', (
        tester,
      ) async {
        await pumpItch(tester, [
          for (var i = 1; i <= 4; i++)
            ItchMatch(_owned(i, 'Pack $i'), MatchKind.missing),
        ]);
        final context = tester.element(row(1));
        final theme = Theme.of(context);
        final scheme = theme.colorScheme;
        expect(colorOf(tester, 1), theme.scaffoldBackgroundColor);
        expect(colorOf(tester, 2), scheme.surfaceContainer);
        expect(colorOf(tester, 3), theme.scaffoldBackgroundColor);
        expect(colorOf(tester, 4), scheme.surfaceContainer);
        expect(scheme.surfaceContainer, isNot(theme.scaffoldBackgroundColor));

        // Row 1's background spans the list, its Download button included.
        final list = tester.getRect(find.byType(ListView));
        final band = tester.getRect(row(2));
        expect(band.left, list.left);
        expect(band.right, list.right);
        final download = tester.getRect(
          find.descendant(
            of: row(2),
            matching: find.widgetWithText(OutlinedButton, 'Download'),
          ),
        );
        expect(band.contains(download.topLeft), isTrue);
        expect(
          band.contains(download.bottomRight - const Offset(1, 1)),
          isTrue,
        );

        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: tester.getCenter(row(1)));
        addTearDown(mouse.removePointer);
        await tester.pump();
        expect(colorOf(tester, 1), scheme.surfaceContainerHighest);
        await mouse.moveTo(const Offset(1, 1));
        await tester.pump();
        expect(colorOf(tester, 1), theme.scaffoldBackgroundColor);
      });

      testWidgets('To link: the same stripes', (tester) async {
        await pumpItch(tester, [
          for (var i = 1; i <= 3; i++)
            ItchMatch(
              _owned(i, 'Pack $i'),
              MatchKind.fuzzy,
              pack: pack('orcmaker/Pack $i'),
            ),
        ]);
        await tester.tap(find.widgetWithText(Tab, 'To link'));
        await tester.pumpAndSettle();
        final theme = Theme.of(tester.element(row(1)));
        expect(colorOf(tester, 1), theme.scaffoldBackgroundColor);
        expect(colorOf(tester, 2), theme.colorScheme.surfaceContainer);
        expect(colorOf(tester, 3), theme.scaffoldBackgroundColor);
        expect(
          find.descendant(
            of: row(2),
            matching: find.widgetWithText(OutlinedButton, 'Link'),
          ),
          findsOneWidget,
        );
      });
    });
  });
}
