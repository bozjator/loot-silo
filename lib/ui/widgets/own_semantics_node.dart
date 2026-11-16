import 'package:flutter/widgets.dart';

/// Gives [child] its own semantics node. Wrap a widget that is an
/// `OverlayPortal` (Tooltip, MenuAnchor, Slider: its value indicator) when
/// another one would share its semantics node.
///
/// A portal marks the node its child merges into as the parent of its
/// overlay, and a node keeps only one such mark (Flutter 3.47). Two portals
/// under one node leave one overlay with no parent; Windows then rejects
/// the semantics update ("Failed to update ui::AXTree … will not be in the
/// tree"), and every later one, so a screen reader reads a stale app. The
/// widget tests check for this (`test/helpers/platform_semantics.dart`).
class OwnSemanticsNode extends StatelessWidget {
  const OwnSemanticsNode({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) =>
      Semantics(container: true, child: child);
}
