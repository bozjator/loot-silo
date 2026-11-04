import 'dart:convert';
import 'dart:io';

import 'package:assets_explorer/core/text_preview.dart';
import 'package:path/path.dart' as p;
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('preview'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('which files preview', () {
    for (final rel in [
      'README.md',
      'docs/License.TXT',
      'map.tmx',
      'tiles.tsx',
      'data.json',
      'LICENSE',
      'readme',
    ]) {
      expect(isTextPreviewable(rel), isTrue, reason: rel);
    }
    for (final rel in ['font.ttf', 'model.fbx', 'Makefile', 'a.png']) {
      expect(isTextPreviewable(rel), isFalse, reason: rel);
    }
    expect(isMarkdown('a/B.MD'), isTrue);
    expect(isMarkdown('a.txt'), isFalse);
  });

  test('UTF-8 decodes and drops a BOM', () {
    final r = decodeText([0xEF, 0xBB, 0xBF, ...utf8.encode('Čuk ♥')]);
    expect(r.text, 'Čuk ♥');
    expect(r.latin1, isFalse);
  });

  test('invalid UTF-8 falls back to Latin-1 instead of failing', () {
    // "Café © 2019" in Windows-1252/Latin-1.
    final r = decodeText([
      ...'Caf'.codeUnits,
      0xE9,
      0x20,
      0xA9,
      ...' 2019'.codeUnits,
    ]);
    expect(r.text, 'Café © 2019');
    expect(r.latin1, isTrue);
  });

  test('files over the cap are not read', () async {
    final big = File(p.join(tmp.path, 'big.txt'))
      ..writeAsBytesSync(List.filled(2048, 0x41));
    final r = await readTextPreview(big.path, maxBytes: 1024);
    expect(r.text, isNull);
    expect(r.size, 2048);
    final ok = await readTextPreview(big.path, maxBytes: 4096);
    expect(ok.text, hasLength(2048));
    expect(previewMaxBytes, 1024 * 1024);
  });
}
