import 'package:loot_silo/core/animation_detector.dart';
import 'package:loot_silo/ui/help_screen.dart';
import 'package:loot_silo/ui/shortcuts.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/logo.dart';

void main() {
  /// Every selectable paragraph on the page, joined.
  String pageText(WidgetTester tester) => [
    for (final e in find.byType(SelectableText).evaluate())
      (e.widget as SelectableText).data ?? '',
  ].join('\n');

  Future<void> pumpHelp(WidgetTester tester) async {
    // Tall enough that the whole list is built.
    await tester.binding.setSurfaceSize(const Size(1200, 16000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const MaterialApp(home: HelpScreen()));
    await tester.pump();
  }

  testWidgets('the word lists come from the animation detector', (
    tester,
  ) async {
    await pumpHelp(tester);
    final text = pageText(tester);
    expect(animationWords, containsAll(['walk', 'idle', 'attack', 'sheet']));
    expect(text, contains('Animation words: ${animationWords.join(', ')}.'));
    expect(text, contains('Sheet words: ${sheetWords.join(', ')}.'));
    expect(text, contains(notAnimationWords.join(', ')));
    expect(animationWords, orderedEquals([...animationWords]..sort()));
  });

  testWidgets('every shortcut and gesture of the table is listed', (
    tester,
  ) async {
    await pumpHelp(tester);
    final text = pageText(tester);
    for (final (where, keys) in shortcutSections) {
      expect(text, contains(where));
      for (final k in keys) {
        expect(text, contains(k.keys), reason: k.label);
        expect(text, contains(k.label));
      }
    }
    for (final m in mouseHelp) {
      expect(text, contains(m.gesture));
    }
    // The tab keys from M31 are there.
    expect(text, contains('Ctrl+Tab'));
    expect(text, contains('Ctrl+Shift+Tab'));
    expect(text, contains('Ctrl+W'));
    expect(text, contains('F1'));
  });

  testWidgets('M38: Favorites section', (tester) async {
    await pumpHelp(tester);
    final text = pageText(tester);
    expect(find.text('Favorites'), findsOneWidget);
    expect(text, contains('on image and animation cards'));
    expect(text, contains('The Favorites chip (★ and a count) in the'));
    expect(text, contains('In the Files view it lists the starred files'));
    expect(text, contains('Favorites chip on a pack page'));
    expect(text, contains('asset_pack.json'));
    expect(text, contains('Click a star'));
  });

  testWidgets('M45: import menu and the Not an animation confirmation', (
    tester,
  ) async {
    await pumpHelp(tester);
    final text = pageText(tester);
    expect(text, contains('The import button in the top bar'));
    expect(text, contains('"Not an animation" asks first'));
    expect(text, isNot(contains('Favorites (')));
  });

  testWidgets('M46: collapse / expand all folders', (tester) async {
    await pumpHelp(tester);
    expect(
      pageText(tester),
      contains('the button left of the view switch collapses every'),
    );
  });

  testWidgets('M47: cell size from the folder, Make animation guess', (
    tester,
  ) async {
    await pumpHelp(tester);
    final text = pageText(tester);
    expect(text, contains('A sheet can take its cell size from other'));
    expect(text, contains('starting from the best guess'));
  });

  testWidgets('M48: the Help title says Loot Silo', (tester) async {
    await pumpHelp(tester);
    expect(
      find.descendant(
        of: find.byType(AppBar),
        matching: find.text('How Loot Silo works'),
      ),
      findsOneWidget,
    );
    expect(pageText(tester), isNot(contains('Asset Explorer')));
    // M49: the logo at the top, before the first section.
    final logo = find.byKey(const ValueKey('app-logo'));
    expect(logo, findsOneWidget);
    expect(
      tester.getTopLeft(logo).dy,
      lessThan(tester.getTopLeft(find.text('Library layout')).dy),
    );
    expectLockup(tester);
  });

  testWidgets('M37: Play all and how Loop works with it', (tester) async {
    await pumpHelp(tester);
    final text = pageText(tester);
    expect(text, contains('Play all (Shift+Space)'));
    expect(text, contains('Loop repeats the whole list'));
    expect(text, contains(AppKeys.playAll.label));
    expect(AppKeys.playAll.keys, 'Shift+Space');
  });

  testWidgets('M36: header icons, hover delay, Dashboard tab', (tester) async {
    await pumpHelp(tester);
    final text = pageText(tester);
    expect(find.text('Pack page & tabs'), findsOneWidget);
    expect(text, contains("in the header's top-right corner"));
    expect(text, contains('Rest the pointer on the bar for a moment'));
    expect(text, contains('clicking it takes you back to the dashboard'));
  });

  testWidgets('M35: whole frames, wheel zoom, Combine writes on Save', (
    tester,
  ) async {
    await pumpHelp(tester);
    final text = pageText(tester);
    expect(text, contains('no cropping'));
    expect(text, contains('Wheel over the Edit preview'));
    expect(text, contains('mouse wheel over the Edit preview'));
    expect(text, contains('Only Save writes it'));
    expect(text, isNot(contains('and zoom.')));
  });

  testWidgets('M41: selection in both views, no confirm, a file name', (
    tester,
  ) async {
    await pumpHelp(tester);
    final text = pageText(tester);
    expect(text, contains('in either view'));
    expect(text, contains('opens in Edit straight away'));
    expect(text, contains('file name field'));
    expect(text, isNot(contains('It asks first')));
    expect(text, contains('Ctrl / Shift-click images'));
  });

  testWidgets('M43: frame sizes from gaps, borrowed sizes, false strips', (
    tester,
  ) async {
    await pumpHelp(tester);
    final text = pageText(tester);
    expect(text, contains("Frames don't have to be square"));
    expect(text, contains('the transparent gaps between frames decide'));
    expect(text, contains('borrows the frame size'));
    expect(text, contains('exactly the same size in its folder'));
    expect(text, contains('only if its frames look apart'));
    expect(text, contains('stays one image'));
    expect(text, isNot(contains('checked for strips whose')));
  });

  testWidgets('M44: Settings section explains resuming', (tester) async {
    await pumpHelp(tester);
    final text = pageText(tester);
    expect(find.text('Settings'), findsWidgets);
    expect(text, contains('Resume where I left off (on by default)'));
    expect(text, contains('the same pack tabs'));
    expect(text, contains('Packs no longer in the library'));
    expect(text, contains('Off: every start shows a clean dashboard'));
  });

  test('keys are described as printed on the keyboard', () {
    expect(AppKeys.dashboardSearch.keys, '/  or  Ctrl+F');
    expect(AppKeys.rescan.keys, 'F5  or  Ctrl+R');
    expect(AppKeys.settings.keys, 'Ctrl+,');
    expect(AppKeys.back.keys, 'Esc');
    expect(AppKeys.viewerNext.keys, '→');
    expect(AppKeys.playStop.keys, 'Space');
    expect(AppKeys.pinHeader.keys, 'H');
  });

  testWidgets('bindings accept exactly their keys', (tester) async {
    bool? seen;
    await tester.pumpWidget(
      MaterialApp(
        home: Focus(
          autofocus: true,
          onKeyEvent: (_, e) {
            if (e is KeyDownEvent) seen = AppKeys.closeTab.accepts(e);
            return KeyEventResult.ignored;
          },
          child: const SizedBox(),
        ),
      ),
    );
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyW);
    expect(seen, isFalse);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyW);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    expect(seen, isTrue);
  });

  testWidgets('M76: first-run choices and the itch.io tabs', (tester) async {
    await pumpHelp(tester);
    final text = pageText(tester);
    expect(text, contains('An empty library shows three ways to start'));
    expect(text, contains('Download from itch.io (Connect itch.io until'));
    expect(text, contains('counts your owned assets'));
    for (final tab in [
      'Missing:',
      'To link:',
      'Inside a pack:',
      'In library:',
    ]) {
      expect(text, contains(tab));
    }
    expect(text, contains('even when it is empty'));
    expect(text, contains('emptied on start'));
  });
}
