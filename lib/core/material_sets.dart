import 'package:path/path.dart' as p;

/// What one map (texture) of a material holds.
enum MapRole {
  color('Color', 'Color'),
  normalGL('Normal (GL)', 'Normal'),
  normalDX('Normal (DX)', 'Normal DX'),
  roughness('Roughness', 'Roughness'),
  metalness('Metalness', 'Metalness'),
  ao('AO', 'AO'),
  height('Height', 'Height'),
  opacity('Opacity', 'Opacity'),
  emission('Emission', 'Emission'),
  specular('Specular', 'Specular'),
  packed('Packed (ARM)', 'ARM'),

  /// Named by a `.mtlx` without a role the app knows.
  other('Map', 'Map');

  const MapRole(this.label, this.chip);

  final String label;

  /// The short form on a card's chip.
  final String chip;

  bool get isNormal => this == normalGL || this == normalDX;
}

/// One map of a material: its role and pack-relative path.
class MaterialMap {
  const MaterialMap(this.role, this.path);

  final MapRole role;
  final String path;

  @override
  bool operator ==(Object other) =>
      other is MaterialMap && other.role == role && other.path == path;

  @override
  int get hashCode => Object.hash(role, path);

  @override
  String toString() => 'MaterialMap(${role.name}, $path)';
}

/// One PBR material: its maps, the preview the pack ships (if any) and the
/// same material saved for other tools (`.mtlx`, `.tres`, `.blend`…).
class MaterialSet {
  const MaterialSet({
    required this.key,
    required this.name,
    required this.maps,
    this.preview,
    this.toolFiles = const [],
    this.resolution,
  });

  /// Pack-relative path of the material without suffix, resolution tag or
  /// extension (`Rock/PavingStones138`). Favorites store it.
  final String key;

  /// The material's own name (`PavingStones138`).
  final String name;

  /// In [MapRole] order.
  final List<MaterialMap> maps;

  /// The rendered picture the pack ships (`PavingStones138.png`).
  final String? preview;

  /// Files for other tools, sorted.
  final List<String> toolFiles;

  /// `1K`, `2K`… from the file names or the Color map's width.
  final String? resolution;

  /// '.' at the pack's top.
  String get folder => p.posix.dirname(key);

  /// Where "By folder" groups the material: [folder] / [name].
  String get groupPath => key;

  MaterialMap? mapOf(MapRole role) =>
      maps.where((m) => m.role == role).firstOrNull;

  /// The Color map, else null.
  String? get color => mapOf(MapRole.color)?.path;

  /// The preview, then the maps: what the image viewer steps through.
  List<String> get pictures => [?preview, for (final m in maps) m.path];

  /// Every file of the material.
  List<String> get files => [...pictures, ...toolFiles];

  MaterialSet withResolution(String? r) => MaterialSet(
    key: key,
    name: name,
    maps: maps,
    preview: preview,
    toolFiles: toolFiles,
    resolution: r,
  );

  @override
  String toString() =>
      'MaterialSet($key, maps: $maps, preview: $preview, tools: $toolFiles)';
}

/// Tool formats a material may come in, by extension, with the chip label.
const materialToolFormats = {
  'mtlx': 'MaterialX',
  'tres': 'Godot',
  'usdc': 'USD',
  'usda': 'USD',
  'usdz': 'USD',
  'blend': 'Blender',
  'sbsar': 'Substance',
  'sbs': 'Substance',
  'mat': 'Unity',
};

/// Image formats a map may be in (what the engine can show).
const _mapExts = {'png', 'jpg', 'jpeg', 'webp', 'bmp', 'gif'};

/// Suffix spellings per role, as regex fragments; longer first wins.
const _aliases = <(String, MapRole)>[
  ('ambient[_ -]?occlusion', MapRole.ao),
  ('base[_ -]?colou?r', MapRole.color),
  ('normal[_ -]?gl', MapRole.normalGL),
  ('normal[_ -]?dx', MapRole.normalDX),
  ('nor[_ -]?gl', MapRole.normalGL),
  ('nor[_ -]?dx', MapRole.normalDX),
  ('displacement', MapRole.height),
  ('glossiness', MapRole.specular),
  ('roughness', MapRole.roughness),
  ('metalness', MapRole.metalness),
  ('occlusion', MapRole.ao),
  ('metallic', MapRole.metalness),
  ('emissive', MapRole.emission),
  ('emission', MapRole.emission),
  ('specular', MapRole.specular),
  ('diffuse', MapRole.color),
  ('opacity', MapRole.opacity),
  ('albedo', MapRole.color),
  ('colour', MapRole.color),
  ('normal', MapRole.normalGL),
  ('height', MapRole.height),
  ('color', MapRole.color),
  ('alpha', MapRole.opacity),
  ('metal', MapRole.metalness),
  ('rough', MapRole.roughness),
  ('gloss', MapRole.specular),
  ('bump', MapRole.height),
  ('diff', MapRole.color),
  ('norm', MapRole.normalGL),
  ('disp', MapRole.height),
  ('mask', MapRole.opacity),
  ('spec', MapRole.specular),
  ('col', MapRole.color),
  ('dif', MapRole.color),
  ('nor', MapRole.normalGL),
  ('nrm', MapRole.normalGL),
  ('rgh', MapRole.roughness),
  ('arm', MapRole.packed),
  ('orm', MapRole.packed),
  ('ao', MapRole.ao),
];

