import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// The pack page tabs that have a "By folder" view.
enum FoldTab { images, animations }

/// Which folders are collapsed in each pack's "By folder" views, remembered
/// across launches in `ui_state.json`. Keyed by the pack's folder path, so
/// two libraries never share an entry.
///
/// Only collapsed folders are kept: a folder added to a pack later shows up
/// open. A pack/tab with nothing collapsed has no entry. Folder names that
/// no longer exist are harmless (nothing matches them); packs that are gone
/// are dropped by [prune] after each library load.
class FolderFolds {
  /// With no [file] (tests) the folds live in memory only.
  FolderFolds([this.file]) : _packs = _read(file);

  final File? file;
  final Map<String, Map<FoldTab, Set<String>>> _packs;

  /// The collapsed folders of [packPath]'s [tab]; a copy, so edit it freely
  /// and hand it back to [set].
  Set<String> of(String packPath, FoldTab tab) => {...?_packs[packPath]?[tab]};

  /// Remembers [collapsed] as the collapsed folders of [packPath]'s [tab].
  void set(String packPath, FoldTab tab, Set<String> collapsed) {
    final tabs = _packs[packPath];
    final old = tabs?[tab] ?? const <String>{};
    if (old.length == collapsed.length && old.containsAll(collapsed)) return;
    if (collapsed.isEmpty) {
      tabs!.remove(tab);
      if (tabs.isEmpty) _packs.remove(packPath);
    } else {
      (_packs[packPath] ??= {})[tab] = {...collapsed};
    }
    _write();
  }

  /// Forgets the packs inside [root] that aren't in [packPaths] (deleted or
  /// moved). Entries of other libraries are kept.
  void prune(String root, Iterable<String> packPaths) {
    final keep = packPaths.toSet();
    final before = _packs.length;
    _packs.removeWhere(
      (path, _) => p.isWithin(root, path) && !keep.contains(path),
    );
    if (_packs.length != before) _write();
  }

  static Map<String, Map<FoldTab, Set<String>>> _read(File? file) {
    final packs = <String, Map<FoldTab, Set<String>>>{};
    if (file == null) return packs;
    try {
      final json = jsonDecode(file.readAsStringSync());
      if (json is! Map<String, Object?>) return packs;
      if (json['collapsed_folders'] case final Map<String, Object?> byPack) {
        for (final MapEntry(key: path, value: tabs) in byPack.entries) {
          if (tabs is! Map<String, Object?>) continue;
          final read = <FoldTab, Set<String>>{
            for (final MapEntry(:key, :value) in tabs.entries)
              if (FoldTab.values.asNameMap()[key] case final tab?)
                if (value is List<Object?>) tab: {...value.whereType<String>()},
          }..removeWhere((_, s) => s.isEmpty);
          if (read.isNotEmpty) packs[path] = read;
        }
      }
    } on FileSystemException {
      // First run.
    } on FormatException {
      // Corrupt file; start fresh.
    }
    return packs;
  }

  void _write() {
    final file = this.file;
    if (file == null) return;
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert({
        'collapsed_folders': {
          for (final MapEntry(key: path, value: tabs) in _packs.entries)
            path: {
              for (final MapEntry(:key, :value) in tabs.entries)
                key.name: [...value]..sort(),
            },
        },
      }),
    );
  }
}
