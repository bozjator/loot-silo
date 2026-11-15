import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import '../core/model_mesh.dart';
import '../core/model_raster.dart';
import '../core/model_render_pool.dart';

/// A picture this cheap is drawn right where it is asked for; anything
/// bigger goes to the worker isolates. Estimated nanoseconds, from
/// measurements of `native/model_raster.c` on one core.
const _inlineBudgetNs = 3000000;

int _costNs(ModelMesh mesh, RasterView view) =>
    mesh.triangleCount * 25 +
    view.width * view.height * view.samples * view.samples * 3;

/// The latest rendered picture of one model stage.
///
/// A painter asks [frame] for the picture of a camera. It gets the newest
/// one there is and, when that isn't the one it asked for, the new one is
/// drawn in the background and announced to the listeners (the painter
/// repaints). Only the last camera asked for is drawn, so a slow model
/// skips frames instead of falling behind.
class ModelPicture extends ChangeNotifier {
  static final _context = RasterContext();
  static ModelRenderPool? _pool;

  /// `flutter test` has no real time for worker isolates: draw inline.
  static final _inTest = Platform.environment.containsKey('FLUTTER_TEST');

  /// Whether the engine can make an image at once (Impeller can, Skia
  /// can't); null until tried.
  static bool? _syncImages;

  ui.Image? _image;
  Object? _shown;
  Object? _wanted;
  (RasterMesh, RasterView)? _job;
  var _busy = false;
  var _disposed = false;

  /// The newest picture; null before the first one is ready.
  ui.Image? get image => _image;

  /// How many pictures were drawn.
  int get renders => _renders;
  var _renders = 0;

  /// A picture asked for is still being drawn.
  bool get busy => _busy;

  /// The newest picture, after asking for the one of [mesh] seen by
  /// [view]. Null before the first picture, or when the mesh can't be
  /// drawn.
  ui.Image? frame(ModelMesh mesh, RasterView view) {
    final RasterMesh raster;
    try {
      raster = RasterMesh.of(mesh);
    } on ModelReadError {
      return null;
    }
    final key = (raster, raster.textureVersion, view);
    if (key == _shown) return _image;
    if (!_busy &&
        _syncImages != false &&
        _costNs(mesh, view) < _inlineBudgetNs) {
      final image = _renderNow(raster, view);
      if (image != null) {
        _show(image, key);
        return image;
      }
    }
    if (key != _wanted) {
      _wanted = key;
      _job = (raster, view);
      if (!_busy) unawaited(_work());
    }
    return _image;
  }

  /// Draws and makes the image on the spot; null where the engine can't.
  ui.Image? _renderNow(RasterMesh raster, RasterView view) {
    final pixels = Uint8List(view.width * view.height * 4);
    if (!_context.render(raster, view, pixels)) return null;
    try {
      final image = ui.decodeImageFromPixelsSync(
        pixels,
        view.width,
        view.height,
        ui.PixelFormat.rgba8888,
      );
      _syncImages = true;
      return image;
    } on Object {
      _syncImages = false;
      return null;
    }
  }

  void _show(ui.Image image, Object key) {
    _image?.dispose();
    _image = image;
    _shown = key;
    _renders++;
  }

  Future<void> _work() async {
    _busy = true;
    try {
      while (!_disposed && _wanted != _shown && _job != null) {
        final key = _wanted!;
        final (raster, view) = _job!;
        final Uint8List? pixels;
        if (_inTest || _costNs(raster.mesh, view) < _inlineBudgetNs) {
          final out = Uint8List(view.width * view.height * 4);
          pixels = _context.render(raster, view, out) ? out : null;
        } else {
          pixels = await (_pool ??= ModelRenderPool()).render(raster, view);
        }
        if (pixels == null) {
          // Out of memory: keep what is shown and stop asking.
          _shown = key;
          break;
        }
        final image = await _decode(pixels, view.width, view.height);
        if (_disposed) {
          image.dispose();
          break;
        }
        _show(image, key);
        notifyListeners();
      }
    } finally {
      _busy = false;
    }
  }

  static Future<ui.Image> _decode(Uint8List pixels, int width, int height) {
    final done = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      pixels,
      width,
      height,
      ui.PixelFormat.rgba8888,
      done.complete,
    );
    return done.future;
  }

  @override
  void dispose() {
    _disposed = true;
    _image?.dispose();
    _image = null;
    super.dispose();
  }
}
