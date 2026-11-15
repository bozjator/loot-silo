import 'dart:isolate';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/itch_media.dart';
import '../core/library_index.dart';
import '../core/natural_order.dart';
import 'dashboard.dart';
import 'favorites.dart';
import 'providers.dart';

/// What a node of the dashboard's folder tree (M98) is.
enum TreeKind {
  /// A folder above packs (an author folder, a grouping folder).
  folder,

  /// A bundle of packs (M95).
  bundle,

  /// A folder inside a bundle that holds packs (`2D assets`).
  section,

  pack,

  /// A folder inside a pack.
  packFolder,
}

/// A node of the folder tree. [path] is library-relative (POSIX), so the
/// selected node is a path prefix that filters every dashboard view.
class TreeNode {
  TreeNode({
    required this.path,
    required this.label,
    required this.kind,
    this.packId,
    this.fileCount = 0,
    List<TreeNode>? children,
  }) : children = children ?? [];

  final String path;

  /// The folder name (`A / B` when merged), or the pack's title.
  final String label;
  final TreeKind kind;

  /// The pack this node is or is inside; null above packs (and for a
  /// bundle, which is not a pack of its own).
  final String? packId;

  /// Files under a pack folder (the whole subtree, `_itch` left out).
  final int fileCount;

  /// Above packs: built with the tree. A pack's folders come from
  /// [packFoldersProvider] on first expand.
  final List<TreeNode> children;
}

/// Whether [path] is [node] or inside it.
bool underNode(String path, String node) =>
    path == node || path.startsWith('$node/');

/// Whether a pack (or a tile, or a bundle) at [path] belongs in a view
/// filtered by [node]: it's under the node, or the node is inside it.
bool matchesNode(String path, String node) =>
    underNode(path, node) || node.startsWith('$path/');

/// The tree above packs, from the library's pack rows: folders, bundles,
/// sections and packs, sorted by name with folders first. No disk access.
List<TreeNode> buildLibraryTree(List<PackRow> packs) {
  final root = TreeNode(path: '', label: '', kind: TreeKind.folder);
  final byPath = <String, TreeNode>{'': root};
  final bundles = {
    for (final pk in packs)
      if (pk.isBundle) pk.id,
  };
  bool inBundle(String path) => bundles.any((b) => path.startsWith('$b/'));
  // Bundles and packs first, so a folder that is one is made as one.
  final rows = [...packs]
    ..sort((a, b) => a.id.split('/').length.compareTo(b.id.split('/').length));
  for (final pk in rows) {
    if (pk.id == '.' || pk.id.isEmpty) continue;
    final parts = pk.id.split('/');
    var parent = root;
    for (var i = 0; i < parts.length; i++) {
      final path = parts.sublist(0, i + 1).join('/');
      final last = i == parts.length - 1;
      var node = byPath[path];
      if (node == null) {
        node = last
            ? TreeNode(
                path: path,
                label: pk.title,
                kind: pk.isBundle ? TreeKind.bundle : TreeKind.pack,
                packId: pk.isBundle ? null : pk.id,
                fileCount: pk.fileCount,
              )
            : TreeNode(
                path: path,
                label: parts[i],
                kind: inBundle(path) ? TreeKind.section : TreeKind.folder,
              );
        byPath[path] = node;
        parent.children.add(node);
      }
      parent = node;
    }
  }
  void sort(TreeNode n) {
    n.children.sort(_byKindThenName);
    n.children.forEach(sort);
  }

  sort(root);
  return root.children;
}

int _byKindThenName(TreeNode a, TreeNode b) {
  final pa = a.kind == TreeKind.pack, pb = b.kind == TreeKind.pack;
  if (pa != pb) return pa ? 1 : -1;
  return naturalCompare(a.label.toLowerCase(), b.label.toLowerCase());
}

/// Folders the tree leaves out inside packs: `_`-prefixed ones (`_itch`,
/// `_organizational`, …).
bool _hiddenFolder(String name) => name.startsWith('_');

