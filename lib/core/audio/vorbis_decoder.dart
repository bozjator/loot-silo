import 'dart:math' as math;
import 'dart:typed_data';

import 'peak_sink.dart';

/// Decodes the first Ogg Vorbis stream of an Ogg file to mono samples for
/// [sink], following the Vorbis I specification; false when the file isn't
/// Vorbis or uses floor type 0 (unused by encoders since 2002).
///
/// Peaks only: all channels share each block's size and window, so their
/// spectra are added before one IMDCT, which halves that cost and gives the
/// same mix as averaging the decoded channels.
bool decodeVorbis(Uint8List bytes, PeakSink sink) {
  final packets = _OggPackets(bytes);
  try {
    return _Vorbis(packets, sink).run();
  } on _VorbisError {
    return false;
  }
}

class _VorbisError implements Exception {
  const _VorbisError(this.message);

  final String message;

  @override
  String toString() => 'Vorbis: $message';
}

/// The packets of the first logical stream, in order.
class _OggPackets {
  _OggPackets(this.bytes);

  final Uint8List bytes;
  var _at = 0;
  int? _serial;

  /// The granule position of the stream's last page (its sample count).
  int lastGranule = -1;

  /// Segments of the page being read, and where its body is.
  var _lacing = Uint8List(0);
  var _segment = 0;
  var _body = 0;
  final _pending = BytesBuilder(copy: false);

  /// The next packet, or null at the end. A packet within one page is a
  /// view of [bytes]; only packets across pages are copied.
  Uint8List? next() {
    var start = _body;
    while (true) {
      while (_segment < _lacing.length) {
        final size = _lacing[_segment++];
        final end = math.min(_body + size, bytes.length);
        _body = end;
        if (size < 255) {
          if (_pending.isEmpty) return Uint8List.sublistView(bytes, start, end);
          _pending.add(Uint8List.sublistView(bytes, start, end));
          return _pending.takeBytes();
        }
      }
      if (_body > start) {
        _pending.add(Uint8List.sublistView(bytes, start, _body));
      }
      if (!_page()) {
        // A packet cut by the end of the file still counts.
        return _pending.isEmpty ? null : _pending.takeBytes();
      }
      start = _body;
    }
  }

  bool _page() {
    while (_at + 27 <= bytes.length) {
      if (bytes[_at] != 0x4F ||
          bytes[_at + 1] != 0x67 ||
          bytes[_at + 2] != 0x67 ||
          bytes[_at + 3] != 0x53) {
        _at++;
        continue;
      }
      final d = ByteData.sublistView(bytes);
      final serial = d.getUint32(_at + 14, Endian.little);
      final segments = bytes[_at + 26];
      final lacingAt = _at + 27;
      if (lacingAt + segments > bytes.length) return false;
      final lacing = Uint8List.sublistView(
        bytes,
        lacingAt,
        lacingAt + segments,
      );
      var size = 0;
      for (final s in lacing) {
        size += s;
      }
      final body = lacingAt + segments;
      _at = body + size;
      _serial ??= serial;
      if (serial != _serial) continue;
      final granule = d.getInt64(lacingAt - 21, Endian.little);
      if (granule >= 0) lastGranule = granule;
      _lacing = lacing;
      _segment = 0;
      _body = body;
      return true;
    }
    return false;
  }
}

/// LSB-first bit reader over one packet; reads past the end give zeros
/// and set [ended].
class _Bits {
  /// The packet is copied with 4 zero bytes after it, so [peek] needs no
  /// bounds tests.
  _Bits(Uint8List packet)
    : b = Uint8List(packet.length + 4)..setRange(0, packet.length, packet),
      end = packet.length * 8;

  final Uint8List b;
  final int end;
  var pos = 0;
  var ended = false;

  int read(int n) {
    if (n == 0) return 0;
    if (n > 24) return read(16) | read(n - 16) << 16;
    if (pos + n > end) {
      ended = true;
      if (pos >= end) {
        pos += n;
        return 0;
      }
    }
    final v = peek(n);
    pos += n;
    return v;
  }

  /// The next [n] (≤ 24) bits without moving; zeros past the end.
  int peek(int n) {
    final i = pos >> 3;
    if (i + 4 > b.length) return 0;
    final w = b[i] | b[i + 1] << 8 | b[i + 2] << 16 | b[i + 3] << 24;
    return (w >> (pos & 7)) & ((1 << n) - 1);
  }

  bool flag() => read(1) == 1;
}

int _ilog(int x) {
  var n = 0;
  while (x > 0) {
    n++;
    x >>= 1;
  }
  return n;
}

double _float32(int x) {
  final mantissa = x & 0x1FFFFF;
  final exponent = (x & 0x7FE00000) >> 21;
  final v = mantissa * math.pow(2, exponent - 788).toDouble();
  return (x & 0x80000000) != 0 ? -v : v;
}

