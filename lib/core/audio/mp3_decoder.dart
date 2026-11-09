import 'dart:math' as math;
import 'dart:typed_data';

import 'mp3_tables.dart';
import 'peak_sink.dart';

/// Decodes an MPEG audio layer III file (MPEG-1, 2 and 2.5) to mono samples
/// for [sink]; false when no frame could be found.
///
/// Peaks only, so the stereo stage is replaced by a mix in the frequency
/// domain: mid/side frames use the mid channel alone (the side channel is
/// not even Huffman-decoded), left/right frames add both channels when they
/// use the same block type, else take the left one. Intensity stereo is not
/// rebuilt. Everything else (bit reservoir, scalefactors, requantization,
/// short-block reorder, alias reduction, IMDCT, polyphase synthesis) follows
/// ISO/IEC 11172-3 and 13818-3.
bool decodeMp3(Uint8List bytes, PeakSink sink) => _Mp3(bytes, sink).run();

const _bitratesV1 = [
  0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, //
];
const _bitratesV2 = [
  0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, //
];
const _rates = [44100, 48000, 32000];

/// MPEG-1 scalefactor bit lengths by `scalefac_compress`.
const _slen = [
  [0, 0], [0, 1], [0, 2], [0, 3], [3, 0], [1, 1], [1, 2], [1, 3], //
  [2, 1], [2, 2], [2, 3], [3, 1], [3, 2], [3, 3], [4, 2], [4, 3],
];
const _pretab = [
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 3, 3, 3, 2, 0, //
];

/// Alias reduction coefficients.
const _ci = [-0.6, -0.535, -0.33, -0.185, -0.095, -0.041, -0.0142, -0.0037];

class _Header {
  _Header(
    this.lsf,
    this.table,
    this.channels,
    this.ms,
    this.intensity,
    this.crc,
    this.length,
  );

  /// MPEG-2 or 2.5: one granule per frame, other side info.
  final bool lsf;

  /// Index into [mp3LongBands] / [mp3ShortBands].
  final int table;
  final int channels;

  /// Joint stereo with mid/side, intensity stereo on.
  final bool ms;
  final bool intensity;
  final bool crc;
  final int length;

  /// Parses the 4 bytes at [at]; null when they aren't a layer III header.
  static _Header? parse(Uint8List b, int at) {
    if (at + 4 > b.length || b[at] != 0xFF || (b[at + 1] & 0xE0) != 0xE0) {
      return null;
    }
    final version = (b[at + 1] >> 3) & 3; // 3 = 1, 2 = 2, 0 = 2.5
    final layer = (b[at + 1] >> 1) & 3;
    final bitIndex = b[at + 2] >> 4;
    final rateIndex = (b[at + 2] >> 2) & 3;
    if (version == 1 || layer != 1 || rateIndex == 3) return null;
    // Free format (0) isn't supported; 15 is invalid.
    if (bitIndex == 0 || bitIndex == 15) return null;
    final lsf = version != 3;
    final rate =
        _rates[rateIndex] >> (version == 3 ? 0 : (version == 2 ? 1 : 2));
    final kbps = (lsf ? _bitratesV2 : _bitratesV1)[bitIndex];
    final padding = (b[at + 2] >> 1) & 1;
    final length = (lsf ? 72000 : 144000) * kbps ~/ rate + padding;
    final mode = b[at + 3] >> 6;
    final table = (version == 3 ? 0 : (version == 2 ? 3 : 6)) + rateIndex;
    return _Header(
      lsf,
      table,
      mode == 3 ? 1 : 2,
      mode == 1 && (b[at + 3] & 0x20) != 0,
      mode == 1 && (b[at + 3] & 0x10) != 0,
      (b[at + 1] & 1) == 0,
      length,
    );
  }

  bool sameStream(_Header o) => o.lsf == lsf && o.table == table;
}

/// Side info of one granule of one channel.
class _Granule {
  var part23 = 0;
  var bigValues = 0;
  var globalGain = 0;
  var scalefacCompress = 0;
  var blockType = 0;
  var mixed = false;
  final tables = [0, 0, 0];
  final subblockGain = [0, 0, 0];
  var region1 = 0;
  var region2 = 0;
  var preflag = false;
  var scalefacScale = 0;
  var count1Table = 0;
}

/// MSB-first bit reader over a byte buffer.
class _Bits {
  _Bits(this.b, this.pos);

  final Uint8List b;

  /// In bits.
  int pos;

  int bit() {
    final i = pos >> 3;
    final v = i < b.length ? (b[i] >> (7 - (pos & 7))) & 1 : 0;
    pos++;
    return v;
  }

