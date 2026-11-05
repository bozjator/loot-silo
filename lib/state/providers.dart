import 'dart:io';
import 'dart:isolate';

import 'package:file_selector/file_selector.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../core/library_index.dart';
import '../core/library_service.dart';
import '../core/pack_editor.dart';
import '../install/archive_extractor.dart';
import 'settings.dart';

/// Overridden in `main` (and tests) once the app support folder is known.
final settingsStoreProvider = Provider<SettingsStore>(
  (ref) => throw UnimplementedError('settingsStoreProvider not overridden'),
);

/// Overridden in `main` with the on-disk index, in tests with memory.
final libraryIndexProvider = Provider<LibraryIndex>(
  (ref) => throw UnimplementedError('libraryIndexProvider not overridden'),
);

/// Asks the user for a folder; swapped out in tests.
typedef DirectoryPicker = Future<String?> Function(String title);

final directoryPickerProvider = Provider<DirectoryPicker>(
  (ref) =>
      (title) => getDirectoryPath(confirmButtonText: title),
);

/// Asks where to save a file; swapped out in tests.
typedef SaveLocationPicker = Future<String?> Function(String suggestedName);

final saveLocationProvider = Provider<SaveLocationPicker>(
  (ref) =>
      (name) async => (await getSaveLocation(suggestedName: name))?.path,
);

/// Asks for archives to import; swapped out in tests.
typedef ArchivePicker = Future<List<String>> Function();

final archivePickerProvider = Provider<ArchivePicker>(
  (ref) => () async {
    final files = await openFiles(
      acceptedTypeGroups: const [
        XTypeGroup(label: 'Archives', extensions: archiveExtensions),
      ],
      confirmButtonText: 'Import',
    );
    return [for (final f in files) f.path];
  },
);

/// Where archives are unpacked before import; outside the library so the
/// importer can copy from it. Overridden in `main` with the app cache.
final extractRootProvider = Provider<String>(
  (ref) => p.join(Directory.systemTemp.path, 'assets_explorer_extract'),
);

final settingsProvider = NotifierProvider<SettingsNotifier, AppSettings>(
  SettingsNotifier.new,
);

class SettingsNotifier extends Notifier<AppSettings> {
  @override
  AppSettings build() => ref.read(settingsStoreProvider).load();

  void setLibraryPath(String path) => _save(state.copyWith(libraryPath: path));

  void setTheme(ThemeChoice theme) => _save(state.copyWith(theme: theme));

  void setAnimateAll(bool on) => _save(state.copyWith(animateAll: on));

  void setAudioLoop(bool on) => _save(state.copyWith(audioLoop: on));

  void setViewerPixelPerfect(bool on) =>
      _save(state.copyWith(viewerPixelPerfect: on));

  void setDashboardTileSize(double size) {
    if (size != state.dashboardTileSize) {
      _save(state.copyWith(dashboardTileSize: size));
    }
  }

  void setDetailHeaderPinned(bool on) =>
      _save(state.copyWith(detailHeaderPinned: on));

  void setImagesView(ItemsView view) => _save(state.copyWith(imagesView: view));

  void setAnimationsView(ItemsView view) =>
      _save(state.copyWith(animationsView: view));

  void setDetailAnimateMode(AnimateMode mode) =>
      _save(state.copyWith(detailAnimateMode: mode));

  void setDashboardView(DashboardView view) =>
      _save(state.copyWith(dashboardView: view));

  void setAnimationThumbSize(double size) {
    if (size != state.animationThumbSize) {
      _save(state.copyWith(animationThumbSize: size));
    }
  }

  void setImageThumbSize(double size) {
    if (size != state.imageThumbSize) {
      _save(state.copyWith(imageThumbSize: size));
    }
  }

  void _save(AppSettings settings) {
    state = settings;
    ref.read(settingsStoreProvider).save(state);
  }
}

class LibraryState {
  const LibraryState({this.root, this.packs = const [], this.result});

  final String? root;
  final List<PackRow> packs;
  final LoadResult? result;

  Iterable<PackRow> get topLevel => packs.where((p) => p.parentId == null);
}

final libraryProvider = AsyncNotifierProvider<LibraryNotifier, LibraryState>(
  LibraryNotifier.new,
);

/// The library folder was moved, deleted or is on an unmounted drive.
class LibraryMissing implements Exception {
  const LibraryMissing(this.path);

  final String path;

  @override
  String toString() =>
      'The library folder $path is missing. Reconnect the drive or choose '
      'another folder.';
}

class LibraryNotifier extends AsyncNotifier<LibraryState> {
  @override
  Future<LibraryState> build() => _load(force: false);

  Future<LibraryState> _load({required bool force}) async {
    final root = ref.watch(settingsProvider.select((s) => s.libraryPath));
    if (root == null) return const LibraryState();
    if (!Directory(root).existsSync()) {
      throw LibraryMissing(root);
    }
    final service = LibraryService(ref.read(libraryIndexProvider));
    final result = await service.load(root, force: force);
    return LibraryState(root: root, packs: result.packs, result: result);
  }

  /// Full rescan, e.g. after an import.
  Future<void> rescan() async {
    state = const AsyncLoading<LibraryState>();
    state = await AsyncValue.guard(() => _load(force: true));
  }

  /// Rescan that keeps showing the current packs until it finishes, e.g.
  /// after editing one pack's sidecar.
  Future<void> reload() async {
    state = await AsyncValue.guard(() => _load(force: true));
  }
}

/// Expanded-view folders by pack id; re-read after every load.
final subFoldersProvider = FutureProvider<Map<String, List<SubFolderRow>>>((
  ref,
) async {
  await ref.watch(libraryProvider.future);
  return ref.read(libraryIndexProvider).allSubFolders();
});

/// Files and animations of one pack, for the detail view.
final packContentsProvider = FutureProvider.autoDispose
    .family<PackContents, String>((ref, packId) async {
      final library = await ref.watch(libraryProvider.future);
      final pack = library.packs.firstWhere((p) => p.id == packId);
      final files = await ref.read(libraryIndexProvider).filesWithSizes(packId);
      return _contentsInBackground(pack.path, files);
    });

Future<PackContents> _contentsInBackground(
  String path,
  List<(String, int)> files,
) => Isolate.run(() => loadPackContents(path, files));
