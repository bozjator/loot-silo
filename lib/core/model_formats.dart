import 'package:path/path.dart' as p;

import 'audio_formats.dart' show formatOf;
import 'model_mesh.dart' show readableModelExts;

/// Model formats in the order a card picks one: the ones the app can draw
/// first (GLB, glTF, OBJ), then the ones it only lists.
const modelFormatOrder = [
  'glb',
  'gltf',
  'obj',
  'fbx',
  'dae',
  'stl',
  'blend',
  '3ds',
  'vox',
];

/// A folder that only sorts files by format (`GLTF format`, `OBJ format`,
/// `glb`, `FBX files`).
final _formatFolder = RegExp(
  r'^(gltf|glb|obj|fbx|dae|collada|stl|blend|3ds|vox)'
  r'([ _-]?(files?|formats?|versions?|models?))?$',
  caseSensitive: false,
);

/// One model, saved in one or more formats.
class ModelItem {
  ModelItem(this.key, this.files);

  /// What its files share: the path without the extension and without
  /// format folders, lowercased.
  final String key;

  /// Pack-relative paths, one per format, in [modelFormatOrder].
  final List<String> files;

  /// The files the app can draw, best first.
  List<String> get readable => [
    for (final f in files)
      if (readableModelExts.contains(formatOf(f))) f,
  ];

  /// The file a card draws first; null when none is readable.
  String? get shown => readable.firstOrNull;

  /// The model's folder with the format folders left out; '.' at the top.
  String get folder {
    final kept = [
      for (final s in p.posix.split(p.posix.dirname(files.first)))
        if (s != '.' && !_formatFolder.hasMatch(s)) s,
    ];
    return kept.isEmpty ? '.' : p.posix.joinAll(kept);
  }

  /// [folder] / the first file's name: where "By folder" groups the model.
  String get groupPath {
    final f = folder;
    final name = p.posix.basename(files.first);
    return f == '.' ? name : '$f/$name';
  }
}

String _keyOf(String rel) {
  final parts = p.posix.split(p.posix.withoutExtension(rel));
  return [
    for (var i = 0; i < parts.length; i++)
      if (i == parts.length - 1 || !_formatFolder.hasMatch(parts[i])) parts[i],
  ].join('/').toLowerCase();
}

int _rank(String rel) {
  final i = modelFormatOrder.indexOf(formatOf(rel));
  return i < 0 ? modelFormatOrder.length : i;
}

/// [models] (pack-relative paths) as models: files that differ only in
/// their extension, or in a format folder (`GLTF format/a.glb`,
/// `OBJ format/a.obj`), are one model. Models keep the order of their first
/// file in [models].
List<ModelItem> groupModelFormats(List<String> models) {
  final byKey = <String, List<String>>{};
  for (final rel in models) {
    final files = byKey.putIfAbsent(_keyOf(rel), () => []);
    // Two files of one format (`a.obj`, `A.OBJ`) stay apart.
    if (files.any((f) => formatOf(f) == formatOf(rel))) {
      byKey.putIfAbsent(rel.toLowerCase(), () => []).add(rel);
    } else {
      files.add(rel);
    }
  }
  return [
    for (final MapEntry(:key, :value) in byKey.entries)
      ModelItem(key, value..sort((a, b) => _rank(a) - _rank(b))),
  ];
}
