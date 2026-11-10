import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../core/audio_formats.dart' show formatOf;
import '../core/library_index.dart';
import '../core/material_sets.dart';
import '../core/pack_editor.dart';
import '../state/favorites.dart';
import '../state/folder_folds.dart';
import '../state/providers.dart';
import '../state/settings.dart';
import 'cursors.dart';
import 'double_click.dart';
import 'folder_groups.dart';
import 'material_viewer.dart';
import 'reveal.dart';
import 'shortcuts.dart';
import 'theme_colors.dart';
import 'widgets/format_chips.dart';
import 'widgets/file_menu.dart';
import 'widgets/item_card.dart';
import 'widgets/tab_toolbar.dart';
import 'widgets/thumb_size.dart';

/// A pack's PBR materials as cards, one per material: the preview the pack
/// ships (else the Color map tiled 2 × 2, so seams and scale show), the
/// name, resolution and map count. While hovered, map chips along the
/// bottom show one map in the card (the picture comes back on leave) and
/// tool chips (MaterialX, Godot, Blender…) show their file in the file
/// manager. Flat or By folder, star, focus and the size slider work as in
/// the Models tab; double-click opens the [MaterialViewer].
class MaterialsTab extends ConsumerStatefulWidget {
  const MaterialsTab({super.key, required this.pack, required this.contents});

  final PackRow pack;
  final PackContents contents;

  @override
  ConsumerState<MaterialsTab> createState() => _MaterialsTabState();
}

class _MaterialsTabState extends ConsumerState<MaterialsTab> {
  late final _collapsed = ref
      .read(folderFoldsProvider)
      .of(widget.pack.path, FoldTab.materials);

  void _saveFolds() => ref
      .read(folderFoldsProvider)
      .set(widget.pack.path, FoldTab.materials, _collapsed);

  /// Focus mode: the clicked card (by material key); the others dim.
  String? _focused;
  final _keys = FocusNode(debugLabel: 'materials');

  /// The map a hovered card shows, by material key; dropped on leave.
  final _picked = <String, String>{};

  List<MaterialSet> get _materials => widget.contents.materials;

  @override
  void dispose() {
    _keys.dispose();
    _scale.dispose();
    super.dispose();
  }

  /// The grid's slider stops (M79).
  final _scale = ThumbScale(materialThumbRange, spacing: 8);

  @override
  void didUpdateWidget(MaterialsTab old) {
    super.didUpdateWidget(old);
    if (!_materials.any((m) => m.key == _focused)) _focused = null;
  }

  void _focus(String? key) {
    setState(() => _focused = key);
    _keys.requestFocus();
  }

  List<String> _groupPaths(List<MaterialSet> sets) => [
    for (final m in sets) m.groupPath,
  ];

  /// Material keys in on-screen order.
  List<String> _shown() {
    final sets = _materials;
    return [
      for (final i in visibleOrder(
        _groupPaths(sets),
        ref.read(settingsProvider).materialsView,
        _collapsed,
      ))
        sets[i].key,
    ];
  }

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

  /// A second click on a card opens the viewer.
  final _clicks = DoubleClick<String>();

  /// A click focuses the card (or leaves it); a second one soon after opens
  /// the viewer (see the Models tab for why this isn't a double-tap
  /// recognizer).
  void _tapped(MaterialSet m) {
    if (_clicks.second(m.key)) {
      setState(() => _focused = m.key);
      _openViewer(m);
      return;
    }
    _focus(_focused == m.key ? null : m.key);
  }

  /// The material viewer, stepping through the materials in on-screen
  /// order.
  void _openViewer(MaterialSet m) {
    final byKey = {for (final x in _materials) x.key: x};
    final shown = [for (final k in _shown()) byKey[k]!];
    showMaterialViewer(
      context,
      packPath: widget.pack.path,
      materials: shown,
      index: math.max(0, shown.indexOf(m)),
      sizes: widget.contents.sizes,
    );
  }

  void _dropHiddenFocus() {
    if (_focused case final key? when !_shown().contains(key)) _focused = null;
  }

