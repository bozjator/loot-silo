import 'package:loot_silo/core/fs_tree.dart';
import 'package:loot_silo/core/preview_picker.dart';
import 'package:loot_silo/core/sidecar.dart';
import 'package:flutter_test/flutter_test.dart';

List<(String, FileEntry)> files(Map<String, int> m) => [
  for (final e in m.entries) (e.key, FileEntry(e.key.split('/').last, e.value)),
];

void main() {
  test('the first chosen preview that exists wins', () {
    final f = files({'Preview.png': 9, 'art/hero.png': 1, 'b.png': 1});
    expect(
      pickPreview(
        f,
        sidecar: const PackSidecar(previews: ['art/hero.png', 'b.png']),
      ),
      'art/hero.png',
    );
    expect(
      pickPreview(
        f,
        sidecar: const PackSidecar(previews: ['gone.png', 'b.png']),
      ),
      'b.png',
    );
    expect(
      pickPreview(f, sidecar: const PackSidecar(previews: ['gone.png'])),
      'Preview.png',
    );
  });

  test('the largest-image fallback skips texture maps', () {
    // A Renderpeople pack: the render beside its (much bigger) maps.
    final f = files({
      'rp_nathan_walking_A.jpg': 118,
      'tex/rp_nathan_dif.jpg': 5293,
      'tex/rp_nathan_gloss.jpg': 13314,
      'tex/rp_nathan_mask01.jpg': 2205,
      'tex/rp_nathan_norm.jpg': 11737,
    });
    expect(pickPreview(f), 'rp_nathan_walking_A.jpg');
    // Only maps: the largest still stands in.
    expect(
      pickPreview(files({'a_gloss.png': 9, 'a_norm.png': 3})),
      'a_gloss.png',
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

  test('preview candidates: numbered mockups count, ranked and in order', () {
    final c = previewCandidates([
      'mockups/mockup10.png',
      'mockups/mockup2.png',
      'mockups/mockup1.gif',
      'tiles/grass.png',
      'preview.png',
      '_itch/screenshot1.png',
      'promo/coupon_preview.png',
      'All_sheet.png',
      'samples/forest.png',
    ]);
    expect(c, [
      '_itch/screenshot1.png',
      'preview.png',
      'mockups/mockup1.gif',
      'mockups/mockup2.png',
      'mockups/mockup10.png',
      'All_sheet.png',
      'samples/forest.png',
    ]);
  });
}
