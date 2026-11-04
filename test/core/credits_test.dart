import 'dart:io';

import 'package:assets_explorer/core/credits.dart';
import 'package:assets_explorer/core/library_index.dart';
import 'package:assets_explorer/core/pack_editor.dart';
import 'package:assets_explorer/core/sidecar.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('credits'));
  tearDown(() => tmp.deleteSync(recursive: true));

  PackRow pack(String id, List<String> usedIn, {String? author}) => PackRow(
    id: id,
    path: p.join(tmp.path, id),
    title: id.split('/').last,
    author: author ?? id.split('/').first,
    isContainer: false,
    types: const [],
    tags: const [],
    usedIn: usedIn,
    fileCount: 1,
    totalBytes: 1,
  );

  test('groups packs per author with license and credit wording', () {
    Directory(p.join(tmp.path, 'Matt Firth (shikashipx)')).createSync();
    const AuthorInfo(
      user: 'Matt Firth (shikashipx)',
      url: 'https://shikashipx.itch.io/',
      license: 'Commercial use and editing allowed',
      extra: {'credit': 'Matt Firth (shikashipx)', 'attribution': 'required'},
    ).write(p.join(tmp.path, 'Matt Firth (shikashipx)'));
    Directory(p.join(tmp.path, 'Kenney')).createSync();
    const AuthorInfo(
      user: 'Kenney',
      url: 'https://kenney.itch.io/',
      license: 'CC0',
    ).write(p.join(tmp.path, 'Kenney'));

    final packs = [
      pack('Kenney/Tiny Town', ['Orc Siege']),
      pack('Kenney/Bundle/Sub', ['Orc Siege', 'Other']),
      pack('Kenney/Unused', []),
      pack('Matt Firth (shikashipx)/Icons', ['Orc Siege']),
      pack('Nobody/Loose', ['Orc Siege'], author: 'Nobody'),
    ];
    expect(knownGames(packs), ['Orc Siege', 'Other']);

    final credits = collectCredits(tmp.path, packs, 'Orc Siege');
    expect([for (final c in credits) c.displayName], [
      'Kenney',
      'Matt Firth (shikashipx)',
      'Nobody',
    ]);
    expect(credits.first.packs, ['Sub', 'Tiny Town']);
    expect(credits.first.license, 'CC0');
    expect(credits[1].attribution, 'required');
    expect(credits.last.url, isNull);

    final md = creditsMarkdown('Orc Siege', credits);
    expect(md, startsWith('# Credits — Orc Siege'));
    expect(md, contains('## Kenney\n\n- Website: <https://kenney.itch.io/>'));
    expect(md, contains('- License: CC0\n- Assets: Sub, Tiny Town'));
    final txt = creditsText('Orc Siege', credits);
    expect(txt, contains('Kenney — https://kenney.itch.io/\n  License: CC0'));
    expect(txt, contains('Nobody\n  Assets: Loose'));
  });

  test('setUsedIn and updateAuthorInfo edit the sidecar files', () {
    final packDir = Directory(p.join(tmp.path, 'A', 'Pack'))
      ..createSync(recursive: true);
    setUsedIn(packDir.path, 'Game', used: true);
    setUsedIn(packDir.path, 'Game 2', used: true);
    setUsedIn(packDir.path, 'Game', used: false);
    expect(PackSidecar.read(packDir.path)!.usedIn, ['Game 2']);

    final authorDir = p.join(tmp.path, 'A');
    updateAuthorInfo(authorDir, license: 'CC0', credit: 'A. Person');
    var info = AuthorInfo.read(p.join(authorDir, authorFileName))!;
    expect((info.user, info.license, info.credit), ('A', 'CC0', 'A. Person'));
    updateAuthorInfo(authorDir, url: 'https://a.itch.io/', credit: '');
    info = AuthorInfo.read(p.join(authorDir, authorFileName))!;
    expect((info.url, info.license, info.credit), (
      'https://a.itch.io/',
      'CC0',
      null,
    ));
  });
}
