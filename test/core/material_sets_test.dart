import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:loot_silo/core/fs_tree.dart';
import 'package:loot_silo/core/material_sets.dart';
import 'package:loot_silo/core/pack_editor.dart';
import 'package:loot_silo/core/type_classifier.dart';
import 'package:loot_silo/state/settings.dart';
import 'package:path/path.dart' as p;

/// The `.mtlx` ambientCG ships, trimmed to the parts the reader looks at.
String ambientMtlx(String name, String ext) =>
    '''
<?xml version="1.0"?>
<materialx version="1.39" fileprefix="./">
  <open_pbr_surface type="surfaceshader" name="${name}_OpenPbrSurface">
    <input type="color3" nodename="${name}_Color" name="base_color" />
    <input type="vector3" nodename="NormalMap" name="geometry_normal" />
    <input type="float" nodename="${name}_Roughness" name="specular_roughness" />
  </open_pbr_surface>
  <surfacematerial type="material" name="$name">
    <input type="surfaceshader" nodename="${name}_OpenPbrSurface" name="surfaceshader" />
    <input type="displacementshader" nodename="displacement" name="displacementshader" />
  </surfacematerial>
  <tiledimage type="color3" name="${name}_Color">
    <input type="filename" value="${name}_Color.$ext" name="file" colorspace="srgb_texture" />
  </tiledimage>
  <tiledimage type="float" name="${name}_Displacement">
    <input type="filename" value="${name}_Displacement.$ext" name="file" />
  </tiledimage>
  <displacement type="displacementshader" name="displacement">
    <input type="float" nodename="${name}_Displacement" name="displacement" />
  </displacement>
  <tiledimage type="vector3" name="${name}_NormalGL">
    <input type="filename" value="${name}_NormalGL.$ext" name="file" />
  </tiledimage>
  <normalmap type="vector3" name="NormalMap">
    <input type="vector3" nodename="${name}_NormalGL" name="in" />
  </normalmap>
  <tiledimage type="float" name="${name}_Roughness">
    <input type="filename" value="${name}_Roughness.$ext" name="file" />
  </tiledimage>
</materialx>
''';

/// An ambientCG download as it unpacks (`PavingStones138_1K-JPG`).
List<String> ambientFiles(String name, String tag, String ext) => [
  for (final m in [
    'AmbientOcclusion',
    'Color',
    'Displacement',
    'NormalDX',
    'NormalGL',
    'Roughness',
  ])
    '${name}_${tag}_$m.$ext',
  '${name}_$tag.blend',
  '${name}_$tag.mtlx',
  '${name}_$tag.tres',
  '${name}_$tag.usdc',
  '$name.png',
];

Map<String, MapRole> rolesOf(MaterialSet m) => {
  for (final map in m.maps) map.path: map.role,
};

