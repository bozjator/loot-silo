import 'fs_tree.dart';
import 'itch_media.dart';
import 'pack_detector.dart';
import 'type_classifier.dart' show pathWords;

/// A pack inside a bundle (M95), under its section heading (Kenney's
/// `2D assets`), or none.
class BundleChild {
  const BundleChild(this.dir, this.section);

  final DirNode dir;
  final String? section;
}

/// How a folder splits into a bundle: its packs, by section.
class BundlePlan {
  const BundlePlan(this.packs);

  final List<BundleChild> packs;

  /// The section headings, in folder order.
  List<String> get sections => {for (final c in packs) ?c.section}.toList();
}

/// Names of asset kinds, formats and actions: a folder named only by these
/// is a folder of one pack (`PNG`, `Tiles`, `Idle`, `Audio`), never a pack
/// of its own.
const _kindWords = {
  'png', 'jpg', 'jpeg', 'svg', 'gif', 'psd', 'webp', 'tga', 'bmp', //
  'vector', 'vectors', 'spritesheet', 'spritesheets', 'sprite', 'sprites',
  'sheet', 'sheets', 'tile', 'tiles', 'tileset', 'tilesets', 'tilemap',
  'tilemaps', 'atlas', 'atlases', 'character', 'characters', 'enemy',
  'enemies', 'npc', 'npcs', 'prop', 'props', 'item', 'items', 'object',
  'objects', 'icon', 'icons', 'ui', 'gui', 'hud', 'background',
  'backgrounds', 'bg', 'effect', 'effects', 'fx', 'vfx', 'sfx', 'music',
  'audio', 'sound', 'sounds', 'font', 'fonts', 'model', 'models', 'texture',
  'textures', 'material', 'materials', 'animation', 'animations', 'anim',
  'anims', 'frame', 'frames', 'idle', 'walk', 'walking', 'run', 'running',
  'jump', 'attack', 'death', 'die', 'dead', 'hurt', 'hit', 'fall', 'climb',
  'cast', 'shoot', 'dash', 'roll', 'crouch', 'block', 'slide', 'projectile',
  'proyectile', '2d', '3d', 'obj', 'fbx', 'gltf', 'glb', 'blend', 'dae',
  'stl', 'ogg', 'wav', 'mp3', 'flac', 'source', 'sources', 'src', 'extra',
  'extras', 'other', 'misc', 'asset', 'assets', 'file', 'files',
  'isometric', 'topdown', 'side', 'left', 'right', 'up', 'down', 'front',
  'back', 'separate', 'separated', 'single', 'individual', 'large', 'small',
  'medium', 'map', 'maps', 'scene', 'scenes', 'demo', 'example', 'examples',
};

/// Version and edition words, left out when comparing names for editions
/// of one pack (`… v1.03 -Free Soldier&Orc`, `… -Full 20 Characters`).
const _editionWords = {
  'v', 'version', 'free', 'full', 'demo', 'lite', 'pro', 'deluxe', //
  'premium', 'complete', 'basic', 'standard', 'edition', 'update',
  'updated', 'legacy', 'bonus', 'paid',
};

/// Fewest pack-like children a guessed bundle has.
const minBundlePacks = 3;

/// Share of a guessed bundle's files its pack-like children hold.
const bundleCoverage = 0.8;

/// Share of a section's files its pack-like children hold.
const sectionCoverage = 0.7;

/// Decides whether a folder that would be one pack is a bundle of packs
/// (M95). Structure first, names only as hints:
///
/// 1. **Pack-like child**: a license / readme / preview / `asset_pack.json`
///    or `_itch` at its top, or a count or version suffix. Never one named
///    only by asset kinds or actions (`PNG`, `Idle`) unless it has a count
///    suffix, or one starting with `_`.
/// 2. **Section**: a child with no pack signal of its own whose children are
///    two or more pack-like folders holding most of its files (Kenney's
///    `2D assets`). One level only.
/// 3. **Editions**: pack-like children named like each other or the parent
///    once version / edition words are left out (Zerie's "Tiny RPG Character
///    Asset Pack v1.03 -Free …", "… -Full …") make one pack.
/// 4. **Bundle**: three or more pack-like children (across sections) holding
///    most of the files, no asset files at the folder's own top, and not
///    rule 3.
///
/// Every other child folder with files becomes a pack of the bundle too, so
/// no file is left out.
class BundleDetector {
  final _files = <String, int>{};

  int _count(DirNode d) =>
      _files[d.path] ??= d.walk().fold(0, (n, x) => n + x.files.length);