  /// The next 8 bits, without moving.
  int peek8() {
    final i = pos >> 3;
    final hi = i < b.length ? b[i] : 0;
    final lo = i + 1 < b.length ? b[i + 1] : 0;
    return ((hi << 8 | lo) >> (8 - (pos & 7))) & 0xFF;
  }

  int read(int n) {
    var v = 0;
    for (var k = 0; k < n; k++) {
      v = (v << 1) | bit();
    }
    return v;
  }
}

/// A Huffman code as a binary tree: node `n`'s children are at `2n` and
/// `2n + 1`; a leaf holds `-(value + 1)`.
Int32List _tree(List<int> codes, List<int> lengths) {
  var nodes = Int32List(64);
  var used = 1;
  for (var v = 0; v < codes.length; v++) {
    final len = lengths[v];
    if (len == 0) continue;
    var n = 0;
    for (var k = len - 1; k >= 0; k--) {
      final slot = 2 * n + ((codes[v] >> k) & 1);
      if (slot >= nodes.length) {
        nodes = Int32List(nodes.length * 2)..setAll(0, nodes);
      }
      if (k == 0) {
        nodes[slot] = -(v + 1);
      } else {
        if (nodes[slot] <= 0) {
          if (2 * used + 1 >= nodes.length) {
            nodes = Int32List(nodes.length * 2)..setAll(0, nodes);
          }
          nodes[slot] = used++;
        }
        n = nodes[slot];
      }
    }
  }
  return nodes;
}

/// A Huffman tree with an 8-bit lookup table in front: entry
/// `len << 16 | value` for codes of up to 8 bits, else `-(node + 1)` where
/// the walk goes on bit by bit after those 8 bits.
class _Huffman {
  _Huffman(this.tree) : lut = Int32List(256) {
    for (var p = 0; p < 256; p++) {
      var n = 0;
      var entry = 0;
      for (var k = 0; k < 8; k++) {
        final next = tree[2 * n + ((p >> (7 - k)) & 1)];
        if (next < 0) {
          entry = (k + 1) << 16 | (-next - 1);
          break;
        }
        if (next == 0) {
          // Not a code: corrupt data; take 8 bits and give 0.
          entry = 8 << 16;
          break;
        }
        n = next;
        if (k == 7) entry = -(n + 1);
      }
      lut[p] = entry;
    }
  }

  final Int32List tree;
  final Int32List lut;

  int decode(_Bits bits) {
    final e = lut[bits.peek8()];
    if (e >= 0) {
      bits.pos += e >> 16;
      return e & 0xFFFF;
    }
    bits.pos += 8;
    return _decode(tree, bits, -e - 1);
  }
}

int _decode(Int32List tree, _Bits bits, [int start = 0]) {
  var n = start;
  for (var guard = 0; guard < 24; guard++) {
    final next = tree[2 * n + bits.bit()];
    if (next < 0) return -next - 1;
    if (next == 0) return 0; // Not a code: corrupt data.
    n = next;
  }
  return 0;
}

final _trees = [
  for (var t = 0; t < mp3HuffSide.length; t++)
    mp3HuffSide[t] == 0
        ? null
        : _Huffman(_tree(mp3HuffCodes[t], mp3HuffLengths[t])),
];
final _count1Tree = _Huffman(_tree(mp3Count1Codes, mp3Count1Lengths));

/// |x|^(4/3) for every value Huffman decoding can give.
final _pow43 = Float64List.fromList([
  for (var i = 0; i < 8207; i++) math.pow(i, 4 / 3).toDouble(),
]);

/// 2^(x / 4) for x in -400..399 (as `x + 400`), enough for every gain.
final _pow2q = Float64List.fromList([
  for (var i = 0; i < 800; i++) math.pow(2, (i - 400) / 4).toDouble(),
]);

final _cs = Float64List.fromList([
  for (final c in _ci) 1 / math.sqrt(1 + c * c),
]);
final _ca = Float64List.fromList([
  for (final c in _ci) c / math.sqrt(1 + c * c),
]);

/// DCT-IV matrices of 18 and 6 points: the IMDCTs of 36 and 12 samples
/// are these, unfolded ([_unfold]).
final _dct4of18 = _dct4(18);

/// [_dct4of18] with each row padded to 20, in lanes of four.
final _dct4of18x4 = Float32x4List.view(
  Float32List.fromList([
    for (var m = 0; m < 18; m++) ...[
      for (var k = 0; k < 18; k++) _dct4of18[m * 18 + k],
      0,
      0,
    ],
  ]).buffer,
);
final _dct4of6 = _dct4(6);

