import 'package:path/path.dart' as p;

import 'animation_detector.dart';
import 'fs_tree.dart';
import 'preview_picker.dart';

/// One first-level folder of a pack that the dashboard can show as its own
/// tile (the "Expanded" view), e.g. each character of Pixel-Banner.
class SubFolder {
  const SubFolder({
    required this.folder,
    required this.preview,
    this.previewAnim,
    required this.fileCount,
    required this.totalBytes,
  });

  /// Folder name relative to the pack (first level, no slash).
  final String folder;

  /// Representative image relative to [folder].
  final String? preview;

  /// Frame data when [preview] is a sprite sheet; paths in it
  /// are relative to [folder] too.
  final SpriteAnim? previewAnim;
  final int fileCount;
  final int totalBytes;
}

/// Folders that only sort a pack by format, size or purpose; they never
/// make a pack "a collection of distinct things".
final _organizational = RegExp(
  r'^_|^(png|jpe?g|gif|webp|psd|aseprite|ase|svg|vectors?|sources?|exports?|'
  r'sprites?|sprite ?sheets?|spritesheets?|sheets?|frames?|separated|'
  r'separate ?frames?|individual( ?frames| ?sprites)?|singles?|'
  r'previews?|mockups?|screenshots?|samples?|examples?|showcase|'
  r'docs?|documentation|licen[cs]es?|fonts?|audio|sounds?|sfx|music|'
  r'godot|unity|gamemaker|game ?maker|rpg ?maker( ?mv| ?mz)?|tiled|'
  r'tilesets?|tiles|backgrounds?|ui|gui|icons|'
  r'\d+x\d*|x\d+|\d+px|@?\dx|with(out)? ?shadows?|no ?shadows?|'
  r'black|white|light|dark|default|other|misc|extras?)$',
  caseSensitive: false,
);

/// Splits a pack into tiles by first-level folder when at least two
/// folders hold images of their own; otherwise returns nothing and the pack
/// stays one tile.
///
/// [files] are the pack's files relative to [packPath]; [overrides] the
/// sidecar's animation overrides (pack-relative keys).
List<SubFolder> splitSubFolders(
  String packPath,
  List<(String, FileEntry)> files, {
  Map<String, Object?> overrides = const {},
}) {
  final byFolder = <String, List<(String, FileEntry)>>{};
  for (final (rel, f) in files) {
    final slash = rel.indexOf('/');
    if (slash < 0) continue;
    final folder = rel.substring(0, slash);
    if (_organizational.hasMatch(folder)) continue;
    (byFolder[folder] ??= []).add((rel.substring(slash + 1), f));
  }
  byFolder.removeWhere(
    (_, fs) => !fs.any((e) => previewExts.contains(e.$2.ext)),
  );
  if (byFolder.length < 2) return const [];

  final folders = byFolder.keys.toList()
    ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  return [
    for (final folder in folders)
      _tile(packPath, folder, byFolder[folder]!, overrides),
  ];
}

SubFolder _tile(
  String packPath,
  String folder,
  List<(String, FileEntry)> files,
  Map<String, Object?> overrides,
) {
  final pick = pickPreviewRanked(files);
  final prefix = '$folder/';
  final chosen = choosePreviewAnimation(
    p.join(packPath, folder),
    [for (final (rel, _) in files) rel],
    preview: pick?.path,
    rank: pick?.rank ?? 6,
    overrides: {
      for (final e in overrides.entries)
        if (e.key.startsWith(prefix)) e.key.substring(prefix.length): e.value,
    },
  );
  return SubFolder(
    folder: folder,
    preview: chosen.preview,
    previewAnim: chosen.anim,
    fileCount: files.length,
    totalBytes: files.fold(0, (sum, e) => sum + e.$2.size),
  );
}
