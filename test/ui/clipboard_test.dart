import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:loot_silo/ui/clipboard.dart';
import 'package:loot_silo/ui/widgets/file_menu.dart';
import 'package:path/path.dart' as p;

class _Caps implements FileClipboard {
  _Caps(this.linux);
  final bool linux;
  @override
  bool get canCopyFiles => linux;
  @override
  bool get canOpenWith => linux;
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('clip'));
  tearDown(() => tmp.deleteSync(recursive: true));

  group('pngBytesOf', () {
    final picture = img.Image(width: 7, height: 5, numChannels: 4);

    test('a PNG is passed on as it is', () {
      final bytes = img.encodePng(picture);
      final f = File(p.join(tmp.path, 'a.png'))..writeAsBytesSync(bytes);
      expect(pngBytesOf(f.path), bytes);
    });

    test('other formats become a PNG of the same size', () {
      for (final (name, bytes) in [
        ('a.bmp', img.encodeBmp(picture)),
        ('a.jpg', img.encodeJpg(picture)),
        ('a.gif', img.encodeGif(picture)),
      ]) {
        final f = File(p.join(tmp.path, name))..writeAsBytesSync(bytes);
        final png = img.decodePng(pngBytesOf(f.path)!)!;
        expect((png.width, png.height), (7, 5), reason: name);
      }
    });

    test('not an image: null', () {
      final f = File(p.join(tmp.path, 'a.txt'))..writeAsStringSync('hello');
      expect(pngBytesOf(f.path), isNull);
    });
  });

  test('GIF file names are safe', () {
    expect(gifFileName('Explosion(16x16)'), 'Explosion(16x16)');
    expect(gifFileName('a/b:c'), 'a_b_c');
    expect(gifFileName('  '), 'animation');
  });

  test('menu items: only what applies, in order', () {
    const one = FileMenuTarget(
      files: ['/a.png'],
      image: '/a.png',
      open: '/a.png',
    );
    const many = FileMenuTarget(files: ['/a.png', '/b.png']);
    const fileItems = [
      FileMenuAction.copyImage,
      FileMenuAction.copyFiles,
      FileMenuAction.copyPath,
      FileMenuAction.open,
      FileMenuAction.openWith,
    ];
    expect(fileMenuActions(one, _Caps(true)), fileItems);
    // An animation puts the two GIF items first (M75).
    final anim = FileMenuTarget(
      files: const ['/a.png'],
      image: '/a.png',
      open: '/a.png',
      gif: (name: 'a', make: () async => null),
    );
    expect(fileMenuActions(anim, _Caps(true)), [
      FileMenuAction.copyGif,
      FileMenuAction.copyGifFile,
      ...fileItems,
    ]);
    // A pack's image: the cover / previews items last, as they apply.
    const asPreview = FileMenuTarget(
      files: ['/a.png'],
      open: '/a.png',
      preview: PreviewTarget(
        packId: 'x',
        packPath: '/',
        preview: 'b.png',
        file: 'a.png',
      ),
    );
    List<FileMenuAction> previewItems(List<String>? previews) => [
      ...fileMenuActions(asPreview, _Caps(false), previews: previews).skip(2),
    ];
    expect(previewItems(['b.png']), [
      FileMenuAction.useAsCover,
      FileMenuAction.addPreview,
    ]);
    expect(previewItems(['b.png', 'a.png']), [
      FileMenuAction.useAsCover,
      FileMenuAction.removePreview,
    ]);
    expect(previewItems(['a.png', 'b.png']), [FileMenuAction.removePreview]);
    // Still loading: none.
    expect(previewItems(null), isEmpty);
    expect(FileMenuAction.values.take(3), [
      FileMenuAction.copyGif,
      FileMenuAction.copyGifFile,
      FileMenuAction.copyImage,
    ]);
    expect(
      [for (final a in FileMenuAction.values) fileMenuLabel(a, 1)],
      [
        'Copy as GIF to clipboard',
        'Copy as GIF file',
        'Copy image to clipboard',
        'Copy file',
        'Copy path',
        'Open',
        'Open with…',
        'Use as pack cover',
        'Add to pack previews',
        'Remove from pack previews',
      ],
    );
    expect(fileMenuLabel(FileMenuAction.copyFiles, 3), 'Copy 3 files');
    expect(fileMenuLabel(FileMenuAction.copyPath, 3), 'Copy 3 paths');
    expect(fileMenuActions(anim, _Caps(false)), [
      FileMenuAction.copyPath,
      FileMenuAction.open,
    ]);
    expect(fileMenuActions(many, _Caps(true)), [
      FileMenuAction.copyFiles,
      FileMenuAction.copyPath,
    ]);
    expect(fileMenuActions(one, _Caps(false)), [
      FileMenuAction.copyPath,
      FileMenuAction.open,
    ]);
  });
}
