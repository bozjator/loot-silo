import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../core/audio_formats.dart' show formatOf;
import '../core/material_sets.dart';
import 'cursors.dart';
import 'folder_groups.dart' show folderTitle;
import 'format.dart';
import 'material_preview.dart';
import 'reveal.dart';
import 'shortcuts.dart';
import 'theme_colors.dart';
import 'widgets/format_chips.dart';
import 'widgets/dialog_close.dart';

/// What the material viewer's stage shows.
enum MaterialStageMode {
  sphere('Sphere'),
  plane('Plane'),
  tiled('Tiled 3 × 3'),
  map('Map');

  const MaterialStageMode(this.label);

  final String label;
}

/// Opens [materials] in the [MaterialViewer] at [index], over a dark
/// backdrop.
Future<void> showMaterialViewer(
  BuildContext context, {
  required String packPath,
  required List<MaterialSet> materials,
  required int index,
  Map<String, int> sizes = const {},
}) => showDialog<void>(
  context: context,
  barrierColor: Colors.black87,
  builder: (_) => MaterialViewer(
    packPath: packPath,
    materials: materials,
    initialIndex: index,
    sizes: sizes,
  ),
);

/// Sphere / plane size as a part of the stage's short side.
const defaultMaterialZoom = 0.85;
const minMaterialZoom = 0.3;
const maxMaterialZoom = 2.0;

/// Where the light starts: up and to the left, in front.
const defaultLightAzimuth = -0.6;
const defaultLightElevation = 0.55;

/// The viewer's mode, tiling, zoom, turn and light, kept while the app runs.
class MaterialViewOptions {
  var mode = MaterialStageMode.sphere;
  var tiling = 1.0;
  var zoom = defaultMaterialZoom;
  var yaw = 0.0;
  var azimuth = defaultLightAzimuth;
  var elevation = defaultLightElevation;

  void reset() {
    mode = MaterialStageMode.sphere;
    tiling = 1;
    zoom = defaultMaterialZoom;
    yaw = 0;
    azimuth = defaultLightAzimuth;
    elevation = defaultLightElevation;
  }
}

/// Shared by every material viewer opened this session.
final materialViewOptions = MaterialViewOptions();

/// A near full-window look at one material: a lit sphere (or plane) drawn
/// by a fragment shader from its Color, Normal, Roughness, Metalness and AO
/// maps, the Color map tiled 3 × 3, or one map at actual pixels; a strip of
/// its maps below the stage; an info panel; prev / next through the tab's
/// materials in on-screen order.
class MaterialViewer extends ConsumerStatefulWidget {
  const MaterialViewer({
    super.key,
    required this.packPath,
    required this.materials,
    required this.initialIndex,
    this.sizes = const {},
  });

  final String packPath;
  final List<MaterialSet> materials;
  final int initialIndex;

  /// File sizes by relative path; missing ones are read from disk.
  final Map<String, int> sizes;

  @override
  ConsumerState<MaterialViewer> createState() => _MaterialViewerState();
}

class _MaterialViewerState extends ConsumerState<MaterialViewer> {
  late var _index = widget.initialIndex.clamp(0, widget.materials.length - 1);

  // Session only, like the model viewer's toggles (not saved).
  final _o = materialViewOptions;
  MaterialStageMode get _mode => _o.mode;
  set _mode(MaterialStageMode v) => _o.mode = v;
  double get _tiling => _o.tiling;
  set _tiling(double v) => _o.tiling = v;
  double get _zoom => _o.zoom;
  set _zoom(double v) => _o.zoom = v;
  double get _yaw => _o.yaw;
  set _yaw(double v) => _o.yaw = v;
  double get _azimuth => _o.azimuth;
  set _azimuth(double v) => _o.azimuth = v;
  double get _elevation => _o.elevation;
  set _elevation(double v) => _o.elevation = v;
  var _dragging = false;
  var _copied = false;

