import 'dart:io';

import 'package:loot_silo/core/animation_detector.dart';
import 'package:loot_silo/ui/widgets/animated_sprite.dart';
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
    // The whole cell, padding included.
    expect(src(tester), const Rect.fromLTWH(0, 0, 8, 8));
    await tester.pump(const Duration(milliseconds: 500));
    expect(src(tester).left, 0);
  });

  testWidgets('advances at fps, skips the empty cell, keeps padding', (
    tester,
  ) async {
    await pumpSprite(tester, playing: true);
    final seen = <double>{};
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      seen.add(src(tester).left);
    }
    expect(seen, {0, 8, 16});
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a total-frames override stops before the remaining cells', (
    tester,
  ) async {
    await pumpSprite(tester, playing: true, anim: anim.withFrameCount(2)!);
    final seen = <double>{};
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      seen.add(src(tester).left);
    }
    // 2 frames of 16 px, each holding two of the 8 px blobs.
    expect(seen, hasLength(2));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('cells past the frame total are never shown', (tester) async {
    // Four 8 px cells capped at 2 frames: cells 3 and 4 are skipped.
    await pumpSprite(
      tester,
      playing: true,
      anim: const SpriteAnim(
        path: 'run.png',
        kind: AnimKind.sheet,
        frameW: 8,
        frameH: 8,
        cols: 4,
        frameTotal: 2,
      ),
    );
    final seen = <double>{};
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      seen.add(src(tester).left);
    }
    expect(seen, {0, 8});
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
    expect(src(tester), const Rect.fromLTWH(0, 0, 8, 16));
  });

  testWidgets('unmounting after the image cache dropped the sheet is safe', (
    tester,
  ) async {
    await pumpSprite(tester, playing: true);
    expect(find.byType(CustomPaint), findsWidgets);
    // The cache letting go disposes the stream the sprite loaded from (the
    // dashboard does this when many previews pass through the cache).
    imageCache.clear();
    imageCache.clearLiveImages();
    // The cache lets go of its handle at the end of the frame.
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });

  testWidgets('unmounting while the empty-frame check reads pixels is safe', (
    tester,
  ) async {
    // A three-frame strip: the sprite can go (scrolled away) while the
    // empty-frame check reads its pixels.
    final names = ['walk.png'];
    final image = img.Image(width: 48, height: 16, numChannels: 4);
    for (var i = 0; i < 3; i++) {
      img.fillRect(
        image,
        x1: 4 + i * 16,
        y1: 4,
        x2: 11 + i * 16,
        y2: 11,
        color: img.ColorRgba8(0, 0, 255, 255),
      );
    }
    File(p.join(tmp.path, names.single)).writeAsBytesSync(img.encodePng(image));
    await tester.pumpWidget(const SizedBox());
    for (final n in names) {
      await tester.runAsync(
        () => precacheImage(
          FileImage(File(p.join(tmp.path, n))),
          tester.element(find.byType(SizedBox)),
        ),
      );
    }
    // Cached: the frames arrive at once and the check starts reading.
    await tester.pumpWidget(
      AnimatedSprite(
        packPath: tmp.path,
        anim: SpriteAnim(
          path: names.single,
          kind: AnimKind.sheet,
          frameW: 16,
          frameH: 16,
          cols: 3,
        ),
        playing: true,
      ),
    );
    // Gone before the first read finishes; its images are disposed.
    await tester.pumpWidget(const SizedBox());
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    expect(tester.takeException(), isNull);
  });

  group('whole frames and zoom (M35)', () {
    /// Two 64 px frames with a small blob each, at different places: the
    /// union of their opaque bounds is the shared crop.
    void paddedSheet(String name) {
      final image = img.Image(width: 128, height: 64, numChannels: 4);
      img.fillRect(
        image,
        x1: 20,
        y1: 24,
        x2: 27,
        y2: 31,
        color: img.ColorRgba8(0, 200, 0, 255),
      );
      img.fillRect(
        image,
        x1: 64 + 24,
        y1: 28,
        x2: 64 + 31,
        y2: 39,
        color: img.ColorRgba8(0, 0, 200, 255),
      );
      File(p.join(tmp.path, name)).writeAsBytesSync(img.encodePng(image));
    }

    const padded = SpriteAnim(
      path: 'padded.png',
      kind: AnimKind.sheet,
      frameW: 64,
      frameH: 64,
      cols: 2,
    );

    Future<void> pumpAt(
      WidgetTester tester,
      SpriteAnim a, {
      double box = 64,
      bool settle = true,
    }) async {
      final provider = FileImage(File(p.join(tmp.path, a.path)));
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(
        () => precacheImage(provider, tester.element(find.byType(SizedBox))),
      );
      await tester.pumpWidget(
        Center(
          child: SizedBox(
            width: box,
            height: box,
            child: AnimatedSprite(packPath: tmp.path, anim: a, playing: false),
          ),
        ),
      );
      if (!settle) return;
      final drawn = find.descendant(
        of: find.byType(AnimatedSprite),
        matching: find.byType(CustomPaint),
      );
      for (var i = 0; i < 50 && drawn.evaluate().isEmpty; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
    }

    SpriteFramePainter painter(WidgetTester tester) =>
        tester
                .widget<CustomPaint>(
                  find.descendant(
                    of: find.byType(AnimatedSprite),
                    matching: find.byType(CustomPaint),
                  ),
                )
                .painter!
            as SpriteFramePainter;

    testWidgets('a padded sheet is drawn whole, padding kept', (tester) async {
      paddedSheet('padded.png');
      await pumpAt(tester, padded, box: 200);
      final pt = painter(tester);
      // The whole 64 px cell, not the opaque bounds.
      expect(pt.src, const Rect.fromLTWH(0, 0, 64, 64));
      // 64 px in 200 px: 3× in whole steps.
      expect(pt.scaleFor(const Size(200, 200)), 3);
    });

    testWidgets('drawn on the first frame, no wait for a pixel read', (
      tester,
    ) async {
      paddedSheet('padded.png');
      await pumpAt(tester, padded, settle: false);
      await tester.pump();
      expect(painter(tester).src, const Rect.fromLTWH(0, 0, 64, 64));
    });

    testWidgets('plays an in-memory image (bytes) without a file', (
      tester,
    ) async {
      final image = img.Image(width: 32, height: 16, numChannels: 4);
      img.fill(image, color: img.ColorRgba8(9, 9, 9, 255));
      final bytes = img.encodePng(image);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(
        Center(
          child: SizedBox(
            width: 64,
            height: 64,
            child: AnimatedSprite(
              packPath: tmp.path,
              anim: const SpriteAnim(
                path: 'not_written.png',
                kind: AnimKind.sheet,
                frameW: 16,
                frameH: 16,
                cols: 2,
              ),
              bytes: bytes,
              playing: false,
            ),
          ),
        ),
      );
      final drawn = find.descendant(
        of: find.byType(AnimatedSprite),
        matching: find.byType(CustomPaint),
      );
      for (var i = 0; i < 50 && drawn.evaluate().isEmpty; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      expect(painter(tester).src, const Rect.fromLTWH(0, 0, 16, 16));
      expect(File(p.join(tmp.path, 'not_written.png')).existsSync(), isFalse);
    });

    testWidgets('a zoom is a fixed scale, centred and clipped', (tester) async {
      paddedSheet('padded.png');
      await pumpAt(tester, padded.copyWith(zoom: 2), box: 200);
      final pt = painter(tester);
      expect(pt.zoom, 2);
      expect(pt.scaleFor(const Size(200, 200)), 2);
      // Larger than the box still draws (clipped), it doesn't shrink.
      await pumpAt(tester, padded.copyWith(zoom: 8), box: 64);
      expect(painter(tester).scaleFor(const Size(64, 64)), 8);
    });
  });
}