/// Bits looked up at once when decoding a codeword.
const _fastBits = 10;

class _Codebook {
  _Codebook(this.dimensions, this.entries, this.lengths);

  final int dimensions;
  final int entries;
  final Uint8List lengths;

  /// `entry << 5 | length` by the next [_fastBits] bits; -1 when the code
  /// is longer (then [_tree] decides).
  late final Int32List _fast;

  /// Codewords longer than [_fastBits], as a binary tree over the bits in
  /// stream order: children at `2n`, `2n + 1`, leaves `-(entry + 1)`.
  var _tree = Int32List(2);
  var _treeUsed = 1;

  /// The VQ vector of every entry (`entries * dimensions`), when the book
  /// has a lookup table.
  Float32List? vectors;

  /// Builds the codewords the way the spec assigns them.
  void build() {
    _fast = Int32List(1 << _fastBits)..fillRange(0, 1 << _fastBits, -1);
    final available = Uint32List(33);
    var first = true;
    for (var e = 0; e < entries; e++) {
      final len = lengths[e];
      if (len == 0) continue;
      int code;
      if (first) {
        first = false;
        code = 0;
        for (var i = 1; i <= len; i++) {
          available[i] = 1 << (32 - i);
        }
      } else {
        var z = len;
        while (z > 0 && available[z] == 0) {
          z--;
        }
        if (z == 0) throw const _VorbisError('overspecified codebook');
        code = available[z];
        available[z] = 0;
        for (var y = len; y > z; y--) {
          available[y] = code + (1 << (32 - y));
        }
      }
      _add(e, code >> (32 - len), len);
    }
  }

  /// [code]: the codeword's [len] bits, first-read bit highest.
  void _add(int entry, int code, int len) {
    if (len <= _fastBits) {
      // Stream order is the reverse of the code's bit order.
      var reversed = 0;
      for (var i = 0; i < len; i++) {
        reversed |= ((code >> (len - 1 - i)) & 1) << i;
      }
      for (var fill = 0; fill < 1 << (_fastBits - len); fill++) {
        _fast[reversed | (fill << len)] = entry << 5 | len;
      }
      return;
    }
    var n = 0;
    for (var i = len - 1; i >= 0; i--) {
      final slot = 2 * n + ((code >> i) & 1);
      if (i == 0) {
        _tree[slot] = -(entry + 1);
      } else {
        if (_tree[slot] <= 0) {
          if (2 * _treeUsed + 2 > _tree.length) {
            _tree = Int32List(_tree.length * 2 + 2)..setAll(0, _tree);
          }
          _tree[slot] = _treeUsed++;
        }
        n = _tree[slot];
      }
    }
  }

  /// The next entry, or -1 for a bad code or the end of the packet.
  int decode(_Bits b) {
    final f = _fast[b.peek(_fastBits)];
    if (f >= 0) {
      final len = f & 31;
      if (b.pos + len > b.end) {
        b.ended = true;
        return -1;
      }
      b.pos += len;
      return f >> 5;
    }
    var n = 0;
    for (var guard = 0; guard < 33; guard++) {
      final next = _tree[2 * n + b.read(1)];
      if (b.ended) return -1;
      if (next < 0) return -next - 1;
      if (next == 0) return -1;
      n = next;
    }
    return -1;
  }
}

class _Floor {
  _Floor({
    required this.partitionClasses,
    required this.classDimensions,
    required this.classSubclasses,
    required this.classMasterbooks,
    required this.subclassBooks,
    required this.multiplier,
    required this.xs,
  }) {
    final n = xs.length;
    order = List.generate(n, (i) => i)..sort((a, b) => xs[a] - xs[b]);
    low = Int32List(n);
    high = Int32List(n);
    for (var i = 2; i < n; i++) {
      var lo = 0;
      var hi = 1;
      var loX = -1;
      var hiX = 1 << 30;
      for (var j = 0; j < i; j++) {
        if (xs[j] < xs[i] && xs[j] > loX) {
          loX = xs[j];
          lo = j;
        }
        if (xs[j] > xs[i] && xs[j] < hiX) {
          hiX = xs[j];
          hi = j;
        }
      }
      low[i] = lo;
      high[i] = hi;
    }
  }

  final List<int> partitionClasses;
  final List<int> classDimensions;
  final List<int> classSubclasses;
  final List<int> classMasterbooks;
  final List<List<int>> subclassBooks;
  final int multiplier;
  final List<int> xs;
  late final List<int> order;
  late final Int32List low;
  late final Int32List high;
}

class _Residue {
  _Residue(
    this.type,
    this.begin,
    this.end,
    this.partitionSize,
    this.classifications,
    this.classbook,
    this.books,
  );

