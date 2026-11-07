import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loot_silo/state/dashboard.dart';
import 'package:loot_silo/state/providers.dart';
import 'package:loot_silo/state/settings.dart';
import 'package:loot_silo/ui/settings_screen.dart';
import 'package:loot_silo/ui/theme_colors.dart';
import 'package:loot_silo/ui/widgets/filter_bar.dart';
import 'package:path/path.dart' as p;

/// Milestone 51: colour themes.
void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('theme'));
  tearDown(() => tmp.deleteSync(recursive: true));

  group('theme_color setting', () {
    test('defaults to teal and round-trips by name', () {
      expect(const AppSettings().themeColor, ThemeColor.teal);
      final f = File(p.join(tmp.path, 'settings.json'));
      final store = SettingsStore(f)
        ..save(const AppSettings(themeColor: ThemeColor.blueGrey));
      expect(f.readAsStringSync(), contains('"theme_color": "blueGrey"'));
      expect(store.load().themeColor, ThemeColor.blueGrey);
      for (final c in ThemeColor.values) {
        expect(
          AppSettings.fromJson(AppSettings(themeColor: c).toJson()).themeColor,
          c,
        );
      }
    });

    test('an unknown or missing name falls back to teal', () {
      expect(
        AppSettings.fromJson({'theme_color': 'chartreuse'}).themeColor,
        ThemeColor.teal,
      );
      expect(
        AppSettings.fromJson({'theme_color': 42}).themeColor,
        ThemeColor.teal,
      );
      expect(AppSettings.fromJson({}).themeColor, ThemeColor.teal);
    });

    test('teal is the old seed; every preset has its own seed and name', () {
      expect(ThemeColor.teal.seed, Colors.teal);
      expect(
        ThemeColor.values.map((c) => c.seed).toSet(),
        hasLength(ThemeColor.values.length),
      );
      expect(ThemeColor.blueGrey.label, 'Blue grey');
      expect(ThemeColor.teal.label, 'Teal');
    });
  });

  testWidgets('picking a swatch recolours light and dark at once', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final store = SettingsStore(File(p.join(tmp.path, 'settings.json')));
    final container = ProviderContainer(
      overrides: [settingsStoreProvider.overrideWithValue(store)],
    );
    addTearDown(container.dispose);

    Color primary() =>
        Theme.of(tester.element(find.byType(SettingsScreen)))
            .colorScheme
            .primary;

    for (final brightness in [Brightness.light, Brightness.dark]) {
      container
          .read(settingsProvider.notifier)
          .setTheme(
            brightness == Brightness.light
                ? ThemeChoice.light
                : ThemeChoice.dark,
          );
      container.read(settingsProvider.notifier).setThemeColor(ThemeColor.teal);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: Consumer(
            builder: (context, ref, _) {
              final s = ref.watch(settingsProvider);
              return MaterialApp(
                themeMode: s.theme == ThemeChoice.dark
                    ? ThemeMode.dark
                    : ThemeMode.light,
                theme: appTheme(s.themeColor, Brightness.light),
                darkTheme: appTheme(s.themeColor, Brightness.dark),
                home: const SettingsScreen(),
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      final teal = primary();
      expect(
        teal,
        ColorScheme.fromSeed(
          seedColor: Colors.teal,
          brightness: brightness,
        ).primary,
      );
      final purple = find.byKey(const ValueKey('theme-color:purple'));
      expect(purple, findsOneWidget);
      expect(find.byTooltip('Purple'), findsOneWidget);
      // Only the selected swatch has a check mark.
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('theme-color:teal')),
          matching: find.byIcon(Icons.check),
        ),
        findsOneWidget,
      );
      await tester.tap(purple);
      await tester.pumpAndSettle();
      expect(primary(), isNot(teal));
      expect(
        primary(),
        ColorScheme.fromSeed(
          seedColor: Colors.purple,
          brightness: brightness,
        ).primary,
      );
      expect(
        find.descendant(of: purple, matching: find.byIcon(Icons.check)),
        findsOneWidget,
      );
      expect(store.load().themeColor, ThemeColor.purple);
    }
  });

  testWidgets('a selected type chip changes colour with the theme', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 300));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = TextEditingController();
    final focus = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focus.dispose);
    final key = GlobalKey();

    Future<Color> chipColour(ThemeColor color) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(color, Brightness.light),
          home: Scaffold(
            body: RepaintBoundary(
              key: key,
              child: FilterBar(
                query: const DashboardQuery(types: {'character'}),
                facets: const Facets(
                  types: [('character', 3)],
                  authors: [],
                  tags: [],
                  sources: [],
                ),
                resultCount: 3,
                searchController: controller,
                searchFocus: focus,
                onText: (_) {},
                onToggleType: (_) {},
                onToggleAuthor: (_) {},
                onToggleTag: (_) {},
                onToggleSource: (_) {},
                onSort: (_) {},
                onClear: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final chip = tester.getRect(
        find.ancestor(
          of: find.text('character'),
          matching: find.byType(FilterChip),
        ),
      );
      final origin = tester.getTopLeft(find.byKey(key));
      // Inside the chip, between its rounded corner and the label.
      final at = Offset(chip.left + 6, chip.center.dy) - origin;
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      return (await tester.runAsync(() async {
        final image = await boundary.toImage();
        final bytes = await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        );
        final i = (at.dy.round() * image.width + at.dx.round()) * 4;
        final c = Color.fromARGB(
          bytes!.getUint8(i + 3),
          bytes.getUint8(i),
          bytes.getUint8(i + 1),
          bytes.getUint8(i + 2),
        );
        image.dispose();
        return c;
      }))!;
    }

    final teal = await chipColour(ThemeColor.teal);
    final red = await chipColour(ThemeColor.red);
    final scheme = ColorScheme.fromSeed(seedColor: Colors.red);
    expect(red, isNot(teal));
    // The selected chip is filled with the scheme's secondary container.
    expect(red, scheme.secondaryContainer.withAlpha(255));
  });
}
