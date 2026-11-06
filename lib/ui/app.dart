import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../install/archive_extractor.dart';
import '../state/dashboard.dart';
import '../state/providers.dart';
import '../state/settings.dart';
import 'archive_import.dart';
import 'credits_screen.dart';
import 'dashboard.dart';
import 'folder_import_screen.dart';
import 'itch_screen.dart';
import 'settings_screen.dart';
import 'tabs.dart';
import 'cursors.dart';

/// Root widget of Asset Explorer.
class AssetsExplorerApp extends ConsumerStatefulWidget {
  const AssetsExplorerApp({super.key});

  @override
  ConsumerState<AssetsExplorerApp> createState() => _AppState();
}

class _AppState extends ConsumerState<AssetsExplorerApp> {
  final _navigator = GlobalKey<NavigatorState>();
  final _top = TopRoute();

  /// Runs an app-wide shortcut on any page, but not over a dialog or a
  /// popup menu, and only once a library is set up.
  void Function() _shortcut(
    void Function(BuildContext context) action, {
    bool needsLibrary = true,
    String? notOn,
  }) => () {
    final context = _navigator.currentContext;
    final top = _top.top;
    if (context == null || top is! PageRoute) return;
    // A popup menu inside a tab is on that tab's navigator.
    final tabTop = ref.read(tabsProvider.notifier).currentTop;
    if (top.isFirst && tabTop != null && tabTop is! PageRoute) return;
    if (notOn != null && top.settings.name == notOn) return;
    if (needsLibrary && ref.read(settingsProvider).libraryPath == null) return;
    action(context);
  };

  /// Ctrl+I/O import, Ctrl+R/F5 rescan, Ctrl+, settings. They live above the
  /// navigator, so they work wherever focus is (also when it fell back to a
  /// page's focus scope after a click on empty space or a page closing).
  Map<ShortcutActivator, VoidCallback> get _appShortcuts {
    final rescan = _shortcut((_) => rescanLibrary(ref));
    return {
      const SingleActivator(LogicalKeyboardKey.keyI, control: true): _shortcut(
        (c) => importFolder(c, ref),
        notOn: FolderImportScreen.routeName,
      ),
      const SingleActivator(LogicalKeyboardKey.keyO, control: true): _shortcut(
        (c) => importArchive(c, ref),
        notOn: FolderImportScreen.routeName,
      ),
      const SingleActivator(LogicalKeyboardKey.keyR, control: true): rescan,
      const SingleActivator(LogicalKeyboardKey.f5): rescan,
      // Pack tabs: only while the tabs are shown (no page over them).
      const SingleActivator(LogicalKeyboardKey.tab, control: true): _onTabs(
        (t) => t.cycle(1),
      ),
      const SingleActivator(LogicalKeyboardKey.tab, control: true, shift: true):
          _onTabs((t) => t.cycle(-1)),
      const SingleActivator(LogicalKeyboardKey.keyW, control: true): _onTabs(
        (t) => t.closeCurrent(),
      ),
      const SingleActivator(LogicalKeyboardKey.comma, control: true): _shortcut(
        openSettings,
        needsLibrary: false,
        notOn: SettingsScreen.routeName,
      ),
    };
  }

  /// A tab shortcut, run when the tabs are on top (no page or dialog over
  /// them, no menu inside the shown tab).
  VoidCallback _onTabs(void Function(TabsNotifier tabs) action) =>
      _shortcut((_) {
        if (_top.top?.isFirst ?? false) action(ref.read(tabsProvider.notifier));
      });

  /// Closes the top page or dialog, else goes back within the shown tab; on
  /// the dashboard, leaves an open bundle.
  Future<void> _back() async {
    final root = _navigator.currentState;
    if (root != null && root.canPop()) {
      await root.maybePop();
      return;
    }
    final tabs = ref.read(tabsProvider.notifier);
    if (await tabs.currentNavigator?.maybePop() ?? false) return;
    if (ref.read(tabsProvider).active != 0) return;
    final query = ref.read(dashboardQueryProvider.notifier);
    if (ref.read(dashboardQueryProvider).bundleId != null) {
      query.openBundle(null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = ref.watch(settingsProvider.select((s) => s.theme));
    return MaterialApp(
      title: 'Asset Explorer',
      debugShowCheckedModeBanner: false,
      navigatorKey: _navigator,
      navigatorObservers: [_top],
      themeMode: switch (theme) {
        ThemeChoice.system => ThemeMode.system,
        ThemeChoice.light => ThemeMode.light,
        ThemeChoice.dark => ThemeMode.dark,
      },
      // Esc and the mouse back button close the current page; dialogs and
      // search handle Esc first.
      builder: (context, child) => Listener(
        onPointerDown: (event) {
          if (event.buttons & kBackMouseButton != 0) _back();
        },
        child: CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.escape): _back,
            ..._appShortcuts,
          },
          child: child!,
        ),
      ),
      theme: withClickCursors(
        ThemeData(colorSchemeSeed: Colors.teal, brightness: Brightness.light),
      ),
      darkTheme: withClickCursors(
        ThemeData(colorSchemeSeed: Colors.teal, brightness: Brightness.dark),
      ),
      home: const TabsHost(dashboard: HomeScreen()),
    );
  }
}

