import 'dart:async';

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
  tags('Tags'),
  type('Type');

  const PackSort(this.label);
  final String label;
}

/// Source facet value for packs with no recorded source (folders put into
/// the library by hand); sub-packs take their bundle's.
const noSource = 'unknown';

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
  /// How long typing must pause before the search runs.
  static const searchDebounce = Duration(milliseconds: 150);

  Timer? _debounce;

  @override
  DashboardQuery build() {
    ref.onDispose(() => _debounce?.cancel());
    return const DashboardQuery();
  }

  /// Search text from the field: applied once typing pauses for
  /// [searchDebounce]; clearing it applies at once.
  void setText(String text) {
    _debounce?.cancel();
    if (text.trim().isEmpty) {
      if (state.text != text) state = state.copyWith(text: text);
      return;
    }
    _debounce = Timer(searchDebounce, () {
      if (state.text != text) state = state.copyWith(text: text);
    });
  }

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

  void clearFilters() {
    _debounce?.cancel();
    state = DashboardQuery(sort: state.sort);
  }
}

/// FTS hits in rank order, or null when there is no search text.
final searchHitsProvider = FutureProvider<List<String>?>((ref) async {
  final text = ref.watch(dashboardQueryProvider.select((q) => q.text.trim()));
  // Re-run after rescans.
  await ref.watch(libraryProvider.future);
  if (text.isEmpty) return null;
  return ref.read(libraryIndexProvider).search(text);
});

/// Files matching the search text, or null when there is none.
final fileSearchProvider = FutureProvider<FileSearch?>((ref) async {
  final text = ref.watch(dashboardQueryProvider.select((q) => q.text.trim()));
  await ref.watch(libraryProvider.future);
  if (text.isEmpty) return null;
  return ref.read(libraryIndexProvider).searchFiles(text);
});

/// One tile of the Files view: a matching file and its pack.
typedef FileTile = ({PackRow pack, String relPath});

/// Keeps the [hits] whose pack is in [packs] (the packs the filters let
/// through, already sorted by [sort]) and orders them: best match keeps
/// the index order, Name sorts by file name, other sorts follow their
/// pack's place, then file name.
List<FileTile> filterFileHits(
  List<FileHit> hits,
  List<PackRow> packs,
  PackSort sort,
) {
  final place = {for (var i = 0; i < packs.length; i++) packs[i].id: i};
  final byId = {for (final pk in packs) pk.id: pk};
  final out = [
    for (final h in hits)
      if (byId[h.packId] case final pack?) (pack: pack, relPath: h.relPath),
  ];
  String name(FileTile t) => p.basename(t.relPath).toLowerCase();
  switch (sort) {
    case PackSort.relevance:
      break;
    case PackSort.title:
      out.sort((a, b) {
        final c = name(a).compareTo(name(b));
        return c != 0 ? c : a.relPath.compareTo(b.relPath);
      });
    default:
      out.sort((a, b) {
        final c = place[a.pack.id]!.compareTo(place[b.pack.id]!);
        return c != 0 ? c : name(a).compareTo(name(b));
      });
  }
  return out;
}

/// The Files view's tiles: file hits within the packs the filters (and an
/// open bundle) allow, in the chosen order.
final visibleFilesProvider = Provider<AsyncValue<List<FileTile>>>((ref) {
  final library = ref.watch(libraryProvider);
  final files = ref.watch(fileSearchProvider);
  final q = ref.watch(dashboardQueryProvider);
  return switch ((library, files)) {
    (AsyncValue(:final error?, :final stackTrace), _) ||
    (
      _,
      AsyncValue(:final error?, :final stackTrace),
    ) => AsyncError(error, stackTrace ?? StackTrace.current),
    (AsyncValue(value: final lib?), AsyncValue(hasValue: true, :final value)) =>
      AsyncData(
        value == null
            ? const []
            : filterFileHits(
                value.hits,
                applyQuery(lib.packs, q, null),
                q.sort,
              ),
      ),
    _ => const AsyncLoading(),
  };
});

/// The dashboard's filter menus and chips.
enum Facet { type, author, tag, source }

/// Whether [p] passes [q]'s type / author / tag / source filters, leaving
/// out [skip] (a facet's own counts ignore its own selection).
bool passesFacets(PackRow p, DashboardQuery q, {Facet? skip}) =>
    (skip == Facet.type || q.types.isEmpty || p.types.any(q.types.contains)) &&
    (skip == Facet.author ||
        q.authors.isEmpty ||
        q.authors.contains(p.author ?? '')) &&
    (skip == Facet.tag || q.tags.isEmpty || p.tags.any(q.tags.contains)) &&
    (skip == Facet.source ||
        q.sources.isEmpty ||
        q.sources.contains(p.source ?? noSource));

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
  out = out.where((p) => passesFacets(p, q));

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
    case PackSort.tags || PackSort.type:
      final keys = {
        for (final p in list)
          p.id: q.sort == PackSort.tags
              ? tagSortKey(p.tags)
              : typeSortKey(p.types),
      };
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

