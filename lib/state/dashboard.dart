import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../core/library_index.dart';
import '../core/type_classifier.dart';
import '../ui/format.dart';
import 'providers.dart';
import 'settings.dart';

enum PackSort {
  relevance('Best match'),
  title('Name'),
  author('Author'),
  size('Size'),
  files('File count'),
  tags('Tags');

  const PackSort(this.label);
  final String label;
}

/// Source facet value for packs without a sidecar source.
const noSource = 'other';

/// Search text, facet filters, sort and the bundle being browsed.
class DashboardQuery {
  const DashboardQuery({
    this.text = '',
    this.types = const {},
    this.authors = const {},
    this.tags = const {},
    this.sources = const {},
    this.sort = PackSort.relevance,
    this.bundleId,
  });

  final String text;
  final Set<String> types;
  final Set<String> authors;
  final Set<String> tags;
  final Set<String> sources;
  final PackSort sort;

  /// When set, the grid shows this bundle's sub-packs.
  final String? bundleId;

  bool get hasFilters =>
      types.isNotEmpty ||
      authors.isNotEmpty ||
      tags.isNotEmpty ||
      sources.isNotEmpty;

  /// Searching or filtering shows every matching pack, sub-packs included.
  bool get isFlat => text.trim().isNotEmpty || hasFilters;

  DashboardQuery copyWith({
    String? text,
    Set<String>? types,
    Set<String>? authors,
    Set<String>? tags,
    Set<String>? sources,
    PackSort? sort,
    String? Function()? bundleId,
  }) => DashboardQuery(
    text: text ?? this.text,
    types: types ?? this.types,
    authors: authors ?? this.authors,
    tags: tags ?? this.tags,
    sources: sources ?? this.sources,
    sort: sort ?? this.sort,
    bundleId: bundleId != null ? bundleId() : this.bundleId,
  );
}

final dashboardQueryProvider =
    NotifierProvider<DashboardQueryNotifier, DashboardQuery>(
      DashboardQueryNotifier.new,
    );

class DashboardQueryNotifier extends Notifier<DashboardQuery> {
  @override
  DashboardQuery build() => const DashboardQuery();

  void setText(String text) => state = state.copyWith(text: text);
  void setSort(PackSort sort) => state = state.copyWith(sort: sort);
  void openBundle(String? id) => state = state.copyWith(bundleId: () => id);

  static Set<String> _toggle(Set<String> s, String v) =>
      s.contains(v) ? ({...s}..remove(v)) : {...s, v};

  void toggleType(String v) =>
      state = state.copyWith(types: _toggle(state.types, v));
  void toggleAuthor(String v) =>
      state = state.copyWith(authors: _toggle(state.authors, v));
  void toggleTag(String v) =>
      state = state.copyWith(tags: _toggle(state.tags, v));
  void toggleSource(String v) =>
      state = state.copyWith(sources: _toggle(state.sources, v));

  void clearFilters() => state = DashboardQuery(sort: state.sort);
}

/// FTS hits in rank order, or null when there is no search text.
final searchHitsProvider = FutureProvider<List<String>?>((ref) async {
  final text = ref.watch(dashboardQueryProvider.select((q) => q.text.trim()));
  // Re-run after rescans.
  await ref.watch(libraryProvider.future);
  if (text.isEmpty) return null;
  return ref.read(libraryIndexProvider).search(text);
});

/// Applies [q] to [packs]; pure so it can be unit tested.
List<PackRow> applyQuery(
  List<PackRow> packs,
  DashboardQuery q,
  List<String>? hits,
) {
  Iterable<PackRow> out;
  if (q.bundleId != null && !q.isFlat) {
    out = packs.where((p) => p.parentId == q.bundleId);
  } else if (q.isFlat) {
    out = packs;
    if (q.bundleId != null) {
      out = out.where((p) => p.parentId == q.bundleId);
    }
  } else {
    out = packs.where((p) => p.parentId == null);
  }
  if (hits != null) {
    final hitSet = hits.toSet();
    out = out.where((p) => hitSet.contains(p.id));
  }
  if (q.types.isNotEmpty) out = out.where((p) => p.types.any(q.types.contains));
  if (q.authors.isNotEmpty) {
    out = out.where((p) => q.authors.contains(p.author ?? ''));
  }
  if (q.tags.isNotEmpty) out = out.where((p) => p.tags.any(q.tags.contains));
  if (q.sources.isNotEmpty) {
    out = out.where((p) => q.sources.contains(p.source ?? noSource));
  }

  final list = out.toList();
  int byTitle(PackRow a, PackRow b) =>
      a.title.toLowerCase().compareTo(b.title.toLowerCase());
  switch (q.sort) {
    case PackSort.relevance when hits != null:
      final rank = {for (var i = 0; i < hits.length; i++) hits[i]: i};
      list.sort((a, b) => rank[a.id]!.compareTo(rank[b.id]!));
    case PackSort.relevance || PackSort.title:
      list.sort(byTitle);
    case PackSort.author:
      list.sort((a, b) {
        final c = (a.author ?? '￿').toLowerCase().compareTo(
          (b.author ?? '￿').toLowerCase(),
        );
        return c != 0 ? c : byTitle(a, b);
      });
    case PackSort.size:
      list.sort((a, b) => b.totalBytes.compareTo(a.totalBytes));
    case PackSort.files:
      list.sort((a, b) => b.fileCount.compareTo(a.fileCount));
    case PackSort.tags:
      final keys = {for (final p in list) p.id: tagSortKey(p.tags)};
      list.sort((a, b) {
        final ka = keys[a.id], kb = keys[b.id];
        if (ka == null || kb == null) {
          if (ka != kb) return ka == null ? 1 : -1;
          return byTitle(a, b);
        }
        final c = ka.compareTo(kb);
        return c != 0 ? c : byTitle(a, b);
      });
  }
  return list;
}

