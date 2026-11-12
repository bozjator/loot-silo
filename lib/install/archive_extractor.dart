import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;

import 'folder_importer.dart' show safeFolderName;

enum ArchiveKind { zip, tar, tarGz, sevenZip, rar }

/// The format of [path] judged by its extension, or null if unsupported.
ArchiveKind? archiveKindOf(String path) {
  final name = p.basename(path).toLowerCase();
  if (name.endsWith('.tar.gz') || name.endsWith('.tgz')) {
    return ArchiveKind.tarGz;
  }
  return switch (p.extension(name)) {
    '.zip' => ArchiveKind.zip,
    '.tar' => ArchiveKind.tar,
    '.7z' => ArchiveKind.sevenZip,
    '.rar' => ArchiveKind.rar,
    _ => null,
  };
}

/// Extensions offered in the "Import archive" picker.
const archiveExtensions = ['zip', 'rar', '7z', 'tar', 'tgz', 'gz'];

/// The archive's name without its extension(s): `Pack v1.tar.gz` → `Pack v1`.
String archiveStem(String path) {
  final name = p.basename(path);
  final lower = name.toLowerCase();
  for (final ext in ['.tar.gz', '.tgz', '.zip', '.tar', '.7z', '.rar']) {
    if (lower.endsWith(ext)) return name.substring(0, name.length - ext.length);
  }
  return p.basenameWithoutExtension(name);
}

/// An archive unpacked into one folder, ready for the folder importer.
class ExtractedArchive {
  const ExtractedArchive(this.archivePath, this.folder);

  final String archivePath;

  /// The normalised root folder (`<dest>/<Name>`).
  final String folder;
}