Float64List _dct4(int n) => Float64List.fromList([
  for (var m = 0; m < n; m++)
    for (var k = 0; k < n; k++) math.cos(math.pi / n * (m + 0.5) * (k + 0.5)),
]);

/// The 36-sample windows of block types 0, 1 and 3 (2 uses [_shortWindow]).
final _windows = [
  for (var type = 0; type < 4; type++)
    Float64List.fromList([
      for (var i = 0; i < 36; i++)
        switch (type) {
          1 when i >= 30 => 0.0,
          1 when i >= 24 => math.sin(math.pi / 12 * (i - 18 + 0.5)),
          1 when i >= 18 => 1.0,
          3 when i < 6 => 0.0,
          3 when i < 12 => math.sin(math.pi / 12 * (i - 6 + 0.5)),
          3 when i < 18 => 1.0,
          _ => math.sin(math.pi / 36 * (i + 0.5)),
        },
    ]),
];
final _shortWindow = Float64List.fromList([
  for (var i = 0; i < 12; i++) math.sin(math.pi / 12 * (i + 0.5)),
]);

/// The synthesis window D in ISO order.
final _synthWindow = Float64List.fromList([
  for (var i = 0; i < 512; i++)
    mp3WindowBase[i <= 256 ? i : 512 - i] / 65536 * ((i ~/ 64).isOdd ? -1 : 1),
]);

/// [_synthWindow] as lanes of four, for [_Mp3._synth].
final _synthTaps = Float32x4List.view(
  Float32List.fromList(_synthWindow).buffer,
);

class _Mp3 {
  _Mp3(this.bytes, this.sink);

  final Uint8List bytes;
  final PeakSink sink;

  /// Main data of the last frames (the bit reservoir).
  var _res = Uint8List(8192);
  var _resLength = 0;

  final _granules = [
    [_Granule(), _Granule()],
    [_Granule(), _Granule()],
  ];
  final _scfsi = [Int32List(4), Int32List(4)];

  /// Scalefactors per channel: 22 long bands, then 13 × 3 short ones.
  final _sfLong = [Int32List(22), Int32List(22)];
  final _sfShort = [Int32List(39), Int32List(39)];
  final _values = [Int32List(576), Int32List(576)];
  final _xr = [Float64List(576), Float64List(576)];
  final _reordered = Float64List(576);

  /// IMDCT overlap per subband and the synthesis filter's V buffer.
  final _overlap = Float64List(576);
  final _subbands = Float64List(576);

  /// Written twice (at `o` and `o + 1024`) so reads never wrap; in lanes
  /// of four (float precision is plenty for peaks).
  final _v = Float32List(2048);
  late final _v4 = Float32x4List.view(_v.buffer);
  var _vOffset = 0;

  /// The DCT of one time slot's 32 subband samples ([_synth]).
  final _xf = Float32List(32);
  late final _x4s = Float32x4List.view(_xf.buffer);
  final _block = Float64List(36);
  final _u = Float64List(18);

  /// One subband's 18 lines, padded to 20, for the SIMD IMDCT.
  final _x = Float32List(20);
  late final _x4 = Float32x4List.view(_x.buffer);

  /// Samples still to drop at the start: the encoder's delay, from a LAME
  /// tag, plus the 529 of the synthesis filter.
  var _skip = 0;

  /// Samples left to give out, from the Xing frame count minus the LAME
  /// delay and padding; null when unknown.
  int? _left;

  bool run() {
    var at = _start();
    _Header? first;
    final info = _Header.parse(bytes, at);
    if (info != null && _infoFrame(info, at)) {
      // Its main data (zeros) may still be in the next frame's reservoir;
      // its own output isn't audio.
      _skip += info.lsf ? 576 : 1152;
    }
    while (at + 4 <= bytes.length) {
      final h = _Header.parse(bytes, at);
      if (h == null || (first != null && !first.sameStream(h))) {
        at = _resync(at + 1, first);
        if (at < 0) break;
        continue;
      }
      first ??= h;
      final end = math.min(at + h.length, bytes.length);
      _frame(h, at, end);
      at = at + h.length;
    }
    return first != null;
  }