  final int type;
  final int begin;
  final int end;
  final int partitionSize;
  final int classifications;
  final int classbook;

  /// `books[class][pass]`, -1 when unused.
  final List<List<int>> books;
}

class _Mapping {
  _Mapping(
    this.magnitudes,
    this.angles,
    this.mux,
    this.submapFloor,
    this.submapResidue,
  );

  final List<int> magnitudes;
  final List<int> angles;
  final List<int> mux;
  final List<int> submapFloor;
  final List<int> submapResidue;
}

class _Mode {
  _Mode(this.long, this.mapping);

  final bool long;
  final int mapping;
}

/// floor1_inverse_dB_table: 256 steps from about -140 dB to 0 dB.
final _inverseDb = Float32List.fromList([
  for (var i = 0; i < 256; i++)
    math.min(1.0, 1.0649863e-07 * math.pow(1.0649863, i).toDouble()),
]);

class _Vorbis {
  _Vorbis(this.packets, this.sink);

  final _OggPackets packets;
  final PeakSink sink;

  var _channels = 0;
  var _short = 0;
  var _long = 0;
  final _books = <_Codebook>[];
  final _floors = <_Floor?>[];
  final _residues = <_Residue>[];
  final _mappings = <_Mapping>[];
  final _modes = <_Mode>[];

  /// The previous block's IMDCT output (not windowed yet), its size and
  /// window; two buffers take turns.
  Float64List? _previous;
  var _previousSize = 0;
  late Float64List _previousWindow;
  late final _blocks = [Float64List(_long), Float64List(_long)];
  var _turn = 0;
  late final _out = Float64List(_long);
  var _given = 0;

  bool run() {
    final id = packets.next();
    if (id == null || !_header(id, 1)) return false;
    final d = ByteData.sublistView(id);
    if (id.length < 30) return false;
    _channels = id[11];
    final sizes = id[28];
    _short = 1 << (sizes & 15);
    _long = 1 << (sizes >> 4);
    if (_channels == 0 || _short < 64 || _long < _short || _long > 8192) {
      return false;
    }
    if (d.getUint32(12, Endian.little) == 0) return false;
    final comment = packets.next();
    if (comment == null || !_header(comment, 3)) return false;
    final setup = packets.next();
    if (setup == null || !_header(setup, 5)) return false;
    if (!_setup(setup)) return false;
    _spectrum = Float64List(_long ~/ 2);
    _channel = [for (var c = 0; c < _channels; c++) Float64List(_long ~/ 2)];
    _floor = [for (var c = 0; c < _channels; c++) Float32List(_long ~/ 2)];
    for (var p = packets.next(); p != null; p = packets.next()) {
      _audio(p);
    }
    return true;
  }

  bool _header(Uint8List p, int type) =>
      p.length >= 7 &&
      p[0] == type &&
      String.fromCharCodes(p, 1, 7) == 'vorbis';

  bool _setup(Uint8List packet) {
    final b = _Bits(packet)..pos = 7 * 8;
    final books = b.read(8) + 1;
    for (var i = 0; i < books; i++) {
      _books.add(_codebook(b));
    }
    final times = b.read(6) + 1;
    for (var i = 0; i < times; i++) {
      if (b.read(16) != 0) return false;
    }
    final floors = b.read(6) + 1;
    for (var i = 0; i < floors; i++) {
      final type = b.read(16);
      if (type == 0) return false;
      if (type != 1) return false;
      _floors.add(_floor1(b));
    }
    final residues = b.read(6) + 1;
    for (var i = 0; i < residues; i++) {
      final type = b.read(16);
      if (type > 2) return false;
      _residues.add(_residue(b, type));
    }
    final mappings = b.read(6) + 1;
    for (var i = 0; i < mappings; i++) {
      if (b.read(16) != 0) return false;
      _mappings.add(_mapping(b));
    }
    final modes = b.read(6) + 1;
    for (var i = 0; i < modes; i++) {
      final long = b.flag();
      b.read(16);
      b.read(16);
      final mapping = b.read(8);
      if (mapping >= _mappings.length) return false;
      _modes.add(_Mode(long, mapping));
    }
    return !b.ended;
  }

