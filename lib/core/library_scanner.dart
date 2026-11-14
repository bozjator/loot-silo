import 'package:path/path.dart' as p;

import 'animation_detector.dart';
import 'fs_tree.dart';
import 'itch_media.dart';
import 'material_sets.dart';
import 'pack_detector.dart';
import 'preview_picker.dart';
import 'sidecar.dart';
import 'sub_folders.dart';
import 'type_classifier.dart';

/// One pack as seen by a scan, ready for the index.
class ScannedPack {
  const ScannedPack({
    required this.id,
    required this.path,
    required this.title,
    required this.author,
    required this.authorFile,
    required this.types,
    required this.tags,
    required this.source,
    required this.files,
    required this.sizes,
    required this.preview,
    this.previewAnim,
    required this.totalBytes,
    required this.sidecar,
    this.subFolders = const [],
  });

  /// Path relative to the scanned root, `/`-separated. Stable across scans.
  final String id;
  final String path;
  final String title;
  final AuthorInfo? author;
  final String? authorFile;

  final List<String> types;
  final List<String> tags;
  final PackSource? source;

  /// Files relative to [path], `_itch` media included (the preview and
  /// the header carousel use it); see [contentFiles].
  final List<String> files;

  /// [files] without the `_itch` metadata ([isItchMedia]): what the pack
  /// holds, for counts and file search.
  Iterable<String> get contentFiles => files.where((f) => !isItchMedia(f));

  /// Byte sizes, parallel to [files].
  final List<int> sizes;

  /// Representative image relative to [path].
  final String? preview;

  /// Frame data when [preview] is a sprite sheet.
  final SpriteAnim? previewAnim;

  /// Bytes of [contentFiles].
  final int totalBytes;
  final PackSidecar? sidecar;

  /// Tiles for the dashboard's Expanded view; empty when the pack stays
  /// one tile.
  final List<SubFolder> subFolders;
}

class ScanResult {
  const ScanResult({
    required this.root,
    required this.fingerprint,
    required this.packs,
    required this.elapsed,
  });

  final String root;
  final String fingerprint;
  final List<ScannedPack> packs;
  final Duration elapsed;

  /// Distinct author files that ended up attached to a pack.
  Set<String> get resolvedAuthorFiles => {
    for (final pk in packs) ?pk.authorFile,
  };
}

const _sidecarNames = {packFileName, authorFileName};

/// Scans [root] synchronously; call it through `Isolate.run`.
ScanResult scanLibrary(String root) {
  final sw = Stopwatch()..start();
  final fingerprint = treeFingerprint(root);
  final tree = readTree(root);
  final packs = <ScannedPack>[];

  String idOf(DirNode d) => p.split(p.relative(d.path, from: root)).join('/');

  for (final dp in PackDetector().detect(tree)) {
    final id = idOf(dp.dir);
    final files = <(String, FileEntry)>[
      for (final entry in dp.dir.allFiles())
        if (!_sidecarNames.contains(entry.$2.name)) entry,
    ];
    final sc = dp.sidecar;
    final content = [
      for (final e in files)
        if (!isItchMedia(e.$1)) e,
    ];
    final types = sc != null && sc.types.isNotEmpty
        ? sc.types
        : [for (final t in classifyPack(id, content)) t.id];
    // Material maps are no pictures of the pack (and no animations): the
    // material's shipped preview, else its Color map, stands in for them.
    final (materials, _) = groupMaterials([for (final (rel, _) in files) rel]);
    final maps = {
      for (final m in materials) ...[for (final map in m.maps) map.path],
    };
    final pictures = maps.isEmpty
        ? files
        : [
            for (final e in files)
              if (!maps.contains(e.$1)) e,
          ];
    final pick = pickPreviewRanked(pictures, sidecar: sc);
    final chosen = choosePreviewAnimation(
      dp.dir.path,
      [for (final (rel, _) in pictures) rel],
      preview: pick?.path,
      rank: pick?.rank ?? 6,
      overrides: sc?.animations ?? const {},
    );
    final preview =
        chosen.preview ??
        materials.firstOrNull?.preview ??
        materials.firstOrNull?.color;
    packs.add(
      ScannedPack(
        id: id,
        path: dp.dir.path,
        title: dp.title,
        author: dp.author,
        authorFile: dp.authorFile,
        types: types,
        tags: sc != null && sc.tags.isNotEmpty
            ? sc.tags
            : suggestTags(id, types: types),
        source: sc?.source,
        files: [for (final (rel, _) in files) rel],
        sizes: [for (final (_, f) in files) f.size],
        preview: preview,
        previewAnim: preview == chosen.preview ? chosen.anim : null,
        totalBytes: content.fold(0, (sum, e) => sum + e.$2.size),
        sidecar: sc,
        subFolders: splitSubFolders(
          dp.dir.path,
          files,
          overrides: sc?.animations ?? const {},
        ),
      ),
    );
  }
  return ScanResult(
    root: root,
    fingerprint: fingerprint,
    packs: packs,
    elapsed: sw.elapsed,
  );
}
