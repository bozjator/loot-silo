import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

import '../core/text_preview.dart';
import 'format.dart';
import 'reveal.dart';

/// Opens [rel] (relative to [packPath]) in the [TextPreviewDialog].
Future<void> showTextPreview(
  BuildContext context, {
  required String packPath,
  required String rel,
}) => showDialog<void>(
  context: context,
  builder: (_) => TextPreviewDialog(packPath: packPath, rel: rel),
);

/// A text file, read-only: monospace and selectable, or rendered when it's
/// Markdown (with a Raw / Rendered switch). Files over [previewMaxBytes]
/// only offer to open externally.
class TextPreviewDialog extends ConsumerStatefulWidget {
  const TextPreviewDialog({
    super.key,
    required this.packPath,
    required this.rel,
  });

  final String packPath;
  final String rel;

  @override
  ConsumerState<TextPreviewDialog> createState() => _TextPreviewDialogState();
}

class _TextPreviewDialogState extends ConsumerState<TextPreviewDialog> {
  late final _path = p.join(widget.packPath, widget.rel);
  late final _preview = readTextPreview(_path);
  late var _rendered = isMarkdown(widget.rel);

  void _openExternally() => launchUrl(Uri.file(_path));

  /// Web and mail links open in the browser; relative links are ignored.
  void _onLink(String text, String? href, String title) {
    final uri = href == null ? null : Uri.tryParse(href);
    if (uri != null && const {'http', 'https', 'mailto'}.contains(uri.scheme)) {
      launchUrl(uri);
    }
  }

  /// Images next to the file are shown; remote ones are not fetched.
  Widget _image(Uri uri, String? title, String? alt) {
    if (!uri.hasScheme) {
      final file = File(
        p.join(p.dirname(_path), Uri.decodeComponent(uri.path)),
      );
      if (p.isWithin(widget.packPath, file.path) && file.existsSync()) {
        return Image.file(file, filterQuality: FilterQuality.none);
      }
    }
    return Text('[${alt ?? title ?? uri}]');
  }

  @override
  Widget build(BuildContext context) {
    final window = MediaQuery.sizeOf(context);
    final theme = Theme.of(context);
    final markdown = isMarkdown(widget.rel);
    return Dialog(
      insetPadding: EdgeInsets.symmetric(
        horizontal: window.width * 0.08,
        vertical: window.height * 0.06,
      ),
      clipBehavior: Clip.antiAlias,
      child: FutureBuilder(
        future: _preview,
        builder: (context, snap) {
          final text = snap.data?.text;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 8, 12),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            p.basename(widget.rel),
                            style: theme.textTheme.titleMedium,
                          ),
                          Text(
                            [
                              widget.rel,
                              if (snap.data?.latin1 ?? false)
                                'not UTF-8, shown as Latin-1',
                            ].join(' · '),
                            style: theme.textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                    if (markdown && text != null) ...[
                      SegmentedButton<bool>(
                        showSelectedIcon: false,
                        segments: const [
                          ButtonSegment(value: false, label: Text('Raw')),
                          ButtonSegment(value: true, label: Text('Rendered')),
                        ],
                        selected: {_rendered},
                        onSelectionChanged: (s) =>
                            setState(() => _rendered = s.single),
                      ),
                      const SizedBox(width: 8),
                    ],
                    IconButton(
                      tooltip: 'Copy all',
                      icon: const Icon(Icons.copy),
                      onPressed: text == null
                          ? null
                          : () {
                              Clipboard.setData(ClipboardData(text: text));
                              ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                                const SnackBar(content: Text('Copied')),
                              );
                            },
                    ),
                    IconButton(
                      tooltip: 'Open externally',
                      icon: const Icon(Icons.open_in_new),
                      onPressed: _openExternally,
                    ),
                    IconButton(
                      tooltip: 'Show in file manager',
                      icon: const Icon(Icons.drive_file_move_outline),
                      onPressed: () => ref.read(revealProvider)(_path),
                    ),
                    IconButton(
                      tooltip: 'Close',
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(child: _body(context, snap)),
            ],
          );
        },
      ),
    );
  }

  Widget _body(BuildContext context, AsyncSnapshot<TextPreview> snap) {
    if (snap.hasError) {
      return Center(child: Text('Could not read: ${snap.error}'));
    }
    final preview = snap.data;
    if (preview == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final text = preview.text;
    if (text == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'This file is too large to preview '
              '(${formatBytes(preview.size!)}).',
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _openExternally,
              icon: const Icon(Icons.open_in_new),
              label: const Text('Open externally'),
            ),
          ],
        ),
      );
    }
    if (_rendered) {
      return Markdown(
        data: text,
        selectable: true,
        padding: const EdgeInsets.all(20),
        onTapLink: _onLink,
        imageBuilder: _image,
      );
    }
    return Scrollbar(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: SelectableText(
          text,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
        ),
      ),
    );
  }
}