/// The folders of pack [packId] (at [packPath], library-relative) from its
/// files' relative paths, any depth, each with the number of files under
/// it. A folder holding only one folder and no files is merged with it as
/// `A / B`.
List<TreeNode> buildPackFolders(String packId, Iterable<String> relPaths) {
  final counts = <String, int>{};
  final kids = <String, Set<String>>{'': {}};
  final direct = <String, int>{};
  for (final rel in relPaths) {
    if (isItchMedia(rel)) continue;
    final parts = rel.split('/');
    if (parts.length < 2) continue;
    var hidden = false;
    for (var i = 0; i < parts.length - 1; i++) {
      if (_hiddenFolder(parts[i])) {
        hidden = true;
        break;
      }
    }
    if (hidden) continue;
    var parent = '';
    for (var i = 0; i < parts.length - 1; i++) {
      final dir = parts.sublist(0, i + 1).join('/');
      counts[dir] = (counts[dir] ?? 0) + 1;
      (kids[parent] ??= {}).add(dir);
      kids[dir] ??= {};
      parent = dir;
    }
    direct[parent] = (direct[parent] ?? 0) + 1;
  }
  List<TreeNode> build(String dir) {
    final out = <TreeNode>[];
    for (final child in kids[dir] ?? const <String>{}) {
      var path = child;
      var label = child.substring(dir.isEmpty ? 0 : dir.length + 1);
      // One folder and no files of its own: show them as one row.
      while ((kids[path]?.length ?? 0) == 1 && (direct[path] ?? 0) == 0) {
        final only = kids[path]!.single;
        label = '$label / ${only.substring(path.length + 1)}';
        path = only;
      }
      out.add(
        TreeNode(
          path: '$packId/$path',
          label: label,
          kind: TreeKind.packFolder,
          packId: packId,
          fileCount: counts[child] ?? 0,
          children: build(path),
        ),
      );
    }
    return out..sort(_byKindThenName);
  }

  return build('');
}

/// The counts the tree shows, following every filter but the node itself:
/// above packs the packs under a node (a bundle's packs count, the bundle
/// doesn't), at and inside a pack its files; null where the pack is
/// filtered out (shown as 0, greyed).
class TreeCounts {
  const TreeCounts(this.packs, this.passing);

  /// Packs under each node above packs, by path.
  final Map<String, int> packs;

  /// Ids of the packs the filters let through.
  final Set<String> passing;

  int of(TreeNode n) => switch (n.kind) {
    TreeKind.pack ||
    TreeKind.packFolder => passing.contains(n.packId) ? n.fileCount : 0,
    _ => packs[n.path] ?? 0,
  };

  /// Counts for [all] packs under [q] (its node ignored) and the search
  /// [hits] (null without search text).
  factory TreeCounts.of(
    List<PackRow> all,
    DashboardQuery q,
    List<String>? hits, {
    Favorites favorites = Favorites.none,
  }) {
    final hitSet = hits?.toSet();
    final passing = <String>{};
    final packs = <String, int>{};
    for (final pk in all) {
      if (pk.isBundle) continue;
      if (hitSet != null && !hitSet.contains(pk.id)) continue;
      if (!passesFacets(pk, q, favorites: favorites)) continue;
      passing.add(pk.id);
      var at = pk.id.lastIndexOf('/');
      while (at > 0) {
        final dir = pk.id.substring(0, at);
        packs[dir] = (packs[dir] ?? 0) + 1;
        at = dir.lastIndexOf('/');
      }
    }
    return TreeCounts(packs, passing);
  }
}

/// One row of the tree as drawn: a node at a depth.
typedef TreeRow = ({TreeNode node, int depth, bool expandable, bool expanded});

