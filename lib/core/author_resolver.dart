import 'dart:io';

import 'package:path/path.dart' as p;

import 'fs_tree.dart';
import 'sidecar.dart';

final _creditFile = RegExp(
  r'(author|credit|licen[cs]e|contact|readme|about|info)',
  caseSensitive: false,
);
final _itchUrl = RegExp(
  r'https?://([a-z0-9-]+)\.itch\.io\b',
  caseSensitive: false,
);
const _maxTextBytes = 64 * 1024;

/// Lowercase letters and digits only, for loose name comparison.
String normalizeName(String s) =>
    s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

/// Whether a folder called [dirName] is the folder of [author], meaning
/// its children are that author's packs rather than the folder being a
/// pack itself.
bool isAuthorFolderName(String dirName, AuthorInfo author) {
  final n = normalizeName(dirName);
  if (n.isEmpty) return false;
  if (n == normalizeName(author.user)) return true;
  final slug = author.itchSlug;
  return slug != null && n == normalizeName(slug);
}

/// Finds an author for a pack that has no `ASSET_AUTHOR.txt` by reading
/// small credit, license and readme files and looking for an itch.io url.
///
/// Only files near the pack root (depth ≤ 1) are read, so huge bundles stay
/// cheap. Returns null when nothing convincing is found.
AuthorInfo? guessAuthor(DirNode pack) {
  final candidates =
      [
        for (final f in pack.files) (p.join(pack.path, f.name), f),
        for (final d in pack.dirs)
          for (final f in d.files) (p.join(d.path, f.name), f),
      ].where(
        (c) =>
            const {'txt', 'md', 'html', 'htm', 'rtf', ''}.contains(c.$2.ext) &&
            c.$2.size <= _maxTextBytes &&
            _creditFile.hasMatch(c.$2.stem),
      );

  for (final (path, _) in candidates) {
    final String text;
    try {
      text = File(path).readAsStringSync();
    } on FileSystemException {
      continue;
    }
    final parsed = AuthorInfo.parse(text);
    if (parsed != null && p.basename(path) == authorFileName) return parsed;
    final m = _itchUrl.firstMatch(text);
    if (m != null) {
      final slug = m.group(1)!.toLowerCase();
      if (slug == 'www') continue;
      return AuthorInfo(
        user: slug,
        url: 'https://$slug.itch.io/',
        itchUser: slug,
      );
    }
  }
  return null;
}
