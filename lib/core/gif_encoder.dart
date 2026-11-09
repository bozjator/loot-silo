import 'dart:typed_data';

/// One frame for [encodeGif]: [width] × [height] RGBA pixels, shown for
/// [delayMs].
class GifFrame {
  GifFrame({
    required this.width,
    required this.height,
    required this.rgba,
    required this.delayMs,
  }) : assert(rgba.length == width * height * 4);

  final int width;
  final int height;
  final Uint8List rgba;
  final int delayMs;
}

/// A looping GIF89a of [frames] (all the same size), in pure Dart.
///
/// Each frame gets its own colour table: exact when it has at most 256
/// colours (255 when some pixels are transparent), else a median cut.
/// Pixels with alpha below 128 use the one transparent index; frames are
/// disposed to the background, so a transparent pixel never shows the
/// frame before. Delays are in 1/100 s, rounded, at least 2 (browsers and
/// chat apps treat 0 and 1 as "as fast as possible" or 10).
Uint8List encodeGif(List<GifFrame> frames) {
  if (frames.isEmpty) throw ArgumentError('No frames');
  final w = frames.first.width;
  final h = frames.first.height;
  if (frames.any((f) => f.width != w || f.height != h)) {
    throw ArgumentError('Frames differ in size');
  }
  final out = BytesBuilder(copy: false);
  void u16(int v) => out
    ..addByte(v & 0xFF)
    ..addByte((v >> 8) & 0xFF);

  out.add('GIF89a'.codeUnits);
  u16(w);
  u16(h);
  // No global colour table; background index 0, no aspect ratio.
  out
    ..addByte(0x00)
    ..addByte(0)
    ..addByte(0);
  // NETSCAPE2.0: loop forever.
  out
    ..add(const [0x21, 0xFF, 0x0B])
    ..add('NETSCAPE2.0'.codeUnits)
    ..add(const [0x03, 0x01, 0x00, 0x00, 0x00]);

  for (final frame in frames) {
    final (:palette, :indices, :transparent) = _quantize(frame.rgba);
    final colors = palette.length ~/ 3;
    var bits = 1;
    while ((1 << bits) < colors) {
      bits++;
    }
    final tableSize = 1 << bits;

    // Graphic control: disposal 2 (to background), transparency, delay.
    out
      ..add(const [0x21, 0xF9, 0x04])
      ..addByte((2 << 2) | (transparent != null ? 1 : 0));
    u16(gifDelay(frame.delayMs));
    out
      ..addByte(transparent ?? 0)
      ..addByte(0);

    // Image descriptor with a local colour table.
    out.addByte(0x2C);
    u16(0);
    u16(0);
    u16(w);
    u16(h);
    out.addByte(0x80 | (bits - 1));
    out.add(palette);
    out.add(Uint8List(tableSize * 3 - palette.length));

    final minCode = bits < 2 ? 2 : bits;
    out.addByte(minCode);
    final data = _lzw(indices, minCode);
    for (var i = 0; i < data.length; i += 255) {
      final n = data.length - i < 255 ? data.length - i : 255;
      out
        ..addByte(n)
        ..add(Uint8List.sublistView(data, i, i + n));
    }
    out.addByte(0);
  }
  out.addByte(0x3B);
  return out.toBytes();
}

/// [ms] as GIF centiseconds: rounded, at least 2.
int gifDelay(int ms) {
  final cs = (ms / 10).round();
  return cs < 2 ? 2 : (cs > 0xFFFF ? 0xFFFF : cs);
}

/// A palette (RGB triplets) and one index per pixel; [transparent] is the
/// index used for alpha < 128, if any pixel needs it.
({Uint8List palette, Uint8List indices, int? transparent}) _quantize(
  Uint8List rgba,
) {
  final n = rgba.length ~/ 4;
  final indices = Uint8List(n);
  var hasTransparent = false;
  final counts = <int, int>{};
  for (var i = 0; i < n; i++) {
    if (rgba[i * 4 + 3] < 128) {
      hasTransparent = true;
      continue;
    }
    final c = (rgba[i * 4] << 16) | (rgba[i * 4 + 1] << 8) | rgba[i * 4 + 2];
    counts[c] = (counts[c] ?? 0) + 1;
  }
  final room = hasTransparent ? 255 : 256;
  final List<int> colors;
  final Map<int, int> indexOf;
  if (counts.length <= room) {
    colors = counts.keys.toList();
    indexOf = {for (var i = 0; i < colors.length; i++) colors[i]: i};
  } else {
    (colors, indexOf) = _medianCut(counts, room);
  }
  final transparent = hasTransparent ? colors.length : null;
  final total = colors.length + (hasTransparent ? 1 : 0);
  // At least two entries: a one-colour table is not valid everywhere.
  final palette = Uint8List((total < 2 ? 2 : total) * 3);
  for (var i = 0; i < colors.length; i++) {
    palette[i * 3] = colors[i] >> 16;
    palette[i * 3 + 1] = (colors[i] >> 8) & 0xFF;
    palette[i * 3 + 2] = colors[i] & 0xFF;
  }
  for (var i = 0; i < n; i++) {
    if (rgba[i * 4 + 3] < 128) {
      indices[i] = transparent!;
    } else {
      final c = (rgba[i * 4] << 16) | (rgba[i * 4 + 1] << 8) | rgba[i * 4 + 2];
      indices[i] = indexOf[c]!;
    }
  }
  return (palette: palette, indices: indices, transparent: transparent);
}