/// The rows shown for [roots] with [expanded] open: a flat list, so the
/// panel builds only the rows on screen. A pack's children are
/// [packFolders]`[packId]` once loaded; [hasFolders] says whether a pack
/// not loaded yet gets an expander.
List<TreeRow> visibleRows(
  List<TreeNode> roots,
  Set<String> expanded,
  Map<String, List<TreeNode>> packFolders,
  bool Function(String packId) hasFolders,
) {
  final out = <TreeRow>[];
  void walk(List<TreeNode> nodes, int depth) {
    for (final n in nodes) {
      final kids = n.kind == TreeKind.pack ? packFolders[n.packId] : n.children;
      final expandable = n.kind == TreeKind.pack
          ? (kids == null ? hasFolders(n.packId!) : kids.isNotEmpty)
          : kids!.isNotEmpty;
      final open = expandable && expanded.contains(n.path);
      out.add((node: n, depth: depth, expandable: expandable, expanded: open));
      if (open && kids != null) walk(kids, depth + 1);
    }
  }

  walk(roots, 0);
  return out;
}

/// The tree's nodes above packs, rebuilt after every scan.
final libraryTreeProvider = Provider<List<TreeNode>>((ref) {
  final packs = ref.watch(libraryProvider).value?.packs ?? const [];
  return buildLibraryTree(packs);
});

/// Packs that have folders the tree shows (an expander), from the index.
final packsWithFoldersProvider = FutureProvider<Set<String>>((ref) async {
  await ref.watch(libraryProvider.future);
  return ref.read(libraryIndexProvider).packsWithFolders();
});

/// A pack's folders, read from the index on first expand and kept until
/// the next scan.
final packFoldersProvider = FutureProvider.family<List<TreeNode>, String>((
  ref,
  packId,
) async {
  await ref.watch(libraryProvider.future);
  final files = await ref.read(libraryIndexProvider).filesOf(packId);
  // A huge pack (50,000 files: ~70 ms) is sorted off the UI thread.
  if (files.length < 5000) return buildPackFolders(packId, files);
  return _packFoldersInBackground(packId, files);
});

Future<List<TreeNode>> _packFoldersInBackground(
  String packId,
  List<String> files,
) => Isolate.run(() => buildPackFolders(packId, files));

/// The tree's counts for the current filters (search, chips; not the node).
final treeCountsProvider = Provider<TreeCounts>((ref) {
  final packs = ref.watch(libraryProvider).value?.packs ?? const [];
  final q = ref.watch(dashboardQueryProvider);
  // While a new search runs, the last hits keep the counts steady.
  final hits = q.text.trim().isEmpty
      ? null
      : ref.watch(searchHitsProvider).value;
  return TreeCounts.of(packs, q, hits, favorites: ref.watch(favoritesProvider));
});

/// The tree's expanded nodes, by path; kept across rescans, saved in the
/// session.
final treeExpandedProvider = NotifierProvider<TreeExpanded, Set<String>>(
  TreeExpanded.new,
);

class TreeExpanded extends Notifier<Set<String>> {
  @override
  Set<String> build() => const {};

  void toggle(String path) => state = state.contains(path)
      ? ({...state}..remove(path))
      : {...state, path};

  void expand(Iterable<String> paths) => state = {...state, ...paths};

  void collapse(Iterable<String> paths) => state = {...state}..removeAll(paths);

  void set(Set<String> paths) => state = paths;
}

/// The node's path as the chip shows it: levels joined with ` › `, pack
/// names by title.
String nodeLabel(String node, List<PackRow> packs) {
  final titles = {for (final pk in packs) pk.id: pk.title};
  final parts = node.split('/');
  return [
    for (var i = 0; i < parts.length; i++)
      titles[parts.sublist(0, i + 1).join('/')] ?? parts[i],
  ].join(' › ');
}

/// [text] cut in the middle to [max] characters (`Kenney › … › Tanks`).
String middleEllipsis(String text, int max) {
  if (text.length <= max) return text;
  final keep = max - 1;
  final head = (keep / 2).ceil();
  return '${text.substring(0, head)}…'
      '${text.substring(text.length - (keep - head))}';
}

/// The first-level folder of pack [packId] that [node] is in, for opening
/// the pack there; null when the node isn't inside the pack.
String? nodeFolderIn(String packId, String? node) {
  if (node == null || !node.startsWith('$packId/')) return null;
  return node.substring(packId.length + 1).split('/').first;
}
