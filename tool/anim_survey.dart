// Read-only animation survey: `dart run tool/anim_survey.dart <library>`.
// Prints one line per detected animation (as the pack page detects them),
// so two runs can be diffed before and after a detector change.
import 'dart:io';

import 'package:loot_silo/core/library_scanner.dart';
import 'package:loot_silo/core/pack_editor.dart';

void main(List<String> args) {
  final packs = scanLibrary(args.single).packs;
  for (final pack in packs..sort((a, b) => a.id.compareTo(b.id))) {
    final contents = loadPackContents(pack.path, [
      for (final f in pack.files) (f, 0),
    ]);
    for (final a in contents.detected) {
      stdout.writeln(
        '${pack.id} | ${a.path} | ${a.kind.name} '
        '${a.frameW}x${a.frameH} ${a.cols}x${a.rows} n=${a.frameCount}',
      );
    }
  }
}