  _Codebook _codebook(_Bits b) {
    if (b.read(24) != 0x564342) throw const _VorbisError('codebook sync');
    final dimensions = b.read(16);
    final entries = b.read(24);
    final lengths = Uint8List(entries);
    if (b.flag()) {
      // Ordered: runs of entries per length.
      var entry = 0;
      var len = b.read(5) + 1;
      while (entry < entries) {
        final count = b.read(_ilog(entries - entry));
        if (entry + count > entries) {
          throw const _VorbisError('codebook lengths');
        }
        lengths.fillRange(entry, entry + count, len);
        entry += count;
        len++;
      }
    } else {
      final sparse = b.flag();
      for (var e = 0; e < entries; e++) {
        if (!sparse || b.flag()) lengths[e] = b.read(5) + 1;
      }
    }
    final book = _Codebook(dimensions, entries, lengths)..build();
    final lookup = b.read(4);
    if (lookup == 1 || lookup == 2) {
      final min = _float32(b.read(32));
      final delta = _float32(b.read(32));
      final valueBits = b.read(4) + 1;
      final sequence = b.flag();
      final values = lookup == 1
          ? _lookup1(entries, dimensions)
          : entries * dimensions;
      final mult = Int32List(values);
      for (var i = 0; i < values; i++) {
        mult[i] = b.read(valueBits);
      }
      if (b.ended) throw const _VorbisError('codebook lookup');
      final v = Float32List(entries * dimensions);
      for (var e = 0; e < entries; e++) {
        var last = 0.0;
        var divisor = 1;
        for (var i = 0; i < dimensions; i++) {
          final offset = lookup == 1
              ? (e ~/ divisor) % values
              : e * dimensions + i;
          final x = mult[offset] * delta + min + last;
          v[e * dimensions + i] = x;
          if (sequence) last = x;
          divisor *= values;
        }
      }
      book.vectors = v;
    } else if (lookup != 0) {
      throw const _VorbisError('lookup type');
    }
    return book;
  }

  /// The greatest r with r^dimensions ≤ entries.
  static int _lookup1(int entries, int dimensions) {
    var r = math.pow(entries, 1 / dimensions).floor();
    while (math.pow(r + 1, dimensions) <= entries) {
      r++;
    }
    while (r > 0 && math.pow(r, dimensions) > entries) {
      r--;
    }
    return r;
  }

  _Floor _floor1(_Bits b) {
    final partitions = b.read(5);
    final classes = [for (var p = 0; p < partitions; p++) b.read(4)];
    final count = classes.isEmpty ? 0 : classes.reduce(math.max) + 1;
    final dims = <int>[];
    final subs = <int>[];
    final masters = <int>[];
    final subBooks = <List<int>>[];
    for (var c = 0; c < count; c++) {
      dims.add(b.read(3) + 1);
      final s = b.read(2);
      subs.add(s);
      masters.add(s > 0 ? b.read(8) : -1);
      subBooks.add([for (var j = 0; j < 1 << s; j++) b.read(8) - 1]);
    }
    final multiplier = b.read(2) + 1;
    final rangeBits = b.read(4);
    final xs = [0, 1 << rangeBits];
    for (final c in classes) {
      for (var j = 0; j < dims[c]; j++) {
        xs.add(b.read(rangeBits));
      }
    }
    for (final m in masters) {
      if (m >= _books.length) throw const _VorbisError('floor book');
    }
    return _Floor(
      partitionClasses: classes,
      classDimensions: dims,
      classSubclasses: subs,
      classMasterbooks: masters,
      subclassBooks: subBooks,
      multiplier: multiplier,
      xs: xs,
    );
  }

  _Residue _residue(_Bits b, int type) {
    final begin = b.read(24);
    final end = b.read(24);
    final size = b.read(24) + 1;
    final classifications = b.read(6) + 1;
    final classbook = b.read(8);
    final cascade = <int>[];
    for (var i = 0; i < classifications; i++) {
      final low = b.read(3);
      final high = b.flag() ? b.read(5) : 0;
      cascade.add(high * 8 + low);
    }
    final books = [
      for (var i = 0; i < classifications; i++)
        [
          for (var pass = 0; pass < 8; pass++)
            (cascade[i] >> pass) & 1 == 1 ? b.read(8) : -1,
        ],
    ];
    if (classbook >= _books.length) throw const _VorbisError('residue book');
    return _Residue(type, begin, end, size, classifications, classbook, books);
  }

  _Mapping _mapping(_Bits b) {
    final submaps = b.flag() ? b.read(4) + 1 : 1;
    final magnitudes = <int>[];
    final angles = <int>[];
    if (b.flag()) {
      final steps = b.read(8) + 1;
      final bits = _ilog(_channels - 1);
      for (var i = 0; i < steps; i++) {
        magnitudes.add(b.read(bits));
        angles.add(b.read(bits));
      }
    }
    if (b.read(2) != 0) throw const _VorbisError('mapping reserved');
    final mux = [
      for (var c = 0; c < _channels; c++) submaps > 1 ? b.read(4) : 0,
    ];
    final floors = <int>[];
    final residues = <int>[];
    for (var s = 0; s < submaps; s++) {
      b.read(8);
      floors.add(b.read(8));
      residues.add(b.read(8));
    }
    return _Mapping(magnitudes, angles, mux, floors, residues);
  }

