import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loot_silo/ui/help_screen.dart';
import 'package:loot_silo/ui/shortcuts.dart';
import 'package:loot_silo/ui/widgets/thumb_size.dart';

/// Shortcuts use Cmd on macOS and Ctrl elsewhere, and say so.
void main() {
  final platforms = TargetPlatformVariant({
    TargetPlatform.linux,
    TargetPlatform.macOS,
  });
  bool mac() => defaultTargetPlatform == TargetPlatform.macOS;
  LogicalKeyboardKey primary() =>
      mac() ? LogicalKeyboardKey.metaLeft : LogicalKeyboardKey.controlLeft;
  LogicalKeyboardKey other() =>
      mac() ? LogicalKeyboardKey.controlLeft : LogicalKeyboardKey.metaLeft;

  Future<void> chord(
    WidgetTester tester,
    LogicalKeyboardKey modifier,
    LogicalKeyboardKey key, {
    bool shift = false,
  }) async {
    await tester.sendKeyDownEvent(modifier);
    if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(key);
    if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(modifier);
  }

  testWidgets('shortcuts fire with the platform\'s modifier', (tester) async {
    final fired = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: CallbackShortcuts(
          bindings: {
            ...AppKeys.closeTab.bind(() => fired.add('close')),
            ...AppKeys.settings.bind(() => fired.add('settings')),
            ...AppKeys.nextTab.bind(() => fired.add('next')),
            ...AppKeys.previousTab.bind(() => fired.add('previous')),
          },
          child: const Focus(autofocus: true, child: SizedBox()),
        ),
      ),
    );
    await tester.pump();

    await chord(tester, other(), LogicalKeyboardKey.keyW);
    await chord(tester, other(), LogicalKeyboardKey.comma);
    expect(fired, isEmpty);

    await chord(tester, primary(), LogicalKeyboardKey.keyW);
    await chord(tester, primary(), LogicalKeyboardKey.comma);
    expect(fired, ['close', 'settings']);
    fired.clear();

    // Tabs switch with Ctrl on macOS too (as in Safari and Finder).
    await chord(tester, LogicalKeyboardKey.controlLeft, LogicalKeyboardKey.tab);
    await chord(
      tester,
      LogicalKeyboardKey.controlLeft,
      LogicalKeyboardKey.tab,
      shift: true,
    );
    expect(fired, ['next', 'previous']);
  }, variant: platforms);

  testWidgets('labels name the platform\'s modifier', (tester) async {
    final mod = mac() ? 'Cmd' : 'Ctrl';
    expect(primaryKey, mod);
    expect(AppKeys.closeTab.keys, '$mod+W');
    expect(AppKeys.settings.keys, '$mod+,');
    expect(AppKeys.rescan.keys, 'F5  or  $mod+R');
    expect(AppKeys.dashboardSearch.keys, '/  or  $mod+F');
    expect(AppKeys.nextTab.keys, 'Ctrl+Tab');
    expect(AppKeys.previousTab.keys, 'Ctrl+Shift+Tab');
    expect(
      mouseHelp.map((m) => m.gesture),
      contains('$mod + wheel over a grid'),
    );

    await tester.binding.setSurfaceSize(const Size(1200, 16000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const MaterialApp(home: HelpScreen()));
    await tester.pump();
    final text = [
      for (final e in find.byType(SelectableText).evaluate())
        (e.widget as SelectableText).data ?? '',
    ].join('\n');
    expect(text, contains('(F5 or $mod+R)'));
    expect(text, contains('($mod+I, $mod+O,'));
    expect(text, contains('$mod / Shift-click'));
    expect(text, contains('(or $mod + wheel)'));
    final other = mac() ? 'Ctrl' : 'Cmd';
    expect(text, isNot(contains('$other+R')));
  }, variant: platforms);

  testWidgets('the modifier + wheel resizes; the other one scrolls', (
    tester,
  ) async {
    final steps = <int>[];
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: CtrlWheelResize(
          onSteps: steps.add,
          child: GridView.builder(
            controller: controller,
            physics: const CtrlWheelPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 4,
            ),
            itemCount: 200,
            itemBuilder: (_, i) => Text('$i'),
          ),
        ),
      ),
    );
    final center = tester.getCenter(find.byType(GridView));
    Future<void> wheel(double dy) async {
      final pointer = TestPointer(1, PointerDeviceKind.mouse);
      pointer.hover(center);
      await tester.sendEventToBinding(pointer.scroll(Offset(0, dy)));
      await tester.pump();
    }

    await tester.sendKeyDownEvent(other());
    await wheel(100);
    await tester.sendKeyUpEvent(other());
    expect(steps, isEmpty);
    final offset = controller.offset;
    expect(offset, greaterThan(0));

    await tester.sendKeyDownEvent(primary());
    await wheel(-100);
    await wheel(100);
    await tester.sendKeyUpEvent(primary());
    expect(steps, [1, -1]);
    expect(controller.offset, offset);
  }, variant: platforms);
}