  @override
  Widget build(BuildContext context) {
    final sets = _materials;
    final rels = _groupPaths(sets);
    final pack = widget.pack;
    final favorites = ref.watch(
      favoritesProvider.select((f) => f.filesOf(pack.id)),
    );
    final size = materialThumbRange.clamp(
      ref.watch(settingsProvider.select((s) => s.materialThumbSize)),
    );
    final view = ref.watch(settingsProvider.select((s) => s.materialsView));
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
            ItemsViewToggle(view: view, onChanged: settings.setMaterialsView),
            const Spacer(),
            ThumbSizeSlider(
              width: detailControlWidth,
              range: materialThumbRange,
              value: size,
              scale: _scale,
              onChanged: settings.setMaterialThumbSize,
            ),
          ],
        ),
        Expanded(
          child: CtrlWheelResize(
            onSteps: (n) => settings.setMaterialThumbSize(_scale.step(size, n)),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => _focus(null),
              child: GroupedGrid(
                key: PageStorageKey('materials:${pack.id}'),
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
                  scale: _scale,
                  imageAspect: 1,
                  footer: (_) => itemCardFooter,
                  spacing: 8,
                ),
                itemBuilder: (context, i) => _card(sets[i], favorites),
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

  Widget _card(MaterialSet m, Set<String> favorites) {
    final pack = widget.pack;
    final count = m.maps.length;
    final details = [
      ?m.resolution,
      '$count ${count == 1 ? 'map' : 'maps'}',
    ].join(' · ');
    return FileMenuArea(
      target: () => FileMenuTarget(
        files: [for (final map in m.maps) p.join(pack.path, map.path)],
      ),
      child: ItemCard(
        key: ValueKey('material:${m.key}'),
        path: m.key,
        title: materialTitle(m.name),
        details: details,
        stagePadding: 0,
        stage: (hover) {
          // The picked map shows only while hovered.
          if (!hover) _picked.remove(m.key);
          final picked = hover ? _picked[m.key] : null;
          return Stack(
            fit: StackFit.expand,
            children: [
              MaterialPicture(packPath: pack.path, material: m, map: picked),
              if (hover && m.toolFiles.isNotEmpty)
                Positioned(
                  top: 6,
                  left: 6,
                  child: FormatChips(
                    files: m.toolFiles,
                    shown: '',
                    vertical: true,
                    pickSingle: true,
                    label: (f) =>
                        materialToolFormats[formatOf(f)] ??
                        formatOf(f).toUpperCase(),
                    tooltip: (f) => '${p.basename(f)}: show in file manager',
                    onPick: (f) =>
                        ref.read(revealProvider)(p.join(pack.path, f)),
                  ),
                ),
              if (hover)
                Positioned(
                  left: 6,
                  right: 6,
                  bottom: 6,
                  child: _MapChips(
                    material: m,
                    picked: picked,
                    onPick: (f) => setState(
                      () => f == picked
                          ? _picked.remove(m.key)
                          : _picked[m.key] = f,
                    ),
                  ),
                ),
            ],
          );
        },
        focused: _focused == m.key,
        dimmed: _focused != null && _focused != m.key,
        starred: favorites.contains(m.key),
        onToggleStar: () =>
            ref.read(favoritesProvider.notifier).toggleFile(pack.id, m.key),
        onTap: () => _tapped(m),
        actions: [
          CardIconButton(
            tooltip: 'Open in viewer',
            icon: Icons.open_in_full,
            onPressed: () => _openViewer(m),
          ),
          RevealButton(p.join(pack.path, m.preview ?? m.maps.first.path)),
        ],
      ),
    );
  }
}

/// A material's maps as chips in a row (wrapping on small cards); the
/// shown one highlighted, a second click on it brings the picture back.
class _MapChips extends StatelessWidget {
  const _MapChips({
    required this.material,
    required this.picked,
    required this.onPick,
  });

  final MaterialSet material;
  final String? picked;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final style = Theme.of(context).textTheme.labelSmall;
    return Wrap(
      spacing: 4,
      runSpacing: 4,
      children: [
        for (final map in material.maps)
          Tooltip(
            message: '${map.role.label}: ${p.basename(map.path)}',
            child: Material(
              key: ValueKey('map:${map.path}'),
              color: map.path == picked
                  ? scheme.primaryContainer
                  : scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(4),
              child: InkWell(
                mouseCursor: clickCursor,
                borderRadius: BorderRadius.circular(4),
                onTap: () => onPick(map.path),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 5,
                    vertical: 2,
                  ),
                  child: Text(
                    map.role.chip,
                    style: style?.copyWith(
                      color: map.path == picked
                          ? scheme.onPrimaryContainer
                          : scheme.onSurfaceVariant,
                      fontWeight: map.path == picked ? FontWeight.bold : null,
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// A material's picture: [map] when given, else the preview the pack
/// ships, else the Color map tiled 2 × 2, else the first map. Decoded at
/// the size shown (maps are often 1K–4K photos), smoothly filtered.
class MaterialPicture extends StatelessWidget {
  const MaterialPicture({
    super.key,
    required this.packPath,
    required this.material,
    this.map,
  });

  final String packPath;
  final MaterialSet material;
  final String? map;

  @override
  Widget build(BuildContext context) {
    final m = material;
    final tiled = map == null && m.preview == null && m.color != null;
    final rel = map ?? m.preview ?? m.color ?? m.maps.first.path;
    return ColoredBox(
      color: modelStageColor(Theme.of(context).colorScheme),
      child: LayoutBuilder(
        builder: (context, box) {
          final dpr = MediaQuery.devicePixelRatioOf(context);
          final side = math.max(box.maxWidth, box.maxHeight);
          final px = (side * dpr / (tiled ? 2 : 1)).ceil().clamp(16, 2048);
          final image = ResizeImage(
            FileImage(File(p.join(packPath, rel))),
            width: px,
            allowUpscaling: false,
          );
          Widget tile() => Image(
            key: ValueKey('material-picture:$rel'),
            image: image,
            fit: tiled ? BoxFit.cover : BoxFit.contain,
            filterQuality: FilterQuality.medium,
            gaplessPlayback: true,
            errorBuilder: (_, _, _) =>
                const Center(child: Icon(Icons.broken_image_outlined)),
          );
          if (!tiled) return tile();
          return Column(
            children: [
              for (var r = 0; r < 2; r++)
                Expanded(
                  child: Row(
                    children: [
                      for (var c = 0; c < 2; c++)
                        Expanded(child: SizedBox.expand(child: tile())),
                    ],
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}
