import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../state/dashboard.dart';
import '../state/folder_tree.dart';
import '../state/providers.dart';
import '../state/settings.dart';
import 'cursors.dart';
import 'double_click.dart';
import 'format.dart';
import 'reveal.dart';

/// The dashboard's folder tree (M98): the library's folders down into packs
/// and their folders, with counts that follow the search and filters. One
/// click selects a node (every view then keeps what is under it), the
/// chevron or a double-click folds it; the keyboard moves with the arrows.
class FolderTreePanel extends ConsumerStatefulWidget {
  const FolderTreePanel({
    super.key,
    required this.onOpenPack,
    this.onSelected,
    this.onLeave,
  });

  /// "Open pack" / "Open in new tab" from a node's menu: the pack, the
  /// first-level folder to start at, and whether in a new tab.
  final void Function(String packId, String? folder, bool newTab) onOpenPack;

  /// After a node was selected or cleared (the overlay closes on it).
  final VoidCallback? onSelected;

  /// Esc: the focus goes back to the grid.
  final VoidCallback? onLeave;

  /// Every row is this tall, so the keyboard can scroll by index.
  static const rowHeight = 30.0;

  @override
  ConsumerState<FolderTreePanel> createState() => _FolderTreePanelState();
}

class _FolderTreePanelState extends ConsumerState<FolderTreePanel> {
  final _focus = FocusNode(debugLabel: 'folder tree');
  final _scroll = ScrollController();
  final _clicks = DoubleClick<String>();

  /// The keyboard's row, by path.
  String? _cursor;
  var _rows = const <TreeRow>[];

