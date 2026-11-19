import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:loot_silo/state/settings.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('settings_format'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('settings without a version load and are written as version 1', () {
    final file = File('${tmp.path}/settings.json')
      ..writeAsStringSync(
        jsonEncode({
          'library_path': '/lib',
          'theme': 'dark',
          'from_newer_app': [1, 2],
        }),
      );
    final store = SettingsStore(file);
    final s = store.load();
    expect(s.libraryPath, '/lib');
    expect(s.theme, ThemeChoice.dark);

    store.save(s.copyWith(theme: ThemeChoice.light));
    final json = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
    expect(json['format_version'], 1);
    expect(json['theme'], 'light');
    expect(json['from_newer_app'], [1, 2]);
    expect(store.load().extra, {
      'from_newer_app': [1, 2],
    });
  });
}