  /// The bundle [d] is, or null when it is one pack.
  BundlePlan? guess(DirNode d) {
    if (d.files.any((f) => assetExts.contains(f.ext) && !isPreviewFile(f))) {
      return null;
    }
    final plan = _plan(d);
    final likes = [
      for (final c in plan.packs)
        if (c.$2) c.$1,
    ];
    if (likes.length < minBundlePacks) return null;
    final total = d.dirs.fold(0, (n, c) => n + _count(c));
    final covered = likes.fold(0, (n, c) => n + _count(c.dir));
    if (total == 0 || covered < total * bundleCoverage) return null;
    if (_editions([for (final c in likes) c.dir.name], d.name)) return null;
    return BundlePlan([for (final c in plan.packs) c.$1]);
  }

  /// [d] split as a bundle whatever the guess ("Split into packs"): every
  /// child folder with files is a pack, sections as in [guess]. Null when
  /// fewer than two packs come out.
  BundlePlan? force(DirNode d) {
    final plan = _plan(d);
    return plan.packs.length < 2
        ? null
        : BundlePlan([for (final c in plan.packs) c.$1]);
  }

  /// Packs of [d] with whether each is pack-like (rule 1).
  ({List<(BundleChild, bool)> packs}) _plan(DirNode d) {
    final children = [
      for (final c in d.dirs)
        if (!_ignored(c) && _count(c) > 0) c,
    ];
    final out = <(BundleChild, bool)>[];
    final sections = <DirNode>{
      for (final c in children)
        if (!_packLike(c) && _isSection(c)) c,
    };
    for (final c in children) {
      if (sections.contains(c)) {
        final inner = [
          for (final g in c.dirs)
            if (!_ignored(g) && _count(g) > 0) g,
        ];
        for (final g in inner) {
          out.add((BundleChild(g, c.name), _packLike(g)));
        }
      } else {
        // A folder of loose files (Kenney's `Fonts`) next to sections is a
        // section of one pack.
        final section = sections.isNotEmpty && !_packLike(c) ? c.name : null;
        out.add((BundleChild(c, section), _packLike(c)));
      }
    }
    return (packs: out);
  }

  bool _ignored(DirNode c) =>
      c.name.startsWith('_') ||
      c.name == itchMediaDir ||
      isPreviewDirName(c.name);

  bool _isSection(DirNode c) {
    if (hasStrongPackSignal(c)) return false;
    final inner = [
      for (final g in c.dirs)
        if (!_ignored(g) && _count(g) > 0) g,
    ];
    final likes = inner.where(_packLike).toList();
    if (likes.length < 2) return false;
    final covered = likes.fold(0, (n, g) => n + _count(g));
    return covered >= _count(c) * sectionCoverage;
  }

  /// Rule 1. A shared inner layout is no sign on its own: one pack's
  /// character folders share theirs (OboroPixel: `Idle`, `Run`… in each).
  /// A count suffix outweighs kind words (Kenney's `UI sounds (50 sounds)`).
  bool _packLike(DirNode c) =>
      !_ignored(c) &&
      (isCountedName(c.name) ||
          !_isKindName(c.name) &&
              (hasStrongPackSignal(c) ||
                  c.dirs.any((x) => x.name == itchMediaDir) ||
                  isVersionedName(c.name)));
}

bool _isKindName(String name) {
  // `Attack1`, `Idle 2`: the numbers say nothing.
  final words = [
    for (final w in pathWords(name))
      if (w.replaceAll(RegExp(r'\d+$'), '') case final s when s.isNotEmpty) s,
  ];
  return words.isNotEmpty && words.every(_kindWords.contains);
}

/// [name]'s words without numbers and version / edition words.
List<String> _baseWords(String name) => [
  for (final w in pathWords(
    name.replaceAll(RegExp(r'v\d+(\.\d+)*', caseSensitive: false), ' '),
  ))
    if (!RegExp(r'^v?\d+$').hasMatch(w) && !_editionWords.contains(w)) w,
];

bool _startsWith(List<String> a, List<String> prefix) {
  if (prefix.length > a.length) return false;
  for (var i = 0; i < prefix.length; i++) {
    if (a[i] != prefix[i]) return false;
  }
  return true;
}

/// Rule 3: most [names] start like [parent], or all share a long start.
bool _editions(List<String> names, String parent) {
  final words = [for (final n in names) _baseWords(n)];
  final base = _baseWords(parent);
  if (base.length >= 2 &&
      words.where((w) => _startsWith(w, base)).length * 2 >= words.length) {
    return true;
  }
  var prefix = words.first;
  for (final w in words.skip(1)) {
    var i = 0;
    while (i < prefix.length && i < w.length && prefix[i] == w[i]) {
      i++;
    }
    prefix = prefix.sublist(0, i);
  }
  final shortest = words.map((w) => w.length).reduce((a, b) => a < b ? a : b);
  return prefix.length >= 2 && prefix.length * 2 >= shortest;
}
