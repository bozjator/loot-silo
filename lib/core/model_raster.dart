import 'dart:ffi';
import 'dart:typed_data';

import 'model_mesh.dart';

// Bindings of `native/model_raster.c`, compiled by `hook/build.dart`.

@Native<
  Pointer<Void> Function(
    Pointer<Float>,
    Pointer<Float>,
    Pointer<Float>,
    Pointer<Uint32>,
    Pointer<Uint16>,
    Int32,
    Int32,
    Pointer<Uint32>,
    Pointer<Uint8>,
    Int32,
    Int32,
    Int32,
  )
>(symbol: 'ls_mesh_create', isLeaf: true)
external Pointer<Void> _meshCreate(
  Pointer<Float> pos,
  Pointer<Float> nrm,
  Pointer<Float> uv,
  Pointer<Uint32> idx,
  Pointer<Uint16> triMat,
  int vertices,
  int triangles,
  Pointer<Uint32> matColor,
  Pointer<Uint8> matFlags,
  int materials,
  int hasUv,
  int flatShaded,
);

@Native<Void Function(Pointer<Void>)>(symbol: 'ls_mesh_free', isLeaf: true)
external void _meshFree(Pointer<Void> mesh);

@Native<Void Function(Pointer<Void>, Int32, Pointer<Void>)>(
  symbol: 'ls_mesh_set_texture',
  isLeaf: true,
)
external void _meshSetTexture(
  Pointer<Void> mesh,
  int material,
  Pointer<Void> texture,
);

@Native<Pointer<Void> Function(Pointer<Uint8>, Int32, Int32)>(
  symbol: 'ls_texture_create',
  isLeaf: true,
)
external Pointer<Void> _textureCreate(Pointer<Uint8> rgba, int w, int h);

@Native<Void Function(Pointer<Void>)>(symbol: 'ls_texture_free', isLeaf: true)
external void _textureFree(Pointer<Void> texture);

@Native<Pointer<Void> Function()>(symbol: 'ls_context_create', isLeaf: true)
external Pointer<Void> _contextCreate();

@Native<Void Function(Pointer<Void>)>(symbol: 'ls_context_free', isLeaf: true)
external void _contextFree(Pointer<Void> context);

@Native<
  Int32 Function(
    Pointer<Void>,
    Pointer<Void>,
    Float,
    Float,
    Float,
    Float,
    Float,
    Int32,
    Int32,
    Int32,
    Uint32,
    Uint32,
    Float,
  )
>(symbol: 'ls_frame_begin', isLeaf: true)
external int _frameBegin(
  Pointer<Void> context,
  Pointer<Void> mesh,
  double yaw,
  double pitch,
  double zoom,
  double panX,
  double panY,
  int w,
  int h,
  int ss,
  int flags,
  int lineArgb,
  double linePx,
);

@Native<Void Function(Pointer<Void>, Int32, Int32)>(
  symbol: 'ls_frame_transform',
  isLeaf: true,
)
external void _frameTransform(Pointer<Void> context, int part, int parts);

@Native<Void Function(Pointer<Void>, Int32, Int32, Pointer<Uint8>)>(
  symbol: 'ls_frame_band',
  isLeaf: true,
)
external void _frameBand(
  Pointer<Void> context,
  int part,
  int parts,
  Pointer<Uint8> out,
);

@Native<Pointer<Uint8> Function(Int64)>(symbol: 'ls_buffer_alloc', isLeaf: true)
external Pointer<Uint8> _bufferAlloc(int bytes);

@Native<Void Function(Pointer<Uint8>)>(symbol: 'ls_buffer_free', isLeaf: true)
external void _bufferFree(Pointer<Uint8> buffer);

final _noUvs = Float32List(2);

final _freeMesh = NativeFinalizer(
  Native.addressOf<NativeFunction<Void Function(Pointer<Void>)>>(_meshFree),
);
final _freeTexture = NativeFinalizer(
  Native.addressOf<NativeFunction<Void Function(Pointer<Void>)>>(_textureFree),
);
final _freeContext = NativeFinalizer(
  Native.addressOf<NativeFunction<Void Function(Pointer<Void>)>>(_contextFree),
);

