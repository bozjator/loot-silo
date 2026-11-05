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
    expect(c.other, [
      'license.txt',
      'src/hero.psd',
    ], reason: 'PSD is not shown');
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

    // A total frame count is stored as `frames`; the width follows.
    saveAnimationOverride(tmp.path, detected, detected.withFrameCount(2));
    expect(sidecarJson()['animations'], {
      'Hero/Idle.png': {'frames': 2},
    });
    final f = loadPackContents(tmp.path, [('Hero/Idle.png', 1)]);
    expect(f.animations.single.frameW, 64);
    expect(f.animations.single.frameCount, 2);

    saveAnimationOverride(tmp.path, detected, null);
    expect(sidecarJson().containsKey('animations'), isFalse);
  });

  test('PackContents.matching keeps only matching files and animations', () {
    const seq = SpriteAnim(
      path: 'fx/smoke_1.png',
      kind: AnimKind.sequence,
      frameW: 8,
      frameH: 8,
      frames: ['fx/smoke_1.png', 'fx/smoke_2.png'],
    );
    const sheet = SpriteAnim(
      path: 'hero/idle.png',
      kind: AnimKind.sheet,
      frameW: 8,
      frameH: 8,
      cols: 4,
    );
    const c = PackContents(
      images: ['fx/smoke_1.png', 'hero/idle.png', 'props/barrels_0.png'],
      audio: ['sfx/barrel_roll.wav', 'sfx/hit.wav'],
      other: ['README.txt'],
      detected: [seq, sheet],
      sizes: {},
      sidecar: null,
    );
    final m = c.matching(['barrel']);
    expect(m.images, ['props/barrels_0.png']);
    expect(m.audio, ['sfx/barrel_roll.wav']);
    expect(m.other, isEmpty);
    expect(m.detected, isEmpty);
    expect(c.matching(['smoke']).detected, [seq]);
    expect(c.matching(['idle']).detected, [sheet]);
    expect(c.matching(['arrel'], infix: true).images, ['props/barrels_0.png']);
    expect(c.matching(['arrel']).images, isEmpty);
  });

  test('the row choice is saved as rows: all or a 1-based number', () {
    png('fx/Explosion(32x32).png', 64, 64);
    final detected = loadPackContents(tmp.path, [
      ('fx/Explosion(32x32).png', 1),
    ]).detected.single;
    expect(detected.rows, greaterThan(1));
    saveAnimationOverride(
      tmp.path,
      detected,
      detected.copyWith(playRow: SpriteAnim.allRows),
    );
    expect(sidecarJson()['animations'], {
      'fx/Explosion(32x32).png': {'rows': 'all'},
    });
    final c = loadPackContents(tmp.path, [('fx/Explosion(32x32).png', 1)]);
    expect(c.animations.single.rowToPlay, isNull);
    saveAnimationOverride(tmp.path, detected, detected.copyWith(playRow: 1));
    expect(sidecarJson()['animations'], {
      'fx/Explosion(32x32).png': {'rows': 2},
    });
    // Row 0 is the default, so it isn't written.
    saveAnimationOverride(tmp.path, detected, detected.copyWith(playRow: 0));
    expect(sidecarJson().containsKey('animations'), isFalse);
  });

  test('"Not an animation" moves a file to the images only and back', () {
    png('Hero/Idle.png', 128, 32);
    for (var i = 1; i <= 3; i++) {
      png('fx/smoke_$i.png', 16, 16);
    }
    final files = [
      ('Hero/Idle.png', 1),
      for (var i = 1; i <= 3; i++) ('fx/smoke_$i.png', 1),
    ];
    final before = loadPackContents(tmp.path, files);
    expect(before.animations.map((a) => a.path).toSet(), {
      'Hero/Idle.png',
      'fx/smoke_1.png',
    });
    // A sheet and a numbered sequence.
    setNotAnimation(tmp.path, 'Hero/Idle.png');
    setNotAnimation(tmp.path, 'fx/smoke_1.png');
    expect(sidecarJson()['animations'], {
      'Hero/Idle.png': false,
      'fx/smoke_1.png': false,
    });
    final hidden = loadPackContents(tmp.path, files);
    expect(hidden.animations, isEmpty);
    expect(hidden.shownDetected, isEmpty);
    expect(hidden.hiddenAnimations.map((a) => a.path).toSet(), {
      'Hero/Idle.png',
      'fx/smoke_1.png',
    });
    expect(hidden.images, contains('Hero/Idle.png'));
    expect(hidden.images, contains('fx/smoke_2.png'));

    // Restore drops the override entirely.
    setNotAnimation(tmp.path, 'Hero/Idle.png', hidden: false);
    setNotAnimation(tmp.path, 'fx/smoke_1.png', hidden: false);
    expect(sidecarJson().containsKey('animations'), isFalse);
    final back = loadPackContents(tmp.path, files);
    expect(back.animations.length, 2);
    expect(back.hiddenAnimations, isEmpty);
  });

  test('detectAnimations and the preview skip files marked false', () {
    png('Hero/Idle.png', 128, 32);
    final all = detectAnimations(tmp.path, ['Hero/Idle.png']);
    expect(all, isNotEmpty);
    final none = detectAnimations(
      tmp.path,
      ['Hero/Idle.png'],
      overrides: {'Hero/Idle.png': false},
    );
    expect(none, isEmpty);
    final chosen = choosePreviewAnimation(
      tmp.path,
      ['Hero/Idle.png'],
      preview: 'Hero/Idle.png',
      rank: 6,
      overrides: {'Hero/Idle.png': false},
    );
    expect(chosen.anim, isNull);
  });
}
