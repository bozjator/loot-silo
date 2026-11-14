import 'package:path/path.dart' as p;

import 'fs_tree.dart';
import 'material_sets.dart';
import 'natural_order.dart';
import 'sidecar.dart';

/// Formats Flutter can decode for a tile preview.
const previewExts = {'png', 'gif', 'jpg', 'jpeg', 'webp', 'bmp'};
const animatedExts = {'gif', 'webp', 'apng'};

final _previewWord = RegExp(
  r'(^|[^a-z])(preview|mockup|cover|sample|showcase|screenshot|example|thumbnail)s?([^a-z]|$)',
  caseSensitive: false,
);
final _allStem = RegExp(r'^all([^a-z]|$)', caseSensitive: false);

/// Promo and housekeeping images that never represent the pack.
final _promo = RegExp(
  r'(coupon|promo|discount|banner_ad|advert|logo|donate|patreon|kofi|ko-fi|support[^a-z]*me|licen[cs]e|follow)',
  caseSensitive: false,
);

/// Preferred preview words, best first.
const _previewRank = [
  'preview', 'mockup', 'cover', 'showcase', 'screenshot', 'thumbnail', //
  'all', 'sample', 'example',
];

int _rank(String rel) {
  final lower = rel.toLowerCase();
  final stem = p.basenameWithoutExtension(lower);
  for (var i = 0; i < _previewRank.length; i++) {
    final w = _previewRank[i];
    if (w == 'all' ? _allStem.hasMatch(stem) : stem.contains(w)) return i;
  }
  for (var i = 0; i < _previewRank.length; i++) {
    if (p.dirname(lower).contains(_previewRank[i])) {
      return _previewRank.length + i;
    }
  }
  return 99;
}

/// Picks the image that best represents a pack, as a path relative to it.
///
/// Priority, as in the plan:
/// 1. the first of the sidecar `previews` that exists;
/// 2. itch cover/screenshots in `_itch/`;
/// 3. files named, or inside folders named, preview / mockup / cover /
///    sample / showcase / screenshot / example, or an `all*` sheet;
/// 4. a GIF / animated WebP;
/// 5. a detected animation (chosen by the scanner, see
///    `choosePreviewAnimation`);
/// 6. the largest image near the root (depth ≤ 2), else anywhere;
///    texture maps (`_gloss`, `_norm`, `_mask01` …) only when nothing
///    else is left.
///
/// Promo images (coupon, logo, patreon …) are never picked. Named previews
/// are ordered by word (preview > mockup > cover > … > sample > example),
/// file name before folder name, then shallower, then larger; static
/// images beat animated ones there.
String? pickPreview(List<(String, FileEntry)> files, {PackSidecar? sidecar}) =>
    pickPreviewRanked(files, sidecar: sidecar)?.path;

/// The plan's preview priority: 1 sidecar cover … 6 largest image.
typedef PreviewPick = ({String path, int rank});

/// [pickPreview] plus which priority rule chose the file, so the scanner
/// can try a detected animation (rank 5) before settling for rank 6.
PreviewPick? pickPreviewRanked(
  List<(String, FileEntry)> files, {
  PackSidecar? sidecar,
}) {
  final images = [
    for (final f in files)
      if (previewExts.contains(f.$2.ext) &&
          !_promo.hasMatch(p.basenameWithoutExtension(f.$1)))
        f,
  ];
  final chosen = sidecar?.previews ?? const <String>[];
  if (chosen.isNotEmpty) {
    final present = {for (final f in files) f.$1};
    final cover = chosen.where(present.contains).firstOrNull;
    if (cover != null) return (path: cover, rank: 1);
  }
  if (images.isEmpty) return null;

  int depth(String rel) => '/'.allMatches(rel).length;
  (String, FileEntry)? best(Iterable<(String, FileEntry)> candidates) {
    final list = candidates.toList();
    if (list.isEmpty) return null;
    list.sort((a, b) {
      final r = _rank(a.$1).compareTo(_rank(b.$1));
      if (r != 0) return r;
      final d = depth(a.$1).compareTo(depth(b.$1));
      if (d != 0) return d;
      return b.$2.size.compareTo(a.$2.size);
    });
    return list.first;
  }

  final itch = best(images.where((f) => f.$1.startsWith('_itch/')));
  if (itch != null) {
    final covers = images.where((f) => f.$1.startsWith('_itch/cover'));
    return (path: covers.isNotEmpty ? covers.first.$1 : itch.$1, rank: 2);
  }

  final named = images.where((f) {
    final stem = p.basenameWithoutExtension(f.$1);
    final dirs = p.dirname(f.$1);
    return _previewWord.hasMatch(stem) ||
        _allStem.hasMatch(stem) ||
        (dirs != '.' && _previewWord.hasMatch(dirs));
  });
  final namedStatic = best(
    named.where((f) => !animatedExts.contains(f.$2.ext)),
  );
  final namedAny = namedStatic ?? best(named);
  if (namedAny != null) return (path: namedAny.$1, rank: 3);

  final gif = best(images.where((f) => animatedExts.contains(f.$2.ext)));
  if (gif != null) return (path: gif.$1, rank: 4);

  int largestFirst((String, FileEntry) a, (String, FileEntry) b) =>
      b.$2.size.compareTo(a.$2.size);
  final pictures = images.where((f) => !looksLikeMap(f.$1)).toList();
  final pool = pictures.isEmpty ? images : pictures;
  final shallow = pool.where((f) => depth(f.$1) <= 2).toList()
    ..sort(largestFirst);
  if (shallow.isNotEmpty) return (path: shallow.first.$1, rank: 6);
  return (path: (pool..sort(largestFirst)).first.$1, rank: 6);
}

/// The images that can stand for a pack, best first: itch files, then
/// files named, or inside folders named, preview / mockup / cover / … (the
/// same words and ranking as [pickPreview], so `mockups/mockup2.png`
/// counts), then `all*` sheets. Promo images are left out. Ties go to
/// shallower paths, then natural order.
List<String> previewCandidates(Iterable<String> images) {
  bool candidate(String rel) {
    final stem = p.basenameWithoutExtension(rel);
    if (_promo.hasMatch(stem)) return false;
    final dirs = p.dirname(rel);
    return rel.startsWith('_itch/') ||
        _previewWord.hasMatch(stem) ||
        _allStem.hasMatch(stem) ||
        (dirs != '.' && _previewWord.hasMatch(dirs));
  }

  int depth(String rel) => '/'.allMatches(rel).length;
  final out = images.where(candidate).toList()
    ..sort((a, b) {
      final ia = a.startsWith('_itch/') ? 0 : 1;
      final ib = b.startsWith('_itch/') ? 0 : 1;
      if (ia != ib) return ia.compareTo(ib);
      final r = _rank(a).compareTo(_rank(b));
      if (r != 0) return r;
      final d = depth(a).compareTo(depth(b));
      return d != 0 ? d : naturalCompare(a, b);
    });
  return out;
}
