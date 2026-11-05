import 'dart:io';
import 'dart:typed_data';

import 'package:assets_explorer/core/animation_detector.dart';
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

    test('grid from consensus strip height', () {
      expect(detectSheet('All-Spritesheet.png', 864, 672), isNull);
      final s = detectSheet('All-Spritesheet.png', 864, 672, consensus: 96)!;
      expect((s.cols, s.rows), (9, 7));
    });

    test('non-dividing hints and plain images are rejected', () {
      expect(detectSheet('(32x32)/odd.png', 100, 70), isNull);
      expect(detectSheet('photo.png', 800, 600), isNull);
    });
  });

  test('sequences: consecutive numbers, same size, small frames', () {
    for (var i = 0; i < 4; i++) {
      png('walk/walk_$i.png', 16, 16);
    }
    png('gap/f1.png', 8, 8);
    png('gap/f2.png', 8, 8);
    png('gap/f4.png', 8, 8);
    for (var i = 1; i <= 3; i++) {
      png('big/$i.png', 600, 600);
    }
    final files = [
      for (final f in tmp.listSync(recursive: true).whereType<File>())
        p.relative(f.path, from: tmp.path),
    ];
    final seqs = detectSequences(tmp.path, files);
    expect(seqs, hasLength(1));
    expect(seqs.single.frames, [
      'walk/walk_0.png',
      'walk/walk_1.png',
      'walk/walk_2.png',
      'walk/walk_3.png',
    ]);
    expect(seqs.single.label, 'walk');
    expect(seqs.single.frameCount, 4);
  });

  group('sequence word rule', () {
    List<String> listed() => [
      for (final f in tmp.listSync(recursive: true).whereType<File>())
        p.relative(f.path, from: tmp.path),
    ];

    test('numbered props without an animation word are images', () {
      for (var i = 0; i < 6; i++) {
        png('props-sprites/barrels_$i.png', 16, 16);
        png('Decorations_sprites/chimney-h_$i.png', 8, 32);
      }
      expect(detectSequences(tmp.path, listed()), isEmpty);
      expect(animationCandidates(listed()), isEmpty);
    });

    test('a word in the prefix or any folder keeps the sequence', () {
      for (var i = 1; i <= 3; i++) {
        png('props/torch_fire_$i.png', 16, 16);
        png('Effects/Hit/$i.png', 16, 16);
        png('Animated stuff/flag/flag$i.png', 16, 16);
        png('Projectiles/Fireball$i.png', 8, 8);
      }
      final seqs = detectSequences(tmp.path, listed());
      expect(seqs.map((s) => s.path).toSet(), {
        'props/torch_fire_1.png',
        'Effects/Hit/1.png',
        'Animated stuff/flag/flag1.png',
        'Projectiles/Fireball1.png',
      });
      expect(animationCandidates(listed()), hasLength(12));
    });

    test('hasAnimationWord matches plurals and ignores the pack root', () {
      expect(hasAnimationWord('fx/explosions', 'boom'), isTrue);
      expect(hasAnimationWord('.', 'walk_'), isTrue);
      expect(hasAnimationWord('.', 'barrels_'), isFalse);
      expect(hasAnimationWord('furniture', 'decor_animals_'), isFalse);
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

  test('detectAnimations combines kinds, consensus and overrides', () {
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
    expect(
      byPath.keys,
      unorderedEquals([
        'Wolf/Idle/Idle.png',
        'Wolf/All-Spritesheet.png',
        'fx/boom0.png',
        'loop.gif',
      ]),
    );
    expect(byPath['Wolf/All-Spritesheet.png']!.cols, 3);
    expect(byPath['Wolf/Idle/Idle.png']!.fps, 4);
    expect(
      byPath['Wolf/Idle/Idle.png']!.cols,
      2,
      reason: 'frame_w override re-slices',
    );
    expect(byPath['fx/boom0.png']!.kind, AnimKind.sequence);
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
    // A named sheet keeps its place and gains frames from the strip height.
    final sheet = choosePreviewAnimation(
      tmp.path,
      files,
      preview: 'big_effect.png',
      rank: 3,
    );
    expect(sheet.preview, 'big_effect.png');
    expect((sheet.anim!.cols, sheet.anim!.rows), (9, 7));
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
    const seq = SpriteAnim(
      path: 'a_1.png',
      kind: AnimKind.sequence,
      frameW: 8,
      frameH: 8,
      frames: ['a_1.png', 'a_2.png'],
    );
    expect(SpriteAnim.fromJson(seq.toJson()).frames, seq.frames);
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
      expect(islands.playRow, 0);
      expect(islands.rowToPlay, 0);
      final all = islands.copyWith(playRow: SpriteAnim.allRows);
      expect(all.rowToPlay, isNull);
      expect(all.toJson()['play_row'], SpriteAnim.allRows);
      expect(SpriteAnim.fromJson(all.toJson()), all);
      expect(SpriteAnim.fromJson(islands.toJson()).playRow, 0);
      expect(all == islands, isFalse);
      // Size edits keep the row choice.
      expect(all.copyWith(frameW: 64).playRow, SpriteAnim.allRows);
      expect(applyOverride(islands, {'rows': 'all'}).rowToPlay, isNull);
      expect(applyOverride(islands, {'rows': 3}).rowToPlay, 2);
      expect(applyOverride(islands, {'rows': 'x'}), islands);
    });

    test('false marks a file as not an animation', () {
      expect(isNotAnimation(false), isTrue);
      expect(isNotAnimation({'fps': 8}), isFalse);
      expect(isNotAnimation(null), isFalse);
    });
  });
}
