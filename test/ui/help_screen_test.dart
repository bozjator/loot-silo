import 'package:assets_explorer/core/animation_detector.dart';
import 'package:assets_explorer/ui/help_screen.dart';
import 'package:assets_explorer/ui/shortcuts.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  /// Every selectable paragraph on the page, joined.
  String pageText(WidgetTester tester) => [
    for (final e in find.byType(SelectableText).evaluate())
      (e.widget as SelectableText).data ?? '',
  ].join('\n');

  Future<void> pumpHelp(WidgetTester tester) async {
    // Tall enough that the whole list is built.
    await tester.binding.setSurfaceSize(const Size(1200, 12000));
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

  testWidgets('M35: whole frames, wheel zoom, Combine writes on Save', (
    tester,
  ) async {
    await pumpHelp(tester);
    final text = pageText(tester);
    expect(text, contains('no cropping'));
    expect(text, contains('Wheel over the Edit preview'));
    expect(text, contains('mouse wheel over the Edit preview'));
    expect(text, contains('Only Save writes <folder>_animation.png'));
    expect(text, isNot(contains('and zoom.')));
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