/// Any known suffix at the end, to skip most names with one test.
final _anySuffix = RegExp(
  '(?:${[for (final (alias, _) in _aliases) alias].join('|')})\$',
  caseSensitive: false,
);

final _suffixRes = [
  for (final (alias, role) in _aliases)
    (RegExp('([_\\- ]?)($alias)\$', caseSensitive: false), role),
];

/// A resolution tag at the end of a name: `_1K`, `_2K-JPG`, `-4k`.
final _resTag = RegExp(
  r'[_\- ]?(\d{1,2})k(?:[_\- ]?(?:jpe?g|png|exr|tga|tiff?|webp))?$',
  caseSensitive: false,
);

final _previewWord = RegExp(r'[_\- ]?(preview|sphere)$', caseSensitive: false);
final _upper = RegExp('[A-Z]');

/// [stem] without a trailing resolution tag, and the tag (`1K`).
(String, String?) _stripRes(String stem) {
  final m = _resTag.firstMatch(stem);
  if (m == null || m.start == 0) return (stem, null);
  return (stem.substring(0, m.start), '${m[1]}K');
}

String _trimSeparators(String s) => s.replaceAll(RegExp(r'[_\- ]+$'), '');

/// A map's name split: (material name, role, resolution tag), or null when
/// the name has no known suffix.
(String, MapRole, String?)? _parseMap(String stem) {
  final (rest, res) = _stripRes(stem);
  if (!_anySuffix.hasMatch(rest)) return null;
  for (final (re, role) in _suffixRes) {
    final m = re.firstMatch(rest);
    if (m == null) continue;
    final prefix = rest.substring(0, m.start);
    if (prefix.isEmpty) continue;
    // With no separator the suffix must start a camelCase word, so
    // `Protocol` is not "Proto" + Col.
    if (m[1]!.isEmpty) {
      final last = prefix[prefix.length - 1];
      if (!_upper.hasMatch(m[2]![0]) || _upper.hasMatch(last)) continue;
    }
    final (name, res2) = _stripRes(_trimSeparators(prefix));
    final trimmed = _trimSeparators(name);
    if (trimmed.isEmpty) continue;
    return (trimmed, role, res ?? res2);
  }
  return null;
}

final _trailingNumber = RegExp(r'[_\- ]?\d+$');

/// [rel]'s name ends in a texture-map suffix (`_gloss`, `_Normal`,
/// `_mask01`, `_rough_2K`): a map rather than a picture of the pack,
/// whether or not it forms a material.
bool looksLikeMap(String rel) {
  final stem = p.posix.basenameWithoutExtension(rel);
  if (_parseMap(stem) != null) return true;
  final bare = stem.replaceFirst(_trailingNumber, '');
  return bare != stem && bare.isNotEmpty && _parseMap(bare) != null;
}

String _ext(String rel) =>
    p.posix.extension(rel).toLowerCase().replaceFirst('.', '');

String _keyIn(String folder, String name) =>
    (folder == '.' ? name : '$folder/$name').toLowerCase();

