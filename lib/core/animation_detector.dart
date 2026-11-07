import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import 'type_classifier.dart';

enum AnimKind { sheet, gif }

/// One animation found in a pack: a sprite sheet (strip or grid) or a
/// natively animated GIF. One file is always one animation; frame files
/// are combined into a strip by hand ("Combine into animation").
class SpriteAnim {
  const SpriteAnim({
    required this.path,
    required this.kind,
    required this.frameW,
    required this.frameH,
    this.cols = 1,
    this.rows = 1,
    this.fps = defaultFps,
    this.frameTotal,
    this.playRow = allRows,
    this.zoom,
  });

  static const defaultFps = 10.0;

  /// Choices for [zoom] in the Edit dialog (whole pixel steps).
  static const zoomSteps = [1, 2, 3, 4, 5, 6, 7, 8];

  /// [playRow] value meaning every row of a grid plays in turn.
  static const allRows = -1;

  /// Most frames the Frames field steps to.
  static const maxFrameCount = 512;

  /// Sheet or GIF, relative to the pack.
  final String path;
  final AnimKind kind;
  final int frameW;
  final int frameH;
  final int cols;
  final int rows;

  final double fps;

  /// User override of a sheet's total frame count (sidecar `frames`). When
  /// set, frames past it in the last row are skipped.
  final int? frameTotal;

  /// The grid row that plays (0-based), or [allRows]. Every row by
  /// default; sidecar key `rows` (a 1-based row number) saves a single row.
  final int playRow;

  /// Screen pixels per sprite pixel, or null for Auto: the trimmed frame
  /// fitted to the box in whole steps. A set zoom is drawn centred and
  /// clipped. Sidecar key `zoom`.
  final int? zoom;

  /// The row for [AnimatedSprite]: null plays every row.
  int? get rowToPlay => playRow < 0 ? null : playRow.clamp(0, rows - 1);

  int get frameCount => switch (kind) {
    AnimKind.sheet => frameTotal ?? cols * rows,
    AnimKind.gif => 1,
  };

  /// Display name: the file stem.
  String get label => p.basenameWithoutExtension(path);

  /// Changing the frame size drops a [frameTotal] override, since cols and
  /// rows are recomputed from it.
  SpriteAnim copyWith({
    String? path,
    int? frameW,
    int? frameH,
    double? fps,
    int? playRow,
    Object? zoom = _keep,
  }) {
    final fw = frameW ?? this.frameW;
    final fh = frameH ?? this.frameH;
    final sheetW = this.frameW * cols;
    final sheetH = this.frameH * rows;
    final newRows = kind == AnimKind.sheet && fh > 0 ? sheetH ~/ fh : rows;
    return SpriteAnim(
      path: path ?? this.path,
      kind: kind,
      frameW: fw,
      frameH: fh,
      cols: kind == AnimKind.sheet && fw > 0 ? sheetW ~/ fw : cols,
      rows: newRows,
      fps: fps ?? this.fps,
      frameTotal: frameW == null && frameH == null ? frameTotal : null,
      playRow: _keepRow(playRow ?? this.playRow, newRows),
      zoom: identical(zoom, _keep) ? this.zoom : zoom as int?,
    );
  }

  /// [copyWith]'s "leave [zoom] as it is"; pass null for Auto.
  static const _keep = Object();

  /// A row that no longer exists falls back to all rows.
  static int _keepRow(int row, int rows) => row < rows ? row : allRows;

  /// This sheet re-sliced into [n] frames on the best grid that fits:
  /// `cols × rows` with `cols * rows >= n > (rows - 1) * cols` (the last
  /// row is used), both cell sizes dividing the sheet. Square cells win,
  /// then this sheet's row count, then fewer empty cells. Null when no grid
  /// fits or this isn't a sheet.
  SpriteAnim? withFrameCount(int n) {
    if (kind != AnimKind.sheet || n < 1 || n > maxFrameCount) return null;
    final sheetW = frameW * cols;
    final sheetH = frameH * rows;
    (int, int)? best;
    List<num>? bestKey;
    for (var r = 1; r <= n && r <= sheetH; r++) {
      final c = (n + r - 1) ~/ r;
      if (c > sheetW || sheetW % c != 0 || sheetH % r != 0) continue;
      if (n <= (r - 1) * c) continue;
      final fw = sheetW ~/ c, fh = sheetH ~/ r;
      final key = <num>[
        fw == fh ? 0 : 1,
        r == rows ? 0 : 1,
        c * r - n,
        (fw / fh - 1).abs() + (fh / fw - 1).abs(),
        r,
      ];
      if (bestKey == null || _lexLess(key, bestKey)) {
        best = (c, r);
        bestKey = key;
      }
    }
    if (best == null) return null;
    final (c, r) = best;
    return SpriteAnim(
      path: path,
      kind: kind,
      frameW: sheetW ~/ c,
      frameH: sheetH ~/ r,
      cols: c,
      rows: r,
      fps: fps,
      frameTotal: n,
      playRow: _keepRow(playRow, r),
      zoom: zoom,
    );
  }

  static bool _lexLess(List<num> a, List<num> b) {
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return a[i] < b[i];
    }
    return false;
  }

  /// The next frame count from [from] in direction [step] (+1 / −1) that
  /// has a fitting grid ([withFrameCount]), or null when there is none.
  int? nextFrameCount(int from, int step) {
    for (var n = from + step; n >= 1 && n <= maxFrameCount; n += step) {
      if (withFrameCount(n) != null) return n;
    }
    return null;
  }

  Map<String, Object?> toJson() => {
    'path': path,
    'kind': kind.name,
    'frame_w': frameW,
    'frame_h': frameH,
    if (cols != 1) 'cols': cols,
    if (rows != 1) 'rows': rows,
    if (fps != defaultFps) 'fps': fps,
    if (frameTotal != null) 'frames_total': frameTotal,
    if (playRow != allRows) 'play_row': playRow,
    'zoom': ?zoom,
  };

  factory SpriteAnim.fromJson(Map<String, Object?> j) => SpriteAnim(
    path: j['path']! as String,
    kind: AnimKind.values.byName(j['kind']! as String),
    frameW: (j['frame_w']! as num).toInt(),
    frameH: (j['frame_h']! as num).toInt(),
    cols: (j['cols'] as num?)?.toInt() ?? 1,
    rows: (j['rows'] as num?)?.toInt() ?? 1,
    fps: (j['fps'] as num?)?.toDouble() ?? defaultFps,
    frameTotal: (j['frames_total'] as num?)?.toInt(),
    playRow: (j['play_row'] as num?)?.toInt() ?? allRows,
    zoom: (j['zoom'] as num?)?.toInt(),
  );

  @override
  bool operator ==(Object other) =>
      other is SpriteAnim &&
      other.path == path &&
      other.kind == kind &&
      other.frameW == frameW &&
      other.frameH == frameH &&
      other.cols == cols &&
      other.rows == rows &&
      other.fps == fps &&
      other.frameTotal == frameTotal &&
      other.playRow == playRow &&
      other.zoom == zoom;

  @override
  int get hashCode => Object.hash(
    path,
    kind,
    frameW,
    frameH,
    cols,
    rows,
    fps,
    frameTotal,
    playRow,
    zoom,
  );

  @override
  String toString() =>
      'SpriteAnim($path, ${kind.name}, ${frameW}x$frameH, ${cols}x$rows${frameTotal == null ? '' : ', $frameTotal total'})';
}

