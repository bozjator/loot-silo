import 'fs_tree.dart';

enum AssetType {
  character('character'),
  environment('environment'),
  ui('ui'),
  icons('icons'),
  vfx('vfx'),
  sfx('sfx'),
  music('music'),
  threeD('3d'),
  font('font'),
  misc('misc');

  const AssetType(this.id);

  /// Stable id used in sidecars and the index.
  final String id;

  static AssetType? fromId(String id) =>
      values.where((t) => t.id == id).firstOrNull;
}

const imageExts = {
  'png',
  'gif',
  'jpg',
  'jpeg',
  'webp',
  'bmp',
  'aseprite',
  'ase',
  'psd',
  'svg',
  'tga',
};
const audioExts = {'ogg', 'wav', 'mp3', 'flac', 'm4a', 'aiff', 'opus'};
const modelExts = {
  'glb',
  'gltf',
  'fbx',
  'obj',
  'blend',
  'dae',
  'stl',
  '3ds',
  'vox',
};
const fontExts = {'ttf', 'otf', 'woff', 'woff2', 'fnt'};

/// Splits a path or name into lowercase words, breaking on separators
/// and camelCase (`FreeCharactersPack` → free, characters, pack).
List<String> pathWords(String s) => s
    .replaceAllMapped(RegExp(r'([a-z])([A-Z])'), (m) => '${m[1]} ${m[2]}')
    .toLowerCase()
    .split(RegExp(r'[^a-z0-9]+'))
    .where((w) => w.isNotEmpty)
    .toList();

bool _matches(String word, Set<String> keys) =>
    keys.contains(word) ||
    (word.endsWith('s') && keys.contains(word.substring(0, word.length - 1))) ||
    (word.endsWith('es') && keys.contains(word.substring(0, word.length - 2)));

const _imageKeywords = <AssetType, Set<String>>{
  AssetType.character: {
    'character',
    'char',
    'hero',
    'player',
    'enemy',
    'enemie',
    'monster',
    'npc', //
    'knight', 'orc', 'skeleton', 'slime', 'goblin', 'mage', 'wizard',
    'archer', 'soldier', 'human', 'creature', 'animal', 'bandit', 'warrior',
    'villager', 'boss', 'mob', 'portrait', 'avatar', 'idle', 'walk', 'run',
    'attack', 'death', 'hurt',
  },
  AssetType.environment: {
    'tile', 'tileset', 'tilemap', 'environment', 'terrain', 'background', //
    'bg', 'map', 'prop', 'building', 'nature', 'dungeon', 'village', 'forest',
    'platformer', 'interior', 'house', 'tree', 'ground', 'wall', 'parallax',
    'foliage', 'isometric', 'level', 'world', 'town', 'harbor', 'land',
  },
  AssetType.ui: {
    'ui', 'gui', 'hud', 'button', 'panel', 'menu', 'bar', 'slot', 'cursor', //
    'window', 'dialog', 'dialogue', 'gamepad', 'controller', 'prompt',
    'onscreen', 'minimap', 'frame', 'banner', 'scroll', 'parchment',
  },
  AssetType.icons: {'icon', 'item', 'items', 'inventory', 'loot'},
  AssetType.vfx: {
    'effect', 'vfx', 'fx', 'particle', 'explosion', 'magic', 'spell', //
    'projectile', 'smoke', 'fire', 'spark', 'impact', 'slash', 'hit',
  },
};

const _musicKeywords = {
  'music', 'bgm', 'loop', 'theme', 'tune', 'song', 'track', 'ost', //
  'soundtrack', 'melody', 'jingle', 'tunes',
};

const _sfxKeywords = {
  'sfx', 'sound', 'fx', 'effect', 'foley', 'footstep', 'ambience', //
  'ambient', 'impact', 'hit', 'click', 'voice', 'ui',
};

/// Audio files bigger than this are treated as music when no name keyword
/// decides it; real sfx are almost always short.
const _musicSizeBytes = 1500000;

/// Decides sfx vs music for one audio file. Word levels are checked from
/// the most specific (the file's own path) to the least (folders above the
/// pack); within a level sfx words win, so "Cozy FX" under `music/` is sfx.
AssetType _audioType(List<List<String>> levels, int size) {
  for (final words in levels) {
    if (words.any((w) => _matches(w, _sfxKeywords))) return AssetType.sfx;
    if (words.any((w) => _matches(w, _musicKeywords))) return AssetType.music;
  }
  return size > _musicSizeBytes ? AssetType.music : AssetType.sfx;
}

