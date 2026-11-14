import 'package:flutter_test/flutter_test.dart';
import 'package:loot_silo/ui/widgets/file_menu.dart';

void main() {
  test('previewsAfter: cover, add and remove keep the rest in order', () {
    const now = ['a.png', 'b.png', 'c.png'];
    expect(previewsAfter(FileMenuAction.useAsCover, 'c.png', now), [
      'c.png',
      'a.png',
      'b.png',
    ]);
    expect(previewsAfter(FileMenuAction.useAsCover, 'x.png', now), [
      'x.png',
      ...now,
    ]);
    expect(previewsAfter(FileMenuAction.addPreview, 'x.png', now), [
      ...now,
      'x.png',
    ]);
    expect(previewsAfter(FileMenuAction.removePreview, 'b.png', now), [
      'a.png',
      'c.png',
    ]);
    expect(
      previewsAfter(FileMenuAction.removePreview, 'a.png', ['a.png']),
      isEmpty,
    );
  });
}