  late Float64List _spectrum;

  /// Floor buffers kept from packet to packet.
  final _ys = Int32List(1024);
  final _finalY = Int32List(1024);
  final _step2 = Uint8List(1024);
  late List<Float64List> _channel;

  /// Each channel's floor curve as gains.
  late List<Float32List> _floor;

  void _audio(Uint8List packet) {
    final b = _Bits(packet);
    if (b.read(1) != 0) return;
    final modeIndex = b.read(_ilog(_modes.length - 1));
    if (modeIndex >= _modes.length) return;
    final mode = _modes[modeIndex];
    final n = mode.long ? _long : _short;
    var prevLong = false;
    var nextLong = false;
    if (mode.long) {
      prevLong = b.flag();
      nextLong = b.flag();
    }
    final half = n ~/ 2;
    final map = _mappings[mode.mapping];
    // Residues write nothing past their end: later loops stop there.
    var top = 0;
    for (var s = 0; s < map.submapResidue.length; s++) {
      final r = _residues[map.submapResidue[s]];
      final shared = r.type == 2 ? map.mux.where((m) => m == s).length : 1;
      top = math.max(top, (r.end + shared - 1) ~/ math.max(shared, 1));
    }
    top = math.min(top, half);
    final used = List<bool>.filled(_channels, false);
    for (var c = 0; c < _channels; c++) {
      final floor = _floors[map.submapFloor[map.mux[c]]];
      if (floor != null) used[c] = _decodeFloor(floor, b, _floor[c], half);
      _channel[c].fillRange(0, top, 0);
    }
    // A coupled pair needs both residues when either has a floor.
    final decode = List<bool>.of(used);
    for (var i = 0; i < map.magnitudes.length; i++) {
      final m = map.magnitudes[i];
      final a = map.angles[i];
      if (m >= _channels || a >= _channels) return;
      if (decode[m] || decode[a]) {
        decode[m] = true;
        decode[a] = true;
      }
    }
    for (var s = 0; s < map.submapResidue.length; s++) {
      final chans = [
        for (var c = 0; c < _channels; c++)
          if (map.mux[c] == s) c,
      ];
      _decodeResidue(_residues[map.submapResidue[s]], b, chans, [
        for (final c in chans) !decode[c],
      ], half);
    }
    final spectrum = _spectrum;
    spectrum.fillRange(0, half, 0);
    // The usual stereo pair: undo the coupling, apply both floors and add
    // in one pass.
    if (_channels == 2 &&
        map.magnitudes.length == 1 &&
        used[0] &&
        used[1] &&
        map.magnitudes[0] != map.angles[0]) {
      final mag = _channel[map.magnitudes[0]];
      final ang = _channel[map.angles[0]];
      final fm = _floor[map.magnitudes[0]];
      final fa = _floor[map.angles[0]];
      for (var k = 0; k < top; k++) {
        final m = mag[k];
        final a = ang[k];
        // t: the angle with the magnitude's sign. a > 0 gives (m, m − t),
        // else (m + t, m); both have m on each side.
        final t = m > 0 ? a : -a;
        final f = fm[k];
        final g = fa[k];
        spectrum[k] = m * (f + g) + (a > 0 ? -t * g : t * f);
      }
      return _finish(spectrum, n, half, mode, prevLong, nextLong);
    }
    for (var i = map.magnitudes.length - 1; i >= 0; i--) {
      final mag = _channel[map.magnitudes[i]];
      final ang = _channel[map.angles[i]];
      for (var k = 0; k < top; k++) {
        final m = mag[k];
        final a = ang[k];
        if (m > 0) {
          if (a > 0) {
            ang[k] = m - a;
          } else {
            ang[k] = m;
            mag[k] = m + a;
          }
        } else {
          if (a > 0) {
            ang[k] = m + a;
          } else {
            ang[k] = m;
            mag[k] = m - a;
          }
        }
      }
    }
    // Floor × residue, all channels added into one spectrum.
    for (var c = 0; c < _channels; c++) {
      if (!used[c]) continue;
      final r = _channel[c];
      final f = _floor[c];
      for (var k = 0; k < top; k++) {
        spectrum[k] += r[k] * f[k];
      }
    }
    _finish(spectrum, n, half, mode, prevLong, nextLong);
  }

  void _finish(
    Float64List spectrum,
    int n,
    int half,
    _Mode mode,
    bool prevLong,
    bool nextLong,
  ) {
    final out = _blocks[_turn];
    _turn ^= 1;
    _imdct(spectrum, half, out);
    _overlap(out, n, _window(n, mode.long, prevLong, nextLong));
  }

