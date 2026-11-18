import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loot_silo/state/providers.dart';
import 'package:loot_silo/state/settings.dart';
import 'package:loot_silo/ui/settings_screen.dart';
import 'package:loot_silo/ui/theme_colors.dart';
import 'package:loot_silo/ui/widgets/glass.dart';
import 'package:path/path.dart' as p;

/// Settings → Appearance → Style: Glass or Classic.
void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('style'));
  tearDown(() => tmp.deleteSync(recursive: true));

  group('style setting', () {
    test('defaults to glass and round-trips by name', () {
      expect(const AppSettings().style, AppStyle.glass);
      final f = File(p.join(tmp.path, 'settings.json'));
      final store = SettingsStore(f)
        ..save(const AppSettings(style: AppStyle.classic));
      expect(f.readAsStringSync(), contains('"style": "classic"'));
      expect(store.load().style, AppStyle.classic);
      for (final s in AppStyle.values) {
        expect(AppSettings.fromJson(AppSettings(style: s).toJson()).style, s);
      }
    });

    test('an unknown or missing name falls back to glass', () {
      expect(AppSettings.fromJson({'style': 'neon'}).style, AppStyle.glass);
      expect(AppSettings.fromJson({}).style, AppStyle.glass);
    });
  });

  test('glass pages are see-through; classic ones solid, same shapes', () {
    for (final b in Brightness.values) {
      final glass = appTheme(ThemeColor.teal, b);
      final classic = appTheme(ThemeColor.teal, b, style: AppStyle.classic);
      expect(glass.extension<AppLook>()!.glass, isTrue);
      expect(classic.extension<AppLook>()!.glass, isFalse);
      expect(glass.scaffoldBackgroundColor.a, 0);
      expect(classic.scaffoldBackgroundColor.a, 1);
      expect(classic.cardTheme.color!.a, 1);
      // Shapes and the palette are shared.
      expect(classic.colorScheme, glass.colorScheme);
      expect(classic.cardTheme.shape, isA<RoundedRectangleBorder>());
      expect(
        (classic.inputDecorationTheme.border! as OutlineInputBorder)
            .borderRadius,
        (glass.inputDecorationTheme.border! as OutlineInputBorder).borderRadius,
      );
    }
  });

  testWidgets('the hover glow and sheen are glass only', (tester) async {
    Future<void> pump(AppStyle style) => tester.pumpWidget(
      MaterialApp(
        theme: appTheme(ThemeColor.teal, Brightness.dark, style: style),
        home: const Center(
          child: HoverLift(
            hover: true,
            child: SizedBox(
              width: 100,
              height: 100,
              child: GlassSheen(key: ValueKey('sheen')),
            ),
          ),
        ),
      ),
    );

    await pump(AppStyle.glass);
    expect(
      find.descendant(
        of: find.byType(HoverLift),
        matching: find.byType(AnimatedContainer),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('sheen')),
        matching: find.byType(DecoratedBox),
      ),
      findsOneWidget,
    );

    await pump(AppStyle.classic);
    // MaterialApp animates from one theme to the next.
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byType(HoverLift),
        matching: find.byType(AnimatedContainer),
      ),
      findsNothing,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('sheen')),
        matching: find.byType(DecoratedBox),
      ),
      findsNothing,
    );
  });

  group('pack covers setting', () {
    test('defaults to fill and round-trips by name', () {
      expect(const AppSettings().coverFit, CoverFit.fill);
      final f = File(p.join(tmp.path, 'settings.json'));
      final store = SettingsStore(f)
        ..save(const AppSettings(coverFit: CoverFit.fit));
      expect(f.readAsStringSync(), contains('"cover_fit": "fit"'));
      expect(store.load().coverFit, CoverFit.fit);
      expect(
        AppSettings.fromJson({'cover_fit': 'zoom'}).coverFit,
        CoverFit.fill,
      );
      expect(AppSettings.fromJson({}).coverFit, CoverFit.fill);
    });

    test('the theme carries it, in both styles', () {
      for (final style in AppStyle.values) {
        bool fills(CoverFit fit) => appTheme(
          ThemeColor.teal,
          Brightness.dark,
          style: style,
          coverFit: fit,
        ).extension<AppLook>()!.fillCovers;
        expect(fills(CoverFit.fit), isFalse);
        expect(fills(CoverFit.fill), isTrue);
      }
    });
  });

  testWidgets('picking Classic in Settings saves it and restyles the app', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final store = SettingsStore(File(p.join(tmp.path, 'settings.json')));
    final container = ProviderContainer(
      overrides: [settingsStoreProvider.overrideWithValue(store)],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: Consumer(
          builder: (context, ref, _) {
            final s = ref.watch(settingsProvider);
            return MaterialApp(
              theme: appTheme(
                s.themeColor,
                Brightness.light,
                style: s.style,
                coverFit: s.coverFit,
              ),
              home: const SettingsScreen(),
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    bool glass() => isGlass(tester.element(find.byType(SettingsScreen)));

    expect(find.text('Style'), findsOneWidget);
    expect(glass(), isTrue);
    await tester.tap(find.text('Classic'));
    await tester.pumpAndSettle();
    expect(glass(), isFalse);
    expect(store.load().style, AppStyle.classic);

    await tester.tap(find.text('Glass'));
    await tester.pumpAndSettle();
    expect(glass(), isTrue);
    expect(store.load().style, AppStyle.glass);

    // Pack covers: Fill by default; Fit, then Fill again.
    expect(find.text('Pack covers'), findsOneWidget);
    bool fills() => fillsCovers(tester.element(find.byType(SettingsScreen)));
    expect(fills(), isTrue);
    await tester.tap(find.text('Fit'));
    await tester.pumpAndSettle();
    expect(fills(), isFalse);
    expect(store.load().coverFit, CoverFit.fit);
    await tester.tap(find.text('Fill'));
    await tester.pumpAndSettle();
    expect(fills(), isTrue);
    expect(store.load().coverFit, CoverFit.fill);
  });
}