void main() {
  test('both ambientCG layouts: one material with six maps', () {
    for (final (tag, ext) in [('1K-JPG', 'jpg'), ('1K-PNG', 'png')]) {
      final files = ambientFiles('PavingStones138', tag, ext);
      final (sets, rest) = groupMaterials(
        files,
        mtlx: {
          'PavingStones138_$tag.mtlx': ambientMtlx('PavingStones138_$tag', ext),
        },
      );
      expect(rest, isEmpty);
      expect(sets, hasLength(1));
      final m = sets.single;
      expect(m.key, 'PavingStones138');
      expect(m.name, 'PavingStones138');
      expect(m.resolution, '1K');
      expect(m.preview, 'PavingStones138.png');
      expect(m.toolFiles, [
        'PavingStones138_$tag.blend',
        'PavingStones138_$tag.mtlx',
        'PavingStones138_$tag.tres',
        'PavingStones138_$tag.usdc',
      ]);
      expect(
        [for (final x in m.maps) x.role],
        [
          MapRole.color,
          MapRole.normalGL,
          MapRole.normalDX,
          MapRole.roughness,
          MapRole.ao,
          MapRole.height,
        ],
      );
      expect(m.pictures.first, 'PavingStones138.png');
      expect(materialTitle(m.name), 'Paving Stones 138');
    }
  });

  test('Poly Haven style, with a packed ARM map and the tag at the end', () {
    final (sets, rest) = groupMaterials([
      'rock_wall/rock_wall_diff_1k.jpg',
      'rock_wall/rock_wall_nor_gl_1k.jpg',
      'rock_wall/rock_wall_rough_1k.jpg',
      'rock_wall/rock_wall_arm_1k.jpg',
      'rock_wall/rock_wall.blend',
    ]);
    expect(rest, isEmpty);
    final m = sets.single;
    expect(m.key, 'rock_wall/rock_wall');
    expect(m.folder, 'rock_wall');
    expect(m.resolution, '1K');
    expect(m.preview, isNull);
    expect(m.color, 'rock_wall/rock_wall_diff_1k.jpg');
    expect(rolesOf(m).values, [
      MapRole.color,
      MapRole.normalGL,
      MapRole.roughness,
      MapRole.packed,
    ]);
    expect(m.toolFiles, ['rock_wall/rock_wall.blend']);
  });

  test('Substance style, camelCase with no separator', () {
    final (sets, rest) = groupMaterials([
      'Wood_BaseColor.png',
      'Wood_Normal.png',
      'Wood_Metallic.png',
      'WoodRoughness.png',
      'Protocol.png',
      'Wood_preview.png',
    ]);
    expect(rest, ['Protocol.png']);
    final m = sets.single;
    expect(m.name, 'Wood');
    expect(m.preview, 'Wood_preview.png');
    expect(rolesOf(m), {
      'Wood_BaseColor.png': MapRole.color,
      'Wood_Normal.png': MapRole.normalGL,
      'Wood_Metallic.png': MapRole.metalness,
      'WoodRoughness.png': MapRole.roughness,
    });
  });

  test('several materials in one folder and in sub-folders', () {
    final (sets, rest) = groupMaterials([
      'Bricks_Color.png',
      'Bricks_Normal.png',
      'Tiles_Color.png',
      'Tiles_Roughness.png',
      'stone/Granite_Albedo.jpg',
      'stone/Granite_Height.jpg',
      'stone/Marble_Albedo.jpg',
      'stone/Marble_AO.jpg',
      'hero.png',
    ]);
    expect(
      [for (final m in sets) m.key],
      ['Bricks', 'stone/Granite', 'stone/Marble', 'Tiles'],
    );
    expect(rest, ['hero.png']);
  });

  test(
    'a lone normal map, or two maps without Color / Normal, stay images',
    () {
      final files = [
        'hero_normal.png',
        'hero.png',
        'rock_rough.png',
        'rock_ao.png',
      ];
      final (sets, rest) = groupMaterials(files);
      expect(sets, isEmpty);
      expect(rest, files);
    },
  );

  test('a .mtlx names a map with an odd name, and gives its role', () {
    const xml = '''
<materialx version="1.38">
  <nodegraph name="NG">
    <image name="img_a" type="color3">
      <input name="file" type="filename" value="textures/ground_A.png" />
    </image>
    <image name="img_b" type="vector3">
      <input name="file" type="filename" value="textures/bumpy thing.png" />
    </image>
    <normalmap name="nm" type="vector3">
      <input name="in" type="vector3" nodename="img_b" />
    </normalmap>
  </nodegraph>
  <standard_surface name="SR" type="surfaceshader">
    <input name="base_color" type="color3" nodename="img_a" />
    <input name="normal" type="vector3" nodename="nm" />
  </standard_surface>
</materialx>''';
    expect(readMtlxMaps(xml), [
      ('textures/ground_A.png', MapRole.color),
      ('textures/bumpy thing.png', MapRole.normalGL),
    ]);
    final (sets, rest) = groupMaterials(
      [
        'Ground/Ground.mtlx',
        'Ground/textures/ground_A.png',
        'Ground/textures/bumpy thing.png',
        'Ground/other.png',
      ],
      mtlx: {'Ground/Ground.mtlx': xml},
    );
    final m = sets.single;
    expect(m.key, 'Ground/Ground');
    expect(rolesOf(m), {
      'Ground/textures/ground_A.png': MapRole.color,
      'Ground/textures/bumpy thing.png': MapRole.normalGL,
    });
    expect(m.toolFiles, ['Ground/Ground.mtlx']);
    expect(rest, ['Ground/other.png']);
  });

  test('materialTitle splits camelCase and numbers', () {
    expect(materialTitle('rock_wall'), 'Rock wall');
    expect(materialTitle('WoodFloor041'), 'Wood Floor 041');
  });

  test('the classifier adds `material`, alone or beside the rest', () {
    (String, FileEntry) f(String rel) => (rel, FileEntry(p.basename(rel), 10));
    final only = [
      for (final r in ambientFiles('Bricks01', '2K-JPG', 'jpg')) f(r),
    ];
    expect(classifyPack('Bricks01', only), [AssetType.material]);
    final mixed = [
      ...only,
      f('characters/knight.png'),
      f('characters/orc.png'),
    ];
    expect(classifyPack('Stuff', mixed), [
      AssetType.character,
      AssetType.material,
    ]);
    expect(classifyPack('Stuff', [f('a.png')]), [AssetType.misc]);
  });

  group('loadPackContents', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('materials'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('maps and previews leave Images, tool files leave Other files', () {
      final files = [
        ...ambientFiles('Paving', '1K-PNG', 'png'),
        'hero.png',
        'readme.txt',
      ];
      for (final rel in files) {
        File(p.join(tmp.path, rel)).writeAsStringSync('x');
      }
      File(p.join(tmp.path, 'Paving_1K-PNG.mtlx'))
          .writeAsStringSync(ambientMtlx('Paving_1K-PNG', 'png'));
      final c = loadPackContents(tmp.path, [for (final f in files) (f, 1)]);
      expect(c.images, ['hero.png']);
      expect(c.other, ['readme.txt']);
      expect(c.models, isEmpty);
      expect(c.materials.single.key, 'Paving');
      expect(c.materials.single.maps, hasLength(6));
      expect(c.matching(['roughness']).materials, hasLength(1));
      expect(c.matching(['paving']).materials, hasLength(1));
      expect(c.matching(['hero']).materials, isEmpty);
      expect(c.only({'Paving'}).materials, hasLength(1));
      expect(c.only({'hero.png'}).materials, isEmpty);
      expect(c.within('sub').materials, isEmpty);
      expect(c.only({'Paving'}).isEmpty, isFalse);
    });
  });

  test('material_thumb_size and materials_view round-trip; defaults', () {
    const fresh = AppSettings();
    expect(fresh.materialsView, ItemsView.flat);
    expect(fresh.materialThumbSize, 200);
    final json = fresh
        .copyWith(materialsView: ItemsView.folders, materialThumbSize: 320)
        .toJson();
    expect(json['material_thumb_size'], 320);
    expect(json['materials_view'], 'folders');
    final back = AppSettings.fromJson(json);
    expect(back.materialsView, ItemsView.folders);
    expect(back.materialThumbSize, 320);
    expect(AppSettings.fromJson(const {}).materialsView, ItemsView.flat);
  });

  const library = '../assets_library';
  test(
    'the real library holds exactly the two paving materials (read-only)',
    skip: Directory(library).existsSync() ? false : 'no $library',
    () {
      final found = <String>{};
      final sw = Stopwatch();
      var scanned = 0;
      for (final e in Directory(library).listSync(recursive: true)) {
        if (e is! File || p.basename(e.path) != 'asset_pack.json') continue;
        final pack = e.parent.path;
        final files = <(String, int)>[
          for (final f in Directory(pack).listSync(recursive: true))
            if (f is File) (p.relative(f.path, from: pack), 0),
        ];
        scanned += files.length;
        final mtlx = readMtlxFiles(pack, files);
        sw.start();
        final (sets, _) = groupMaterials([
          for (final (rel, _) in files) rel,
        ], mtlx: mtlx);
        sw.stop();
        for (final m in sets) {
          expect(m.maps, hasLength(6), reason: m.toString());
          found.add('${p.basename(pack)}: ${m.key}');
        }
      }
      // ignore: avoid_print
      print('grouped $scanned files in ${sw.elapsedMilliseconds} ms');
      expect(found, {
        'PavingStones138_1K-JPG: PavingStones138',
        'PavingStones152_1K-PNG: PavingStones152',
      });
    },
  );
}