class ExtractError implements Exception {
  ExtractError(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Finds the first of [names] on PATH, plus the usual install folders:
/// 7-Zip's on Windows, and Homebrew's on macOS (an app opened from Finder
/// gets a PATH without them).
String? findTool(List<String> names, {Map<String, String>? environment}) {
  final env = environment ?? Platform.environment;
  final dirs = [
    ...(env['PATH'] ?? '').split(Platform.isWindows ? ';' : ':'),
    if (Platform.isWindows) r'C:\Program Files\7-Zip',
    if (Platform.isMacOS) ...['/opt/homebrew/bin', '/usr/local/bin'],
  ];
  for (final name in names) {
    for (final dir in dirs.where((d) => d.isNotEmpty)) {
      for (final candidate in [
        p.join(dir, name),
        if (Platform.isWindows) p.join(dir, '$name.exe'),
      ]) {
        if (File(candidate).existsSync()) return candidate;
      }
    }
  }
  return null;
}

/// macOS ships bsdtar (libarchive), which reads 7z and rar (RAR4 and
/// RAR5) but not encrypted ones; the fallback when 7-Zip and unrar are
/// missing.
String? get systemBsdtar =>
    Platform.isMacOS && File('/usr/bin/tar').existsSync()
    ? '/usr/bin/tar'
    : null;

/// How to install a tool for 7z/rar on this OS, for error messages.
String get archiveToolInstallHint {
  if (Platform.isMacOS) return 'install 7-Zip with: brew install sevenzip';
  if (Platform.isWindows) return 'install 7-Zip from https://7-zip.org';
  return 'install it (for example: sudo apt install 7zip unrar)';
}

/// Unpacks [archivePath] into a new folder under [destParent] and
/// normalises it: junk (`__MACOSX`, `.DS_Store`, `Thumbs.db`) and symlinks
/// are dropped, and chains of single folders are collapsed so the result
/// is one folder holding the content. That folder is named after the
/// archive's own single root folder if it has one, else after the archive.
///
/// Synchronous; run it in an isolate. Never writes outside [destParent].
ExtractedArchive extractArchive(String archivePath, String destParent) {
  final format = archiveKindOf(archivePath);
  if (format == null) {
    throw ExtractError('Not a supported archive: ${p.basename(archivePath)}');
  }
  Directory(destParent).createSync(recursive: true);
  final raw = Directory(
    p.join(destParent, '.raw-${DateTime.now().microsecondsSinceEpoch}'),
  )..createSync();
  try {
    switch (format) {
      case ArchiveKind.zip || ArchiveKind.tar || ArchiveKind.tarGz:
        _extractWithPackage(archivePath, format, raw.path);
      case ArchiveKind.sevenZip || ArchiveKind.rar:
        _extractWithTool(archivePath, format, raw.path);
    }
    _removeJunk(raw);
    var content = raw;
    String? rootName;
    while (true) {
      final entries = content.listSync();
      if (entries.length != 1 || entries.single is! Directory) break;
      content = entries.single as Directory;
      rootName ??= p.basename(content.path);
    }
    if (content.listSync().isEmpty) {
      throw ExtractError(
        '${p.basename(archivePath)} is empty or not a valid archive',
      );
    }
    final base = safeFolderName(rootName ?? archiveStem(archivePath));
    var target = p.join(destParent, base);
    for (var n = 2; FileSystemEntity.typeSync(target) != .notFound; n++) {
      target = p.join(destParent, '$base ($n)');
    }
    content.renameSync(target);
    return ExtractedArchive(archivePath, target);
  } finally {
    if (raw.existsSync()) raw.deleteSync(recursive: true);
  }
}

/// A safe relative path for an archive entry, or null for entries that
/// would land outside the destination (absolute paths, `..`).
String? safeEntryPath(String name) {
  final unixish = name.replaceAll(r'\', '/');
  if (unixish.startsWith('/') || RegExp(r'^[A-Za-z]:').hasMatch(unixish)) {
    return null;
  }
  final parts = <String>[];
  for (final part in unixish.split('/')) {
    if (part.isEmpty || part == '.') continue;
    if (part == '..') return null;
    parts.add(part);
  }
  return parts.isEmpty ? null : p.joinAll(parts);
}

void _extractWithPackage(String path, ArchiveKind format, String dest) {
  if (format == ArchiveKind.tarGz) {
    // Inflate next to the output first, then read it as a plain tar.
    final tar = '$dest.tar';
    try {
      final input = InputFileStream(path);
      final output = OutputFileStream(tar);
      try {
        GZipDecoder().decodeStream(input, output);
      } on Object catch (e) {
        throw ExtractError('Cannot read ${p.basename(path)}: $e');
      } finally {
        input.closeSync();
        output.closeSync();
      }
      _extractWithPackage(tar, ArchiveKind.tar, dest);
    } finally {
      final f = File(tar);
      if (f.existsSync()) f.deleteSync();
    }
    return;
  }
  final input = InputFileStream(path);
  Archive archive;
  try {
    archive = format == ArchiveKind.zip
        ? ZipDecoder().decodeStream(input)
        : TarDecoder().decodeStream(input);
  } on Object catch (e) {
    input.closeSync();
    throw ExtractError('Cannot read ${p.basename(path)}: $e');
  }
  try {
    for (final entry in archive) {
      if (entry.isSymbolicLink) continue;
      final rel = safeEntryPath(entry.name);
      if (rel == null) continue;
      final out = p.join(dest, rel);
      if (!p.isWithin(dest, out)) continue;
      if (!entry.isFile) {
        Directory(out).createSync(recursive: true);
        continue;
      }
      Directory(p.dirname(out)).createSync(recursive: true);
      final stream = OutputFileStream(out);
      try {
        entry.writeContent(stream);
      } finally {
        stream.closeSync();
      }
    }
  } finally {
    input.closeSync();
  }
}

void _extractWithTool(String path, ArchiveKind format, String dest) {
  final sevenZip = findTool(['7zz', '7z', '7za']);
  final unrar = format == ArchiveKind.rar ? findTool(['unrar']) : null;
  final bsdtar = systemBsdtar;
  final ProcessResult result;
  if (sevenZip != null) {
    // -p- fails encrypted archives instead of waiting for a password.
    result = Process.runSync(sevenZip, [
      'x',
      '-y',
      '-bd',
      '-p-',
      '-o$dest',
      path,
    ]);
  } else if (unrar != null) {
    result = Process.runSync(unrar, ['x', '-o+', '-y', '-p-', path, '$dest/']);
  } else if (bsdtar != null) {
    // bsdtar refuses absolute and `..` entries unless given -P.
    result = Process.runSync(bsdtar, ['-x', '-f', path, '-C', dest]);
  } else {
    throw ExtractError(
      'Extracting ${p.basename(path)} needs 7-Zip'
      '${format == ArchiveKind.rar ? ' or unrar' : ''}; '
      '$archiveToolInstallHint.',
    );
  }
  if (result.exitCode != 0) {
    final usedTar = sevenZip == null && unrar == null;
    final lines = [
      for (final l in '${result.stderr}'.split('\n'))
        if (l.trim().isNotEmpty) l.trim(),
    ];
    // 7-Zip and unrar end with the reason; bsdtar starts with it and ends
    // with "Error exit delayed from previous errors".
    final message = lines.isEmpty
        ? ''
        : usedTar
        ? lines.first.replaceFirst('tar: ', '')
        : lines.last;
    throw ExtractError(
      'Could not extract ${p.basename(path)}'
      '${message.isEmpty ? '' : ': $message'}'
      '${usedTar ? '. If it opens elsewhere, $archiveToolInstallHint' : ''}',
    );
  }
}

const _junkNames = {'__MACOSX', '.DS_Store', 'Thumbs.db', 'desktop.ini'};

/// Drops OS junk and every symlink (an extracted link could point outside
/// the staging folder).
void _removeJunk(Directory dir) {
  for (final e in dir.listSync(followLinks: false)) {
    if (e is Link || _junkNames.contains(p.basename(e.path))) {
      e.deleteSync(recursive: true);
    } else if (e is Directory) {
      _removeJunk(e);
    }
  }
}
