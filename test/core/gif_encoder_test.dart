import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:loot_silo/core/animation_detector.dart';
import 'package:loot_silo/core/animation_gif.dart';
import 'package:loot_silo/core/gif_encoder.dart';
import 'package:path/path.dart' as p;

/// Decodes [gif] with the engine's codec: each frame's RGBA and duration.
Future<List<(Uint8List, Duration)>> decode(Uint8List gif) async {
  final codec = await ui.instantiateImageCodec(gif);
  final out = <(Uint8List, Duration)>[];
  for (var i = 0; i < codec.frameCount; i++) {
    final frame = await codec.getNextFrame();
    final data = await frame.image.toByteData(
      format: ui.ImageByteFormat.rawStraightRgba,
    );
    out.add((data!.buffer.asUint8List(), frame.duration));
    frame.image.dispose();
  }
  codec.dispose();
  return out;
}

/// A [w]×[h] frame of pixel art: [colors] colours in stripes shifted by
/// [seed], a transparent corner.
GifFrame art(int w, int h, int seed, {int colors = 6, int delayMs = 100}) {
  final rgba = Uint8List(w * h * 4);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final i = (y * w + x) * 4;
      if (x < 2 && y < 2) continue; // transparent
      final c = ((x + y * 3 + seed) * 7919) % colors;
      rgba
        ..[i] = (c * 53) % 256
        ..[i + 1] = (c * 97 + 31) % 256
        ..[i + 2] = (c * 193 + 7) % 256
        ..[i + 3] = 255;
    }
  }
  return GifFrame(width: w, height: h, rgba: rgba, delayMs: delayMs);
}

