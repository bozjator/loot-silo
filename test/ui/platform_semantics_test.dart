import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loot_silo/ui/widgets/own_semantics_node.dart';
import 'package:loot_silo/ui/widgets/slider_overlay.dart';

import '../helpers/platform_semantics.dart';

/// The check every widget test runs (test/flutter_test_config.dart): that
/// Windows would take each semantics update.
void main() {
  final binding = PlatformSemanticsBinding.instanceForTests;

  Widget app(Widget child) => MaterialApp(
    home: Scaffold(body: Center(child: child)),
  );

  Widget slider() => Slider(value: 0.5, onChanged: (_) {});

  /// The updates [child] sends, which Windows would reject; taken, so the
  /// tear-down check passes.
  Future<List<String>> rejectedFor(WidgetTester tester, Widget child) async {
    await tester.pumpWidget(app(child));
    await tester.pump();
    return binding.takeRejected();
  }

  testWidgets('a Slider whose semantics are left out is caught', (
    tester,
  ) async {
    // Its value indicator stays in the root Overlay, with no parent.
    final rejected = await rejectedFor(tester, Offstage(child: slider()));
    expect(rejected, isNotEmpty);
    expect(rejected.single, contains('Slider'));
  });

  testWidgets('SliderOverlay keeps the indicator with the slider', (
    tester,
  ) async {
    expect(
      await rejectedFor(
        tester,
        Offstage(child: SliderOverlay(child: slider())),
      ),
      isEmpty,
    );
  });

  // The audio list's rows: the name and the details line both have one.
  Widget row({bool own = false}) {
    Widget tip(String text) {
      final tooltip = Tooltip(message: text, child: Text(text));
      return own ? OwnSemanticsNode(child: tooltip) : tooltip;
    }

    return ListTile(title: tip('Name'), trailing: tip('Details'), onTap: () {});
  }

  testWidgets('two Tooltips in one node are caught before one shows', (
    tester,
  ) async {
    final rejected = await rejectedFor(tester, row());
    expect(rejected.single, contains('Two OverlayPortals share'));
  });

  testWidgets('and the platform rejects one when it shows', (tester) async {
    await rejectedFor(tester, row());
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    // A node keeps one portal's traversal parent; the other one's breaks.
    for (final text in ['Name', 'Details']) {
      await mouse.moveTo(tester.getCenter(find.text(text)));
      await tester.pump(const Duration(seconds: 2));
    }
    final rejected = binding.takeRejected();
    await mouse.removePointer();
    await tester.pump(const Duration(seconds: 2));
    binding.takeRejected();
    expect(rejected.join(), contains('no parent lists'));
  });

  testWidgets('Tooltips each in their own node are taken, also shown', (
    tester,
  ) async {
    expect(await rejectedFor(tester, row(own: true)), isEmpty);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    for (final text in ['Name', 'Details']) {
      await mouse.moveTo(tester.getCenter(find.text(text)));
      await tester.pump(const Duration(seconds: 2));
    }
    expect(find.text('Details'), findsNWidgets(2), reason: 'tooltip shown');
    await mouse.removePointer();
  });

  testWidgets('a Slider under a Tooltip, each in its own node, is taken', (
    tester,
  ) async {
    // The thumbnail size slider: two OverlayPortals.
    expect(
      await rejectedFor(
        tester,
        OwnSemanticsNode(
          child: Tooltip(
            message: 'Thumbnail size',
            child: SizedBox(width: 200, child: SliderOverlay(child: slider())),
          ),
        ),
      ),
      isEmpty,
    );
  });
}
