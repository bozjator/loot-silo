import 'dart:isolate';

import 'fs_tree.dart';
import 'library_index.dart';
import 'library_scanner.dart';

/// Keeps the [LibraryIndex] in step with a library folder.
class LibraryService {
  LibraryService(this.index);

  final LibraryIndex index;

  /// Loads the packs under [root].
  ///
  /// A warm start only fingerprints the folder tree and reads the index;
  /// a full scan runs in a background isolate when the tree changed, the
  /// root is new, or [force] is set.
  Future<LoadResult> load(String root, {bool force = false}) async {
    final sw = Stopwatch()..start();
    if (!force) {
      final state = await index.scanStateFor(root);
      if (state != null) {
        final fp = await Isolate.run(() => treeFingerprint(root));
        if (fp == state.fingerprint) {
          return LoadResult(
            await index.allPacks(),
            scanned: false,
            elapsed: sw.elapsed,
          );
        }
      }
    }
    final result = await Isolate.run(() => scanLibrary(root));
    await index.replaceScan(result);
    return LoadResult(
      await index.allPacks(),
      scanned: true,
      elapsed: sw.elapsed,
    );
  }
}

class LoadResult {
  const LoadResult(this.packs, {required this.scanned, required this.elapsed});

  final List<PackRow> packs;

  /// Whether a full scan ran (false for a warm start from the index).
  final bool scanned;
  final Duration elapsed;
}