/// Width and height from a PNG or GIF header, without decoding.
(int, int)? readImageSize(String path) {
  final RandomAccessFile f;
  try {
    f = File(path).openSync();
  } on FileSystemException {
    return null;
  }
  try {
    final h = f.readSync(24);
    if (h.length >= 24 &&
        h[0] == 0x89 &&
        h[1] == 0x50 &&
        h[2] == 0x4E &&
        h[3] == 0x47) {
      final d = ByteData.sublistView(h);
      return (d.getUint32(16), d.getUint32(20));
    }
    if (h.length >= 10 && h[0] == 0x47 && h[1] == 0x49 && h[2] == 0x46) {
      final d = ByteData.sublistView(h);
      return (d.getUint16(6, Endian.little), d.getUint16(8, Endian.little));
    }
    return null;
  } finally {
    f.closeSync();
  }
}

final _sizeHint = RegExp(r'(?<!\d)(\d{1,4})\s*[xX×]\s*(\d{1,4})(?!\d)');
final _framesHint = RegExp(
  r'(?:^|[^a-z0-9])(\d{1,3})\s*(?:f|frames?)(?![a-z])',
  caseSensitive: false,
);
const _sheetWords = {
  'sheet',
  'spritesheet',
  'strip',
  'anim',
  'animation',
  'animated',
};
const _notAnimWords = {
  'background', 'bg', 'parallax', 'tileset', 'tilemap', 'tiles', 'tile', //
  'map', 'terrain', 'mockup', 'preview', 'cover', 'icon', 'icons', 'font',
  'ui', 'gui', 'panel', 'button', 'screenshot',
};

/// Most frames a detected sheet may have; bigger grids are tilesets.
const maxSheetFrames = 64;

/// Frame size hinted by a `(96x96)`-style token in the file name, or else
/// the nearest folder name.
(int, int)? _hintedSize(String rel) {
  final parts = rel.split('/').reversed;
  for (final part in parts) {
    final m = _sizeHint.firstMatch(part);
    if (m != null) return (int.parse(m[1]!), int.parse(m[2]!));
  }
  return null;
}

/// Decides whether one image of [w]×[h] at [rel] is a sprite sheet.
///
/// In order: a size hint like `(96x96)` that divides the image (a small
/// one like `7x7` that doesn't may count columns × rows); a frame
/// count hint like `_8f`; a horizontal strip of square frames (width a
/// multiple of height, 3–64 frames, or 2+ with a "sheet" word). Tilesets,
/// backgrounds, UI and previews are excluded unless the name says "sheet".
/// A square-frame guess may still be re-cut by its transparent column gaps
/// ([detectAnimations]).
SpriteAnim? detectSheet(String rel, int w, int h) =>
    _detectSheet(rel, w, h)?.anim;

/// Tilesets, backgrounds, UI and previews without a sheet word: never
/// sheets, so not worth a pixel scan either.
bool _notAnimation(String rel) {
  final words = pathWords(rel).toSet();
  return !words.any(_sheetWords.contains) && words.any(_notAnimWords.contains);
}

/// [detectSheet], also saying whether the frames are only the square-strip
/// guess (no size or frame-count hint behind them).
({SpriteAnim anim, bool squareGuess})? _detectSheet(String rel, int w, int h) {
  if (w <= 0 || h <= 0 || _notAnimation(rel)) return null;
  final sheetWord = pathWords(rel).any(_sheetWords.contains);

  SpriteAnim? grid(int fw, int fh) {
    if (fw <= 0 || fh <= 0 || w % fw != 0 || h % fh != 0) return null;
    final cols = w ~/ fw;
    final rows = h ~/ fh;
    final n = cols * rows;
    if (n < 2 || n > maxSheetFrames * 2 || cols < 2 && rows < 2) return null;
    return SpriteAnim(
      path: rel,
      kind: AnimKind.sheet,
      frameW: fw,
      frameH: fh,
      cols: cols,
      rows: rows,
    );
  }

  final hint = _hintedSize(rel);
  if (hint != null) {
    final g = grid(hint.$1, hint.$2);
    if (g != null) return (anim: g, squareGuess: false);
    // A small hint that isn't a frame size may count cells instead:
    // `spritesheet7x7.png` is 7 × 7 frames.
    final (c, r) = hint;
    if (c <= 16 && r <= 16 && w % c == 0 && h % r == 0) {
      final cells = grid(w ~/ c, h ~/ r);
      if (cells != null) return (anim: cells, squareGuess: false);
    }
  }
  final framesHint = _framesHint.firstMatch(p.basenameWithoutExtension(rel));
  if (framesHint != null) {
    final n = int.parse(framesHint[1]!);
    if (n >= 2 && w % n == 0) {
      final g = grid(w ~/ n, h);
      if (g != null) return (anim: g, squareGuess: false);
    }
  }
  if (h <= 512 && w % h == 0) {
    final n = w ~/ h;
    if (n >= 3 && n <= maxSheetFrames || n == 2 && sheetWord) {
      final g = grid(h, h);
      if (g != null) return (anim: g, squareGuess: true);
    }
  }
  return null;
}

/// Words that mark a file or folder as animated: a strip there gets a
/// pixel check of its frame width ([detectAnimations]), and its headers are
/// read at scan time ([animationCandidates]). Plurals match too.
const _animVocabulary = {
  ..._sheetWords, 'idle', 'walk', 'walking', 'run', 'running', 'attack', //
  'jump', 'death', 'die', 'dying', 'dead', 'hurt', 'hit', 'fly', 'flying',
  'cast', 'casting', 'frame', 'sequence', 'fx', 'vfx', 'sfx', 'explosion',
  'explode', 'effect', 'smoke', 'fire', 'flame', 'spell', 'magic',
  'particle', 'slash', 'dash', 'roll', 'spin', 'blink', 'sparkle', 'splash',
  'burst', 'impact', 'loop', 'move', 'moving', 'shoot', 'skill', 'projectile',
  'fireball',
};

/// [_animVocabulary] sorted; the Help page lists them.
List<String> get animationWords => _animVocabulary.toList()..sort();

/// Words that keep an image from being taken as a sheet, unless its name
/// also has a sheet word; sorted, for the Help page.
List<String> get notAnimationWords => _notAnimWords.toList()..sort();

