import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

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

  /// Paths relative to the pack, sorted.
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

  /// Only files matching a search ([fileMatches]); an animation stays when
  /// its sheet or any of its frames matches.
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
          if (hit(a.path) || a.frames.any(hit)) a,
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
  List<String> carousel(String? preview, {int limit = 100}) => [
    ?preview,
    ...previewCandidates(images).where((f) => f != preview),
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
  return PackContents(
    images: images..sort(),
    audio: audio..sort(),
    other: other..sort(),
    // Effect packs often hold grids with no size hints; a few full
    // decodes find them by their transparent gaps.
    detected: detectAnimations(
      packPath,
      images,
      manual: manualAnimations(sidecar?.animations ?? const {}),
      maxPixelScans: worthPixelScan(packPath) ? 24 : 0,
    ),
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
      if (anim.playRow != detected.playRow)
        'rows': anim.playRow < 0 ? 'all' : anim.playRow + 1,
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

/// What [combineFrames] wrote.
typedef CombinedStrip = ({String path, int frameW, int frameH, int frames});

/// Stacks the images [rels] (natural order) left to right into one PNG at
/// [outRel]. Frames of different sizes are centred in the largest frame
/// size. The frame files stay. Records the strip in the sidecar as a
/// `manual` animation with its frame size. Pure Dart; see
/// [combineFramesInBackground].
CombinedStrip combineFrames(String packPath, List<String> rels, String outRel) {
  final ordered = [...rels]..sort(naturalCompare);
  final frames = <img.Image>[];
  for (final rel in ordered) {
    final decoded = img.decodeImage(
      File(p.join(packPath, rel)).readAsBytesSync(),
    );
    if (decoded == null) throw FormatException('Not an image: $rel');
    frames.add(decoded.convert(numChannels: 4));
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
  File(p.join(packPath, outRel))
    ..parent.createSync(recursive: true)
    ..writeAsBytesSync(img.encodePng(strip));
  final old = PackSidecar.read(packPath) ?? const PackSidecar();
  old
      .copyWith(
        animations: {
          ...old.animations,
          outRel: {'manual': true, 'frame_w': fw, 'frame_h': fh},
        },
      )
      .write(packPath);
  return (path: outRel, frameW: fw, frameH: fh, frames: frames.length);
}

/// [combineFrames] in an isolate.
Future<CombinedStrip> combineFramesInBackground(
  String packPath,
  List<String> rels,
  String outRel,
) => Isolate.run(() => combineFrames(packPath, rels, outRel));
