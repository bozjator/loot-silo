import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/providers.dart';
import 'folder_import_screen.dart';

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
            tooltip: 'Rescan library',
            onPressed: scanning
                ? null
                : () => ref.read(libraryProvider.notifier).rescan(),
            icon: const Icon(Icons.refresh),
          ),
          const SizedBox(width: 4),
          FilledButton.tonalIcon(
            onPressed: () => _importFolder(context, ref),
            icon: const Icon(Icons.drive_folder_upload_outlined),
            label: const Text('Import folder'),
          ),
          const SizedBox(width: 12),
        ],
      ),
      body: switch (library) {
        AsyncValue(:final value?) when value.packs.isNotEmpty => _PackList(
          state: value,
        ),
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
    );
  }
}

class _PackList extends StatelessWidget {
  const _PackList({required this.state});

  final LibraryState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final top = state.topLevel.toList();
    final subCount = state.packs.length - top.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text(
            '${top.length} packs'
            '${subCount > 0 ? ' · $subCount sub-packs' : ''}'
            ' · ${state.root}',
            style: theme.textTheme.labelLarge,
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: top.length,
            itemBuilder: (context, i) {
              final pack = top[i];
              return ListTile(
                dense: true,
                title: Text(pack.title),
                subtitle: Text(
                  '${pack.author ?? 'Unknown author'} · '
                  '${pack.types.join(', ')} · ${pack.fileCount} files',
                ),
              );
            },
          ),
        ),
      ],
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
