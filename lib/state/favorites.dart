import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/library_index.dart';
import '../core/pack_editor.dart';
import 'providers.dart';

/// Starred packs and files, by pack id. Files are relative to their pack.
class Favorites {
  const Favorites({this.packs = const {}, this.files = const {}});

  factory Favorites.of(Iterable<PackRow> rows) => Favorites(
    packs: {
      for (final r in rows)
        if (r.favorite) r.id,
    },
    files: {
      for (final r in rows)
        if (r.favoriteFiles.isNotEmpty) r.id: r.favoriteFiles.toSet(),
    },
  );

  static const none = Favorites();

  final Set<String> packs;
  final Map<String, Set<String>> files;

  bool isPack(String packId) => packs.contains(packId);

  bool isFile(String packId, String rel) =>
      files[packId]?.contains(rel) ?? false;

  /// The pack's starred files (empty when none).
  Set<String> filesOf(String packId) => files[packId] ?? const {};

  /// Starred, or has a starred file: what the dashboard's Favorites filter
  /// lets through.
  bool hasAny(String packId) =>
      packs.contains(packId) || (files[packId]?.isNotEmpty ?? false);

  /// Every starred file as (pack id, path), by pack then path.
  List<FileHit> get allFiles => [
    for (final e in files.entries)
      for (final rel in e.value.toList()..sort()) (packId: e.key, relPath: rel),
  ];

  bool get isEmpty => packs.isEmpty && files.values.every((s) => s.isEmpty);
}

final favoritesProvider = NotifierProvider<FavoritesNotifier, Favorites>(
  FavoritesNotifier.new,
);

/// Follows the library (each load reads the stars from the index); a toggle
/// writes `asset_pack.json` and the index row and updates this state, with
/// no rescan, so an open pack page doesn't reload.
class FavoritesNotifier extends Notifier<Favorites> {
  @override
  Favorites build() {
    final packs = ref.watch(libraryProvider).value?.packs;
    return packs == null ? Favorites.none : Favorites.of(packs);
  }

  PackRow? _pack(String packId) => ref
      .read(libraryProvider)
      .value
      ?.packs
      .where((p) => p.id == packId)
      .firstOrNull;

  Future<void> togglePack(String packId) async {
    final pack = _pack(packId);
    if (pack == null || !packExists(pack.path)) return;
    final favorite = !state.isPack(packId);
    final sidecar = setFavoritePack(pack.path, favorite: favorite);
    state = Favorites(
      packs: favorite
          ? {...state.packs, packId}
          : ({...state.packs}..remove(packId)),
      files: state.files,
    );
    await _store(packId, sidecar.favorite, sidecar.favoriteFiles);
  }

  Future<void> toggleFile(String packId, String rel) async {
    final pack = _pack(packId);
    if (pack == null || !packExists(pack.path)) return;
    final favorite = !state.isFile(packId, rel);
    final sidecar = setFavoriteFile(pack.path, rel, favorite: favorite);
    state = Favorites(
      packs: state.packs,
      files: {...state.files, packId: sidecar.favoriteFiles.toSet()},
    );
    await _store(packId, sidecar.favorite, sidecar.favoriteFiles);
  }

  Future<void> _store(String packId, bool favorite, List<String> files) => ref
      .read(libraryIndexProvider)
      .setFavorites(packId, favorite: favorite, files: files);
}