/// [types] sorted by their label (the type id, as the chips show it).
List<String> sortedTypes(List<String> types) =>
    [...types]..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

/// What the Type sort orders by: the sorted types joined with `, `, or null
/// for a pack without types, which goes last.
String? typeSortKey(List<String> types) =>
    types.isEmpty ? null : sortedTypes(types).join(', ').toLowerCase();

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
  // The Files view lists files instead; pack tiles stay as in Packs.
  if (view != DashboardView.expanded) {
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
    this.types = const [],
    required this.authors,
    required this.tags,
    required this.sources,
  });

  final List<(String, int)> types;
  final List<(String, int)> authors;
  final List<(String, int)> tags;
  final List<(String, int)> sources;

  static List<(String, int)> _count(
    Iterable<String> values, [
    Set<String> selected = const {},
  ]) {
    final m = <String, int>{};
    for (final v in values) {
      m[v] = (m[v] ?? 0) + 1;
    }
    final out = m.entries.map((e) => (e.key, e.value)).toList()
      ..sort(
        (a, b) => b.$2 != a.$2 ? b.$2.compareTo(a.$2) : a.$1.compareTo(b.$1),
      );
    // A selected value nothing matches any more stays listed (at 0), so it
    // can be unticked.
    final zero = [
      for (final v in selected)
        if (!m.containsKey(v)) v,
    ]..sort();
    return [...out, for (final v in zero) (v, 0)];
  }

  static List<String> _authors(Iterable<PackRow> l) => [
    for (final p in l) ?p.author,
  ];
  static List<String> _sources(Iterable<PackRow> l) => [
    for (final p in l) p.source ?? noSource,
  ];

  factory Facets.of(List<PackRow> packs) => Facets(
    types: _count(packs.expand((p) => p.types)),
    authors: _count(_authors(packs)),
    tags: _count(packs.expand((p) => p.tags)),
    sources: _count(_sources(packs)),
  );

  /// Faceted counts: each facet counts the packs (in the open bundle, and
  /// among the search [hits] when searching) that pass the *other* active
  /// filters. Sub-packs count, since any filter lists them.
  factory Facets.forQuery(
    List<PackRow> packs,
    DashboardQuery q,
    List<String>? hits,
  ) {
    Iterable<PackRow> base = packs;
    if (q.bundleId != null) {
      base = base.where((p) => p.parentId == q.bundleId);
    }
    if (hits != null) {
      final hitSet = hits.toSet();
      base = base.where((p) => hitSet.contains(p.id));
    }
    final list = base.toList();
    Iterable<PackRow> without(Facet f) =>
        list.where((p) => passesFacets(p, q, skip: f));
    return Facets(
      types: _count(without(Facet.type).expand((p) => p.types), q.types),
      authors: _count(_authors(without(Facet.author)), q.authors),
      tags: _count(without(Facet.tag).expand((p) => p.tags), q.tags),
      sources: _count(_sources(without(Facet.source)), q.sources),
    );
  }
}

/// Every tag in the library, most used first (tag editor suggestions).
List<String> knownTags(WidgetRef ref) => [
  for (final (t, _) in Facets.of(
    ref.read(libraryProvider).value?.packs ?? const [],
  ).tags)
    t,
];

/// Authors in the library (their folders under the library root) with how
/// many packs each has, by name.
List<(String, int)> knownAuthors(List<PackRow> packs) {
  final m = <String, int>{};
  for (final p in packs) {
    if (p.parentId == null && p.author != null) {
      m[p.author!] = (m[p.author!] ?? 0) + 1;
    }
  }
  return [for (final e in m.entries) (e.key, e.value)]
    ..sort((a, b) => a.$1.toLowerCase().compareTo(b.$1.toLowerCase()));
}

final facetsProvider = Provider<Facets>((ref) {
  final packs = ref.watch(libraryProvider).value?.packs ?? const [];
  final q = ref.watch(dashboardQueryProvider);
  // While a new search runs, the last hits keep the counts steady.
  final hits = q.text.trim().isEmpty
      ? null
      : ref.watch(searchHitsProvider).value;
  return Facets.forQuery(packs, q, hits);
});
