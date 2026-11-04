import 'dart:io';

import 'package:assets_explorer/core/animation_detector.dart';
import 'package:assets_explorer/state/providers.dart';
import 'package:assets_explorer/state/settings.dart';
import 'package:assets_explorer/ui/animation_grid.dart';
import 'package:assets_explorer/ui/reveal.dart';
import 'package:assets_explorer/ui/widgets/animated_sprite.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('anims'));
  tearDown(() => tmp.deleteSync(recursive: true));

  const names = ['knight_idle', 'knight_walk', 'knight_attack'];
  final anims = [
    for (final n in names)
      SpriteAnim(
        path: '$n.png',
        kind: AnimKind.sheet,
        frameW: 16,
        frameH: 16,
        cols: 4,
      ),
  ];

  final edited = <SpriteAnim>[];
  var escapedToApp = 0;

  Future<void> pumpGrid(WidgetTester tester) async {
    for (final n in names) {
      File(p.join(tmp.path, '$n.png'))
          .writeAsBytesSync(img.encodePng(img.Image(width: 64, height: 16)));
    }
    await tester.binding.setSurfaceSize(const Size(1000, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsStoreProvider.overrideWithValue(
            SettingsStore(File(p.join(tmp.path, 'settings.json'))),
          ),
          revealProvider.overrideWithValue((_) async {}),
        ],
        child: MaterialApp(
          // Stands in for the app-level Esc (close the page).
          home: CallbackShortcuts(
            bindings: {
              const SingleActivator(LogicalKeyboardKey.escape): () =>
                  escapedToApp++,
            },
            child: Scaffold(
              body: AnimationGrid(
                gridId: 'pack',
                packPath: tmp.path,
                animations: anims,
                detected: anims,
                onEdit: edited.add,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  double opacityOf(WidgetTester tester, String title) => tester
      .widget<AnimatedOpacity>(
        find.ancestor(
          of: find.text(title),
          matching: find.byType(AnimatedOpacity),
        ),
      )
      .opacity;

  double scaleOf(WidgetTester tester, String title) => tester
      .widget<AnimatedScale>(
        find.ancestor(
          of: find.text(title),
          matching: find.byType(AnimatedScale),
        ),
      )
      .scale;

  bool playing(WidgetTester tester, String title) => tester
      .widget<AnimatedSprite>(
        find.descendant(
          of: find.ancestor(of: find.text(title), matching: find.byType(Card)),
          matching: find.byType(AnimatedSprite),
        ),
      )
      .playing;

  testWidgets('a click focuses a card; others dim and pause', (tester) async {
    await pumpGrid(tester);
    expect(find.text('Knight idle'), findsOneWidget);
    expect(opacityOf(tester, 'Knight walk'), 1);
    expect(playing(tester, 'Knight walk'), isTrue);

    await tester.tap(find.text('Knight idle'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(scaleOf(tester, 'Knight idle'), greaterThan(1));
    expect(opacityOf(tester, 'Knight idle'), 1);
    expect(opacityOf(tester, 'Knight walk'), 0.35);
    expect(playing(tester, 'Knight walk'), isFalse);
    expect(playing(tester, 'Knight idle'), isTrue);

    // Clicking the focused card again clears it.
    await tester.tap(find.text('Knight idle'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(opacityOf(tester, 'Knight walk'), 1);
    expect(scaleOf(tester, 'Knight idle'), 1);
  });

  testWidgets('arrows move focus; Esc clears it before closing the page', (
    tester,
  ) async {
    escapedToApp = 0;
    await pumpGrid(tester);
    await tester.tap(find.text('Knight idle'));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(opacityOf(tester, 'Knight walk'), 1);
    expect(opacityOf(tester, 'Knight idle'), 0.35);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(opacityOf(tester, 'Knight attack'), 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(opacityOf(tester, 'Knight walk'), 1);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(opacityOf(tester, 'Knight attack'), 1);
    expect(escapedToApp, 0);
    // Nothing focused: Esc goes on to the app.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    expect(escapedToApp, 1);
  });

  testWidgets('clicking empty space clears focus; Edit reports the card', (
    tester,
  ) async {
    await pumpGrid(tester);
    await tester.tap(find.text('Knight walk'));
    await tester.pump();
    expect(opacityOf(tester, 'Knight idle'), 0.35);
    await tester.tapAt(const Offset(900, 650));
    await tester.pump();
    expect(opacityOf(tester, 'Knight idle'), 1);

    await tester.tap(find.byTooltip('Edit animation').at(2));
    expect(edited.single.path, 'knight_attack.png');
  });
}
