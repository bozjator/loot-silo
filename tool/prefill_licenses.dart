// Fills `license:`, `credit:` and `attribution:` in the library's author
// files from the "Licenses and credits" table of the old hand-written
// INDEX.md. Only missing values are written; dry run unless --write.
//
//   dart run tool/prefill_licenses.dart <INDEX.md> <library> [--write]
import 'dart:io';

import 'package:assets_explorer/core/author_resolver.dart';
import 'package:assets_explorer/core/pack_editor.dart';
import 'package:assets_explorer/core/sidecar.dart';
import 'package:path/path.dart' as p;

void main(List<String> args) {
  if (args.length < 2) {
    stderr.writeln('usage: prefill_licenses <INDEX.md> <library> [--write]');
    exit(64);
  }
  final write = args.contains('--write');
  final rows = parseLicenseTable(File(args[0]).readAsStringSync());
  final folders = [
    for (final d in Directory(args[1]).listSync().whereType<Directory>())
      p.basename(d.path),
  ];
  for (final row in rows) {
    final folder = matchFolder(row, folders);
    if (folder == null) {
      stdout.writeln('skip  ${row.author} (no single author folder)');
      continue;
    }
    final dir = p.join(args[1], folder);
    final info =
        AuthorInfo.read(p.join(dir, authorFileName)) ??
        AuthorInfo(user: folder);
    final license = info.license == null ? row.license : null;
    final credit = info.credit == null ? row.credit : null;
    final attribution = info.attribution == null ? row.attribution : null;
    if (license == null && credit == null && attribution == null) {
      stdout.writeln('keep  $folder');
      continue;
    }
    stdout.writeln(
      '${write ? 'write' : 'would'} $folder: '
      'license=${license ?? '-'} credit=${credit ?? '-'} '
      'attribution=${attribution ?? '-'}',
    );
    if (write) {
      updateAuthorInfo(
        dir,
        license: license,
        credit: credit,
        attribution: attribution,
      );
    }
  }
}

typedef LicenseRow = ({
  String author,
  String? license,
  String? credit,
  String? attribution,
});

/// Rows of the `| Author | License summary | Credit |` table.
List<LicenseRow> parseLicenseTable(String markdown) {
  final out = <LicenseRow>[];
  var inTable = false;
  for (final line in markdown.split('\n')) {
    final t = line.trim();
    if (t.startsWith('| Author')) {
      inTable = true;
      continue;
    }
    if (!inTable) continue;
    if (!t.startsWith('|')) break;
    if (t.startsWith('|---')) continue;
    final cells = t.split('|').map((c) => c.trim()).toList();
    if (cells.length < 4) continue;
    final (author, license, credit) = (cells[1], cells[2], cells[3]);
    // Rows naming several authors carry no usable license.
    if (author.contains(',')) continue;
    // "Same terms; …" refers to the row above.
    var summary = license.replaceAll('`', '');
    final same = RegExp(r'^Same terms;?\s*').firstMatch(summary);
    if (same != null && out.isNotEmpty && out.last.license != null) {
      final rest = summary.substring(same.end);
      summary = rest.isEmpty
          ? out.last.license!
          : '${out.last.license!} Note: $rest.';
    }
    final required = RegExp(
      r'^Required:\s*(?:exact wording\s*)?"?([^"]+?)"?$',
    ).firstMatch(credit);
    out.add((
      author: author.replaceAll(RegExp(r'\s*\(`.*`\)'), ''),
      license: summary.isEmpty ? null : summary,
      credit: required?.group(1),
      attribution: required != null
          ? 'required'
          : credit.startsWith('Optional') || credit.startsWith('Not required')
          ? 'optional'
          : null,
    ));
  }
  return out;
}

/// The author folder a row belongs to: exact credit wording, then exact
/// name, then the one folder whose name contains it.
String? matchFolder(LicenseRow row, List<String> folders) {
  String n(String s) => normalizeName(s);
  for (final key in [?row.credit, row.author]) {
    final exact = folders.where((f) => n(f) == n(key)).toList();
    if (exact.length == 1) return exact.single;
  }
  final partial = folders.where((f) => n(f).contains(n(row.author))).toList();
  return partial.length == 1 ? partial.single : null;
}
