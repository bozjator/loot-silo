import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/model_mesh.dart';
import '../state/providers.dart';
import 'model_painter.dart';
import 'theme_colors.dart';

/// One turn of a hovered card.
const modelTurnDuration = Duration(seconds: 6);

/// A model card's picture: the mesh of [path] drawn from the default
/// camera, turning slowly while [turning]. Shows a spinner while the file
/// is read, and an error or "Too large to preview" stage when it can't be
/// drawn (the reason in the tooltip).
class ModelStage extends ConsumerStatefulWidget {
  const ModelStage({super.key, required this.path, this.turning = false});

  /// Absolute path of a GLB, glTF or OBJ file.
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
  Map<String, ui.Image> _textures = const {};

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
    super.dispose();
  }

  void _load() {
    final path = widget.path;
    final cache = ref.read(modelCacheProvider);
    _result = cache.peek(path);
    _textures = const {};
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
    for (final key in mesh.textures) {
      modelTexture(key, mesh, path).then((image) {
        if (image == null || !mounted || widget.path != path) return;
        setState(() => _textures = {..._textures, key: image});
      });
    }
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
          ),
        ),
      ),
      _ => const SizedBox.shrink(),
    };
  }
}

/// Decoded textures, shared by every card (Kenney kits use one
/// `colormap.png` for all their models); the oldest go past 64.
final _textures = <String, Future<ui.Image?>>{};

/// The image a material names: a file, or one stored inside [mesh] (keyed
/// by the model's [path] too). Null when it can't be read or decoded.
Future<ui.Image?> modelTexture(String key, ModelMesh mesh, String path) {
  final embedded = mesh.images[key];
  final id = embedded == null ? key : '$path#$key';
  final hit = _textures.remove(id);
  if (hit != null) return _textures[id] = hit;
  Future<ui.Image?> decode() async {
    try {
      final bytes = embedded ?? await File(key).readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      return (await codec.getNextFrame()).image;
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
