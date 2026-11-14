import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:loot_silo/core/animation_detector.dart';
import 'package:loot_silo/core/library_index.dart';
import 'package:loot_silo/core/library_scanner.dart';
import 'package:loot_silo/core/pack_editor.dart';
import 'package:loot_silo/core/sidecar.dart';
import 'package:loot_silo/state/anim_cache_fill.dart';
import 'package:path/path.dart' as p;

/// M94: detected animations are cached in the index.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late Directory tmp;
  late String pack;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('anim_cache');
    pack = p.join(tmp.path, 'Hero Maker', 'Knight Pack');
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  void write(String rel, List<int> bytes) => File(p.join(pack, rel))
    ..parent.createSync(recursive: true)
    ..writeAsBytesSync(bytes);

  List<int> png(int w, int h) => img.encodePng(img.Image(width: w, height: h));

  void writeSidecar(Map<String, Object?> json) =>
      File(p.join(pack, packFileName)).writeAsStringSync(jsonEncode(json));

  /// A strip, a GIF, a plain image, a hand-made animation and an atlas.
  void writeFixture() {
    write('License.txt', utf8.encode('CC0'));
    write(
      'hero_walk.png',
      File('test/fixtures/images/hero_walk.png').readAsBytesSync(),
    );
    write('hero.png', File('test/fixtures/images/hero.png').readAsBytesSync());
    final gif = img.Image(width: 8, height: 8, numChannels: 4)
      ..frameDuration = 100;
    gif.addFrame(img.Image(width: 8, height: 8, numChannels: 4));
    write('fx/spark.gif', img.encodeGif(gif));
    write('props/barrel.png', png(48, 16));
    write('atlas/sheet.png', png(64, 64));
    write('atlas/sheet.xml', utf8.encode('<TextureAtlas/>'));
    writeSidecar({
      'animations': {
        'props/barrel.png': {'manual': true},
      },
    });
  }

  List<(String, int)> filesOf() {
    final all =
        Directory(pack).listSync(recursive: true).whereType<File>().toList()
          ..sort((a, b) => a.path.compareTo(b.path));
    return [
      for (final f in all)
        if (p.basename(f.path) != packFileName)
          (p.relative(f.path, from: pack), f.lengthSync()),
    ];
  }

  test('same files and sidecar: a hit, with the same contents', () {
    writeFixture();
    final first = loadPackContentsCached(pack, filesOf());
    expect(first.fresh, isNotNull);
    final paths = {for (final a in first.contents.detected) a.path};
    expect(
      paths,
      containsAll(['hero_walk.png', 'fx/spark.gif', 'props/barrel.png']),
    );

    final again = loadPackContentsCached(pack, filesOf(), cached: first.fresh);
    expect(again.fresh, isNull, reason: 'detection skipped');
    final a = again.contents, b = first.contents;
    expect(a.detected, b.detected);
    expect(a.images, b.images);
    expect(a.animations, b.animations);
    expect(a.other, b.other);
    // And the same as without any cache.
    expect(loadPackContents(pack, filesOf()).detected, a.detected);
  });

  group('a miss when what detection reads changes', () {
    late AnimCache cache;
    setUp(() {
      writeFixture();
      cache = loadPackContentsCached(pack, filesOf()).fresh!;
    });

    AnimCache? freshNow() =>
        loadPackContentsCached(pack, filesOf(), cached: cache).fresh;

    test('a file size', () {
      write('hero.png', png(40, 40));
      expect(freshNow(), isNotNull);
      expect(freshNow()!.signature, isNot(cache.signature));
    });

    test('an added image', () {
      write('fx/new_explosion.png', png(64, 16));
      expect(freshNow(), isNotNull);
    });

    test('a removed image', () {
      File(p.join(pack, 'hero.png')).deleteSync();
      expect(freshNow(), isNotNull);
    });

    test('a file made an animation by hand ("Make animation…")', () {
      writeSidecar({
        'animations': {
          'props/barrel.png': {'manual': true},
          'hero.png': {'manual': true},
        },
      });
      final c = loadPackContentsCached(pack, filesOf(), cached: cache);
      expect(c.fresh, isNotNull);
      expect(c.contents.detected.map((a) => a.path), contains('hero.png'));
    });

    test('the detector version is part of the signature', () {
      final sig = animationSignature(
        packPath: pack,
        images: const ['a.png'],
        sizes: const {'a.png': 1},
        atlases: const {},
        manual: const {},
      );
      expect(sig, hasLength(40));
      expect(
        animationSignature(
          packPath: pack,
          images: const ['a.png'],
          sizes: const {'a.png': 2},
          atlases: const {},
          manual: const {},
        ),
        isNot(sig),
      );
    });
  });

  test('fps, frame size and "Not an animation" edits keep the cache', () {
    writeFixture();
    final cache = loadPackContentsCached(pack, filesOf()).fresh!;
    writeSidecar({
      'animations': {
        'props/barrel.png': {'manual': true},
        'hero_walk.png': {'fps': 4},
        'fx/spark.gif': false,
      },
    });
    final c = loadPackContentsCached(pack, filesOf(), cached: cache);
    expect(c.fresh, isNull);
    // Applied on top of the cached detection right away.
    final walk = c.contents.animations.firstWhere(
      (a) => a.path == 'hero_walk.png',
    );
    expect(walk.fps, 4);
    expect(
      c.contents.animations.map((a) => a.path),
      isNot(contains('fx/spark.gif')),
    );
    expect(c.contents.images, contains('fx/spark.gif'));
  });

  group('index', () {
    late LibraryIndex index;
    setUp(() => index = LibraryIndex(NativeDatabase.memory()));
    tearDown(() => index.close());

    test('stores and replaces an entry per pack', () async {
      expect(await index.animCache('a'), isNull);
      await index.putAnimCache('a', 's1', '[]');
      await index.putAnimCache('a', 's2', '[{"x":1}]');
      final got = await index.animCache('a');
      expect(got?.signature, 's2');
      expect(got?.json, '[{"x":1}]');
    });

    test('a rescan keeps the entries of packs still there', () async {
      writeFixture();
      AuthorInfo(user: 'Hero Maker').write(p.dirname(pack));
      final other = p.join(tmp.path, 'Hero Maker', 'Slimes');
      File(p.join(other, 'slime.png'))
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(png(8, 8));
      File(p.join(other, 'License.txt')).writeAsStringSync('CC0');
      await index.replaceScan(scanLibrary(tmp.path));
      final ids = [for (final r in await index.allPacks()) r.id];
      expect(ids, hasLength(2));
      for (final id in ids) {
        await index.putAnimCache(id, 'sig', '[]');
      }
      Directory(other).deleteSync(recursive: true);
      await index.replaceScan(scanLibrary(tmp.path));
      final kept = [for (final r in await index.allPacks()) r.id].single;
      expect(await index.animCache(kept), isNotNull);
      for (final id in ids.where((i) => i != kept)) {
        expect(await index.animCache(id), isNull);
      }
    });
  });

  group('background fill', () {
    late LibraryIndex index;
    setUp(() => index = LibraryIndex(NativeDatabase.memory()));
    tearDown(() => index.close());

    Future<List<PackRow>> scanTwoPacks() async {
      writeFixture();
      AuthorInfo(user: 'Hero Maker').write(p.dirname(pack));
      final small = p.join(tmp.path, 'Hero Maker', 'Slimes');
      File(p.join(small, 'slime_idle.png'))
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(png(32, 8));
      File(p.join(small, 'License.txt')).writeAsStringSync('CC0');
      await index.replaceScan(scanLibrary(tmp.path));
      return index.allPacks();
    }

    test('fills stale packs largest first, then nothing', () async {
      final packs = await scanTwoPacks();
      final filler = AnimCacheFiller(index, pause: Duration.zero);
      final done = await filler.fill(packs);
      final bySize = [...packs]
        ..sort((a, b) => b.fileCount.compareTo(a.fileCount));
      expect(done, [for (final pk in bySize) pk.id]);
      // The page now opens from the cache.
      final knight = packs.firstWhere((pk) => pk.path == pack);
      final cached = await index.animCache(knight.id);
      final files = await index.filesWithSizes(knight.id);
      expect(loadPackContentsCached(pack, files, cached: cached).fresh, isNull);
      expect(
        await AnimCacheFiller(index, pause: Duration.zero).fill(packs),
        isEmpty,
      );
    });

    test('a cancelled fill stops before the next pack', () async {
      final packs = await scanTwoPacks();
      final filler = AnimCacheFiller(index, pause: Duration.zero)..cancel();
      expect(await filler.fill(packs), isEmpty);
      for (final pk in packs) {
        expect(await index.animCache(pk.id), isNull);
      }
    });
  });

  test('cached animations keep every SpriteAnim field', () {
    const a = SpriteAnim(
      path: 'a.png',
      kind: AnimKind.sheet,
      frameW: 16,
      frameH: 8,
      cols: 4,
      rows: 2,
      fps: 12,
      frameTotal: 7,
      playRow: 1,
      zoom: 2,
    );
    expect(
      SpriteAnim.fromJson(
        jsonDecode(jsonEncode(a.toJson())) as Map<String, Object?>,
      ),
      a,
    );
  });
}
