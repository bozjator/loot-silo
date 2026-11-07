import 'dart:io';

import 'package:loot_silo/ui/widgets/pixel_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

final hero = File('test/fixtures/images/hero.png').absolute;
final walk = File('test/fixtures/images/hero_walk.png').absolute;

Widget at(File file) => MaterialApp(
  home: Center(child: SizedBox(width: 64, height: 64, child: PixelImage(file))),
);

void main() {
  testWidgets('a paused image whose stream was disposed rebuilds cleanly', (
    tester,
  ) async {
    // Loaded with real timers so no precache listener lingers: the widget
    // is the stream's only listener, as in the app.
    Future<void> show(File file) async {
      await tester.runAsync(() async {
        await tester.pumpWidget(at(file));
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await tester.pump();
    }

    // A full cache (big grids) keeps nothing: when the paused widget drops
    // its last listener after the first frame, the stream is disposed.
    final size = imageCache.maximumSize;
    imageCache.maximumSize = 0;
    addTearDown(() => imageCache.maximumSize = size);

    await show(hero);
    expect(find.byType(RawImage), findsOneWidget);

    // Switching the file (and disposing the widget) must not touch the
    // dead stream.
    await show(walk);
    expect(tester.takeException(), isNull);
    expect(find.byType(RawImage), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });
}
