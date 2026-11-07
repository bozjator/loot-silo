import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:loot_silo/core/library_index.dart';
import 'package:loot_silo/core/sidecar.dart';
import 'package:loot_silo/itch/itch_api.dart';
import 'package:loot_silo/itch/itch_key.dart';
import 'package:loot_silo/itch/itch_matcher.dart';
import 'package:loot_silo/itch/itch_page_scraper.dart';
import 'package:loot_silo/itch/itch_sync.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;

const secret = 'SECRET-KEY-123';

Map<String, Object?> gameJson(
  int id,
  String title, {
  String user = 'orcmaker',
  String? cover,
}) => {
  'id': id,
  'title': title,
  'url': 'https://$user.itch.io/${title.toLowerCase().replaceAll(' ', '-')}',
  'classification': 'assets',
  'cover_url': cover,
  'user': {
    'id': 7,
    'username': user,
    'display_name': user == 'orcmaker' ? 'Orc Maker' : null,
    'url': 'https://$user.itch.io',
  },
};

OwnedKey key(int id, String title, {String user = 'orcmaker'}) =>
    OwnedKey.fromJson({'id': id * 10, 'game': gameJson(id, title, user: user)});

PackRow pack(
  String id, {
  String? author,
  String? url,
  int? itchGameId,
  String? parent,
}) => PackRow(
  id: id,
  path: '/lib/$id',
  title: id.split('/').last,
  author: author ?? id.split('/').first,
  authorUrl: url,
  parentId: parent,
  isContainer: false,
  types: const [],
  tags: const [],
  usedIn: const [],
  favorite: false,
  favoriteFiles: const [],
  itchGameId: itchGameId,
  fileCount: 1,
  totalBytes: 1,
);