/// One picture of a model: the camera, the picture's size and what is
/// drawn over the surface.
class RasterView {
  const RasterView({
    required this.width,
    required this.height,
    this.yaw = 0,
    this.pitch = 0,
    this.zoom = 1,
    this.panX = 0,
    this.panY = 0,
    this.samples = 2,
    this.textured = true,
    this.wireframe = false,
    this.grid = false,
    this.lineColor = 0xFF000000,
    this.lineWidth = 1,
  });

  /// The picture's size in pixels.
  final int width;
  final int height;

  /// Turn around the up axis and tilt toward the viewer, in radians.
  final double yaw;
  final double pitch;

  /// 1 fits the model to the picture.
  final double zoom;

  /// Offset of the model's centre, in the picture's pixels.
  final double panX;
  final double panY;

  /// Each pixel is the average of [samples] × [samples] samples (smooth
  /// edges); 1 draws faster.
  final int samples;

  /// False draws every material in its plain colour.
  final bool textured;

  /// Outlines the triangles facing the camera; edges behind the surface
  /// are hidden.
  final bool wireframe;

  /// A floor of squares under the model.
  final bool grid;

  /// ARGB colour and width (in the picture's pixels) of the wireframe and
  /// grid lines.
  final int lineColor;
  final double lineWidth;

  int get _flags => (wireframe ? 1 : 0) | (grid ? 2 : 0) | (textured ? 0 : 4);

  @override
  bool operator ==(Object other) =>
      other is RasterView &&
      other.width == width &&
      other.height == height &&
      other.yaw == yaw &&
      other.pitch == pitch &&
      other.zoom == zoom &&
      other.panX == panX &&
      other.panY == panY &&
      other.samples == samples &&
      other.textured == textured &&
      other.wireframe == wireframe &&
      other.grid == grid &&
      other.lineColor == lineColor &&
      other.lineWidth == lineWidth;

  @override
  int get hashCode => Object.hash(
    width,
    height,
    yaw,
    pitch,
    zoom,
    panX,
    panY,
    samples,
    textured,
    wireframe,
    grid,
    lineColor,
    lineWidth,
  );
}

/// A texture's pixels in the renderer's memory, shared by every mesh that
/// uses the image.
class RasterTexture implements Finalizable {
  RasterTexture._(this._ptr, this.width, this.height);

  /// From straight (not premultiplied) RGBA pixels; null when they don't
  /// fit the size or memory runs out.
  static RasterTexture? fromRgba(Uint8List rgba, int width, int height) {
    if (width <= 0 || height <= 0 || rgba.length < width * height * 4) {
      return null;
    }
    final ptr = _textureCreate(rgba.address, width, height);
    if (ptr == nullptr) return null;
    final texture = RasterTexture._(ptr, width, height);
    _freeTexture.attach(texture, ptr, detach: texture);
    return texture;
  }

  final Pointer<Void> _ptr;
  final int width;
  final int height;
}

/// A [ModelMesh] copied into the renderer's memory, freed with this object.
class RasterMesh implements Finalizable {
  RasterMesh._(this._ptr, this.mesh);

  static final _of = Expando<RasterMesh>();

  /// The renderer's copy of [mesh], made on first use and kept with it.
  /// Throws a [ModelReadError] when the mesh can't be drawn.
  static RasterMesh of(ModelMesh mesh) =>
      _of[mesh] ??= RasterMesh._create(mesh);

  factory RasterMesh._create(ModelMesh mesh) {
    final materials = mesh.materials;
    final colors = Uint32List(materials.length);
    final flags = Uint8List(materials.length);
    for (var i = 0; i < materials.length; i++) {
      colors[i] = materials[i].color;
      flags[i] =
          (materials[i].doubleSided ? 1 : 0) | (materials[i].nearest ? 2 : 0);
    }
    final uvs = mesh.uvs;
    final ptr = _meshCreate(
      mesh.positions.address,
      mesh.normals.address,
      (uvs ?? _noUvs).address,
      mesh.indices.address,
      mesh.triangleMaterials.address,
      mesh.vertexCount,
      mesh.triangleCount,
      colors.address,
      flags.address,
      materials.length,
      uvs == null ? 0 : 1,
      mesh.facetted ? 1 : 0,
    );
    if (ptr == nullptr) throw const ModelReadError('Could not draw the model');
    final raster = RasterMesh._(ptr, mesh);
    _freeMesh.attach(raster, ptr, detach: raster);
    return raster;
  }

