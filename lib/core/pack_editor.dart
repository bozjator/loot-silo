import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'package:path/path.dart' as p;

import 'animation_detector.dart';
import 'file_search.dart';
import 'natural_order.dart';
import 'preview_picker.dart';
import 'sidecar.dart';
import 'type_classifier.dart';

export 'natural_order.dart' show naturalCompare;

/// What the detail view shows for one pack, gathered off the UI thread.
class PackContents {
  const PackContents({
    required this.images,
    required this.audio,
    required this.other,
    required this.detected,
    required this.sizes,
    required this.sidecar,
  });

  /// Paths relative to the pack, sorted. [images] leaves out the files
  /// shown as animations ([shownDetected]): one file is listed in one tab.
  final List<String> images;
  final List<String> audio;
  final List<String> other;

  /// Animations as detected, before sidecar overrides.
  final List<SpriteAnim> detected;
  final Map<String, int> sizes;
  final PackSidecar? sidecar;

  /// Only what lies under [folder] (pack-relative, no trailing slash).
  PackContents within(String folder) {
    final prefix = '$folder/';
    List<String> under(List<String> l) => [
      for (final f in l)
        if (f.startsWith(prefix)) f,
    ];
    return PackContents(
      images: under(images),
      audio: under(audio),
      other: under(other),
      detected: [
        for (final a in detected)
          if (a.path.startsWith(prefix)) a,
      ],
      sizes: sizes,
      sidecar: sidecar,
    );
  }

  /// No file in any tab.
  bool get isEmpty =>
      images.isEmpty && audio.isEmpty && other.isEmpty && detected.isEmpty;

  /// Only files matching a search ([fileMatches]).
  PackContents matching(List<String> words, {bool infix = false}) {
    bool hit(String rel) => fileMatches(rel, words, infix: infix);
    List<String> keep(List<String> l) => [
      for (final f in l)
        if (hit(f)) f,
    ];
    return PackContents(
      images: keep(images),
      audio: keep(audio),
      other: keep(other),
      detected: [
        for (final a in detected)
          if (hit(a.path)) a,
      ],
      sizes: sizes,
      sidecar: sidecar,
    );
  }

  /// Only the files in [keep] (the starred ones).
  PackContents only(Set<String> keep) {
    List<String> kept(List<String> l) => [
      for (final f in l)
        if (keep.contains(f)) f,
    ];
    return PackContents(
      images: kept(images),
      audio: kept(audio),
      other: kept(other),
      detected: [
        for (final a in detected)
          if (keep.contains(a.path)) a,
      ],
      sizes: sizes,
      sidecar: sidecar,
    );
  }

  bool _hidden(SpriteAnim a) => isNotAnimation(sidecar?.animations[a.path]);

  /// [detected] minus the files marked "Not an animation"; parallel to
  /// [animations].
  List<SpriteAnim> get shownDetected => [
    for (final a in detected)
      if (!_hidden(a)) a,
  ];

  /// Detected animations the user marked "Not an animation"; they show in
  /// the Images tab only.
  List<SpriteAnim> get hiddenAnimations => [
    for (final a in detected)
      if (_hidden(a)) a,
  ];

  /// [shownDetected] with the sidecar's overrides applied.
  List<SpriteAnim> get animations => [
    for (final a in shownDetected)
      applyOverride(a, sidecar?.animations[a.path]),
  ];

  /// Images worth flipping through at the top of the page and in the
  /// viewer opened from it: the tile preview first, then the pack's preview
  /// candidates ([previewCandidates]), at most [limit].
  ///
  /// Animations count too (animated GIF mockups), although [images] leaves
  /// them out.
  List<String> carousel(String? preview, {int limit = 100}) => [
    ?preview,
    ...previewCandidates(
      [...images, for (final a in shownDetected) a.path]..sort(),
    ).where((f) => f != preview),
  ].take(limit).toList();
}

/// Splits [files] into images / audio / other and detects animations,
/// applying the sidecar's overrides. Pure Dart; run it in an isolate.
PackContents loadPackContents(String packPath, List<(String, int)> files) {
  final sidecar = PackSidecar.read(packPath);
  final images = <String>[], audio = <String>[], other = <String>[];
  for (final (rel, _) in files) {
    final ext = p.extension(rel).toLowerCase().replaceFirst('.', '');
    // Only formats the engine decodes count as images; PSD/Aseprite
    // sources are listed with the other files.
    if (previewExts.contains(ext)) {
      images.add(rel);
    } else if (audioExts.contains(ext)) {
      audio.add(rel);
    } else {
      other.add(rel);
    }
  }
  // Effect packs often hold grids with no size hints; a few full decodes
  // find them by their transparent gaps. Files with an animation word get
  // the same check, and their strips a check of the frame width.
  images.sort();
  final detected = detectAnimations(
    packPath,
    images,
    manual: manualAnimations(sidecar?.animations ?? const {}),
    maxPixelScans: worthPixelScan(packPath) ? 24 : 0,
    maxWordScans: detailWordScans,
    atlases: atlasImages([for (final (rel, _) in files) rel]),
  );
  // An animation is listed in the Animations tab only; "Not an animation"
  // brings it back here.
  final animated = {
    for (final a in detected)
      if (!isNotAnimation(sidecar?.animations[a.path])) a.path,
  };
  return PackContents(
    images: [
      for (final f in images)
        if (!animated.contains(f)) f,
    ],
    audio: audio..sort(),
    other: other..sort(),
    detected: detected,
    sizes: {for (final (rel, size) in files) rel: size},
    sidecar: sidecar,
  );
}

