import 'package:flutter/widgets.dart';

/// Wrap every `Slider` in this: an `Overlay` of its own for the slider's
/// value indicator, in a semantics node of its own.
///
/// A Slider keeps its value indicator in the nearest Overlay at all times
/// (Flutter 3.47), with a semantics node whose parent is the slider's node.
/// Whenever the slider's own semantics are left out (the first frame of a
/// route, which is offstage; a faded-out or collapsed toolbar) that node
/// has no parent, and Windows rejects the semantics update ("Failed to
/// update ui::AXTree … will not be in the tree"), and every later one. In
/// an Overlay inside the slider's subtree, the indicator is left out with
/// it. The own node keeps the slider apart from other OverlayPortals, as
/// `OwnSemanticsNode` does.
///
/// Nothing is clipped, so the indicator still draws above the track.
class SliderOverlay extends StatelessWidget {
  const SliderOverlay({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    child: Overlay.wrap(clipBehavior: Clip.none, child: child),
  );
}