/// Picks a folder and opens the import review; rescans after an import.
Future<void> importFolder(BuildContext context, WidgetRef ref) async {
  final source = await ref.read(directoryPickerProvider)('Import folder');
  if (source == null || !context.mounted) return;
  final imported = await Navigator.of(context, rootNavigator: true).push<bool>(
    MaterialPageRoute(
      settings: const RouteSettings(name: FolderImportScreen.routeName),
      builder: (_) => FolderImportScreen(sourcePath: source),
    ),
  );
  if (imported == true) await ref.read(libraryProvider.notifier).rescan();
}

/// Picks archives and imports them; rescans after an import.
Future<void> importArchive(BuildContext context, WidgetRef ref) async {
  final paths = await ref.read(archivePickerProvider)();
  if (paths.isEmpty || !context.mounted) return;
  if (await importArchives(context, ref, paths)) {
    await ref.read(libraryProvider.notifier).rescan();
  }
}

/// Rescans the library unless a scan is already running.
void rescanLibrary(WidgetRef ref) {
  if (!ref.read(libraryProvider).isLoading) {
    ref.read(libraryProvider.notifier).rescan();
  }
}

void openSettings(BuildContext context) =>
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(
        settings: const RouteSettings(name: SettingsScreen.routeName),
        builder: (_) => const SettingsScreen(),
      ),
    );

/// Library overview: the dashboard plus import, itch.io, credits and
/// settings.
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  Future<void> _chooseLibrary(BuildContext context, WidgetRef ref) async {
    final path = await ref.read(directoryPickerProvider)('Use as library');
    if (path != null) ref.read(settingsProvider.notifier).setLibraryPath(path);
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
          await Navigator.of(context, rootNavigator: true).push<bool>(
            MaterialPageRoute(
              settings: const RouteSettings(name: FolderImportScreen.routeName),
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
    void rescan() => rescanLibrary(ref);

    // Ctrl+I/O/R, F5 and Ctrl+, are bound app-wide (AssetsExplorerApp).
    return Scaffold(
      appBar: AppBar(
        title: const Text('Asset Explorer'),
        bottom: tabStrip(ref, progress: scanning),
        actions: [
          IconButton(
            tooltip: 'itch.io',
            onPressed: () => Navigator.of(
              context,
              rootNavigator: true,
            ).push(MaterialPageRoute<void>(builder: (_) => const ItchScreen())),
            icon: const Icon(Icons.storefront_outlined),
          ),
          IconButton(
            tooltip: 'Credits',
            onPressed: () => Navigator.of(context, rootNavigator: true).push(
              MaterialPageRoute<void>(builder: (_) => const CreditsScreen()),
            ),
            icon: const Icon(Icons.receipt_long_outlined),
          ),
          IconButton(
            tooltip: 'Rescan library (F5)',
            onPressed: scanning ? null : rescan,
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: 'Settings (Ctrl+,)',
            onPressed: () => openSettings(context),
            icon: const Icon(Icons.settings_outlined),
          ),
          const SizedBox(width: 4),
          OutlinedButton.icon(
            onPressed: () => importArchive(context, ref),
            icon: const Icon(Icons.archive_outlined),
            label: const Text('Import archive'),
          ),
          const SizedBox(width: 8),
          FilledButton.tonalIcon(
            onPressed: () => importFolder(context, ref),
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
            action: Wrap(
              spacing: 8,
              children: [
                OutlinedButton(
                  onPressed: rescan,
                  child: const Text('Try again'),
                ),
                FilledButton(
                  onPressed: () => _chooseLibrary(context, ref),
                  child: const Text('Choose another folder'),
                ),
              ],
            ),
          ),
          AsyncValue(hasValue: true) => _Message(
            icon: Icons.inventory_2_outlined,
            title: 'Your library is empty',
            body: 'Import a folder or drop an archive to get started.',
            action: FilledButton.icon(
              onPressed: () => importFolder(context, ref),
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