  /// Decodes and renders floor 1 into [curve] (as gains); false for
  /// an unused channel.
  bool _decodeFloor(_Floor f, _Bits b, Float32List curve, int half) {
    if (!b.flag()) return false;
    const ranges = [256, 128, 86, 64];
    final range = ranges[f.multiplier - 1];
    final count = f.xs.length;
    if (count > _ys.length) return false;
    final ys = _ys;
    final bits = _ilog(range - 1);
    ys[0] = b.read(bits);
    ys[1] = b.read(bits);
    var offset = 2;
    for (final cls in f.partitionClasses) {
      final dim = f.classDimensions[cls];
      final cbits = f.classSubclasses[cls];
      final csub = (1 << cbits) - 1;
      var cval = 0;
      if (cbits > 0) {
        cval = _books[f.classMasterbooks[cls]].decode(b);
        if (cval < 0) return false;
      }
      for (var j = 0; j < dim; j++) {
        final book = f.subclassBooks[cls][cval & csub];
        cval >>= cbits;
        if (book >= 0) {
          final v = _books[book].decode(b);
          if (v < 0) return false;
          ys[offset + j] = v;
        } else {
          ys[offset + j] = 0;
        }
      }
      offset += dim;
    }
    if (b.ended) return false;

    // Amplitude values from the predictions.
    final finalY = _finalY;
    final step2 = _step2..fillRange(0, count, 0);
    finalY[0] = ys[0];
    finalY[1] = ys[1];
    step2[0] = 1;
    step2[1] = 1;
    for (var i = 2; i < count; i++) {
      final lo = f.low[i];
      final hi = f.high[i];
      final predicted = _renderPoint(
        f.xs[lo],
        finalY[lo],
        f.xs[hi],
        finalY[hi],
        f.xs[i],
      );
      final val = ys[i];
      final highroom = range - predicted;
      final lowroom = predicted;
      final room = highroom < lowroom ? highroom * 2 : lowroom * 2;
      if (val != 0) {
        step2[lo] = 1;
        step2[hi] = 1;
        step2[i] = 1;
        if (val >= room) {
          finalY[i] = highroom > lowroom
              ? val - lowroom + predicted
              : predicted - val + highroom - 1;
        } else {
          finalY[i] = val.isOdd
              ? predicted - ((val + 1) >> 1)
              : predicted + (val >> 1);
        }
      } else {
        finalY[i] = predicted;
      }
    }

    // Lines between the used points, in x order.
    var lx = 0;
    var ly = finalY[f.order[0]] * f.multiplier;
    var hy = ly;
    var hx = 0;
    for (var k = 1; k < count; k++) {
      final i = f.order[k];
      if (step2[i] == 0) continue;
      hy = finalY[i] * f.multiplier;
      hx = f.xs[i];
      _renderLine(lx, ly, hx, hy, curve, half);
      lx = hx;
      ly = hy;
    }
    if (hx < half) _renderLine(hx, hy, half, hy, curve, half);
    return true;
  }

  static int _renderPoint(int x0, int y0, int x1, int y1, int x) {
    final dy = y1 - y0;
    final adx = x1 - x0;
    final err = dy.abs() * (x - x0);
    final off = adx == 0 ? 0 : err ~/ adx;
    return dy < 0 ? y0 - off : y0 + off;
  }

  static void _renderLine(
    int x0,
    int y0,
    int x1,
    int y1,
    Float32List v,
    int n,
  ) {
    final dy = y1 - y0;
    final adx = x1 - x0;
    if (adx <= 0) return;
    final base = dy ~/ adx;
    final sy = dy < 0 ? base - 1 : base + 1;
    final ady = dy.abs() - base.abs() * adx;
    var y = y0;
    var err = 0;
    if (x0 < n) v[x0] = _inverseDb[y < 0 ? 0 : (y > 255 ? 255 : y)];
    for (var x = x0 + 1; x < x1 && x < n; x++) {
      err += ady;
      if (err >= adx) {
        err -= adx;
        y += sy;
      } else {
        y += base;
      }
      v[x] = _inverseDb[y < 0 ? 0 : (y > 255 ? 255 : y)];
    }
  }

  void _decodeResidue(
    _Residue r,
    _Bits b,
    List<int> chans,
    List<bool> skip,
    int half,
  ) {
    if (chans.isEmpty) return;
    if (r.type == 2) {
      if (skip.every((s) => s)) return;
      final ch = chans.length;
      final v = Float64List(half * ch);
      _residueVectors(r, b, [v], [false], half * ch);
      for (var j = 0; j < ch; j++) {
        final out = _channel[chans[j]];
        for (var k = 0; k < half; k++) {
          out[k] = v[k * ch + j];
        }
      }
      return;
    }
    _residueVectors(r, b, [for (final c in chans) _channel[c]], skip, half);
  }

