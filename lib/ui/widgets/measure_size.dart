import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Calls [onSize] with [child]'s laid-out size whenever it changes, after
/// the frame (so the callback may set state).
class MeasureSize extends SingleChildRenderObjectWidget {
  const MeasureSize({super.key, required this.onSize, super.child});

  final ValueChanged<Size> onSize;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      RenderMeasureSize(onSize);

  @override
  void updateRenderObject(
    BuildContext context,
    RenderMeasureSize renderObject,
  ) => renderObject.onSize = onSize;
}

/// Reports its size to [MeasureSize.onSize].
class RenderMeasureSize extends RenderProxyBox {
  RenderMeasureSize(this.onSize);

  ValueChanged<Size> onSize;
  Size? _reported;

  @override
  void performLayout() {
    super.performLayout();
    final s = size;
    if (s == _reported) return;
    _reported = s;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (attached && _reported == s) onSize(s);
    });
  }
}
