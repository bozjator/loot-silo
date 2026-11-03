import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

/// Key for the [RepaintBoundary] that wraps the app under test.
final screenshotKey = GlobalKey();

/// Wraps [app] so [captureScreenshot] can grab it.
Widget screenshotable(Widget app) =>
    RepaintBoundary(key: screenshotKey, child: app);

/// Writes a PNG of the app to `screenshots/<name>.png`.
///
/// Desktop integration tests can't use `binding.takeScreenshot`, so we
/// render the root boundary to an image instead.
Future<File> captureScreenshot(WidgetTester tester, String name) async {
  await tester.pumpAndSettle();
  late File file;
  await tester.runAsync(() async {
    final boundary =
        screenshotKey.currentContext!.findRenderObject()
            as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 1);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    file = File('screenshots/$name.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes!.buffer.asUint8List());
  });
  return file;
}
