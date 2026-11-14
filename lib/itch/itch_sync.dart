import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;

import '../core/sidecar.dart';
import '../core/type_classifier.dart';
import '../core/fs_tree.dart';
import '../install/archive_extractor.dart';
import '../install/folder_importer.dart';
import 'itch_api.dart';
import 'itch_matcher.dart';
import 'itch_page_scraper.dart';

/// Folder for itch covers and screenshots inside a pack.
const itchMediaDir = '_itch';

/// Uploads worth installing: no platform builds (exe/apk/app); the rest
/// (asset archives, license PDFs, loose files) all go in.
List<ItchUpload> assetUploads(List<ItchUpload> uploads) => [
  for (final u in uploads)
    if (!u.isPlatformBuild) u,
];

/// The author folder for an itch user: an existing folder whose author
/// file points at the same itch account wins, so downloads land next to
/// packs imported earlier.
AuthorInfo authorFor(ItchUser user, String libraryRoot) {
  final root = Directory(libraryRoot);
  if (root.existsSync()) {
    for (final dir in root.listSync().whereType<Directory>()) {
      final info = AuthorInfo.read(p.join(dir.path, authorFileName));
      final slug = info?.itchSlug ?? itchSlugOf(info?.url);
      if (slug != null &&
          {
            user.username.toLowerCase(),
            itchSlugOf(user.url),
          }.contains(slug.toLowerCase())) {
        return AuthorInfo(
          user: p.basename(dir.path),
          url: info?.url ?? user.url,
          itchUser: user.username,
        );
      }
    }
  }
  return AuthorInfo(user: user.name, url: user.url, itchUser: user.username);
}

/// Records the itch game in a pack's sidecar.
void linkPack(String packPath, ItchGame game, {bool downloaded = false}) {
  final old = PackSidecar.read(packPath) ?? const PackSidecar();
  old
      .copyWith(
        itchGameId: game.id,
        itchUrl: game.url,
        source: downloaded ? PackSource.itch : null,
      )
      .write(packPath);
}

/// Saves the cover and up to [maxScreenshots] page screenshots into
/// `<pack>/_itch/`; the preview picker puts the cover first. Missing
/// images are skipped; returns how many files were saved.
Future<int> fetchItchMedia(
  ItchApi api,
  String packPath,
  ItchGame game, {
  int maxScreenshots = 8,
}) async {
  final dir = Directory(p.join(packPath, itchMediaDir));
  final urls = <(String, Uri)>[];
  if (game.coverUrl case final cover?) {
    urls.add(('cover', Uri.parse(cover)));
  }
  try {
    final page = await api.fetchPublic(Uri.parse(game.url));
    if (page.statusCode == 200) {
      for (final (i, uri) in screenshotUrls(
        page.body,
        limit: maxScreenshots,
      ).indexed) {
        urls.add(('screenshot_${'${i + 1}'.padLeft(2, '0')}', uri));
      }
    }
  } on Object {
    // The page is optional; the cover alone is fine.
  }
  var saved = 0;
  for (final (name, uri) in urls) {
    try {
      final r = await api.fetchPublic(uri);
      if (r.statusCode != 200 || r.bodyBytes.isEmpty) continue;
      final ext = imageExtension(uri, contentType: r.headers['content-type']);
      dir.createSync(recursive: true);
      File(p.join(dir.path, '$name.$ext')).writeAsBytesSync(r.bodyBytes);
      saved++;
    } on Object {
      continue;
    }
  }
  return saved;
}

class ItchInstallResult {
  const ItchInstallResult({this.target, this.error, this.skipped = const []});

  /// Library-relative folder of the new pack.
  final String? target;
  final String? error;

  /// Uploads left out (platform builds).
  final List<String> skipped;

  bool get ok => error == null && target != null;
}

/// Top-level so the isolate closure captures nothing but its arguments.
Future<ExtractedArchive> _extract(String archive, String dest) =>
    Isolate.run(() => extractArchive(archive, dest));

Future<ImportOutcome> _import(ImportItem item, String library, String rel) =>
    Isolate.run(() => importItem(item, library, rel));

/// Downloads a game's asset uploads, unpacks them into one pack folder
/// and imports it like any other pack (verified copy, sidecar, author
/// file), then marks it as an itch pack and fetches its media.
///
/// One upload becomes the pack's content; several become sub-folders.
/// [workRoot] holds downloads and extraction and is cleaned up.
Future<ItchInstallResult> installItchGame(
  ItchApi api,
  OwnedKey key, {
  required String libraryRoot,
  required String workRoot,
  void Function(String status, double? progress)? onStatus,
}) async {
  final game = key.game;
  final work = Directory(
    p.join(
      workRoot,
      'itch-${game.id}-${DateTime.now().microsecondsSinceEpoch}',
    ),
  );
  try {
    final all = await api.uploads(key);
    final uploads = assetUploads(all);
    final skipped = [
      for (final u in all)
        if (!uploads.contains(u)) u.filename,
    ];
    if (uploads.isEmpty) {
      return ItchInstallResult(
        error: all.isEmpty
            ? 'No downloadable files'
            : 'Only platform builds (${skipped.join(', ')})',
        skipped: skipped,
      );
    }
    final packDir = Directory(p.join(work.path, safeFolderName(game.title)));
    final downloads = Directory(p.join(work.path, '.downloads'))
      ..createSync(recursive: true);
    for (final (i, upload) in uploads.indexed) {
      final file = File(
        p.join(downloads.path, safeFolderName(upload.filename)),
      );
      final label = uploads.length == 1
          ? upload.filename
          : '${upload.filename} (${i + 1}/${uploads.length})';
      onStatus?.call('Downloading $label', 0);
      await api.download(
        key,
        upload,
        file,
        onProgress: (got, total) => onStatus?.call(
          'Downloading $label',
          total > 0 ? got / total : null,
        ),
      );
      if (archiveKindOf(file.path) != null) {
        onStatus?.call('Extracting $label', null);
        if (uploads.length == 1) {
          final out = await _extract(file.path, p.join(work.path, '.x'));
          Directory(out.folder).renameSync(packDir.path);
        } else {
          packDir.createSync(recursive: true);
          await _extract(file.path, packDir.path);
        }
      } else {
        packDir.createSync(recursive: true);
        file.copySync(p.join(packDir.path, safeFolderName(upload.filename)));
      }
    }

    final files = [
      for (final (rel, entry) in readTree(packDir.path).allFiles())
        (rel, entry),
    ];
    final item = ImportItem(
      sourcePath: packDir.path,
      sourceRel: game.title,
      title: game.title,
      author: authorFor(game.user, libraryRoot),
      types: [for (final t in classifyPack(game.title, files)) t.id],
      tags: suggestTags(game.title),
      fileCount: files.length,
      totalBytes: files.fold(0, (n, f) => n + f.$2.size),
      origin: game.url,
    );
    final rel = ImportPlan(work.path, libraryRoot, [item]).targets()[item]!;
    onStatus?.call('Copying into the library', null);
    final outcome = await _import(item, libraryRoot, rel);
    if (!outcome.verified) {
      return ItchInstallResult(
        error: outcome.error ?? 'Copy could not be verified',
        skipped: skipped,
      );
    }
    final target = p.join(libraryRoot, rel);
    linkPack(target, game, downloaded: true);
    onStatus?.call('Fetching cover and screenshots', null);
    await fetchItchMedia(api, target, game);
    return ItchInstallResult(target: rel, skipped: skipped);
  } on Object catch (e) {
    return ItchInstallResult(error: '$e');
  } finally {
    if (work.existsSync()) work.deleteSync(recursive: true);
  }
}