/// Words that mark a file as a sheet; sorted, for the Help page.
List<String> get sheetWords => _sheetWords.toList()..sort();

bool _isSheetWord(String w) =>
    _sheetWords.contains(w) ||
    (w.endsWith('s') && _sheetWords.contains(w.substring(0, w.length - 1)));

bool _isAnimWord(String w) =>
    _animVocabulary.contains(w) ||
    (w.endsWith('s') && _animVocabulary.contains(w.substring(0, w.length - 1)));

/// Whether [rel] (pack-relative) has an animation word in its file name or
/// in one of its folders.
bool hasAnimationWord(String rel) => pathWords(rel).any(_isAnimWord);

/// All animations in a pack, one per file. Reads image headers, plus up to
/// [maxPixelScans] full decodes for the transparency-gap heuristic on any
/// undetected image, and up to [maxWordScans] decodes for files with an
/// animation word ([hasAnimationWord]), [maxWordPixels] pixels in all: a
/// square-frame strip guess is re-cut by its column gaps
/// ([stripFromColumnGaps]), an undetected image is checked for a grid of
/// gaps ([detectSheetByGaps]; strips up to [maxWordStripWidth] ×
/// [maxWordStripHeight], grids up to [maxWordGridSide] a side). An
/// undetected file with an animation word then takes the grid of a
/// detected sheet of exactly its size in its folder ([borrowGrid]). Any
/// other undetected file whose size is a whole number of an animation's
/// frames in its folder is cut into those cells when the cuts are
/// transparent ([cellGrid]; same budget). A
/// square-frame guess with no sheet or animation word in its path is
/// checked too, up to [maxWordScans] times: when the picture runs across
/// the frame cuts it's one image ([runsAcrossCuts]). [atlases]
/// ([atlasImages]) skip those checks. Run it in an isolate for big packs.
/// Per-file [overrides] (the sidecar's `animations{}`) set frame size and
/// fps. Files marked `manual` there ([manualAnimations]), or listed in
/// [manual], become one-row strips ([guessStrip]) when nothing else detects
/// them ("Make animation…").
List<SpriteAnim> detectAnimations(
  String packPath,
  List<String> files, {
  Map<String, Object?> overrides = const {},
  Set<String> manual = const {},
  int maxHeaders = 4000,
  int maxPixelScans = 0,
  int maxWordScans = 0,
  int maxWordPixels = detailWordPixels,
  Set<String> atlases = const {},
}) {
  final made = {...manual, ...manualAnimations(overrides)};
  final sizes = <String, (int, int)>{};
  final out = <SpriteAnim>[];
  var reads = 0;
  for (final rel in files) {
    final ext = p.extension(rel).toLowerCase();
    if (ext != '.png' && ext != '.gif') continue;
    if (reads++ >= maxHeaders) break;
    final size = readImageSize(p.join(packPath, rel));
    if (size == null) continue;
    if (ext == '.gif') {
      out.add(
        SpriteAnim(
          path: rel,
          kind: AnimKind.gif,
          frameW: size.$1,
          frameH: size.$2,
        ),
      );
    } else {
      sizes[rel] = size;
    }
  }
  var pixelScans = 0;
  var wordScans = 0;
  var wordPixels = 0;
  var recuts = 0;
  var stripChecks = 0;
  // How sure each sheet's grid is ([borrowGrid]): a gap grid counts its
  // evenly cut axes (0–2), anything else is sure; undetected files are -1.
  final sureness = <String, int>{};
  final series = numberedFrames(sizes);
  // Names with a sheet word are checked first, then other animation
  // words, then files that only sit in an animated folder (often hundreds
  // of single frames), so the budget goes to the likely sheets.
  int rank(String rel) {
    final words = pathWords(p.basenameWithoutExtension(rel));
    if (words.any(_isSheetWord)) return 0;
    return words.any(_isAnimWord) ? 1 : 2;
  }

  final order = sizes.keys.toList()
    ..sort((a, b) {
      final c = rank(a).compareTo(rank(b));
      return c != 0 ? c : a.compareTo(b);
    });
  for (final rel in order) {
    final (w, h) = sizes[rel]!;
    final found = _detectSheet(rel, w, h);
    var s = found?.anim;
    final animWord = hasAnimationWord(rel);
    if (found != null && found.squareGuess) {
      if (!animWord) {
        if (stripChecks < maxWordScans) {
          stripChecks++;
          if (runsAcrossCuts(packPath, found.anim)) s = null;
        }
      } else if (recuts < maxWordScans &&
          w <= maxWordStripWidth &&
          h <= maxWordStripHeight &&
          !atlases.contains(rel)) {
        recuts++;
        s = stripFromColumnGaps(packPath, found.anim) ?? s;
      }
    }
    // Big images are rarely one animation and cost the most to decode:
    // bounded by size, by count and by pixels per pack. A file named as one
    // frame (`sail-frame15.png`) isn't decoded.
    final scannable = w <= 2048 && h <= 2048 && w >= 64 && h >= 64;
    if (s == null && found == null) {
      if (scannable && pixelScans < maxPixelScans) {
        pixelScans++;
        s = detectSheetByPixels(packPath, rel);
      } else if (animWord &&
          wordScans < maxWordScans &&
          wordScanSize(w, h) &&
          wordPixels + w * h <= maxWordPixels &&
          !atlases.contains(rel) &&
          !_notAnimation(rel) &&
          !_oneFrame.hasMatch(p.basenameWithoutExtension(rel))) {
        wordScans++;
        wordPixels += w * h;
        final byGaps = _sheetByGaps(
          packPath,
          rel,
          allowTwo: !series.contains(rel),
        );
        s = byGaps?.anim;
        if (byGaps != null) sureness[rel] = byGaps.evenAxes;
      }
    }
    if (s == null && made.contains(rel)) s = guessStrip(rel, w, h);
    if (s != null) {
      out.add(s);
      sureness[rel] ??= 3;
    } else if (found == null && animWord && !atlases.contains(rel)) {
      sureness[rel] = -1;
    }
  }
  final borrowed = borrowGrid(sureness, out, sizes);
  final replaced = {for (final a in borrowed) a.path};
  out
    ..removeWhere((a) => replaced.contains(a.path))
    ..addAll(borrowed);
  // Undetected files cut into the frame size of an animation next to them
  // (a 6×6 grid of 192 px cells beside 192-high strips), when the cuts
  // fall on transparent lines.
  final shown = {for (final a in out) a.path};
  for (final rel in order) {
    if (shown.contains(rel) ||
        atlases.contains(rel) ||
        _notAnimation(rel) ||
        _oneFrame.hasMatch(p.basenameWithoutExtension(rel))) {
      continue;
    }
    final (w, h) = sizes[rel]!;
    final cells = [
      for (final (fw, fh) in folderFrameSizes(rel, out))
        if (_fitsCells(w, h, fw, fh)) (fw, fh),
    ];
    if (cells.isEmpty ||
        !wordScanSize(w, h) ||
        wordScans >= maxWordScans ||
        wordPixels + w * h > maxWordPixels) {
      continue;
    }
    wordScans++;
    wordPixels += w * h;
    final decoded = _alphaOf(packPath, rel);
    if (decoded == null) continue;
    for (final (fw, fh) in cells) {
      if (cellGrid(rel, decoded, fw, fh) case final grid?) {
        out.add(grid);
        break;
      }
    }
  }
  final result = [
    for (final a in out)
      if (!isNotAnimation(overrides[a.path]))
        applyOverride(a, overrides[a.path]),
  ]..sort((a, b) => a.path.compareTo(b.path));
  return result;
}

