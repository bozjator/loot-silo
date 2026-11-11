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
      lessThan(tester.getTopLeft(find.text('Getting started')).dy),
    );
    expectLockup(tester);
  });

  testWidgets('M82: animation detection explained for users', (tester) async {
    await pumpHelp(tester);
    final text = pageText(tester);
    expect(find.text('Animations'), findsOneWidget);
    for (final heading in [
      'What makes an image an animation',
      'Why an image is not shown as an animation',
      'Why an image is shown as an animation by mistake',
      'Fixing it yourself',
      'Naming tips for your own files',
    ]) {
      expect(text, contains(heading));
    }
    expect(text, contains('hero (32x32).png'));
    expect(text, contains('walk_8f.png'));
    expect(text, contains('transparent gaps'));
    expect(text, contains('stays one image'));
    expect(text, contains('combine them into one'));
    expect(text, contains('"Make animation…"'));
    expect(text, contains('"Not an animation" asks first'));
    expect(text, contains('Only Save writes it'));
  });

  testWidgets('M82: Rescan library is explained', (tester) async {
    await pumpHelp(tester);
    final text = pageText(tester);
    expect(find.text('Rescan library'), findsOneWidget);
    expect(text, contains('(F5 or Ctrl+R)'));
    expect(text, contains('added, removed or renamed outside the app'));
    expect(text, contains('Nothing you set is lost'));
    expect(text, contains('a pack file edited by hand'));
  });

  testWidgets('M82: user help, no implementation details', (tester) async {
    await pumpHelp(tester);
    final text = pageText(tester);
    expect(text, contains('An empty library shows three'));
    expect(text, contains('Play all (Shift+Space)'));
    expect(text, contains(AppKeys.playAll.label));
    expect(text, contains('The Favorites chip (★ and a count)'));
    expect(text, contains('Resume where I left off (on by default)'));
    expect(text, contains('To link: packs you imported yourself'));
    for (final internal in [
      'px',
      'SHA-1',
      'used to stop',
      'emptied on start',
      'tooltip gives the cards per row',
      'rows are kept even',
      'is_container',
      '200,000',
    ]) {
      expect(text, isNot(contains(internal)), reason: internal);
    }
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
}
