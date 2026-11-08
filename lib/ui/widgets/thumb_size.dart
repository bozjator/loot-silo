import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../cursors.dart';

/// Allowed thumbnail sizes, in logical pixels of tile width.
typedef SizeRange = ({double min, double max, double step});

const dashboardTileRange = (min: 140.0, max: 480.0, step: 20.0);
const imageThumbRange = (min: 80.0, max: 400.0, step: 20.0);
const animationThumbRange = (min: 120.0, max: 400.0, step: 20.0);

extension SizeRangeClamp on SizeRange {
  double clamp(double v) => v.clamp(min, max).toDouble();

  /// [v] moved by [steps] whole steps, kept in range.
  double nudge(double v, int steps) => clamp(v + steps * step);
}

/// A grid of cards that are an image area of fixed proportions plus a text
/// footer of fixed height, so labels never clip however wide tiles get.
///
/// Columns are counted like [SliverGridDelegateWithMaxCrossAxisExtent].
class ThumbGridDelegate extends SliverGridDelegate {
  const ThumbGridDelegate({
    required this.maxTileWidth,
    required this.imageAspect,
    required this.footer,
    this.spacing = 12,
  });

  final double maxTileWidth;

  /// Width / height of the image area.
  final double imageAspect;

  /// Footer height for a tile of the given width.
  final double Function(double tileWidth) footer;
  final double spacing;

  @override
  SliverGridLayout getLayout(SliverConstraints constraints) {
    final width = constraints.crossAxisExtent;
    final (count, tile) = thumbColumns(width, maxTileWidth, spacing);
    final height = tile / imageAspect + footer(tile);
    return SliverGridRegularTileLayout(
      crossAxisCount: count,
      mainAxisStride: height + spacing,
      crossAxisStride: tile + spacing,
      childMainAxisExtent: height,
      childCrossAxisExtent: tile,
      reverseCrossAxis: axisDirectionIsReversed(constraints.crossAxisDirection),
    );
  }

  @override
  bool shouldRelayout(ThumbGridDelegate old) =>
      old.maxTileWidth != maxTileWidth ||
      old.imageAspect != imageAspect ||
      old.spacing != spacing;
}

/// Column count and tile width for tiles at most [maxTileWidth] wide,
/// counted like [SliverGridDelegateWithMaxCrossAxisExtent].
(int, double) thumbColumns(double width, double maxTileWidth, double spacing) {
  final count = math.max(1, (width / (maxTileWidth + spacing)).ceil());
  return (count, math.max(0.0, (width - spacing * (count - 1)) / count));
}

/// A lazily built grid whose rows are as tall as their tallest tile, so
/// cards with short labels leave no empty footer. Columns are counted like
/// [ThumbGridDelegate].
class ThumbRows extends StatelessWidget {
  const ThumbRows({
    super.key,
    required this.maxTileWidth,
    required this.itemCount,
    required this.itemBuilder,
    this.spacing = 12,
    this.padding = EdgeInsets.zero,
    this.physics,
  });

  final double maxTileWidth;
  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;
  final double spacing;
  final EdgeInsets padding;
  final ScrollPhysics? physics;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final (count, tile) = thumbColumns(
        constraints.maxWidth - padding.horizontal,
        maxTileWidth,
        spacing,
      );
      final rows = (itemCount / count).ceil();
      return ListView.builder(
        physics: physics,
        padding: padding,
        itemCount: rows,
        itemBuilder: (context, r) => Padding(
          padding: EdgeInsets.only(top: r == 0 ? 0 : spacing),
          // Every tile in the row stretches to the tallest one.
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var c = 0; c < count; c++) ...[
                  if (c > 0) SizedBox(width: spacing),
                  SizedBox(
                    width: tile,
                    child: r * count + c < itemCount
                        ? itemBuilder(context, r * count + c)
                        : null,
                  ),
                ],
              ],
            ),
          ),
        ),
      );
    },
  );
}

/// Scrolls like its parent, except the mouse wheel is left alone while Ctrl
/// is held, so [CtrlWheelResize] can use it.
class CtrlWheelPhysics extends ScrollPhysics {
  const CtrlWheelPhysics({super.parent});

  @override
  CtrlWheelPhysics applyTo(ScrollPhysics? ancestor) =>
      CtrlWheelPhysics(parent: buildParent(ancestor));

  @override
  bool shouldAcceptUserOffset(ScrollMetrics position) =>
      !HardwareKeyboard.instance.isControlPressed &&
      super.shouldAcceptUserOffset(position);
}

/// Ctrl + mouse wheel over [child] calls [onSteps] with +1 (wheel up,
/// bigger) or -1. Pair the grid inside with [CtrlWheelPhysics].
class CtrlWheelResize extends StatelessWidget {
  const CtrlWheelResize({
    super.key,
    required this.onSteps,
    required this.child,
  });

  final ValueChanged<int> onSteps;
  final Widget child;

  @override
  Widget build(BuildContext context) => Listener(
    onPointerSignal: (event) {
      if (event is! PointerScrollEvent ||
          !HardwareKeyboard.instance.isControlPressed ||
          event.scrollDelta.dy == 0) {
        return;
      }
      GestureBinding.instance.pointerSignalResolver.register(
        event,
        (e) => onSteps((e as PointerScrollEvent).scrollDelta.dy < 0 ? 1 : -1),
      );
    },
    child: child,
  );
}