/// A file name that says it is one frame: `sail-frame15`, `frame_3`.
final _oneFrame = RegExp(r'frame[ _-]?\d+$', caseSensitive: false);

/// Grids borrowed from a same-size sheet in the same folder, e.g. for a
/// strip whose particle effects hide its frame gaps, next to the same
/// strip without them. [sureness] (by path) says how sure each grid is:
/// -1 for an undetected file with an animation word, 0–2 for a grid cut
/// from gaps (its evenly cut axes), 3 for any other. A file whose grid is
/// less than sure (under 2) takes the grid of the surest sheet in [found]
/// of exactly its size ([sizes]) in its folder, when that one is surer.
/// Never for paths with a not-animation word ([detectSheet]).
List<SpriteAnim> borrowGrid(
  Map<String, int> sureness,
  List<SpriteAnim> found,
  Map<String, (int, int)> sizes,
) {
  final best = <(String, int, int), (SpriteAnim, int)>{};
  for (final a in [...found]..sort((a, b) => a.path.compareTo(b.path))) {
    final size = sizes[a.path];
    if (a.kind != AnimKind.sheet || size == null) continue;
    final key = (p.dirname(a.path), size.$1, size.$2);
    final sure = sureness[a.path] ?? 3;
    if (best[key] case (_, final known) when known >= sure) continue;
    best[key] = (a, sure);
  }
  return [
    for (final MapEntry(key: rel, value: sure) in sureness.entries)
      if (sure < 2 && !_notAnimation(rel))
        if (sizes[rel] case (final w, final h))
          if (best[(p.dirname(rel), w, h)] case (final a, final from)
              when from > sure && a.path != rel)
            SpriteAnim(
              path: rel,
              kind: AnimKind.sheet,
              frameW: a.frameW,
              frameH: a.frameH,
              cols: a.cols,
              rows: a.rows,
              frameTotal: a.frameTotal,
            ),
  ];
}

/// Frame sizes of the sheets in [anims] that sit in [rel]'s folder, the
/// most used first (then the bigger frame), for cutting [rel] into the same
/// cells ([cellGrid]).
List<(int, int)> folderFrameSizes(String rel, Iterable<SpriteAnim> anims) {
  final dir = p.dirname(rel);
  final counts = <(int, int), int>{};
  for (final a in anims) {
    if (a.kind != AnimKind.sheet || a.path == rel) continue;
    if (p.dirname(a.path) != dir) continue;
    final key = (a.frameW, a.frameH);
    counts[key] = (counts[key] ?? 0) + 1;
  }
  return counts.keys.toList()..sort((a, b) {
    final c = counts[b]!.compareTo(counts[a]!);
    return c != 0 ? c : (b.$1 * b.$2).compareTo(a.$1 * a.$2);
  });
}

/// Whether a [w]×[h] image holds at least two whole [fw]×[fh] cells.
bool _fitsCells(int w, int h, int fw, int fh) {
  if (fw <= 0 || fh <= 0 || w % fw != 0 || h % fh != 0) return false;
  final n = (w ~/ fw) * (h ~/ fh);
  return n >= 2 && n <= maxSheetFrames * 4;
}

/// [decoded] (alpha, width, height) of [rel] cut into [fw]×[fh] cells, when
/// every cut line is transparent (±1 px, like [gapGrid]) and at least
/// three cells hold something. Empty cells at the end don't count as
/// frames ([usedCells]).
SpriteAnim? cellGrid(
  String rel,
  (Uint8List, int, int) decoded,
  int fw,
  int fh,
) {
  final (alpha, w, h) = decoded;
  if (!_fitsCells(w, h, fw, fh)) return null;
  bool colEmpty(int x) {
    if (x < 0 || x >= w) return false;
    for (var y = 0; y < h; y++) {
      if (alpha[y * w + x] != 0) return false;
    }
    return true;
  }

  bool rowEmpty(int y) {
    if (y < 0 || y >= h) return false;
    final o = y * w;
    for (var x = 0; x < w; x++) {
      if (alpha[o + x] != 0) return false;
    }
    return true;
  }

  for (var x = fw; x < w; x += fw) {
    if (!colEmpty(x - 1) && !colEmpty(x) && !colEmpty(x + 1)) return null;
  }
  for (var y = fh; y < h; y += fh) {
    if (!rowEmpty(y - 1) && !rowEmpty(y) && !rowEmpty(y + 1)) return null;
  }
  final cols = w ~/ fw;
  final rows = h ~/ fh;
  final total = cols * rows;
  // Two filled cells are too often one prop with a gap in it (a table
  // over its chairs), as in [gapGrid].
  if (filledCells(alpha, w, fw, fh, cols, rows) < 3) return null;
  final used = usedCells(alpha, w, fw, fh, cols, rows);
  return SpriteAnim(
    path: rel,
    kind: AnimKind.sheet,
    frameW: fw,
    frameH: fh,
    cols: cols,
    rows: rows,
    frameTotal: used < total ? used : null,
  );
}

/// The starting guess for "Make animation…" on an image nothing detected:
/// the cells of an animation in its folder ([folderSizes], [cellGrid]),
/// then the transparent-gap grid ([gapGrid]), then square frames
/// ([guessStrip]: a strip when the width is a multiple of the height,
/// else one frame). Decodes the image; run it in an isolate.
SpriteAnim guessAnimation(
  String packPath,
  String rel,
  int w,
  int h, {
  List<(int, int)> folderSizes = const [],
}) {
  final decoded = wordScanSize(w, h) ? _alphaOf(packPath, rel) : null;
  if (decoded != null) {
    for (final (fw, fh) in folderSizes) {
      if (cellGrid(rel, decoded, fw, fh) case final grid?) return grid;
    }
    final (alpha, dw, dh) = decoded;
    if (gapGrid(alpha, dw, dh) case (:final fw, :final fh, evenAxes: _)) {
      final cols = dw ~/ fw;
      final rows = dh ~/ fh;
      final used = usedCells(alpha, dw, fw, fh, cols, rows);
      return SpriteAnim(
        path: rel,
        kind: AnimKind.sheet,
        frameW: fw,
        frameH: fh,
        cols: cols,
        rows: rows,
        frameTotal: used >= 2 && used < cols * rows ? used : null,
      );
    }
  }
  return guessStrip(rel, w, h);
}