  void _residueVectors(
    _Residue r,
    _Bits b,
    List<Float64List> vectors,
    List<bool> skip,
    int size,
  ) {
    final begin = math.min(r.begin, size);
    final end = math.min(r.end, size);
    final psize = r.partitionSize;
    final partitions = (end - begin) ~/ psize;
    if (partitions <= 0) return;
    final classbook = _books[r.classbook];
    final perWord = classbook.dimensions;
    final classes = [
      for (var j = 0; j < vectors.length; j++) Int32List(partitions + perWord),
    ];
    for (var pass = 0; pass < 8; pass++) {
      var p = 0;
      while (p < partitions) {
        if (pass == 0) {
          for (var j = 0; j < vectors.length; j++) {
            if (skip[j]) continue;
            var temp = classbook.decode(b);
            if (temp < 0) return;
            for (var i = perWord - 1; i >= 0; i--) {
              classes[j][i + p] = temp % r.classifications;
              temp ~/= r.classifications;
            }
          }
        }
        for (var i = 0; i < perWord && p < partitions; i++, p++) {
          for (var j = 0; j < vectors.length; j++) {
            if (skip[j]) continue;
            final book = r.books[classes[j][p]][pass];
            if (book < 0) continue;
            final cb = _books[book];
            final vq = cb.vectors;
            if (vq == null) return;
            final dim = cb.dimensions;
            final v = vectors[j];
            final offset = begin + p * psize;
            if (r.type == 0) {
              final step = psize ~/ dim;
              for (var k = 0; k < step; k++) {
                final e = cb.decode(b);
                if (e < 0) return;
                for (var d = 0; d < dim; d++) {
                  v[offset + k + d * step] += vq[e * dim + d];
                }
              }
            } else {
              var k = 0;
              while (k < psize) {
                final e = cb.decode(b);
                if (e < 0) return;
                final base = e * dim;
                for (var d = 0; d < dim && k < psize; d++, k++) {
                  v[offset + k] += vq[base + d];
                }
              }
            }
          }
        }
      }
    }
  }

  /// The block windowed by [win] and overlapped with the previous one;
  /// gives out the samples between the two blocks' centres. Only the parts
  /// that overlap are windowed.
  void _overlap(Float64List cur, int n, Float64List win) {
    final prev = _previous;
    if (prev != null) {
      final pn = _previousSize;
      final pw = _previousWindow;
      final count = pn ~/ 4 + n ~/ 4;
      final out = _out;
      final shift = n ~/ 4 - pn ~/ 4;
      // prev covers t < pn / 2, cur covers t ≥ -shift (both up to count).
      // No 1 / channels scale: the peaks are scaled to the loudest anyway.
      final prevEnd = math.min(count, pn ~/ 2);
      final curStart = math.max(0, -shift);
      final p0 = pn ~/ 2;
      for (var t = 0; t < prevEnd; t++) {
        out[t] = prev[p0 + t] * pw[p0 + t];
      }
      out.fillRange(prevEnd, count, 0);
      for (var t = curStart; t < count; t++) {
        out[t] += cur[t + shift] * win[t + shift];
      }
      var give = count;
      final total = packets.lastGranule;
      if (total > 0 && _given + give > total) {
        give = math.max(0, total - _given);
      }
      sink.addAll(out, give);
      _given += give;
    }
    _previous = cur;
    _previousSize = n;
    _previousWindow = win;
  }

  /// Windows by `long, prevLong, nextLong` as bits.
  final _windows = List<Float64List?>.filled(8, null);

  Float64List _window(int n, bool long, bool prevLong, bool nextLong) {
    final key = (long ? 4 : 0) | (prevLong ? 2 : 0) | (nextLong ? 1 : 0);
    return _windows[key] ??= () {
      final w = Float64List(n);
      final leftStart = long && !prevLong ? n ~/ 4 - _short ~/ 4 : 0;
      final leftEnd = long && !prevLong ? n ~/ 4 + _short ~/ 4 : n ~/ 2;
      final leftN = long && !prevLong ? _short ~/ 2 : n ~/ 2;
      final rightStart = long && !nextLong ? n * 3 ~/ 4 - _short ~/ 4 : n ~/ 2;
      final rightEnd = long && !nextLong ? n * 3 ~/ 4 + _short ~/ 4 : n;
      final rightN = long && !nextLong ? _short ~/ 2 : n ~/ 2;
      double slope(double x) {
        final s = math.sin(x);
        return math.sin(math.pi / 2 * s * s);
      }

      for (var i = leftStart; i < leftEnd; i++) {
        w[i] = slope((i - leftStart + 0.5) / leftN * math.pi / 2);
      }
      for (var i = leftEnd; i < rightStart; i++) {
        w[i] = 1;
      }
      for (var i = rightStart; i < rightEnd; i++) {
        w[i] = slope(
          (i - rightStart + 0.5) / rightN * math.pi / 2 + math.pi / 2,
        );
      }
      return w;
    }();
  }

