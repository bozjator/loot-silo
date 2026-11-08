import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The README's images are committed media with alt text (M53); since
/// M54 only the logo and the three screenshots in docs/media.
void main() {
  final readme = File('README.md').readAsStringSync();
  final images = RegExp(r'<img\s[^>]*>').allMatches(readme).map((m) => m[0]!);

  test('every README image is a local file with alt text', () {
    expect(images.length, 4, reason: 'the logo and three screenshots');
    for (final tag in images) {
      final src = RegExp(r'src="([^"]+)"').firstMatch(tag)?[1];
      expect(src, isNotNull, reason: tag);
      expect(src, isNot(startsWith('http')), reason: 'relative path: $tag');
      expect(File(src!).existsSync(), isTrue, reason: 'missing $src');
      final alt = RegExp(r'alt="([^"]+)"').firstMatch(tag)?[1] ?? '';
      expect(alt.length, greaterThan(10), reason: 'alt text: $tag');
    }
    // Markdown images too, if any are added later.
    for (final m in RegExp(r'!\[([^\]]*)\]\(([^)]+)\)').allMatches(readme)) {
      expect(m[1], isNotEmpty, reason: 'alt text: ${m[0]}');
      expect(File(m[2]!).existsSync(), isTrue, reason: 'missing ${m[2]}');
    }
  });

  test('docs/media is the three screenshots, each shown in the README', () {
    final files = Directory('docs/media').listSync().whereType<File>();
    expect(files.length, 3);
    var total = 0;
    for (final f in files) {
      final rel = 'docs/media/${f.uri.pathSegments.last}';
      expect(readme, contains('src="$rel"'), reason: '$rel unused');
      total += f.lengthSync();
    }
    expect(total, lessThan(2 * 1024 * 1024));
  });

  test('the README still describes every feature area', () {
    for (final heading in [
      'Library and import',
      'Dashboard: search, filters and favorites',
      'Sprite sheet and animation detection',
      'Image viewer',
      'Sound effects browser',
      'Credits and licenses',
      'itch.io sync',
      'Tabs, resume and themes',
    ]) {
      expect(readme, contains('### $heading'), reason: heading);
    }
  });

  test('the README links to itch.io near the top and the end', () {
    const itch = 'https://bozjator.itch.io/loot-silo';
    final first = readme.indexOf(itch);
    expect(first, inInclusiveRange(0, readme.length ~/ 10));
    expect(readme.lastIndexOf(itch), greaterThan(readme.length * 9 ~/ 10));
  });
}