/// Alpha below 128 is transparent (all zero after decoding).
Uint8List expected(GifFrame f) {
  final out = Uint8List.fromList(f.rgba);
  for (var i = 0; i < out.length; i += 4) {
    if (out[i + 3] < 128) {
      out.fillRange(i, i + 4, 0);
    } else {
      out[i + 3] = 255;
    }
  }
  return out;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('every frame and delay round-trips exactly (≤ 256 colours)', () async {
    final frames = [
      for (var i = 0; i < 5; i++) art(23, 17, i, delayMs: 80 + i * 10),
    ];
    final decoded = await decode(encodeGif(frames));
    expect(decoded, hasLength(5));
    for (var i = 0; i < 5; i++) {
      expect(decoded[i].$1, expected(frames[i]), reason: 'frame $i');
      expect(decoded[i].$2, Duration(milliseconds: gifDelay(80 + i * 10) * 10));
    }
  });

  test('big frames reset the LZW table and still decode', () async {
    // Noise-like art: many codes, so the 4096-entry table fills.
    final frames = [art(200, 150, 3, colors: 255)];
    final decoded = await decode(encodeGif(frames));
    expect(decoded.single.$1, expected(frames.single));
  });

  test('transparency: alpha < 128 is cut out, the rest kept opaque', () async {
    final rgba = Uint8List(4 * 4 * 4);
    for (var i = 0; i < 16; i++) {
      rgba
        ..[i * 4] = 200
        ..[i * 4 + 3] = i < 8 ? 40 : 200;
    }
    final frame = GifFrame(width: 4, height: 4, rgba: rgba, delayMs: 100);
    final decoded = await decode(encodeGif([frame]));
    final px = decoded.single.$1;
    expect(px[3], 0);
    expect(px[8 * 4 + 3], 255);
    expect(px[8 * 4], 200);
  });

  test('a fully transparent frame clears the one before (disposal)', () async {
    final solid = art(6, 6, 1);
    final clear = GifFrame(
      width: 6,
      height: 6,
      rgba: Uint8List(6 * 6 * 4),
      delayMs: 100,
    );
    final decoded = await decode(encodeGif([solid, clear]));
    expect(decoded[1].$1.every((b) => b == 0), isTrue);
  });

  test('more than 256 colours: median cut, close to the source', () async {
    final rgba = Uint8List(64 * 64 * 4);
    for (var y = 0; y < 64; y++) {
      for (var x = 0; x < 64; x++) {
        final i = (y * 64 + x) * 4;
        rgba
          ..[i] = x * 4
          ..[i + 1] = y * 4
          ..[i + 2] = (x + y) * 2
          ..[i + 3] = 255;
      }
    }
    final frame = GifFrame(width: 64, height: 64, rgba: rgba, delayMs: 100);
    final decoded = (await decode(encodeGif([frame]))).single.$1;
    var worst = 0;
    for (var i = 0; i < rgba.length; i++) {
      final d = (decoded[i] - rgba[i]).abs();
      if (d > worst) worst = d;
    }
    // 4096 colours in at most 256 boxes: within a box's width.
    expect(worst, lessThan(40));
  });

  test('delays: 1/100 s, rounded, at least 2', () {
    expect(gifDelay(0), 2);
    expect(gifDelay(14), 2);
    expect(gifDelay(83), 8);
    expect(gifDelay(100), 10);
    expect(gifDelay(1000 ~/ 12), 8);
  });

  test(
    'a sheet as the card plays it: cells, order, fps, empty cells',
    () async {
      final tmp = Directory.systemTemp.createTempSync('gif');
      addTearDown(() => tmp.deleteSync(recursive: true));
      // 4 × 2 cells of 8 px; cell 6 is empty, so the card skips it.
      final sheet = img.Image(width: 32, height: 16, numChannels: 4);
      for (var cell = 0; cell < 8; cell++) {
        if (cell == 6) continue;
        final ox = (cell % 4) * 8, oy = (cell ~/ 4) * 8;
        for (var y = 0; y < 8; y++) {
          for (var x = 0; x < 8; x++) {
            sheet.setPixelRgba(
              ox + x,
              oy + y,
              cell * 30,
              255 - cell * 20,
              x * 20,
              255,
            );
          }
        }
      }
      File(p.join(tmp.path, 'run.png')).writeAsBytesSync(img.encodePng(sheet));
      const anim = SpriteAnim(
        path: 'run.png',
        kind: AnimKind.sheet,
        frameW: 8,
        frameH: 8,
        cols: 4,
        rows: 2,
        fps: 12,
      );
      final decoded = await decode(animationGif(tmp.path, anim)!);
      expect(decoded, hasLength(7));
      final cells = [0, 1, 2, 3, 4, 5, 7];
      for (var i = 0; i < cells.length; i++) {
        final cell = cells[i];
        final ox = (cell % 4) * 8, oy = (cell ~/ 4) * 8;
        final px = decoded[i].$1;
        for (var y = 0; y < 8; y++) {
          for (var x = 0; x < 8; x++) {
            final s = sheet.getPixel(ox + x, oy + y);
            final at = (y * 8 + x) * 4;
            expect(
              [px[at], px[at + 1], px[at + 2], px[at + 3]],
              [s.r, s.g, s.b, 255],
              reason: 'cell $cell ($x, $y)',
            );
          }
        }
        expect(decoded[i].$2, const Duration(milliseconds: 80));
      }
      // One row only, as the Edit dialog's row choice plays it.
      final row = await decode(
        animationGif(tmp.path, anim.copyWith(playRow: 1))!,
      );
      expect(row, hasLength(3));
      // A GIF animation is copied as it is.
      final gif = encodeGif([art(4, 4, 0)]);
      File(p.join(tmp.path, 'a.gif')).writeAsBytesSync(gif);
      expect(
        animationGif(
          tmp.path,
          const SpriteAnim(
            path: 'a.gif',
            kind: AnimKind.gif,
            frameW: 4,
            frameH: 4,
          ),
        ),
        gif,
      );
    },
  );

  test('timings: 16 × 64² and 60 × 256² frames', () {
    String time(List<GifFrame> frames) {
      encodeGif(frames); // warm up
      final watch = Stopwatch()..start();
      final bytes = encodeGif(frames);
      return '${watch.elapsedMilliseconds} ms, ${bytes.length ~/ 1024} KB';
    }

    final small = [for (var i = 0; i < 16; i++) art(64, 64, i, colors: 16)];
    final big = [for (var i = 0; i < 60; i++) art(256, 256, i, colors: 32)];
    // ignore: avoid_print
    print('GIF encode: 16 × 64×64 ${time(small)}; 60 × 256×256 ${time(big)}');
  });
}
