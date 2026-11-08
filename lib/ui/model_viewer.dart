import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../core/audio_formats.dart' show formatOf;
import '../core/model_formats.dart';
import '../core/model_mesh.dart';
import '../state/providers.dart';
import 'folder_groups.dart' show folderTitle;
import 'format.dart';
import 'model_painter.dart';
import 'model_stage.dart' show modelTexture, modelTurnDuration;
import 'reveal.dart';
import 'shortcuts.dart';
import 'theme_colors.dart';
import 'widgets/format_chips.dart';

/// The viewer's toggles, kept while the app runs (not saved).
class ModelViewOptions {
  var textured = true;
  var wireframe = false;
  var turntable = false;
  var grid = false;
}

/// Shared by every viewer opened this session.
final modelViewOptions = ModelViewOptions();

/// Opens [items] (each drawn from [files], pack-relative, parallel to it) in
/// the [ModelViewer] at [index], over a dark backdrop.
Future<void> showModelViewer(
  BuildContext context, {
  required String packPath,
  required List<ModelItem> items,
  required List<String> files,
  required int index,
  Map<String, int> sizes = const {},
}) => showDialog<void>(
  context: context,
  barrierColor: Colors.black87,
  builder: (_) => ModelViewer(
    packPath: packPath,
    items: items,
    files: files,
    initialIndex: index,
    sizes: sizes,
  ),
);

/// Smallest and largest zoom (1 fits the model).
const minModelZoom = 0.2;
const maxModelZoom = 20.0;

/// Radians per logical pixel of drag, and per orbit key press.
const _orbitPerPixel = 0.01;
const _orbitStep = 15 * math.pi / 180;
const _zoomStep = 1.25;

/// A near full-window look at one model: drag to orbit, wheel or pinch to
/// zoom, right- or middle-drag to pan, double-click to reset; toggles for
/// texture, wireframe, turntable and a floor grid; an info panel; prev /
/// next through the tab's models in on-screen order.
class ModelViewer extends ConsumerStatefulWidget {
  const ModelViewer({
    super.key,
    required this.packPath,
    required this.items,
    required this.files,
    required this.initialIndex,
    this.sizes = const {},
  });

  final String packPath;
  final List<ModelItem> items;
  final List<String> files;
  final int initialIndex;

  /// File sizes by relative path; missing ones are read from disk.
  final Map<String, int> sizes;

  @override
  ConsumerState<ModelViewer> createState() => _ModelViewerState();
}

