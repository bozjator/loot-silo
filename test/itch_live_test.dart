// Live itch.io smoke test; not part of the normal run. Needs ITCH_LIVE=1
// and a key via ITCH_API_KEY or ITCH_ENV_FILE. Only reads: the profile,
// the owned keys and one game's upload list. The key is never printed.
@Tags(['live'])
library;

import 'dart:io';

import 'package:loot_silo/itch/itch_api.dart';
import 'package:loot_silo/itch/itch_key.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final key = Platform.environment['ITCH_LIVE'] == '1'
      ? keyFromEnvironment()
      : null;
  test('owned keys and one upload list', () async {
    final api = ItchApi(key!);
    addTearDown(api.close);
    final me = await api.profile();
    expect(me.username, isNotEmpty);
    final keys = await api.ownedKeys();
    expect(keys, isNotEmpty);
    expect({for (final k in keys) k.id}.length, keys.length);
    final uploads = await api.uploads(keys.first);
    expect(uploads, isNotEmpty);
    // ignore: avoid_print
    print(
      '${me.username}: ${keys.length} owned keys; '
      '${keys.first.game.title} has ${uploads.length} uploads',
    );
  }, skip: key == null ? 'set ITCH_LIVE=1 and an itch key' : false);
}
