import 'dart:isolate';

import 'package:file_selector/file_selector.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/library_index.dart';
import '../core/library_service.dart';
import '../core/pack_editor.dart';
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

final settingsProvider = NotifierProvider<SettingsNotifier, AppSettings>(
  SettingsNotifier.new,
);

class SettingsNotifier extends Notifier<AppSettings> {
  @override
  AppSettings build() => ref.read(settingsStoreProvider).load();

  void setLibraryPath(String path) {
    state = state.copyWith(libraryPath: path);
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

class LibraryNotifier extends AsyncNotifier<LibraryState> {
  @override
  Future<LibraryState> build() => _load(force: false);

  Future<LibraryState> _load({required bool force}) async {
    final root = ref.watch(settingsProvider.select((s) => s.libraryPath));
    if (root == null) return const LibraryState();
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
