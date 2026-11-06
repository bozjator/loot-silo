import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../core/animation_detector.dart';
import '../state/providers.dart';
import '../state/settings.dart';
import 'cursors.dart';
import 'folder_groups.dart';
import 'format.dart';
import 'image_viewer.dart';
import 'reveal.dart';
import 'widgets/animated_sprite.dart';
import 'widgets/pixel_image.dart';
import 'widgets/thumb_size.dart';
import 'shortcuts.dart';

/// Animations as a grid of small cards that play all at once or only while
/// hovered ([AnimateMode]). Clicking a card focuses it: it plays, the others
/// dim and pause. Click it again, click empty space or press Esc to clear;
/// ←/→ move the focus. Fps, frame size and row are edited in a dialog; the
/// open icon shows the sheet in the image viewer.
class AnimationGrid extends ConsumerStatefulWidget {
  const AnimationGrid({
    super.key,
    required this.gridId,
    required this.packPath,
    required this.animations,
    required this.detected,
    required this.onEdit,
    this.sizes = const {},
  });

  /// Keys the scroll position; the pack id.
  final String gridId;
  final String packPath;

  /// With sidecar overrides applied; [detected] is the same list without.
  final List<SpriteAnim> animations;
  final List<SpriteAnim> detected;
  final ValueChanged<SpriteAnim> onEdit;

  /// File sizes for the image viewer's info line.
  final Map<String, int> sizes;

  @override
  ConsumerState<AnimationGrid> createState() => _AnimationGridState();
}

class _AnimationGridState extends ConsumerState<AnimationGrid> {
  final _keys = FocusNode(debugLabel: 'animations');
  int? _focused;

  /// Folders folded away in the "By folder" view, for this visit.
  final _collapsed = <String>{};

  @override
  void dispose() {
    _keys.dispose();
    super.dispose();
  }

  void _focus(int? i) {
    setState(() => _focused = i);
    _keys.requestFocus();
  }

