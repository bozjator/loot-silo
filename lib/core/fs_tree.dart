import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

class FileEntry {
  const FileEntry(this.name, this.size);
  final String name;
  final int size;

  String get ext => p.extension(name).toLowerCase().replaceFirst('.', '');
  String get stem => p.basenameWithoutExtension(name);
}

/// An in-memory snapshot of a directory tree.
///
/// Built once per scan so detection heuristics can look around freely
/// without touching the disk again.
class DirNode {
  DirNode(this.path, this.files, this.dirs);

  final String path;
  final List<FileEntry> files;
  final List<DirNode> dirs;

  String get name => p.basename(path);

  bool hasFile(String name) => files.any((f) => f.name == name);

  /// This node and all descendants, depth first.
  Iterable<DirNode> walk() sync* {
    yield this;
    for (final d in dirs) {
      yield* d.walk();
    }
  }

  /// Every file below this node as `(path relative to this node, entry)`.
  Iterable<(String, FileEntry)> allFiles([String prefix = '']) sync* {
    for (final f in files) {
      yield (prefix.isEmpty ? f.name : '$prefix/${f.name}', f);
    }
    for (final d in dirs) {
      yield* d.allFiles(prefix.isEmpty ? d.name : '$prefix/${d.name}');
    }
  }
}

bool _hidden(String name) => name.startsWith('.');

/// Reads the tree under [path] synchronously; run it in an isolate.
///
/// Hidden entries and symlinks are skipped, and children are sorted by name
/// so results are stable across runs.
DirNode readTree(String path) {
  final files = <FileEntry>[];
  final dirs = <DirNode>[];
  final List<FileSystemEntity> entries;
  try {
    entries = Directory(path).listSync(followLinks: false);
  } on FileSystemException {
    return DirNode(path, files, dirs);
  }
  for (final e in entries) {
    final name = p.basename(e.path);
    if (_hidden(name)) continue;
    if (e is File) {
      files.add(FileEntry(name, e.statSync().size));
    } else if (e is Directory) {
      dirs.add(readTree(e.path));
    }
  }
  files.sort((a, b) => a.name.compareTo(b.name));
  dirs.sort((a, b) => a.path.compareTo(b.path));
  return DirNode(path, files, dirs);
}

/// A cheap fingerprint of the tree under [root]: every directory path and
/// its mtime. Adding, removing or renaming any entry changes it.
///
/// Edits to a file's contents are not caught; the library is only changed
/// through the app or by copying packs in, so this is enough for a warm
/// start check.
String treeFingerprint(String root) {
  final buf = StringBuffer();
  void visit(Directory d) {
    final stat = d.statSync();
    buf.writeln('${d.path}\u0000${stat.modified.microsecondsSinceEpoch}');
    final List<FileSystemEntity> entries;
    try {
      entries = d.listSync(followLinks: false)
        ..sort((a, b) => a.path.compareTo(b.path));
    } on FileSystemException {
      return;
    }
    for (final e in entries) {
      if (e is Directory && !_hidden(p.basename(e.path))) visit(e);
    }
  }

  if (Directory(root).existsSync()) visit(Directory(root));
  return sha1.convert(utf8.encode(buf.toString())).toString();
}
