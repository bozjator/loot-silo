import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import 'type_classifier.dart';

enum AnimKind { sheet, sequence, gif }

/// One animation found in a pack: a sprite sheet (strip or grid), a
/// numbered frame sequence, or a natively animated GIF.
class SpriteAnim {
  const SpriteAnim({
    required this.path,
    required this.kind,
    required this.frameW,
    required this.frameH,
    this.cols = 1,
    this.rows = 1,
    this.frames = const [],
    this.fps = defaultFps,
  });

  static const defaultFps = 10.0;

  /// Sheet / GIF / first frame, relative to the pack.
  final String path;
  final AnimKind kind;
  final int frameW;
  final int frameH;
  final int cols;
  final int rows;

  /// Frame files of a sequence, relative to the pack, in order.
  final List<String> frames;
  final double fps;

  int get frameCount => switch (kind) {
    AnimKind.sequence => frames.length,
    AnimKind.sheet => cols * rows,
    AnimKind.gif => 1,
  };

  /// Display name: file stem, or the shared prefix of a sequence.
  String get label {
    final stem = p.basenameWithoutExtension(path);
    if (kind != AnimKind.sequence) return stem;
    final prefix = stem.replaceFirst(RegExp(r'[\s_-]*\d+$'), '');
    return prefix.isEmpty ? p.basename(p.dirname(path)) : prefix;
  }

  SpriteAnim copyWith({int? frameW, int? frameH, double? fps}) {
    final fw = frameW ?? this.frameW;
    final fh = frameH ?? this.frameH;
    final sheetW = this.frameW * cols;
    final sheetH = this.frameH * rows;
    return SpriteAnim(
      path: path,
      kind: kind,
      frameW: fw,
      frameH: fh,
      cols: kind == AnimKind.sheet && fw > 0 ? sheetW ~/ fw : cols,
      rows: kind == AnimKind.sheet && fh > 0 ? sheetH ~/ fh : rows,
      frames: frames,
      fps: fps ?? this.fps,
    );
  }

  Map<String, Object?> toJson() => {
    'path': path,
    'kind': kind.name,
    'frame_w': frameW,
    'frame_h': frameH,
    if (cols != 1) 'cols': cols,
    if (rows != 1) 'rows': rows,
    if (frames.isNotEmpty) 'frames': frames,
    if (fps != defaultFps) 'fps': fps,
  };