/// Writes user edits to `asset_pack.json`, creating it when missing and
/// keeping every other key. A null argument leaves that field alone; an
/// empty [title] clears the custom title.
PackSidecar updatePackSidecar(
  String packPath, {
  String? title,
  List<String>? types,
  List<String>? tags,
}) {
  final old = PackSidecar.read(packPath) ?? const PackSidecar();
  final cleared = title != null && title.trim().isEmpty;
  final next = PackSidecar(
    title: cleared ? null : (title?.trim() ?? old.title),
    types: types ?? old.types,
    tags: tags ?? old.tags,
    source: old.source,
    sourcePath: old.sourcePath,
    itchGameId: old.itchGameId,
    itchUrl: old.itchUrl,
    cover: old.cover,
    notes: old.notes,
    usedIn: old.usedIn,
    isContainer: old.isContainer,
    animations: old.animations,
    favorite: old.favorite,
    favoriteFiles: old.favoriteFiles,
    extra: old.extra,
  );
  next.write(packPath);
  return next;
}

/// Saves (or with a null [anim], removes) the animation override for one
/// file. Only fields that differ from [detected] are stored.
///
/// [manual] (or an existing `manual` mark) keeps `"manual": true`, so an
/// image made into an animation by hand stays one; resetting ([anim] null)
/// turns it back into a plain image.
PackSidecar saveAnimationOverride(
  String packPath,
  SpriteAnim detected,
  SpriteAnim? anim, {
  bool manual = false,
}) {
  final old = PackSidecar.read(packPath) ?? const PackSidecar();
  final previous = old.animations[detected.path];
  final keepManual = manual || (previous is Map && previous['manual'] == true);
  final animations = {...old.animations}..remove(detected.path);
  if (anim != null) {
    final o = <String, Object?>{
      if (keepManual) 'manual': true,
      // With a total frame count, the frame width follows from it.
      if (anim.frameTotal == null && anim.frameW != detected.frameW)
        'frame_w': anim.frameW,
      if (anim.frameH != detected.frameH) 'frame_h': anim.frameH,
      if (anim.fps != SpriteAnim.defaultFps) 'fps': anim.fps,
      'frames': ?anim.frameTotal,
      // Detection plays every row, so only a single row is saved.
      if (anim.playRow >= 0) 'rows': anim.playRow + 1,
      if (anim.zoom != detected.zoom) 'zoom': ?anim.zoom,
    };
    if (o.isNotEmpty) animations[detected.path] = o;
  }
  final next = old.copyWith(animations: animations);
  next.write(packPath);
  return next;
}

/// Marks [rel] as not an animation (`animations: {"<rel>": false}`), or
/// with [hidden] false removes that mark (like "Reset to detected").
PackSidecar setNotAnimation(String packPath, String rel, {bool hidden = true}) {
  final old = PackSidecar.read(packPath) ?? const PackSidecar();
  final animations = {...old.animations}..remove(rel);
  if (hidden) animations[rel] = false;
  final next = old.copyWith(animations: animations);
  next.write(packPath);
  return next;
}

/// True when [packPath] still exists; the detail view checks before
/// writing so a vanished folder isn't recreated by a sidecar write.
bool packExists(String packPath) => Directory(packPath).existsSync();

/// Stars or unstars the pack (`favorite`), keeping every other key.
PackSidecar setFavoritePack(String packPath, {required bool favorite}) {
  final old = PackSidecar.read(packPath) ?? const PackSidecar();
  final next = old.copyWith(favorite: favorite);
  next.write(packPath);
  return next;
}

/// Stars or unstars one file ([rel], relative to the pack) in
/// `favorite_files`, keeping every other key; the list stays sorted.
PackSidecar setFavoriteFile(
  String packPath,
  String rel, {
  required bool favorite,
}) {
  final old = PackSidecar.read(packPath) ?? const PackSidecar();
  final files = {...old.favoriteFiles}..remove(rel);
  if (favorite) files.add(rel);
  final next = old.copyWith(favoriteFiles: files.toList()..sort());
  next.write(packPath);
  return next;
}

/// Adds or removes [game] from the pack's `used_in` list.
PackSidecar setUsedIn(String packPath, String game, {required bool used}) {
  final old = PackSidecar.read(packPath) ?? const PackSidecar();
  final games = [...old.usedIn]..remove(game);
  if (used) games.add(game);
  final next = old.copyWith(usedIn: games);
  next.write(packPath);
  return next;
}