/// [guessAnimation] in a background isolate.
Future<SpriteAnim> guessAnimationInBackground(
  String packPath,
  String rel,
  int w,
  int h, {
  List<(int, int)> folderSizes = const [],
}) => Isolate.run(
  () => guessAnimation(packPath, rel, w, h, folderSizes: folderSizes),
);

/// Files in a numbered series: at least three of the same size in one
/// folder named alike but for a trailing number (`boat-idle-1.png`,
/// `boat-idle-2.png`, …). Each is likely one frame, so a gap grid of only
/// two cells (one sprite with a gap in the middle) doesn't count for them.
Set<String> numberedFrames(Map<String, (int, int)> sizes) {
  final series = <(String, String, int, int), List<String>>{};
  for (final MapEntry(key: rel, value: (w, h)) in sizes.entries) {
    final m = _numbered.firstMatch(p.basenameWithoutExtension(rel));
    if (m == null) continue;
    final key = (p.dirname(rel), m[1]!.toLowerCase(), w, h);
    (series[key] ??= []).add(rel);
  }
  return {
    for (final files in series.values)
      if (files.length >= 3) ...files,
  };
}

final _numbered = RegExp(r'^(.*?)[ _-]?\d+$');

/// Widest and tallest strip a pixel check of a file with an animation word
/// decodes ([detectAnimations]).
const maxWordStripWidth = 16384;
const maxWordStripHeight = 1024;

/// Longest side of any other image that check decodes.
const maxWordGridSide = 4096;

/// Whether a [w]×[h] image is within the word-based pixel check's limits.
bool wordScanSize(int w, int h) =>
    w >= 8 &&
    h >= 8 &&
    (w <= maxWordStripWidth && h <= maxWordStripHeight ||
        w <= maxWordGridSide && h <= maxWordGridSide);

/// Atlas data formats: an image with one of these next to it (same stem)
/// is a texture atlas of unrelated sprites, not an animation.
const _atlasExts = {'.xml', '.json', '.plist', '.atlas', '.tpsheet'};

/// Images in [files] (pack-relative) that come with an atlas data file,
/// e.g. Kenney's `sheet_tanks.png` + `sheet_tanks.xml`.
Set<String> atlasImages(Iterable<String> files) {
  final data = {
    for (final f in files)
      if (_atlasExts.contains(p.extension(f).toLowerCase()))
        p.withoutExtension(f).toLowerCase(),
  };
  return {
    for (final f in files)
      if (p.extension(f).toLowerCase() == '.png' &&
          data.contains(p.withoutExtension(f).toLowerCase()))
        f,
  };
}

/// Files the sidecar's `animations{}` marks `"manual": true`: made into
/// animations by hand, not by detection.
Set<String> manualAnimations(Map<String, Object?> overrides) => {
  for (final MapEntry(:key, :value) in overrides.entries)
    if (value is Map && value['manual'] == true) key,
};

/// A one-row strip guess for an image nothing detected: square frames when
/// the width is a whole multiple of the height, otherwise one frame.
SpriteAnim guessStrip(String rel, int w, int h) {
  final square = h > 0 && w > h && w % h == 0;
  return SpriteAnim(
    path: rel,
    kind: AnimKind.sheet,
    frameW: square ? h : w,
    frameH: h,
    cols: square ? w ~/ h : 1,
  );
}

/// The sidecar override that marks a file as not an animation
/// (`animations: {"<path>": false}`): it then only shows as an image.
bool isNotAnimation(Object? override) => override == false;

/// Applies a sidecar override `{frame_w, frame_h, fps, frames, rows, zoom}`
/// to [a]. `frames` (total frame count, sheets only) is applied after the
/// size; a count that doesn't fit the sheet is ignored. `rows` is the
/// 1-based row that plays; without it every row plays.
SpriteAnim applyOverride(SpriteAnim a, Object? override) {
  if (override is! Map) return a;
  final rows = override['rows'];
  final sized = a.copyWith(
    frameW: (override['frame_w'] as num?)?.toInt(),
    frameH: (override['frame_h'] as num?)?.toInt(),
    fps: (override['fps'] as num?)?.toDouble(),
  );
  final n = (override['frames'] as num?)?.toInt();
  final sliced = n == null ? sized : sized.withFrameCount(n) ?? sized;
  final rowed = rows is num && rows >= 1
      ? sliced.copyWith(playRow: rows.toInt() - 1)
      : sliced;
  final zoom = (override['zoom'] as num?)?.toInt();
  return zoom != null && zoom >= 1 && zoom <= SpriteAnim.zoomSteps.last
      ? rowed.copyWith(zoom: zoom)
      : rowed;
}

/// The animation a tile should show: idle first, then walk/run, then any
/// strip, then grids; shallower and shorter paths win ties.
SpriteAnim? pickTileAnimation(List<SpriteAnim> anims) {
  int score(SpriteAnim a) {
    final words = pathWords(p.basenameWithoutExtension(a.path)).toSet();
    var s = 0;
    if (words.contains('idle')) s += 30;
    if (words.contains('walk') || words.contains('run')) s += 20;
    if (a.rows == 1) s += 10;
    if (a.kind == AnimKind.gif) s -= 5;
    if (pathWords(a.path).contains('shadow') ||
        pathWords(a.path).contains('shadows')) {
      s -= 3;
    }
    return s;
  }

  if (anims.isEmpty) return null;
  return (anims.toList()..sort((a, b) {
        final c = score(b).compareTo(score(a));
        if (c != 0) return c;
        final d = '/'
            .allMatches(a.path)
            .length
            .compareTo('/'.allMatches(b.path).length);
        return d != 0 ? d : a.path.length.compareTo(b.path.length);
      }))
      .first;
}

const _animNameWords = {
  ..._sheetWords, 'idle', 'walk', 'run', 'attack', 'jump', 'death', 'hurt', //
  'fly', 'cast', 'explosion', 'effect', 'fx',
};

/// Cheap subset of a pack's files worth reading headers for: names with
/// animation words or size hints, and files in folders with an animation
/// word ([hasAnimationWord]).
List<String> animationCandidates(Iterable<String> files, {int limit = 400}) {
  final out = <String>[];
  for (final rel in files) {
    if (!rel.toLowerCase().endsWith('.png')) continue;
    final stem = p.basenameWithoutExtension(rel);
    if (_sizeHint.hasMatch(rel) ||
        hasAnimationWord(p.dirname(rel)) ||
        _framesHint.hasMatch(stem) ||
        pathWords(stem).any(_animNameWords.contains)) {
      out.add(rel);
      if (out.length >= limit) break;
    }
  }
  return out;
}

