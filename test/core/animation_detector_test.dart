import 'dart:io';
import 'dart:typed_data';

import 'package:loot_silo/core/animation_detector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

late Directory tmp;

/// Writes an opaque [w]×[h] PNG (or one with only [blobs] opaque).
void png(String rel, int w, int h, {List<(int, int, int, int)>? blobs}) {
  final image = img.Image(width: w, height: h, numChannels: 4);
  if (blobs == null) {
    img.fill(image, color: img.ColorRgba8(200, 50, 50, 255));
  } else {
    for (final (x, y, bw, bh) in blobs) {
      img.fillRect(
        image,
        x1: x,
        y1: y,
        x2: x + bw - 1,
        y2: y + bh - 1,
        color: img.ColorRgba8(0, 0, 255, 255),
      );
    }
  }
  final f = File(p.join(tmp.path, rel))..parent.createSync(recursive: true);
  f.writeAsBytesSync(img.encodePng(image));
}

void main() {
  setUp(() => tmp = Directory.systemTemp.createTempSync('anim'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('readImageSize reads PNG and GIF headers only', () {
    png('a.png', 37, 11);
    final gif = File(p.join(tmp.path, 'b.gif'))
      ..writeAsBytesSync([
        ...'GIF89a'.codeUnits,
        40,
        1,
        30,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
      ]);
    File(p.join(tmp.path, 'c.png'))
        .writeAsStringSync('nope, not a png at all......');
    expect(readImageSize(p.join(tmp.path, 'a.png')), (37, 11));
    expect(readImageSize(gif.path), (296, 30));
    expect(readImageSize(p.join(tmp.path, 'c.png')), isNull);
    expect(readImageSize(p.join(tmp.path, 'missing.png')), isNull);
  });

  group('detectSheet', () {
    test('size hint in a folder name, grid', () {
      final s = detectSheet('SpriteSheets(96x96)/Orc/Orc-Sheet.png', 960, 768)!;
      expect((s.frameW, s.frameH, s.cols, s.rows), (96, 96, 10, 8));
    });

    test('frame count hint', () {
      final s = detectSheet('fire_6f.png', 120, 30)!;
      expect((s.frameW, s.cols), (20, 6));
    });

    test('square-frame strip', () {
      final s = detectSheet('Wolf/Idle/Idle.png', 384, 96)!;
      expect((s.frameW, s.cols, s.rows), (96, 4, 1));
      expect(
        detectSheet('two.png', 64, 32),
        isNull,
        reason: '2 frames need a sheet word',
      );
      expect(detectSheet('two-sheet.png', 64, 32)!.cols, 2);
    });

    test('tilesets, backgrounds and UI are not animations', () {
      expect(detectSheet('Tiles/forest_tiles.png', 160, 32), isNull);
      expect(detectSheet('background_far.png', 512, 128), isNull);
      expect(detectSheet('ui/buttons.png', 300, 50), isNull);
      expect(detectSheet('Tiles/water-sheet.png', 128, 32)!.cols, 4);
    });

    test('no consensus grid: big images next to strips stay images', () {
      expect(detectSheet('All-Spritesheet.png', 864, 672), isNull);
      // Generic Items: a 52×13 strip of 4 frames next to 130×130 items.
      png('PNG/White/genericItem_white_061.png', 52, 13);
      png('PNG/White/genericItem_white_147.png', 130, 130);
      // Sea Adventures: 128 px banner strips next to a 896×640 shadow.
      png('props/animated/banner-flag.png', 512, 128);
      png('props/islands-update/islands-grass-shadow.png', 896, 640);
      final anims = detectAnimations(tmp.path, [
        'PNG/White/genericItem_white_061.png',
        'PNG/White/genericItem_white_147.png',
        'props/animated/banner-flag.png',
        'props/islands-update/islands-grass-shadow.png',
      ]);
      expect(anims.map((a) => a.path), [
        'PNG/White/genericItem_white_061.png',
        'props/animated/banner-flag.png',
      ]);
    });

    test('several rows play all rows by default', () {
      final g = detectSheet('hero(32x32).png', 128, 64)!;
      expect((g.cols, g.rows), (4, 2));
      expect(g.playRow, SpriteAnim.allRows);
      expect(g.rowToPlay, isNull);
      // A saved row wins.
      expect(applyOverride(g, {'rows': 2}).rowToPlay, 1);
    });

    test('non-dividing hints and plain images are rejected', () {
      expect(detectSheet('(32x32)/odd.png', 100, 70), isNull);
      expect(detectSheet('photo.png', 800, 600), isNull);
    });
  });

  group('one file, one animation', () {
    List<String> listed() => [
      for (final f in tmp.listSync(recursive: true).whereType<File>())
        p.relative(f.path, from: tmp.path),
    ]..sort();

    test('numbered files are never a sequence; each is judged alone', () {
      for (var i = 0; i < 4; i++) {
        png('walk/walk_$i.png', 16, 16);
      }
      // Sea Adventures' gems: gems-1.png is really an 8-frame strip.
      for (var i = 1; i <= 4; i++) {
        png('props/animated/gems-$i.png', 256, 32);
      }
      // Kenney explosions: frames trimmed to their content.
      png('Ground explosion/groundExplosion00.png', 192, 192);
      png('Ground explosion/groundExplosion01.png', 149, 151);
      png('Ground explosion/groundExplosion02.png', 160, 170);
      final anims = detectAnimations(tmp.path, listed());
      expect(anims.map((a) => a.path), [
        for (var i = 1; i <= 4; i++) 'props/animated/gems-$i.png',
      ]);
      final gems = anims.first;
      expect(
        (gems.kind, gems.frameW, gems.cols, gems.rows),
        (AnimKind.sheet, 32, 8, 1),
      );
      expect(gems.label, 'gems-1');
    });

    test('animation words mark files and folders, plurals too', () {
      expect(hasAnimationWord('fx/explosions/boom.png'), isTrue);
      expect(hasAnimationWord('walk_0.png'), isTrue);
      expect(hasAnimationWord('props/animated/banner-only.png'), isTrue);
      expect(hasAnimationWord('barrels_0.png'), isFalse);
      expect(hasAnimationWord('furniture/decor_animals_0.png'), isFalse);
    });

    test('numbered props without an animation word are no candidates', () {
      for (var i = 0; i < 6; i++) {
        png('props-sprites/barrels_$i.png', 16, 16);
      }
      png('Effects/Hit/1.png', 16, 16);
      expect(animationCandidates(listed()), ['Effects/Hit/1.png']);
    });
  });

  test('only a manual mark makes an undetected image an animation', () {
    png('props/islands-update/islands-grass-tower-vfx.png', 640, 800);
    const rel = 'props/islands-update/islands-grass-tower-vfx.png';
    expect(detectAnimations(tmp.path, [rel]), isEmpty);
    // Edits alone don't make it one.
    expect(
      detectAnimations(
        tmp.path,
        [rel],
        overrides: {
          rel: {'frame_h': 160, 'frames': 16},
        },
      ),
      isEmpty,
    );
    final a = detectAnimations(
      tmp.path,
      [rel],
      overrides: {
        rel: {'manual': true, 'frame_h': 160, 'frames': 16},
      },
    ).single;
    expect((a.frameCount, a.rowToPlay), (16, null));
    expect(a.frameH * a.rows, 800);
    expect(
      manualAnimations({
        rel: {'manual': true},
        'y.png': {'fps': 4},
        'x.png': false,
      }),
      {rel},
    );
  });

  test('atlas images (with an .xml) skip the pixel checks', () {
    expect(
      atlasImages([
        'Spritesheet/sheet_tanks.png',
        'Spritesheet/sheet_tanks.xml',
        'Spritesheet/other.png',
      ]),
      {'Spritesheet/sheet_tanks.png'},
    );
  });

  group('non-square strips from column gaps', () {
    /// 1152×128 with 12 frames of 96×128, a transparent gap in each.
    void banner(String rel, {bool gaps = true}) => png(
      rel,
      1152,
      128,
      blobs: [
        if (gaps)
          for (var i = 0; i < 12; i++) (i * 96 + 6, 4, 84, 120)
        else
          (0, 4, 1152, 120),
      ],
    );

    test('banner-only.png is 12 frames of 96×128', () {
      banner('props/animated/banner-only.png');
      // The square guess alone: 9 frames of 128.
      final guess = detectSheet('props/animated/banner-only.png', 1152, 128)!;
      expect((guess.frameW, guess.cols), (128, 9));
      final a = detectAnimations(tmp.path, [
        'props/animated/banner-only.png',
      ], maxWordScans: 4).single;
      expect((a.frameW, a.frameH, a.cols, a.rows), (96, 128, 12, 1));
      expect(a.frameCount, 12);
      // Frame counts step from there as usual.
      expect(a.withFrameCount(12), isNotNull);
      expect(a.withFrameCount(12)!.cols, 12);
    });

    test('no check without budget, animation word or gaps', () {
      banner('props/animated/banner-only.png');
      banner('props/banner-plain.png');
      banner('props/animated/banner-solid.png', gaps: false);
      final anims = {
        for (final a in detectAnimations(tmp.path, [
          'props/animated/banner-only.png',
          'props/animated/banner-solid.png',
          'props/banner-plain.png',
        ], maxWordScans: 8))
          a.path: a,
      };
      expect(anims['props/animated/banner-only.png']!.frameW, 96);
      expect(anims['props/animated/banner-solid.png']!.frameW, 128);
      // No animation word: the 128 px cuts run through its frames, so it
      // is one picture (M43).
      expect(anims['props/banner-plain.png'], isNull);
      final unchecked = detectAnimations(tmp.path, [
        'props/animated/banner-only.png',
      ]).single;
      expect(unchecked.frameW, 128);
    });

    test('a size hint is never re-cut', () {
      banner('anim/banner(128x128).png');
      final a = detectAnimations(tmp.path, [
        'anim/banner(128x128).png',
      ], maxWordScans: 4).single;
      expect(a.frameW, 128);
    });
  });

  test('transparency gaps reveal a grid', () {
    final alpha = Uint8List(8 * 8);
    void blob(int x0, int y0) {
      for (var y = y0; y < y0 + 3; y++) {
        for (var x = x0; x < x0 + 3; x++) {
          alpha[y * 8 + x] = 255;
        }
      }
    }

    blob(0, 0);
    blob(4, 0);
    blob(0, 4);
    blob(5, 5);
    expect(gridFromTransparency(alpha, 8, 8), (4, 4));
    expect(
      gridFromTransparency(Uint8List(16)..fillRange(0, 16, 255), 4, 4),
      isNull,
    );

    png(
      'fx/3.png',
      128,
      128,
      blobs: [
        for (var y = 0; y < 2; y++)
          for (var x = 0; x < 2; x++) (x * 64 + 8, y * 64 + 8, 40, 40),
      ],
    );
    final s = detectSheetByPixels(tmp.path, 'fx/3.png')!;
    expect((s.frameW, s.cols, s.rows), (64, 2, 2));
  });

  group('transparency grid fallback', () {
    /// A [w]×[h] alpha buffer with opaque rectangles.
    Uint8List alphaOf(int w, int h, List<(int, int, int, int)> rects) {
      final a = Uint8List(w * h);
      for (final (x0, y0, rw, rh) in rects) {
        for (var y = y0; y < y0 + rh; y++) {
          for (var x = x0; x < x0 + rw; x++) {
            a[y * w + x] = 255;
          }
        }
      }
      return a;
    }

    test('clean grid is found by the run rule', () {
      final a = alphaOf(64, 64, [
        for (var y = 0; y < 4; y++)
          for (var x = 0; x < 4; x++) (x * 16 + 4, y * 16 + 4, 8, 8),
      ]);
      expect(gridFromTransparency(a, 64, 64), (16, 16));
    });

    test('particles inside cells break runs but not boundaries', () {
      // 4×4 grid of 16 px cells. Each cell holds a blob plus loose
      // particles near its edges, so gaps between runs don't line up with
      // cells, yet the cell boundaries stay transparent.
      final a = alphaOf(64, 64, [
        for (var y = 0; y < 4; y++)
          for (var x = 0; x < 4; x++) ...[
            (x * 16 + 6, y * 16 + 6, 4, 4),
            (x * 16 + 1 + (x + y) % 3, y * 16 + 13, 1, 1),
            (x * 16 + 13, y * 16 + 1 + (x * y) % 4, 1, 1),
          ],
      ]);
      expect(gridFromTransparency(a, 64, 64), (16, 16));
    });

    test('a single sprite with a transparent middle line is not split', () {
      // Fragmented columns (3 runs) and one row run: only x has a fallback.
      final a = alphaOf(64, 32, [
        (2, 4, 8, 24),
        (12, 4, 19, 24),
        (33, 4, 28, 24),
      ]);
      expect(gridFromTransparency(a, 64, 32), isNull);
    });

    test('square cells win when both axes allow several counts', () {
      // 64×32 with blobs every 16 px: x allows 2 and 4, y allows 2.
      final a = alphaOf(64, 32, [
        for (var y = 0; y < 2; y++)
          for (var x = 0; x < 4; x++) ...[
            (x * 16 + 3, y * 16 + 3, 10, 10),
            (x * 16 + 7, y * 16 + 1, 1, 1),
          ],
        (31, 20, 2, 1), // crosses x = 32: rules out 2 columns there
      ]);
      // The particle at x = 31..32 still leaves x = 33 clear (±1 px), so
      // both 2 and 4 columns fit; 4 gives square 16 px cells.
      expect(gridFromTransparency(a, 64, 32), (16, 16));
    });
  });

  test('detectAnimations combines kinds and overrides', () {
    png('Wolf/Idle/Idle.png', 128, 32);
    png('Wolf/All-Spritesheet.png', 96, 64);
    for (var i = 0; i < 3; i++) {
      png('fx/boom$i.png', 20, 20);
    }
    File(p.join(tmp.path, 'loop.gif')).writeAsBytesSync([
      ...'GIF89a'.codeUnits,
      8,
      0,
      8,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
    ]);
    final files = [
      for (final f in tmp.listSync(recursive: true).whereType<File>())
        p.relative(f.path, from: tmp.path),
    ]..sort();
    final anims = detectAnimations(
      tmp.path,
      files,
      overrides: {
        'Wolf/Idle/Idle.png': {'fps': 4, 'frame_w': 64},
      },
    );
    final byPath = {for (final a in anims) a.path: a};
    // No consensus grid: 96×64 isn't cut by the 32 px strip height.
    expect(byPath.keys, unorderedEquals(['Wolf/Idle/Idle.png', 'loop.gif']));
    expect(byPath['Wolf/Idle/Idle.png']!.fps, 4);
    expect(
      byPath['Wolf/Idle/Idle.png']!.cols,
      2,
      reason: 'frame_w override re-slices',
    );
    // Numbered frame files stay images.
    expect(byPath.keys.where((k) => k.startsWith('fx/')), isEmpty);
    expect(byPath['loop.gif']!.kind, AnimKind.gif);
    expect(pickTileAnimation(anims)!.path, 'Wolf/Idle/Idle.png');
  });

  test('choosePreviewAnimation replaces only weak previews', () {
    png('Orc/Orc_Idle.png', 600, 100);
    png('Orc/Orc_Attack.png', 800, 100);
    png('big_effect.png', 900, 700);
    png('mockup.png', 900, 700);
    final files = [
      'Orc/Orc_Attack.png',
      'Orc/Orc_Idle.png',
      'big_effect.png',
      'mockup.png',
    ];
    final weak = choosePreviewAnimation(
      tmp.path,
      files,
      preview: 'big_effect.png',
      rank: 6,
    );
    expect(weak.preview, 'Orc/Orc_Idle.png');
    expect(weak.anim!.cols, 6);
    final mockup = choosePreviewAnimation(
      tmp.path,
      files,
      preview: 'mockup.png',
      rank: 3,
    );
    expect(mockup.preview, 'mockup.png');
    expect(mockup.anim, isNull);
    // No consensus grid: the strip height doesn't cut a strong preview.
    final strong = choosePreviewAnimation(
      tmp.path,
      files,
      preview: 'big_effect.png',
      rank: 3,
    );
    expect(strong.preview, 'big_effect.png');
    expect(strong.anim, isNull);
  });

  test('SpriteAnim JSON round trip and copyWith', () {
    const a = SpriteAnim(
      path: 's.png',
      kind: AnimKind.sheet,
      frameW: 32,
      frameH: 32,
      cols: 4,
      rows: 2,
      fps: 12,
    );
    expect(SpriteAnim.fromJson(a.toJson()), a);
    final b = a.copyWith(frameW: 64);
    expect((b.cols, b.rows), (2, 2));
    // All rows is the default and isn't written; a single row is.
    expect(a.playRow, SpriteAnim.allRows);
    expect(a.toJson().containsKey('play_row'), isFalse);
    final row = a.copyWith(playRow: 1);
    expect(row.toJson()['play_row'], 1);
    expect(SpriteAnim.fromJson(row.toJson()), row);
    // A row past the new grid falls back to all rows.
    expect(row.copyWith(frameH: 64).playRow, SpriteAnim.allRows);
  });

  group('total frame count override', () {
    const tinyStrip = SpriteAnim(
      path: 't.png',
      kind: AnimKind.sheet,
      frameW: 5,
      frameH: 5,
    );
    const strip = SpriteAnim(
      path: 'chimney-smoke.png',
      kind: AnimKind.sheet,
      frameW: 64,
      frameH: 64,
      cols: 24,
    );

    test('one row: frame width follows the count', () {
      final s = strip.withFrameCount(16)!;
      expect((s.frameW, s.frameH, s.cols, s.rows), (96, 64, 16, 1));
      expect(s.frameCount, 16);
      // 1536 / 7 is uneven on one row; two rows of 4 fit.
      final seven = strip.withFrameCount(7)!;
      expect(
        (seven.cols, seven.rows, seven.frameW, seven.frameH),
        (4, 2, 384, 32),
      );
      expect(strip.withFrameCount(0), isNull);
      expect(strip.withFrameCount(SpriteAnim.maxFrameCount + 1), isNull);
      const tiny = SpriteAnim(
        path: 't.png',
        kind: AnimKind.sheet,
        frameW: 7,
        frameH: 7,
      );
      expect(tiny.withFrameCount(2), isNull, reason: '7 px splits no way');
    });

    test('multi-row: cols = ceil(n / rows), last row partly filled', () {
      const grid = SpriteAnim(
        path: 'g.png',
        kind: AnimKind.sheet,
        frameW: 32,
        frameH: 32,
        cols: 4,
        rows: 3,
      );
      final s = grid.withFrameCount(11)!;
      expect((s.cols, s.rows, s.frameW, s.frameCount), (4, 3, 32, 11));
      final t = grid.withFrameCount(6)!;
      expect((t.cols, t.frameW, t.frameCount), (2, 64, 6));
      // 4 frames: 3 rows would leave the last one empty; 2×2 fits.
      final four = grid.withFrameCount(4)!;
      expect((four.cols, four.rows, four.frameW, four.frameH), (2, 2, 64, 48));
      expect(grid.withFrameCount(5)!.frameCount, 5);
    });

    test('frame size edits clear it, fps edits keep it', () {
      final s = strip.withFrameCount(16)!;
      expect(s.copyWith(fps: 8).frameTotal, 16);
      final r = s.copyWith(frameW: 48);
      expect((r.frameTotal, r.cols, r.frameCount), (null, 32, 32));
    });

    test('JSON round trip and sidecar override', () {
      final s = strip.withFrameCount(16)!;
      expect(s.toJson()['frames_total'], 16);
      expect(SpriteAnim.fromJson(s.toJson()), s);
      expect(SpriteAnim.fromJson(strip.toJson()).frameTotal, isNull);
      expect(applyOverride(strip, {'frames': 16}), s);
      expect(applyOverride(tinyStrip, {'frames': 7}), tinyStrip);
      final g = applyOverride(strip, {'frames': 16, 'fps': 12});
      expect((g.frameW, g.fps, g.frameCount), (96, 12.0, 16));
    });
  });

  group('frame grid search', () {
    // islands-grass-tower-vfx.png: 640×640, detected as 5×5 of 128 px.
    const islands = SpriteAnim(
      path: 'props/islands-update/islands-grass-tower-vfx.png',
      kind: AnimKind.sheet,
      frameW: 128,
      frameH: 128,
      cols: 5,
      rows: 5,
    );

    test('16 frames on a 640 px sheet is a 4×4 grid of 160 px', () {
      final s = islands.withFrameCount(16)!;
      expect((s.cols, s.rows, s.frameW, s.frameH), (4, 4, 160, 160));
      expect(s.frameCount, 16);
    });

    test('square cells win, then the detected rows, then fewer empty', () {
      // 8 on 640×640: 4×2 (160×320) or 2×4 (320×160) are not square;
      // 3×3 (213 px) doesn't divide. 8 rows of 1 (640×80) neither.
      final eight = islands.withFrameCount(8)!;
      expect(eight.cols * eight.rows, greaterThanOrEqualTo(8));
      // 25 stays the detected grid.
      final all = islands.withFrameCount(25)!;
      expect((all.cols, all.rows, all.frameW), (5, 5, 128));
      // 4: 2×2 squares of 320.
      final four = islands.withFrameCount(4)!;
      expect((four.cols, four.rows, four.frameW), (2, 2, 320));
    });

    test('−/+ steps skip counts with no fitting grid', () {
      const tiny = SpriteAnim(
        path: 't.png',
        kind: AnimKind.sheet,
        frameW: 6,
        frameH: 6,
      );
      // 6×6 px: 1, 2, 3, 4 (2×2 of 3), 6 fit; 5 → 3×2 cells 2×3 fits too,
      // so check against withFrameCount itself.
      for (final from in [1, 2, 3, 4, 5, 6, 9]) {
        final up = tiny.nextFrameCount(from, 1);
        if (up == null) continue;
        expect(up, greaterThan(from));
        expect(tiny.withFrameCount(up), isNotNull);
        for (var n = from + 1; n < up; n++) {
          expect(tiny.withFrameCount(n), isNull, reason: '$n skipped');
        }
      }
      expect(tiny.nextFrameCount(1, -1), isNull);
      const prime = SpriteAnim(
        path: 'p.png',
        kind: AnimKind.sheet,
        frameW: 7,
        frameH: 7,
      );
      expect(prime.nextFrameCount(1, 1), isNot(2));
    });

    test('play row: JSON, copyWith and sidecar rows', () {
      // All rows by default (M34).
      expect(islands.playRow, SpriteAnim.allRows);
      expect(islands.rowToPlay, isNull);
      final first = islands.copyWith(playRow: 0);
      expect(first.rowToPlay, 0);
      expect(first.toJson()['play_row'], 0);
      expect(SpriteAnim.fromJson(first.toJson()), first);
      expect(SpriteAnim.fromJson(islands.toJson()).playRow, SpriteAnim.allRows);
      expect(first == islands, isFalse);
      // Size edits keep the row choice.
      expect(first.copyWith(frameW: 64).playRow, 0);
      expect(applyOverride(islands, {'rows': 3}).rowToPlay, 2);
      expect(applyOverride(islands, {'rows': 'x'}), islands);
    });

    test('false marks a file as not an animation', () {
      expect(isNotAnimation(false), isTrue);
      expect(isNotAnimation({'fps': 8}), isFalse);
      expect(isNotAnimation(null), isFalse);
    });
  });

  test('zoom: JSON, copyWith keeps or clears it, sidecar range', () {
    const a = SpriteAnim(
      path: 'a.png',
      kind: AnimKind.sheet,
      frameW: 16,
      frameH: 16,
      cols: 4,
    );
    final z = a.copyWith(zoom: 4);
    expect(z.zoom, 4);
    expect(z.copyWith(fps: 8).zoom, 4, reason: 'kept when not passed');
    expect(z.copyWith(frameW: 32).zoom, 4);
    expect(z.withFrameCount(2)!.zoom, 4);
    expect(z.copyWith(zoom: null).zoom, isNull);
    expect(z.toJson()['zoom'], 4);
    expect(a.toJson().containsKey('zoom'), isFalse);
    expect(SpriteAnim.fromJson(z.toJson()), z);
    expect(z == a, isFalse);
    expect(applyOverride(a, {'zoom': 2}).zoom, 2);
    expect(applyOverride(a, {'zoom': 0}).zoom, isNull);
    expect(applyOverride(a, {'zoom': 99}).zoom, isNull);
  });

  group('M43: non-square frames, same-folder grids, false strips', () {
    Map<String, SpriteAnim> detect(List<String> files, {int scans = 16}) => {
      for (final a in detectAnimations(tmp.path, files, maxWordScans: scans))
        a.path: a,
    };

    /// A [cols]×[rows] grid of [fw]×[fh] frames, each a blob with a 3 px
    /// transparent border; the first [used] cells only.
    List<(int, int, int, int)> cells(
      int fw,
      int fh,
      int cols,
      int rows, {
      int? used,
    }) => [
      for (var i = 0; i < (used ?? cols * rows); i++)
        ((i % cols) * fw + 3, (i ~/ cols) * fh + 3, fw - 6, fh - 6),
    ];

    test('a strip of 5 non-square frames (30×40) with gaps', () {
      png('fx/slash.png', 150, 40, blobs: cells(30, 40, 5, 1));
      final a = detect(['fx/slash.png'])['fx/slash.png']!;
      expect((a.frameW, a.frameH, a.cols, a.rows), (30, 40, 5, 1));
      expect(a.frameCount, 5);
    });

    test('a grid with an empty last cell: the frame total is the used '
        'cells', () {
      png('fx/boom-anim.png', 150, 120, blobs: cells(50, 60, 3, 2, used: 5));
      final a = detect(['fx/boom-anim.png'])['fx/boom-anim.png']!;
      expect((a.frameW, a.frameH, a.cols, a.rows), (50, 60, 3, 2));
      expect(a.frameTotal, 5);
      expect(a.frameCount, 5);
      // An empty cell before a used one keeps the whole grid.
      png(
        'fx/hole-anim.png',
        150,
        120,
        blobs: [
          for (final (i, b) in cells(50, 60, 3, 2).indexed)
            if (i != 2) b,
        ],
      );
      expect(
        detect(['fx/hole-anim.png'])['fx/hole-anim.png']!.frameTotal,
        null,
      );
    });

    test('a gap inside each frame (sails) does not split its row', () {
      // 4 × 2 cells of 40×50, each two parts with a transparent row between.
      png(
        'ship/sails-anim.png',
        160,
        100,
        blobs: [
          for (var r = 0; r < 2; r++)
            for (var c = 0; c < 4; c++) ...[
              (c * 40 + 5, r * 50 + 5, 30, 16),
              (c * 40 + 5, r * 50 + 24, 30, 22),
            ],
        ],
      );
      final a = detect(['ship/sails-anim.png'])['ship/sails-anim.png']!;
      expect((a.frameW, a.frameH, a.cols, a.rows), (40, 50, 4, 2));
    });

    test('big strips are checked: 9120×640 → 15 frames of 608×640', () {
      png(
        'ship/ship-animations-idle.png',
        9120,
        640,
        blobs: [for (var i = 0; i < 15; i++) (i * 608 + 202, 111, 197, 490)],
      );
      final a = detect([
        'ship/ship-animations-idle.png',
      ])['ship/ship-animations-idle.png']!;
      expect((a.frameW, a.frameH, a.cols, a.rows), (608, 640, 15, 1));
      // Over the pixel budget: not decoded.
      expect(
        detectAnimations(
          tmp.path,
          ['ship/ship-animations-idle.png'],
          maxWordScans: 16,
          maxWordPixels: 1000000,
        ),
        isEmpty,
      );
      expect(wordScanSize(16384, 1024), isTrue);
      expect(wordScanSize(16385, 640), isFalse);
      expect(wordScanSize(4096, 4096), isTrue);
      expect(wordScanSize(4097, 2048), isFalse);
    });

    test('a same-size file without gaps borrows its sibling\'s grid', () {
      png('ship/sail-anim.png', 150, 40, blobs: cells(30, 40, 5, 1));
      png('ship/sail-anim-fx.png', 150, 40); // particles: no clean gap
      png('ship/sail-anim-wide.png', 170, 40); // other size
      png('other/sail-anim-fx.png', 150, 40); // other folder
      final anims = detect([
        'ship/sail-anim.png',
        'ship/sail-anim-fx.png',
        'ship/sail-anim-wide.png',
        'other/sail-anim-fx.png',
      ]);
      final fx = anims['ship/sail-anim-fx.png']!;
      expect((fx.frameW, fx.frameH, fx.cols, fx.rows), (30, 40, 5, 1));
      expect(anims.containsKey('ship/sail-anim-wide.png'), isFalse);
      expect(anims.containsKey('other/sail-anim-fx.png'), isFalse);
    });

    test('borrowGrid: only less sure grids, only from surer ones', () {
      const sizes = {'a/x.png': (100, 50), 'a/y.png': (100, 50)};
      const x = SpriteAnim(
        path: 'a/x.png',
        kind: AnimKind.sheet,
        frameW: 25,
        frameH: 50,
        cols: 4,
      );
      const y = SpriteAnim(
        path: 'a/y.png',
        kind: AnimKind.sheet,
        frameW: 50,
        frameH: 50,
        cols: 2,
      );
      // y was cut from uneven gaps (0), x is sure (3): y takes x's grid.
      final b = borrowGrid({'a/x.png': 3, 'a/y.png': 0}, [x, y], sizes);
      expect(b.single.path, 'a/y.png');
      expect(b.single.frameW, 25);
      // Two sure grids keep their own.
      expect(borrowGrid({'a/x.png': 3, 'a/y.png': 2}, [x, y], sizes), isEmpty);
    });

    test('a 96×32 continuous prop stays an image', () {
      png('props/bags.png', 96, 32, blobs: [(5, 1, 85, 29)]);
      expect(detect(['props/bags.png']), isEmpty);
      // Without the budget the square guess stands.
      expect(detectAnimations(tmp.path, ['props/bags.png']), hasLength(1));
    });

    test('a 96×32 strip of 3 separate frames is still a strip', () {
      png('props/coin.png', 96, 32, blobs: cells(32, 32, 3, 1));
      final a = detect(['props/coin.png'])['props/coin.png']!;
      expect((a.frameW, a.cols), (32, 3));
      // Full frames (water tiles) cross every cut but look alike.
      png('props/water.png', 96, 32);
      expect(detect(['props/water.png']), contains('props/water.png'));
    });

    test('picturesAcrossCuts', () {
      Uint8List alpha(int w, int h, List<(int, int, int, int)> rects) {
        final a = Uint8List(w * h);
        for (final (x0, y0, rw, rh) in rects) {
          for (var y = y0; y < y0 + rh; y++) {
            for (var x = x0; x < x0 + rw; x++) {
              a[y * w + x] = 255;
            }
          }
        }
        return a;
      }

      // One wide prop over 6 cuts of 32.
      expect(
        picturesAcrossCuts(alpha(192, 32, [(15, 0, 162, 27)]), 192, 32, 32),
        isTrue,
      );
      // Touching only one cut of five: not most of them.
      expect(
        picturesAcrossCuts(
          alpha(192, 32, [
            for (var i = 0; i < 6; i++) (i * 32 + 4, 4, 24, 24),
            (60, 10, 8, 8),
          ]),
          192,
          32,
          32,
        ),
        isFalse,
      );
    });

    test(
      'two cells: never in a numbered series, otherwise clean gaps only',
      () {
        for (var i = 1; i <= 3; i++) {
          png('boat/boat-anim-$i.png', 60, 40, blobs: cells(30, 40, 2, 1));
        }
        png('raft/raft-anim.png', 60, 40, blobs: cells(30, 40, 2, 1));
        final anims = detect([
          for (var i = 1; i <= 3; i++) 'boat/boat-anim-$i.png',
          'raft/raft-anim.png',
        ]);
        expect(anims.keys, ['raft/raft-anim.png']);
        expect(anims['raft/raft-anim.png']!.cols, 2);
        expect(
          numberedFrames({
            'a/b-1.png': (4, 4),
            'a/b-2.png': (4, 4),
            'a/b-3.png': (4, 4),
            'a/c-1.png': (4, 4),
            'a/b-4.png': (8, 8),
          }),
          {'a/b-1.png', 'a/b-2.png', 'a/b-3.png'},
        );
      },
    );

    test('a file named as one frame is not cut', () {
      png('ship/parts/sail-frame12.png', 150, 40, blobs: cells(30, 40, 5, 1));
      expect(detect(['ship/parts/sail-frame12.png']), isEmpty);
    });

    test('a small size hint that is no frame size counts cells', () {
      png('fx/wind spritesheet3x2.png', 300, 80);
      final a = detectSheet('fx/wind spritesheet3x2.png', 300, 80)!;
      expect((a.frameW, a.frameH, a.cols, a.rows), (100, 40, 3, 2));
      // A real frame size still wins.
      expect(detectSheet('fx/wind(16x16).png', 64, 32)!.frameW, 16);
    });
  });

  group('M47: same-folder cell size, Make animation guess', () {
    Map<String, SpriteAnim> detect(List<String> files, {int scans = 16}) => {
      for (final a in detectAnimations(tmp.path, files, maxWordScans: scans))
        a.path: a,
    };

    /// Small sprites (12×20) in the middle of [cell]-px cells, the first
    /// [used] of a [cols]×[rows] grid; frames move a little, like a
    /// character.
    List<(int, int, int, int)> sprites(
      int cell,
      int cols,
      int rows,
      int used,
    ) => [
      for (var i = 0; i < used; i++)
        (
          (i % cols) * cell + cell ~/ 2 - 6 + i % 3,
          (i ~/ cols) * cell + cell ~/ 2 - 10,
          12,
          20,
        ),
    ];

    test('a 6×6 grid of 48 px cells with 35 sprites beside 48-high strips: '
        '35 frames of the strips\' size', () {
      // The strip: 10 frames of 48 px (square guess). The grid's name has
      // no animation word (`pulling` became one in M55).
      png('npc/fisher-idle.png', 480, 48, blobs: sprites(48, 10, 1, 10));
      png('npc/fisher-reeling.png', 288, 288, blobs: sprites(48, 6, 6, 35));
      final found = detect(['npc/fisher-idle.png', 'npc/fisher-reeling.png']);
      final a = found['npc/fisher-reeling.png']!;
      expect((a.frameW, a.frameH, a.cols, a.rows), (48, 48, 6, 6));
      expect(a.frameTotal, 35);
      expect(a.frameCount, 35);
      // Without the strip next to it, nothing detects it (no animation
      // word), but Make animation starts from the gap grid: the same 35.
      final alone = detect(['npc/fisher-reeling.png']);
      expect(alone, isEmpty);
      final guess = guessAnimation(
        tmp.path,
        'npc/fisher-reeling.png',
        288,
        288,
      );
      expect((guess.frameW, guess.frameH, guess.frameCount), (48, 48, 35));
    });

    test('the cells must be cut on transparent lines and hold 3 sprites', () {
      png('npc/walk.png', 192, 48, blobs: sprites(48, 4, 1, 4));
      // A picture across the cut lines: not cut.
      png('npc/sign.png', 96, 96, blobs: [(10, 10, 76, 76)]);
      // Two parts (a table over its chairs): not cut.
      png('npc/table.png', 48, 96, blobs: [(8, 8, 32, 30), (8, 56, 32, 30)]);
      // One shadow in a middle cell: not cut.
      png('npc/shadow.png', 144, 96, blobs: [(60, 60, 20, 8)]);
      final found = detect([
        'npc/walk.png',
        'npc/sign.png',
        'npc/table.png',
        'npc/shadow.png',
      ]);
      expect(found.keys, ['npc/walk.png']);
    });

    test('not for tilesets, atlases or a one-frame name', () {
      png('npc/walk.png', 192, 48, blobs: sprites(48, 4, 1, 4));
      png('npc/tileset.png', 144, 144, blobs: sprites(48, 3, 3, 9));
      png('npc/pose-frame3.png', 144, 144, blobs: sprites(48, 3, 3, 9));
      final found = detect([
        'npc/walk.png',
        'npc/tileset.png',
        'npc/pose-frame3.png',
      ]);
      expect(found.keys, ['npc/walk.png']);
    });

    test('folderFrameSizes: most used first, own folder only', () {
      SpriteAnim sheet(String path, int fw, int fh) => SpriteAnim(
        path: path,
        kind: AnimKind.sheet,
        frameW: fw,
        frameH: fh,
        cols: 4,
      );
      expect(
        folderFrameSizes('a/x.png', [
          sheet('a/1.png', 32, 32),
          sheet('a/2.png', 64, 48),
          sheet('a/3.png', 64, 48),
          sheet('b/4.png', 16, 16),
          sheet('a/x.png', 8, 8),
        ]),
        [(64, 48), (32, 32)],
      );
    });

    test('guessAnimation: folder cells, then gaps, then square, then 1', () {
      png('g/grid.png', 144, 144, blobs: sprites(48, 3, 3, 9));
      // Folder cells win over the gap grid when they fit.
      var g = guessAnimation(
        tmp.path,
        'g/grid.png',
        144,
        144,
        folderSizes: const [(48, 48)],
      );
      expect((g.frameW, g.cols, g.rows), (48, 3, 3));
      // A folder size that doesn't cut cleanly is skipped.
      g = guessAnimation(
        tmp.path,
        'g/grid.png',
        144,
        144,
        folderSizes: const [(72, 72)],
      );
      expect((g.frameW, g.cols, g.rows), (48, 3, 3));
      // No gaps (opaque): square frames for a strip, else one frame.
      png('g/solid.png', 96, 32);
      g = guessAnimation(tmp.path, 'g/solid.png', 96, 32);
      expect((g.frameW, g.cols), (32, 3));
      png('g/odd.png', 50, 30);
      g = guessAnimation(tmp.path, 'g/odd.png', 50, 30);
      expect((g.frameW, g.cols, g.frameCount), (50, 1, 1));
    });
  });

  group('M55: word stems, folder frame sizes, smoke, one-picture props', () {
    Map<String, SpriteAnim> detect(List<String> files, {int scans = 64}) => {
      for (final a in detectAnimations(tmp.path, files, maxWordScans: scans))
        a.path: a,
    };

    /// Small (6×8) sprites in [cell]-px cells: those of [cols]×[rows] whose
    /// index [drawn] accepts.
    List<(int, int, int, int)> sprites(
      int cell,
      int cols,
      int rows,
      bool Function(int i) drawn,
    ) => [
      for (var i = 0; i < cols * rows; i++)
        if (drawn(i)) ((i % cols) * cell + 5, (i ~/ cols) * cell + 4, 6, 8),
    ];

    test('a trailing number keeps the word: idle2, attack1, atk2', () {
      for (final name in [
        'crab-claw enemy-idle2.png',
        'hero-attack1.png',
        'crab-claw enemy-atk2-finish.png',
        'Attack2.png',
        'fisherman-fishing-throwing.png',
      ]) {
        expect(hasAnimationWord('c/$name'), isTrue, reason: name);
      }
      expect(hasAnimationWord('c/crab-claw enemy-2.png'), isFalse);
      expect(animationWords, containsAll(['atk', 'throwing', 'fishing']));
      // Not-animation words match exactly: `tilesets and props` holds
      // animated props.
      expect(detectSheet('tilesets and props/fountain.png', 64, 16), isNotNull);
      expect(detectSheet('tileset2/water.png', 64, 16), isNull);
    });

    test('17 frames on 1920×320 is 12 × 2 of 160, not 5 × 4', () {
      const death = SpriteAnim(
        path: 'villager-R-Arm-skin2-death.png',
        kind: AnimKind.sheet,
        frameW: 320,
        frameH: 320,
        cols: 6,
      );
      final s = death.withFrameCount(17)!;
      expect(
        (s.cols, s.rows, s.frameW, s.frameH, s.frameCount),
        (12, 2, 160, 160, 17),
      );
    });

    test('a strip without a word takes its folder\'s frame size when the '
        'square cuts run through drawings', () {
      // 8 frames of 40×32 (sprites 20 wide) beside a sibling with a word.
      final wide = [for (var i = 0; i < 8; i++) (i * 40 + 10, 6, 20, 20)];
      png('crab/crab-idle.png', 320, 32, blobs: wide);
      png('crab/crab-xyz.png', 320, 32, blobs: wide);
      final found = detect(['crab/crab-idle.png', 'crab/crab-xyz.png']);
      for (final a in found.values) {
        expect((a.frameW, a.frameH, a.cols), (40, 32, 8), reason: a.path);
      }
    });

    test('a two-row death sheet takes the 16 px cells of its siblings', () {
      // Siblings: 10 frames of 16 px. Death: 192×32, 12 × 2 cells of 16
      // with 17 sprites; the square guess was 6 of 32.
      png(
        'parts/arm-idle.png',
        160,
        16,
        blobs: sprites(16, 10, 1, (_) => true),
      );
      png(
        'parts/leg-idle.png',
        160,
        16,
        blobs: sprites(16, 10, 1, (_) => true),
      );
      png(
        'parts/arm-death.png',
        192,
        32,
        blobs: sprites(16, 12, 2, (i) => i < 17),
      );
      final a = detect([
        'parts/arm-idle.png',
        'parts/leg-idle.png',
        'parts/arm-death.png',
      ])['parts/arm-death.png']!;
      expect(
        (a.frameW, a.frameH, a.cols, a.rows, a.frameCount),
        (16, 16, 12, 2, 17),
      );
      // Bigger cells over a clean strip don't win: 16 px frames stay.
      png('small/coin-spin.png', 64, 16, blobs: sprites(16, 4, 1, (_) => true));
      png(
        'small/gem-spin.png',
        64,
        32,
        blobs: [(4, 4, 24, 24), (36, 4, 24, 24)],
      );
      png(
        'small/orb-spin.png',
        64,
        32,
        blobs: [(4, 4, 24, 24), (36, 4, 24, 24)],
      );
      expect(
        detect([
          'small/coin-spin.png',
          'small/gem-spin.png',
          'small/orb-spin.png',
        ])['small/coin-spin.png']!.frameW,
        16,
      );
    });

    test(
      'a body-part layer hidden in some frames takes its siblings\' grid',
      () {
        // Idle strips of 16 px frames, two-row death sheets of 16 px cells.
        for (final part in ['head', 'body']) {
          png(
            'parts/$part-idle.png',
            160,
            16,
            blobs: sprites(16, 10, 1, (_) => true),
          );
          png(
            'parts/$part-death.png',
            192,
            32,
            blobs: sprites(16, 12, 2, (i) => i < 20),
          );
        }
        // The arm shows in frame 1 and 7–12 only.
        png(
          'parts/arm-death.png',
          192,
          32,
          blobs: sprites(16, 12, 2, (i) => i == 0 || i >= 6 && i < 12),
        );
        final found = detect([
          'parts/head-idle.png',
          'parts/body-idle.png',
          'parts/head-death.png',
          'parts/body-death.png',
          'parts/arm-death.png',
        ]);
        final arm = found['parts/arm-death.png']!;
        expect(
          (arm.frameW, arm.frameH, arm.cols, arm.rows, arm.frameCount),
          (16, 16, 12, 2, 12),
        );
        expect(found['parts/head-death.png']!.frameCount, 20);
        expect(
          siblingGrids(found.values, {
            for (final f in found.keys)
              f: f.endsWith('idle.png') ? (160, 16) : (192, 32),
          })[('parts', 192, 32)],
          (16, 16),
        );
      },
    );

    test('smoke: the most frames with clear cuts and a drawing in each', () {
      // 16 frames of 24×16 on 384×16, each with two wisps and a gap
      // inside, so the gaps are uneven; the square guess (24 of 16)
      // leaves frames empty.
      final wisps = [
        for (var i = 0; i < 16; i++) ...[
          (i * 24 + 4, 4, 5, 6),
          (i * 24 + 10, 2, 6 + i % 3, 8),
        ],
      ];
      png('fx/chimney-smoke.png', 384, 16, blobs: wisps);
      final a = detect(['fx/chimney-smoke.png'])['fx/chimney-smoke.png']!;
      expect((a.frameW, a.frameH, a.cols), (24, 16, 16));
    });

    test('thin parts over every cut make one picture (antlers, bunting)', () {
      // Antlers: a 1 px line from x 22 to 73 over a 20 px head.
      png(
        'props/decor_shields_7.png',
        96,
        32,
        blobs: [(22, 6, 52, 2), (38, 3, 20, 18)],
      );
      // Bunting: a string over the whole width with pennants on it.
      png(
        'props/pennant-bunting_2.png',
        224,
        32,
        blobs: [
          (6, 5, 215, 1),
          for (var x = 10; x < 210; x += 24) (x, 6, 10, 12),
        ],
      );
      expect(
        detect(['props/decor_shields_7.png', 'props/pennant-bunting_2.png']),
        isEmpty,
      );
    });
  });
}
