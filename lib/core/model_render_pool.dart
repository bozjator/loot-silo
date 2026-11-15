import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'model_raster.dart';

/// Draws models on worker isolates, so a big mesh or a big picture never
/// holds up the thread that asked. Each worker projects a share of the
/// vertices, then draws a band of rows, all at the same time.
///
/// One picture at a time: calls queue up behind each other.
class ModelRenderPool {
  ModelRenderPool({int? workers})
    : workerCount =
          workers ?? math.max(1, math.min(Platform.numberOfProcessors - 1, 6));

  final int workerCount;
  final _workers = <_Worker>[];
  Future<void>? _starting;
  final _context = RasterContext();
  RasterBuffer? _buffer;
  Future<void> _queue = Future.value();
  var _disposed = false;

  /// [mesh] as [view] sees it: premultiplied RGBA of `width × height × 4`
  /// bytes, or null when memory runs out or the pool is disposed.
  Future<Uint8List?> render(RasterMesh mesh, RasterView view) {
    final done = _queue.then((_) => _render(mesh, view));
    _queue = done.then((_) {}, onError: (_) {});
    return done;
  }

  Future<Uint8List?> _render(RasterMesh mesh, RasterView view) async {
    if (_disposed) return null;
    await (_starting ??= _start());
    if (_disposed) return null;
    final bytes = view.width * view.height * 4;
    if ((_buffer?.length ?? 0) < bytes) {
      _buffer?.free();
      _buffer = null;
      try {
        _buffer = RasterBuffer(bytes);
      } on OutOfMemoryError {
        return null;
      }
    }
    final buffer = _buffer!;
    if (!_context.begin(mesh, view)) return null;
    // Every worker projects its share of the vertices, then draws its
    // share of the rows.
    final context = _context.address;
    final parts = math.min(workerCount, view.height);
    await Future.wait([
      for (var i = 0; i < parts; i++)
        _workers[i].send([_transform, context, i, parts, 0]),
    ]);
    await Future.wait([
      for (var i = 0; i < parts; i++)
        _workers[i].send([_band, context, i, parts, buffer.address]),
    ]);
    // A copy: the next picture reuses the buffer.
    return Uint8List.fromList(Uint8List.sublistView(buffer.bytes, 0, bytes));
  }

  Future<void> _start() async {
    for (var i = 0; i < workerCount; i++) {
      _workers.add(await _Worker.spawn());
    }
  }

  /// Stops the workers once the pictures already asked for are done.
  Future<void> dispose() async {
    _disposed = true;
    await _queue;
    await _starting;
    for (final w in _workers) {
      w.close();
    }
    _workers.clear();
    _buffer?.free();
    _buffer = null;
  }
}

const _transform = 0;
const _band = 1;

class _Worker {
  _Worker(this._isolate, this._port, this._replies) {
    _replies.listen((message) {
      final reply = message as List<Object?>;
      _pending.remove(reply[0]! as int)?.complete(reply[1]);
    });
  }

  static Future<_Worker> spawn() async {
    final replies = ReceivePort();
    final ready = ReceivePort();
    final isolate = await Isolate.spawn(_workerMain, [
      ready.sendPort,
      replies.sendPort,
    ]);
    final port = await ready.first as SendPort;
    return _Worker(isolate, port, replies);
  }

  final Isolate _isolate;
  final SendPort _port;
  final ReceivePort _replies;
  final _pending = <int, Completer<Object?>>{};
  var _next = 0;

  Future<Object?> send(List<Object?> job) {
    final id = _next++;
    final done = Completer<Object?>();
    _pending[id] = done;
    _port.send([id, ...job]);
    return done.future;
  }

  void close() {
    _replies.close();
    _isolate.kill();
  }
}

void _workerMain(List<SendPort> ports) {
  final [ready, replies] = ports;
  final jobs = ReceivePort();
  ready.send(jobs.sendPort);
  jobs.listen((message) {
    final job = message as List<Object?>;
    final id = job[0]! as int;
    final context = job[2]! as int;
    final part = job[3]! as int, parts = job[4]! as int;
    if (job[1] == _transform) {
      transformPart(context, part, parts);
    } else {
      renderBand(context, part, parts, job[5]! as int);
    }
    replies.send([id, true]);
  });
}
