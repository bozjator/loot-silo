import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/model_mesh.dart';
import '../core/model_raster.dart';
import '../state/providers.dart';
import 'model_painter.dart';
import 'model_picture.dart';
import 'theme_colors.dart';

/// One turn of a hovered card.
const modelTurnDuration = Duration(seconds: 6);

/// A model card's picture: the mesh of [path] drawn from the default
/// camera, turning slowly while [turning]. Shows a spinner while the file
/// is read, and an error or "Too large to preview" stage when it can't be
/// drawn (the reason in the tooltip).
class ModelStage extends ConsumerStatefulWidget {
  const ModelStage({super.key, required this.path, this.turning = false});

  /// Absolute path of a model file [readModel] can read.
  final String path;
  final bool turning;

  @override
  ConsumerState<ModelStage> createState() => _ModelStageState();
}

class _ModelStageState extends ConsumerState<ModelStage>
    with SingleTickerProviderStateMixin {
  late final _turn = AnimationController(
    vsync: this,
    duration: modelTurnDuration,
  );

  /// A [ModelMesh] or a [ModelReadError]; null while reading.
  Object? _result;

  /// Textures loaded for the mesh shown.
  var _textures = 0;
  final _picture = ModelPicture();

  @override
  void initState() {
    super.initState();
    _load();
    if (widget.turning) _turn.repeat();
  }

  @override
  void didUpdateWidget(ModelStage old) {
    super.didUpdateWidget(old);
    if (old.path != widget.path) _load();
    if (widget.turning != old.turning) {
      // Stopping keeps the angle it reached.
      widget.turning ? _turn.repeat() : _turn.stop();
    }
  }

  @override
  void dispose() {
    _turn.dispose();
    _picture.dispose();
    super.dispose();
  }

  void _load() {
    final path = widget.path;
    final cache = ref.read(modelCacheProvider);
    _result = cache.peek(path);
    _textures = 0;
    if (_result case final ModelMesh mesh) {
      _loadTextures(mesh);
      return;
    }
    if (_result != null) return;
    cache
        .load(path)
        .then(
          (mesh) {
            if (!mounted || widget.path != path) return;
            setState(() => _result = mesh);
            _loadTextures(mesh);
          },
          onError: (Object e) {
            if (!mounted || widget.path != path) return;
            setState(
              () => _result = e is ModelReadError ? e : ModelReadError('$e'),
            );
          },
        );
  }

  void _loadTextures(ModelMesh mesh) {
    final path = widget.path;
    loadModelTextures(mesh, path, () {
      if (mounted && widget.path == path) setState(() => _textures++);
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return switch (_result) {
      null => const Center(
        child: SizedBox.square(
          key: ValueKey('model-loading'),
          dimension: 24,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      ),
      final ModelTooLargeError e => Tooltip(
        message: '${e.reason}: ${e.triangles} triangles',
        child: Center(
          key: const ValueKey('model-too-large'),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.view_in_ar, size: 36, color: scheme.onSurfaceVariant),
              const SizedBox(height: 4),
              Text(
                e.reason,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
      final ModelReadError e => Tooltip(
        message: e.reason,
        child: Center(
          key: const ValueKey('model-error'),
          child: Icon(
            Icons.broken_image_outlined,
            size: 36,
            color: scheme.error,
          ),
        ),
      ),
      final ModelMesh mesh => AnimatedBuilder(
        animation: _turn,
        builder: (context, _) => CustomPaint(
          key: const ValueKey('model-paint'),
          size: Size.infinite,
          painter: ModelPainter(
            mesh: mesh,
            yaw: defaultModelYaw + _turn.value * 2 * math.pi,
            textures: _textures,
            background: modelStageColor(scheme),
            pixelRatio: MediaQuery.devicePixelRatioOf(context),
            picture: _picture,
          ),
        ),
      ),
      _ => const SizedBox.shrink(),
    };
  }
}

/// Textures in the renderer's memory, shared by every card (Kenney kits
/// use one `colormap.png` for all their models); the oldest go past 64.
final _textures = <String, Future<RasterTexture?>>{};

/// The image a material names: a file, or one stored inside [mesh] (keyed
/// by the model's [path] too). Null when it can't be read or decoded.
Future<RasterTexture?> modelTexture(String key, ModelMesh mesh, String path) {
  final embedded = mesh.images[key];
  final id = embedded == null ? key : '$path#$key';
  final hit = _textures.remove(id);
  if (hit != null) return _textures[id] = hit;
  Future<RasterTexture?> decode() async {
    try {
      final bytes = embedded ?? await File(key).readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      final image = (await codec.getNextFrame()).image;
      codec.dispose();
      final pixels = await image.toByteData(
        format: ui.ImageByteFormat.rawStraightRgba,
      );
      final (width, height) = (image.width, image.height);
      image.dispose();
      if (pixels == null) return null;
      return RasterTexture.fromRgba(
        pixels.buffer.asUint8List(pixels.offsetInBytes, pixels.lengthInBytes),
        width,
        height,
      );
    } on Object {
      return null;
    }
  }

  final future = decode();
  _textures[id] = future;
  while (_textures.length > 64) {
    _textures.remove(_textures.keys.first);
  }
  return future;
}

/// Loads the textures [mesh] (the model at [path]) names and hands them to
/// the renderer; [onLoaded] runs after each one, to repaint. Textures the
/// renderer already has are left alone.
void loadModelTextures(ModelMesh mesh, String path, VoidCallback onLoaded) {
  if (mesh.textures.isEmpty) return;
  final RasterMesh raster;
  try {
    raster = RasterMesh.of(mesh);
  } on ModelReadError {
    return;
  }
  for (final key in mesh.textures) {
    if (raster.hasTexture(key)) continue;
    modelTexture(key, mesh, path).then((texture) {
      if (texture == null) return;
      raster.setTexture(key, texture);
      onLoaded();
    });
  }
}
