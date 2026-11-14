// Read-only: lists owned itch.io keys and how they match a library.
// The key comes from ITCH_API_KEY, ./.env or ITCH_ENV_FILE and is never
// printed.
//
//   ITCH_ENV_FILE=~/.config/…/app.env dart run tool/itch_report.dart <library>
import 'dart:io';

import 'package:loot_silo/core/library_index.dart';
import 'package:loot_silo/core/library_scanner.dart';
import 'package:loot_silo/itch/itch_api.dart';
import 'package:loot_silo/itch/itch_key.dart';
import 'package:loot_silo/itch/itch_matcher.dart';

Future<void> main(List<String> args) async {
  final key = keyFromEnvironment();
  if (key == null || args.isEmpty) {
    stderr.writeln('usage: itch_report <library>  (needs an itch API key)');
    exit(64);
  }
  final api = ItchApi(key);
  try {
    final me = await api.profile();
    final keys = await api.ownedKeys();
    stdout.writeln('${me.username}: ${keys.length} owned keys');
    final scan = scanLibrary(args.first);
    final packs = [
      for (final pk in scan.packs)
        PackRow(
          id: pk.id,
          path: pk.path,
          title: pk.title,
          author: pk.author?.user,
          authorUrl: pk.author?.url,
          types: pk.types,
          tags: pk.tags,
          usedIn: const [],
          favorite: pk.sidecar?.favorite ?? false,
          favoriteFiles: pk.sidecar?.favoriteFiles ?? const [],
          itchGameId: pk.sidecar?.itchGameId,
          fileCount: pk.files.length,
          totalBytes: pk.totalBytes,
        ),
    ];
    final matches = matchOwnedKeys(
      keys,
      packs,
      folders: {for (final pk in scan.packs) pk.id: folderNamesOf(pk.files)},
    );
    for (final kind in MatchKind.values) {
      final group = matches.where((m) => m.kind == kind).toList();
      stdout.writeln('\n${kind.name} (${group.length})');
      for (final m in group) {
        final g = m.key.game;
        stdout.writeln(
          '  ${g.title} — ${g.user.username} [${g.classification}]'
          '${m.pack == null ? '' : '  →  ${m.pack!.id} '
                    '(${m.score.toStringAsFixed(2)})'}',
        );
      }
    }
    if (args.contains('--uploads') && keys.isNotEmpty) {
      final ups = await api.uploads(keys.first);
      stdout.writeln('\nuploads of ${keys.first.game.title}:');
      for (final u in ups) {
        stdout.writeln('  ${u.filename} ${u.size} B ${u.type} ${u.traits}');
      }
    }
  } on ItchApiException catch (e) {
    stderr.writeln('itch: $e');
    exitCode = 1;
  } finally {
    api.close();
  }
}
