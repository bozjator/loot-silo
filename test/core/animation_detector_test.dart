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
}