/// Suggests asset types for a pack from its file mix and names.
///
/// [packPath] is the pack's path below the scan root; its last segment is
/// the pack name and the rest are category folders.
///
/// Every file votes for one type: by extension for 3d and fonts, by name
/// words and size for audio, and by path keywords for images. For packs
/// that are mostly images, keywords in the pack path add an extra quarter
/// of the votes. Types with at least 15 % of the votes are returned,
/// strongest first.
List<AssetType> classifyPack(
  String packPath,
  Iterable<(String, FileEntry)> files,
) {
  final votes = <AssetType, double>{};
  void vote(AssetType t, [double w = 1]) => votes[t] = (votes[t] ?? 0) + w;
  final packWords = pathWords(packPath);
  final segments = packPath.split('/');
  final nameWords = pathWords(segments.last);
  final ancestorWords = pathWords(segments.take(segments.length - 1).join(' '));

  AssetType? keywordType(List<String> words) {
    for (final entry in _imageKeywords.entries) {
      if (words.any((w) => _matches(w, entry.value))) return entry.key;
    }
    return null;
  }

  var total = 0;
  for (final (rel, f) in files) {
    final ext = f.ext;
    if (modelExts.contains(ext)) {
      vote(AssetType.threeD);
    } else if (fontExts.contains(ext)) {
      vote(AssetType.font);
    } else if (audioExts.contains(ext)) {
      vote(_audioType([pathWords(rel), nameWords, ancestorWords], f.size));
    } else if (imageExts.contains(ext)) {
      vote(
        keywordType(pathWords(rel)) ?? keywordType(packWords) ?? AssetType.misc,
      );
    } else {
      continue;
    }
    total++;
  }
  if (total == 0) return const [AssetType.misc];

  final audio = (votes[AssetType.sfx] ?? 0) + (votes[AssetType.music] ?? 0);
  if (audio < total / 2) {
    for (final entry in _imageKeywords.entries) {
      if (packWords.any((w) => _matches(w, entry.value))) {
        vote(entry.key, total * 0.25);
      }
    }
  }
  final sum = votes.values.fold<double>(0, (a, b) => a + b);
  final ranked = votes.entries.where((e) => e.value / sum >= 0.15).toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  final types = [for (final e in ranked) e.key];
  if (types.length > 1) types.remove(AssetType.misc);
  return types.isEmpty ? const [AssetType.misc] : types;
}

/// Generic folder-word → tag map used to turn source paths into tags.
const tagKeywords = <String, String>{
  'character': 'character', 'char': 'character', 'hero': 'character', //
  'enemy': 'enemy', 'enemie': 'enemy', 'monster': 'monster',
  'environment': 'environment', 'tileset': 'tileset', 'tile': 'tileset',
  'ui': 'ui', 'gui': 'ui', 'hud': 'ui', 'icon': 'icons',
  'sfx': 'sfx', 'sound': 'sfx', 'music': 'music', 'bgm': 'music',
  'vfx': 'vfx', 'effect': 'vfx', 'fx': 'vfx', 'particle': 'vfx',
  'font': 'font', '3d': '3d', '2d': '2d',
  'pixel': 'pixel-art', 'pixelart': 'pixel-art', 'rpg': 'rpg',
  'platformer': 'platformer', 'topdown': 'top-down', 'isometric': 'isometric',
  'scifi': 'sci-fi', 'space': 'space', 'fantasy': 'fantasy',
  'medieval': 'medieval', 'horror': 'horror', 'cozy': 'cozy', 'cosy': 'cozy',
  'retro': 'retro', 'chiptune': 'chiptune', '16bit': '16-bit', '8bit': '8-bit',
  'ambience': 'ambience', 'ambiences': 'ambience', 'footstep': 'footsteps',
  'animation': 'animated', 'animated': 'animated', 'spritesheet': 'spritesheet',
};

/// Suggests tags from the folder names above a pack and its title.
List<String> suggestTags(String relativePath) {
  final lower = relativePath.toLowerCase();
  final words = pathWords(relativePath);
  final tags = <String>{
    for (final w in words)
      ?(tagKeywords[w] ??
          (w.endsWith('s') ? tagKeywords[w.substring(0, w.length - 1)] : null)),
  };
  // Compound words the splitter breaks apart.
  if (lower.contains('sci-fi') || lower.contains('scifi')) tags.add('sci-fi');
  if (lower.contains('top-down') || lower.contains('topdown')) {
    tags.add('top-down');
  }
  if (RegExp(r'16[ -]?bit').hasMatch(lower)) tags.add('16-bit');
  if (RegExp(r'8[ -]?bit').hasMatch(lower)) tags.add('8-bit');
  if (lower.contains('pixel art') || lower.contains('pixelart')) {
    tags.add('pixel-art');
  }
  // "Sound Effects" / "Cozy FX" are audio, not visual effects.
  if (tags.contains('sfx') || tags.contains('music')) tags.remove('vfx');
  return tags.toList()..sort();
}
