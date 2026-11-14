import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../core/animation_gif.dart';
import '../core/animation_detector.dart';
import '../state/folder_folds.dart';
import '../state/providers.dart';
import '../state/settings.dart';
import 'card_focus.dart';
import 'double_click.dart';
import 'folder_groups.dart';
import 'format.dart';
import 'image_viewer.dart';
import 'reveal.dart';
import 'widgets/animated_sprite.dart';
import 'widgets/file_menu.dart';
import 'widgets/item_card.dart';
import 'widgets/pixel_image.dart';
import 'widgets/tab_toolbar.dart';
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
    this.favoriteFiles = const {},
    this.onToggleFavorite,
    this.previewFor,
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

  /// Starred files; each card has a star toggle when [onToggleFavorite]
  /// is set.
  final Set<String> favoriteFiles;
  final ValueChanged<String>? onToggleFavorite;

  /// The right-click menu's cover / previews target for an animation's
  /// file; none without it.
  final PreviewTarget Function(String rel)? previewFor;

  @override
  ConsumerState<AnimationGrid> createState() => _AnimationGridState();
}

class _AnimationGridState extends ConsumerState<AnimationGrid> {
  final _keys = FocusNode(debugLabel: 'animations');
  final _focusedCard = CardFocus<int>();
  int? get _focused => _focusedCard.value;

  /// The on-screen order, kept between clicks and key presses (M93).
  final _order = ShownOrder();

  List<SpriteAnim>? _pathsFrom;
  var _paths = const <String>[];

  /// The animations' paths, the same list until the animations change.
  List<String> get _pathList {
    if (!identical(widget.animations, _pathsFrom)) {
      _pathsFrom = widget.animations;
      _paths = [for (final a in widget.animations) a.path];
    }
    return _paths;
  }

  /// Folders folded away in the "By folder" view; remembered per pack.
  late final _collapsed = ref
      .read(folderFoldsProvider)
      .of(widget.packPath, FoldTab.animations);

  void _saveFolds() => ref
      .read(folderFoldsProvider)
      .set(widget.packPath, FoldTab.animations, _collapsed);

  @override
  void dispose() {
    _keys.dispose();
    _scale.dispose();
    _focusedCard.dispose();
    super.dispose();
  }

  /// The grid's slider stops (M79).
  final _scale = ThumbScale(animationThumbRange);

  void _focus(int? i) {
    _focusedCard.value = i;
    _keys.requestFocus();
  }

  /// A second click on a card opens the image viewer.
  final _clicks = DoubleClick<int>();