  /// Whether the frame at [at] is a Xing / Info frame, which holds no
  /// audio; reads the LAME encoder delay from it.
  bool _infoFrame(_Header h, int at) {
    final x =
        at +
        4 +
        (h.lsf ? (h.channels == 1 ? 9 : 17) : (h.channels == 1 ? 17 : 32));
    if (x + 8 > bytes.length) return false;
    final tag = String.fromCharCodes(bytes, x, x + 4);
    if (tag != 'Xing' && tag != 'Info') return false;
    // The LAME tag follows the 120-byte Xing block.
    final lame = x + 120;
    if (lame + 24 <= bytes.length &&
        String.fromCharCodes(bytes, lame, lame + 4) == 'LAME') {
      final delay = (bytes[lame + 21] << 4) | (bytes[lame + 22] >> 4);
      final padding = ((bytes[lame + 22] & 0xF) << 8) | bytes[lame + 23];
      _skip = delay + 529;
      if ((bytes[x + 7] & 1) != 0) {
        final frames = ByteData.sublistView(bytes).getUint32(x + 8);
        _left = frames * (h.lsf ? 576 : 1152) - delay - padding;
      }
    }
    return true;
  }

  /// After an ID3v2 tag, at the first header that is followed by another.
  int _start() {
    var at = 0;
    if (bytes.length >= 10 &&
        bytes[0] == 0x49 &&
        bytes[1] == 0x44 &&
        bytes[2] == 0x33) {
      final size =
          (bytes[6] << 21) | (bytes[7] << 14) | (bytes[8] << 7) | bytes[9];
      at = 10 + size + ((bytes[5] & 0x10) != 0 ? 10 : 0);
    }
    final found = _resync(at, null);
    return found < 0 ? bytes.length : found;
  }

  /// The next header from [at] whose frame is followed by another header
  /// (or the end); -1 if none.
  int _resync(int at, _Header? like) {
    for (var i = at; i + 4 <= bytes.length; i++) {
      final h = _Header.parse(bytes, i);
      if (h == null || (like != null && !like.sameStream(h))) continue;
      final next = i + h.length;
      if (next + 4 > bytes.length) return i;
      final n = _Header.parse(bytes, next);
      if (n != null && n.sameStream(h)) return i;
    }
    return -1;
  }

  void _frame(_Header h, int at, int end) {
    final granules = h.lsf ? 1 : 2;
    final sideStart = at + 4 + (h.crc ? 2 : 0);
    final sideLength = h.lsf
        ? (h.channels == 1 ? 9 : 17)
        : (h.channels == 1 ? 17 : 32);
    final mainStart = sideStart + sideLength;
    if (mainStart > end) return;
    final side = _Bits(bytes, sideStart * 8);
    final mainBegin = _sideInfo(h, side);

    // Append this frame's main data to the reservoir.
    final mainLength = end - mainStart;
    if (_resLength + mainLength > _res.length) {
      final keep = math.min(_resLength, 512);
      final grown = Uint8List(math.max(_res.length, keep + mainLength + 512));
      grown.setRange(0, keep, _res, _resLength - keep);
      _res = grown;
      _resLength = keep;
    }
    final available = _resLength;
    _res.setRange(_resLength, _resLength + mainLength, bytes, mainStart);
    _resLength += mainLength;
    if (mainBegin > available) {
      // The reservoir starts before this stream: silence, like a decoder.
      for (var i = 0; i < 18 * granules; i++) {
        _emit(0);
      }
      return;
    }
    final bits = _Bits(_res, (available - mainBegin) * 8);
    for (var gr = 0; gr < granules; gr++) {
      _granule(h, gr, bits);
    }
  }

  /// Reads the side info into [_granules]; returns `main_data_begin`.
  int _sideInfo(_Header h, _Bits b) {
    final ch = h.channels;
    final int mainBegin;
    if (h.lsf) {
      mainBegin = b.read(8);
      b.read(ch == 1 ? 1 : 2);
    } else {
      mainBegin = b.read(9);
      b.read(ch == 1 ? 5 : 3);
      for (var c = 0; c < ch; c++) {
        for (var band = 0; band < 4; band++) {
          _scfsi[c][band] = b.bit();
        }
      }
    }
    final bands = mp3LongBands[h.table];
    final shortBands = mp3ShortBands[h.table];
    for (var gr = 0; gr < (h.lsf ? 1 : 2); gr++) {
      for (var c = 0; c < ch; c++) {
        final g = _granules[gr][c];
        g.part23 = b.read(12);
        g.bigValues = math.min(b.read(9), 288);
        g.globalGain = b.read(8);
        g.scalefacCompress = b.read(h.lsf ? 9 : 4);
        if (b.bit() == 1) {
          g.blockType = b.read(2);
          g.mixed = b.bit() == 1;
          g.tables[0] = b.read(5);
          g.tables[1] = b.read(5);
          g.tables[2] = 0;
          for (var w = 0; w < 3; w++) {
            g.subblockGain[w] = b.read(3);
          }
          g.region1 = g.blockType == 2 ? shortBands[3] * 3 : bands[8];
          g.region2 = 576;
        } else {
          g.blockType = 0;
          g.mixed = false;
          for (var t = 0; t < 3; t++) {
            g.tables[t] = b.read(5);
          }
          for (var w = 0; w < 3; w++) {
            g.subblockGain[w] = 0;
          }
          final r0 = b.read(4);
          final r1 = b.read(3);
          g.region1 = bands[math.min(r0 + 1, 22)];
          g.region2 = bands[math.min(r0 + r1 + 2, 22)];
        }
        // LSF: the preflag comes from scalefac_compress.
        g.preflag = h.lsf ? g.scalefacCompress >= 500 : b.bit() == 1;
        g.scalefacScale = b.bit();
        g.count1Table = b.bit();
      }
    }
    return mainBegin;
  }

