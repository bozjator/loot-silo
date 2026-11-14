// Read-only timing on the user's real `assets_library` (M73): how long a
// sort by a header value takes to read every track of the biggest audio
// pack. Skipped when the library isn't there.
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loot_silo/core/audio_formats.dart';
import 'package:loot_silo/ui/track_player.dart';
import 'package:path/path.dart' as p;

void main() {
  final lib = Directory('../assets_library');

  test('M73: headers of the biggest audio pack (real, read-only)', () async {
    // Packs are the folders holding asset_pack.json; their audio files
    // are those below them.
    final packs = <String, List<String>>{};
    for (final e in lib.listSync(recursive: true, followLinks: false)) {
      if (e is! File) continue;
      if (!audioFormatOrder.contains(formatOf(e.path))) continue;
      var dir = e.parent;
      while (dir.path != lib.path &&
          !File(p.join(dir.path, 'asset_pack.json')).existsSync()) {
        dir = dir.parent;
      }
      packs.putIfAbsent(dir.path, () => []).add(e.path);
    }
    final (pack, files) = packs.entries
        .map((e) => (e.key, e.value))
        .reduce((a, b) => a.$2.length >= b.$2.length ? a : b);
    final before = Directory(pack).statSync().modified;
    final tracks = groupAudioFormats([
      for (final f in files) p.relative(f, from: pack),
    ]);
    final shown = [for (final t in tracks) p.join(pack, t.pick('ogg'))];
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final read = container.read(audioInfoProvider);
    final watch = Stopwatch()..start();
    final infos = await Future.wait(shown.map(read));
    watch.stop();
    // ignore: avoid_print
    print(
      'M73: ${p.basename(pack)}: ${shown.length} tracks '
      '(${files.length} files) read in ${watch.elapsedMilliseconds} ms',
    );
    expect(infos.where((i) => i?.sampleRate != null), isNotEmpty);
    expect(Directory(pack).statSync().modified, before);
  }, skip: lib.existsSync() ? false : 'no ../assets_library');
}