void main() {
  group('ItchApi', () {
    test('owned keys follow pages; an empty page is {}', () async {
      final pages = <String>[];
      final api = ItchApi(
        secret,
        client: MockClient((r) async {
          expect(r.headers['Authorization'], 'Bearer $secret');
          final page = r.url.queryParameters['page']!;
          pages.add(page);
          final keys = switch (page) {
            '1' => [
              {'id': 1, 'game': gameJson(11, 'A')},
              {'id': 2, 'game': gameJson(12, 'B')},
            ],
            '2' => [
              {'id': 3, 'game': gameJson(13, 'C')},
            ],
            _ => <String, Object?>{},
          };
          return http.Response(
            jsonEncode({'owned_keys': keys, 'per_page': 2, 'page': page}),
            200,
          );
        }),
      );
      final keys = await api.ownedKeys();
      expect(keys.map((k) => k.game.title), ['A', 'B', 'C']);
      expect(pages, ['1', '2'], reason: 'short page ends the listing');
      expect(keys.first.game.user.name, 'Orc Maker');
    });

    test('auth errors never echo the key', () async {
      final api = ItchApi(
        secret,
        client: MockClient(
          (_) async => http.Response('{"errors":["invalid key"]}', 401),
        ),
      );
      await expectLater(
        api.profile(),
        throwsA(
          isA<ItchApiException>()
              .having((e) => e.isAuthError, 'auth', isTrue)
              .having((e) => '$e', 'message', isNot(contains(secret))),
        ),
      );
    });

    test('uploads: traits as {} or list, platform builds', () async {
      final api = ItchApi(
        secret,
        client: MockClient(
          (r) async => http.Response(
            jsonEncode({
              'uploads': [
                {'id': 1, 'filename': 'pack.zip', 'size': 10, 'traits': {}},
                {
                  'id': 2,
                  'filename': 'demo.exe',
                  'traits': ['p_windows'],
                },
                {'id': 3, 'filename': 'tool', 'type': 'executable'},
                {
                  'id': 4,
                  'filename': 'License.pdf',
                  'type': 'documentation',
                  'traits': ['demo'],
                },
              ],
            }),
            200,
          ),
        ),
      );
      final ups = await api.uploads(key(1, 'X'));
      expect(ups.map((u) => u.isPlatformBuild), [false, true, true, false]);
      expect(assetUploads(ups).map((u) => u.filename), [
        'pack.zip',
        'License.pdf',
      ]);
    });

    test('download follows the redirect without the key', () async {
      final tmp = Directory.systemTemp.createTempSync('dl');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final api = ItchApi(
        secret,
        client: MockClient((r) async {
          if (r.url.host == 'api.itch.io') {
            expect(r.url.path, '/uploads/5/download');
            expect(r.url.queryParameters['download_key_id'], '10');
            return http.Response(
              '',
              302,
              headers: {'location': 'https://cdn.example/file'},
            );
          }
          expect(r.headers.containsKey('Authorization'), isFalse);
          return http.Response('hello', 200);
        }),
      );
      final file = File(p.join(tmp.path, 'f.zip'));
      await api.download(
        key(1, 'X'),
        const ItchUpload(id: 5, filename: 'f.zip', size: 5),
        file,
      );
      expect(file.readAsStringSync(), 'hello');
      await expectLater(
        api.download(
          key(1, 'X'),
          const ItchUpload(id: 5, filename: 'f.zip', size: 99),
          file,
        ),
        throwsA(isA<ItchApiException>()),
        reason: 'size mismatch',
      );
    });
  });

  group('matcher', () {
    test('title tokens', () {
      expect(titleTokens('Magic & Spells SFX 07 v1.2'), [
        'magic',
        'spell',
        'sound',
        'effect',
        '7',
      ]);
      expect(titleTokens('CharactersAnimationsAssetPack'), [
        'character',
        'animation',
      ]);
    });

    test('pairs real-world titles and keeps numbers apart', () {
      const url = 'https://elvgames.itch.io/';
      final packs = [
        pack('E/Monster Sound Effects 4', url: url),
        pack('E/Game Sound Effects Pack 4', url: url),
        pack('E/Magic & Spells SFX 7', url: url),
        pack('E/Magic and Spells 1 - Universal Sound Effects', url: url),
        pack('R/ERW - Grass Land 2.0 v2.1', url: 'https://rafaelmatos.itch.io'),
        pack('K/Bundle/Space Shooter Pack', author: 'Kenney', parent: 'K/B'),
        pack('P/Pixel-Banner', url: 'https://pixel-banner.itch.io'),
        pack('Z/Done', url: 'https://zerie.itch.io', itchGameId: 99),
      ];
      final keys = [
        key(1, 'Monster Sound Effects 4 - Universal', user: 'elvgames'),
        key(2, 'Game Sound Effects 4 - Universal', user: 'elvgames'),
        key(3, 'Magic & Spells Sound Effects 7', user: 'elvgames'),
        key(4, 'Epic RPG World - Grass Land 2.0', user: 'rafaelmatos'),
        key(5, 'Space Shooter Pack', user: 'someoneelse'),
        key(6, 'Axe Skeleton – 32x32 Animated RPG Enemy', user: 'pixel-banner'),
        key(99, 'Whatever', user: 'zerie'),
        key(3, 'Magic & Spells Sound Effects 7', user: 'elvgames'),
      ];
      final m = {
        for (final x in matchOwnedKeys(
          keys,
          packs,
          folders: {
            'P/Pixel-Banner': {'AxeSkeleton', 'BruteGoblin'},
          },
        ))
          x.key.game.id: x,
      };
      expect(m.length, 7, reason: 'duplicate key collapsed');
      expect(m[1]!.pack!.id, 'E/Monster Sound Effects 4');
      expect(m[2]!.pack!.id, 'E/Game Sound Effects Pack 4');
      expect(m[3]!.pack!.id, 'E/Magic & Spells SFX 7');
      expect(m[4]!.pack!.id, 'R/ERW - Grass Land 2.0 v2.1', reason: 'acronym');
      expect(m[5]!.kind, MatchKind.missing, reason: 'other author');
      expect(m[6]!.kind, MatchKind.inside);
      expect(m[6]!.pack!.id, 'P/Pixel-Banner');
      expect(m[99]!.kind, MatchKind.linked);
    });

    test('folderNamesOf', () {
      expect(folderNamesOf(['a/b/c/x.png', 'y.png', 'a/z.png']), {'a', 'b'});
    });
  });

  test('screenshot scraping', () {
    const html = '''
<div class="screenshot_list">
  <a href="https://img.itch.zone/a/original/1.gif"><img src="x"></a>
  <a href="https://img.itch.zone/a/original/2.png"><img src="y"></a>
  <a href="javascript:void(0)"></a>
  <a href="https://img.itch.zone/a/original/1.gif"></a>
</div>''';
    final urls = screenshotUrls(html);
    expect(urls.map((u) => u.path), ['/a/original/1.gif', '/a/original/2.png']);
    expect(imageExtension(urls.first), 'gif');
    expect(
      imageExtension(Uri.parse('https://x/y'), contentType: 'image/jpeg'),
      'jpg',
    );
  });

  test('keyFromEnvironment', () {
    final tmp = Directory.systemTemp.createTempSync('key');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final env = File(p.join(tmp.path, 'app.env'))
      ..writeAsStringSync('# x\nexport ITCH_API_KEY="abc"\n');
    expect(readKeyFromEnvFile(env.path), 'abc');
    expect(keyFromEnvironment(environment: {'ITCH_API_KEY': ' k '}), 'k');
    expect(
      keyFromEnvironment(
        environment: {'ITCH_ENV_FILE': env.path},
        workingDirectory: tmp.path,
      ),
      'abc',
    );
    expect(
      keyFromEnvironment(environment: const {}, workingDirectory: tmp.path),
      isNull,
    );
  });

  test('installItchGame downloads, imports, links and fetches media', () async {
    final tmp = Directory.systemTemp.createTempSync('itch');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final library = Directory(p.join(tmp.path, 'library'))..createSync();
    // An existing author folder with the same itch account is reused.
    Directory(p.join(library.path, 'Orcs Inc')).createSync();
    const AuthorInfo(
      user: 'Orcs Inc',
      url: 'https://orcmaker.itch.io/',
    ).write(p.join(library.path, 'Orcs Inc'));

    final zip = ZipEncoder().encodeBytes(
      Archive()
        ..add(ArchiveFile.string('orcs/orc_idle.png', 'png'))
        ..add(ArchiveFile.string('orcs/readme.txt', 'hi')),
    );
    final requests = <String>[];
    final api = ItchApi(
      secret,
      client: MockClient((r) async {
        requests.add('${r.url.host}${r.url.path}');
        if (r.url.host != 'api.itch.io') {
          expect(r.headers.containsKey('Authorization'), isFalse);
        }
        return switch ('${r.url.host}${r.url.path}') {
          'api.itch.io/games/1/uploads' => http.Response(
            jsonEncode({
              'uploads': [
                {'id': 5, 'filename': 'Orc Pack.zip', 'size': zip.length},
                {
                  'id': 6,
                  'filename': 'orcs.exe',
                  'traits': ['p_windows'],
                },
              ],
            }),
            200,
          ),
          'api.itch.io/uploads/5/download' => http.Response(
            '',
            302,
            headers: {'location': 'https://cdn.example/orc.zip'},
          ),
          'cdn.example/orc.zip' => http.Response.bytes(zip, 200),
          'orcmaker.itch.io/orc-pack' => http.Response(
            '<div class="screenshot_list">'
            '<a href="https://img.example/s1.png"></a></div>',
            200,
          ),
          'img.example/cover.png' ||
          'img.example/s1.png' => http.Response.bytes([1, 2, 3], 200),
          _ => http.Response('nope', 404),
        };
      }),
    );
    final k = OwnedKey.fromJson({
      'id': 10,
      'game': gameJson(1, 'Orc Pack', cover: 'https://img.example/cover.png'),
    });
    final statuses = <String>[];
    final result = await installItchGame(
      api,
      k,
      libraryRoot: library.path,
      workRoot: p.join(tmp.path, 'work'),
      onStatus: (s, _) => statuses.add(s),
    );
    expect(result.error, isNull);
    expect(result.target, 'Orcs Inc/Orc Pack');
    expect(result.skipped, ['orcs.exe']);
    final packDir = p.join(library.path, 'Orcs Inc', 'Orc Pack');
    expect(File(p.join(packDir, 'orc_idle.png')).existsSync(), isTrue);
    expect(File(p.join(packDir, '_itch', 'cover.png')).existsSync(), isTrue);
    expect(
      File(p.join(packDir, '_itch', 'screenshot_01.png')).existsSync(),
      isTrue,
    );
    final sc = PackSidecar.read(packDir)!;
    expect(sc.source, PackSource.itch);
    expect(sc.itchGameId, 1);
    expect(sc.itchUrl, 'https://orcmaker.itch.io/orc-pack');
    expect(sc.cover, '_itch/cover.png');
    expect(sc.sourcePath, 'https://orcmaker.itch.io/orc-pack');
    final author = AuthorInfo.read(
      p.join(library.path, 'Orcs Inc', authorFileName),
    )!;
    expect(author.itchUser, 'orcmaker');
    expect(Directory(p.join(tmp.path, 'work')).listSync(), isEmpty);
    expect(statuses, contains('Downloading Orc Pack.zip'));
  });
}
