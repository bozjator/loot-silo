import 'package:path/path.dart' as p;

import 'author_resolver.dart';
import 'fs_tree.dart';
import 'sidecar.dart';
import 'type_classifier.dart';

/// A pack found in a folder tree.
class DetectedPack {
  DetectedPack({
    required this.dir,
    required this.author,
    this.authorFile,
    this.sidecar,
  });

  final DirNode dir;
  final AuthorInfo? author;

  /// The `ASSET_AUTHOR.txt` the author came from, if any.
  final String? authorFile;
  final PackSidecar? sidecar;

  String get title => sidecar?.title ?? dir.name;
}

final _previewStem = RegExp(
  r'^(preview|mockup|cover|sample|showcase|screenshot)s?(?![a-z])',
  caseSensitive: false,
);
final _docStem = RegExp(
  r'^(licen[cs]e|read[ _-]?me|credits?|contact|terms)(?![a-z])',
  caseSensitive: false,
);
final _countedName = RegExp(
  r'\(\s*\d+\s+(assets|sounds|files|sprites|models|tracks|icons|textures)\s*\)',
  caseSensitive: false,
);
final _previewDirName = RegExp(
  r'^_?(mockups?|previews?|screenshots?|examples?|samples?|showcase|itch)$',
  caseSensitive: false,
);
final _versioned = RegExp(r'(^|[^a-z])v(ersion)?\s?\d', caseSensitive: false);
const _packWords = {
  'pack', 'bundle', 'kit', 'asset', 'assets', 'vol', 'collection', 'sfx', //
  'music', 'bgm', 'tileset', 'effects', 'sounds', 'tunes', 'loops', 'set',
};
const assetExts = {...imageExts, ...audioExts, ...modelExts, ...fontExts};

bool _isPreviewOrDoc(FileEntry f) =>
    _previewStem.hasMatch(f.stem) || _docStem.hasMatch(f.stem);

/// Strong evidence that a folder is a pack root: a sidecar, a license /
/// readme / preview file at its top, or a Kenney-style `(N assets)` name.
bool hasStrongPackSignal(DirNode d) =>
    d.hasFile(packFileName) ||
    d.files.any(_isPreviewOrDoc) ||
    _countedName.hasMatch(d.name);

/// Weaker evidence, only used to choose between "this author folder holds
/// several packs" and "this author folder is one pack".
bool _hasWeakPackSignal(DirNode d) =>
    hasStrongPackSignal(d) ||
    d.dirs.any((c) => _previewDirName.hasMatch(c.name)) ||
    _versioned.hasMatch(d.name) ||
    pathWords(d.name).any(_packWords.contains);

bool _hasAssets(DirNode d) =>
    d.walk().any((n) => n.files.any((f) => assetExts.contains(f.ext)));

bool _hasDirectAssets(DirNode d) =>
    d.files.any((f) => assetExts.contains(f.ext));

/// Finds packs and their authors in an arbitrary folder tree.
///
/// Rules, applied top-down:
/// 1. A folder with `ASSET_AUTHOR.txt` whose name matches the author (or
///    their itch slug) is an *author folder*: each child folder is a pack,
///    unless none of them looks like a pack, in which case the folder
///    itself is one pack. Any other folder with that file is a pack.
/// 2. A folder with a strong pack signal ([hasStrongPackSignal]) is a pack.
/// 3. A folder with assets but no signal anywhere below it is a pack, so
///    loose collections still show up.
/// 4. A folder with asset files directly in it is a pack, even when child
///    folders have signals of their own (those files would otherwise belong
///    to no pack). Docs alone don't count.
/// 5. Otherwise recurse. Authors are inherited from author files above.
///
/// A pack is always flat: every folder below it, signalled or not, is an
/// ordinary folder of that pack.
class PackDetector {
  final _signalBelow = <String, bool>{};

  List<DetectedPack> detect(DirNode root) {
    final out = <DetectedPack>[];
    _visit(root, null, null, out, isRoot: true);
    if (out.isEmpty && _hasAssets(root)) {
      out.add(_pack(root, guessAuthor(root), null));
    }
    return out;
  }

  bool _anySignalBelow(DirNode d) => _signalBelow[d.path] ??= d.dirs.any(
    (c) =>
        c.hasFile(authorFileName) ||
        hasStrongPackSignal(c) ||
        _anySignalBelow(c),
  );

  void _visit(
    DirNode d,
    AuthorInfo? author,
    String? authorFile,
    List<DetectedPack> out, {
    bool isRoot = false,
  }) {
    if (d.hasFile(authorFileName)) {
      final file = p.join(d.path, authorFileName);
      final info = AuthorInfo.read(file);
      if (info != null) {
        author = info;
        authorFile = file;
        if (!isAuthorFolderName(d.name, info)) {
          out.add(_pack(d, author, authorFile));
          return;
        }
        final children = d.dirs
            .where((c) => !_previewDirName.hasMatch(c.name))
            .toList();
        if (_hasDirectAssets(d) || !children.any(_hasWeakPackSignal)) {
          out.add(_pack(d, author, authorFile));
        } else {
          for (final c in children) {
            if (_hasAssets(c)) out.add(_pack(c, author, authorFile));
          }
        }
        return;
      }
    }
    if (!isRoot && hasStrongPackSignal(d)) {
      out.add(_pack(d, author ?? guessAuthor(d), authorFile));
      return;
    }
    if (!isRoot && !_anySignalBelow(d)) {
      if (_hasAssets(d)) {
        out.add(_pack(d, author ?? guessAuthor(d), authorFile));
      }
      return;
    }
    if (!isRoot && _hasDirectAssets(d)) {
      out.add(_pack(d, author ?? guessAuthor(d), authorFile));
      return;
    }
    for (final c in d.dirs) {
      _visit(c, author, authorFile, out);
    }
  }

  DetectedPack _pack(DirNode d, AuthorInfo? author, String? authorFile) =>
      DetectedPack(
        dir: d,
        author: author,
        authorFile: authorFile,
        sidecar: d.hasFile(packFileName) ? PackSidecar.read(d.path) : null,
      );
}