/// Columns for [n] cards when [wanted] are asked for, so the rows come out
/// as even as possible: `ceil(n / ceil(n / wanted))`. 8 cards, 5 wanted →
/// 4 (two rows of 4); 9 cards → 5 (5 + 4); 7 cards, 3 wanted → 3 (no even
/// split exists). Fewer cards than [wanted] get one column each.
int balancedColumns(int n, int wanted) {
  final c = math.max(1, wanted);
  if (n <= 0) return c;
  final rows = (n + c - 1) ~/ c;
  return (n + rows - 1) ~/ rows;
}

/// Width of the pack detail page's file search box, and of the thumbnail
/// slider in the tab toolbars right under it, so the two line up.
const detailControlWidth = 260.0;

/// Height of the pack detail toolbar's controls (search box, Favorites
/// chip), so they line up: a dense field's natural height.
const detailControlHeight = 36.0;

/// Corner radius of the pack detail toolbar's controls: the search box and
/// the Favorites chip next to it use this one value (a Material 3 chip's
/// own 8 px), so their corners match.
const detailControlRadius = BorderRadius.all(Radius.circular(8));

/// The chip density that paints a chip [detailControlHeight] tall.
///
/// A chip's outline isn't sized by the box around it: `RawChip` centres
/// its own `Material` (label + padding + density) inside whatever it is
/// given, so a compact chip in a 36 px `SizedBox` still paints 34 px, one
/// pixel short at the top and bottom. A chip is 38 px at the standard
/// density and each vertical step is 2 px, so −1 gives 36.
const detailChipDensity = VisualDensity(
  horizontal: -2,
  vertical: (detailControlHeight - 38) / 2,
);

/// Width of the compact slider's track (the dashboard's).
const compactSliderTrack = 140.0;

/// The default 2 px division dot, reported as 1 px wide. Flutter paints the
/// dots only when they are three reported widths apart: the dashboard's 17
/// steps on [compactSliderTrack] are about 5 px apart, so with the real
/// width they were left out, while the detail page's wider track showed
/// them.
class _DenseTickMarkShape extends RoundSliderTickMarkShape {
  const _DenseTickMarkShape();

  @override
  Size getPreferredSize({
    required SliderThemeData sliderTheme,
    required bool isEnabled,
  }) => const Size.square(1);
}

/// Compact thumbnail size slider for a toolbar. The small icon on the left
/// makes thumbnails one step smaller, the big one on the right one step
/// larger.
class ThumbSizeSlider extends StatelessWidget {
  const ThumbSizeSlider({
    super.key,
    required this.range,
    required this.value,
    required this.onChanged,
    this.width,
  });

  final SizeRange range;
  final double value;
  final ValueChanged<double> onChanged;

  /// The whole slider's width, icons included; a compact
  /// [compactSliderTrack] when null.
  final double? width;

  @override
  Widget build(BuildContext context) {
    final v = range.clamp(value);
    return SizedBox(
      width: width,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _EndButton(
            key: const ValueKey('thumb-smaller'),
            tooltip: 'Smaller',
            icon: Icons.photo_size_select_small,
            size: 18,
            onPressed: v > range.min
                ? () => onChanged(range.nudge(v, -1))
                : null,
          ),
          _track(
            Tooltip(
              message: 'Thumbnail size (Ctrl + mouse wheel)',
              child: SliderTheme(
                data: SliderTheme.of(context)
                    .copyWith(tickMarkShape: const _DenseTickMarkShape()),
                child: Slider(
                  mouseCursor: WidgetStateMouseCursor.clickable,
                  // The default side padding is the 24 px hover overlay's
                  // radius, which left the end icons far from the track.
                  // Enough for the thumb at either end is enough here.
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  min: range.min,
                  max: range.max,
                  divisions: ((range.max - range.min) / range.step).round(),
                  value: v,
                  label: '${value.round()} px',
                  onChanged: onChanged,
                ),
              ),
            ),
          ),
          _EndButton(
            key: const ValueKey('thumb-larger'),
            tooltip: 'Larger',
            icon: Icons.photo_size_select_large,
            size: 22,
            onPressed: v < range.max
                ? () => onChanged(range.nudge(v, 1))
                : null,
          ),
        ],
      ),
    );
  }

  Widget _track(Widget slider) => width == null
      ? SizedBox(width: compactSliderTrack, child: slider)
      : Expanded(child: slider);
}

/// One of the slider's end icons as a small button, no wider than the
/// icon plus a little room for its hover highlight.
class _EndButton extends StatelessWidget {
  const _EndButton({
    super.key,
    required this.tooltip,
    required this.icon,
    required this.size,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final double size;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: tooltip,
    onPressed: onPressed,
    mouseCursor: clickCursor,
    icon: Icon(icon, size: size),
    padding: const EdgeInsets.all(3),
    constraints: const BoxConstraints(),
    style: const ButtonStyle(tapTargetSize: MaterialTapTargetSize.shrinkWrap),
  );
}
