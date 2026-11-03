import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

void copyTree(String from, String to) {
  for (final e in Directory(from).listSync(recursive: true)) {
    final target = p.join(to, p.relative(e.path, from: from));
    if (e is Directory) {
      Directory(target).createSync(recursive: true);
    } else if (e is File) {
      Directory(p.dirname(target)).createSync(recursive: true);
      e.copySync(target);
    }
  }
}

/// Relative path → SHA-1 for every file under [root], including hidden ones.
Map<String, String> snapshot(String root) => {
  for (final f in Directory(root).listSync(recursive: true).whereType<File>())
    p.relative(f.path, from: root): sha1
        .convert(f.readAsBytesSync())
        .toString(),
};
