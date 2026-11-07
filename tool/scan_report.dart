// Read-only scan report: `dart run tool/scan_report.dart <folder>`.
import 'dart:io';

import 'package:loot_silo/core/library_scanner.dart';

void main(List<String> args) {
  final r = scanLibrary(args.single);
  final authors = <String>{for (final pk in r.packs) ?pk.author?.user};
  for (final pk in r.packs) {
    final indent = pk.parentId == null ? '' : '    ';
    stdout.writeln(
      '$indent${pk.isContainer ? '[bundle] ' : ''}${pk.id}'
      '  | ${pk.author?.user ?? '?'} | ${pk.types.join(',')} | ${pk.tags.join(',')} | ${pk.files.length} files | ${pk.preview} ${pk.previewAnim == null ? '' : '[${pk.previewAnim!.frameW}x${pk.previewAnim!.frameH} ${pk.previewAnim!.cols}x${pk.previewAnim!.rows} ${pk.previewAnim!.kind.name}]'}',
    );
  }
  stdout.writeln(
    '\npacks=${r.packs.length} top-level=${r.packs.where((x) => x.parentId == null).length} '
    'authors=${authors.length} authorFiles=${r.resolvedAuthorFiles.length} '
    'noAuthor=${r.packs.where((x) => x.author == null).length} elapsed=${r.elapsed.inMilliseconds}ms',
  );
}
