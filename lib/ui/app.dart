import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../install/archive_extractor.dart';
import '../state/providers.dart';
import 'archive_import.dart';
import 'credits_screen.dart';
import 'dashboard.dart';
import 'folder_import_screen.dart';
import 'itch_screen.dart';

/// Root widget of Asset Explorer.
class AssetsExplorerApp extends StatelessWidget {
  const AssetsExplorerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Asset Explorer',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: Colors.teal,
        brightness: Brightness.light,
      ),
      darkTheme: ThemeData(
        colorSchemeSeed: Colors.teal,
        brightness: Brightness.dark,
      ),
      home: const HomeScreen(),
    );
  }
}

/// Library overview. A plain list until the dashboard milestone lands.
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  Future<void> _chooseLibrary(BuildContext context, WidgetRef ref) async {
    final path = await ref.read(directoryPickerProvider)('Use as library');
    if (path != null) ref.read(settingsProvider.notifier).setLibraryPath(path);
  }

  Future<void> _importFolder(BuildContext context, WidgetRef ref) async {
    final source = await ref.read(directoryPickerProvider)('Import folder');
    if (source == null || !context.mounted) return;
    final imported = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => FolderImportScreen(sourcePath: source)),
    );
    if (imported == true) await ref.read(libraryProvider.notifier).rescan();
  }

  Future<void> _importArchive(BuildContext context, WidgetRef ref) async {
    final paths = await ref.read(archivePickerProvider)();
    if (paths.isEmpty || !context.mounted) return;
    if (await importArchives(context, ref, paths)) {
      await ref.read(libraryProvider.notifier).rescan();
    }
  }

  /// Dropped folders go through the folder import, archives through the
  /// archive import; anything else is reported.
  Future<void> _onDrop(
    BuildContext context,
    WidgetRef ref,
    List<String> paths,
  ) async {
    final folders = [
      for (final path in paths)
        if (FileSystemEntity.isDirectorySync(path)) path,
    ];
    final archives = [
      for (final path in paths)
        if (archiveKindOf(path) != null && File(path).existsSync()) path,
    ];
    final skipped = paths.length - folders.length - archives.length;
    if (skipped > 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Skipped $skipped dropped '
            '${skipped == 1 ? 'item' : 'items'}: only folders and '
            'zip / rar / 7z / tar archives can be imported',
          ),
        ),
      );
    }
    var imported = false;
    if (archives.isNotEmpty) {
      imported = await importArchives(context, ref, archives);
    }
    for (final folder in folders) {
      if (!context.mounted) break;
      imported |=
          await Navigator.of(context).push<bool>(
            MaterialPageRoute(
              builder: (_) => FolderImportScreen(sourcePath: folder),
            ),
          ) ??
          false;
    }
    if (imported) await ref.read(libraryProvider.notifier).rescan();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final libraryPath = ref.watch(
      settingsProvider.select((s) => s.libraryPath),
    );
    if (libraryPath == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Asset Explorer')),
        body: _Message(
          icon: Icons.folder_special_outlined,
          title: 'Choose a library folder',
          body:
              'Asset Explorer keeps your packs in one folder it manages, '
              'organised as Author/Pack.',
          action: FilledButton.icon(
            onPressed: () => _chooseLibrary(context, ref),
            icon: const Icon(Icons.folder_open),
            label: const Text('Choose folder'),
          ),
        ),
      );
    }

    final library = ref.watch(libraryProvider);
    final scanning = library.isLoading;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Asset Explorer'),
        bottom: scanning
            ? const PreferredSize(
                preferredSize: Size.fromHeight(4),
                child: LinearProgressIndicator(),
              )
            : null,
        actions: [
          IconButton(
            tooltip: 'itch.io',
            onPressed: () => Navigator.of(
              context,
            ).push(MaterialPageRoute<void>(builder: (_) => const ItchScreen())),
            icon: const Icon(Icons.storefront_outlined),
          ),
          IconButton(
            tooltip: 'Credits',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const CreditsScreen()),
            ),
            icon: const Icon(Icons.receipt_long_outlined),
          ),
          IconButton(
            tooltip: 'Rescan library',
            onPressed: scanning
                ? null
                : () => ref.read(libraryProvider.notifier).rescan(),
            icon: const Icon(Icons.refresh),
          ),
          const SizedBox(width: 4),
          OutlinedButton.icon(
            onPressed: () => _importArchive(context, ref),
            icon: const Icon(Icons.archive_outlined),
            label: const Text('Import archive'),
          ),
          const SizedBox(width: 8),
          FilledButton.tonalIcon(
            onPressed: () => _importFolder(context, ref),
            icon: const Icon(Icons.drive_folder_upload_outlined),
            label: const Text('Import folder'),
          ),
          const SizedBox(width: 12),
        ],
      ),
      body: DropZone(
        onDrop: (paths) => _onDrop(context, ref, paths),
        child: switch (library) {
          AsyncValue(:final value?) when value.packs.isNotEmpty =>
            const Dashboard(),
          AsyncValue(:final error?) => _Message(
            icon: Icons.error_outline,
            title: 'Could not read the library',
            body: '$error',
          ),
          AsyncValue(hasValue: true) => _Message(
            icon: Icons.inventory_2_outlined,
            title: 'Your library is empty',
            body: 'Import a folder or drop an archive to get started.',
            action: FilledButton.icon(
              onPressed: () => _importFolder(context, ref),
              icon: const Icon(Icons.drive_folder_upload_outlined),
              label: const Text('Import folder'),
            ),
          ),
          _ => const Center(child: Text('Scanning library…')),
        },
      ),
    );
  }
}

/// Accepts files dragged in from the desktop and shows a hint while
/// something hovers.
class DropZone extends StatefulWidget {
  const DropZone({super.key, required this.onDrop, required this.child});

  final ValueChanged<List<String>> onDrop;
  final Widget child;

  @override
  State<DropZone> createState() => _DropZoneState();
}

class _DropZoneState extends State<DropZone> {
  var _hovering = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DropTarget(
      onDragEntered: (_) => setState(() => _hovering = true),
      onDragExited: (_) => setState(() => _hovering = false),
      onDragDone: (details) {
        setState(() => _hovering = false);
        widget.onDrop([for (final f in details.files) f.path]);
      },
      child: Stack(
        fit: StackFit.expand,
        children: [
          widget.child,
          if (_hovering)
            IgnorePointer(
              child: Container(
                margin: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: scheme.primaryContainer.withValues(alpha: 0.85),
                  border: Border.all(color: scheme.primary, width: 3),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.file_download,
                        size: 64,
                        color: scheme.primary,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'Drop archives or folders to import',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({
    required this.icon,
    required this.title,
    required this.body,
    this.action,
  });

  final IconData icon;
  final String title;
  final String body;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 64, color: theme.colorScheme.primary),
            const SizedBox(height: 16),
            Text(title, style: theme.textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(body, textAlign: TextAlign.center),
            if (action != null) ...[const SizedBox(height: 20), action!],
          ],
        ),
      ),
    );
  }
}
