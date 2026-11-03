import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

/// Loads Roboto and Material Icons from the Flutter SDK so goldens show
/// real text and icons instead of the test font's boxes.
Future<void> loadAppFonts() async {
  final root = Platform.environment['FLUTTER_ROOT'];
  if (root == null) return;
  final dir = p.join(root, 'bin', 'cache', 'artifacts', 'material_fonts');
  Future<void> load(String family, List<String> files) async {
    final loader = FontLoader(family);
    for (final f in files) {
      final file = File(p.join(dir, f));
      if (!file.existsSync()) return;
      loader.addFont(
        Future.value(ByteData.sublistView(file.readAsBytesSync())),
      );
    }
    await loader.load();
  }

  await load('Roboto', [
    'Roboto-Regular.ttf',
    'Roboto-Medium.ttf',
    'Roboto-Bold.ttf',
  ]);
  await load('MaterialIcons', ['MaterialIcons-Regular.otf']);
}
