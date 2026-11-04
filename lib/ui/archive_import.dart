import 'dart:io';
import 'dart:isolate';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../install/archive_extractor.dart';
import '../state/providers.dart';
import 'folder_import_screen.dart';

/// Top-level so the isolate closure captures nothing but its arguments.
Future<ExtractedArchive> _extractInBackground(String archive, String dest) =>
    Isolate.run(() => extractArchive(archive, dest));

/// Extracts [archives] next to each other in a temporary folder, then
/// opens the usual import review on that folder. The temporary folder is
/// removed afterwards; the archives themselves are never touched.
///
/// Returns true when anything was imported.
Future<bool> importArchives(
  BuildContext context,
  WidgetRef ref,
  List<String> archives,
) async {
  final temp = Directory(
    p.join(
      ref.read(extractRootProvider),
      'import-${DateTime.now().microsecondsSinceEpoch}',
    ),
  );
  final progress = ValueNotifier<String>('');
  final extracted = <ExtractedArchive>[];
  final errors = <String>[];
  try {
    temp.createSync(recursive: true);
    if (!context.mounted) return false;
    // Not awaited: closed below once extraction is done.
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _ExtractDialog(progress: progress),
    );
    for (final (i, archive) in archives.indexed) {
      progress.value =
          'Extracting ${p.basename(archive)} (${i + 1}/${archives.length})';
      try {
        extracted.add(await _extractInBackground(archive, temp.path));
      } on Object catch (e) {
        errors.add(
          e is ExtractError ? e.message : '${p.basename(archive)}: $e',
        );
      }
    }
    if (context.mounted) Navigator.of(context).pop();
    if (!context.mounted) return false;
    if (extracted.isEmpty) {
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Nothing to import'),
          content: Text(errors.join('\n')),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('OK'),
            ),
          ],
        ),
      );
      return false;
    }
    final imported = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => FolderImportScreen(
          sourcePath: temp.path,
          title: archives.length == 1 ? 'Import archive' : 'Import archives',
          origins: {
            for (final e in extracted) p.basename(e.folder): e.archivePath,
          },
          notes: errors,
        ),
      ),
    );
    return imported ?? false;
  } finally {
    progress.dispose();
    if (temp.existsSync()) await temp.delete(recursive: true);
  }
}

class _ExtractDialog extends StatelessWidget {
  const _ExtractDialog({required this.progress});

  final ValueNotifier<String> progress;

  @override
  Widget build(BuildContext context) => AlertDialog(
    content: Row(
      children: [
        const CircularProgressIndicator(),
        const SizedBox(width: 20),
        Expanded(
          child: ValueListenableBuilder(
            valueListenable: progress,
            builder: (_, text, _) => Text(text),
          ),
        ),
      ],
    ),
  );
}
