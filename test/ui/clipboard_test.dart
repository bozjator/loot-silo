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

  test('menu items: only what applies, in order', () {
    const one = FileMenuTarget(
      files: ['/a.png'],
      image: '/a.png',
      open: '/a.png',
    );
    const many = FileMenuTarget(files: ['/a.png', '/b.png']);
    expect(fileMenuActions(one, _Caps(true)), FileMenuAction.values);
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
