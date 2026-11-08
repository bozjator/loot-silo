import 'dart:math' as math;

import 'package:flutter/gestures.dart' show kDoubleTapTimeout;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../core/audio_formats.dart' show formatOf;
import '../core/library_index.dart';
import '../core/model_formats.dart';
import '../core/model_mesh.dart';
import '../core/pack_editor.dart';
import '../state/favorites.dart';
import '../state/folder_folds.dart';
import '../state/providers.dart';
import '../state/settings.dart';
import 'folder_groups.dart';
import 'format.dart';
import 'model_stage.dart';
import 'model_viewer.dart';
import 'reveal.dart';
import 'shortcuts.dart';
import 'widgets/format_chips.dart';
import 'widgets/item_card.dart';
import 'widgets/tab_toolbar.dart';
import 'widgets/thumb_size.dart';

/// A pack's 3D models as cards, one per model whatever formats it comes
/// in: the model drawn from a three-quarter view (turning while hovered),
/// its name, triangle count and formats. Format chips (all of them while
/// hovered, else the drawn one) switch the drawn
/// file (GLB, glTF, OBJ) or show an unreadable one (FBX, DAE…) in the file
/// manager. Flat or By folder (format folders left out), star, focus and
/// the size slider work as in the Images tab.
class ModelsTab extends ConsumerStatefulWidget {
  const ModelsTab({super.key, required this.pack, required this.contents});

  final PackRow pack;
  final PackContents contents;

  @override
  ConsumerState<ModelsTab> createState() => _ModelsTabState();
}

class _ModelsTabState extends ConsumerState<ModelsTab> {
  /// Folders folded away in the "By folder" view; remembered per pack.
  late final _collapsed = ref
      .read(folderFoldsProvider)
      .of(widget.pack.path, FoldTab.models);

  void _saveFolds() => ref
      .read(folderFoldsProvider)
      .set(widget.pack.path, FoldTab.models, _collapsed);

  /// Focus mode: the clicked card (by model key); the others dim.
  String? _focused;
  final _keys = FocusNode(debugLabel: 'models');

  /// The format picked on a card, by model key.
  final _chosen = <String, String>{};

  /// Files whose read was asked for, so the footer gets the triangle
  /// count once it is known.
  final _asked = <String>{};

  List<String>? _groupedFrom;
  var _items = const <ModelItem>[];

  List<ModelItem> get _models {
    final models = widget.contents.models;
    if (!identical(models, _groupedFrom)) {
      _groupedFrom = models;
      _items = [
        for (final m in groupModelFormats(models))
          if (m.readable.isNotEmpty) m,
      ];
    }
    return _items;
  }