  final Pointer<Void> _ptr;
  final ModelMesh mesh;

  /// The textures set so far, by [ModelMaterial.texture]; kept alive here
  /// because the renderer only borrows them.
  final _textures = <String, RasterTexture>{};

  /// Counts [setTexture] calls: a picture drawn before is out of date.
  int get textureVersion => _textureVersion;
  var _textureVersion = 0;

  /// The address of the renderer's mesh, for a call from another isolate
  /// (keep this object alive meanwhile).
  int get address => _ptr.address;

  bool hasTexture(String key) => _textures.containsKey(key);

  /// Draws every material whose [ModelMaterial.texture] is [key] with
  /// [texture].
  void setTexture(String key, RasterTexture texture) {
    if (identical(_textures[key], texture)) return;
    _textures[key] = texture;
    final materials = mesh.materials;
    for (var i = 0; i < materials.length; i++) {
      if (materials[i].texture == key) _meshSetTexture(_ptr, i, texture._ptr);
    }
    _textureVersion++;
  }
}

/// The renderer's working memory (depth and colour samples, projected
/// vertices). One per thread that draws; reused from frame to frame.
class RasterContext implements Finalizable {
  RasterContext() : _ptr = _contextCreate() {
    _freeContext.attach(this, _ptr, detach: this);
  }

  final Pointer<Void> _ptr;

  /// For [beginFrame], [transformPart] and [renderBand] calls from other
  /// isolates.
  int get address => _ptr.address;

  /// Draws [mesh] as [view] sees it into [out], premultiplied RGBA of
  /// `width × height × 4` bytes. False when memory runs out.
  bool render(RasterMesh mesh, RasterView view, Uint8List out) {
    assert(out.length >= view.width * view.height * 4);
    if (!begin(mesh, view)) return false;
    _frameTransform(_ptr, 0, 1);
    _frameBand(_ptr, 0, 1, out.address);
    return true;
  }

  /// Sets up a frame of [mesh] for [view]. [transformPart] then projects
  /// the vertices and [renderBand] draws the rows, each in parts that
  /// several isolates may do at once.
  bool begin(RasterMesh mesh, RasterView view) =>
      beginFrame(address, mesh.address, view);
}

/// [RasterContext.begin] by addresses, for a call from another isolate.
bool beginFrame(int context, int mesh, RasterView view) =>
    _frameBegin(
      Pointer<Void>.fromAddress(context),
      Pointer<Void>.fromAddress(mesh),
      view.yaw,
      view.pitch,
      view.zoom,
      view.panX,
      view.panY,
      view.width,
      view.height,
      view.samples,
      view._flags,
      view.lineColor,
      view.lineWidth,
    ) !=
    0;

/// Pixels outside the Dart heap, so that worker isolates can fill them.
/// [free] it when done.
class RasterBuffer {
  RasterBuffer(this.length) : _ptr = _bufferAlloc(length) {
    if (_ptr == nullptr) throw const OutOfMemoryError();
  }

  final Pointer<Uint8> _ptr;
  final int length;

  int get address => _ptr.address;

  /// The pixels themselves, not a copy; invalid after [free].
  Uint8List get bytes => _ptr.asTypedList(length);

  void free() => _bufferFree(_ptr);
}

/// Projects part [part] of [parts] of the vertices of the frame begun in
/// the context at [context]. Every part must be done before a band is
/// drawn.
void transformPart(int context, int part, int parts) =>
    _frameTransform(Pointer<Void>.fromAddress(context), part, parts);

/// Draws part [part] of [parts] of the rows of the frame begun in the
/// context at [context] into the picture at [out] (native memory of
/// `width × height × 4` bytes). The rows are shared out by the work in
/// them.
void renderBand(int context, int part, int parts, int out) => _frameBand(
  Pointer<Void>.fromAddress(context),
  part,
  parts,
  Pointer<Uint8>.fromAddress(out),
);
