import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Files bigger than this are not previewed; they open externally instead.
const previewMaxBytes = 1024 * 1024;

const _textExtensions = {
  '.txt', '.md', '.markdown', '.json', '.csv', '.tsv', '.ini', '.cfg', //
  '.tsx', '.tmx', '.xml', '.yaml', '.yml', '.log', '.nfo',
};

/// Extension-less names that are plain text in practice.
const _textNames = {'readme', 'license', 'licence', 'copying', 'credits'};

/// Whether [rel] can be shown in the text preview.
bool isTextPreviewable(String rel) {
  final ext = p.extension(rel).toLowerCase();
  if (_textExtensions.contains(ext)) return true;
  return ext.isEmpty && _textNames.contains(p.basename(rel).toLowerCase());
}

bool isMarkdown(String rel) =>
    const {'.md', '.markdown'}.contains(p.extension(rel).toLowerCase());

/// What the preview shows: the text, or why there is none.
class TextPreview {
  const TextPreview.text(this.text, {this.latin1 = false}) : size = null;
  const TextPreview.tooLarge(int this.size) : text = null, latin1 = false;

  final String? text;

  /// Not valid UTF-8, so decoded as Latin-1.
  final bool latin1;

  /// Set when the file is over [previewMaxBytes].
  final int? size;
}

/// Decodes [bytes] as UTF-8 (dropping a BOM), or Latin-1 when that fails;
/// Latin-1 maps every byte, so any file decodes.
TextPreview decodeText(List<int> bytes) {
  try {
    var text = utf8.decode(bytes);
    if (text.startsWith('﻿')) text = text.substring(1);
    return TextPreview.text(text);
  } on FormatException {
    return TextPreview.text(latin1.decode(bytes), latin1: true);
  }
}

/// Reads [path] for the preview, without loading files over [maxBytes].
Future<TextPreview> readTextPreview(
  String path, {
  int maxBytes = previewMaxBytes,
}) async {
  final file = File(path);
  final size = await file.length();
  if (size > maxBytes) return TextPreview.tooLarge(size);
  return decodeText(await file.readAsBytes());
}
