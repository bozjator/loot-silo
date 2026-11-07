import 'dart:io';

import 'package:assets_explorer/core/sidecar.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AuthorInfo', () {
    test('parses the original user/url format', () {
      final a = AuthorInfo.parse(
        'user: Kenney\nurl: https://kenney.itch.io/\n',
      )!;
      expect(a.user, 'Kenney');
      expect(a.url, 'https://kenney.itch.io/');
      expect(a.itchSlug, 'kenney');
    });

    test('keeps extended and unknown keys through a round trip', () {
      const text =
          'user: Matt Firth (shikashipx)\r\n'
          'url: https://shikashipx.itch.io/\n'
          'itch_user: shikashipx\nlicense: CC0\nTwitter: @matt\n';
      final a = AuthorInfo.parse(text)!;
      expect(a.itchUser, 'shikashipx');
      expect(a.license, 'CC0');
      expect(a.extra, {'twitter': '@matt'});
      expect(AuthorInfo.parse(a.serialize()), a);
      expect(AuthorInfo.parse(a.serialize())!.extra, a.extra);
    });

    test('needs a user line', () {
      expect(AuthorInfo.parse('url: https://x.itch.io/'), isNull);
      expect(AuthorInfo.parse(''), isNull);
    });

    test('itchSlug is null for non-itch urls', () {
      expect(
        const AuthorInfo(user: 'a', url: 'https://example.com').itchSlug,
        isNull,
      );
      expect(const AuthorInfo(user: 'a').itchSlug, isNull);
    });
  });

  group('PackSidecar', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('sidecar'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('reads the managed fixture, keeping unknown keys', () {
      final sc = PackSidecar.read(
        'test/fixtures/managed/HeroMaker/Knight Pack',
      )!;
      expect(sc.title, 'Knight Pack');
      expect(sc.types, ['character']);
      expect(sc.tags, ['knight', 'pixel-art']);
      expect(sc.source, PackSource.imported);
      expect(sc.usedIn, ['My Game']);
      expect(sc.extra, {'future_field': 42});
    });

    test('write then read round-trips every field', () {
      const sc = PackSidecar(
        title: 'T',
        types: ['ui'],
        tags: ['a'],
        source: PackSource.itch,
        sourcePath: '/x',
        itchGameId: 12,
        itchUrl: 'https://a.itch.io/t',
        cover: '_itch/cover.png',
        notes: 'n',
        usedIn: ['G'],
        isContainer: true,
        animations: {
          'walk.png': {'fps': 8},
        },
        favorite: true,
        favoriteFiles: ['a/b.png', 'c.wav'],
        extra: {'k': 'v'},
      );
      sc.write(tmp.path);
      expect(PackSidecar.read(tmp.path)!.toJson(), sc.toJson());
    });

    test('favorites round-trip; unstarred leaves no keys', () {
      final json = const PackSidecar(
        favorite: true,
        favoriteFiles: ['x.png'],
      ).toJson();
      expect(json, {
        'favorite': true,
        'favorite_files': ['x.png'],
      });
      final back = PackSidecar.fromJson(json);
      expect(back.favorite, isTrue);
      expect(back.favoriteFiles, ['x.png']);
      expect(back.extra, isEmpty);
      expect(const PackSidecar(title: 't').copyWith(favorite: false).toJson(), {
        'title': 't',
      });
    });

    test('empty sidecar writes an empty object', () {
      expect(const PackSidecar().toJson(), isEmpty);
    });

    test('malformed or missing json reads as null', () {
      expect(PackSidecar.read(tmp.path), isNull);
      File('${tmp.path}/$packFileName').writeAsStringSync('{nope');
      expect(PackSidecar.read(tmp.path), isNull);
      File('${tmp.path}/$packFileName').writeAsStringSync('[1]');
      expect(PackSidecar.read(tmp.path), isNull);
    });
  });
}
