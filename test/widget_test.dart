import 'dart:io';

import 'package:assets_explorer/core/library_index.dart';
import 'package:assets_explorer/state/providers.dart';
import 'package:assets_explorer/state/settings.dart';
import 'package:assets_explorer/ui/app.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('app'));
  tearDown(() => tmp.deleteSync(recursive: true));

  testWidgets('first run asks for a library folder and saves it', (
    tester,
  ) async {
    final store = SettingsStore(File(p.join(tmp.path, 'settings.json')));
    final index = LibraryIndex(NativeDatabase.memory());
    addTearDown(index.close);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsStoreProvider.overrideWithValue(store),
          libraryIndexProvider.overrideWithValue(index),
          directoryPickerProvider.overrideWithValue((_) async => tmp.path),
        ],
        child: const AssetsExplorerApp(),
      ),
    );
    expect(find.text('Choose a library folder'), findsOneWidget);
    await tester.tap(find.text('Choose folder'));
    await tester.pump();
    expect(store.load().libraryPath, tmp.path);
  });

  test('settings survive a corrupt file', () {
    final f = File(p.join(tmp.path, 'settings.json'))..writeAsStringSync('{');
    expect(SettingsStore(f).load().libraryPath, isNull);
  });
}
