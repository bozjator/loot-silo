import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../core/library_scanner.dart';
import '../core/sidecar.dart';

const unknownAuthor = 'Unknown Author';

/// Makes [name] safe as a folder name on Linux, Windows and macOS.
String safeFolderName(String name) {
  final cleaned = name
      .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_')
      .replaceAll(RegExp(r'[. ]+$'), '')
      .trim();
  return cleaned.isEmpty ? '_' : cleaned;
}

/// The library folder for an author.
String authorFolderName(AuthorInfo? author) =>
    safeFolderName(author?.user ?? unknownAuthor);

/// One top-level pack in a folder import. Editable in the review table.
class ImportItem {
  ImportItem({
    required this.sourcePath,
    required this.sourceRel,
    required this.title,
    required this.author,
    required this.types,
    required this.tags,
    required this.isContainer,
    required this.subPackCount,
    required this.fileCount,
    required this.totalBytes,
    this.importedAs,
    this.origin,
  }) : folderName = safeFolderName(p.basename(sourcePath)),
       selected = importedAs == null;

  final String sourcePath;

  /// Path relative to the import root, used for display and tag hints.
  final String sourceRel;
  final String title;
  final bool isContainer;
  final int subPackCount;
  final int fileCount;
  final int totalBytes;

  /// Library-relative path of an earlier import of the same source.
  final String? importedAs;

  /// What to record as `source_path` when [sourcePath] is a temporary
  /// extraction: the archive (plus the sub-folder for multi-pack archives).
  final String? origin;

  AuthorInfo? author;
  List<String> types;
  List<String> tags;
  String folderName;
  bool selected;
}

/// A reviewed list of packs to copy from [sourceRoot] into [libraryRoot].
class ImportPlan {
  ImportPlan(this.sourceRoot, this.libraryRoot, this.items);

  final String sourceRoot;
  final String libraryRoot;
  final List<ImportItem> items;

  Iterable<ImportItem> get selected => items.where((i) => i.selected);

  /// Library-relative targets (`Author/Pack`) for the selected items.
  ///
  /// Name clashes with folders already in the library, or between items,
  /// get a ` (2)`, ` (3)` … suffix, so nothing is ever overwritten.
  Map<ImportItem, String> targets() {
    final used = <String>{};
    final out = <ImportItem, String>{};
    for (final item in selected) {
      final authorDir = authorFolderName(item.author);
      var name = item.folderName;
      for (var n = 2; ; n++) {
        final rel = '$authorDir/$name';
        final taken =
            used.contains(rel.toLowerCase()) ||
            FileSystemEntity.typeSync(p.join(libraryRoot, rel)) !=
                FileSystemEntityType.notFound;
        if (!taken) break;
        name = '${item.folderName} ($n)';
      }
      final rel = '$authorDir/$name';
      used.add(rel.toLowerCase());
      out[item] = rel;
    }
    return out;
  }
}

bool _isWithin(String parent, String child) =>
    p.equals(parent, child) || p.isWithin(parent, child);

/// The picked folder and the library overlap (see [checkRoots]).
class OverlappingFoldersError implements Exception {
  const OverlappingFoldersError({
    required this.source,
    required this.library,
    required this.sourceInLibrary,
  });

  final String source;
  final String library;

  /// True when [source] is (inside) the library; false when it contains the
  /// library.
  final bool sourceInLibrary;

  /// A plain explanation for the import screens.
  String get message => sourceInLibrary
      ? 'This folder is inside your library ($library). Pick a folder '
            'outside the library, or move it out first.'
      : 'This folder contains your library ($library). Pick a folder that '
            "doesn't contain the library, or move the library out first.";

  @override
  String toString() => 'OverlappingFoldersError: $source, $library';
}

/// Refuses imports where source and library overlap, which could make the
/// importer read its own output or write into the source.
void checkRoots(String sourceRoot, String libraryRoot) {
  final s = p.canonicalize(sourceRoot);
  final l = p.canonicalize(libraryRoot);
  if (_isWithin(l, s) || _isWithin(s, l)) {
    throw OverlappingFoldersError(
      source: s,
      library: l,
      sourceInLibrary: _isWithin(l, s),
    );
  }
}