/// Groups [files] (pack-relative paths) into materials. Maps share a name
/// plus a known suffix (`Wood_Color.png`, `Wood_Normal.png`); a group needs
/// two maps, one of them Color or Normal. A `.mtlx` whose text is in
/// [mtlx] (by path) names its maps itself, with their roles. Previews
/// (`Wood.png`, `Wood_preview.png`) and tool files (`Wood.blend`) of a
/// material join it.
///
/// Returns the materials (sorted by key) and the files no material took,
/// in their order in [files].
(List<MaterialSet>, List<String>) groupMaterials(
  List<String> files, {
  Map<String, String> mtlx = const {},
}) {
  // By lowercased key: maps, display name and resolution tag.
  final maps = <String, List<MaterialMap>>{};
  final names = <String, String>{};
  final resolutions = <String, String>{};
  final confirmed = <String>{};
  final mapKey = <String, String>{};
  final keys = <String, String>{};

  void addMap(String folder, String name, MaterialMap m, String? res) {
    final key = _keyIn(folder, name);
    maps.putIfAbsent(key, () => []).add(m);
    names.putIfAbsent(key, () => name);
    keys.putIfAbsent(key, () => folder == '.' ? name : '$folder/$name');
    if (res != null) resolutions.putIfAbsent(key, () => res);
    mapKey[m.path] = key;
  }

  final images = [
    for (final f in files)
      if (_mapExts.contains(_ext(f))) f,
  ];
  for (final rel in images) {
    final parsed = _parseMap(p.posix.basenameWithoutExtension(rel));
    if (parsed == null) continue;
    final (name, role, res) = parsed;
    final folder = p.posix.dirname(rel);
    addMap(folder, name, MaterialMap(role, rel), res);
  }

  // A `.mtlx` names its maps: they are one material, whatever their names.
  final byLower = {for (final f in images) f.toLowerCase(): f};
  for (final MapEntry(key: rel, value: xml) in mtlx.entries) {
    final folder = p.posix.dirname(rel);
    final (stem, res) = _stripRes(p.posix.basenameWithoutExtension(rel));
    final name = _trimSeparators(stem);
    final key = _keyIn(folder, name);
    for (final (file, role) in readMtlxMaps(xml)) {
      final path = p.posix.normalize(p.posix.join(folder, file));
      final image = byLower[path.toLowerCase()];
      if (image == null) continue;
      final from = mapKey[image];
      final old = from == null
          ? null
          : maps[from]!.firstWhere((m) => m.path == image);
      if (from != null) maps[from]!.remove(old);
      var r = role ?? old?.role ?? MapRole.other;
      // The `.mtlx` says "normal"; the name says which convention.
      if (r == MapRole.normalGL && old?.role == MapRole.normalDX) {
        r = MapRole.normalDX;
      }
      addMap(folder, name, MaterialMap(r, image), res);
      confirmed.add(key);
    }
  }

  final kept = <String>{
    for (final MapEntry(:key, :value) in maps.entries)
      if (confirmed.contains(key) && value.isNotEmpty ||
          value.length >= 2 &&
              value.any((m) => m.role == MapRole.color || m.role.isNormal))
        key,
  };
  if (kept.isEmpty) return (const <MaterialSet>[], files);
  final taken = <String>{
    for (final k in kept) ...[for (final m in maps[k]!) m.path],
  };

  // Previews and tool files named like a material.
  final previews = <String, String>{};
  final tools = <String, List<String>>{};
  for (final rel in files) {
    if (taken.contains(rel)) continue;
    final ext = _ext(rel);
    final folder = p.posix.dirname(rel);
    final (stem, _) = _stripRes(p.posix.basenameWithoutExtension(rel));
    if (_mapExts.contains(ext)) {
      final key = _keyIn(folder, _trimSeparators(stem));
      final word = _previewWord.firstMatch(stem);
      final bare = word == null
          ? null
          : _keyIn(
              folder,
              _trimSeparators(_stripRes(stem.substring(0, word.start)).$1),
            );
      for (final k in [key, ?bare]) {
        if (kept.contains(k) && !previews.containsKey(k)) {
          previews[k] = rel;
          taken.add(rel);
          break;
        }
      }
    } else if (materialToolFormats.containsKey(ext)) {
      final key = _keyIn(folder, _trimSeparators(stem));
      if (kept.contains(key)) {
        tools.putIfAbsent(key, () => []).add(rel);
        taken.add(rel);
      }
    }
  }

  final sets = [
    for (final k in kept)
      MaterialSet(
        key: keys[k]!,
        name: names[k]!,
        maps: maps[k]!..sort(_byRole),
        preview: previews[k],
        toolFiles: (tools[k] ?? [])..sort(),
        resolution: resolutions[k],
      ),
  ]..sort((a, b) => a.key.toLowerCase().compareTo(b.key.toLowerCase()));
  return (
    sets,
    [
      for (final f in files)
        if (!taken.contains(f)) f,
    ],
  );
}

int _byRole(MaterialMap a, MaterialMap b) {
  final r = a.role.index - b.role.index;
  return r != 0 ? r : a.path.compareTo(b.path);
}

