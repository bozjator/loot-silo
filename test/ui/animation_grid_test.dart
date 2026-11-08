import 'dart:io';

import 'package:loot_silo/core/animation_detector.dart';
import 'package:loot_silo/state/providers.dart';
import 'package:loot_silo/state/settings.dart';
import 'package:loot_silo/ui/animation_grid.dart';
import 'package:loot_silo/ui/image_viewer.dart';
import 'package:loot_silo/ui/reveal.dart';
import 'package:loot_silo/ui/shortcuts.dart';
import 'package:loot_silo/ui/widgets/animated_sprite.dart';
import 'package:flutter/gestures.dart';
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
  late SettingsStore store;
  var detected = <SpriteAnim>[];
  var escapedToApp = 0;

  Future<void> pumpGrid(WidgetTester tester) async {
    detected = [];
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
            store = SettingsStore(File(p.join(tmp.path, 'settings.json'))),
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
                detected: detected.isEmpty ? anims : detected,
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

  /// Card icons take clicks only while the card is hovered.
  Future<void> hover(WidgetTester tester, String title) async {
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: tester.getCenter(find.text(title)));
    addTearDown(mouse.removePointer);
    await tester.pump();
  }

  testWidgets('a click focuses a card; others dim and pause', (tester) async {
    await pumpGrid(tester);
    expect(find.text('Knight idle'), findsOneWidget);
    expect(opacityOf(tester, 'Knight walk'), 1);
    // Hover mode (the default): nothing plays until hovered or focused.
    expect(playing(tester, 'Knight walk'), isFalse);

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

  testWidgets('the mouse back button leaves focus mode first (M40)', (
    tester,
  ) async {
    await pumpGrid(tester);
    // Nothing focused: the app gets the back button.
    expect(offerBack(), isFalse);
    await tester.tap(find.text('Knight idle'));
    await tester.pump();
    expect(opacityOf(tester, 'Knight walk'), 0.35);
    expect(offerBack(), isTrue);
    await tester.pump();
    expect(opacityOf(tester, 'Knight walk'), 1);
    expect(offerBack(), isFalse);
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

    await hover(tester, 'Knight attack');
    await tester.tap(find.byTooltip('Edit animation').at(2));
    expect(edited.single.path, 'knight_attack.png');
  });

  double iconsOpacity(WidgetTester tester, String title) => tester
      .widget<AnimatedOpacity>(
        find.descendant(
          of: find.ancestor(of: find.text(title), matching: find.byType(Card)),
          matching: find.byKey(const ValueKey('card-icons')),
        ),
      )
      .opacity;

  testWidgets('hover mode plays the hovered card; All plays every card', (
    tester,
  ) async {
    await pumpGrid(tester);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(990, 690));
    addTearDown(mouse.removePointer);
    await tester.pump();
    for (final n in ['Knight idle', 'Knight walk', 'Knight attack']) {
      expect(playing(tester, n), isFalse, reason: n);
      expect(iconsOpacity(tester, n), 0, reason: n);
    }

    await mouse.moveTo(tester.getCenter(find.text('Knight walk')));
    await tester.pump();
    expect(playing(tester, 'Knight walk'), isTrue);
    expect(playing(tester, 'Knight idle'), isFalse);
    expect(iconsOpacity(tester, 'Knight walk'), 1);
    expect(iconsOpacity(tester, 'Knight idle'), 0);
    // Hidden icons ignore clicks.
    expect(
      tester
          .widget<IgnorePointer>(
            find
                .ancestor(
                  of: find.byKey(const ValueKey('card-icons')).first,
                  matching: find.byType(IgnorePointer),
                )
                .first,
          )
          .ignoring,
      isTrue,
    );
    await mouse.moveTo(const Offset(990, 690));
    await tester.pump();
    expect(playing(tester, 'Knight walk'), isFalse);

    await tester.tap(find.text('All'));
    await tester.pump();
    expect(store.load().detailAnimateMode, AnimateMode.all);
    for (final n in ['Knight idle', 'Knight walk', 'Knight attack']) {
      expect(playing(tester, n), isTrue, reason: n);
    }
    // Focus still pauses the others.
    await tester.tap(find.text('Knight idle'));
    await tester.pump();
    expect(playing(tester, 'Knight walk'), isFalse);
    expect(playing(tester, 'Knight idle'), isTrue);
  });

  testWidgets('edited cards keep a badge without hover', (tester) async {
    await pumpGrid(tester);
    detected = [anims[0], anims[1].copyWith(fps: 4), anims[2]];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsStoreProvider.overrideWithValue(store),
          revealProvider.overrideWithValue((_) async {}),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: AnimationGrid(
              gridId: 'pack',
              packPath: tmp.path,
              animations: anims,
              detected: detected,
              onEdit: edited.add,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    final badge = find.byKey(const ValueKey('edited-badge'));
    expect(badge, findsOneWidget);
    expect(
      find.descendant(
        of: find.ancestor(
          of: find.text('Knight walk'),
          matching: find.byType(Card),
        ),
        matching: badge,
      ),
      findsOneWidget,
    );
  });

  testWidgets('the open icon shows the sheet in the viewer, in grid order', (
    tester,
  ) async {
    await pumpGrid(tester);
    await hover(tester, 'Knight walk');
    await tester.tap(find.byTooltip('Open image').at(1));
    await tester.pump(const Duration(milliseconds: 300));
    final viewer = tester.widget<ImageViewer>(find.byType(ImageViewer));
    expect(viewer.images, [
      'knight_idle.png',
      'knight_walk.png',
      'knight_attack.png',
    ]);
    expect(viewer.initialIndex, 1);
    // Esc closes the viewer, not the page.
    escapedToApp = 0;
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(ImageViewer), findsNothing);
    expect(escapedToApp, 0);
    // The card itself still focuses.
    await tester.tap(find.text('Knight walk'));
    await tester.pump();
    expect(opacityOf(tester, 'Knight idle'), 0.35);
  });

  testWidgets('M64: a double-click opens the viewer on that animation', (
    tester,
  ) async {
    await pumpGrid(tester);
    // One click only focuses.
    await tester.tap(find.text('Knight idle'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(ImageViewer), findsNothing);
    // A second click soon after opens the viewer on the same file as the
    // card's Open icon.
    await tester.tap(find.text('Knight attack'));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.text('Knight attack'));
    await tester.pump(const Duration(milliseconds: 300));
    final viewer = tester.widget<ImageViewer>(find.byType(ImageViewer));
    expect(viewer.images[viewer.initialIndex], 'knight_attack.png');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(ImageViewer), findsNothing);
    expect(opacityOf(tester, 'Knight idle'), 0.35);

    // Ctrl held: two clicks focus and unfocus, no viewer.
    await tester.pump(const Duration(seconds: 1));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.tap(find.text('Knight walk'));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.text('Knight walk'));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(ImageViewer), findsNothing);
  });
}
