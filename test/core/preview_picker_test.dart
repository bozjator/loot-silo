import 'package:assets_explorer/core/fs_tree.dart';
import 'package:assets_explorer/core/preview_picker.dart';
import 'package:assets_explorer/core/sidecar.dart';
import 'package:flutter_test/flutter_test.dart';

List<(String, FileEntry)> files(Map<String, int> m) => [
  for (final e in m.entries) (e.key, FileEntry(e.key.split('/').last, e.value)),
];

void main() {
  test('sidecar cover wins when the file exists', () {
    final f = files({'Preview.png': 9, 'art/hero.png': 1});
    expect(
      pickPreview(f, sidecar: const PackSidecar(cover: 'art/hero.png')),
      'art/hero.png',
    );
    expect(
      pickPreview(f, sidecar: const PackSidecar(cover: 'gone.png')),
      'Preview.png',
    );
  });

  test('itch cover beats named previews', () {
    final f = files({
      'Preview.png': 9,
      '_itch/screenshot1.png': 5,
      '_itch/cover.png': 1,
    });
    expect(pickPreview(f), '_itch/cover.png');
  });

  test('preview beats sample regardless of size; promo images are skipped', () {
    expect(
      pickPreview(files({'Sample.png': 900, 'Preview.png': 10})),
      'Preview.png',
    );
    expect(
      pickPreview(files({'COUPON.png': 900, 'PNG/craft.png': 10})),
      'PNG/craft.png',
    );
    expect(pickPreview(files({'patreon_logo.png': 900, 'a.png': 1})), 'a.png');
  });

  test('preview folders count; file names rank above folder names', () {
    expect(
      pickPreview(files({'Mockups/scene1.png': 50, 'tiles.png': 900})),
      'Mockups/scene1.png',
    );
    expect(
      pickPreview(files({'mockups/a.png': 50, 'mockup.png': 1})),
      'mockup.png',
    );
  });

  test('all-sheets and static previews are preferred over gifs', () {
    expect(
      pickPreview(files({'Wolf/All-Spritesheet.png': 5, 'big.png': 99})),
      'Wolf/All-Spritesheet.png',
    );
    expect(
      pickPreview(files({'preview.gif': 99, 'preview.png': 1})),
      'preview.png',
    );
    expect(pickPreview(files({'walk.gif': 1, 'big.png': 99})), 'walk.gif');
  });

  test('falls back to the largest shallow image', () {
    final f = files({'a.png': 10, 'b/c.png': 30, 'b/c/d/e.png': 999});
    expect(pickPreview(f), 'b/c.png');
    expect(pickPreview(files({'x/y/z/deep.png': 1})), 'x/y/z/deep.png');
  });

  test('no image, no preview', () {
    expect(
      pickPreview(files({'a.ogg': 1, 'b.psd': 1, 'c.aseprite': 1})),
      isNull,
    );
  });
}
