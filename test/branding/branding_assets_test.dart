import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:loot_silo/ui/widgets/branding.dart';

img.Image load(String path) {
  final file = File(path);
  expect(file.existsSync(), isTrue, reason: path);
  final image = img.decodePng(file.readAsBytesSync());
  expect(image, isNotNull, reason: path);
  expect(image!.hasAlpha, isTrue, reason: '$path has an alpha channel');
  return image;
}

void main() {
  test('the app icon is a cut-out rounded square', () {
    for (final path in [Branding.iconFull, Branding.iconSmall]) {
      final icon = load(path);
      expect(icon.width, icon.height, reason: path);
      final last = icon.width - 1;
      for (final (x, y) in [(0, 0), (last, 0), (0, last), (last, last)]) {
        expect(icon.getPixel(x, y).a, 0, reason: '$path corner ($x, $y)');
      }
      final c = icon.width ~/ 2;
      expect(icon.getPixel(c, c).a, 255, reason: '$path centre');
      // The edge midpoints are inside the square (only corners are cut).
      expect(icon.getPixel(c, 3).a, greaterThan(200), reason: '$path top');
    }
    expect(load(Branding.iconFull).width, 512);
  });

  test('the small sizes and the platform icons exist', () {
    for (final s in [16, 24, 32, 48, 64]) {
      expect(load('assets/branding/icon_small_$s.png').width, s);
    }
    expect(load('assets/branding/icon_full_1024.png').width, 1024);
    expect(load('linux/runner/resources/app_icon.png').width, 256);
    expect(File('windows/runner/resources/app_icon.ico').existsSync(), isTrue);
    expect(
      File('linux/runner/resources/dev.uzo.loot_silo.desktop')
          .readAsStringSync(),
      contains('Name=Loot Silo'),
    );
  });

  test('the README logo is the lockup: trimmed, transparent, wide', () {
    final logo = load(Branding.logoReadme);
    expect(logo.width, greaterThan(logo.height * 3));
    bool any(Iterable<(int, int)> pixels) =>
        pixels.any((p) => logo.getPixel(p.$1, p.$2).a > 8);
    final w = logo.width, h = logo.height;
    // Trimmed: something on every edge.
    expect(any([for (var x = 0; x < w; x++) (x, 0)]), isTrue);
    expect(any([for (var x = 0; x < w; x++) (x, h - 1)]), isTrue);
    expect(any([for (var y = 0; y < h; y++) (0, y)]), isTrue);
    expect(any([for (var y = 0; y < h; y++) (w - 1, y)]), isTrue);
    // Transparent around the icon's rounded corner and right of the text.
    expect(logo.getPixel(0, 0).a, 0);
    expect(logo.getPixel(w - 1, h - 1).a, 0);
    // The app icon's silo on the left: the same picture as icon_small.
    final small = img.copyResize(
      load('assets/branding/icon_small_256.png'),
      width: h,
      height: h,
    );
    final mid = logo.getPixel(h ~/ 2, h ~/ 2);
    final ref = small.getPixel(h ~/ 2, h ~/ 2);
    expect((mid.r - ref.r).abs(), lessThan(24));
    expect((mid.g - ref.g).abs(), lessThan(24));
    expect((mid.b - ref.b).abs(), lessThan(24));
  });

  test('the old gamepad logo is gone; the lockup icon is bundled', () {
    expect(File('assets/branding/logo_wide.png').existsSync(), isFalse);
    final pubspec = File('pubspec.yaml').readAsStringSync();
    expect(pubspec, contains(Branding.iconLarge));
    expect(pubspec, isNot(contains('logo_wide')));
    expect(load(Branding.iconLarge).width, 256);
    expect(File('README.md').readAsStringSync(), contains(Branding.logoReadme));
  });
}