  factory SpriteAnim.fromJson(Map<String, Object?> j) => SpriteAnim(
    path: j['path']! as String,
    kind: AnimKind.values.byName(j['kind']! as String),
    frameW: (j['frame_w']! as num).toInt(),
    frameH: (j['frame_h']! as num).toInt(),
    cols: (j['cols'] as num?)?.toInt() ?? 1,
    rows: (j['rows'] as num?)?.toInt() ?? 1,
    frames: (j['frames'] as List?)?.cast<String>() ?? const [],
    fps: (j['fps'] as num?)?.toDouble() ?? defaultFps,
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
      other.frames.length == frames.length;

  @override
  int get hashCode => Object.hash(path, kind, frameW, frameH, cols, rows, fps);

  @override
  String toString() =>
      'SpriteAnim($path, ${kind.name}, ${frameW}x$frameH, ${cols}x$rows, ${frames.length} frames)';
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
final _numbered = RegExp(r'^(.*?)(\d+)$');

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
/// In order: a size hint like `(96x96)` that divides the image; a frame
/// count hint like `_8f`; a horizontal strip of square frames (width a
/// multiple of height, 3–64 frames, or 2+ with a "sheet" word); a grid of
/// [consensus]-sized squares, where [consensus] is the most common strip
/// height in the same pack. Tilesets, backgrounds, UI and previews are
/// excluded unless the name says "sheet".
SpriteAnim? detectSheet(String rel, int w, int h, {int? consensus}) {
  if (w <= 0 || h <= 0) return null;
  final words = pathWords(rel).toSet();
  final sheetWord = words.any(_sheetWords.contains);
  if (!sheetWord && words.any(_notAnimWords.contains)) return null;

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
    if (g != null) return g;
  }
  final framesHint = _framesHint.firstMatch(p.basenameWithoutExtension(rel));
  if (framesHint != null) {
    final n = int.parse(framesHint[1]!);
    if (n >= 2 && w % n == 0) {
      final g = grid(w ~/ n, h);
      if (g != null) return g;
    }
  }
  if (h <= 512 && w % h == 0) {
    final n = w ~/ h;
    if (n >= 3 && n <= maxSheetFrames || n == 2 && sheetWord) return grid(h, h);
  }
  if (consensus != null && w > consensus && h > consensus) {
    final g = grid(consensus, consensus);
    if (g != null && g.frameCount <= maxSheetFrames * 2) return g;
  }
  return null;
}

/// Finds numbered frame sequences (`walk_0.png … walk_7.png`, `1.png …`).
///
/// Needs ≥ 3 consecutive numbers with the same prefix and extension in one
/// folder, whose first and last frames have the same size, at most 512 px
/// (bigger numbered images are separate artworks, not frames).
List<SpriteAnim> detectSequences(String packPath, Iterable<String> files) {
  final groups = <String, List<(int, String)>>{};
  for (final rel in files) {
    final ext = p.extension(rel).toLowerCase();
    if (ext != '.png') continue;
    final m = _numbered.firstMatch(p.basenameWithoutExtension(rel));
    if (m == null) continue;
    final key = '${p.dirname(rel)}\u0000${m[1]!.toLowerCase()}\u0000$ext';
    groups.putIfAbsent(key, () => []).add((int.parse(m[2]!), rel));
  }
  final out = <SpriteAnim>[];
  for (final g in groups.values) {
    if (g.length < 3) continue;
    g.sort((a, b) => a.$1.compareTo(b.$1));
    var consecutive = true;
    for (var i = 1; i < g.length; i++) {
      if (g[i].$1 != g[i - 1].$1 + 1) consecutive = false;
    }
    if (!consecutive) continue;
    final first = readImageSize(p.join(packPath, g.first.$2));
    final last = readImageSize(p.join(packPath, g.last.$2));
    if (first == null || first != last) continue;
    if (first.$1 > 512 || first.$2 > 512) continue;
    out.add(
      SpriteAnim(
        path: g.first.$2,
        kind: AnimKind.sequence,
        frameW: first.$1,
        frameH: first.$2,
        frames: [for (final (_, rel) in g) rel],
      ),
    );
  }
  return out;
}

/// All animations in a pack. Reads image headers, plus up to
/// [maxPixelScans] full decodes for the transparency-gap heuristic; run in
/// an isolate for big packs. Per-file [overrides] (the sidecar's
/// `animations{}`) set frame size and fps.
List<SpriteAnim> detectAnimations(
  String packPath,
  List<String> files, {
  Map<String, Object?> overrides = const {},
  int maxHeaders = 4000,
  int maxPixelScans = 0,
}) {
  final sequences = detectSequences(packPath, files);
  final inSequence = {for (final s in sequences) ...s.frames};
  final sizes = <String, (int, int)>{};
  final out = <SpriteAnim>[...sequences];
  var reads = 0;
  for (final rel in files) {
    final ext = p.extension(rel).toLowerCase();
    if (ext != '.png' && ext != '.gif') continue;
    if (inSequence.contains(rel)) continue;
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
  final strips = <String, SpriteAnim>{};
  for (final MapEntry(key: rel, value: (w, h)) in sizes.entries) {
    final s = detectSheet(rel, w, h);
    if (s != null) strips[rel] = s;
  }
  final consensus = _consensus(strips.values);
  var pixelScans = 0;
  for (final MapEntry(key: rel, value: (w, h)) in sizes.entries) {
    var s = strips[rel] ?? detectSheet(rel, w, h, consensus: consensus);
    if (s == null &&
        pixelScans < maxPixelScans &&
        w <= 2048 &&
        h <= 2048 &&
        w >= 64 &&
        h >= 64) {
      pixelScans++;
      s = detectSheetByPixels(packPath, rel);
    }
    if (s != null) out.add(s);
  }
  final result = [for (final a in out) applyOverride(a, overrides[a.path])]
    ..sort((a, b) => a.path.compareTo(b.path));
  return result;
}

/// Most common frame height among single-row strips, if any.
int? _consensus(Iterable<SpriteAnim> sheets) {
  final counts = <int, int>{};
  for (final s in sheets) {
    if (s.rows == 1 && s.frameW == s.frameH) {
      counts[s.frameH] = (counts[s.frameH] ?? 0) + 1;
    }
  }
  if (counts.isEmpty) return null;
  return (counts.entries.toList()..sort((a, b) => b.value.compareTo(a.value)))
      .first
      .key;
}

/// Applies a sidecar override `{frame_w, frame_h, fps}` to [a].
SpriteAnim applyOverride(SpriteAnim a, Object? override) {
  if (override is! Map) return a;
  return a.copyWith(
    frameW: (override['frame_w'] as num?)?.toInt(),
    frameH: (override['frame_h'] as num?)?.toInt(),
    fps: (override['fps'] as num?)?.toDouble(),
  );
}

/// The animation a tile should show: idle first, then walk/run, then any
/// strip or sequence, then grids; shallower and shorter paths win ties.
SpriteAnim? pickTileAnimation(List<SpriteAnim> anims) {
  int score(SpriteAnim a) {
    final words = pathWords(p.basenameWithoutExtension(a.path)).toSet();
    var s = 0;
    if (words.contains('idle')) s += 30;
    if (words.contains('walk') || words.contains('run')) s += 20;
    if (a.kind == AnimKind.sequence || a.rows == 1) s += 10;
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

final _animNameWords = {
  ..._sheetWords, 'idle', 'walk', 'run', 'attack', 'jump', 'death', 'hurt', //
  'fly', 'cast', 'explosion', 'effect', 'fx',
};

/// Cheap subset of a pack's files worth reading headers for: names with
/// animation words, size hints or trailing numbers.
List<String> animationCandidates(Iterable<String> files, {int limit = 400}) {
  final out = <String>[];
  for (final rel in files) {
    if (!rel.toLowerCase().endsWith('.png')) continue;
    final stem = p.basenameWithoutExtension(rel);
    if (_sizeHint.hasMatch(rel) ||
        _numbered.hasMatch(stem) ||
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
            anim: applyOverride(sheet, overrides[preview]),
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
  if (sheet == null) {
    final strips = <SpriteAnim>[];
    for (final rel in candidates.take(60)) {
      final s = readImageSize(p.join(packPath, rel));
      final d = s == null ? null : detectSheet(rel, s.$1, s.$2);
      if (d != null) strips.add(d);
    }
    final c = _consensus(strips);
    if (c != null) sheet = detectSheet(preview, size.$1, size.$2, consensus: c);
  }
  return (
    preview: preview,
    anim: sheet == null ? null : applyOverride(sheet, overrides[preview]),
  );
}

/// Finds a grid from fully transparent gaps between frames.
///
/// [alpha] holds one byte per pixel, row-major. Columns (and rows) that are
/// transparent from top to bottom split the image into runs; equal-pitch
/// runs that divide the image evenly give the frame size. Returns null
/// when the image has no such gaps or the pitch is irregular.
(int, int)? gridFromTransparency(Uint8List alpha, int w, int h) {
  int? pitch(int length, bool Function(int) empty) {
    final starts = <int>[];
    var inRun = false;
    for (var i = 0; i < length; i++) {
      final e = empty(i);
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

  bool colEmpty(int x) {
    for (var y = 0; y < h; y++) {
      if (alpha[y * w + x] != 0) return false;
    }
    return true;
  }

  bool rowEmpty(int y) {
    final o = y * w;
    for (var x = 0; x < w; x++) {
      if (alpha[o + x] != 0) return false;
    }
    return true;
  }

  final fw = pitch(w, colEmpty);
  final fh = pitch(h, rowEmpty);
  if (fw == null || fh == null) return null;
  if (fw == w && fh == h) return null;
  return (fw, fh);
}

/// Decodes [path] and applies [gridFromTransparency]; slow, so callers
/// limit it to a few likely files.
SpriteAnim? detectSheetByPixels(String packPath, String rel) {
  final bytes = File(p.join(packPath, rel)).readAsBytesSync();
  final image = img.decodePng(bytes);
  if (image == null || !image.hasAlpha) return null;
  final w = image.width;
  final h = image.height;
  final alpha = Uint8List(w * h);
  var i = 0;
  for (final px in image) {
    alpha[i++] = px.a.toInt();
  }
  final cell = gridFromTransparency(alpha, w, h);
  if (cell == null) return null;
  final cols = w ~/ cell.$1;
  final rows = h ~/ cell.$2;
  if (cols * rows < 2 || cols * rows > maxSheetFrames) return null;
  return SpriteAnim(
    path: rel,
    kind: AnimKind.sheet,
    frameW: cell.$1,
    frameH: cell.$2,
    cols: cols,
    rows: rows,
  );
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
