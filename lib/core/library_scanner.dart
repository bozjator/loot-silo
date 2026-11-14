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
    this.isBundle = false,
    this.bundleId,
    this.section,
    this.fileTotal,
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

  /// A bundle of packs (M95); [files] are its own (license, cover).
  final bool isBundle;

  /// The bundle this pack is in, and its heading there.
  final String? bundleId;
  final String? section;

  /// A bundle's file count: its packs' and its own content files.
  final int? fileTotal;
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
///
/// [importSource]: [root] is a folder picked for import, which may itself
/// be a bundle (a downloaded all-in-one); a library root never is.
ScanResult scanLibrary(String root, {bool importSource = false}) {
  final sw = Stopwatch()..start();
  final fingerprint = treeFingerprint(root);
  final tree = readTree(root);
  final packs = <ScannedPack>[];

  String idOf(DirNode d) => p.split(p.relative(d.path, from: root)).join('/');

  /// One pack (or a bundle's own files when [own] is given).
  ScannedPack scan(
    DetectedPack dp, {
    List<(String, FileEntry)>? own,
    String? bundleId,
    PackSource? inheritedSource,
    List<ScannedPack> children = const [],
  }) {
    final id = idOf(dp.dir);
    final files = <(String, FileEntry)>[
      for (final entry in own ?? dp.dir.allFiles())
        if (!_sidecarNames.contains(entry.$2.name)) entry,
    ];
    final sc = dp.sidecar;
    final content = [
      for (final e in files)
        if (!isItchMedia(e.$1)) e,
    ];
    final List<String> types;
    if (sc != null && sc.types.isNotEmpty) {
      types = sc.types;
    } else if (dp.isBundle) {
      // Types shared by at least 10 % of its packs; the packs themselves
      // are what searches and filters list.
      final counts = <String, int>{};
      for (final c in children) {
        for (final t in c.types) {
          counts[t] = (counts[t] ?? 0) + 1;
        }
      }
      types =
          counts.keys.where((t) => counts[t]! >= children.length * 0.1).toList()
            ..sort((a, b) => counts[b]!.compareTo(counts[a]!));
    } else {
      types = [for (final t in classifyPack(id, content)) t.id];
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
    SpriteAnim? previewAnim = preview == chosen.preview ? chosen.anim : null;
    if (preview == null && dp.isBundle) {
      // A bundle without a cover of its own shows its first pack's.
      for (final c in children) {
        if (c.preview != null) {
          preview = p.posix.join(
            p.posix.joinAll(p.split(p.relative(c.path, from: dp.dir.path))),
            c.preview,
          );
          // The frames are read from the bundle's folder.
          previewAnim = c.previewAnim == null
              ? null
              : SpriteAnim.fromJson({
                  ...c.previewAnim!.toJson(),
                  'path': preview,
                });
          break;
        }
      }
    }
    final bytes = content.fold(0, (sum, e) => sum + e.$2.size);
    return ScannedPack(
      id: id,
      path: dp.dir.path,
      title: dp.title,
      author: dp.author,
      authorFile: dp.authorFile,
      types: types,
      tags: sc != null && sc.tags.isNotEmpty
          ? sc.tags
          : suggestTags(id, types: types),
      source: sc?.source ?? inheritedSource,
      files: [for (final (rel, _) in files) rel],
      sizes: [for (final (_, f) in files) f.size],
      preview: preview,
      previewAnim: previewAnim,
      totalBytes: bytes + children.fold(0, (n, c) => n + c.totalBytes),
      sidecar: sc,
      // A bundle's packs show whole in the Expanded view; their own pages
      // have By folder.
      subFolders: dp.isBundle || bundleId != null
          ? const []
          : splitSubFolders(
              dp.dir.path,
              files,
              overrides: sc?.animations ?? const {},
            ),
      isBundle: dp.isBundle,
      bundleId: bundleId,
      section: dp.section,
      fileTotal: dp.isBundle
          ? content.length +
                children.fold(0, (n, c) => n + c.contentFiles.length)
          : null,
    );
  }

  final detected = PackDetector().detect(tree, rootMayBeBundle: importSource);
  for (final dp in detected) {
    if (dp.bundle != null) continue;
    if (!dp.isBundle) {
      packs.add(scan(dp));
      continue;
    }
    final bundleId = idOf(dp.dir);
    final kids = [
      for (final c in detected)
        if (identical(c.bundle, dp))
          scan(c, bundleId: bundleId, inheritedSource: dp.sidecar?.source),
    ];
    // The bundle's own files: the ones none of its packs holds.
    final inKids = [
      for (final k in kids)
        '${p.posix.joinAll(p.split(p.relative(k.path, from: dp.dir.path)))}/',
    ];
    final own = [
      for (final e in dp.dir.allFiles())
        if (!inKids.any(e.$1.startsWith)) e,
    ];
    packs
      ..add(scan(dp, own: own, children: kids))
      ..addAll(kids);
  }
  return ScanResult(
    root: root,
    fingerprint: fingerprint,
    packs: packs,
    elapsed: sw.elapsed,
  );
}
