import 'dart:io';

import 'package:assets_explorer/core/animation_detector.dart';
import 'package:assets_explorer/core/library_index.dart';
import 'package:assets_explorer/state/dashboard.dart';
import 'package:assets_explorer/ui/widgets/filter_bar.dart';
import 'package:assets_explorer/ui/widgets/pack_tile.dart';
import 'package:assets_explorer/ui/widgets/pixel_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/fonts.dart';

Widget frame(Widget child, {Size size = const Size(240, 300)}) => MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: ThemeData(
    colorSchemeSeed: Colors.teal,
    brightness: Brightness.dark,
    fontFamily: 'Roboto',
  ),
  home: Scaffold(
    body: Center(
      child: SizedBox.fromSize(size: size, child: child),
    ),
  ),
);

PackRow row({
  String? preview,
  bool container = false,
  List<String> types = const ['character'],
  SpriteAnim? anim,
}) => PackRow(
  id: 'Hero/Pack',
  path: File('test/fixtures/images').absolute.path,
  title: 'Tiny Hero Pack v1.2',
  author: 'HeroMaker',
  isContainer: container,
  types: types,
  tags: const [],
  usedIn: const [],
  favorite: false,
  favoriteFiles: const [],
  preview: preview,
  previewAnim: anim,
  fileCount: 42,
  totalBytes: 1234567,
);

/// Decodes the fixture image for real (outside the fake-async zone) so
/// tiles find it in the image cache.
Future<void> precacheHero(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  final context = tester.element(find.byType(SizedBox));
  await tester.runAsync(() async {
    await precacheImage(
      PixelImage.providerFor(File('test/fixtures/images/hero.png').absolute),
      context,
    );
    await precacheImage(
      FileImage(File('test/fixtures/images/hero_walk.png').absolute),
      context,
    );
  });
}

/// Lets real image decoding finish.
Future<void> decode(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
  }
}

void main() {
  setUpAll(loadAppFonts);

  test('integerScale upscales in whole steps only', () {
    expect(integerScale(7.9), 7);
    expect(integerScale(1.2), 1);
    expect(integerScale(0.4), 0.4);
  });

  testWidgets('tile with pixel-art preview', (tester) async {
    await precacheHero(tester);
    await tester.pumpWidget(frame(PackTile(pack: row(preview: 'hero.png'))));
    await decode(tester);
    final raw = tester.widget<RawImage>(find.byType(RawImage));
    expect(raw.filterQuality, FilterQuality.none);
    expect(raw.width! / 12, raw.width! ~/ 12, reason: 'whole-number scale');
    await expectLater(
      find.byType(PackTile),
      matchesGoldenFile('goldens/tile_pixel.png'),
    );
  });

  testWidgets('bundle tile and generated audio tile', (tester) async {
    await precacheHero(tester);
    await tester.pumpWidget(
      frame(
        Row(
          children: [
            Expanded(
              child: PackTile(
                pack: row(
                  preview: 'hero.png',
                  container: true,
                  types: const ['3d', 'ui', 'sfx', 'font'],
                ),
                subPackCount: 63,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: PackTile(pack: row(types: const ['sfx'])),
            ),
          ],
        ),
        size: const Size(480, 300),
      ),
    );
    await decode(tester);
    expect(find.text('Bundle · 63'), findsOneWidget);
    expect(find.text('+1'), findsOneWidget);
    expect(find.byIcon(Icons.graphic_eq), findsOneWidget);
    await expectLater(
      find.byType(Row).first,
      matchesGoldenFile('goldens/tile_bundle_audio.png'),
    );
  });

  testWidgets('sprite-sheet tile shows its first frame', (tester) async {
    await precacheHero(tester);
    await tester.pumpWidget(
      frame(
        PackTile(
          pack: row(
            preview: 'hero_walk.png',
            anim: const SpriteAnim(
              path: 'hero_walk.png',
              kind: AnimKind.sheet,
              frameW: 12,
              frameH: 10,
              cols: 4,
            ),
          ),
        ),
      ),
    );
    await decode(tester);
    await expectLater(
      find.byType(PackTile),
      matchesGoldenFile('goldens/tile_sheet_frame0.png'),
    );
  });

  testWidgets('filter bar with active filters', (tester) async {
    final controller = TextEditingController(text: 'slime');
    final focus = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focus.dispose);
    final toggled = <String>[];
    await tester.pumpWidget(
      frame(
        FilterBar(
          query: const DashboardQuery(
            text: 'slime',
            types: {'character'},
            authors: {'Zerie'},
            tags: {'pixel-art'},
          ),
          facets: const Facets(
            types: [('character', 3), ('sfx', 2), ('tileset', 1)],
            authors: [('Zerie', 1), ('Kenney', 130)],
            tags: [('pixel-art', 9)],
            sources: [('imported', 71)],
          ),
          resultCount: 3,
          searchController: controller,
          searchFocus: focus,
          onText: (_) {},
          onToggleType: toggled.add,
          onToggleAuthor: toggled.add,
          onToggleTag: toggled.add,
          onToggleSource: toggled.add,
          onSort: (_) {},
          onClear: () => toggled.add('clear'),
        ),
        size: const Size(1100, 200),
      ),
    );
    expect(find.text('3 packs'), findsOneWidget);
    expect(find.text('Author · 1'), findsOneWidget);
    // Type chips show their count; types nothing has are hidden.
    expect(find.widgetWithText(FilterChip, '3'), findsOneWidget);
    expect(find.widgetWithText(FilterChip, 'music'), findsNothing);
    await expectLater(
      find.byType(FilterBar),
      matchesGoldenFile('goldens/filter_bar.png'),
    );

    await tester.tap(find.widgetWithText(FilterChip, 'sfx'));
    await tester.tap(
      find
          .descendant(
            of: find.widgetWithText(InputChip, 'Zerie'),
            matching: find.byType(Icon),
          )
          .last,
    );
    await tester.tap(find.text('Clear'));
    expect(toggled, ['sfx', 'Zerie', 'clear']);
  });
}