/// Preview and tile animation for a pack at scan time.
///
/// When [preview] came from the weakest rule (rank 6, largest image) or
/// there is none, a detected animation takes over (plan rank 5). When the
/// preview is a PNG sprite sheet itself (e.g. `All-Spritesheet.png`), it
/// keeps its place and gains frame data so the tile can show one frame.
({String? preview, SpriteAnim? anim}) choosePreviewAnimation(
  String packPath,
  List<String> files, {
  String? preview,
  int rank = 6,
  Map<String, Object?> overrides = const {},
}) {
  final candidates = animationCandidates(files);
  if (preview == null || rank == 6) {
    final anim = pickTileAnimation(
      detectAnimations(
        packPath,
        candidates,
        overrides: overrides,
        maxWordScans: tileWordScans,
        maxWordPixels: tileWordPixels,
        atlases: atlasImages(files),
      ).where((a) => a.kind != AnimKind.gif).toList(),
    );
    if (anim != null) return (preview: anim.path, anim: anim);
    if (preview != null &&
        preview.toLowerCase().endsWith('.png') &&
        worthPixelScan(packPath)) {
      final size = readImageSize(p.join(packPath, preview));
      if (size != null && size.$1 <= 2048 && size.$2 <= 2048) {
        final sheet = detectSheetByPixels(packPath, preview);
        if (sheet != null) {
          return (
            preview: preview,
            anim: isNotAnimation(overrides[preview])
                ? null
                : applyOverride(sheet, overrides[preview]),
          );
        }
      }
    }
    return (preview: preview, anim: null);
  }
  if (!preview.toLowerCase().endsWith('.png')) {
    return (preview: preview, anim: null);
  }
  final size = readImageSize(p.join(packPath, preview));
  if (size == null) return (preview: preview, anim: null);
  var sheet = detectSheet(preview, size.$1, size.$2);
  // A strip made with "Combine" / "Make animation" chosen as the cover:
  // its saved frame size, as on the Animations tab, even where the name
  // alone finds no frames (non-square frames).
  if (sheet == null && manualAnimations(overrides).contains(preview)) {
    sheet = guessStrip(preview, size.$1, size.$2);
  }
  return (
    preview: preview,
    anim: sheet == null || isNotAnimation(overrides[preview])
        ? null
        : applyOverride(sheet, overrides[preview]),
  );
}

/// Finds a grid from fully transparent gaps between frames.
///
/// [alpha] holds one byte per pixel, row-major. Columns (and rows) that are
/// transparent from top to bottom split the image into runs; equal-pitch
/// runs that divide the image evenly give the frame size.
///
/// When stray particles break those runs (effect sheets), a fallback tries
/// even cell counts per axis instead ([_evenCellCounts]); it only splits
/// when both axes end up with at least two cells, so a single sprite with a
/// transparent middle line stays whole. Returns null when nothing fits.
(int, int)? gridFromTransparency(
  Uint8List alpha,
  int w,
  int h, {
  bool fallback = true,
}) {
  final colEmpty = List.generate(w, (x) {
    for (var y = 0; y < h; y++) {
      if (alpha[y * w + x] != 0) return false;
    }
    return true;
  });
  final rowEmpty = List.generate(h, (y) {
    final o = y * w;
    for (var x = 0; x < w; x++) {
      if (alpha[o + x] != 0) return false;
    }
    return true;
  });

  final fw = _pitch(colEmpty);
  final fh = _pitch(rowEmpty);
  if (fw != null && fh != null) {
    if (fw == w && fh == h) return null;
    return (fw, fh);
  }
  if (!fallback) return null;

  // Fallback: cell counts whose boundaries are transparent.
  final xs = fw != null ? [w ~/ fw] : _evenCellCounts(colEmpty);
  final ys = fh != null ? [h ~/ fh] : _evenCellCounts(rowEmpty);
  (int, int)? best;
  var bestSquare = false;
  for (final nx in xs) {
    for (final ny in ys) {
      if (nx < 2 || ny < 2) continue;
      final square = w ~/ nx == h ~/ ny;
      final better =
          best == null ||
          square && !bestSquare ||
          square == bestSquare && nx * ny > best.$1 * best.$2;
      if (better) {
        best = (nx, ny);
        bestSquare = square;
      }
    }
  }
  return best == null ? null : (w ~/ best.$1, h ~/ best.$2);
}

/// Cell counts n = 2…16 dividing the axis whose boundary lines
/// (k·length/n, k = 1…n-1, ±1 px) are fully transparent and whose bands all
/// hold something. [empty] marks fully transparent lines along the axis.
List<int> _evenCellCounts(List<bool> empty) {
  final length = empty.length;
  final out = <int>[];
  for (var n = 2; n <= 16; n++) {
    if (length % n != 0) continue;
    final cell = length ~/ n;
    if (cell < 2) break;
    var ok = true;
    for (var k = 1; k < n && ok; k++) {
      final b = k * cell;
      ok = empty[b - 1] || empty[b] || (b + 1 < length && empty[b + 1]);
    }
    for (var k = 0; k < n && ok; k++) {
      ok = empty.sublist(k * cell, (k + 1) * cell).contains(false);
    }
    if (ok) out.add(n);
  }
  return out;
}

/// Most pixel checks of files with an animation word per pack at scan
/// time, for the tile animation; the detail page allows [detailWordScans].
const tileWordScans = 8;

/// Most pixels the word-based pixel checks decode per pack when its detail
/// page loads (the ship sheets are 6–8 MP each), and at scan time.
const detailWordPixels = 256000000;
const tileWordPixels = 32000000;

/// Most pixel checks of files with an animation word per pack when its
/// detail page loads.
const detailWordScans = 256;

/// One alpha byte per pixel of the PNG at [rel], with its size; null when
/// it has no alpha or can't be read.
(Uint8List, int, int)? _alphaOf(String packPath, String rel) {
  final File file = File(p.join(packPath, rel));
  final img.Image? image;
  try {
    image = img.decodePng(file.readAsBytesSync());
  } on FileSystemException {
    return null;
  }
  if (image == null || !image.hasAlpha) return null;
  final w = image.width;
  final h = image.height;
  final alpha = Uint8List(w * h);
  if (image.format == img.Format.uint8 &&
      image.numChannels == 4 &&
      !image.hasPalette) {
    // RGBA bytes: much faster than iterating pixels on big sheets.
    final bytes = image.toUint8List();
    for (var i = 0, j = 3; i < alpha.length; i++, j += 4) {
      alpha[i] = bytes[j];
    }
    return (alpha, w, h);
  }
  var i = 0;
  for (final px in image) {
    alpha[i++] = px.a.toInt();
  }
  return (alpha, w, h);
}

