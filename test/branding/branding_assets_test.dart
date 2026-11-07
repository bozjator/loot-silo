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

  test('the wide logo is trimmed: something on every edge', () {
    final logo = load(Branding.logoWide);
    expect(logo.width, greaterThan(logo.height * 2));
    bool any(Iterable<(int, int)> pixels) =>
        pixels.any((p) => logo.getPixel(p.$1, p.$2).a > 8);
    final w = logo.width, h = logo.height;
    expect(any([for (var x = 0; x < w; x++) (x, 0)]), isTrue);
    expect(any([for (var x = 0; x < w; x++) (x, h - 1)]), isTrue);
    expect(any([for (var y = 0; y < h; y++) (0, y)]), isTrue);
    expect(any([for (var y = 0; y < h; y++) (w - 1, y)]), isTrue);
    // Transparent background (a corner).
    expect(logo.getPixel(0, 0).a, 0);
    // No stray speck of the neighbouring art: no empty column or row
    // between an edge and the logo itself.
    bool column(int x) => any([for (var y = 0; y < h; y++) (x, y)]);
    bool row(int y) => any([for (var x = 0; x < w; x++) (x, y)]);
    expect([for (var x = 0; x < w; x++) column(x)], everyElement(isTrue));
    expect([for (var y = 0; y < h; y++) row(y)], everyElement(isTrue));
  });
}
