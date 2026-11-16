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

  /// The updates [child] sends, which Windows would reject; cleared, so
  /// the tear-down check passes.
  Future<List<String>> rejectedFor(WidgetTester tester, Widget child) async {
    await tester.pumpWidget(app(child));
    await tester.pump();
    final rejected = List.of(binding.rejected);
    binding.resetPlatformTree();
    return rejected;
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
