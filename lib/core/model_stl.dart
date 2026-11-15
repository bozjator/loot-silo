import 'dart:convert';
import 'dart:typed_data';

import 'model_mesh.dart';

/// Reads an STL file, binary or text: loose triangles without colours,
/// drawn in the plain grey as flat facets. STL is written z-up; the mesh
/// is turned to y-up.
ModelMesh readStl(String path) {
  final bytes = modelFileBytes(path);
  final b = MeshBuilder()..materials.add(ModelMaterial.plain);
  void vertex(double x, double y, double z) {
    b.pos
      ..add(x)
      ..add(z)
      ..add(-y);
    // Facets: the renderer shades each triangle from its own normal.
    b.nrm
      ..add(double.nan)
      ..add(double.nan)
      ..add(double.nan);
    b.uv
      ..add(0)
      ..add(0);
  }

  void triangle() {
    final first = b.vertexCount - 3;
    b.idx
      ..add(first)
      ..add(first + 1)
      ..add(first + 2);
    b.triMat.add(0);
  }

  // A binary file is exactly its header, a count and 50 bytes a triangle
  // (some start with "solid" like a text file, so the size decides).
  if (bytes.length >= 84) {
    final data = ByteData.sublistView(bytes);
    final count = data.getUint32(80, Endian.little);
    if (bytes.length == 84 + count * 50) {
      for (var t = 0; t < count; t++) {
        final at = 84 + t * 50 + 12;
        for (var v = 0; v < 3; v++) {
          vertex(
            data.getFloat32(at + v * 12, Endian.little),
            data.getFloat32(at + v * 12 + 4, Endian.little),
            data.getFloat32(at + v * 12 + 8, Endian.little),
          );
        }
        triangle();
      }
      return b.build();
    }
  }

  final text = latin1.decode(bytes);
  if (!text.trimLeft().startsWith('solid')) {
    throw const ModelReadError('Not a valid STL file');
  }
  var inFacet = 0;
  for (final raw in LineSplitter.split(text)) {
    final line = raw.trim();
    if (line.startsWith('vertex')) {
      final parts = line.split(RegExp(r'\s+'));
      if (parts.length < 4) throw const ModelReadError('Not a valid STL file');
      final x = double.tryParse(parts[1]);
      final y = double.tryParse(parts[2]);
      final z = double.tryParse(parts[3]);
      if (x == null || y == null || z == null) {
        throw const ModelReadError('Not a valid STL file');
      }
      vertex(x, y, z);
      if (++inFacet == 3) triangle();
    } else if (line.startsWith('facet')) {
      // A facet cut short leaves its vertices unused.
      inFacet = 0;
    }
  }
  return b.build();
}
