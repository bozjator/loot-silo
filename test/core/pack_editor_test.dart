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

  test('zoom is saved as zoom and loaded back; Auto writes nothing', () {
    png('Hero/Idle.png', 128, 32);
    final detected = loadPackContents(tmp.path, [
      ('Hero/Idle.png', 1),
    ]).detected.single;
    expect(detected.zoom, isNull);
    saveAnimationOverride(tmp.path, detected, detected.copyWith(zoom: 3));
    expect(sidecarJson()['animations'], {
      'Hero/Idle.png': {'zoom': 3},
    });
    final c = loadPackContents(tmp.path, [('Hero/Idle.png', 1)]);
    expect(c.animations.single.zoom, 3);
    saveAnimationOverride(tmp.path, detected, detected.copyWith(zoom: null));
    expect(sidecarJson().containsKey('animations'), isFalse);
  });

  group('make animations from images (M28)', () {
    /// A [w]×[h] image filled with a colour derived from [shade].
    void solid(String rel, int w, int h, int shade) {
      final i = img.Image(width: w, height: h, numChannels: 4);
      img.fill(i, color: img.ColorRgba8(shade, 255 - shade, 40, 255));
      File(p.join(tmp.path, rel))
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(img.encodePng(i));
    }

    img.Image read(String rel) =>
        img.decodePng(File(p.join(tmp.path, rel)).readAsBytesSync())!;

    test('natural order: frame2 before frame10', () {
      final names = ['f10.png', 'f2.png', 'f1.png', 'F3.png'];
      expect(names..sort(naturalCompare), [
        'f1.png',
        'f2.png',
        'F3.png',
        'f10.png',
      ]);
    });

    test('the strip keeps natural order and its output size', () {
      solid('smoke/f10.png', 8, 8, 100);
      solid('smoke/f2.png', 8, 8, 50);
      solid('smoke/f1.png', 8, 8, 10);
      final r = combineFrames(tmp.path, [
        'smoke/f10.png',
        'smoke/f2.png',
        'smoke/f1.png',
      ], 'smoke/smoke_animation.png');
      expect(r, (
        path: 'smoke/smoke_animation.png',
        frameW: 8,
        frameH: 8,
        frames: 3,
      ));
      final strip = read('smoke/smoke_animation.png');
      expect((strip.width, strip.height), (24, 8));
      expect(
        [for (var i = 0; i < 3; i++) strip.getPixel(i * 8 + 4, 4).r],
        [10, 50, 100],
      );
      // The frame files stay.
      expect(File(p.join(tmp.path, 'smoke/f1.png')).existsSync(), isTrue);
    });

    test('mixed sizes are centred in the largest frame', () {
      solid('a/1.png', 4, 4, 10);
      solid('a/2.png', 8, 6, 200);
      final r = combineFrames(tmp.path, ['a/1.png', 'a/2.png'], 'a/out.png');
      expect((r.frameW, r.frameH), (8, 6));
      final strip = read('a/out.png');
      expect((strip.width, strip.height), (16, 6));
      // 4×4 centred in 8×6: x 2..5, y 1..4; the rest transparent.
      expect(strip.getPixel(0, 0).a, 0);
      expect(strip.getPixel(2, 1).r, 10);
      expect(strip.getPixel(5, 4).r, 10);
      expect(strip.getPixel(6, 1).a, 0);
      expect(strip.getPixel(8, 0).r, 200);
    });

    test('the strip is recorded as a manual animation and detected', () {
      solid('ui/a.png', 8, 6, 10);
      solid('ui/b.png', 8, 6, 20);
      combineFrames(tmp.path, ['ui/a.png', 'ui/b.png'], 'ui/ui_animation.png');
      expect(sidecarJson()['animations'], {
        'ui/ui_animation.png': {'manual': true, 'frame_w': 8, 'frame_h': 6},
      });
      final c = loadPackContents(tmp.path, [
        ('ui/a.png', 1),
        ('ui/b.png', 1),
        ('ui/ui_animation.png', 1),
      ]);
      final a = c.animations.singleWhere(
        (a) => a.path == 'ui/ui_animation.png',
      );
      expect((a.frameW, a.frameH, a.frameCount), (8, 6, 2));
    });

    test('output names: folder, root, numbered when taken', () {
      expect(
        combinedName(['fx/Black smoke/b2.png', 'fx/Black smoke/b1.png']),
        'fx/Black smoke/Black smoke_animation.png',
      );
      expect(combinedName(['b.png', 'a.png']), 'animation.png');
      expect(
        combinedName(
          ['x/1.png', 'x/2.png'],
          taken: {'x/x_animation.png', 'x/x_animation_2.png'},
          unique: true,
        ),
        'x/x_animation_3.png',
      );
      // Without unique the caller asks before overwriting.
      expect(
        combinedName(['x/1.png'], taken: {'x/x_animation.png'}),
        'x/x_animation.png',
      );
    });

    test('Make animation: a manual mark turns a plain image into a strip', () {
      solid('ui/panel.png', 64, 16, 10);
      solid('ui/button.png', 30, 16, 10);
      List<SpriteAnim> anims() => loadPackContents(tmp.path, [
        ('ui/panel.png', 1),
        ('ui/button.png', 1),
      ]).animations;
      expect(anims(), isEmpty, reason: 'UI words are not animations');
      final guess = guessStrip('ui/panel.png', 64, 16);
      expect((guess.frameW, guess.cols), (16, 4));
      expect(guessStrip('ui/button.png', 30, 16).cols, 1);
      saveAnimationOverride(tmp.path, guess, guess, manual: true);
      expect(sidecarJson()['animations'], {
        'ui/panel.png': {'manual': true},
      });
      expect(anims().single.frameCount, 4);
      // Later edits keep the mark; reset drops it.
      saveAnimationOverride(tmp.path, guess, guess.copyWith(fps: 6));
      expect(sidecarJson()['animations'], {
        'ui/panel.png': {'manual': true, 'fps': 6.0},
      });
      saveAnimationOverride(tmp.path, guess, null);
      expect(anims(), isEmpty);
    });
  });
}
