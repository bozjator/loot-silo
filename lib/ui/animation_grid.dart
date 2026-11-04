import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../core/animation_detector.dart';
import '../state/providers.dart';
import 'cursors.dart';
import 'format.dart';
import 'reveal.dart';
import 'widgets/animated_sprite.dart';
import 'widgets/pixel_image.dart';
import 'widgets/thumb_size.dart';

/// Animations as a grid of small playing cards. Clicking a card focuses it:
/// the others dim and pause. Click it again, click empty space or press Esc
/// to clear; ←/→ move the focus. Fps, frame size and row are edited in a
/// dialog, as before.
class AnimationGrid extends ConsumerStatefulWidget {
  const AnimationGrid({
    super.key,
    required this.gridId,
    required this.packPath,
    required this.animations,
    required this.detected,
    required this.onEdit,
  });

  /// Keys the scroll position; the pack id.
  final String gridId;
  final String packPath;

  /// With sidecar overrides applied; [detected] is the same list without.
  final List<SpriteAnim> animations;
  final List<SpriteAnim> detected;
  final ValueChanged<SpriteAnim> onEdit;

  @override
  ConsumerState<AnimationGrid> createState() => _AnimationGridState();
}

class _AnimationGridState extends ConsumerState<AnimationGrid> {
  final _keys = FocusNode(debugLabel: 'animations');
  int? _focused;

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
    final last = widget.animations.length - 1;
    switch (event.logicalKey) {
      case LogicalKeyboardKey.escape:
        _focus(null);
      case LogicalKeyboardKey.arrowLeft:
        _focus(math.max(0, focused - 1));
      case LogicalKeyboardKey.arrowRight:
        _focus(math.min(last, focused + 1));
      default:
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
    final settings = ref.read(settingsProvider.notifier);
    return Focus(
      focusNode: _keys,
      onKeyEvent: _onKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
            child: Align(
              alignment: Alignment.centerRight,
              child: ThumbSizeSlider(
                range: animationThumbRange,
                value: size,
                onChanged: settings.setAnimationThumbSize,
              ),
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
                child: GridView.builder(
                  key: PageStorageKey('animations:${widget.gridId}'),
                  physics: const CtrlWheelPhysics(),
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                  // A square stage over a title and a details line.
                  gridDelegate: ThumbGridDelegate(
                    maxTileWidth: size,
                    imageAspect: 1,
                    footer: (_) => 64,
                  ),
                  itemCount: anims.length,
                  // Only built (so only playing) while on screen.
                  itemBuilder: (context, i) => _AnimationTile(
                    key: ValueKey(anims[i].path),
                    packPath: widget.packPath,
                    anim: anims[i],
                    edited: anims[i] != widget.detected[i],
                    focused: _focused == i,
                    dimmed: _focused != null && _focused != i,
                    onTap: () => _focus(_focused == i ? null : i),
                    onEdit: () => widget.onEdit(anims[i]),
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

/// One animation in the grid: plays unless [dimmed]; [focused] adds a
/// highlight border and a slight zoom.
class _AnimationTile extends StatelessWidget {
  const _AnimationTile({
    super.key,
    required this.packPath,
    required this.anim,
    required this.edited,
    required this.focused,
    required this.dimmed,
    required this.onTap,
    required this.onEdit,
  });

  final String packPath;
  final SpriteAnim anim;

  /// Has a sidecar override.
  final bool edited;
  final bool focused;
  final bool dimmed;
  final VoidCallback onTap;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final a = anim;
    const duration = Duration(milliseconds: 200);
    return AnimatedOpacity(
      duration: duration,
      opacity: dimmed ? 0.35 : 1,
      child: AnimatedScale(
        duration: duration,
        scale: focused ? 1.04 : 1,
        child: Card(
          clipBehavior: Clip.antiAlias,
          margin: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: focused
                ? BorderSide(color: scheme.primary, width: 2)
                : BorderSide.none,
          ),
          child: InkWell(
            mouseCursor: clickCursor,
            onTap: onTap,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: ColoredBox(
                    color: scheme.surfaceContainerHighest,
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: a.kind == AnimKind.gif
                          ? PixelImage(
                              File(p.join(packPath, a.path)),
                              animate: !dimmed,
                            )
                          : AnimatedSprite(
                              packPath: packPath,
                              anim: a,
                              playing: !dimmed,
                            ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(10, 4, 2, 6),
                  child: Row(
                    children: [
                      Expanded(
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
                                        '${a.cols}×${a.rows} · '
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
                      if (a.kind != AnimKind.gif)
                        IconButton(
                          tooltip: edited
                              ? 'Edit animation (edited)'
                              : 'Edit animation',
                          iconSize: 18,
                          visualDensity: VisualDensity.compact,
                          color: edited ? scheme.primary : null,
                          icon: const Icon(Icons.tune),
                          onPressed: onEdit,
                        ),
                      RevealButton(p.join(packPath, a.path)),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