  void _granule(_Header h, int gr, _Bits bits) {
    final g0 = _granules[gr][0];
    // Mid/side: the mid channel is the mix. Left/right: both, when they
    // share a block type.
    var mix = 1;
    if (h.channels == 2 && !h.ms) {
      final g1 = _granules[gr][1];
      if (g1.blockType == g0.blockType && g1.mixed == g0.mixed) mix = 2;
    }
    var pos = bits.pos;
    for (var c = 0; c < h.channels; c++) {
      final g = _granules[gr][c];
      if (c < mix) {
        bits.pos = pos;
        if (h.lsf) {
          _scalefactorsLsf(h, g, c, bits);
        } else {
          _scalefactors(g, gr, c, bits);
        }
        final lines = _huffman(h, g, bits, _values[c], pos + g.part23);
        _requantize(h, g, c, lines);
      }
      pos += g.part23;
    }
    bits.pos = pos;
    final xr = _xr[0];
    if (mix == 2) {
      final r = _xr[1];
      for (var i = 0; i < 576; i++) {
        xr[i] = (xr[i] + r[i]) * 0.5;
      }
    } else if (h.ms) {
      for (var i = 0; i < 576; i++) {
        xr[i] *= math.sqrt1_2;
      }
    }
    _hybrid(h, g0, xr);
  }

  void _scalefactors(_Granule g, int gr, int c, _Bits b) {
    final slen1 = _slen[g.scalefacCompress][0];
    final slen2 = _slen[g.scalefacCompress][1];
    final sl = _sfLong[c];
    final ss = _sfShort[c];
    if (g.blockType == 2) {
      var sfb = 0;
      if (g.mixed) {
        for (; sfb < 8; sfb++) {
          sl[sfb] = b.read(slen1);
        }
        sfb = 3;
      }
      for (; sfb < 12; sfb++) {
        final n = sfb < 6 ? slen1 : slen2;
        for (var w = 0; w < 3; w++) {
          ss[sfb * 3 + w] = b.read(n);
        }
      }
      for (var w = 0; w < 3; w++) {
        ss[36 + w] = 0;
      }
      return;
    }
    const groups = [0, 6, 11, 16, 21];
    for (var i = 0; i < 4; i++) {
      final n = i < 2 ? slen1 : slen2;
      if (gr == 1 && _scfsi[c][i] == 1) continue;
      for (var sfb = groups[i]; sfb < groups[i + 1]; sfb++) {
        sl[sfb] = b.read(n);
      }
    }
    sl[21] = 0;
  }

