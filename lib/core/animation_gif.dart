import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import 'animation_detector.dart';
import 'gif_encoder.dart';

/// [anim] as a looping GIF, the way its card plays it: the sheet's cells
/// ([SpriteAnim.frameCells]) at their own size, fully transparent cells
/// left out (as the card skips them, unless all are), each shown for 1 / fps s. A GIF
/// animation is its own file's bytes. Null when the file can't be read.
Uint8List? animationGif(String packPath, SpriteAnim anim) {
  final file = File(p.join(packPath, anim.path));
  final Uint8List bytes;
  try {
    bytes = file.readAsBytesSync();
  } on FileSystemException {
    return null;
  }
  if (anim.kind == AnimKind.gif) return bytes;
  final decoded = img.decodeImage(bytes);
  if (decoded == null) return null;
  final image = decoded.convert(numChannels: 4, format: img.Format.uint8);
  final rgba = image.getBytes(order: img.ChannelOrder.rgba);
  final delay = (1000 / (anim.fps <= 0 ? SpriteAnim.defaultFps : anim.fps))
      .round();
  final frames = <GifFrame>[];
  final empty = <GifFrame>[];
  for (final (x, y, w, h) in anim.frameCells(image.width, image.height)) {
    final cell = Uint8List(w * h * 4);
    var opaque = false;
    for (var row = 0; row < h; row++) {
      final sy = y + row;
      if (sy >= image.height) break;
      for (var col = 0; col < w; col++) {
        final sx = x + col;
        if (sx >= image.width) break;
        final from = (sy * image.width + sx) * 4;
        final to = (row * w + col) * 4;
        cell
          ..[to] = rgba[from]
          ..[to + 1] = rgba[from + 1]
          ..[to + 2] = rgba[from + 2]
          ..[to + 3] = rgba[from + 3];
        if (rgba[from + 3] != 0) opaque = true;
      }
    }
    final frame = GifFrame(width: w, height: h, rgba: cell, delayMs: delay);
    (opaque ? frames : empty).add(frame);
  }
  // Like the card: only when nothing is left are the empty cells kept.
  if (frames.isEmpty) frames.addAll(empty);
  if (frames.isEmpty) return null;
  return encodeGif(frames);
}

/// [animationGif] off the UI thread.
Future<Uint8List?> makeAnimationGif(String packPath, SpriteAnim anim) =>
    Isolate.run(() => animationGif(packPath, anim));