/// Shader inputs (MaterialX standard_surface / OpenPBR / UsdPreviewSurface
/// names) and the role of a map feeding them.
const _inputRoles = {
  'base_color': MapRole.color,
  'basecolor': MapRole.color,
  'diffusecolor': MapRole.color,
  'diffuse_color': MapRole.color,
  'geometry_normal': MapRole.normalGL,
  'normal': MapRole.normalGL,
  'coat_normal': MapRole.normalGL,
  'specular_roughness': MapRole.roughness,
  'roughness': MapRole.roughness,
  'metalness': MapRole.metalness,
  'base_metalness': MapRole.metalness,
  'metallic': MapRole.metalness,
  'displacement': MapRole.height,
  'opacity': MapRole.opacity,
  'geometry_opacity': MapRole.opacity,
  'emission_color': MapRole.emission,
  'emissive': MapRole.emission,
  'emissivecolor': MapRole.emission,
  'occlusion': MapRole.ao,
  'specular_color': MapRole.specular,
  'specularcolor': MapRole.specular,
};

final _tag = RegExp(r'<(/?)([\w:.-]+)((?:\s+[\w:.-]+\s*=\s*"[^"]*")*)\s*(/?)>');
final _attr = RegExp(r'([\w:.-]+)\s*=\s*"([^"]*)"');

String _unescape(String s) => s
    .replaceAll('&quot;', '"')
    .replaceAll('&apos;', "'")
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&amp;', '&');

/// The image files a MaterialX document reads (`<input type="filename"
/// value=…>`), relative to it (after `fileprefix`), each with the role of
/// the shader input it ends up in (followed through `normalmap` and other
/// nodes), or null when it feeds none the app knows. A plain scan, no XML
/// package: tags and their attributes are all it needs.
List<(String, MapRole?)> readMtlxMaps(String xml) {
  final stack = <(String, Map<String, String>)>[];
  // Image node name → file; node name → (consumer name, input name).
  final files = <(String, String)>[];
  final feeds = <String, List<(String, String)>>{};
  var prefix = '';
  for (final m in _tag.allMatches(xml)) {
    final closing = m[1] == '/';
    final tag = m[2]!;
    if (closing) {
      if (stack.isNotEmpty) stack.removeLast();
      continue;
    }
    final attrs = {
      for (final a in _attr.allMatches(m[3] ?? '')) a[1]!: _unescape(a[2]!),
    };
    final selfClosing = m[4] == '/';
    if (tag == 'materialx' || tag == 'nodegraph') {
      final fp = attrs['fileprefix'];
      if (fp != null && tag == 'materialx') prefix = fp;
    }
    if (tag == 'input' && stack.isNotEmpty) {
      final (_, parent) = stack.last;
      final parentName = parent['name'] ?? '';
      if (attrs['type'] == 'filename' && attrs['value'] != null) {
        files.add((parentName, attrs['value']!));
      }
      if (attrs['nodename'] case final from?) {
        feeds.putIfAbsent(from, () => []).add((
          parentName,
          (attrs['name'] ?? '').toLowerCase(),
        ));
      }
    }
    if (!selfClosing) stack.add((tag, attrs));
  }

  MapRole? roleOf(String node) {
    final seen = <String>{node};
    var front = [node];
    for (var depth = 0; depth < 6 && front.isNotEmpty; depth++) {
      final next = <String>[];
      for (final n in front) {
        for (final (consumer, input)
            in feeds[n] ?? const <(String, String)>[]) {
          if (_inputRoles[input] case final role?) return role;
          if (seen.add(consumer)) next.add(consumer);
        }
      }
      front = next;
    }
    return null;
  }

  final cleanPrefix = prefix == './' ? '' : prefix;
  return [
    for (final (node, file) in files)
      (p.posix.normalize('$cleanPrefix$file'), roleOf(node)),
  ];
}

/// A material's name for display: separators to spaces, camelCase and
/// numbers split (`PavingStones138` → `Paving Stones 138`).
String materialTitle(String name) {
  final spaced = name
      .replaceAll(RegExp(r'[-_\s]+'), ' ')
      .replaceAllMapped(RegExp(r'([a-z])([A-Z])'), (m) => '${m[1]} ${m[2]}')
      .replaceAllMapped(RegExp(r'([A-Za-z])(\d)'), (m) => '${m[1]} ${m[2]}')
      .trim();
  if (spaced.isEmpty) return name;
  return spaced[0].toUpperCase() + spaced.substring(1);
}