  void _scalefactorsLsf(_Header h, _Granule g, int c, _Bits b) {
    var sfc = g.scalefacCompress;
    final slen = [0, 0, 0, 0];
    final int table;
    // The right channel of an intensity frame codes its scalefactors
    // differently (they are intensity positions there).
    if (c == 1 && h.intensity) {
      sfc >>= 1;
      if (sfc < 180) {
        slen[0] = sfc ~/ 36;
        slen[1] = (sfc % 36) ~/ 6;
        slen[2] = (sfc % 36) % 6;
        table = 3;
      } else if (sfc < 244) {
        sfc -= 180;
        slen[0] = (sfc % 64) >> 4;
        slen[1] = (sfc % 16) >> 2;
        slen[2] = sfc % 4;
        table = 4;
      } else {
        sfc -= 244;
        slen[0] = sfc ~/ 3;
        slen[1] = sfc % 3;
        table = 5;
      }
    } else if (sfc < 400) {
      slen[0] = (sfc >> 4) ~/ 5;
      slen[1] = (sfc >> 4) % 5;
      slen[2] = (sfc & 15) >> 2;
      slen[3] = sfc & 3;
      table = 0;
    } else if (sfc < 500) {
      sfc -= 400;
      slen[0] = (sfc >> 2) ~/ 5;
      slen[1] = (sfc >> 2) % 5;
      slen[2] = sfc & 3;
      table = 1;
    } else {
      sfc -= 500;
      slen[0] = sfc ~/ 3;
      slen[1] = sfc % 3;
      table = 2;
    }
    final kind = g.blockType != 2 ? 0 : (g.mixed ? 2 : 1);
    final parts = mp3LsfPartitions[table][kind];
    final sl = _sfLong[c];
    final ss = _sfShort[c];
    sl.fillRange(0, 22, 0);
    ss.fillRange(0, 39, 0);
    var k = 0;
    for (var part = 0; part < 4; part++) {
      for (var i = 0; i < parts[part]; i++, k++) {
        final v = b.read(slen[part]);
        if (kind == 0) {
          if (k < 22) sl[k] = v;
        } else if (kind == 2 && k < 6) {
          sl[k] = v;
        } else {
          // Short: band by band, three windows each (mixed starts at 3).
          final s = kind == 2 ? k - 6 + 9 : k;
          if (s < 39) ss[s] = v;
        }
      }
    }
  }

  /// Decodes the lines of one part into [out]; returns how many lines it
  /// held (the rest are zero).
  int _huffman(_Header h, _Granule g, _Bits b, Int32List out, int end) {
    out.fillRange(0, 576, 0);
    final big = g.bigValues * 2;
    var i = 0;
    while (i < big) {
      final region = i < g.region1 ? 0 : (i < g.region2 ? 1 : 2);
      final table = g.tables[region];
      final stop = math.min(
        big,
        region == 0 ? g.region1 : (region == 1 ? g.region2 : 576),
      );
      final physical = table < 16 ? table : (table < 24 ? 16 : 17);
      final tree = _trees[physical];
      if (tree == null) {
        // Table 0: all zero.
        i = math.max(stop, i + 2);
        continue;
      }
      final side = mp3HuffSide[physical];
      final linbits = mp3Linbits[table];
      for (; i < stop; i += 2) {
        final v = tree.decode(b);
        var x = v ~/ side;
        var y = v % side;
        if (linbits > 0 && x == 15) x += b.read(linbits);
        if (x != 0 && b.bit() == 1) x = -x;
        if (linbits > 0 && y == 15) y += b.read(linbits);
        if (y != 0 && b.bit() == 1) y = -y;
        out[i] = x;
        out[i + 1] = y;
      }
    }
    // Count1: quadruples until the part ends.
    while (i + 4 <= 576 && b.pos < end) {
      final v = g.count1Table == 1 ? 15 - b.read(4) : _count1Tree.decode(b);
      for (var k = 0; k < 4; k++) {
        var q = (v >> (3 - k)) & 1;
        if (q != 0 && b.bit() == 1) q = -1;
        out[i + k] = q;
      }
      if (b.pos > end) {
        // Overran into the next part: that quadruple wasn't real.
        out.fillRange(i, i + 4, 0);
        break;
      }
      i += 4;
    }
    return i;
  }

  void _requantize(_Header h, _Granule g, int c, int lines) {
    final values = _values[c];
    final xr = _xr[c];
    final long = mp3LongBands[h.table];
    final short = mp3ShortBands[h.table];
    // A scalefactor step is 2^-0.5 (or 2^-1 with scalefac_scale).
    final shift = g.scalefacScale == 1 ? 4 : 2;
    final gain = g.globalGain - 210;
    final sl = _sfLong[c];
    final ss = _sfShort[c];
    // Exponents are kept as four times the power of two ([_pow2q]).
    var i = 0;
    if (g.blockType != 2 || g.mixed) {
      // Long bands (all of them, or below 36 in mixed blocks).
      final limit = g.blockType == 2 ? 36 : 576;
      for (var sfb = 0; sfb < 22 && i < limit && i < lines; sfb++) {
        final pre = g.preflag ? _pretab[sfb] : 0;
        final f = _pow2q[(gain - shift * (sl[sfb] + pre) + 400).clamp(0, 799)];
        final end = math.min(math.min(long[sfb + 1], limit), lines);
        for (; i < end; i++) {
          final v = values[i];
          xr[i] = v == 0 ? 0 : (v < 0 ? -_pow43[-v] * f : _pow43[v] * f);
        }
      }
    }
    if (g.blockType == 2) {
      for (var sfb = g.mixed ? 3 : 0; sfb < 13 && i < lines; sfb++) {
        final width = short[sfb + 1] - short[sfb];
        for (var w = 0; w < 3; w++) {
          final e4 = gain - 8 * g.subblockGain[w] - shift * ss[sfb * 3 + w];
          final f = _pow2q[(e4 + 400).clamp(0, 799)];
          for (var k = 0; k < width && i < 576; k++, i++) {
            final v = values[i];
            xr[i] = v == 0 ? 0 : (v < 0 ? -_pow43[-v] * f : _pow43[v] * f);
          }
        }
      }
    }
    xr.fillRange(i, 576, 0);
  }

