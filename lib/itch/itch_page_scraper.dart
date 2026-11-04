import 'package:html/parser.dart' as html;

/// Full-size screenshot URLs from a public itch.io game page, in page
/// order, at most [limit].
List<Uri> screenshotUrls(String pageHtml, {int limit = 8}) {
  final doc = html.parse(pageHtml);
  final out = <Uri>[];
  for (final a in doc.querySelectorAll('.screenshot_list a')) {
    final href =
        a.attributes['href'] ?? a.querySelector('img')?.attributes['src'];
    final uri = Uri.tryParse(href ?? '');
    if (uri == null || !uri.hasScheme || !uri.scheme.startsWith('http')) {
      continue;
    }
    if (!out.contains(uri)) out.add(uri);
    if (out.length >= limit) break;
  }
  return out;
}

/// The file extension an image URL most likely has (`png` by default).
String imageExtension(Uri uri, {String? contentType}) {
  final fromType = switch (contentType?.split(';').first.trim()) {
    'image/png' => 'png',
    'image/gif' => 'gif',
    'image/jpeg' => 'jpg',
    'image/webp' => 'webp',
    _ => null,
  };
  if (fromType != null) return fromType;
  final last = uri.pathSegments.isEmpty ? '' : uri.pathSegments.last;
  final dot = last.lastIndexOf('.');
  final ext = dot < 0 ? '' : last.substring(dot + 1).toLowerCase();
  return const {'png', 'gif', 'jpg', 'jpeg', 'webp'}.contains(ext)
      ? ext
      : 'png';
}
