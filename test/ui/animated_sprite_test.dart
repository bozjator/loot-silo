import 'dart:io';

import 'package:assets_explorer/core/animation_detector.dart';
import 'package:assets_explorer/ui/widgets/animated_sprite.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

void main() {
  late Directory tmp;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('sprite');
    // 4 cells of 8x8; the last one fully transparent.
    final image = img.Image(width: 32, height: 8, numChannels: 4);
    for (var c = 0; c < 3; c++) {
      img.fillRect(
        image,
        x1: c * 8 + 1,
        y1: 1,
        x2: c * 8 + 6,
        y2: 6,
        color: img.ColorRgba8(255, 0, 0, 255),
      );
    }
    File(p.join(tmp.path, 'run.png')).writeAsBytesSync(img.encodePng(image));
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  const anim = SpriteAnim(
    path: 'run.png',
    kind: AnimKind.sheet,
    frameW: 8,
    frameH: 8,
    cols: 4,
  );

  Future<void> pumpSprite(
    WidgetTester tester, {
    required bool playing,
    SpriteAnim anim = anim,
  }) async {
    final provider = FileImage(File(p.join(tmp.path, 'run.png')));
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(
      () => precacheImage(provider, tester.element(find.byType(SizedBox))),
    );
    await tester.pumpWidget(
      Center(
        child: SizedBox(
          width: 64,
          height: 64,
          child: AnimatedSprite(
            packPath: tmp.path,
            anim: anim,
            playing: playing,
            fps: 10,
          ),
        ),
      ),
    );
    // Let image delivery and the empty-cell check finish for real.
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
  }

  Rect src(WidgetTester tester) =>
      (tester
                  .widget<CustomPaint>(
                    find.descendant(
                      of: find.byType(AnimatedSprite),
                      matching: find.byType(CustomPaint),
                    ),
                  )
                  .painter!
              as SpriteFramePainter)
          .src;

  testWidgets('shows frame 0 when not playing', (tester) async {
    await pumpSprite(tester, playing: false);
    // Cropped to the shared opaque bounds (1..7 in each cell).
    expect(src(tester), const Rect.fromLTRB(1, 1, 7, 7));
    await tester.pump(const Duration(milliseconds: 500));
    expect(src(tester).left, 1);
  });

  testWidgets('advances at fps, skips the empty cell, crops padding', (
    tester,
  ) async {
    await pumpSprite(tester, playing: true);
    final seen = <double>{};
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      seen.add(src(tester).left);
    }
    expect(seen, {1, 9, 17});
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('frames larger than the sheet do not read past the image', (
    tester,
  ) async {
    // 8x16 cells on a 32x8 sheet: every cell reaches below the image.
    await pumpSprite(
      tester,
      playing: false,
      anim: const SpriteAnim(
        path: 'run.png',
        kind: AnimKind.sheet,
        frameW: 8,
        frameH: 16,
        cols: 4,
      ),
    );
    expect(tester.takeException(), isNull);
    expect(src(tester), const Rect.fromLTRB(1, 1, 7, 7));
  });
}