  /// Reorder, alias reduction, IMDCT and synthesis of one mono granule.
  void _hybrid(_Header h, _Granule g, Float64List xr) {
    final short = g.blockType == 2;
    final shortFrom = !short ? 18 * 32 : (g.mixed ? 36 : 0);
    if (short) {
      // [band][window][line] → per subband, the 6 lines of each window
      // in a row ([_imdctShort] reads them that way).
      final bands = mp3ShortBands[h.table];
      for (var sfb = g.mixed ? 3 : 0; sfb < 13; sfb++) {
        final start = bands[sfb];
        final width = bands[sfb + 1] - start;
        for (var w = 0; w < 3; w++) {
          for (var k = 0; k < width; k++) {
            final line = start + k; // In the window's 192 lines.
            final sb = line ~/ 6;
            _reordered[sb * 18 + w * 6 + line % 6] =
                xr[3 * start + w * width + k];
          }
        }
      }
      xr.setRange(shortFrom, 576, _reordered, shortFrom);
    }
    // Alias reduction between long subbands.
    final aliasBands = !short ? 32 : (g.mixed ? 2 : 0);
    for (var sb = 1; sb < aliasBands; sb++) {
      for (var k = 0; k < 8; k++) {
        final lo = sb * 18 - 1 - k;
        final hi = sb * 18 + k;
        final a = xr[lo];
        final b = xr[hi];
        xr[lo] = a * _cs[k] - b * _ca[k];
        xr[hi] = b * _cs[k] + a * _ca[k];
      }
    }
    for (var sb = 0; sb < 32; sb++) {
      final base = sb * 18;
      final o = _block;
      if (base >= shortFrom) {
        _imdctShort(xr, base, o);
      } else {
        _imdctLong(xr, base, g.blockType == 2 ? 0 : g.blockType, o);
      }
      for (var i = 0; i < 18; i++) {
        var s = o[i] + _overlap[base + i];
        _overlap[base + i] = o[i + 18];
        // Frequency inversion.
        if (sb.isOdd && i.isOdd) s = -s;
        _subbands[i * 32 + sb] = s;
      }
    }
    for (var t = 0; t < 18; t++) {
      _synth(t * 32);
    }
  }

  void _imdctLong(Float64List x, int base, int type, Float64List out) {
    var zero = true;
    for (var k = 0; k < 18; k++) {
      if (x[base + k] != 0) {
        zero = false;
        break;
      }
    }
    if (zero) {
      out.fillRange(0, 36, 0);
      return;
    }
    final u = _u;
    final xs = _x4;
    for (var k = 0; k < 18; k++) {
      _x[k] = x[base + k];
    }
    final x0 = xs[0], x1 = xs[1], x2 = xs[2], x3 = xs[3], x4 = xs[4];
    final mat = _dct4of18x4;
    for (var m = 0; m < 18; m++) {
      final r = m * 5;
      final s =
          mat[r] * x0 +
          mat[r + 1] * x1 +
          mat[r + 2] * x2 +
          mat[r + 3] * x3 +
          mat[r + 4] * x4;
      u[m] = s.x + s.y + s.z + s.w;
    }
    _unfold(u, 18, out, 0, _windows[type]);
  }

  void _imdctShort(Float64List x, int base, Float64List out) {
    out.fillRange(0, 36, 0);
    final u = _u;
    final y = _short;
    for (var w = 0; w < 3; w++) {
      final from = base + w * 6;
      for (var m = 0; m < 6; m++) {
        var sum = 0.0;
        for (var k = 0; k < 6; k++) {
          sum += x[from + k] * _dct4of6[m * 6 + k];
        }
        u[m] = sum;
      }
      _unfold(u, 6, y, 0, _shortWindow);
      for (var i = 0; i < 12; i++) {
        out[6 + w * 6 + i] += y[i];
      }
    }
  }

  final _short = Float64List(12);

  /// The last time slot's samples (for a slot cut by [_skip] / [_left]).
  final _slot = Float32List(32);
  late final _slot4 = Float32x4List.view(_slot.buffer);

