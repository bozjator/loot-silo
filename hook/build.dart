import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

/// Compiles the app's own C code into the bundle:
/// - `native/model_raster.c`, the 3D model renderer bound by
///   `lib/core/model_raster.dart`;
/// - `native/fbx_reader.c` with the ufbx library (`native/ufbx/`), the FBX
///   reader bound by `lib/core/model_fbx.dart`.
void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;
    await CBuilder.library(
      name: 'model_raster',
      assetName: 'core/model_raster.dart',
      sources: ['native/model_raster.c'],
      libraries: [if (input.config.code.targetOS != OS.windows) 'm'],
    ).run(input: input, output: output);
    await CBuilder.library(
      name: 'model_fbx',
      assetName: 'core/model_fbx.dart',
      sources: ['native/fbx_reader.c', 'native/ufbx/ufbx.c'],
      includes: ['native'],
      libraries: [if (input.config.code.targetOS != OS.windows) 'm'],
    ).run(input: input, output: output);
  });
}