/// Re-cuts a square-frame strip guess [guess] by its transparent column
/// gaps: when they give an equal frame width that differs from the square
/// guess (`banner-only.png`, 1152×128: 12 frames of 96, not 9 of 128), the
/// strip uses that width. Null when the gaps say nothing else.
SpriteAnim? stripFromColumnGaps(String packPath, SpriteAnim guess) {
  final decoded = _alphaOf(packPath, guess.path);
  if (decoded == null) return null;
  final (alpha, w, h) = decoded;
  if (w != guess.frameW * guess.cols || h != guess.frameH * guess.rows) {
    return null;
  }
  final fw = columnPitch(alpha, w, h);
  if (fw == null || fw == guess.frameW || w % fw != 0) return null;
  final cols = w ~/ fw;
  if (cols < 2 || cols > maxSheetFrames) return null;
  return SpriteAnim(
    path: guess.path,
    kind: AnimKind.sheet,
    frameW: fw,
    frameH: h,
    cols: cols,
  );
}

/// The equal pitch of the runs between fully transparent columns, when
/// every run starts inside its own cell; null otherwise or for one run.
int? columnPitch(Uint8List alpha, int w, int h) {
  final empty = List.generate(w, (x) {
    for (var y = 0; y < h; y++) {
      if (alpha[y * w + x] != 0) return false;
    }
    return true;
  });
  final p = _pitch(empty);
  return p == null || p == w ? null : p;
}

/// See [gridFromTransparency]: the cell length of equal-pitch runs along
/// one axis, the whole [empty] length for one run, null when uneven.
int? _pitch(List<bool> empty) {
  final length = empty.length;
  final starts = <int>[];
  var inRun = false;
  for (var i = 0; i < length; i++) {
    final e = empty[i];
    if (!e && !inRun) starts.add(i);
    inRun = !e;
  }
  final n = starts.length;
  if (n < 2 || length % n != 0) return n == 1 ? length : null;
  final cell = length ~/ n;
  // Every run must start inside its own cell.
  for (var k = 0; k < n; k++) {
    if (starts[k] < k * cell || starts[k] >= (k + 1) * cell) return null;
  }
  return cell;
}

/// Decodes [path] and applies [gridFromTransparency]; slow, so callers
/// limit it to a few likely files. Without [fallback] only clean runs
/// count (the particle fallback splits single sprites too often outside
/// effect packs). At most [maxFrames] cells.
SpriteAnim? detectSheetByPixels(
  String packPath,
  String rel, {
  bool fallback = true,
  int maxFrames = maxSheetFrames,
}) {
  final decoded = _alphaOf(packPath, rel);
  if (decoded == null) return null;
  final (alpha, w, h) = decoded;
  final cell = gridFromTransparency(alpha, w, h, fallback: fallback);
  if (cell == null) return null;
  final cols = w ~/ cell.$1;
  final rows = h ~/ cell.$2;
  if (cols * rows < 2 || cols * rows > maxFrames) return null;
  return SpriteAnim(
    path: rel,
    kind: AnimKind.sheet,
    frameW: cell.$1,
    frameH: cell.$2,
    cols: cols,
    rows: rows,
  );
}

/// Decodes [rel] and applies [gapGrid]. Cells left empty at the end of
/// the grid (a 4×4 sheet of 15 frames) don't count: the frame total is the
/// used cells then.
SpriteAnim? detectSheetByGaps(
  String packPath,
  String rel, {
  int maxCells = maxSheetFrames * 4,
  bool allowTwo = true,
}) => _sheetByGaps(packPath, rel, maxCells: maxCells, allowTwo: allowTwo)?.anim;

/// [detectSheetByGaps], also giving the grid's evenly cut axes
/// ([gapGrid]).
({SpriteAnim anim, int evenAxes})? _sheetByGaps(
  String packPath,
  String rel, {
  int maxCells = maxSheetFrames * 4,
  bool allowTwo = true,
}) {
  final decoded = _alphaOf(packPath, rel);
  if (decoded == null) return null;
  final (alpha, w, h) = decoded;
  final cell = gapGrid(alpha, w, h, maxCells: maxCells, allowTwo: allowTwo);
  if (cell == null) return null;
  final (:fw, :fh, :evenAxes) = cell;
  final cols = w ~/ fw;
  final rows = h ~/ fh;
  final used = usedCells(alpha, w, fw, fh, cols, rows);
  return (
    anim: SpriteAnim(
      path: rel,
      kind: AnimKind.sheet,
      frameW: fw,
      frameH: fh,
      cols: cols,
      rows: rows,
      frameTotal: used >= 2 && used < cols * rows ? used : null,
    ),
    evenAxes: evenAxes,
  );
}

/// Frame size from fully transparent gaps, for files with an animation
/// word. Frames needn't be square.
///
/// Per axis: when the runs between transparent lines are evenly spaced
/// and the cut lines are transparent, their count (an evenly cut axis);
/// otherwise (a gap inside one frame, like a ship's sails, or a frame in
/// two parts) every cell count whose cut lines are transparent and that
/// leaves at least two cells with something in them, or one cell.
///
/// The column count decides first: the most columns for which the
/// squarest row count keeps frames between 1:2 and 2:1 (128×224 flames,
/// not 256×224 pairs of them; 160×160 frames, not 160×80 halves split at
/// the shadow), so the row cut is checked against the column cut. When
/// none does, the squarest of all. [evenAxes] (0–2) tells how sure the
/// grid is ([borrowGrid]). Null when that leaves under three cells (two
/// are too often one sprite with a gap in the middle) unless both axes are
/// evenly cut and [allowTwo]; null over [maxCells].
({int fw, int fh, int evenAxes})? gapGrid(
  Uint8List alpha,
  int w,
  int h, {
  int maxCells = maxSheetFrames * 4,
  bool allowTwo = true,
}) {
  final colEmpty = List.generate(w, (x) {
    for (var y = 0; y < h; y++) {
      if (alpha[y * w + x] != 0) return false;
    }
    return true;
  });
  final rowEmpty = List.generate(h, (y) {
    final o = y * w;
    for (var x = 0; x < w; x++) {
      if (alpha[o + x] != 0) return false;
    }
    return true;
  });
  final xs = _gapCounts(colEmpty)..sort((a, b) => b.compareTo(a));
  final ys = _gapCounts(rowEmpty);
  double skew(int nx, int ny) => math.log((w / nx) / (h / ny)).abs();
  (int, int)? squarestRow(int nx) {
    (int, int)? best;
    for (final ny in ys) {
      if (nx * ny > maxCells) continue;
      if (best == null || skew(nx, ny) < skew(best.$1, best.$2) - 1e-9) {
        best = (nx, ny);
      }
    }
    return best;
  }

  (int, int)? best;
  for (final nx in xs) {
    final pick = squarestRow(nx);
    if (pick != null && skew(pick.$1, pick.$2) <= math.ln2 + 1e-9) {
      best = pick;
      break;
    }
  }
  if (best == null) {
    for (final nx in xs) {
      final pick = squarestRow(nx);
      if (pick == null) continue;
      if (best == null ||
          skew(pick.$1, pick.$2) < skew(best.$1, best.$2) - 1e-9) {
        best = pick;
      }
    }
  }
  if (best == null) return null;
  final evenAxes =
      (_evenPitch(colEmpty) != null ? 1 : 0) +
      (_evenPitch(rowEmpty) != null ? 1 : 0);
  final cells = best.$1 * best.$2;
  if (cells < 2 || cells == 2 && !(allowTwo && evenAxes == 2)) return null;
  return (fw: w ~/ best.$1, fh: h ~/ best.$2, evenAxes: evenAxes);
}