/// [tags] sorted case-insensitively, as tiles show them when sorting by
/// tag.
List<String> sortedTags(List<String> tags) =>
    [...tags]..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

/// What the Tags sort orders by: the sorted tags joined with `, `
/// (lowercase), or null for an untagged pack, which goes last.
String? tagSortKey(List<String> tags) =>
    tags.isEmpty ? null : sortedTags(tags).join(', ').toLowerCase();

/// One dashboard tile: a pack, or in the Expanded view one of its
/// first-level folders.
class DashboardTile {
  const DashboardTile(this.tile, this.pack, [this.folder]);

  /// What the tile shows. For a folder: its path, preview and counts, the
  /// folder name as title and the pack title as subtitle.
  final PackRow tile;
  final PackRow pack;
  final String? folder;

  String get key => folder == null ? pack.id : '${pack.id}/$folder';
}

/// Replaces each pack in [packs] that splits ([subFolders]) with one tile
/// per folder, in the pack's place. With [searchText], a pack whose folder
/// names match every word shows only those folders.
List<DashboardTile> expandPacks(
  List<PackRow> packs,
  Map<String, List<SubFolderRow>> subFolders, {
  String searchText = '',
}) {
  final words = pathWords(searchText);
  bool matches(String folder) {
    final names = pathWords(folder);
    return words.every((w) => names.any((n) => n.startsWith(w)));
  }

  return [
    for (final pack in packs)
      if (subFolders[pack.id] case final subs? when subs.isNotEmpty) ...[
        for (final sf in _matchingOrAll(subs, words.isEmpty ? null : matches))
          DashboardTile(
            pack.copyWith(
              path: p.join(pack.path, sf.folder),
              title: prettyName(sf.folder, isFile: false),
              author: Value(pack.title),
              preview: Value(sf.preview),
              previewAnim: Value(sf.previewAnim),
              fileCount: sf.fileCount,
              totalBytes: sf.totalBytes,
            ),
            pack,
            sf.folder,
          ),
      ] else
        DashboardTile(pack, pack),
  ];
}

List<SubFolderRow> _matchingOrAll(
  List<SubFolderRow> subs,
  bool Function(String)? matches,
) {
  if (matches == null) return subs;
  final hit = subs.where((s) => matches(s.folder)).toList();
  return hit.isEmpty ? subs : hit;
}

/// The dashboard grid's tiles: [visiblePacksProvider], split by folder in
/// the Expanded view.
final visibleTilesProvider = Provider<AsyncValue<List<DashboardTile>>>((ref) {
  final packs = ref.watch(visiblePacksProvider);
  final view = ref.watch(settingsProvider.select((s) => s.dashboardView));
  if (view == DashboardView.packs) {
    return packs.whenData((l) => [for (final p in l) DashboardTile(p, p)]);
  }
  final subs = ref.watch(subFoldersProvider);
  final text = ref.watch(dashboardQueryProvider.select((q) => q.text));
  return switch ((packs, subs)) {
    (AsyncValue(:final error?, :final stackTrace), _) ||
    (
      _,
      AsyncValue(:final error?, :final stackTrace),
    ) => AsyncError(error, stackTrace ?? StackTrace.current),
    (AsyncValue(value: final l?), AsyncValue(value: final s?)) => AsyncData(
      expandPacks(l, s, searchText: text),
    ),
    _ => const AsyncLoading(),
  };
});

final visiblePacksProvider = Provider<AsyncValue<List<PackRow>>>((ref) {
  final library = ref.watch(libraryProvider);
  final hits = ref.watch(searchHitsProvider);
  final q = ref.watch(dashboardQueryProvider);
  return switch ((library, hits)) {
    (AsyncValue(:final error?, :final stackTrace), _) ||
    (
      _,
      AsyncValue(:final error?, :final stackTrace),
    ) => AsyncError(error, stackTrace ?? StackTrace.current),
    (AsyncValue(value: final lib?), AsyncValue(hasValue: true, :final value)) =>
      AsyncData(applyQuery(lib.packs, q, value)),
    _ => const AsyncLoading(),
  };
});

/// Value → number of packs, most common first.
class Facets {
  const Facets({
    required this.authors,
    required this.tags,
    required this.sources,
  });

  final List<(String, int)> authors;
  final List<(String, int)> tags;
  final List<(String, int)> sources;

  static List<(String, int)> _count(Iterable<String> values) {
    final m = <String, int>{};
    for (final v in values) {
      m[v] = (m[v] ?? 0) + 1;
    }
    return m.entries.map((e) => (e.key, e.value)).toList()..sort(
      (a, b) => b.$2 != a.$2 ? b.$2.compareTo(a.$2) : a.$1.compareTo(b.$1),
    );
  }

  factory Facets.of(List<PackRow> packs) => Facets(
    authors: _count([for (final p in packs) ?p.author]),
    tags: _count(packs.expand((p) => p.tags)),
    sources: _count([for (final p in packs) p.source ?? noSource]),
  );
}

final facetsProvider = Provider<Facets>((ref) {
  final packs = ref.watch(libraryProvider).value?.packs ?? const [];
  return Facets.of(packs);
});