  /// Esc and arrows act only while a card is focused; otherwise Esc goes on
  /// to the app and closes the page.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final focused = _focused;
    if (event is KeyUpEvent || focused == null) return KeyEventResult.ignored;
    // Arrows step through the cards in on-screen order.
    final order = visibleOrder(
      [for (final a in widget.animations) a.path],
      ref.read(settingsProvider).animationsView,
      _collapsed,
    );
    final at = order.indexOf(focused);
    if (AppKeys.leaveFocus.accepts(event)) {
      _focus(null);
    } else if (AppKeys.focusPrevious.accepts(event) && at >= 0) {
      _focus(order[math.max(0, at - 1)]);
    } else if (AppKeys.focusNext.accepts(event) && at >= 0) {
      _focus(order[math.min(order.length - 1, at + 1)]);
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final anims = widget.animations;
    final size = animationThumbRange.clamp(
      ref.watch(settingsProvider.select((s) => s.animationThumbSize)),
    );
    final view = ref.watch(settingsProvider.select((s) => s.animationsView));
    final mode = ref.watch(settingsProvider.select((s) => s.detailAnimateMode));
    final settings = ref.read(settingsProvider.notifier);
    final paths = [for (final a in anims) a.path];
    // The viewer steps through the animations in on-screen order.
    final order = visibleOrder(paths, view, _collapsed);
    return Focus(
      focusNode: _keys,
      onKeyEvent: _onKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
            child: Row(
              children: [
                ItemsViewToggle(
                  view: view,
                  onChanged: settings.setAnimationsView,
                ),
                const SizedBox(width: 12),
                AnimateModeToggle(
                  mode: mode,
                  onChanged: settings.setDetailAnimateMode,
                ),
                const Spacer(),
                ThumbSizeSlider(
                  width: detailControlWidth,
                  range: animationThumbRange,
                  value: size,
                  onChanged: settings.setAnimationThumbSize,
                ),
              ],
            ),
          ),
          Expanded(
            child: CtrlWheelResize(
              onSteps: (n) => settings.setAnimationThumbSize(
                animationThumbRange.nudge(size, n),
              ),
              // Taps that miss every card clear the focus.
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => _focus(null),
                child: GroupedGrid(
                  key: PageStorageKey('animations:${widget.gridId}'),
                  rels: [for (final a in anims) a.path],
                  view: view,
                  collapsed: _collapsed,
                  onToggleFolder: (f) => setState(() {
                    if (!_collapsed.remove(f)) _collapsed.add(f);
                    // A card folded out of sight can't stay focused.
                    final i = _focused;
                    if (i != null &&
                        !visibleOrder(paths, view, _collapsed).contains(i)) {
                      _focused = null;
                    }
                  }),
                  physics: const CtrlWheelPhysics(),
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                  // A square stage over a title and a details line.
                  gridDelegate: ThumbGridDelegate(
                    maxTileWidth: size,
                    imageAspect: 1,
                    footer: (_) => 64,
                  ),
                  // Only built (so only playing) while on screen.
                  itemBuilder: (context, i) => _AnimationTile(
                    key: ValueKey(anims[i].path),
                    packPath: widget.packPath,
                    anim: anims[i],
                    edited: anims[i] != widget.detected[i],
                    focused: _focused == i,
                    dimmed: _focused != null && _focused != i,
                    playAll: mode == AnimateMode.all,
                    onTap: () => _focus(_focused == i ? null : i),
                    onEdit: () => widget.onEdit(anims[i]),
                    onOpen: () => showImageViewer(
                      context,
                      packPath: widget.packPath,
                      images: [for (final j in order) paths[j]],
                      index: math.max(0, order.indexOf(i)),
                      sizes: widget.sizes,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// All | Hover: which animation cards play.
class AnimateModeToggle extends StatelessWidget {
  const AnimateModeToggle({
    super.key,
    required this.mode,
    required this.onChanged,
  });

  final AnimateMode mode;
  final ValueChanged<AnimateMode> onChanged;

  @override
  Widget build(BuildContext context) => SegmentedButton<AnimateMode>(
    showSelectedIcon: false,
    style: const ButtonStyle(visualDensity: VisualDensity.compact),
    segments: const [
      ButtonSegment(
        value: AnimateMode.all,
        icon: Icon(Icons.play_circle_outline, size: 18),
        label: Text('All'),
        tooltip: 'Play every animation',
      ),
      ButtonSegment(
        value: AnimateMode.hover,
        icon: Icon(Icons.mouse_outlined, size: 18),
        label: Text('Hover'),
        tooltip: 'Play only the animation under the mouse',
      ),
    ],
    selected: {mode},
    onSelectionChanged: (s) => onChanged(s.single),
  );
}

/// One animation in the grid. Plays when [focused], or when not [dimmed]
/// and either [playAll] or hovered. Its icons (edit, open, reveal) fade in
/// on hover; an edited animation keeps a dot in the stage corner.
class _AnimationTile extends StatefulWidget {
  const _AnimationTile({
    super.key,
    required this.packPath,
    required this.anim,
    required this.edited,
    required this.focused,
    required this.dimmed,
    required this.playAll,
    required this.onTap,
    required this.onEdit,
    required this.onOpen,
  });

  final String packPath;
  final SpriteAnim anim;

  /// Has a sidecar override.
  final bool edited;
  final bool focused;
  final bool dimmed;
  final bool playAll;
  final VoidCallback onTap;
  final VoidCallback onEdit;
  final VoidCallback onOpen;

  @override
  State<_AnimationTile> createState() => _AnimationTileState();
}

class _AnimationTileState extends State<_AnimationTile> {
  var _hover = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final a = widget.anim;
    final packPath = widget.packPath;
    final playing =
        widget.focused || !widget.dimmed && (widget.playAll || _hover);
    const duration = Duration(milliseconds: 200);
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AnimatedOpacity(
        duration: duration,
        opacity: widget.dimmed ? 0.35 : 1,
        child: AnimatedScale(
          duration: duration,
          scale: widget.focused ? 1.04 : 1,
          child: Card(
            clipBehavior: Clip.antiAlias,
            margin: EdgeInsets.zero,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: widget.focused
                  ? BorderSide(color: scheme.primary, width: 2)
                  : BorderSide.none,
            ),
            child: InkWell(
              mouseCursor: clickCursor,
              onTap: widget.onTap,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: ColoredBox(
                      color: scheme.surfaceContainerHighest,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          Padding(
                            padding: const EdgeInsets.all(8),
                            child: a.kind == AnimKind.gif
                                ? PixelImage(
                                    File(p.join(packPath, a.path)),
                                    animate: playing,
                                  )
                                : AnimatedSprite(
                                    packPath: packPath,
                                    anim: a,
                                    playing: playing,
                                  ),
                          ),
                          if (widget.edited)
                            Positioned(
                              top: 6,
                              right: 6,
                              child: Tooltip(
                                message: 'Edited',
                                child: Container(
                                  key: const ValueKey('edited-badge'),
                                  width: 8,
                                  height: 8,
                                  decoration: BoxDecoration(
                                    color: scheme.primary,
                                    shape: BoxShape.circle,
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  // The icons overlay the title only while hovered, so
                  // titles get the full width the rest of the time.
                  Stack(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(10, 4, 10, 6),
                        child: Tooltip(
                          message: a.path,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                prettyName(a.label, isFile: false),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.titleSmall,
                              ),
                              Text(
                                switch (a.kind) {
                                  AnimKind.sheet =>
                                    '${a.frameW}×${a.frameH} · '
                                        '${a.frameCount} frames · '
                                        '${a.fps.round()} fps',
                                  AnimKind.sequence =>
                                    '${a.frames.length} files · '
                                        '${a.fps.round()} fps',
                                  AnimKind.gif => 'GIF',
                                },
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      // Hidden (and not clickable) until hovered; clicks on
                      // the title focus the card.
                      Positioned(
                        top: 0,
                        right: 2,
                        bottom: 0,
                        child: IgnorePointer(
                          ignoring: !_hover,
                          child: AnimatedOpacity(
                            key: const ValueKey('card-icons'),
                            duration: const Duration(milliseconds: 150),
                            opacity: _hover ? 1 : 0,
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  colors: [
                                    scheme.surfaceContainerLow.withValues(
                                      alpha: 0,
                                    ),
                                    scheme.surfaceContainerLow,
                                  ],
                                  stops: const [0, 0.2],
                                ),
                              ),
                              child: Padding(
                                padding: const EdgeInsets.only(left: 16),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    if (a.kind != AnimKind.gif)
                                      IconButton(
                                        tooltip: widget.edited
                                            ? 'Edit animation (edited)'
                                            : 'Edit animation',
                                        iconSize: 18,
                                        visualDensity: VisualDensity.compact,
                                        color: widget.edited
                                            ? scheme.primary
                                            : null,
                                        icon: const Icon(Icons.tune),
                                        onPressed: widget.onEdit,
                                      ),
                                    OpenImageButton(onPressed: widget.onOpen),
                                    RevealButton(p.join(packPath, a.path)),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Opens an animation's sheet (or GIF, or first frame) in the image viewer.
class OpenImageButton extends StatelessWidget {
  const OpenImageButton({super.key, required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: 'Open image',
    iconSize: 18,
    visualDensity: VisualDensity.compact,
    icon: const Icon(Icons.open_in_full),
    onPressed: onPressed,
  );
}