  @override
  void dispose() {
    _keys.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(ModelsTab old) {
    super.didUpdateWidget(old);
    if (!_models.any((m) => m.key == _focused)) _focused = null;
  }

  void _focus(String? key) {
    setState(() => _focused = key);
    _keys.requestFocus();
  }

  /// The file a card draws: the readable format picked on it, else the
  /// best readable one.
  String _fileOf(ModelItem m) {
    final chosen = _chosen[m.key];
    if (chosen != null && m.readable.contains(chosen)) return chosen;
    return m.shown!;
  }

  List<String> _groupPaths(List<ModelItem> models) => [
    for (final m in models) m.groupPath,
  ];

  /// Model keys in on-screen order.
  List<String> _shown() {
    final models = _models;
    return [
      for (final i in visibleOrder(
        _groupPaths(models),
        ref.read(settingsProvider).modelsView,
        _collapsed,
      ))
        models[i].key,
    ];
  }

  /// Esc and arrows act only while a card is focused; otherwise Esc goes on
  /// to the app and closes the page.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final focused = _focused;
    if (event is KeyUpEvent || focused == null) return KeyEventResult.ignored;
    final order = _shown();
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

  /// A readable chip draws that file; an unreadable one is shown in the
  /// file manager.
  void _pick(ModelItem m, String rel) {
    if (readableModelExts.contains(formatOf(rel))) {
      setState(() => _chosen[m.key] = rel);
    } else {
      ref.read(revealProvider)(p.join(widget.pack.path, rel));
    }
  }

  /// The last card click, to tell a double-click.
  (String, DateTime)? _lastTap;

  /// A click focuses the card (or leaves it); a second click on the same
  /// card soon after opens the viewer. Done here rather than with a
  /// double-tap recognizer, which would hold every single click (and the
  /// format chips) back until the double-click time had passed.
  void _tapped(ModelItem m) {
    final now = DateTime.now();
    final last = _lastTap;
    if (last != null &&
        last.$1 == m.key &&
        now.difference(last.$2) <= kDoubleTapTimeout) {
      _lastTap = null;
      // Focused, without taking the keyboard back from the viewer.
      setState(() => _focused = m.key);
      _openViewer(m);
      return;
    }
    _lastTap = (m.key, now);
    _focus(_focused == m.key ? null : m.key);
  }

  /// The viewer, stepping through the models in on-screen order.
  void _openViewer(ModelItem m) {
    final byKey = {for (final x in _models) x.key: x};
    final shown = [for (final k in _shown()) byKey[k]!];
    showModelViewer(
      context,
      packPath: widget.pack.path,
      items: shown,
      files: [for (final x in shown) _fileOf(x)],
      index: math.max(0, shown.indexOf(m)),
      sizes: widget.contents.sizes,
    );
  }

  void _dropHiddenFocus() {
    if (_focused case final key? when !_shown().contains(key)) _focused = null;
  }

  @override
  Widget build(BuildContext context) {
    final models = _models;
    final rels = _groupPaths(models);
    final pack = widget.pack;
    final favorites = ref.watch(
      favoritesProvider.select((f) => f.filesOf(pack.id)),
    );
    final size = modelThumbRange.clamp(
      ref.watch(settingsProvider.select((s) => s.modelThumbSize)),
    );
    final view = ref.watch(settingsProvider.select((s) => s.modelsView));
    final settings = ref.read(settingsProvider.notifier);
    final column = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TabToolbar(
          children: [
            if (view == ItemsView.folders) ...[
              FoldAllButton(
                rels: rels,
                collapsed: _collapsed,
                onPressed: () => setState(() {
                  toggleAllFolders(rels, _collapsed);
                  _saveFolds();
                  _dropHiddenFocus();
                }),
              ),
              const SizedBox(width: 4),
            ],
            ItemsViewToggle(view: view, onChanged: settings.setModelsView),
            const Spacer(),
            ThumbSizeSlider(
              width: detailControlWidth,
              range: modelThumbRange,
              value: size,
              onChanged: settings.setModelThumbSize,
            ),
          ],
        ),
        Expanded(
          child: CtrlWheelResize(
            onSteps: (n) =>
                settings.setModelThumbSize(modelThumbRange.nudge(size, n)),
            // Taps that miss every card clear the focus.
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => _focus(null),
              child: GroupedGrid(
                key: PageStorageKey('models:${pack.id}'),
                rels: rels,
                view: view,
                collapsed: _collapsed,
                onToggleFolder: (f) => setState(() {
                  if (!_collapsed.remove(f)) _collapsed.add(f);
                  _saveFolds();
                  _dropHiddenFocus();
                }),
                physics: const CtrlWheelPhysics(),
                gridDelegate: ThumbGridDelegate(
                  maxTileWidth: size,
                  imageAspect: 1,
                  footer: (_) => itemCardFooter,
                  spacing: 8,
                ),
                itemBuilder: (context, i) => _card(models[i], favorites),
              ),
            ),
          ),
        ),
      ],
    );
    return BackHandler(
      enabled: _focused != null,
      onBack: () => _focus(null),
      child: Focus(focusNode: _keys, onKeyEvent: _onKey, child: column),
    );
  }

  Widget _card(ModelItem m, Set<String> favorites) {
    final pack = widget.pack;
    final rel = _fileOf(m);
    final path = p.join(pack.path, rel);
    final cache = ref.read(modelCacheProvider);
    if (_asked.add(path)) {
      cache.load(path).then((_) {
        if (mounted) setState(() {});
      }, onError: (_) {});
    }
    final formats = [for (final f in m.files) formatOf(f).toUpperCase()];
    // The count first: narrow cards cut the end of the line.
    final details = [
      if (cache.peek(path) case final ModelMesh mesh)
        '${formatCount(mesh.triangleCount)} triangles',
      formats.join(', '),
    ].join(' · ');
    final starred = [
      for (final f in m.files)
        if (favorites.contains(f)) f,
    ];
    return ItemCard(
      key: ValueKey('model:${m.key}'),
      path: rel,
      title: prettyName(p.basename(rel)),
      details: details,
      stagePadding: 0,
      // Only the drawn format's chip until hovered, so a stack of five
      // doesn't cover small cards.
      stage: (hover) => Stack(
        fit: StackFit.expand,
        children: [
          ModelStage(path: path, turning: hover),
          if (m.files.length > 1)
            Positioned(
              top: 6,
              left: 6,
              child: FormatChips(
                files: hover ? m.files : [rel],
                shown: rel,
                vertical: true,
                onPick: (f) => _pick(m, f),
                tooltip: (f) => f == rel
                    ? p.basename(f)
                    : readableModelExts.contains(formatOf(f))
                    ? 'Draw ${p.basename(f)}'
                    : '${p.basename(f)}: not drawn; show in file manager',
              ),
            ),
        ],
      ),
      focused: _focused == m.key,
      dimmed: _focused != null && _focused != m.key,
      starred: starred.isNotEmpty,
      // Starring stars the shown file; unstarring unstars every format.
      onToggleStar: () {
        final favs = ref.read(favoritesProvider.notifier);
        for (final f in starred.isEmpty ? [rel] : starred) {
          favs.toggleFile(pack.id, f);
        }
      },
      onTap: () => _tapped(m),
      actions: [
        CardIconButton(
          tooltip: 'Open in viewer',
          icon: Icons.open_in_full,
          onPressed: () => _openViewer(m),
        ),
        RevealButton(path),
      ],
    );
  }
}
