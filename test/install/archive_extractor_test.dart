import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:loot_silo/core/sidecar.dart';
import 'package:loot_silo/install/archive_extractor.dart';
import 'package:loot_silo/install/folder_importer.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tmp;
  late String out;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('extract');
    out = p.join(tmp.path, 'out');
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  /// Writes a zip of `name → content` entries (null content = directory).
  String zip(String name, Map<String, String?> entries) {
    final archive = Archive();
    for (final MapEntry(:key, :value) in entries.entries) {
      archive.add(
        value == null
            ? ArchiveFile.directory(key)
            : ArchiveFile.string(key, value),
      );
    }
    final path = p.join(tmp.path, name);
    File(path).writeAsBytesSync(ZipEncoder().encodeBytes(archive));
    return path;
  }

  /// Relative file paths under [dir], sorted.
  List<String> files(String dir) => [
    for (final f in Directory(dir).listSync(recursive: true).whereType<File>())
      p.relative(f.path, from: dir).replaceAll(r'\', '/'),
  ]..sort();

  test('formats and stems', () {
    expect(archiveKindOf('a/Pack.ZIP'), ArchiveKind.zip);
    expect(archiveKindOf('Pack.tar.gz'), ArchiveKind.tarGz);
    expect(archiveKindOf('Pack.tgz'), ArchiveKind.tarGz);
    expect(archiveKindOf('Pack.7z'), ArchiveKind.sevenZip);
    expect(archiveKindOf('Pack.rar'), ArchiveKind.rar);
    expect(archiveKindOf('Pack.png'), isNull);
    expect(archiveStem('/x/Cool Pack v1.2.tar.gz'), 'Cool Pack v1.2');
    expect(archiveStem('Cool Pack v1.2.zip'), 'Cool Pack v1.2');
  });

  test('safeEntryPath rejects escapes', () {
    expect(safeEntryPath('a/b.png'), p.join('a', 'b.png'));
    expect(safeEntryPath(r'a\b.png'), p.join('a', 'b.png'));
    expect(safeEntryPath('./a//b.png'), p.join('a', 'b.png'));
    expect(safeEntryPath('../evil.sh'), isNull);
    expect(safeEntryPath('a/../../evil.sh'), isNull);
    expect(safeEntryPath('/etc/passwd'), isNull);
    expect(safeEntryPath(r'C:\evil.exe'), isNull);
  });

  test('zip without a root folder gets one named after the archive', () {
    final path = zip('Forest Tiles v2.zip', {
      'tiles.png': 'x',
      'readme.txt': 'y',
      '__MACOSX/._tiles.png': 'junk',
      '.DS_Store': 'junk',
    });
    final r = extractArchive(path, out);
    expect(p.basename(r.folder), 'Forest Tiles v2');
    expect(files(r.folder), ['readme.txt', 'tiles.png']);
    expect(Directory(out).listSync().map((e) => p.basename(e.path)), [
      'Forest Tiles v2',
    ], reason: 'no staging left behind');
  });

  test('zip with a root folder keeps its name; single folders collapse', () {
    final path = zip('download_123.zip', {
      'Hero Pack/': null,
      'Hero Pack/Hero Pack/Sprites/idle.png': 'x',
      'Hero Pack/Hero Pack/Sprites/run.png': 'x',
    });
    final r = extractArchive(path, out);
    expect(p.basename(r.folder), 'Hero Pack');
    expect(files(r.folder), ['idle.png', 'run.png']);
  });

  test('a root with several folders is kept as is', () {
    final path = zip('Bundle.zip', {
      'Bundle/Characters/a.png': 'x',
      'Bundle/Tiles/b.png': 'x',
    });
    final r = extractArchive(path, out);
    expect(p.basename(r.folder), 'Bundle');
    expect(files(r.folder), ['Characters/a.png', 'Tiles/b.png']);
  });

  test('zip-slip entries are skipped, name clashes get a suffix', () {
    final path = zip('Pack.zip', {
      '../escaped.txt': 'evil',
      'Pack/../../escaped2.txt': 'evil',
      'a.png': 'x',
      'b.png': 'x',
    });
    final first = extractArchive(path, out);
    final second = extractArchive(path, out);
    expect(files(first.folder), ['a.png', 'b.png']);
    expect(p.basename(second.folder), 'Pack (2)');
    expect(File(p.join(tmp.path, 'escaped.txt')).existsSync(), isFalse);
    expect(File(p.join(out, 'escaped.txt')).existsSync(), isFalse);
  });

  test('tar.gz', () {
    final archive = Archive()
      ..add(ArchiveFile.string('Sounds/hit.wav', 'x'))
      ..add(ArchiveFile.string('Sounds/jump.wav', 'y'));
    final path = p.join(tmp.path, 'sfx.tar.gz');
    File(path).writeAsBytesSync(
      GZipEncoder().encodeBytes(TarEncoder().encodeBytes(archive)),
    );
    final r = extractArchive(path, out);
    expect(p.basename(r.folder), 'Sounds');
    expect(files(r.folder), ['hit.wav', 'jump.wav']);
  });

  test('broken and empty archives fail cleanly', () {
    final bad = p.join(tmp.path, 'bad.zip');
    File(bad).writeAsStringSync('not a zip');
    expect(() => extractArchive(bad, out), throwsA(isA<ExtractError>()));
    final empty = zip('empty.zip', {'__MACOSX/x': 'junk'});
    expect(() => extractArchive(empty, out), throwsA(isA<ExtractError>()));
    expect(Directory(out).listSync(), isEmpty);
  });

  final sevenZip = findTool(['7zz', '7z', '7za']);
  test('7z through the 7-Zip CLI, with a symlink dropped', () {
    final src = Directory(p.join(tmp.path, 'src', 'Orc Pack'))
      ..createSync(recursive: true);
    File(p.join(src.path, 'orc.png')).writeAsStringSync('x');
    File(p.join(src.path, 'orc2.png')).writeAsStringSync('y');
    Link(p.join(src.path, 'link')).createSync('/etc/passwd');
    final path = p.join(tmp.path, 'orcs.7z');
    final made = Process.runSync(sevenZip!, ['a', '-snl', path, src.path]);
    expect(made.exitCode, 0, reason: '${made.stderr}');
    final r = extractArchive(path, out);
    expect(p.basename(r.folder), 'Orc Pack');
    expect(files(r.folder), ['orc.png', 'orc2.png']);
    expect(Link(p.join(r.folder, 'link')).existsSync(), isFalse);
  }, skip: sevenZip == null ? '7-Zip not installed' : false);

  test('missing tools give an actionable error', () {
    expect(findTool(['7z'], environment: {'PATH': tmp.path}), isNull);
  });

  test('extracted archives import with the archive as source_path', () async {
    final a = zip('Forest Tiles v2.zip', {
      'tiles.png': 'x',
      'license.txt': 'CC0',
    });
    final b = zip('orc-pack.zip', {
      'Orc Pack/preview.png': 'x',
      'Orc Pack/readme.txt': 'by https://orcmaker.itch.io/',
      'Orc Pack/orc.png': 'y',
    });
    final library = Directory(p.join(tmp.path, 'library'))..createSync();
    final ea = extractArchive(a, out);
    final eb = extractArchive(b, out);
    final origins = {p.basename(ea.folder): a, p.basename(eb.folder): b};
    final plan = planFolderImport(out, library.path, origins: origins);
    expect(
      {for (final i in plan.items) i.sourceRel: i.origin},
      {'Forest Tiles v2': a, 'Orc Pack': b},
    );
    final orc = plan.items.firstWhere((i) => i.sourceRel == 'Orc Pack');
    expect(orc.author?.user, 'orcmaker');
    final outcomes = await runImport(plan).toList();
    expect(outcomes.every((o) => o.verified), isTrue);
    final sidecar = PackSidecar.read(
      p.join(library.path, 'orcmaker', 'Orc Pack'),
    )!;
    expect(sidecar.sourcePath, b);
    expect(sidecar.source, PackSource.imported);

    // Importing the same archives again starts with them unselected.
    final again = planFolderImport(out, library.path, origins: origins);
    expect(again.items.map((i) => i.importedAs), everyElement(isNotNull));
  });
}