/// Splits the colours (weighted by count) into at most [room] boxes along
/// their widest channel; each box's colour is its weighted mean.
(List<int>, Map<int, int>) _medianCut(Map<int, int> counts, int room) {
  var boxes = [counts.keys.toList()];
  int channel(int c, int ch) => (c >> (16 - 8 * ch)) & 0xFF;
  (int, int) widest(List<int> box) {
    var best = 0, range = -1;
    for (var ch = 0; ch < 3; ch++) {
      var lo = 255, hi = 0;
      for (final c in box) {
        final v = channel(c, ch);
        if (v < lo) lo = v;
        if (v > hi) hi = v;
      }
      if (hi - lo > range) {
        range = hi - lo;
        best = ch;
      }
    }
    return (best, range);
  }

  while (boxes.length < room) {
    // Split the box with the widest spread.
    var pick = -1, pickRange = 0, pickChannel = 0;
    for (var i = 0; i < boxes.length; i++) {
      if (boxes[i].length < 2) continue;
      final (ch, range) = widest(boxes[i]);
      if (range > pickRange) {
        pick = i;
        pickRange = range;
        pickChannel = ch;
      }
    }
    if (pick < 0) break;
    final box = boxes[pick]
      ..sort((a, b) => channel(a, pickChannel) - channel(b, pickChannel));
    final total = box.fold(0, (s, c) => s + counts[c]!);
    var acc = 0, cut = 1;
    for (var i = 0; i < box.length - 1; i++) {
      acc += counts[box[i]]!;
      cut = i + 1;
      if (acc * 2 >= total) break;
    }
    boxes = [
      ...boxes.sublist(0, pick),
      box.sublist(0, cut),
      box.sublist(cut),
      ...boxes.sublist(pick + 1),
    ];
  }
  final colors = <int>[];
  final indexOf = <int, int>{};
  for (final box in boxes) {
    var r = 0, g = 0, b = 0, weight = 0;
    for (final c in box) {
      final k = counts[c]!;
      r += channel(c, 0) * k;
      g += channel(c, 1) * k;
      b += channel(c, 2) * k;
      weight += k;
    }
    final i = colors.length;
    colors.add(
      ((r / weight).round() << 16) |
          ((g / weight).round() << 8) |
          (b / weight).round(),
    );
    for (final c in box) {
      indexOf[c] = i;
    }
  }
  return (colors, indexOf);
}

/// GIF's variable-length LZW, codes packed least significant bit first.
Uint8List _lzw(Uint8List indices, int minCode) {
  final clear = 1 << minCode;
  final end = clear + 1;
  final out = BytesBuilder(copy: false);
  var buffer = 0, bufferBits = 0;
  var size = minCode + 1;
  void emit(int code) {
    buffer |= code << bufferBits;
    bufferBits += size;
    while (bufferBits >= 8) {
      out.addByte(buffer & 0xFF);
      buffer >>= 8;
      bufferBits -= 8;
    }
  }

  // (prefix code << 8 | next index) → code.
  var table = <int, int>{};
  var next = end + 1;
  emit(clear);
  if (indices.isEmpty) {
    emit(end);
  } else {
    var prefix = indices[0];
    for (var i = 1; i < indices.length; i++) {
      final k = indices[i];
      final key = (prefix << 8) | k;
      final found = table[key];
      if (found != null) {
        prefix = found;
        continue;
      }
      emit(prefix);
      if (next < 4096) {
        table[key] = next++;
        // The decoder grows its code size one code later than we add.
        if (next > (1 << size) && size < 12) size++;
      } else {
        emit(clear);
        table = <int, int>{};
        next = end + 1;
        size = minCode + 1;
      }
      prefix = k;
    }
    emit(prefix);
    // The decoder adds one more entry on reading that code.
    if (next >= (1 << size) && size < 12) size++;
    emit(end);
  }
  if (bufferBits > 0) out.addByte(buffer & 0xFF);
  return out.toBytes();
}
