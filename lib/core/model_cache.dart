import 'dart:io';
import 'dart:isolate';

import 'model_mesh.dart';

/// Reads [path] and refuses meshes too large to preview. Top level, so
/// [Isolate.run] doesn't capture anything else.
ModelMesh readModelForPreview(String path) {
  final mesh = readModel(path);
  if (mesh.triangleCount > maxPreviewTriangles) {
    throw ModelTooLargeError(mesh.triangleCount);
  }
  return mesh;
}

ModelMesh _readInIsolate(String path) => readModelForPreview(path);

/// Parsed meshes in memory, newest last, by path and modification time;
/// failures are kept too, so a broken file isn't read again until it
/// changes. No disk cache: models are small enough to parse on demand.
class ModelCache {
  ModelCache({this.capacity = 200, Future<ModelMesh> Function(String)? read})
    : _read = read ?? ((path) => Isolate.run(() => _readInIsolate(path)));

  final int capacity;
  final Future<ModelMesh> Function(String path) _read;
  final _entries = <String, Future<ModelMesh>>{};

  /// Finished reads by the same keys, so a card scrolled back into view
  /// draws at once.
  final _done = <String, Object>{};

  int get length => _entries.length;

  /// The mesh of [path], parsed in an isolate unless cached. Throws a
  /// [ModelReadError] for files that can't be drawn.
  Future<ModelMesh> load(String path) {
    final key = _key(path);
    if (key == null) return Future.error(const ModelReadError('Missing file'));
    final hit = _entries.remove(key);
    if (hit != null) return _entries[key] = hit;
    final future = _read(path).catchError(
      (Object e) => throw e is ModelReadError
          ? e
          : ModelReadError('Could not read the file ($e)'),
    );
    _entries[key] = future;
    future.then(
      (m) {
        if (_entries.containsKey(key)) _done[key] = m;
      },
      onError: (Object e) {
        if (_entries.containsKey(key)) _done[key] = e;
      },
    );
    while (_entries.length > capacity) {
      _done.remove(_entries.keys.first);
      _entries.remove(_entries.keys.first);
    }
    return future;
  }

  /// What [load] gave for [path] if it has finished: a [ModelMesh] or a
  /// [ModelReadError]; null while reading or before the first load.
  Object? peek(String path) => switch (_key(path)) {
    final key? => _done[key],
    null => null,
  };

  static String? _key(String path) {
    final stat = File(path).statSync();
    if (stat.type == FileSystemEntityType.notFound) return null;
    return '$path\u0000${stat.modified.microsecondsSinceEpoch}';
  }

  /// Forgets every mesh.
  void clear() {
    _entries.clear();
    _done.clear();
  }
}