  /// y[k] = Σ X[j] cos(π/m · (k + 1/2 + m/2)(j + 1/2)) for the 2m outputs,
  /// from a DCT-IV of m points done with an m/2-point FFT.
  void _imdct(Float64List x, int m, Float64List out) {
    final u = _dct4(x, m);
    final h = m ~/ 2;
    for (var k = 0; k < h; k++) {
      out[k] = u[k + h];
    }
    for (var k = h; k < 3 * h; k++) {
      out[k] = -u[3 * h - 1 - k];
    }
    for (var k = 3 * h; k < 2 * m; k++) {
      out[k] = -u[k - 3 * h];
    }
  }

  final _ffts = <int, _Fft>{};

  Float64List _dct4(Float64List x, int m) {
    final fft = _ffts.putIfAbsent(m, () => _Fft(m));
    return fft.dct4(x);
  }
}

/// DCT-IV of m points through an m/2-point complex FFT:
/// c[n] = (x[2n] + i·x[m−1−2n])·e^(−iπ(n + 1/4)/m), C = FFT(c),
/// d[k] = C[k]·e^(−iπk/m), u[2k] = Re d[k], u[m−1−2k] = −Im d[k].
class _Fft {
  _Fft(this.m)
    : h = m ~/ 2,
      re = Float64List(m ~/ 2),
      im = Float64List(m ~/ 2),
      u = Float64List(m) {
    preCos = Float64List(h);
    preSin = Float64List(h);
    postCos = Float64List(h);
    postSin = Float64List(h);
    for (var n = 0; n < h; n++) {
      final a = -math.pi * (n + 0.25) / m;
      preCos[n] = math.cos(a);
      preSin[n] = math.sin(a);
      final b = -math.pi * n / m;
      postCos[n] = math.cos(b);
      postSin[n] = math.sin(b);
    }
    var bits = 0;
    while (1 << bits < h) {
      bits++;
    }
    reverse = Int32List(h);
    for (var i = 0; i < h; i++) {
      var r = 0;
      for (var k = 0; k < bits; k++) {
        r |= ((i >> k) & 1) << (bits - 1 - k);
      }
      reverse[i] = r;
    }
    // Twiddles of each stage from size 4 up, one after another.
    final cos = <double>[];
    final sin = <double>[];
    final at = <int>[];
    for (var size = 4; size <= h; size *= 2) {
      at.add(cos.length);
      for (var k = 0; k < size ~/ 2; k++) {
        cos.add(math.cos(-2 * math.pi * k / size));
        sin.add(math.sin(-2 * math.pi * k / size));
      }
    }
    stageCos = Float64List.fromList(cos);
    stageSin = Float64List.fromList(sin);
    stageAt = at;
  }

  final int m;
  final int h;
  final Float64List re;
  final Float64List im;
  final Float64List u;
  late final Float64List preCos;
  late final Float64List preSin;
  late final Float64List postCos;
  late final Float64List postSin;
  late final Int32List reverse;
  late final Float64List stageCos;
  late final Float64List stageSin;
  late final List<int> stageAt;

  Float64List dct4(Float64List x) {
    for (var n = 0; n < h; n++) {
      final a = x[2 * n];
      final b = x[m - 1 - 2 * n];
      final r = reverse[n];
      re[r] = a * preCos[n] - b * preSin[n];
      im[r] = a * preSin[n] + b * preCos[n];
    }
    // Iterative radix-2 FFT, input already in bit-reversed order.
    for (var i = 0; i + 1 < h; i += 2) {
      final r = re[i + 1];
      final m = im[i + 1];
      re[i + 1] = re[i] - r;
      im[i + 1] = im[i] - m;
      re[i] += r;
      im[i] += m;
    }
    var stage = 0;
    for (var size = 4; size <= h; size *= 2) {
      final halfSize = size ~/ 2;
      final base = stageAt[stage++];
      for (var start = 0; start < h; start += size) {
        for (var k = 0; k < halfSize; k++) {
          final c = stageCos[base + k];
          final s = stageSin[base + k];
          final i = start + k;
          final j = i + halfSize;
          final tr = re[j] * c - im[j] * s;
          final ti = re[j] * s + im[j] * c;
          re[j] = re[i] - tr;
          im[j] = im[i] - ti;
          re[i] += tr;
          im[i] += ti;
        }
      }
    }
    for (var k = 0; k < h; k++) {
      final dr = re[k] * postCos[k] - im[k] * postSin[k];
      final di = re[k] * postSin[k] + im[k] * postCos[k];
      u[2 * k] = dr;
      u[m - 1 - 2 * k] = -di;
    }
    return u;
  }
}
