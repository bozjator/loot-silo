import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loot_silo/state/providers.dart';
import 'package:loot_silo/ui/tabs.dart';

/// Never loads: tabs show their pack ids.
class _NoLibrary extends LibraryNotifier {
  @override
  Future<LibraryState> build() => Completer<LibraryState>().future;
}

void main() {
  late ProviderContainer container;

  Future<void> pumpStrip(WidgetTester tester, {double width = 600}) async {
    tester.view.physicalSize = Size(width, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    container = ProviderContainer(
      overrides: [libraryProvider.overrideWith(_NoLibrary.new)],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(body: Column(children: [PackTabStrip()])),
        ),
      ),
    );
  }

  TabsNotifier tabs() => container.read(tabsProvider.notifier);
  ScrollPosition position(WidgetTester tester) => tester
      .state<ScrollableState>(
        find.descendant(
          of: find.byKey(const ValueKey('strip-scroll')),
          matching: find.byType(Scrollable),
        ),
      )
      .position;
  Rect viewport(WidgetTester tester) =>
      tester.getRect(find.byKey(const ValueKey('strip-scroll')));
  bool fullyShown(WidgetTester tester, String label) {
    final r = tester.getRect(find.text(label));
    final v = viewport(tester);
    return r.left >= v.left - 0.5 && r.right <= v.right + 0.5;
  }

  testWidgets('few tabs: no arrows or list', (tester) async {
    await pumpStrip(tester, width: 1400);
    tabs()
      ..open('a')
      ..open('b');
    await tester.pumpAndSettle();
    expect(find.byTooltip('Scroll tabs left'), findsNothing);
    expect(find.byTooltip('Scroll tabs right'), findsNothing);
    expect(find.byTooltip('All tabs'), findsNothing);
  });

  testWidgets('many tabs scroll: arrows, wheel, list, reveal', (tester) async {
    await pumpStrip(tester);
    for (var i = 0; i < 12; i++) {
      tabs().open('pack $i');
    }
    await tester.pumpAndSettle();
    // The newest tab, opened behind the dashboard, scrolls into view; the
    // Dashboard tab stays put.
    expect(fullyShown(tester, 'pack 11'), isTrue);
    expect(find.text('Dashboard').hitTestable(), findsOneWidget);
    final left = find.byTooltip('Scroll tabs left');
    final right = find.byTooltip('Scroll tabs right');
    expect(left, findsOneWidget);
    expect(right, findsOneWidget);
    IconButton button(Finder f) => tester.widget<IconButton>(
      find.ancestor(of: f, matching: find.byType(IconButton)).first,
    );
    // The controls are as wide as the strip reckons (or the arrows would
    // flicker on and off near the fit).
    final controls =
        tester.getRect(find.byKey(const ValueKey('strip-all'))).right -
        tester
            .getRect(find.ancestor(of: left, matching: find.byType(IconButton)))
            .left -
        viewport(tester).width;
    expect(controls, closeTo(3 * 28, 0.5));
    expect(button(right).onPressed, isNull);
    expect(button(left).onPressed, isNotNull);

    // The left arrow pages back, all the way to the start.
    for (var i = 0; i < 20 && button(left).onPressed != null; i++) {
      await tester.tap(left);
      await tester.pumpAndSettle();
    }
    expect(position(tester).pixels, 0);
    expect(fullyShown(tester, 'pack 0'), isTrue);
    expect(button(right).onPressed, isNotNull);

    // A vertical wheel scrolls sideways.
    final at = tester.getCenter(find.byKey(const ValueKey('strip-scroll')));
    final mouse = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(mouse.hover(at));
    await tester.sendEventToBinding(mouse.scroll(const Offset(0, 120)));
    await tester.pump();
    expect(position(tester).pixels, 120);

    // Selecting a tab out of view scrolls to it.
    tabs().select(12);
    await tester.pumpAndSettle();
    expect(fullyShown(tester, 'pack 11'), isTrue);
    tabs().select(1);
    await tester.pumpAndSettle();
    expect(position(tester).pixels, 0);

    // The list shows every tab and jumps to the chosen one.
    await tester.tap(find.byTooltip('All tabs'));
    await tester.pumpAndSettle();
    final item = find.ancestor(
      of: find.text('pack 9').last,
      matching: find.byType(CheckedPopupMenuItem<int>),
    );
    expect(find.byType(CheckedPopupMenuItem<int>), findsNWidgets(12));
    await tester.tap(item);
    await tester.pumpAndSettle();
    expect(container.read(tabsProvider).active, 10);
    expect(fullyShown(tester, 'pack 9'), isTrue);

    // Closing tabs until they fit drops the arrows.
    for (var i = 0; i < 10; i++) {
      tabs().close(0);
    }
    await tester.pumpAndSettle();
    expect(left, findsNothing);
    expect(find.byTooltip('All tabs'), findsNothing);
  });
}
