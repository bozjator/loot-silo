// The user files as Loot Silo 1.0.0 (format version 1) writes them, frozen
// in test/fixtures/format_v1. Never edit those files: when a format
// changes, add the next version's fixtures beside them and keep these
// loading (CLAUDE.md, "Data compatibility").
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:loot_silo/core/sidecar.dart';
import 'package:loot_silo/state/settings.dart';
import 'package:path/path.dart' as p;

const fixtures = 'test/fixtures/format_v1';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('format_v1'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('settings.json v1 loads every value and saves back unchanged', () {
    final original = File(p.join(fixtures, 'settings.json')).readAsStringSync();
    final file = File(p.join(tmp.path, 'settings.json'))
      ..writeAsStringSync(original);
    final store = SettingsStore(file);
    final s = store.load();
    expect(s.libraryPath, '/home/user/Game Assets');
    expect(s.theme, ThemeChoice.system);
    expect(s.extra, isEmpty, reason: 'every v1 key is known');
    final session = s.lastSession!;
    expect(session.tabs.map((t) => t.packId), [
      'RafaelMatos/Epic RPG World - Volcano',
      'Kenney/Kenney Game Assets 2',
    ]);
    expect(session.tabs[1].tab, 'audio');
    expect(session.active, 1);
    expect(session.dashboardPage?.tab, 'animations');
    expect(session.sort, 'title');
    expect(session.treeExpanded, ['RafaelMatos']);

    store.save(s);
    expect(jsonDecode(file.readAsStringSync()), jsonDecode(original));
  });

  test('asset_pack.json v1 loads every value and saves back unchanged', () {
    final dir = Directory(p.join(tmp.path, 'Volcano'))..createSync();
    final original = File(p.join(fixtures, 'asset_pack.json'))
        .readAsStringSync();
    File(p.join(dir.path, 'asset_pack.json')).writeAsStringSync(original);
    final pack = PackSidecar.read(dir.path)!;
    expect(pack.title, 'Epic RPG World - Volcano');
    expect(pack.source, PackSource.itch);
    expect(pack.itchGameId, 3095455);
    expect(pack.previews, hasLength(2));
    expect(pack.notes, isNotNull);
    expect(pack.usedIn, ['Pirates']);
    expect(pack.animations, hasLength(2));
    expect(pack.favorite, isTrue);
    expect(pack.favoriteFiles, hasLength(1));
    expect(pack.layout, PackLayout.pack);
    expect(pack.extra, isEmpty, reason: 'every v1 key is known');

    expect(pack.toJson(), jsonDecode(original));
  });

  test('ASSET_AUTHOR.txt v1 loads every value and saves back unchanged', () {
    final original = File(p.join(fixtures, 'ASSET_AUTHOR.txt'))
        .readAsStringSync();
    final author = AuthorInfo.parse(original)!;
    expect(author.user, 'RafaelMatos');
    expect(author.url, 'https://rafaelmatos.itch.io');
    expect(author.itchSlug, 'rafaelmatos');
    expect(author.license, 'CC BY 4.0');
    expect(author.credit, 'Rafael Matos (rafaelmatos.itch.io)');
    expect(author.attribution, 'required');

    expect(author.serialize(), original);
  });
}
