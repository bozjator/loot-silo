import 'dart:io';

import 'package:path/path.dart' as p;

import 'animation_detector.dart';
import 'file_search.dart';
import 'preview_picker.dart';
import 'sidecar.dart';
import 'type_classifier.dart';

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

  /// Images worth flipping through at the top of the page: the tile
  /// preview first, then itch covers and named previews, at most [limit].
  List<String> carousel(String? preview, {int limit = 12}) {
    final out = <String>[?preview];
    for (final f in images) {
      if (out.length >= limit) break;
      if (out.contains(f)) continue;
      final words = pathWords(f);
      if (f.startsWith('_itch/') ||
          words.any(
            const {
              'preview',
              'mockup',
              'cover',
              'showcase',
              'screenshot',
              'thumbnail',
            }.contains,
          )) {
        out.add(f);
      }
    }
    return out;
  }
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
PackSidecar saveAnimationOverride(
  String packPath,
  SpriteAnim detected,
  SpriteAnim? anim,
) {
  final old = PackSidecar.read(packPath) ?? const PackSidecar();
  final animations = {...old.animations}..remove(detected.path);
  if (anim != null) {
    final o = <String, Object?>{
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
