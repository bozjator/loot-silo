// Non-interactive folder import with the default (recommended) plan:
// `dart run tool/import_folder.dart <source> <library>`.
// Uses the same core as the review screen; the source is only read.
import 'dart:io';

import 'package:loot_silo/install/folder_importer.dart';

Future<void> main(List<String> args) async {
  final [source, library] = args;
  final plan = planFolderImport(source, library);
  final skipped = plan.items.where((i) => !i.selected).length;
  stdout.writeln(
    '${plan.items.length} packs, ${plan.selected.length} selected, $skipped already imported',
  );
  var ok = 0;
  final failed = <ImportOutcome>[];
  await for (final o in runImport(plan)) {
    if (o.verified) {
      ok++;
    } else {
      failed.add(o);
    }
    stdout.writeln(
      '${o.verified ? 'OK  ' : 'FAIL'} ${o.target} (${o.copiedFiles}/${o.sourceFiles} files)'
      '${o.error == null ? '' : ' ${o.error}'}',
    );
  }
  stdout.writeln('\n$ok verified, ${failed.length} failed');
  exitCode = failed.isEmpty ? 0 : 1;
}