/// Cell counts along one axis for [gapGrid]; [empty] marks fully
/// transparent lines.
List<int> _gapCounts(List<bool> empty) {
  final length = empty.length;
  final pitch = _evenPitch(empty);
  if (pitch != null) return [length ~/ pitch];
  final out = [1];
  for (var n = 2; n <= maxSheetFrames; n++) {
    if (length % n != 0) continue;
    final cell = length ~/ n;
    if (cell < 4) break;
    var ok = true;
    for (var k = 1; k < n && ok; k++) {
      final b = k * cell;
      ok = empty[b - 1] || empty[b] || (b + 1 < length && empty[b + 1]);
    }
    if (!ok) continue;
    var filled = 0;
    for (var k = 0; k < n; k++) {
      for (var i = k * cell; i < (k + 1) * cell; i++) {
        if (!empty[i]) {
          filled++;
          break;
        }
      }
    }
    if (filled >= 2) out.add(n);
  }
  return out;
}

/// [_pitch] when every cut line between its cells is transparent too
/// (±1 px): runs that merely start in their own cells can still cross the
/// cuts.
int? _evenPitch(List<bool> empty) {
  final cell = _pitch(empty);
  if (cell == null) return null;
  final length = empty.length;
  for (var b = cell; b < length; b += cell) {
    if (!(empty[b - 1] || empty[b] || (b + 1 < length && empty[b + 1]))) {
      return null;
    }
  }
  return cell;
}

/// How many cells of a [cols]×[rows] grid of [fw]×[fh] in [alpha] (row
/// width [w]) have something in them.
int filledCells(Uint8List alpha, int w, int fw, int fh, int cols, int rows) {
  var n = 0;
  for (var r = 0; r < rows; r++) {
    for (var c = 0; c < cols; c++) {
      cell:
      for (var y = r * fh; y < (r + 1) * fh; y++) {
        final o = y * w;
        for (var x = c * fw; x < (c + 1) * fw; x++) {
          if (alpha[o + x] != 0) {
            n++;
            break cell;
          }
        }
      }
    }
  }
  return n;
}

/// Cells of a [cols]×[rows] grid of [fw]×[fh] in [alpha] (row width [w])
/// up to the last one with something in it, row by row; [cols] × [rows]
/// when an empty cell comes before a used one.
int usedCells(Uint8List alpha, int w, int fw, int fh, int cols, int rows) {
  bool filled(int c, int r) {
    for (var y = r * fh; y < (r + 1) * fh; y++) {
      final o = y * w;
      for (var x = c * fw; x < (c + 1) * fw; x++) {
        if (alpha[o + x] != 0) return true;
      }
    }
    return false;
  }

  final total = cols * rows;
  var used = 0;
  var gap = false;
  for (var i = 0; i < total; i++) {
    if (filled(i % cols, i ~/ cols)) {
      if (gap) return total;
      used++;
    } else {
      gap = true;
    }
  }
  return used;
}

/// Whether the one-row strip guess [guess] is really one wide picture: its
/// opaque pixels run across at least half of the frame cuts, each over a
/// quarter of the image's non-empty rows, and the frames' opaque boxes
/// don't look alike (sizes within a fifth of a frame and the same frame
/// edges touched). `supply_bags_1.png` (96×32) is one prop, a strip of
/// three separate frames is not.
bool runsAcrossCuts(String packPath, SpriteAnim guess) {
  final decoded = _alphaOf(packPath, guess.path);
  if (decoded == null) return false;
  final (alpha, w, h) = decoded;
  return picturesAcrossCuts(alpha, w, h, guess.frameW);
}

/// [runsAcrossCuts] on decoded [alpha] cut every [fw] pixels.
bool picturesAcrossCuts(Uint8List alpha, int w, int h, int fw) {
  if (fw <= 0 || w % fw != 0 || w ~/ fw < 2) return false;
  final n = w ~/ fw;
  var opaqueRows = 0;
  for (var y = 0; y < h; y++) {
    final o = y * w;
    for (var x = 0; x < w; x++) {
      if (alpha[o + x] != 0) {
        opaqueRows++;
        break;
      }
    }
  }
  if (opaqueRows == 0) return false;
  var crossed = 0;
  for (var k = 1; k < n; k++) {
    final x = k * fw;
    var rows = 0;
    for (var y = 0; y < h; y++) {
      if (alpha[y * w + x - 1] != 0 && alpha[y * w + x] != 0) rows++;
    }
    if (rows * 4 >= opaqueRows) crossed++;
  }
  if (crossed * 2 < n - 1) return false;
  // Opaque boxes per frame: (width, height, touches left, touches right).
  final boxes = <(int, int, bool, bool)>[];
  for (var k = 0; k < n; k++) {
    var x0 = fw, x1 = -1, y0 = h, y1 = -1;
    for (var y = 0; y < h; y++) {
      final o = y * w + k * fw;
      for (var x = 0; x < fw; x++) {
        if (alpha[o + x] != 0) {
          if (x < x0) x0 = x;
          if (x > x1) x1 = x;
          if (y < y0) y0 = y;
          if (y > y1) y1 = y;
        }
      }
    }
    if (x1 >= 0) boxes.add((x1 - x0 + 1, y1 - y0 + 1, x0 == 0, x1 == fw - 1));
  }
  if (boxes.length < 2) return false;
  final first = boxes.first;
  final alike = boxes.every(
    (b) =>
        (b.$1 - first.$1).abs() * 5 <= fw &&
        (b.$2 - first.$2).abs() * 5 <= h &&
        b.$3 == first.$3 &&
        b.$4 == first.$4,
  );
  return !alike;
}

const _pixelScanWords = {
  'effect',
  'effects',
  'fx',
  'vfx',
  'explosion',
  'anim',
  'animation',
  'spell',
  'magic',
  'particle',
};

/// Whether a pack path suggests effect sheets worth a pixel scan.
bool worthPixelScan(String packPathWords) =>
    pathWords(packPathWords).any(_pixelScanWords.contains);
