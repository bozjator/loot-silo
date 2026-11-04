import 'dart:io';

import 'package:drift_flutter/drift_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'core/library_index.dart';
import 'state/providers.dart';
import 'state/settings.dart';
import 'ui/app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final support = await getApplicationSupportDirectory();
  final cache = await getApplicationCacheDirectory();
  final index = LibraryIndex(
    driftDatabase(
      name: 'library_index',
      native: DriftNativeOptions(databaseDirectory: () async => support),
    ),
  );
  runApp(
    ProviderScope(
      overrides: [
        settingsStoreProvider.overrideWithValue(
          SettingsStore(File(p.join(support.path, 'settings.json'))),
        ),
        libraryIndexProvider.overrideWithValue(index),
        extractRootProvider.overrideWithValue(p.join(cache.path, 'extract')),
      ],
      child: const AssetsExplorerApp(),
    ),
  );
}