  @override
  void dispose() {
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  TreeExpanded get _expanded => ref.read(treeExpandedProvider.notifier);

  void _select(String path) {
    final q = ref.read(dashboardQueryProvider.notifier);
    final selecting = ref.read(dashboardQueryProvider).node != path;
    q.setNode(path);
    // Selecting a node opens it.
    if (selecting) _expanded.expand([path]);
    setState(() => _cursor = path);
    widget.onSelected?.call();
  }

  void _tap(TreeRow row) {
    _focus.requestFocus();
    if (_clicks.second(row.node.path)) {
      if (row.expandable) _expanded.toggle(row.node.path);
      return;
    }
    _select(row.node.path);
  }

  /// Scrolls the row at [i] into view.
  void _show(int i) {
    if (!_scroll.hasClients) return;
    final pos = _scroll.position;
    final top = i * FolderTreePanel.rowHeight;
    final bottom = top + FolderTreePanel.rowHeight;
    if (top < pos.pixels) {
      _scroll.jumpTo(top);
    } else if (bottom > pos.pixels + pos.viewportDimension) {
      _scroll.jumpTo(
        math.min(pos.maxScrollExtent, bottom - pos.viewportDimension),
      );
    }
  }

  void _moveTo(int i) {
    if (_rows.isEmpty) return;
    final at = i.clamp(0, _rows.length - 1);
    setState(() => _cursor = _rows[at].node.path);
    _show(at);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      widget.onLeave?.call();
      return KeyEventResult.handled;
    }
    if (_rows.isEmpty) return KeyEventResult.ignored;
    var at = _rows.indexWhere((r) => r.node.path == _cursor);
    if (at < 0) {
      if (key == LogicalKeyboardKey.arrowDown ||
          key == LogicalKeyboardKey.arrowUp) {
        _moveTo(0);
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    final row = _rows[at];
    if (key == LogicalKeyboardKey.arrowDown) {
      _moveTo(at + 1);
    } else if (key == LogicalKeyboardKey.arrowUp) {
      _moveTo(at - 1);
    } else if (key == LogicalKeyboardKey.arrowRight) {
      if (row.expandable && !row.expanded) {
        _expanded.expand([row.node.path]);
      } else if (row.expanded &&
          at + 1 < _rows.length &&
          _rows[at + 1].depth > row.depth) {
        _moveTo(at + 1);
      }
    } else if (key == LogicalKeyboardKey.arrowLeft) {
      if (row.expanded) {
        _expanded.collapse([row.node.path]);
      } else {
        while (at > 0 && _rows[at].depth >= row.depth) {
          at--;
        }
        if (_rows[at].depth < row.depth) _moveTo(at);
      }
    } else if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter ||
        key == LogicalKeyboardKey.space) {
      _select(row.node.path);
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  /// Every path at or below [node] in the tree as far as it is known
  /// (packs' folders once loaded).
  Iterable<String> _below(TreeNode node) sync* {
    yield node.path;
    final kids = node.kind == TreeKind.pack
        ? ref.read(packFoldersProvider(node.packId!)).value ?? const []
        : node.children;
    for (final k in kids) {
      yield* _below(k);
    }
  }

  Future<void> _menu(TreeRow row, Offset at) async {
    final node = row.node;
    final root = ref.read(libraryProvider).value?.root;
    final packId = node.packId;
    final choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(at.dx, at.dy, at.dx, at.dy),
      items: [
        if (packId != null) ...[
          const PopupMenuItem(
            value: 'open',
            child: ListTile(
              dense: true,
              leading: Icon(Icons.open_in_browser),
              title: Text('Open pack'),
            ),
          ),
          const PopupMenuItem(
            value: 'tab',
            child: ListTile(
              dense: true,
              leading: Icon(Icons.tab_outlined),
              title: Text('Open in new tab'),
            ),
          ),
        ],
        if (root != null)
          const PopupMenuItem(
            value: 'reveal',
            child: ListTile(
              dense: true,
              leading: Icon(Icons.folder_open_outlined),
              title: Text('Show in file manager'),
            ),
          ),
        const PopupMenuItem(
          value: 'expand',
          child: ListTile(
            dense: true,
            leading: Icon(Icons.unfold_more),
            title: Text('Expand all below'),
          ),
        ),
        const PopupMenuItem(
          value: 'collapse',
          child: ListTile(
            dense: true,
            leading: Icon(Icons.unfold_less),
            title: Text('Collapse all'),
          ),
        ),
      ],
    );
    if (!mounted) return;
    switch (choice) {
      case 'open' || 'tab':
        widget.onOpenPack(
          packId!,
          nodeFolderIn(packId, node.path),
          choice == 'tab',
        );
      case 'reveal':
        ref.read(revealProvider)(p.joinAll([root!, ...node.path.split('/')]));
      case 'expand':
        // Packs' folders load on expand; one level more each time.
        _expanded.expand(_below(node));
      case 'collapse':
        _expanded.set(const {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final roots = ref.watch(libraryTreeProvider);
    final expanded = ref.watch(treeExpandedProvider);
    final withFolders =
        ref.watch(packsWithFoldersProvider).value ?? const <String>{};
    final packs = ref.watch(libraryProvider).value?.packs ?? const [];
    final packIds = {
      for (final pk in packs)
        if (!pk.isBundle) pk.id,
    };
    // The folders of every expanded pack, loaded on first expand.
    final packFolders = <String, List<TreeNode>>{
      for (final e in expanded)
        if (packIds.contains(e)) e: ?ref.watch(packFoldersProvider(e)).value,
    };
    final counts = ref.watch(treeCountsProvider);
    final selected = ref.watch(dashboardQueryProvider.select((q) => q.node));
    final rows = _rows = visibleRows(
      roots,
      expanded,
      packFolders,
      withFolders.contains,
    );
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dim = scheme.onSurfaceVariant.withValues(alpha: 0.5);
    // Styles worked out once, not per row.
    final label = theme.textTheme.bodyMedium;
    final labelDim = label?.copyWith(color: dim);
    final countStyle = theme.textTheme.labelSmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    final countDim = theme.textTheme.labelSmall?.copyWith(color: dim);
    final selectedBox = BoxDecoration(color: scheme.secondaryContainer);
    final cursorBox = BoxDecoration(
      border: Border.all(color: scheme.primary),
      borderRadius: BorderRadius.circular(4),
    );
    final cursorSelectedBox = cursorBox.copyWith(
      color: scheme.secondaryContainer,
    );
    return Focus(
      focusNode: _focus,
      onKeyEvent: _onKey,
      child: ListenableBuilder(
        listenable: _focus,
        builder: (context, _) => ListView.builder(
          key: const ValueKey('folder-tree'),
          controller: _scroll,
          itemExtent: FolderTreePanel.rowHeight,
          padding: const EdgeInsets.symmetric(vertical: 4),
          itemCount: rows.length,
          itemBuilder: (context, i) {
            final row = rows[i];
            final n = row.node;
            final count = counts.of(n);
            final isSelected = n.path == selected;
            final isCursor = _focus.hasFocus && n.path == _cursor;
            final empty = count == 0;
            Widget tile = InkWell(
              key: ValueKey('tree:${n.path}'),
              mouseCursor: clickCursor,
              onTap: () => _tap(row),
              onSecondaryTapUp: (d) => _menu(row, d.globalPosition),
              child: Padding(
                padding: EdgeInsets.only(left: 4.0 + row.depth * 16),
                child: Row(
                  children: [
                    SizedBox.square(
                      dimension: 24,
                      child: row.expandable
                          ? _Chevron(
                              key: ValueKey('tree-fold:${n.path}'),
                              expanded: row.expanded,
                              onTap: () => _expanded.toggle(n.path),
                            )
                          : null,
                    ),
                    const SizedBox(width: 2),
                    Icon(
                      switch (n.kind) {
                        TreeKind.folder => Icons.folder_outlined,
                        TreeKind.bundle => Icons.inventory_2_outlined,
                        TreeKind.section => Icons.folder_special_outlined,
                        TreeKind.pack => Icons.widgets_outlined,
                        TreeKind.packFolder => Icons.folder_outlined,
                      },
                      size: 18,
                      color: empty ? dim : scheme.primary,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        n.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: empty ? labelDim : label,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      formatCount(count),
                      style: empty ? countDim : countStyle,
                    ),
                    const SizedBox(width: 8),
                  ],
                ),
              ),
            );
            if (isSelected || isCursor) {
              tile = DecoratedBox(
                decoration: isCursor
                    ? (isSelected ? cursorSelectedBox : cursorBox)
                    : selectedBox,
                position: isCursor
                    ? DecorationPosition.foreground
                    : DecorationPosition.background,
                child: tile,
              );
            }
            return Tooltip(
              message: n.path,
              waitDuration: const Duration(milliseconds: 700),
              child: tile,
            );
          },
        ),
      ),
    );
  }
}

/// A row's expand / collapse arrow: an icon with a tap handler, lighter than
/// an [IconButton] (no tooltip, ink or focus of its own) since every visible
/// row has one.
class _Chevron extends StatelessWidget {
  const _Chevron({super.key, required this.expanded, required this.onTap});

  final bool expanded;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: expanded ? 'Collapse' : 'Expand',
    child: MouseRegion(
      cursor: clickCursor,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Icon(
          expanded ? Icons.expand_more : Icons.chevron_right,
          size: 18,
        ),
      ),
    ),
  );
}

/// The folder tree beside the dashboard grid: the panel with a draggable
/// divider on its right edge. The width is saved when a drag ends.
class FolderTreeSide extends ConsumerStatefulWidget {
  const FolderTreeSide({
    super.key,
    required this.panel,
    required this.maxWidth,
  });

  final Widget panel;

  /// 40 % of the window.
  final double maxWidth;

  @override
  ConsumerState<FolderTreeSide> createState() => _FolderTreeSideState();
}

class _FolderTreeSideState extends ConsumerState<FolderTreeSide> {
  /// While dragging; null otherwise (the saved width shows).
  double? _dragging;

  @override
  Widget build(BuildContext context) {
    final saved = ref.watch(
      settingsProvider.select((s) => s.dashboardTreeWidth),
    );
    final max = math.max(AppSettings.minTreeWidth, widget.maxWidth);
    final width = (_dragging ?? saved).clamp(AppSettings.minTreeWidth, max);
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: width + 6,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(width: width, child: widget.panel),
          MouseRegion(
            cursor: SystemMouseCursors.resizeColumn,
            child: GestureDetector(
              key: const ValueKey('folder-tree-divider'),
              behavior: HitTestBehavior.opaque,
              onHorizontalDragStart: (_) => setState(() => _dragging = width),
              onHorizontalDragUpdate: (d) => setState(
                () => _dragging = ((_dragging ?? width) + d.delta.dx).clamp(
                  AppSettings.minTreeWidth,
                  max,
                ),
              ),
              onHorizontalDragEnd: (_) {
                final w = _dragging;
                setState(() => _dragging = null);
                if (w != null) {
                  ref.read(settingsProvider.notifier).setDashboardTreeWidth(w);
                }
              },
              child: SizedBox(
                width: 6,
                child: Center(
                  child: VerticalDivider(
                    width: 1,
                    thickness: 1,
                    color: scheme.outlineVariant,
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
