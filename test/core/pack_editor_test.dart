import 'dart:convert';
import 'dart:io';

import 'package:assets_explorer/core/animation_detector.dart';
import 'package:assets_explorer/core/pack_editor.dart';
import 'package:assets_explorer/core/sidecar.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('editor'));
  tearDown(() => tmp.deleteSync(recursive: true));

  void png(String rel, int w, int h) {
    final f = File(p.join(tmp.path, rel))..parent.createSync(recursive: true);
    f.writeAsBytesSync(img.encodePng(img.Image(width: w, height: h)));
  }

  Map<String, Object?> sidecarJson() =>
      jsonDecode(File(p.join(tmp.path, packFileName)).readAsStringSync())
          as Map<String, Object?>;

  test('loadPackContents splits files and detects animations', () {
    png('Hero/Idle.png', 128, 32);
    png('preview.png', 200, 150);
    png('_itch/cover.png', 315, 250);
    png('tiles.png', 64, 64);
    final files = [
      ('Hero/Idle.png', 10),
      ('_itch/cover.png', 30),
      ('preview.png', 20),
      ('sfx/hit.wav', 5),
      ('license.txt', 1),
      ('src/hero.psd', 3),
      ('tiles.png', 7),
    ];
    final c = loadPackContents(tmp.path, files);
    expect(c.images, [
      'Hero/Idle.png',
      '_itch/cover.png',
      'preview.png',
      'tiles.png',
    ]);
    expect(c.audio, ['sfx/hit.wav']);
    expect(c.other, ['license.txt', 'src/hero.psd'], reason: 'PSD is not shown');
    expect(c.sizes['preview.png'], 20);
    expect(c.animations.single.path, 'Hero/Idle.png');
    expect(c.carousel('preview.png'), ['preview.png', '_itch/cover.png']);
    expect(c.carousel(null), ['_itch/cover.png', 'preview.png']);
  });

  test('updatePackSidecar keeps other keys and can clear the title', () {
    File(p.join(tmp.path, packFileName)).writeAsStringSync(
      jsonEncode({
        'title': 'Old',
        'types': ['character'],
        'source': 'imported',
        'animations': {
          'a.png': {'fps': 4},
        },
        'custom_key': 42,
      }),
    );
    updatePackSidecar(tmp.path, tags: ['orc', 'pixel']);
    var json = sidecarJson();
    expect(json['title'], 'Old');
    expect(json['tags'], ['orc', 'pixel']);
    expect(json['types'], ['character']);
    expect(json['custom_key'], 42);
    expect(json['animations'], {
      'a.png': {'fps': 4},
    });

    updatePackSidecar(tmp.path, title: '  ', types: ['vfx']);
    json = sidecarJson();
    expect(json.containsKey('title'), isFalse);
    expect(json['types'], ['vfx']);
    expect(json['source'], 'imported');
  });

  test('updatePackSidecar creates a sidecar when missing', () {
    updatePackSidecar(tmp.path, title: 'New name');
    expect(sidecarJson(), {'title': 'New name'});
  });

  test('saveAnimationOverride stores only what differs, null removes', () {
    const detected = SpriteAnim(
      path: 'Hero/Idle.png',
      kind: AnimKind.sheet,
      frameW: 32,
      frameH: 32,
      cols: 4,
    );
    saveAnimationOverride(tmp.path, detected, detected.copyWith(fps: 6));
    expect(sidecarJson()['animations'], {
      'Hero/Idle.png': {'fps': 6.0},
    });

    saveAnimationOverride(
      tmp.path,
      detected,
      detected.copyWith(frameW: 64, fps: 10),
    );
    expect(sidecarJson()['animations'], {
      'Hero/Idle.png': {'frame_w': 64},
    });
    // The override round-trips through loadPackContents.
    png('Hero/Idle.png', 128, 32);
    final c = loadPackContents(tmp.path, [('Hero/Idle.png', 1)]);
    expect(c.detected.single.frameW, 32);
    expect(c.animations.single.frameW, 64);
    expect(c.animations.single.cols, 2);

    saveAnimationOverride(tmp.path, detected, null);
    expect(sidecarJson().containsKey('animations'), isFalse);
  });
}
