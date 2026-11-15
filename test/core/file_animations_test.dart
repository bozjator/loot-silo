import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:loot_silo/core/animation_detector.dart';
import 'package:loot_silo/core/library_index.dart';
import 'package:loot_silo/core/library_scanner.dart';
import 'package:loot_silo/core/sidecar.dart';
import 'package:loot_silo/state/anim_cache_fill.dart';
import 'package:loot_silo/state/dashboard.dart';
import 'package:path/path.dart' as p;

/// M97: which Files view hits are animations, read from the animation
/// cache only.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late Directory tmp;
  late String pack;
  late LibraryIndex index;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('file_anims');
    pack = p.join(tmp.path, 'Hero Maker', 'Knight Pack');
    index = LibraryIndex(NativeDatabase.memory());
  });
  tearDown(() async {
    await index.close();
    tmp.deleteSync(recursive: true);
  });

  void write(String rel, List<int> bytes) => File(p.join(pack, rel))
    ..parent.createSync(recursive: true)
    ..writeAsBytesSync(bytes);

  void writeSidecar(Map<String, Object?> json) =>
      File(p.join(pack, packFileName)).writeAsStringSync(jsonEncode(json));

  /// A strip, a GIF, a still and a hand-made ("Make animation") strip,
  /// all with "walk" in the name but the still.
  void writeFixture({Map<String, Object?> extra = const {}}) {
    write('License.txt', utf8.encode('CC0'));
    write(
      'hero_walk.png',
      File('test/fixtures/images/hero_walk.png').readAsBytesSync(),
    );
    final gif = img.Image(width: 8, height: 8, numChannels: 4)
      ..frameDuration = 100;
    gif.addFrame(img.Image(width: 8, height: 8, numChannels: 4));
    write('fx/walk_dust.gif', img.encodeGif(gif));
    write('tree.png', img.encodePng(img.Image(width: 16, height: 16)));
    write(
      'props/walk_barrel.png',
      img.encodePng(img.Image(width: 48, height: 16)),
    );
    writeSidecar({
      'animations': {
        'props/walk_barrel.png': {'manual': true},
        ...extra,
      },
    });
  }

  Future<List<PackRow>> scan() async {
    await index.replaceScan(scanLibrary(tmp.path));
    return index.allPacks();
  }

  /// What the Files view does for a search: hits → their animations.
  Future<Map<(String, String), SpriteAnim>> lookup(String text) async {
    final hits = (await index.searchFiles(text)).hits;
    final ids = {for (final h in hits) h.packId};
    final caches = await index.animCaches(ids);
    final files = await index.filesWithSizesOf(caches.keys);
    final packs = {for (final pk in await index.allPacks()) pk.id: pk.path};
    return hitAnimations([
      for (final id in caches.keys)
        (
          id: id,
          path: packs[id]!,
          files: files[id] ?? const [],
          cache: caches[id]!,
          rels: {
            for (final h in hits)
              if (h.packId == id) h.relPath,
          },
        ),
    ]);
  }

  test(
    'cached: walk hits map to their animations, tree stays a still',
    () async {
      writeFixture();
      final packs = await scan();
      await AnimCacheFiller(index, pause: Duration.zero).fill(packs);
      final id = packs.single.id;
      final m = await lookup('walk');
      expect(m.keys.map((k) => k.$2), {
        'hero_walk.png',
        'fx/walk_dust.gif',
        'props/walk_barrel.png',
      });
      expect(m.keys.every((k) => k.$1 == id), isTrue);
      expect(m[(id, 'fx/walk_dust.gif')]!.kind, AnimKind.gif);
      expect(m[(id, 'hero_walk.png')]!.kind, AnimKind.sheet);
      expect(await lookup('tree'), isEmpty);
    },
  );

  test('no cache entry: every hit is a still', () async {
    writeFixture();
    await scan();
    expect(await lookup('walk'), isEmpty);
  });

  test(
    'a stale entry (a file changed) gives stills, not old guesses',
    () async {
      writeFixture();
      final packs = await scan();
      await AnimCacheFiller(index, pause: Duration.zero).fill(packs);
      write('hero_walk.png', img.encodePng(img.Image(width: 64, height: 16)));
      await scan();
      expect(await lookup('walk'), isEmpty);
    },
  );

  test('overrides apply; "Not an animation" is a still again', () async {
    writeFixture(
      extra: {
        'hero_walk.png': {'fps': 4},
        'fx/walk_dust.gif': false,
      },
    );
    final packs = await scan();
    await AnimCacheFiller(index, pause: Duration.zero).fill(packs);
    final id = packs.single.id;
    final m = await lookup('walk');
    expect(m[(id, 'hero_walk.png')]!.fps, 4);
    expect(m.containsKey((id, 'fx/walk_dust.gif')), isFalse);
  });

  test('a cache write is announced', () async {
    final changes = index.animCacheChanges().first;
    await index.putAnimCache('x', 'sig', '[]');
    await changes.timeout(const Duration(seconds: 2));
  });
}