  /// One time slot (32 samples, in [_slot] unless [peak] is 0) whose
  /// loudest |sample| is [peak].
  void _emit(double peak) {
    var from = 0;
    var to = 32;
    if (_skip > 0) {
      if (_skip >= 32) {
        _skip -= 32;
        return;
      }
      from = _skip;
      _skip = 0;
    }
    final left = _left;
    if (left != null) {
      if (left <= 0) return;
      to = math.min(32, from + left);
      _left = left - (to - from);
    }
    if (from == 0 && to == 32) return sink.addPeak(peak, 32);
    for (var i = from; i < to; i++) {
      sink.add(peak == 0 ? 0 : _slot[i]);
    }
  }

  /// 32 subband samples at [from] in [_subbands] → 32 PCM samples.
  void _synth(int from) {
    _vOffset = (_vOffset - 64) & 1023;
    final v = _v;
    final o = _vOffset;
    // X[m] = Σ_k s[k] cos(π(2k + 1)m / 64), four m at a time; silent
    // subbands (most of the top ones) are skipped.
    final xs = _x4s;
    var a0 = Float32x4.zero(), a1 = a0, a2 = a0, a3 = a0;
    var a4 = a0, a5 = a0, a6 = a0, a7 = a0;
    var silent = true;
    final c = _dctRows;
    for (var k = 0; k < 32; k++) {
      final s = _subbands[from + k];
      if (s == 0) continue;
      silent = false;
      final sk = Float32x4.splat(s);
      final r = k * 8;
      a0 += c[r] * sk;
      a1 += c[r + 1] * sk;
      a2 += c[r + 2] * sk;
      a3 += c[r + 3] * sk;
      a4 += c[r + 4] * sk;
      a5 += c[r + 5] * sk;
      a6 += c[r + 6] * sk;
      a7 += c[r + 7] * sk;
    }
    if (silent) {
      v.fillRange(o, o + 64, 0);
      v.fillRange(o + 1024, o + 1088, 0);
    } else {
      xs[0] = a0;
      xs[1] = a1;
      xs[2] = a2;
      xs[3] = a3;
      xs[4] = a4;
      xs[5] = a5;
      xs[6] = a6;
      xs[7] = a7;
      final x = _xf;
      for (var i = 0; i < 16; i++) {
        v[o + i] = x[16 + i];
      }
      v[o + 16] = 0;
      for (var i = 17; i < 48; i++) {
        v[o + i] = -x[48 - i];
      }
      for (var i = 48; i < 64; i++) {
        v[o + i] = -x[i - 48];
      }
      v.setRange(o + 1024, o + 1088, v, o);
    }
    // out[j] = Σ_i V[o + 128i + j]·D[64i + j] + V[o + 128i + 96 + j]·D[64i
    // + 32 + j], four outputs at a time.
    // Only the loudest of the 32 is kept.
    final d = _synthTaps;
    final v4 = _v4;
    final o4 = o >> 2;
    var peak = Float32x4.zero();
    for (var j4 = 0; j4 < 8; j4++) {
      var sum = Float32x4.zero();
      for (var i = 0; i < 8; i++) {
        sum += v4[o4 + i * 32 + j4] * d[i * 16 + j4];
        sum += v4[o4 + i * 32 + 24 + j4] * d[i * 16 + 8 + j4];
      }
      _slot4[j4] = sum;
      peak = peak.max(sum.abs());
    }
    _emit(math.max(math.max(peak.x, peak.y), math.max(peak.z, peak.w)));
  }
}

/// Rows of the 32-point DCT-II, `cos(π(2k + 1)m / 64)` at `k * 32 + m`, in
/// lanes of four m.
final _dctRows = Float32x4List.view(
  Float32List.fromList([
    for (var k = 0; k < 32; k++)
      for (var m = 0; m < 32; m++) math.cos(math.pi * (2 * k + 1) * m / 64),
  ]).buffer,
);

/// The 2n windowed IMDCT samples from the DCT-IV [u] of n points:
/// `y[k] = u[k + n/2]`, then `-u[3n/2 - 1 - k]`, then `-u[k - 3n/2]`.
void _unfold(Float64List u, int n, Float64List out, int at, Float64List win) {
  final h = n ~/ 2;
  for (var k = 0; k < h; k++) {
    out[at + k] = u[k + h] * win[k];
  }
  for (var k = h; k < 3 * h; k++) {
    out[at + k] = -u[3 * h - 1 - k] * win[k];
  }
  for (var k = 3 * h; k < 2 * n; k++) {
    out[at + k] = -u[k - 3 * h] * win[k];
  }
}