  /// The map shown in Map mode (pack-relative).
  String? _map;
  final _mapView = TransformationController();

  ui.FragmentProgram? _program;
  ui.Image? _blank;

  /// The shader can't run here (recorded, then the Tiled mode stands in).
  Object? _shaderError;

  /// Decoded maps by pack-relative path; null while decoding or unreadable.
  final _decoded = <String, DecodedMap?>{};
  final _asked = <String>{};
  PreviewMaps _maps = const PreviewMaps();

  MaterialSet get _material => widget.materials[_index];

  @override
  void initState() {
    super.initState();
    materialProgram().then(
      (prog) async {
        final blank = await blankImage();
        if (!mounted) return;
        setState(() {
          _program = prog;
          _blank = blank;
        });
      },
      onError: (Object e) {
        if (!mounted) return;
        setState(() {
          _shaderError = e;
          if (_mode == MaterialStageMode.sphere ||
              _mode == MaterialStageMode.plane) {
            _mode = MaterialStageMode.tiled;
          }
        });
      },
    );
    _load();
  }

  @override
  void dispose() {
    _mapView.dispose();
    for (final d in _decoded.values) {
      d?.image.dispose();
    }
    super.dispose();
  }

  /// Decodes the material's shader maps and every map's size for the strip.
  void _load() {
    final m = _material;
    _map = m.color ?? m.maps.first.path;
    _maps = _previewMaps(m);
    for (final rel in [for (final map in m.maps) map.path]) {
      if (!_asked.add(rel)) continue;
      decodeMap(p.join(widget.packPath, rel)).then((d) {
        if (!mounted) {
          d?.image.dispose();
          return;
        }
        setState(() {
          _decoded[rel] = d;
          _maps = _previewMaps(_material);
        });
      });
    }
  }

  PreviewMaps _previewMaps(MaterialSet m) {
    final paths = PreviewMaps.pathsOf(m);
    ui.Image? of(MapRole role) => _decoded[paths[role]]?.image;
    return PreviewMaps(
      color: of(MapRole.color),
      normal: of(MapRole.normalGL) ?? of(MapRole.normalDX),
      normalDX: !paths.containsKey(MapRole.normalGL),
      roughness: of(MapRole.roughness),
      metalness: of(MapRole.metalness),
      ao: of(MapRole.ao),
    );
  }

  bool get _hasPrev => _index > 0;
  bool get _hasNext => _index < widget.materials.length - 1;

  void _go(int delta) {
    final next = _index + delta;
    if (next < 0 || next >= widget.materials.length) return;
    setState(() {
      _index = next;
      _copied = false;
      _mapView.value = Matrix4.identity();
      _load();
    });
  }

  void _setMode(MaterialStageMode mode) {
    if (_shaderError != null &&
        (mode == MaterialStageMode.sphere || mode == MaterialStageMode.plane)) {
      return;
    }
    setState(() => _mode = mode);
  }

  /// A map from the strip: shown in the stage, at actual pixels.
  void _showMap(String rel) => setState(() {
    _map = rel;
    _mode = MaterialStageMode.map;
    _mapView.value = Matrix4.identity();
  });

  void _reset() => setState(() {
    _zoom = defaultMaterialZoom;
    _yaw = 0;
    _azimuth = defaultLightAzimuth;
    _elevation = defaultLightElevation;
    _mapView.value = Matrix4.identity();
  });

