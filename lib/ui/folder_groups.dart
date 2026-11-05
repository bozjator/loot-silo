import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../state/settings.dart';
import 'cursors.dart';
import 'format.dart';

/// Items (by index) that share a parent folder; `''` is the pack root.
typedef FolderGroup = ({String folder, List<int> items});

/// The folder [rel] is grouped under, keeping at most [depth] levels;
/// `''` for the pack root.
String folderOf(String rel, {int depth = 1 << 30}) {
  final dir = p.posix.dirname(rel);
  if (dir == '.') return '';
  final parts = p.posix.split(dir);
  return parts.length <= depth ? dir : p.posix.joinAll(parts.take(depth));
}

/// Groups [rels] by folder: the pack root first, then folders in path
/// order. Items keep their order within a group.
///
/// Uses the deepest folder level whose sections hold two or more items on
/// average, so `Knight/Attack/1.png`, `Knight/Idle/1.png`… make one
/// "Knight" section instead of one section per single-file sub-folder.
List<FolderGroup> groupByFolder(List<String> rels) {
  final deepest = rels.fold(0, (d, r) {
    final dir = p.posix.dirname(r);
    return dir == '.' ? d : math.max(d, p.posix.split(dir).length);
  });
  var groups = _group(rels, deepest);
  for (
    var depth = deepest - 1;
    depth >= 1 && groups.length * 2 > rels.length;
    depth--
  ) {
    groups = _group(rels, depth);
  }
  final folders = groups.keys.toList()
    ..sort((a, b) {
      if (a.isEmpty || b.isEmpty) return a.isEmpty ? -1 : 1;
      return a.toLowerCase().compareTo(b.toLowerCase());
    });
  return [for (final f in folders) (folder: f, items: groups[f]!)];
}

Map<String, List<int>> _group(List<String> rels, int depth) {
  final groups = <String, List<int>>{};
  for (var i = 0; i < rels.length; i++) {
    (groups[folderOf(rels[i], depth: depth)] ??= []).add(i);
  }
  return groups;
}

/// `Characters / Knight` for `characters/knight_v2`… each part prettified;
/// "Pack root" for files at the top.
String folderTitle(String folder) => folder.isEmpty
    ? 'Pack root'
    : p.posix
          .split(folder)
          .map((s) => prettyName(s, isFile: false))
          .join(' / ');

/// Item indices in the order they appear on screen: as given when flat,
/// group by group (skipping [collapsed] folders) when grouped.
List<int> visibleOrder(
  List<String> rels,
  ItemsView view,
  Set<String> collapsed,
) {
  if (view == ItemsView.flat) return [for (var i = 0; i < rels.length; i++) i];
  return [
    for (final g in groupByFolder(rels))
      if (!collapsed.contains(g.folder)) ...g.items,
  ];
}

/// Flat | By folder switch for a tab's toolbar.
class ItemsViewToggle extends StatelessWidget {
  const ItemsViewToggle({
    super.key,
    required this.view,
    required this.onChanged,
  });

  final ItemsView view;
  final ValueChanged<ItemsView> onChanged;

  @override
  Widget build(BuildContext context) => SegmentedButton<ItemsView>(
    showSelectedIcon: false,
    style: const ButtonStyle(visualDensity: VisualDensity.compact),
    segments: const [
      ButtonSegment(
        value: ItemsView.flat,
        icon: Icon(Icons.grid_view, size: 18),
        label: Text('Flat'),
      ),
      ButtonSegment(
        value: ItemsView.folders,
        icon: Icon(Icons.folder_outlined, size: 18),
        label: Text('By folder'),
      ),
    ],
    selected: {view},
    onSelectionChanged: (s) => onChanged(s.single),
  );
}

/// A grid of [rels], flat or as collapsible per-folder sections.
class GroupedGrid extends StatelessWidget {
  const GroupedGrid({
    super.key,
    required this.rels,
    required this.view,
    required this.collapsed,
    required this.onToggleFolder,
    required this.gridDelegate,
    required this.itemBuilder,
    this.physics,
    this.padding = const EdgeInsets.fromLTRB(16, 4, 16, 16),
    this.folderAction,
  });

  final List<String> rels;
  final ItemsView view;
  final Set<String> collapsed;
  final ValueChanged<String> onToggleFolder;
  final SliverGridDelegate gridDelegate;
  final Widget Function(BuildContext context, int index) itemBuilder;
  final ScrollPhysics? physics;
  final EdgeInsets padding;

  /// An extra control at the end of a folder header (By folder view), given
  /// the folder and its item indices; null for none.
  final Widget? Function(String folder, List<int> items)? folderAction;

  SliverGrid _grid(List<int> items) => SliverGrid(
    gridDelegate: gridDelegate,
    delegate: SliverChildBuilderDelegate(
      (context, i) => itemBuilder(context, items[i]),
      childCount: items.length,
    ),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final slivers = <Widget>[];
    if (view == ItemsView.flat) {
      slivers.add(_grid([for (var i = 0; i < rels.length; i++) i]));
    } else {
      for (final g in groupByFolder(rels)) {
        final open = !collapsed.contains(g.folder);
        slivers.add(
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.only(top: 8, bottom: 8),
              child: InkWell(
                mouseCursor: clickCursor,
                borderRadius: BorderRadius.circular(8),
                onTap: () => onToggleFolder(g.folder),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                    children: [
                      Icon(open ? Icons.expand_more : Icons.chevron_right),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Tooltip(
                          message: g.folder.isEmpty ? '' : g.folder,
                          child: Text(
                            folderTitle(g.folder),
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleSmall,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        formatCount(g.items.length),
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      if (folderAction?.call(g.folder, g.items)
                          case final action?) ...[
                        const SizedBox(width: 12),
                        action,
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
        if (open) slivers.add(_grid(g.items));
      }
    }
    return CustomScrollView(
      physics: physics,
      slivers: [
        SliverPadding(
          padding: padding,
          sliver: SliverMainAxisGroup(slivers: slivers),
        ),
      ],
    );
  }
}