class _ModelViewerState extends ConsumerState<ModelViewer>
    with SingleTickerProviderStateMixin {
  late var _index = widget.initialIndex.clamp(0, widget.items.length - 1);
  late final _files = [...widget.files];
  final _options = modelViewOptions;

  var _yaw = defaultModelYaw;
  var _pitch = defaultModelPitch;
  var _zoom = 1.0;
  var _pan = Offset.zero;

  /// A button is down on the stage: large meshes draw unsorted meanwhile.
  var _dragging = false;
  var _pinchFrom = 1.0;
  var _copied = false;

  /// A [ModelMesh] or a [ModelReadError]; null while reading.
  Object? _result;
  Map<String, ui.Image> _textures = const {};
  final _paintCache = ModelPaintCache();

  late final Ticker _turntable = createTicker(_turn);
  Duration _lastTick = Duration.zero;

  String get _rel => _files[_index];
  String get _path => p.join(widget.packPath, _rel);

  @override
  void initState() {
    super.initState();
    _load();
    if (_options.turntable) _turntable.start();
  }

  @override
  void dispose() {
    _turntable.dispose();
    super.dispose();
  }

  void _turn(Duration elapsed) {
    final dt = elapsed - _lastTick;
    _lastTick = elapsed;
    setState(() {
      _yaw +=
          2 * math.pi * dt.inMicroseconds / modelTurnDuration.inMicroseconds;
    });
  }

  void _setTurntable(bool on) {
    setState(() => _options.turntable = on);
    if (on) {
      _lastTick = Duration.zero;
      _turntable.start();
    } else {
      _turntable.stop();
    }
  }

  void _load() {
    final path = _path;
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
            if (!mounted || _path != path) return;
            setState(() => _result = mesh);
            _loadTextures(mesh);
          },
          onError: (Object e) {
            if (!mounted || _path != path) return;
            setState(
              () => _result = e is ModelReadError ? e : ModelReadError('$e'),
            );
          },
        );
  }

  void _loadTextures(ModelMesh mesh) {
    final path = _path;
    for (final key in mesh.textures) {
      modelTexture(key, mesh, path).then((image) {
        if (image == null || !mounted || _path != path) return;
        setState(() => _textures = {..._textures, key: image});
      });
    }
  }

  void _reset() => setState(() {
    _yaw = defaultModelYaw;
    _pitch = defaultModelPitch;
    _zoom = 1;
    _pan = Offset.zero;
  });

  void _orbit(double dYaw, double dPitch) => setState(() {
    _yaw += dYaw;
    _pitch = (_pitch + dPitch).clamp(-maxModelPitch, maxModelPitch);
  });

  void _zoomBy(double factor) => setState(
    () => _zoom = (_zoom * factor).clamp(minModelZoom, maxModelZoom),
  );

  bool get _hasPrev => _index > 0;
  bool get _hasNext => _index < widget.items.length - 1;

  /// Stops at the ends; the camera stays where it is.
  void _go(int delta) {
    final next = _index + delta;
    if (next < 0 || next >= widget.items.length) return;
    setState(() {
      _index = next;
      _copied = false;
      _load();
    });
  }

  /// A readable chip draws that file; another is shown in the file manager.
  void _pick(String rel) {
    if (readableModelExts.contains(formatOf(rel))) {
      setState(() {
        _files[_index] = rel;
        _copied = false;
        _load();
      });
    } else {
      ref.read(revealProvider)(p.join(widget.packPath, rel));
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    if (AppKeys.turnLeft.accepts(event)) {
      _orbit(-_orbitStep, 0);
    } else if (AppKeys.turnRight.accepts(event)) {
      _orbit(_orbitStep, 0);
    } else if (AppKeys.tiltUp.accepts(event)) {
      _orbit(0, _orbitStep);
    } else if (AppKeys.tiltDown.accepts(event)) {
      _orbit(0, -_orbitStep);
    } else if (AppKeys.modelPrevious.accepts(event)) {
      _go(-1);
    } else if (AppKeys.modelNext.accepts(event)) {
      _go(1);
    } else if (AppKeys.modelZoomIn.accepts(event)) {
      _zoomBy(_zoomStep);
    } else if (AppKeys.modelZoomOut.accepts(event)) {
      _zoomBy(1 / _zoomStep);
    } else if (AppKeys.resetCamera.accepts(event)) {
      _reset();
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  void _onMove(PointerMoveEvent e) {
    if (e.buttons & kPrimaryButton != 0) {
      _orbit(e.delta.dx * _orbitPerPixel, e.delta.dy * _orbitPerPixel);
    } else if (e.buttons & (kSecondaryMouseButton | kMiddleMouseButton) != 0) {
      setState(() => _pan += e.delta);
    }
  }

  void _onSignal(PointerSignalEvent e) {
    if (e is PointerScrollEvent) {
      GestureBinding.instance.pointerSignalResolver.register(e, (_) {
        _zoomBy(math.exp(-e.scrollDelta.dy / 400));
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final window = MediaQuery.sizeOf(context);
    final theme = Theme.of(context);
    final item = widget.items[_index];
    return Dialog(
      insetPadding: EdgeInsets.symmetric(
        horizontal: window.width * 0.025,
        vertical: window.height * 0.025,
      ),
      clipBehavior: Clip.antiAlias,
      child: Focus(
        autofocus: true,
        onKeyEvent: _onKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _toolbar(theme),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: _stage(theme)),
                  SizedBox(width: 300, child: _info(theme, item)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _toolbar(ThemeData theme) {
    Widget toggle(
      String key,
      String tooltip,
      IconData icon,
      bool on,
      ValueChanged<bool> set,
    ) => IconButton(
      key: ValueKey('toggle-$key'),
      tooltip: tooltip,
      isSelected: on,
      icon: Icon(icon),
      onPressed: () => set(!on),
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
      child: Row(
        children: [
          SizedBox(
            width: 80,
            child: Text(
              '${_index + 1} / ${widget.items.length}',
              style: theme.textTheme.labelLarge,
            ),
          ),
          Expanded(
            child: Column(
              children: [
                Text(
                  prettyName(p.basename(_rel)),
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium,
                ),
                Text(
                  _rel,
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
          toggle(
            'textured',
            _options.textured
                ? 'Textured (click for flat colours)'
                : 'Flat colours (click for textures)',
            Icons.texture,
            _options.textured,
            (on) => setState(() => _options.textured = on),
          ),
          toggle(
            'wireframe',
            'Wireframe',
            Icons.change_history,
            _options.wireframe,
            (on) => setState(() => _options.wireframe = on),
          ),
          toggle(
            'turntable',
            'Turntable',
            Icons.threesixty,
            _options.turntable,
            _setTurntable,
          ),
          toggle(
            'grid',
            'Floor grid',
            Icons.grid_4x4,
            _options.grid,
            (on) => setState(() => _options.grid = on),
          ),
          const SizedBox(width: 8),
          IconButton(
            tooltip: 'Reset the camera (0, double-click)',
            icon: const Icon(Icons.center_focus_strong),
            onPressed: _reset,
          ),
          IconButton(
            tooltip: 'Close',
            icon: const Icon(Icons.close),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }

  Widget _stage(ThemeData theme) {
    final scheme = theme.colorScheme;
    final picture = switch (_result) {
      null => const Center(
        key: ValueKey('viewer-loading'),
        child: CircularProgressIndicator(),
      ),
      final ModelTooLargeError e => Center(
        key: const ValueKey('viewer-too-large'),
        child: Text(
          '${e.reason} (${formatCount(e.triangles)} triangles)',
          style: theme.textTheme.titleMedium,
        ),
      ),
      final ModelReadError e => Center(
        key: const ValueKey('viewer-error'),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.broken_image_outlined, size: 48, color: scheme.error),
            const SizedBox(height: 8),
            Text(e.reason, style: theme.textTheme.titleMedium),
          ],
        ),
      ),
      final ModelMesh mesh => CustomPaint(
        key: const ValueKey('model-viewer-paint'),
        size: Size.infinite,
        painter: ModelPainter(
          mesh: mesh,
          yaw: _yaw,
          pitch: _pitch,
          zoom: _zoom,
          pan: _pan,
          textures: _textures,
          flat: !_options.textured,
          wireframe: _options.wireframe,
          grid: _options.grid,
          sorted: !_dragging || mesh.triangleCount <= unsortedDragTriangles,
          lineColor: scheme.onSurface,
          cache: _paintCache,
        ),
      ),
      _ => const SizedBox.shrink(),
    };
    // Zoomed in, panned or with the floor grid, the drawing reaches past
    // the stage; it stays out of the info panel.
    return ClipRect(
      child: ColoredBox(
        color: modelStageColor(scheme),
        child: Stack(
          fit: StackFit.expand,
          children: [
            MouseRegion(
              cursor: _dragging
                  ? SystemMouseCursors.grabbing
                  : SystemMouseCursors.grab,
              child: Listener(
                key: const ValueKey('model-viewer-stage'),
                onPointerDown: (_) => setState(() => _dragging = true),
                onPointerUp: (_) => setState(() => _dragging = false),
                onPointerCancel: (_) => setState(() => _dragging = false),
                onPointerMove: _onMove,
                onPointerSignal: _onSignal,
                onPointerPanZoomStart: (_) => _pinchFrom = _zoom,
                onPointerPanZoomUpdate: (e) => setState(
                  () => _zoom = (_pinchFrom * e.scale).clamp(
                    minModelZoom,
                    maxModelZoom,
                  ),
                ),
                child: GestureDetector(
                  onDoubleTap: _reset,
                  child: ColoredBox(color: Colors.transparent, child: picture),
                ),
              ),
            ),
            if (widget.items.length > 1) ...[
              Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: IconButton.filledTonal(
                    tooltip: 'Previous model (←)',
                    icon: const Icon(Icons.chevron_left),
                    onPressed: _hasPrev ? () => _go(-1) : null,
                  ),
                ),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: IconButton.filledTonal(
                    tooltip: 'Next model (→)',
                    icon: const Icon(Icons.chevron_right),
                    onPressed: _hasNext ? () => _go(1) : null,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// "1.2", "0.25", "3": two decimals at most.
  static String _units(double v) =>
      v.toStringAsFixed(2).replaceFirst(RegExp(r'\.?0+$'), '');

  Widget _info(ThemeData theme, ModelItem item) {
    final mesh = _result is ModelMesh ? _result! as ModelMesh : null;
    int? size = widget.sizes[_rel];
    if (size == null) {
      try {
        size = File(_path).lengthSync();
      } on FileSystemException {
        // Gone since the scan.
      }
    }
    final b = mesh?.bounds;
    final textures = [
      for (final t in mesh?.textures ?? const <String>{})
        if (mesh!.images.containsKey(t))
          'inside the file'
        else
          p.isWithin(widget.packPath, t)
              ? p.relative(t, from: widget.packPath)
              : t,
    ];
    final rows = <(String, String)>[
      ('Folder', folderTitle(item.folder == '.' ? '' : item.folder)),
      if (mesh != null) ...[
        ('Triangles', formatCount(mesh.triangleCount)),
        ('Vertices', formatCount(mesh.vertexCount)),
        (
          'Size',
          '${_units(b![3] - b[0])} × ${_units(b[4] - b[1])} × '
              '${_units(b[5] - b[2])}',
        ),
        ('Texture', textures.isEmpty ? 'None' : textures.join('\n')),
      ],
      if (size != null) ('File size', formatBytes(size)),
    ];
    final label = theme.textTheme.labelMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return ListView(
      key: const ValueKey('model-info'),
      padding: const EdgeInsets.all(16),
      children: [
        SelectableText(
          prettyName(p.basename(_rel)),
          style: theme.textTheme.titleMedium,
        ),
        const SizedBox(height: 12),
        Text('Formats', style: label),
        const SizedBox(height: 4),
        Align(
          alignment: Alignment.centerLeft,
          child: FormatChips(
            files: item.files,
            shown: _rel,
            onPick: _pick,
            tooltip: (f) => f == _rel
                ? p.basename(f)
                : readableModelExts.contains(formatOf(f))
                ? 'Draw ${p.basename(f)}'
                : '${p.basename(f)}: not drawn; show in file manager',
          ),
        ),
        for (final (name, value) in rows) ...[
          const SizedBox(height: 12),
          Text(name, style: label),
          const SizedBox(height: 2),
          SelectableText(value, key: ValueKey('info:$name')),
        ],
        if (mesh != null) ...[
          const SizedBox(height: 12),
          Text('Materials', style: label),
          for (final m in mesh.usedMaterials)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: _MaterialSwatch(
                m,
                // Its own file: the texture image, else the OBJ's MTL.
                file: switch (m.texture) {
                  final t? when !mesh.images.containsKey(t) => t,
                  _ => m.file,
                },
                onReveal: (path) => ref.read(revealProvider)(path),
              ),
            ),
        ],
        const SizedBox(height: 16),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              icon: const Icon(Icons.drive_file_move_outline, size: 18),
              label: const Text('Show in file manager'),
              onPressed: () => ref.read(revealProvider)(_path),
            ),
            OutlinedButton.icon(
              icon: Icon(_copied ? Icons.check : Icons.copy, size: 18),
              label: Text(_copied ? 'Copied' : 'Copy path'),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: _path));
                setState(() => _copied = true);
              },
            ),
          ],
        ),
      ],
    );
  }
}

/// One material: its colour as a swatch, its name and hex value, and
/// "texture" when an image is painted over the colour. While hovered, a
/// material with a [file] of its own (texture or MTL) shows an icon that
/// reveals it.
class _MaterialSwatch extends StatefulWidget {
  const _MaterialSwatch(
    this.material, {
    required this.file,
    required this.onReveal,
  });

  final ModelMaterial material;
  final String? file;
  final ValueChanged<String> onReveal;

  @override
  State<_MaterialSwatch> createState() => _MaterialSwatchState();
}

class _MaterialSwatchState extends State<_MaterialSwatch> {
  var _hover = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final material = widget.material;
    final c = material.color;
    final hex =
        '#${(c & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';
    final alpha = (c >>> 24) * 100 ~/ 255;
    final details = [
      hex,
      if (alpha < 100) '$alpha% opaque',
      if (material.texture != null) 'texture',
    ].join(' · ');
    final file = widget.file;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Row(
        key: ValueKey('material:${material.name ?? hex}'),
        children: [
          Container(
            width: 20,
            height: 20,
            decoration: BoxDecoration(
              color: Color(c),
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: theme.colorScheme.outlineVariant),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: SelectableText.rich(
              TextSpan(
                children: [
                  TextSpan(text: material.name ?? 'Unnamed'),
                  TextSpan(
                    text: '  $details',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
              maxLines: 1,
            ),
          ),
          // Its room is kept, so rows don't shift as the pointer passes.
          if (file != null)
            Visibility.maintain(
              visible: _hover,
              child: IconButton(
                key: ValueKey('reveal-material:${material.name ?? hex}'),
                tooltip: 'Show ${p.basename(file)} in file manager',
                iconSize: 18,
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.drive_file_move_outline),
                onPressed: () => widget.onReveal(file),
              ),
            ),
        ],
      ),
    );
  }
}