  void _zoomBy(double factor) => setState(
    () => _zoom = (_zoom * factor).clamp(minMaterialZoom, maxMaterialZoom),
  );

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    if (AppKeys.materialPrevious.accepts(event)) {
      _go(-1);
    } else if (AppKeys.materialNext.accepts(event)) {
      _go(1);
    } else if (AppKeys.materialSphere.accepts(event)) {
      _setMode(MaterialStageMode.sphere);
    } else if (AppKeys.materialPlane.accepts(event)) {
      _setMode(MaterialStageMode.plane);
    } else if (AppKeys.materialTiled.accepts(event)) {
      _setMode(MaterialStageMode.tiled);
    } else if (AppKeys.materialMap.accepts(event)) {
      _setMode(MaterialStageMode.map);
    } else if (AppKeys.materialZoomIn.accepts(event)) {
      _zoomBy(1.25);
    } else if (AppKeys.materialZoomOut.accepts(event)) {
      _zoomBy(1 / 1.25);
    } else if (AppKeys.materialReset.accepts(event)) {
      _reset();
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  void _onMove(PointerMoveEvent e) {
    if (e.buttons & kPrimaryButton != 0) {
      setState(() {
        _azimuth = (_azimuth + e.delta.dx * 0.01).clamp(-1.5, 1.5);
        _elevation = (_elevation - e.delta.dy * 0.01).clamp(-1.5, 1.5);
      });
    } else if (e.buttons & (kSecondaryMouseButton | kMiddleMouseButton) != 0) {
      setState(() => _yaw -= e.delta.dx * 0.01);
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
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(child: _stage(theme)),
                        _strip(theme),
                      ],
                    ),
                  ),
                  SizedBox(width: 300, child: _info(theme)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _toolbar(ThemeData theme) {
    final left = closeOnLeft(context);
    final m = _material;
    final lit =
        _mode == MaterialStageMode.sphere || _mode == MaterialStageMode.plane;
    return Padding(
      padding: dialogHeaderPadding(context, text: 16),
      child: Row(
        children: [
          if (left) ...[const DialogCloseButton(), const SizedBox(width: 8)],
          SizedBox(
            width: 80,
            child: Text(
              '${_index + 1} / ${widget.materials.length}',
              style: theme.textTheme.labelLarge,
            ),
          ),
          Expanded(
            child: Column(
              children: [
                Text(
                  materialTitle(m.name),
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium,
                ),
                Text(
                  m.key,
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
          if (lit) ...[
            Tooltip(
              message: 'How often the maps repeat',
              child: Text(
                'Tiling ${_tiling.round()}×',
                style: theme.textTheme.labelLarge,
              ),
            ),
            SizedBox(
              width: 140,
              child: Slider(
                key: const ValueKey('material-tiling'),
                min: 1,
                max: 8,
                divisions: 7,
                value: _tiling,
                mouseCursor: WidgetStateMouseCursor.resolveWith(
                  (_) => SystemMouseCursors.click,
                ),
                onChanged: (v) => setState(() => _tiling = v),
              ),
            ),
          ],
          SegmentedButton<MaterialStageMode>(
            key: const ValueKey('material-modes'),
            showSelectedIcon: false,
            style: const ButtonStyle(
              visualDensity: VisualDensity.compact,
              mouseCursor: WidgetStatePropertyAll(SystemMouseCursors.click),
            ),
            segments: [
              for (final mode in MaterialStageMode.values)
                ButtonSegment(
                  value: mode,
                  label: Text(mode.label),
                  enabled:
                      _shaderError == null ||
                      mode == MaterialStageMode.tiled ||
                      mode == MaterialStageMode.map,
                ),
            ],
            selected: {_mode},
            onSelectionChanged: (s) => _setMode(s.single),
          ),
          const SizedBox(width: 8),
          IconButton(
            tooltip: 'Reset the light, turn and zoom (0, double-click)',
            icon: const Icon(Icons.center_focus_strong),
            onPressed: _reset,
          ),
          if (!left) const DialogCloseButton(),
        ],
      ),
    );
  }

  Widget _stage(ThemeData theme) {
    final scheme = theme.colorScheme;
    final m = _material;
    final Widget picture;
    switch (_mode) {
      case MaterialStageMode.sphere || MaterialStageMode.plane:
        final program = _program, blank = _blank;
        final waiting = PreviewMaps.pathsOf(m).values
            .any((rel) => !_decoded.containsKey(rel));
        picture = program == null || blank == null || waiting
            ? const Center(
                key: ValueKey('material-loading'),
                child: CircularProgressIndicator(),
              )
            : CustomPaint(
                key: ValueKey('material-shader:${_mode.name}'),
                size: Size.infinite,
                painter: MaterialPreviewPainter(
                  program: program,
                  blank: blank,
                  maps: _maps,
                  shape: _mode == MaterialStageMode.sphere
                      ? PreviewShape.sphere
                      : PreviewShape.plane,
                  zoom: _zoom,
                  tiling: _tiling,
                  yaw: _yaw,
                  azimuth: _azimuth,
                  elevation: _elevation,
                ),
              );
      case MaterialStageMode.tiled:
        final rel = m.color ?? m.maps.first.path;
        picture = LayoutBuilder(
          builder: (context, box) {
            final side = math.min(box.maxWidth, box.maxHeight) * _zoom;
            final tile = (side / 3).floorToDouble();
            final dpr = MediaQuery.devicePixelRatioOf(context);
            final image = ResizeImage(
              FileImage(File(p.join(widget.packPath, rel))),
              width: math.max(1, (tile * dpr).ceil()),
              allowUpscaling: false,
            );
            return Center(
              key: const ValueKey('material-tiled'),
              child: SizedBox.square(
                dimension: tile * 3,
                child: Column(
                  children: [
                    for (var r = 0; r < 3; r++)
                      Expanded(
                        child: Row(
                          children: [
                            for (var c = 0; c < 3; c++)
                              Expanded(
                                child: Image(
                                  image: image,
                                  fit: BoxFit.fill,
                                  filterQuality: FilterQuality.medium,
                                  gaplessPlayback: true,
                                ),
                              ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            );
          },
        );
      case MaterialStageMode.map:
        final rel = _map ?? m.maps.first.path;
        picture = InteractiveViewer(
          key: ValueKey('material-map:$rel'),
          transformationController: _mapView,
          minScale: 0.1,
          maxScale: 32,
          boundaryMargin: const EdgeInsets.all(double.infinity),
          child: Center(
            child: Image.file(
              File(p.join(widget.packPath, rel)),
              filterQuality: FilterQuality.none,
              gaplessPlayback: true,
            ),
          ),
        );
    }
    final shaderStage =
        _mode == MaterialStageMode.sphere || _mode == MaterialStageMode.plane;
    return ClipRect(
      child: ColoredBox(
        color: modelStageColor(scheme),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (shaderStage || _mode == MaterialStageMode.tiled)
              MouseRegion(
                cursor: _dragging
                    ? SystemMouseCursors.grabbing
                    : SystemMouseCursors.grab,
                child: Listener(
                  key: const ValueKey('material-viewer-stage'),
                  onPointerDown: (_) => setState(() => _dragging = true),
                  onPointerUp: (_) => setState(() => _dragging = false),
                  onPointerCancel: (_) => setState(() => _dragging = false),
                  onPointerMove: shaderStage ? _onMove : null,
                  onPointerSignal: _onSignal,
                  child: GestureDetector(
                    onDoubleTap: _reset,
                    child: ColoredBox(
                      color: Colors.transparent,
                      child: picture,
                    ),
                  ),
                ),
              )
            else
              GestureDetector(
                onDoubleTap: () => _mapView.value = Matrix4.identity(),
                child: picture,
              ),
            if (_shaderError != null)
              Positioned(
                left: 12,
                top: 12,
                child: Text(
                  'The lit preview can\'t run here: $_shaderError',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            if (widget.materials.length > 1) ...[
              Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: IconButton.filledTonal(
                    tooltip: 'Previous material (←)',
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
                    tooltip: 'Next material (→)',
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

  /// The maps below the stage: picture, role, file name, pixel size.
  Widget _strip(ThemeData theme) {
    final scheme = theme.colorScheme;
    final small = theme.textTheme.bodySmall;
    return SizedBox(
      height: 132,
      child: ListView(
        key: const ValueKey('material-strip'),
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.all(8),
        children: [
          for (final map in _material.maps)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Material(
                key: ValueKey('strip:${map.path}'),
                color: _mode == MaterialStageMode.map && map.path == _map
                    ? scheme.primaryContainer
                    : scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  mouseCursor: clickCursor,
                  onTap: () => _showMap(map.path),
                  child: SizedBox(
                    width: 190,
                    child: Padding(
                      padding: const EdgeInsets.all(6),
                      child: Row(
                        children: [
                          SizedBox.square(
                            dimension: 56,
                            child: switch (_decoded[map.path]) {
                              final d? => RawImage(
                                image: d.image,
                                fit: BoxFit.cover,
                                filterQuality: FilterQuality.medium,
                              ),
                              _ => const SizedBox.shrink(),
                            },
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Text(
                                  map.role.label,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.labelLarge,
                                ),
                                Tooltip(
                                  message: map.path,
                                  child: Text(
                                    p.basename(map.path),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: small,
                                  ),
                                ),
                                if (_decoded[map.path] case final d?)
                                  Text(
                                    '${d.width} × ${d.height}',
                                    key: ValueKey('strip-size:${map.path}'),
                                    style: small,
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  int _sizeOf(String rel) {
    final known = widget.sizes[rel];
    if (known != null) return known;
    try {
      return File(p.join(widget.packPath, rel)).lengthSync();
    } on FileSystemException {
      return 0;
    }
  }

  Widget _info(ThemeData theme) {
    final m = _material;
    final label = theme.textTheme.labelMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final total = m.files.fold(0, (sum, f) => sum + _sizeOf(f));
    final shown = p.join(widget.packPath, m.preview ?? m.maps.first.path);
    Widget row(String name, Widget value) => Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(name, style: label),
          const SizedBox(height: 2),
          value,
        ],
      ),
    );
    return ListView(
      key: const ValueKey('material-info'),
      padding: const EdgeInsets.all(16),
      children: [
        SelectableText(
          materialTitle(m.name),
          style: theme.textTheme.titleMedium,
        ),
        row(
          'Folder',
          SelectableText(folderTitle(m.folder == '.' ? '' : m.folder)),
        ),
        if (m.resolution case final r?)
          row('Resolution', SelectableText(r, key: const ValueKey('info:res'))),
        row(
          'Maps',
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final map in m.maps)
                SelectableText.rich(
                  key: ValueKey('info-map:${map.path}'),
                  TextSpan(
                    children: [
                      TextSpan(text: '${map.role.label}  '),
                      TextSpan(
                        text: p.basename(map.path),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        if (m.preview case final preview?)
          row('Picture', SelectableText(p.basename(preview))),
        if (m.toolFiles.isNotEmpty)
          row(
            'Other tools',
            Align(
              alignment: Alignment.centerLeft,
              child: FormatChips(
                files: m.toolFiles,
                shown: '',
                pickSingle: true,
                label: (f) =>
                    materialToolFormats[formatOf(f)] ??
                    formatOf(f).toUpperCase(),
                tooltip: (f) => '${p.basename(f)}: show in file manager',
                onPick: (f) =>
                    ref.read(revealProvider)(p.join(widget.packPath, f)),
              ),
            ),
          ),
        row(
          'Total size',
          SelectableText(formatBytes(total), key: const ValueKey('info:total')),
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              icon: const Icon(Icons.drive_file_move_outline, size: 18),
              label: const Text('Show in file manager'),
              onPressed: () => ref.read(revealProvider)(shown),
            ),
            OutlinedButton.icon(
              icon: Icon(_copied ? Icons.check : Icons.copy, size: 18),
              label: Text(_copied ? 'Copied' : 'Copy path'),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: shown));
                setState(() => _copied = true);
              },
            ),
          ],
        ),
      ],
    );
  }
}
