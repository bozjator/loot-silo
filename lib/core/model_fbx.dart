import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'model_mesh.dart';

// Bindings of `native/fbx_reader.c` (ufbx), compiled by `hook/build.dart`.

final class _Material extends Struct {
  @Uint32()
  external int argb;
  @Int32()
  external int doubleSided;
  external Pointer<Uint8> name;
  external Pointer<Uint8> texture;
  external Pointer<Uint8> textureAbs;
  external Pointer<Uint8> textureData;
  @Int64()
  external int textureSize;
}

@Native<Pointer<Void> Function(Pointer<Uint8>, Int64, Pointer<Uint8>, Int64)>(
  symbol: 'ls_fbx_load',
  isLeaf: true,
)
external Pointer<Void> _load(
  Pointer<Uint8> data,
  int size,
  Pointer<Uint8> filename,
  int maxTriangles,
);

@Native<Void Function(Pointer<Void>)>(symbol: 'ls_fbx_free', isLeaf: true)
external void _free(Pointer<Void> fbx);

@Native<Pointer<Uint8> Function(Pointer<Void>)>(
  symbol: 'ls_fbx_error',
  isLeaf: true,
)
external Pointer<Uint8> _error(Pointer<Void> fbx);

@Native<Int64 Function(Pointer<Void>)>(symbol: 'ls_fbx_triangles', isLeaf: true)
external int _triangles(Pointer<Void> fbx);

@Native<Int32 Function(Pointer<Void>)>(symbol: 'ls_fbx_has_uv', isLeaf: true)
external int _hasUv(Pointer<Void> fbx);

@Native<Pointer<Float> Function(Pointer<Void>)>(
  symbol: 'ls_fbx_positions',
  isLeaf: true,
)
external Pointer<Float> _positions(Pointer<Void> fbx);

@Native<Pointer<Float> Function(Pointer<Void>)>(
  symbol: 'ls_fbx_normals',
  isLeaf: true,
)
external Pointer<Float> _normals(Pointer<Void> fbx);

@Native<Pointer<Float> Function(Pointer<Void>)>(
  symbol: 'ls_fbx_uvs',
  isLeaf: true,
)
external Pointer<Float> _uvs(Pointer<Void> fbx);

@Native<Pointer<Uint32> Function(Pointer<Void>)>(
  symbol: 'ls_fbx_triangle_materials',
  isLeaf: true,
)
external Pointer<Uint32> _triangleMaterials(Pointer<Void> fbx);

@Native<Int32 Function(Pointer<Void>)>(
  symbol: 'ls_fbx_material_count',
  isLeaf: true,
)
external int _materialCount(Pointer<Void> fbx);

@Native<Pointer<_Material> Function(Pointer<Void>, Int32)>(
  symbol: 'ls_fbx_material',
  isLeaf: true,
)
external Pointer<_Material> _material(Pointer<Void> fbx, int index);

/// A NUL-terminated string from C; bytes that aren't UTF-8 are replaced.
String _string(Pointer<Uint8> at) {
  if (at == nullptr) return '';
  var length = 0;
  while ((at + length).value != 0) {
    length++;
  }
  return utf8.decode(at.asTypedList(length), allowMalformed: true);
}

/// Reads an FBX file, binary or text, with the ufbx library: every mesh
/// in its node's transform, turned y-up, polygons cut into triangles,
/// normals (made up where the file has none), texture coordinates, and
/// each material's colour, opacity and first colour texture (a file, or an
/// image stored inside the FBX). Skins and animations are ignored: models
/// show in their rest pose.
///
/// A file over [maxPreviewTriangles] throws a [ModelTooLargeError] before
/// its triangles are copied.
ModelMesh readFbx(String path) {
  final bytes = modelFileBytes(path);
  if (bytes.isEmpty) throw const ModelReadError('Not a valid FBX file');
  final name = Uint8List.fromList([...utf8.encode(path), 0]);
  final fbx = _load(
    bytes.address,
    bytes.length,
    name.address,
    maxPreviewTriangles,
  );
  if (fbx == nullptr) throw const ModelReadError('Out of memory');
  try {
    final error = _string(_error(fbx));
    final triangles = _triangles(fbx);
    if (error == 'Too large to preview') throw ModelTooLargeError(triangles);
    if (error == 'No triangles') throw const ModelReadError('No triangles');
    if (error.isNotEmpty) {
      // ufbx's first line is "ufbx vX error: <what>"; the rest is a stack.
      final what = error.split('\n').first.split('error: ').last.trim();
      throw ModelReadError(
        what.isEmpty || what == 'Failed to load'
            ? 'Not a valid FBX file'
            : 'Not a valid FBX file ($what)',
      );
    }
    final dir = p.dirname(path);
    final images = <String, Uint8List>{};
    final count = _materialCount(fbx);
    final materials = <ModelMaterial>[];
    for (var i = 0; i < count; i++) {
      final m = _material(fbx, i).ref;
      String? texture;
      if (m.textureData != nullptr && m.textureSize > 0) {
        texture = 'image:$i';
        images[texture] = Uint8List.fromList(
          m.textureData.asTypedList(m.textureSize),
        );
      } else {
        texture = _textureFile(dir, _string(m.texture), _string(m.textureAbs));
      }
      final name = _string(m.name);
      materials.add(
        ModelMaterial(
          color: m.argb,
          name: name.isEmpty ? null : name,
          texture: texture,
          nearest: false,
          doubleSided: m.doubleSided != 0,
        ),
      );
    }
    final vertices = triangles * 3;
    final triMat = _triangleMaterials(fbx).asTypedList(triangles);
    final triangleMaterials = Uint16List(triangles);
    for (var t = 0; t < triangles; t++) {
      // The last material is the plain one.
      triangleMaterials[t] = triMat[t] < count ? triMat[t] : count - 1;
    }
    final indices = Uint32List(vertices);
    for (var i = 0; i < vertices; i++) {
      indices[i] = i;
    }
    return ModelMesh(
      positions: Float32List.fromList(
        _positions(fbx).asTypedList(vertices * 3),
      ),
      normals: Float32List.fromList(_normals(fbx).asTypedList(vertices * 3)),
      indices: indices,
      triangleMaterials: triangleMaterials,
      materials: materials,
      uvs: _hasUv(fbx) != 0
          ? Float32List.fromList(_uvs(fbx).asTypedList(vertices * 2))
          : null,
      images: images,
    );
  } finally {
    _free(fbx);
  }
}

/// Where a texture named by an FBX is: the relative name beside the
/// model, the absolute name as written (often the artist's own disk), or
/// just the file name beside the model. Null when none exists.
String? _textureFile(String dir, String relative, String absolute) {
  String clean(String s) => s.replaceAll(r'\', '/');
  final rel = clean(relative), abs = clean(absolute);
  final tries = [
    if (rel.isNotEmpty && !p.isAbsolute(rel)) p.join(dir, rel),
    if (abs.isNotEmpty && p.isAbsolute(abs)) abs,
    if (rel.isNotEmpty) p.join(dir, p.posix.basename(rel)),
    if (abs.isNotEmpty) p.join(dir, p.posix.basename(abs)),
  ];
  for (final t in tries) {
    if (File(t).existsSync()) return p.normalize(t);
  }
  return null;
}