/// Packs already in the library, keyed by their sidecar `source_path`.
Map<String, String> importedSources(String libraryRoot) {
  final out = <String, String>{};
  final root = Directory(libraryRoot);
  if (!root.existsSync()) return out;
  for (final author in root.listSync().whereType<Directory>()) {
    for (final pack in author.listSync().whereType<Directory>()) {
      final src = PackSidecar.read(pack.path)?.sourcePath;
      if (src != null) {
        out[p.canonicalize(src)] = p
            .split(p.relative(pack.path, from: libraryRoot))
            .join('/');
      }
    }
  }
  return out;
}

/// Builds the default import plan; synchronous, run it in an isolate.
///
/// The source is only read. Every top-level pack becomes one item (bundles
/// carry their sub-packs along), with detected author, types and tags.
/// Packs imported before (same source path) start unselected.
///
/// [origins] maps a top-level folder name in [sourceRoot] to the archive it
/// was extracted from, so sidecars point at the archive, not a temp folder.
ImportPlan planFolderImport(
  String sourceRoot,
  String libraryRoot, {
  Map<String, String> origins = const {},
}) {
  checkRoots(sourceRoot, libraryRoot);
  final scan = scanLibrary(sourceRoot);
  final imported = importedSources(libraryRoot);
  final children = <String, List<ScannedPack>>{};
  for (final pk in scan.packs) {
    if (pk.parentId != null) {
      children.putIfAbsent(pk.parentId!, () => []).add(pk);
    }
  }
  String? originOf(String id) {
    final parts = id.split('/');
    final archive = origins[parts.first];
    if (archive == null) return null;
    return parts.length == 1 ? archive : p.joinAll([archive, ...parts.skip(1)]);
  }

  final items = [
    for (final pk in scan.packs.where((x) => x.parentId == null))
      ImportItem(
        sourcePath: pk.path,
        sourceRel: pk.id,
        title: pk.title,
        author: pk.author,
        types: pk.types,
        tags: pk.tags,
        isContainer: pk.isContainer,
        subPackCount: children[pk.id]?.length ?? 0,
        fileCount:
            pk.files.length +
            (children[pk.id] ?? const []).fold(0, (n, c) => n + c.files.length),
        totalBytes:
            pk.totalBytes +
            (children[pk.id] ?? const []).fold(0, (n, c) => n + c.totalBytes),
        origin: originOf(pk.id),
        importedAs: imported[p.canonicalize(originOf(pk.id) ?? pk.path)],
      ),
  ];
  return ImportPlan(sourceRoot, libraryRoot, items);
}

/// What happened to one pack.
class ImportOutcome {
  const ImportOutcome({
    required this.title,
    required this.target,
    required this.sourceFiles,
    required this.copiedFiles,
    required this.bytes,
    required this.mismatches,
    this.error,
  });

  final String title;

  /// Library-relative target path.
  final String target;
  final int sourceFiles;
  final int copiedFiles;
  final int bytes;

  /// Files whose checksum differed after copying.
  final List<String> mismatches;
  final String? error;

  bool get verified =>
      error == null && mismatches.isEmpty && sourceFiles == copiedFiles;
}

/// Source files that belong in the pack copy: hidden entries are skipped,
/// and the pack's own author file and sidecar are rewritten by the app.
List<String> _packFiles(String root) {
  final out = <String>[];
  void walk(Directory d, String rel) {
    for (final e in d.listSync(followLinks: false)) {
      final name = p.basename(e.path);
      if (name.startsWith('.')) continue;
      final r = rel.isEmpty ? name : '$rel/$name';
      if (e is Directory) {
        walk(e, r);
      } else if (e is File &&
          !(rel.isEmpty && (name == authorFileName || name == packFileName))) {
        out.add(r);
      }
    }
  }

  walk(Directory(root), '');
  out.sort();
  return out;
}

