import 'package:path/path.dart' as p;

import 'author_resolver.dart';
import 'bundle_detector.dart';
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
    this.isBundle = false,
    this.bundle,
    this.section,
  });

  final DirNode dir;
  final AuthorInfo? author;

  /// The `ASSET_AUTHOR.txt` the author came from, if any.
  final String? authorFile;
  final PackSidecar? sidecar;

  /// A bundle of packs (M95); its packs follow it in the detector's list.
  final bool isBundle;

  /// The bundle this pack belongs to.
  final DetectedPack? bundle;

  /// The pack's heading inside its bundle (`2D assets`), if any.
  final String? section;

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

/// A preview / mockup / cover picture or doc named so.
bool isPreviewFile(FileEntry f) => _isPreviewOrDoc(f);

/// `Previews`, `_mockups`, `_itch`…: pictures of the pack, never a pack.
bool isPreviewDirName(String name) => _previewDirName.hasMatch(name);

/// A name with a version (`v1.2`, `Version 3`).
bool isVersionedName(String name) => _versioned.hasMatch(name);

/// A Kenney-style `(N assets)` / `(N sounds)` name: a pack, whatever words
/// come before it.
bool isCountedName(String name) => _countedName.hasMatch(name);

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
/// A pack is flat: every folder below it, signalled or not, is an ordinary
/// folder of that pack. A folder that would be a pack may be a *bundle* of
/// packs instead ([BundleDetector]; `layout` in `asset_pack.json` decides
/// when set).
class PackDetector {
  final _signalBelow = <String, bool>{};
  final _bundles = BundleDetector();

  /// [rootMayBeBundle]: [root] is an import source; with a pack sign of its
  /// own (Kenney's License.txt, Readme) it may be a bundle (M95).
  List<DetectedPack> detect(DirNode root, {bool rootMayBeBundle = false}) {
    final out = <DetectedPack>[];
    if (rootMayBeBundle &&
        !root.hasFile(authorFileName) &&
        hasStrongPackSignal(root) &&
        _isBundle(root)) {
      _add(root, guessAuthor(root), null, out);
      return out;
    }
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
          _add(d, author, authorFile, out);
          return;
        }
        final children = d.dirs
            .where((c) => !_previewDirName.hasMatch(c.name))
            .toList();
        // A child that is a bundle (M95) is its own entry even with no pack
        // sign of its own (an author folder holding one all-in-one).
        if (_hasDirectAssets(d) ||
            !children.any((c) => _hasWeakPackSignal(c) || _isBundle(c))) {
          _add(d, author, authorFile, out);
        } else {
          for (final c in children) {
            if (_hasAssets(c)) _add(c, author, authorFile, out);
          }
        }
        return;
      }
    }
    if (!isRoot && hasStrongPackSignal(d)) {
      _add(d, author ?? guessAuthor(d), authorFile, out);
      return;
    }
    if (!isRoot && !_anySignalBelow(d)) {
      if (_hasAssets(d)) {
        _add(d, author ?? guessAuthor(d), authorFile, out);
      }
      return;
    }
    if (!isRoot && _hasDirectAssets(d)) {
      _add(d, author ?? guessAuthor(d), authorFile, out);
      return;
    }
    for (final c in d.dirs) {
      _visit(c, author, authorFile, out);
    }
  }

  /// [d] as one pack, or as a bundle followed by its packs.
  void _add(
    DirNode d,
    AuthorInfo? author,
    String? authorFile,
    List<DetectedPack> out,
  ) {
    final pack = _pack(d, author, authorFile);
    final plan = _planOf(d, pack.sidecar);
    if (plan == null) {
      out.add(pack);
      return;
    }
    final bundle = DetectedPack(
      dir: d,
      author: author,
      authorFile: authorFile,
      sidecar: pack.sidecar,
      isBundle: true,
    );
    out.add(bundle);
    for (final c in plan.packs) {
      out.add(
        DetectedPack(
          dir: c.dir,
          author: author,
          authorFile: authorFile,
          sidecar: c.dir.hasFile(packFileName)
              ? PackSidecar.read(c.dir.path)
              : null,
          bundle: bundle,
          section: c.section,
        ),
      );
    }
  }

  /// The bundle plan of [d]: its `layout`, else the detector's guess.
  BundlePlan? _planOf(DirNode d, PackSidecar? sidecar) =>
      switch (sidecar?.layout) {
        PackLayout.pack => null,
        PackLayout.bundle => _bundles.force(d),
        null => _bundles.guess(d),
      };

  bool _isBundle(DirNode d) =>
      _planOf(d, d.hasFile(packFileName) ? PackSidecar.read(d.path) : null) !=
      null;

  DetectedPack _pack(DirNode d, AuthorInfo? author, String? authorFile) =>
      DetectedPack(
        dir: d,
        author: author,
        authorFile: authorFile,
        sidecar: d.hasFile(packFileName) ? PackSidecar.read(d.path) : null,
      );
}