/// Updates URL / license / credit wording in an author folder's
/// `ASSET_AUTHOR.txt`. The name stays: it is the folder name.
AuthorInfo? updateAuthorInfo(
  String authorDir, {
  String? url,
  String? license,
  String? credit,
  String? attribution,
}) {
  final path = p.join(authorDir, authorFileName);
  final old = AuthorInfo.read(path) ?? AuthorInfo(user: p.basename(authorDir));
  final next = old.copyWith(
    url: url,
    license: license,
    credit: credit,
    attribution: attribution,
  );
  next.write(authorDir);
  return next;
}

/// The file "Combine into animation" writes for [rels]: `<folder>_animation.png`
/// in the first file's folder, or `animation.png` at the pack root. With
/// [unique], a number is added while the name is in [taken].
String combinedName(
  List<String> rels, {
  Set<String> taken = const {},
  bool unique = false,
}) {
  final first = ([...rels]..sort(naturalCompare)).first;
  final folder = p.posix.dirname(first);
  final stem = folder == '.'
      ? 'animation'
      : '${p.posix.basename(folder)}_animation';
  String at(String name) => folder == '.' ? name : p.posix.join(folder, name);
  var out = at('$stem.png');
  for (var i = 2; unique && taken.contains(out); i++) {
    out = at('${stem}_$i.png');
  }
  return out;
}

/// A strip built by [buildCombinedStrip], not written anywhere yet.
typedef CombinedStripImage = ({
  Uint8List png,
  int frameW,
  int frameH,
  int frames,
});

/// What [combineFrames] wrote.
typedef CombinedStrip = ({String path, int frameW, int frameH, int frames});

/// Stacks the images [rels] (natural order) left to right into one PNG, in
/// memory. Frames of different sizes are centred in the largest frame size.
/// Pure Dart; see [buildCombinedStripInBackground].
CombinedStripImage buildCombinedStrip(String packPath, List<String> rels) {
  final ordered = [...rels]..sort(naturalCompare);
  final frames = <img.Image>[];
  for (final rel in ordered) {
    final decoded = img.decodeImage(
      File(p.join(packPath, rel)).readAsBytesSync(),
    );
    if (decoded == null) throw FormatException('Not an image: $rel');
    // 8-bit RGBA: palette and 1/2/4/16-bit PNGs keep their own format
    // under a plain `convert(numChannels: 4)`, and compositing then copies
    // raw values (15 for white in a 4-bit file) into the 8-bit strip.
    frames.add(decoded.convert(format: img.Format.uint8, numChannels: 4));
  }
  if (frames.length < 2) throw ArgumentError('Need at least 2 images');
  final fw = frames.map((f) => f.width).reduce(math.max);
  final fh = frames.map((f) => f.height).reduce(math.max);
  final strip = img.Image(
    width: fw * frames.length,
    height: fh,
    numChannels: 4,
  );
  for (var i = 0; i < frames.length; i++) {
    final f = frames[i];
    img.compositeImage(
      strip,
      f,
      dstX: i * fw + (fw - f.width) ~/ 2,
      dstY: (fh - f.height) ~/ 2,
      blend: img.BlendMode.direct,
    );
  }
  return (
    png: img.encodePng(strip),
    frameW: fw,
    frameH: fh,
    frames: frames.length,
  );
}

/// [buildCombinedStrip] in an isolate.
Future<CombinedStripImage> buildCombinedStripInBackground(
  String packPath,
  List<String> rels,
) => Isolate.run(() => buildCombinedStrip(packPath, rels));

/// Writes a combined strip ([png]) to [anim]'s path and records it in the
/// sidecar as a `manual` animation with [anim]'s settings. [detected] is the
/// strip as built; its frame size is always stored, since detection alone
/// would guess square frames.
PackSidecar saveCombinedStrip(
  String packPath,
  Uint8List png,
  SpriteAnim detected,
  SpriteAnim anim,
) {
  File(p.join(packPath, anim.path))
    ..parent.createSync(recursive: true)
    ..writeAsBytesSync(png);
  final saved = saveAnimationOverride(packPath, detected, anim, manual: true);
  final entry = <String, Object?>{
    ...?(saved.animations[anim.path] as Map?)?.cast<String, Object?>(),
    'manual': true,
  };
  if (anim.frameTotal == null) entry.putIfAbsent('frame_w', () => anim.frameW);
  entry.putIfAbsent('frame_h', () => anim.frameH);
  final next = saved.copyWith(
    animations: {...saved.animations, anim.path: entry},
  );
  next.write(packPath);
  return next;
}

/// Builds the strip for [rels] and writes it at [outRel] right away (see
/// [saveCombinedStrip]); the UI shows it first and writes on Save. The
/// frame files stay.
CombinedStrip combineFrames(String packPath, List<String> rels, String outRel) {
  final built = buildCombinedStrip(packPath, rels);
  final anim = SpriteAnim(
    path: outRel,
    kind: AnimKind.sheet,
    frameW: built.frameW,
    frameH: built.frameH,
    cols: built.frames,
  );
  saveCombinedStrip(packPath, built.png, anim, anim);
  return (
    path: outRel,
    frameW: built.frameW,
    frameH: built.frameH,
    frames: built.frames,
  );
}