/// Copies one pack into the library and verifies it; synchronous, run it in
/// an isolate.
///
/// Files are copied into `<library>/.staging/` first, checked by SHA-1
/// against the source, given their sidecar, and only then renamed to
/// [targetRel]. The author file at `<library>/<Author>/` is created or has
/// missing fields filled in. The source is never written to.
ImportOutcome importItem(
  ImportItem item,
  String libraryRoot,
  String targetRel,
) {
  final target = p.join(libraryRoot, targetRel);
  final staging = Directory(
    p.join(
      libraryRoot,
      '.staging',
      '${p.basename(target)}-${DateTime.now().microsecondsSinceEpoch}',
    ),
  );
  var copied = 0;
  var bytes = 0;
  final mismatches = <String>[];
  List<String> files = const [];
  try {
    checkRoots(item.sourcePath, libraryRoot);
    if (FileSystemEntity.typeSync(target) != FileSystemEntityType.notFound) {
      throw StateError('Target already exists: $targetRel');
    }
    files = _packFiles(item.sourcePath);
    for (final rel in files) {
      final src = File(p.join(item.sourcePath, rel));
      final dst = File(p.join(staging.path, rel));
      dst.parent.createSync(recursive: true);
      final data = src.readAsBytesSync();
      dst.writeAsBytesSync(data, flush: true);
      if (sha1.convert(data) != sha1.convert(dst.readAsBytesSync())) {
        mismatches.add(rel);
      }
      copied++;
      bytes += data.length;
    }
    if (mismatches.isNotEmpty) {
      throw StateError('${mismatches.length} files failed verification');
    }

    final existing = PackSidecar.read(item.sourcePath) ?? const PackSidecar();
    existing
        .copyWith(
          title: item.title,
          types: item.types,
          tags: item.tags,
          source: PackSource.imported,
          sourcePath: item.origin ?? p.canonicalize(item.sourcePath),
          isContainer: item.isContainer,
        )
        .write(staging.path);

    final authorDir = Directory(p.dirname(target))..createSync(recursive: true);
    if (item.author != null) _mergeAuthor(authorDir.path, item.author!);
    staging.renameSync(target);
  } catch (e) {
    if (staging.existsSync()) staging.deleteSync(recursive: true);
    return ImportOutcome(
      title: item.title,
      target: targetRel,
      sourceFiles: files.length,
      copiedFiles: copied,
      bytes: bytes,
      mismatches: mismatches,
      error: '$e',
    );
  } finally {
    final stagingRoot = staging.parent;
    if (stagingRoot.existsSync() && stagingRoot.listSync().isEmpty) {
      stagingRoot.deleteSync();
    }
  }
  return ImportOutcome(
    title: item.title,
    target: targetRel,
    sourceFiles: files.length,
    copiedFiles: copied,
    bytes: bytes,
    mismatches: mismatches,
  );
}

/// Writes the author file, keeping what is there and filling gaps.
void _mergeAuthor(String dir, AuthorInfo author) {
  final current = AuthorInfo.read(p.join(dir, authorFileName));
  if (current == null) {
    author.write(dir);
    return;
  }
  final merged = AuthorInfo(
    user: current.user,
    url: current.url ?? author.url,
    itchUser: current.itchUser ?? author.itchUser,
    license: current.license ?? author.license,
    extra: {...author.extra, ...current.extra},
  );
  if (merged != current || merged.extra.length != current.extra.length) {
    merged.write(dir);
  }
}

/// Imports the selected items one by one, each copy in a background
/// isolate, yielding an outcome per pack.
Stream<ImportOutcome> runImport(ImportPlan plan) async* {
  for (final MapEntry(key: item, value: target) in plan.targets().entries) {
    yield await _importInBackground(item, plan.libraryRoot, target);
  }
}

/// Top-level so the isolate closure captures nothing but its arguments.
Future<ImportOutcome> _importInBackground(
  ImportItem item,
  String libraryRoot,
  String target,
) => Isolate.run(() => importItem(item, libraryRoot, target));
