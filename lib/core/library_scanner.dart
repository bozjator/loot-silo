import 'package:path/path.dart' as p;

import 'animation_detector.dart';
import 'fs_tree.dart';
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
    required this.parentId,
    required this.isContainer,
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

  /// Id of the bundle this sub-pack belongs to.
  final String? parentId;
  final bool isContainer;
  final List<String> types;
  final List<String> tags;
  final PackSource? source;

  /// Files relative to [path]; a container leaves out its sub-packs' files.
  final List<String> files;

  /// Byte sizes, parallel to [files].
  final List<int> sizes;

  /// Representative image relative to [path]; for a bundle without one of
  /// its own, a sub-pack's preview.
  final String? preview;

  /// Frame data when [preview] is a sprite sheet.
  final SpriteAnim? previewAnim;
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

  // A sub-pack without a source of its own takes its bundle's: imports and
  // itch downloads write one sidecar, at the bundle.
  List<String> add(DetectedPack dp, String? parentId, PackSource? inherited) {
    final source = dp.sidecar?.source ?? inherited;
    final id = idOf(dp.dir);
    final slot = packs.length;
    // Sub-packs go first so a bundle's types can be the union of theirs;
    // the bundle is then inserted ahead of them.
    final subTypes = <String, int>{};
    for (final s in dp.subPacks) {
      for (final t in add(s, id, source)) {
        subTypes[t] = (subTypes[t] ?? 0) + 1;
      }
    }
    final subDirs = {
      for (final s in dp.subPacks)
        '${p.relative(s.dir.path, from: dp.dir.path)}/',
    };
    final files = <(String, FileEntry)>[
      for (final entry in dp.dir.allFiles())
        if (!_sidecarNames.contains(entry.$2.name) &&
            !subDirs.any((s) => entry.$1.startsWith(s)))
          entry,
    ];
    final sc = dp.sidecar;
    final List<String> types;
    if (sc != null && sc.types.isNotEmpty) {
      types = sc.types;
    } else if (subTypes.isNotEmpty) {
      // Types shared by at least 10 % of the sub-packs; the sub-packs
      // themselves stay searchable for the rare ones.
      final min = dp.subPacks.length * 0.1;
      types = subTypes.keys.where((t) => subTypes[t]! >= min).toList()
        ..sort((a, b) => subTypes[b]!.compareTo(subTypes[a]!));
    } else {
      types = [for (final t in classifyPack(id, files)) t.id];
    }
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
    var preview =
        chosen.preview ??
        materials.firstOrNull?.preview ??
        materials.firstOrNull?.color;
    if (preview == null) {
      for (final sub in packs.skip(slot).where((x) => x.parentId == id)) {
        if (sub.preview != null) {
          preview = '${sub.id.substring(id.length + 1)}/${sub.preview}';
          break;
        }
      }
    }
    packs.insert(
      slot,
      ScannedPack(
        id: id,
        path: dp.dir.path,
        title: dp.title,
        author: dp.author,
        authorFile: dp.authorFile,
        parentId: parentId,
        isContainer: dp.isContainer,
        types: types,
        tags: sc != null && sc.tags.isNotEmpty ? sc.tags : suggestTags(id),
        source: source,
        files: [for (final (rel, _) in files) rel],
        sizes: [for (final (_, f) in files) f.size],
        preview: preview,
        previewAnim: preview == chosen.preview ? chosen.anim : null,
        totalBytes: files.fold(0, (sum, e) => sum + e.$2.size),
        sidecar: sc,
        subFolders: dp.isContainer
            ? const []
            : splitSubFolders(
                dp.dir.path,
                files,
                overrides: sc?.animations ?? const {},
              ),
      ),
    );
    return types;
  }

  for (final dp in PackDetector().detect(tree)) {
    add(dp, null, null);
  }
  return ScanResult(
    root: root,
    fingerprint: fingerprint,
    packs: packs,
    elapsed: sw.elapsed,
  );
}