  /// Esc and arrows act only while a card is focused; otherwise Esc goes on
  /// to the app and closes the page.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final focused = _focused;
    if (event is KeyUpEvent || focused == null) return KeyEventResult.ignored;
    // Arrows step through the cards in on-screen order.
    final order = _order.of(
      _pathList,
      ref.read(settingsProvider).animationsView,
      _collapsed,
    );
    final at = _order.indexOf(focused);
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
    final paths = _pathList;
    // The viewer steps through the animations in on-screen order.
    _order.of(paths, view, _collapsed);
    // The image viewer on card [i], stepping in on-screen order.
    void open(int i) => showImageViewer(
      context,
      packPath: widget.packPath,
      images: _order.shown,
      index: math.max(0, _order.indexOf(i)),
      sizes: widget.sizes,
      animations: {for (final a in anims) a.path: a},
    );
    return FocusBackHandler(
      focus: _focusedCard,
      onBack: () => _focus(null),
      child: Focus(
        focusNode: _keys,
        onKeyEvent: _onKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TabToolbar(
              children: [
                if (view == ItemsView.folders) ...[
                  FoldAllButton(
                    rels: paths,
                    collapsed: _collapsed,
                    onPressed: () => setState(() {
                      toggleAllFolders(paths, _collapsed);
                      _saveFolds();
                      // A card folded out of sight can't stay focused.
                      final i = _focused;
                      if (i != null) {
                        _order.of(paths, view, _collapsed);
                        if (_order.indexOf(i) < 0) _focusedCard.value = null;
                      }
                    }),
                  ),
                  const SizedBox(width: 4),
                ],
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
                  scale: _scale,
                  onChanged: settings.setAnimationThumbSize,
                ),
              ],
            ),
            Expanded(
              child: CtrlWheelResize(
                onSteps: (n) =>
                    settings.setAnimationThumbSize(_scale.step(size, n)),
                // Taps that miss every card clear the focus.
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => _focus(null),
                  child: GroupedGrid(
                    key: PageStorageKey('animations:${widget.gridId}'),
                    rels: paths,
                    groups: _order.groups(paths),
                    view: view,
                    collapsed: _collapsed,
                    onToggleFolder: (f) => setState(() {
                      if (!_collapsed.remove(f)) _collapsed.add(f);
                      _saveFolds();
                      // A card folded out of sight can't stay focused.
                      final i = _focused;
                      if (i != null) {
                        _order.of(paths, view, _collapsed);
                        if (_order.indexOf(i) < 0) _focusedCard.value = null;
                      }
                    }),
                    physics: const CtrlWheelPhysics(),
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                    // A square stage over a title and a details line.
                    gridDelegate: ThumbGridDelegate(
                      maxTileWidth: size,
                      scale: _scale,
                      imageAspect: 1,
                      footer: (_) => itemCardFooter,
                      mainAxisPadding: 24,
                    ),
                    // Only built (so only playing) while on screen.
                    itemBuilder: (context, i) => FocusedCard<int>(
                      focus: _focusedCard,
                      id: i,
                      builder: (context, focused, dimmed) => _AnimationTile(
                        key: ValueKey(anims[i].path),
                        packPath: widget.packPath,
                        anim: anims[i],
                        preview: widget.previewFor?.call(anims[i].path),
                        edited: anims[i] != widget.detected[i],
                        focused: focused,
                        dimmed: dimmed,
                        playAll: mode == AnimateMode.all,
                        onTap: () {
                          if (primaryPressed ||
                              HardwareKeyboard.instance.isShiftPressed) {
                            _clicks.reset();
                            _focus(_focused == i ? null : i);
                          } else if (_clicks.second(i)) {
                            // Focused, without taking the keyboard from
                            // the viewer.
                            _focusedCard.value = i;
                            open(i);
                          } else {
                            _focus(_focused == i ? null : i);
                          }
                        },
                        onEdit: () => widget.onEdit(anims[i]),
                        starred: widget.favoriteFiles.contains(anims[i].path),
                        onToggleStar: widget.onToggleFavorite == null
                            ? null
                            : () => widget.onToggleFavorite!(anims[i].path),
                        onOpen: () => open(i),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
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

/// One animation in the grid ([ItemCard]). Plays when [focused], or when
/// not [dimmed] and either [playAll] or hovered. Its icons (edit, open,
/// reveal) fade in on hover; an edited animation keeps a dot in the stage's
/// top-left corner.
class _AnimationTile extends StatelessWidget {
  const _AnimationTile({
    super.key,
    required this.packPath,
    required this.anim,
    this.preview,
    required this.edited,
    required this.focused,
    required this.dimmed,
    required this.playAll,
    required this.onTap,
    required this.onEdit,
    required this.onOpen,
    this.starred = false,
    this.onToggleStar,
  });

  final String packPath;
  final SpriteAnim anim;
  final PreviewTarget? preview;

  /// The favorites star in the stage's top-right corner: shown on hover,
  /// always when [starred]; none without [onToggleStar].
  final bool starred;
  final VoidCallback? onToggleStar;

  /// Has a sidecar override.
  final bool edited;
  final bool focused;
  final bool dimmed;
  final bool playAll;
  final VoidCallback onTap;
  final VoidCallback onEdit;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final a = anim;
    final file = p.join(packPath, a.path);
    // An animation is one image file: the menu copies and opens that.
    return FileMenuArea(
      target: () => FileMenuTarget(
        files: [file],
        image: file,
        open: file,
        gif: (name: a.label, make: () => makeAnimationGif(packPath, a)),
        preview: preview,
      ),
      child: ItemCard(
        path: a.path,
        focused: focused,
        dimmed: dimmed,
        onTap: onTap,
        starred: starred,
        onToggleStar: onToggleStar,
        title: prettyName(a.label, isFile: false),
        details: switch (a.kind) {
          AnimKind.sheet =>
            '${a.frameW}×${a.frameH} · ${a.frameCount} frames · '
                '${a.fps.round()} fps',
          AnimKind.gif => 'GIF',
        },
        stage: (hover) {
          final playing = focused || !dimmed && (playAll || hover);
          return a.kind == AnimKind.gif
              ? PixelImage(File(p.join(packPath, a.path)), animate: playing)
              : AnimatedSprite(packPath: packPath, anim: a, playing: playing);
        },
        badge: edited
            ? Tooltip(
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
              )
            : null,
        actions: [
          if (a.kind != AnimKind.gif)
            CardIconButton(
              tooltip: edited ? 'Edit animation (edited)' : 'Edit animation',
              color: edited ? scheme.primary : null,
              icon: Icons.tune,
              onPressed: onEdit,
            ),
          OpenImageButton(onPressed: onOpen),
          RevealButton(file),
        ],
      ),
    );
  }
}

/// Opens an animation's sheet (or GIF, or first frame) in the image viewer.
class OpenImageButton extends StatelessWidget {
  const OpenImageButton({super.key, required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => CardIconButton(
    tooltip: 'Open image',
    icon: Icons.open_in_full,
    onPressed: onPressed,
  );
}
